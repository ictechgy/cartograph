#!/usr/bin/env python3
"""제품 실측과 구분하여 채점·정규화·측정 범위의 회귀를 오프라인으로 검증한다."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("benchmark-indexstore-cli.py")
SPEC = importlib.util.spec_from_file_location("indexstore_benchmark", SCRIPT)
assert SPEC and SPEC.loader
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)
FIXTURES = SCRIPT.parents[1] / "Fixtures" / "IndexStoreCLIBenchmark"


class OracleTests(unittest.TestCase):
    def test_caller_batch_builds_reverse_adjacency_once(self):
        edges = {("a", "b"), ("b", "c")}
        with mock.patch.object(BENCH, "reverse_adjacency", wraps=BENCH.reverse_adjacency) as adjacency:
            result = BENCH.caller_answers(edges, ["a", "b", "c", "missing"])
        self.assertEqual(adjacency.call_count, 1)
        self.assertEqual(result["callers"]["c"], {"direct": ["b"], "transitive": ["a", "b"]})
        self.assertEqual(result["callers"]["missing"], {"direct": [], "transitive": []})

    def test_source_oracles_are_explicit_and_internally_consistent(self):
        for name in ("basic", "holdout"):
            with self.subTest(name=name):
                oracle = json.loads((FIXTURES / name / "oracle.json").read_text())
                edges = {tuple(edge) for edge in oracle["edges"]}
                self.assertEqual(len(edges), len(oracle["edges"]))
                answers = BENCH.graph_answers(edges, oracle["targets"])
                self.assertTrue(BENCH.grade(answers, oracle)["passed"])
                mutated = copy.deepcopy(oracle)
                mutated["edges"] = [edge for edge in oracle["edges"] if edge not in oracle["edit"]["remove_edges"]]
                mutated["expected_callers"] = oracle["edit"]["expected_callers"]
                self.assertFalse(BENCH.grade(answers, mutated)["passed"])
                self.assertTrue(
                    BENCH.grade(
                        BENCH.graph_answers({tuple(edge) for edge in mutated["edges"]}, mutated["targets"]), mutated
                    )["passed"]
                )

    def test_false_positive_and_false_negative_fail(self):
        measured = BENCH.score(["expected", "unexpected"], ["expected", "missing"])
        self.assertFalse(measured["exact_match"])
        self.assertEqual((measured["tp"], measured["fp"], measured["fn"]), (1, 1, 1))
        self.assertEqual(measured["precision"], 0.5)
        self.assertEqual(measured["recall"], 0.5)

    def test_empty_set_metrics_are_not_invented(self):
        empty = BENCH.score([], [])
        self.assertTrue(empty["exact_match"])
        self.assertIsNone(empty["precision"])
        self.assertIsNone(empty["recall"])
        self.assertFalse(BENCH.score(["unexpected"], [])["exact_match"])

    def test_cyclic_traversal_terminates_and_excludes_seed(self):
        edges = {("a", "b"), ("b", "a"), ("c", "b"), ("lonely", "lonely")}
        self.assertEqual(BENCH.reverse_callers(edges, "a"), {"direct": ["b"], "transitive": ["b", "c"]})
        self.assertEqual(BENCH.components(edges), [["a", "b"], ["lonely"]])


class ParsingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.project = Path(self.temporary.name)
        (self.project / "Sources").mkdir()
        for path in (FIXTURES / "basic").glob("*.swift"):
            shutil.copy2(path, self.project / "Sources" / path.name)
        self.oracle = json.loads((FIXTURES / "basic" / "oracle.json").read_text())
        self.selectors = BENCH.selectors(self.project)
        self.symbols = {label: f"usr:{label}" for label in self.selectors}
        self.graph = {
            "level": "symbol",
            "nodes": [
                {
                    "id": usr,
                    "usr": usr,
                    "name": self.selectors[label]["name"] + "()",
                    "location": {key: self.selectors[label][key] for key in ("path", "line", "column")},
                }
                for label, usr in self.symbols.items()
            ],
            "edges": [
                {"source": self.symbols[a], "target": self.symbols[b], "kind": "call"} for a, b in self.oracle["edges"]
            ],
        }
        self.batch = {"format": "symbol-query-batch", "version": 1, "results": []}
        for target in self.oracle["targets"]:
            expected = self.oracle["expected_callers"][target]
            self.batch["results"].append(
                {
                    "status": "found",
                    "level": "symbol",
                    "requested": self.symbols[target],
                    "limitations": [],
                    "result": {
                        "subject": {"usr": self.symbols[target]},
                        "truncated": {"usedBy": False, "dependsOn": False, "members": False},
                        "usedBy": [
                            {
                                "usr": self.symbols[label],
                                "depth": 1 if label in expected["direct"] else 2,
                                "edges": ["call"],
                            }
                            for label in expected["transitive"]
                        ],
                    },
                }
            )

    def tearDown(self):
        self.temporary.cleanup()

    def test_native_graph_uses_independent_source_locations(self):
        parsed = BENCH.parse_cartograph_graph(self.graph, self.project, self.oracle["targets"])
        self.assertTrue(BENCH.grade(parsed["answers"], self.oracle)["passed"])
        self.assertEqual(parsed["symbol_ids"], self.symbols)

    def test_extra_graph_edges_are_not_filtered_out(self):
        self.graph["edges"].append(
            {"source": self.symbols["disconnected"], "target": self.symbols["leaf_int"], "kind": "call"}
        )
        parsed = BENCH.parse_cartograph_graph(self.graph, self.project, self.oracle["targets"])
        grade = BENCH.grade(parsed["answers"], self.oracle)
        self.assertFalse(grade["passed"])
        self.assertEqual(grade["checks"]["edges"]["fp"], 1)

    def test_missing_declaration_fails_closed(self):
        self.graph["nodes"] = self.graph["nodes"][1:]
        with self.assertRaises(ValueError):
            BENCH.parse_cartograph_graph(self.graph, self.project, self.oracle["targets"])

    def test_native_batch_direct_and_transitive_agree(self):
        parsed = BENCH.parse_cartograph_batch(self.batch, self.oracle["targets"], self.symbols)
        self.assertTrue(BENCH.grade(parsed, self.oracle, False)["passed"])

    def test_truncation_not_found_and_reordering_fail_closed(self):
        mutations = [
            lambda doc: doc["results"][0]["result"]["truncated"].update(usedBy=True),
            lambda doc: doc["results"][0].update(status="notFound"),
            lambda doc: doc["results"].reverse(),
        ]
        for mutation in mutations:
            changed = copy.deepcopy(self.batch)
            mutation(changed)
            with self.assertRaises(ValueError):
                BENCH.parse_cartograph_batch(changed, self.oracle["targets"], self.symbols)

    def test_missing_empty_answer_fields_are_not_silently_accepted(self):
        for field in ("usedBy", "truncated"):
            changed = copy.deepcopy(self.batch)
            del changed["results"][1]["result"][field]
            with self.assertRaises(ValueError):
                BENCH.parse_cartograph_batch(changed, self.oracle["targets"], self.symbols)

    def test_timed_baseline_omits_scc_and_source_selector_resolution(self):
        store = self.project / "store"
        (store / "v5" / "units").mkdir(parents=True)
        (store / "v5" / "units" / "unit-1").write_text("unit bytes")
        source = self.project / "Sources" / "Calls.swift"
        unit = f"Record | user | {source} | record-1\n"
        record = (
            "Symbols:\n"
            + "\n".join(f"{label} | function | {usr} | definition" for label, usr in self.symbols.items())
            + "\nOccurrences:\n"
            + "\n".join(
                f"1:1 | callee | function | {self.symbols[callee]} | reference, call\n"
                f"  calledBy | {self.symbols[caller]}"
                for caller, callee in self.oracle["edges"]
            )
        )

        def recorded_cli(command, *args, **kwargs):
            return ({"unit-1": unit, "record-1": record}[command[1]], {"wall_seconds": 0.001})

        with (
            mock.patch.object(BENCH, "capture", side_effect=recorded_cli),
            mock.patch.object(BENCH, "selectors", side_effect=AssertionError("Selector work leaked into query")),
            mock.patch.object(BENCH, "components", side_effect=AssertionError("SCC work leaked into query")),
            mock.patch.object(BENCH, "graph_answers", side_effect=AssertionError("Graph task leaked into query")),
        ):
            result = BENCH.baseline_graph(
                Path("index-dump"),
                Path("libIndexStore"),
                self.project,
                store,
                self.oracle["targets"],
                self.project / "raw",
                task="callers",
                symbol_ids=self.symbols,
            )
        self.assertEqual(result["task"], "callers")
        self.assertEqual(set(result["answers"]), {"callers"})
        self.assertTrue(BENCH.grade(result["answers"], self.oracle, False)["passed"])

    def test_caller_only_baseline_rejects_missing_discovery(self):
        with self.assertRaisesRegex(ValueError, "previously resolved"):
            BENCH.baseline_graph(
                Path("index-dump"),
                Path("library"),
                self.project,
                self.project,
                self.oracle["targets"],
                self.project / "raw",
                task="callers",
            )

    def test_unknown_native_neighbor_remains_a_false_positive(self):
        self.batch["results"][1]["result"]["usedBy"].append({"usr": "unexpected", "depth": 1, "edges": ["call"]})
        parsed = BENCH.parse_cartograph_batch(self.batch, self.oracle["targets"], self.symbols)
        self.assertFalse(BENCH.grade(parsed, self.oracle, False)["passed"])


class CheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        subprocess.run(["git", "init", "--quiet"], cwd=self.checkout, check=True)
        (self.checkout / "Sources").mkdir()
        (self.checkout / "Sources" / "Base.swift").write_text("func base() {}\n")
        subprocess.run(["git", "add", "Sources/Base.swift"], cwd=self.checkout, check=True)

    def tearDown(self):
        self.temporary.cleanup()

    def test_untracked_source_is_rejected(self):
        (self.checkout / "Sources" / "Injected.swift").write_text("func injected() {}\n")
        with self.assertRaisesRegex(ValueError, "Injected.swift"):
            BENCH.verify_untracked_build_inputs(self.checkout, self.root / "evidence")

    def test_ignored_source_is_also_rejected(self):
        (self.checkout / ".gitignore").write_text("Sources/*.generated.swift\n")
        (self.checkout / "Sources" / "Hidden.generated.swift").write_text("func hidden() {}\n")
        with self.assertRaisesRegex(ValueError, "Hidden.generated.swift"):
            BENCH.verify_untracked_build_inputs(self.checkout, self.root / "evidence")

    def test_alternate_package_manifest_is_rejected(self):
        (self.checkout / "Package@swift-6.4.swift").write_text("// 주입된 매니페스트\n")
        with self.assertRaisesRegex(ValueError, "Package@swift-6.4.swift"):
            BENCH.verify_untracked_build_inputs(self.checkout, self.root / "evidence")

    def test_unrelated_research_output_is_allowed(self):
        (self.checkout / ".research").mkdir()
        (self.checkout / ".research" / "note.swift").write_text("not a package target\n")
        self.assertTrue(BENCH.verify_untracked_build_inputs(self.checkout, self.root / "evidence")["passed"])


class CompilerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.project = self.root / "fixture"
        (self.project / "Sources").mkdir(parents=True)
        (self.project / "Sources" / "Entry.swift").write_text("@main struct Entry { static func main() {} }\n")
        self.sdk = self.root / "SDK With Spaces.sdk"
        self.sdk.mkdir()
        self.oracle = {"module": "Fixture", "runtime_stdout": "expected\n"}

    def tearDown(self):
        self.temporary.cleanup()

    def compile(self):
        return BENCH.compile_fixture(
            Path("/toolchain/swiftc"), self.project, self.project / "index", self.oracle, self.root / "run", 30
        )

    def test_macos_compiler_receives_explicit_sdk_with_measured_discovery(self):
        with (
            mock.patch.object(BENCH.sys, "platform", "darwin"),
            mock.patch.object(
                BENCH,
                "capture",
                side_effect=[
                    (str(self.sdk) + "\n", {"wall_seconds": 0.1}),
                    ("26.4\n", {"wall_seconds": 0.2}),
                    ("expected\n", {"wall_seconds": 0.3}),
                ],
            ) as capture,
            mock.patch.object(BENCH, "run", return_value={"wall_seconds": 1.0}) as run,
        ):
            result = self.compile()
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("-sdk") + 1], str(self.sdk))
        self.assertEqual(capture.call_args_list[0].args[0], ["xcrun", "--sdk", "macosx", "--show-sdk-path"])
        self.assertEqual(capture.call_args_list[1].args[0], ["xcrun", "--sdk", "macosx", "--show-sdk-version"])
        self.assertEqual(result["sdk"]["path"], str(self.sdk))
        self.assertEqual(result["sdk"]["version"], "26.4")
        self.assertEqual(result["sdk"]["path_discovery"]["wall_seconds"], 0.1)
        self.assertEqual(result["sdk"]["version_discovery"]["wall_seconds"], 0.2)
        self.assertTrue(result["runtime_oracle_passed"])

    def test_macos_missing_sdk_fails_before_compile(self):
        with (
            mock.patch.object(BENCH.sys, "platform", "darwin"),
            mock.patch.object(BENCH, "capture", return_value=(str(self.sdk / "missing"), {})),
            mock.patch.object(BENCH, "run") as run,
            self.assertRaisesRegex(ValueError, "macOS SDK directory"),
        ):
            self.compile()
        run.assert_not_called()

    def test_linux_keeps_sdk_free_compile_and_runtime_oracle(self):
        with (
            mock.patch.object(BENCH.sys, "platform", "linux"),
            mock.patch.object(BENCH, "capture", return_value=("expected\n", {})) as capture,
            mock.patch.object(BENCH, "run", return_value={}) as run,
        ):
            result = self.compile()
        self.assertNotIn("-sdk", run.call_args.args[0])
        self.assertEqual(capture.call_count, 1)
        self.assertIsNone(result["sdk"])
        self.assertTrue(result["runtime_oracle_passed"])


class ProcessTests(unittest.TestCase):
    def test_commands_and_raw_output_are_persisted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = BENCH.run([sys.executable, "-c", "print('raw-output')"], root, root / "child")
            self.assertEqual(Path(result["stdout"]).read_text(), "raw-output\n")
            self.assertGreater(result["wait4_maxrss_bytes"], 0)
            self.assertEqual(json.loads((root / "child.json").read_text())["returncode"], 0)

    def test_timeout_fails_and_preserves_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(RuntimeError):
                BENCH.run([sys.executable, "-c", "import time; time.sleep(30)"], root, root / "timeout", 0.05)
            evidence = json.loads((root / "timeout.json").read_text())
            self.assertTrue(evidence["timed_out"])
            self.assertEqual(evidence["returncode"], 124)
            self.assertTrue(Path(evidence["stdout"]).exists())

    def test_index_fingerprint_ignores_directory_timestamp(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "record"
            path.write_text("before")
            first, timestamp = BENCH.fingerprint(root), path.stat().st_mtime
            path.write_text("after!")
            os.utime(path, (timestamp, timestamp))
            self.assertNotEqual(first, BENCH.fingerprint(root))


if __name__ == "__main__":
    unittest.main(verbosity=2)
