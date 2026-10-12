"""실제 CLI 형식, 소스 식별자, 활성 빌드 경계를 먼저 고정한다."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mixed_adapter as adapter


def unit(name="unit", output="/build/current.o", main="/project/Sources/Core.m", module="", deps=""):
    return adapter.parse_unit(
        name,
        f"""Module: {module}
Has Main File: true
Main File: {main}
Output File: {output}
Target: x86_64-unknown-linux-gnu
Sysroot: /
Working Directory: /project
Is System: false
Is Module: false
Is Debug: true
Provider Identifier: {'swift' if module else 'clang'}
Provider Version: 6.4
Modification Date: 2026-10-12 00:00:00 +0000
Dependencies:
{deps}
""",
    )


def record(body, symbols=""):
    return adapter.parse_record("Symbols:\n" + symbols + "\nOccurrences:\n" + body)


class ParserContracts(unittest.TestCase):
    def test_dependency_types_and_optional_module(self):
        value = unit(
            deps="Record | user | FeatureAlpha | /project/Sources/Shared.swift | shared-record\n"
            "File | user | /project/Sources/Header.h\n"
            "Unit | system | Swift | /sdk/Swift.swiftmodule | swift-unit"
        )
        self.assertEqual([v["kind"] for v in value["dependencies"]], ["Record", "File", "Unit"])
        self.assertEqual(value["dependencies"][0]["module"], "FeatureAlpha")
        self.assertEqual(value["dependencies"][1]["name"], None)

    def test_unit_rejects_lossy_or_unknown_metadata(self):
        with self.assertRaises(ValueError):
            adapter.parse_unit("bad", "Module: A\nDependencies:\n")
        with self.assertRaises(ValueError):
            unit(deps="Unknown | user | /file | name")

    def test_only_called_by_builds_edges(self):
        parsed = record(
            "3:4 | callee | function | c:callee | definition, call\n"
            "  receivedBy | c:receiver\n  calledBy, containedBy | c:caller\n"
        )
        self.assertEqual(adapter.record_edges(parsed), {("c:caller", "c:callee")})

    def test_roles_are_not_declaration_evidence(self):
        parsed = record("9:4 | callee | function | c:callee | definition, call\n")
        self.assertEqual(parsed["occurrences"][0]["line"], 9)
        self.assertNotIn("is_declaration", parsed["occurrences"][0])

    def test_orphan_relation_and_malformed_occurrence_rejected(self):
        for body in ["  calledBy | c:caller\n", "zero:2 | f | function | c:f | definition\n"]:
            with self.assertRaises(ValueError):
                record(body)

    def test_current_output_selection_excludes_old_unit_and_record(self):
        units = {
            "current": unit("current", deps="Record | user | /project/Sources/Core.m | now"),
            "orphan": unit("orphan", output="/build/deleted.o", deps="Record | user | /project/Sources/Gone.m | old"),
        }
        expected = [
            {
                "output": "/build/current.o",
                "source": "/project/Sources/Core.m",
                "module": "",
                "provider": "clang",
                "target": "x86_64-unknown-linux-gnu",
                "sysroot": None,
            }
        ]
        selected = adapter.select_units(units, expected)
        self.assertEqual(selected["roots"], ["current"])
        self.assertEqual(selected["excluded_units"], ["orphan"])
        self.assertEqual([v["name"] for v in selected["records"]], ["now"])

    def test_parent_context_is_preserved_for_shared_record(self):
        units = {
            "a": unit(
                "a",
                "/build/a.o",
                "/project/Sources/Shared.swift",
                "A",
                "Record | user | A | /project/Sources/Shared.swift | shared",
            ),
            "b": unit(
                "b",
                "/build/b.o",
                "/project/Sources/Shared.swift",
                "B",
                "Record | user | B | /project/Sources/Shared.swift | shared",
            ),
        }
        expected = [
            {
                "output": f"/build/{key}.o",
                "source": "/project/Sources/Shared.swift",
                "module": key.upper(),
                "provider": "swift",
                "target": "x86_64-unknown-linux-gnu",
                "sysroot": None,
            }
            for key in ["a", "b"]
        ]
        selected = adapter.select_units(units, expected)
        self.assertEqual({(r["unit"], r["module"]) for r in selected["records"]}, {("a", "A"), ("b", "B")})

    def test_duplicate_current_output_fails_closed(self):
        expected = [
            {
                "output": "/build/current.o",
                "source": "/project/Sources/Core.m",
                "module": "",
                "provider": "clang",
                "target": "x86_64-unknown-linux-gnu",
                "sysroot": None,
            }
        ]
        with self.assertRaises(ValueError):
            adapter.select_units({"a": unit("a"), "b": unit("b")}, expected)

    def test_missing_unit_dependency_fails_closed(self):
        expected = [
            {
                "output": "/build/current.o",
                "source": "/project/Sources/Core.m",
                "module": "",
                "provider": "clang",
                "target": "x86_64-unknown-linux-gnu",
                "sysroot": None,
            }
        ]
        with self.assertRaises(ValueError):
            adapter.select_units({"a": unit("a", deps="Unit | user | M | /build/M.swiftmodule | absent")}, expected)

    def test_minimum_depth_cycle_and_short_path(self):
        edges = [("a", "seed"), ("b", "a"), ("b", "seed"), ("seed", "b"), ("c", "b")]
        self.assertEqual(adapter.reverse_depths(edges, "seed", 8), {"a": 1, "b": 1, "c": 2})


class SourceContracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.project = Path(self.tmp.name)
        (self.project / "Sources").mkdir()
        (self.project / "Sources/Core.m").write_text(
            "int base(int x) { return x; }\nint caller(int x) { return base(x); }\n"
        )
        (self.project / "Sources/API.h").write_text("int base(int x);\n")
        (self.project / "Sources/Shared.swift").write_text(
            "public func quote(_ value: Int32) -> Int32 { return value }\n"
        )
        self.contexts = {
            "Sources/Core.m": ["BridgeKit"],
            "Sources/API.h": ["BridgeKit"],
            "Sources/Shared.swift": ["FeatureAlpha", "FeatureBeta"],
        }
        self.catalog = adapter.source_catalog(self.project, self.contexts)

    def tearDown(self):
        self.tmp.cleanup()

    def test_shared_source_has_two_context_identities(self):
        ids = {d["id"] for d in self.catalog if d["path"].endswith(".swift")}
        self.assertEqual(ids, {"FeatureAlpha::Sources/Shared.swift:1:13", "FeatureBeta::Sources/Shared.swift:1:13"})

    def test_aliases_join_by_compiler_identity_not_name(self):
        sightings = [
            ("c:base", "BridgeKit::Sources/Core.m:1:5"),
            ("c:base", "BridgeKit::Sources/API.h:1:5"),
            ("c:caller", "BridgeKit::Sources/Core.m:2:5"),
        ]
        graph = adapter.bind_graph(self.catalog, sightings, {("c:caller", "c:base")}, {"c:base", "c:caller"})
        self.assertEqual(graph["symbols"]["c:base"], "BridgeKit::Sources/Core.m:1:5")
        self.assertEqual(graph["aliases"]["c:base"], ["BridgeKit::Sources/API.h:1:5"])

    def test_unknown_in_universe_call_does_not_disappear(self):
        graph = adapter.bind_graph(
            self.catalog,
            [("c:base", "BridgeKit::Sources/Core.m:1:5")],
            {("c:unmapped", "c:base")},
            {"c:base", "c:unmapped"},
        )
        self.assertIn(["unmapped:c:unmapped", "BridgeKit::Sources/Core.m:1:5"], graph["edges"])
        self.assertTrue(graph["unresolved"])

    def test_unknown_call_target_does_not_disappear(self):
        graph = adapter.bind_graph(
            self.catalog,
            [("c:base", "BridgeKit::Sources/Core.m:1:5")],
            {("c:base", "c:unknown")},
            {"c:base", "c:unknown"},
        )
        self.assertTrue(graph["unresolved"])
        self.assertIn(["BridgeKit::Sources/Core.m:1:5", "unmapped:c:unknown"], graph["edges"])

    def test_unknown_unused_definition_does_not_disappear(self):
        graph = adapter.bind_graph(self.catalog, [], set(), {"c:unusedUnrecognized"})
        self.assertIn("Unbound in-universe callable compiler identity: c:unusedUnrecognized", graph["unresolved"])

    def test_ambiguous_usr_definition_rejected(self):
        with self.assertRaises(ValueError):
            adapter.bind_graph(
                self.catalog,
                [
                    ("same", "FeatureAlpha::Sources/Shared.swift:1:13"),
                    ("same", "FeatureBeta::Sources/Shared.swift:1:13"),
                ],
                set(),
                {"same"},
            )

    def test_cartograph_requires_module_for_shared_source(self):
        document = {
            "level": "symbol",
            "nodes": [
                {
                    "id": "a",
                    "usr": "s:a",
                    "name": "quote(_:)",
                    "kind": "function",
                    "location": {"path": "Sources/Shared.swift", "line": 1, "column": 13},
                }
            ],
            "edges": [],
        }
        with self.assertRaises(ValueError):
            adapter.cartograph_graph(document, self.project, self.catalog)
        document["nodes"][0]["module"] = "FeatureAlpha"
        parsed = adapter.cartograph_graph(document, self.project, self.catalog)
        self.assertEqual(parsed["symbols"]["s:a"], "FeatureAlpha::Sources/Shared.swift:1:13")

    def test_native_query_unknown_caller_is_retained(self):
        graph = adapter.bind_graph(self.catalog, [("c:base", "BridgeKit::Sources/Core.m:1:5")], set(), {"c:base"})
        request = {"id": "q01", "seed": "BridgeKit::Sources/Core.m:1:5", "max_depth": 8}
        document = {
            "format": "symbol-query-batch",
            "version": 1,
            "results": [
                {
                    "requested": "c:base",
                    "status": "found",
                    "level": "symbol",
                    "limitations": [],
                    "result": {
                        "subject": {"usr": "c:base"},
                        "truncated": {"usedBy": False, "dependsOn": False, "members": False},
                        "usedBy": [{"usr": "c:unknown", "depth": 1, "edges": ["call"]}],
                    },
                }
            ],
        }
        result = adapter.cartograph_batch(document, [request], graph)
        self.assertFalse(result["complete"])
        self.assertEqual(result["queries"][0]["direct"], ["unmapped:c:unknown"])


if __name__ == "__main__":
    unittest.main()
