#!/usr/bin/env python3
"""공개 프로젝트 검증기의 독립 식별·오답 거부·측정 경계를 오프라인으로 검사한다."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("benchmark-indexstore-project.py")
SPEC = importlib.util.spec_from_file_location("indexstore_project", SCRIPT)
assert SPEC and SPEC.loader
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)


class FrozenContractTests(unittest.TestCase):
    def test_original_source_evidence_is_byte_identical(self):
        oracle, manifest = BENCH.frozen_inputs()
        self.assertIn("not the final holdout", oracle["role"])
        self.assertEqual(len(oracle["edges"]), 13)
        self.assertEqual(sum(len(edge["call_lines"]) for edge in oracle["edges"]), 17)
        self.assertEqual(len(BENCH.source_files(manifest)), 53)
        self.assertEqual([query["expected_count"] for query in oracle["queries"]], [1, 4, 10])
        edges = [[edge["caller"], edge["callee"]] for edge in oracle["edges"]]
        for query in oracle["queries"]:
            self.assertEqual(
                BENCH.reverse_depths(edges, query["seed"], query["max_depth"]),
                {item["id"]: item["minimum_depth"] for item in query["expected"]},
            )

    def test_oracle_and_checksum_cannot_be_silently_refrozen(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary) / "fixture"
            shutil.copytree(BENCH.FIXTURE, fixture)
            path = fixture / "oracle.json"
            oracle = json.loads(path.read_text())
            oracle["queries"][0]["expected"] = []
            BENCH.BASE.save(path, oracle)
            sums = (
                (fixture / "SHA256SUMS")
                .read_text()
                .replace(BENCH.FROZEN_HASHES["oracle.json"], BENCH.BASE.sha256(path))
            )
            (fixture / "SHA256SUMS").write_text(sums)
            with self.assertRaisesRegex(ValueError, "Frozen source evidence changed"):
                BENCH.frozen_inputs(fixture)

    def test_depths_and_cycles_have_minimum_distances(self):
        edges = [["a", "seed"], ["b", "a"], ["c", "b"], ["c", "a"], ["a", "a"], ["seed", "b"], ["outside", "c"]]
        self.assertEqual(BENCH.reverse_depths(edges, "seed", 1), {"a": 1})
        self.assertEqual(BENCH.reverse_depths(edges, "seed", 3), {"a": 1, "b": 2, "c": 2, "outside": 3})

    def test_protocol_describes_cached_and_native_work_honestly(self):
        protocol = BENCH.read_json(BENCH.FIXTURE / "runner-protocol.json")
        self.assertIn("reuses its persisted actual-CLI call graph", protocol["queries"])
        self.assertIn("no cold-cache claim", protocol["first"])
        self.assertIn("No superiority conclusion", protocol["interpretation"])
        self.assertIn("not simultaneous aggregate", protocol["rss"])


class IdentityAndAnswerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.project = Path(self.temporary.name)
        self.relative = "Sources/Example/With Spaces.swift"
        path = self.project / self.relative
        path.parent.mkdir(parents=True)
        path.write_text(
            "func seed() {}\nfunc caller() { seed() }\nfunc second() { caller() }\nfunc unrelated() {}\n"
            "func overloaded(_ x: Int) {}\nfunc overloaded(_ x: String) {}\nstruct Thing {\n  init() {}\n}\n"
        )
        self.allowed = {self.relative}
        self.ids = {
            name: f"{self.relative}:{line}:{column}"
            for name, line, column in [
                ("seed", 1, 6),
                ("caller", 2, 6),
                ("second", 3, 6),
                ("unrelated", 4, 6),
                ("overloaded_int", 5, 6),
                ("overloaded_string", 6, 6),
                ("init", 8, 3),
            ]
        }
        self.usrs = {name: f"baseline:{name}" for name in self.ids}
        self.oracle = {
            "nodes": [
                {"id": name, "source_id": self.ids[name], "minimum_caller_depth": depth}
                for name, depth in [("seed", 0), ("caller", 1), ("second", 2)]
            ],
            "edges": [{"caller": "caller", "callee": "seed"}, {"caller": "second", "callee": "caller"}],
            "queries": [
                {
                    "id": f"depth_{depth}",
                    "seed": "seed",
                    "max_depth": depth,
                    "expected": [
                        {"id": name, "minimum_depth": distance}
                        for name, distance in [("caller", 1), ("second", 2)]
                        if distance <= depth
                    ],
                }
                for depth in [1, 3, 5]
            ],
            "explicit_negative_controls": [
                {"path": self.relative, "declaration_line": 4, "qualified_signature": "unrelated()"}
            ],
        }
        self.candidates = {identity: {self.usrs[name]} for name, identity in self.ids.items()}
        self.raw_edges = {(self.usrs["caller"], self.usrs["seed"]), (self.usrs["second"], self.usrs["caller"])}
        self.graph = BENCH.normalized_graph(self.candidates, self.raw_edges, set(self.usrs.values()), self.oracle)

    def tearDown(self):
        self.temporary.cleanup()

    def records(self):
        symbols, occurrences = [], []
        for name, identity in self.ids.items():
            _, row, column = identity.rsplit(":", 2)
            display = "overloaded(_:)" if name.startswith("overloaded") else f"{name}()"
            kind = "constructor" if name == "init" else "function"
            symbols.append(f"{display} | {kind} | {self.usrs[name]} | definition, reference, call, calledBy")
            occurrences.append(
                f"{row}:{column} | {display} | {kind} | {self.usrs[name]} | definition, reference, call, calledBy"
            )
        occurrences.extend(
            [
                f"2:17 | seed() | function | {self.usrs['seed']} | definition, reference, call, calledBy",
                f"  calledBy, containedBy | {self.usrs['caller']}",
                f"3:17 | caller() | function | {self.usrs['caller']} | definition, reference, call, calledBy",
                f"  calledBy, containedBy | {self.usrs['second']}",
            ]
        )
        return {self.relative: "Symbols:\n" + "\n".join(symbols) + "\n\nOccurrences:\n" + "\n".join(occurrences) + "\n"}

    def cg_document(self):
        nodes = []
        for name, identity in self.ids.items():
            path, line, column = identity.rsplit(":", 2)
            nodes.append(
                {
                    "id": f"node:{name}",
                    "usr": f"cartograph:{name}",
                    "name": "overloaded(_:)" if name.startswith("overloaded") else f"{name}()",
                    "kind": "init" if name == "init" else "function",
                    "location": {"path": path, "line": int(line), "column": int(column)},
                }
            )
        return {
            "level": "symbol",
            "nodes": nodes,
            "edges": [
                {"kind": "call", "source": "node:caller", "target": "node:seed"},
                {"kind": "call", "source": "node:second", "target": "node:caller"},
            ],
        }

    def query_document(self):
        return {
            "format": "symbol-query-batch",
            "version": 1,
            "results": [
                {
                    "requested": self.usrs["seed"],
                    "status": "found",
                    "level": "symbol",
                    "limitations": [],
                    "result": {
                        "subject": {"usr": self.usrs["seed"]},
                        "truncated": {"usedBy": False, "dependsOn": False, "members": False},
                        "usedBy": [
                            {"usr": self.usrs["caller"], "depth": 1, "edges": ["call"]},
                            {"usr": self.usrs["second"], "depth": 2, "edges": ["call"]},
                        ],
                    },
                }
            ],
        }

    def test_independent_arm_bindings_use_source_not_shared_usrs(self):
        baseline = BENCH.parse_records(self.records(), self.project, self.allowed, self.oracle)
        native = BENCH.parse_cg_graph(self.cg_document(), self.project, self.allowed, self.oracle)
        self.assertNotEqual(baseline["bindings"], native["bindings"])
        self.assertEqual(baseline["edges"], native["edges"])
        for graph in [baseline, native]:
            self.assertTrue(
                BENCH.grade(BENCH.baseline_queries(graph, BENCH.query_requests(self.oracle)), self.oracle)["passed"]
            )
            self.assertTrue(BENCH.graph_grade(graph, self.oracle)["exact_match"])

    def test_declaration_identity_ignores_symbol_wide_occurrence_roles(self):
        graph = BENCH.parse_records(self.records(), self.project, self.allowed, self.oracle)
        self.assertEqual(graph["symbols"][self.usrs["seed"]], self.ids["seed"])
        self.assertNotIn(f"{self.relative}:2:17", graph["symbols"].values())

    def test_overloads_and_initializer_keep_distinct_source_locations(self):
        graph = BENCH.parse_records(self.records(), self.project, self.allowed, self.oracle)
        self.assertEqual(graph["symbols"][self.usrs["overloaded_int"]], self.ids["overloaded_int"])
        self.assertEqual(graph["symbols"][self.usrs["overloaded_string"]], self.ids["overloaded_string"])
        self.assertEqual(graph["symbols"][self.usrs["init"]], self.ids["init"])

    def test_missing_or_ambiguous_expected_identity_fails(self):
        changed = copy.deepcopy(self.candidates)
        del changed[self.ids["seed"]]
        with self.assertRaises(ValueError):
            BENCH.normalized_graph(changed, self.raw_edges, set(self.usrs.values()), self.oracle)
        changed = copy.deepcopy(self.candidates)
        changed[self.ids["seed"]].add("alternate-seed")
        with self.assertRaises(ValueError):
            BENCH.normalized_graph(changed, self.raw_edges, set(self.usrs.values()), self.oracle)

    def test_additional_in_universe_callers_are_never_filtered_by_oracle(self):
        graph = BENCH.normalized_graph(
            self.candidates,
            self.raw_edges | {(self.usrs["unrelated"], self.usrs["seed"])},
            set(self.usrs.values()),
            self.oracle,
        )
        result = BENCH.grade(BENCH.baseline_queries(graph, BENCH.query_requests(self.oracle)), self.oracle)
        self.assertFalse(result["passed"])
        self.assertEqual(result["checks"]["depth_1"]["fp"], 1)
        self.assertEqual(result["checks"]["depth_5"]["negative_control_violations"], ["unrelated()"])
        self.assertFalse(BENCH.graph_grade(graph, self.oracle)["exact_match"])

    def test_unknown_owned_caller_is_reported_as_failure_not_discarded(self):
        graph = BENCH.normalized_graph(
            self.candidates,
            self.raw_edges | {("unknown-compiler-representation", self.usrs["seed"])},
            set(self.usrs.values()) | {"unknown-compiler-representation"},
            self.oracle,
        )
        answers = BENCH.baseline_queries(graph, BENCH.query_requests(self.oracle))
        self.assertIn("unmapped:unknown-compiler-representation", answers["depth_1"])
        self.assertFalse(BENCH.grade(answers, self.oracle)["passed"])

    def test_external_undeclared_callables_do_not_create_in_scope_paths(self):
        edges = self.raw_edges | {("external", self.usrs["seed"]), (self.usrs["unrelated"], "external")}
        graph = BENCH.normalized_graph(self.candidates, edges, set(self.usrs.values()), self.oracle)
        self.assertTrue(
            BENCH.grade(BENCH.baseline_queries(graph, BENCH.query_requests(self.oracle)), self.oracle)["passed"]
        )

    def test_wrong_depth_fails_even_when_identity_sets_match(self):
        answers = BENCH.baseline_queries(self.graph, BENCH.query_requests(self.oracle))
        answers["depth_5"][self.ids["second"]] = 3
        score = BENCH.grade(answers, self.oracle)
        self.assertFalse(score["passed"])
        self.assertEqual((score["checks"]["depth_5"]["fp"], score["checks"]["depth_5"]["fn"]), (1, 1))

    def test_native_query_checks_subject_depth_truncation_and_duplicates(self):
        request = BENCH.query_requests(self.oracle)[2]
        document = self.query_document()
        parsed = BENCH.parse_cg_query(document, request, self.graph)
        self.assertEqual(parsed["answer"], {self.ids["caller"]: 1, self.ids["second"]: 2})
        mutations = [
            lambda result: result.update(status="notFound"),
            lambda result: result.update(requested="other"),
            lambda result: result["result"]["subject"].update(usr="other"),
            lambda result: result["result"]["truncated"].update(usedBy=True),
            lambda result: result["result"]["truncated"].pop("members"),
            lambda result: result["result"]["usedBy"][0].update(depth=True),
            lambda result: result["result"]["usedBy"][0].update(depth=6),
            lambda result: result["result"]["usedBy"][0].update(edges=["reference"]),
            lambda result: result["result"]["usedBy"].append(result["result"]["usedBy"][0]),
            lambda result: result.update(limitations=["index-staleness: source changed"]),
        ]
        for mutation in mutations:
            changed = copy.deepcopy(document)
            mutation(changed["results"][0])
            with self.assertRaises(ValueError):
                BENCH.parse_cg_query(changed, request, self.graph)

    def test_unknown_native_neighbor_fails_exact_scoring(self):
        document = self.query_document()
        document["results"][0]["result"]["usedBy"].append({"usr": "unexpected", "depth": 1, "edges": ["call"]})
        answers = BENCH.baseline_queries(self.graph, BENCH.query_requests(self.oracle))
        answers["depth_5"] = BENCH.parse_cg_query(document, BENCH.query_requests(self.oracle)[2], self.graph)["answer"]
        self.assertFalse(BENCH.grade(answers, self.oracle)["passed"])

    def test_combined_native_workload_runs_one_max_depth_query(self):
        graph_path = self.project / "graph.json"
        BENCH.BASE.save(graph_path, self.graph)
        config = {
            "task": "cartograph-query",
            "project": str(self.project),
            "graph": str(graph_path),
            "graph_sha256": BENCH.BASE.sha256(graph_path),
            "requests": BENCH.query_requests(self.oracle),
            "out": str(self.project / "raw"),
            "cartograph": "native",
            "store": str(self.project / "store"),
            "cg_config": str(self.project / "config"),
            "timeout": 10,
        }
        with mock.patch.object(BENCH.BASE, "capture", return_value=(json.dumps(self.query_document()), {})) as capture:
            result = BENCH.execute_worker(config)
        self.assertEqual(capture.call_count, 1)
        command = capture.call_args.args[0]
        self.assertEqual(command[command.index("--depth") + 1], "5")
        self.assertEqual(result["native_invocations"], 1)
        self.assertTrue(BENCH.grade(result["answers"], self.oracle)["passed"])
        self.assertEqual(result["answers"]["depth_1"], {self.ids["caller"]: 1})

    def test_malformed_record_and_dangling_native_edge_fail(self):
        with self.assertRaises(ValueError):
            BENCH.parse_records(
                {self.relative: "Occurrences:\n  calledBy | dangling\n"}, self.project, self.allowed, self.oracle
            )
        changed = self.cg_document()
        changed["edges"][0]["source"] = "absent"
        with self.assertRaises(ValueError):
            BENCH.parse_cg_graph(changed, self.project, self.allowed, self.oracle)

    def test_source_universe_is_path_exact(self):
        self.assertIsNone(BENCH.source_identity(self.project, "Sources/Other/With Spaces.swift", 1, 6, self.allowed))
        self.assertIsNone(BENCH.source_identity(self.project, "../escape.swift", 1, 6, self.allowed))
        self.assertEqual(
            BENCH.source_identity(self.project, str(self.project / self.relative), 1, 6, self.allowed), self.ids["seed"]
        )

    def test_fresh_query_worker_measures_cached_bfs_without_native_dumps(self):
        graph_path = self.project / "graph.json"
        BENCH.BASE.save(graph_path, self.graph)
        config = {
            "task": "baseline-query",
            "project": str(self.project),
            "graph": str(graph_path),
            "graph_sha256": BENCH.BASE.sha256(graph_path),
            "requests": BENCH.query_requests(self.oracle),
        }
        result, measurement = BENCH.subprocess_worker(config, self.project / "worker", 20)
        self.assertTrue(BENCH.grade(result["answers"], self.oracle)["passed"])
        self.assertEqual(result["native_invocations"], 0)
        self.assertGreater(measurement["wait4_maxrss_bytes"], 0)
        self.assertGreaterEqual(measurement["workflow_seconds"], measurement["wall_seconds"])
        self.assertTrue(Path(measurement["stdout"]).is_file())
        graph_path.write_text("{}")
        with self.assertRaisesRegex(ValueError, "Frozen graph cache changed"):
            BENCH.execute_worker(config)

    def test_discovery_requires_all_manifest_sources_and_rejects_target_duplicates(self):
        store = self.project / "store"
        (store / "v5" / "units").mkdir(parents=True)
        (store / "v5" / "units" / "unit").write_text("")
        config = {
            "project": str(self.project),
            "store": str(store),
            "out": str(self.project / "raw"),
            "allowed": list(self.allowed),
            "oracle": self.oracle,
            "cli": "unused",
            "library": "unused",
            "timeout": 1,
        }
        with mock.patch.object(BENCH.BASE, "capture", return_value=("", {})):
            with self.assertRaisesRegex(ValueError, "source coverage mismatch"):
                BENCH.baseline_discovery(config)
        text = (
            f"Record | user | {self.project / self.relative} | one\n"
            f"Record | user | {self.project / self.relative} | two\n"
        )
        with mock.patch.object(BENCH.BASE, "capture", return_value=(text, {})):
            with self.assertRaisesRegex(ValueError, "Multiple compiler records"):
                BENCH.baseline_discovery(config)


class CommandContractTests(unittest.TestCase):
    def test_missing_setup_odd_pairs_and_nonempty_output_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "evidence").write_text("do not overwrite")
            for args in [
                [],
                ["--setup-results", "missing", "--output", str(root), "--repetitions", "3"],
                ["--setup-results", "missing", "--output", str(root)],
            ]:
                result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
            self.assertEqual((root / "evidence").read_text(), "do not overwrite")

    def test_baseline_only_failure_is_never_passed_and_keeps_error_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "output"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--baseline-only",
                    "--setup-results",
                    str(root / "missing.json"),
                    "--output",
                    str(root),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            report = BENCH.read_json(root / "results.json")
            self.assertEqual(report["status"], "blocked")
            self.assertIsNone(report["superiority_claim"])
            self.assertIn("error", report)
            self.assertTrue((root / "setup" / "preregistration.json").is_file())
            self.assertEqual(
                BENCH.BASE.sha256(root / "setup" / "frozen-source-evidence" / "oracle.json"),
                BENCH.FROZEN_HASHES["oracle.json"],
            )

    def test_changed_setup_binary_fails_before_running_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "index-dump"
            binary.write_text("original")
            setup = {
                "status": "baseline_only",
                "revision": BENCH.BASE.REVISION,
                "comparator_setup": {
                    "revision": BENCH.BASE.REVISION,
                    "binary": str(binary),
                    "binary_sha256": BENCH.BASE.sha256(binary),
                },
                "toolchain": {"library": str(binary), "library_sha256": BENCH.BASE.sha256(binary)},
            }
            path = root / "setup.json"
            BENCH.BASE.save(path, setup)
            binary.write_text("replaced")
            with self.assertRaisesRegex(ValueError, "Reused cli missing or changed"):
                BENCH.reuse_tools(path, True, root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
