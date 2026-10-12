"""새 설정 배치와 명시적 자기 호출 보존 모드를 먼저 회귀 계약으로 고정한다."""

from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mixed_adapter as adapter
import observe_mixed as hook


class CatalogPublication(unittest.TestCase):
    def test_declaration_lexemes_use_explicit_diagnostic_key_without_mutating_binding_catalog(self):
        catalog = [{"token": "CGBase", "definition": True, "anchor": "Core.m:1:5"}]
        self.assertEqual(
            hook.catalog_evidence(catalog),
            [{"declaration_lexeme": "CGBase", "definition": True, "anchor": "Core.m:1:5"}],
        )
        self.assertEqual(catalog[0]["token"], "CGBase")
        with self.assertRaisesRegex(ValueError, "collision"):
            hook.catalog_evidence([{"token": "CGBase", "declaration_lexeme": "different"}])


class SetupLayouts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_legacy_setup_layout(self):
        path = self.root / "setup.json"
        path.write_text("{}")
        self.assertEqual(hook.setup_path_for(self.root), path)
        self.assertEqual(hook.find_run_root(self.root / "runs/initial/state.json"), self.root)

    def test_integrated_setup_layout(self):
        path = self.root / "setup/setup.json"
        path.parent.mkdir()
        path.write_text("{}")
        self.assertEqual(hook.setup_path_for(self.root), path)
        self.assertEqual(hook.find_run_root(self.root / "runs/initial/state.json"), self.root)

    def test_new_layout_with_arbitrary_state_parent(self):
        path = self.root / "setup/setup.json"
        path.parent.mkdir()
        path.write_text("{}")
        self.assertEqual(hook.find_run_root(self.root / "observations/header-edited/state.json"), self.root)

    def test_conflicting_setup_layouts_are_not_silently_selected(self):
        (self.root / "setup").mkdir()
        (self.root / "setup.json").write_text('{"library_sha256":"old"}')
        (self.root / "setup/setup.json").write_text('{"library_sha256":"new"}')
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            hook.setup_path_for(self.root)
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            hook.find_run_root(self.root / "runs/initial/state.json")

    def test_explicit_root_missing_setup_fails(self):
        with self.assertRaisesRegex(ValueError, "setup"):
            hook.setup_path_for(self.root)


class NativeGraphMode(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.project = self.root / "Project"
        (self.project / "Sources").mkdir(parents=True)
        (self.project / "Sources/Core.m").write_text("int recurse(int value) { return recurse(value); }\n")
        self.catalog = adapter.source_catalog(self.project, {"Sources/Core.m": ["BridgeKit"]})
        self.identity = "BridgeKit::Sources/Core.m:1:5"
        self.requests = [dict(id="q01", seed=self.identity, max_depth=8)]
        self.default_graph = dict(
            level="symbol",
            nodes=[
                dict(
                    id="r",
                    usr="c:recurse",
                    name="recurse",
                    kind="function",
                    location=dict(path="Sources/Core.m", line=1, column=5),
                )
            ],
            edges=[],
        )
        self.complete_graph = {**self.default_graph, "edges": [dict(source="r", target="r", kind="call")]}
        self.batch = dict(
            format="symbol-query-batch",
            version=1,
            results=[
                dict(
                    requested="c:recurse",
                    status="found",
                    level="symbol",
                    limitations=[],
                    result=dict(
                        subject=dict(usr="c:recurse"),
                        usedBy=[],
                        truncated=dict(usedBy=False, dependsOn=False, members=False),
                    ),
                )
            ],
        )
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def capture(self, command, cwd, stem):
        self.calls.append(command)
        if command[1] == "query":
            return json.dumps(self.batch)
        return json.dumps(self.complete_graph if "--include-self-loops" in command else self.default_graph)

    def test_default_graph_mode_keeps_existing_command(self):
        with patch.object(hook, "capture", side_effect=self.capture):
            hook.native_observations(
                Path("/cartograph"),
                self.project,
                self.root / "Store",
                self.catalog,
                self.requests,
                self.root / "default",
                graph_mode="default",
            )
        self.assertEqual(len([c for c in self.calls if c[1] == "graph"]), 1)
        self.assertTrue(all("--include-self-loops" not in c for c in self.calls))

    def test_compatible_mode_retains_default_and_requests_symbol_self_loops(self):
        out = self.root / "complete"
        with patch.object(hook, "capture", side_effect=self.capture):
            result = hook.native_observations(
                Path("/cartograph"),
                self.project,
                self.root / "Store",
                self.catalog,
                self.requests,
                out,
                graph_mode="include-self-loops",
            )
        graph_commands = [c for c in self.calls if c[1] == "graph"]
        self.assertEqual(len(graph_commands), 2)
        self.assertNotIn("--include-self-loops", graph_commands[0])
        self.assertIn("--include-self-loops", graph_commands[1])
        self.assertEqual(graph_commands[1][graph_commands[1].index("--level") + 1], "symbol")
        self.assertEqual(json.loads((out / "normalized-default-graph.json").read_text())["edges"], [])
        self.assertEqual(
            json.loads((out / "normalized-graph.json").read_text())["edges"], [[self.identity, self.identity]]
        )
        self.assertEqual(result["graph"]["queries"][0]["direct"], [])
        self.assertEqual(result["graph"]["queries"][0]["transitive"], [])
        self.assertEqual(result["query"]["queries"][0]["direct"], [])
        self.assertNotIn("--include-self-loops", [c for c in self.calls if c[1] == "query"][0])

    def test_default_and_compatible_graph_scores_remain_separate(self):
        out = self.root / "scores"
        with patch.object(hook, "capture", side_effect=self.capture):
            hook.native_observations(
                Path("/cartograph"),
                self.project,
                self.root / "Store",
                self.catalog,
                self.requests,
                out,
                graph_mode="include-self-loops",
            )
        oracle = self.root / "recursive-oracle.json"
        hook.save(
            oracle,
            {
                "variants": {
                    "initial": {
                        "nodes": [{"key": "recursive", "id": self.identity}],
                        "edges": [{"caller": "recursive", "callee": "recursive"}],
                    }
                }
            },
        )
        default_graph = json.loads((out / "normalized-default-graph.json").read_text())
        selected_graph = json.loads((out / "normalized-graph.json").read_text())
        default_score = hook.grade_graph(default_graph, oracle, "initial")
        selected_score = hook.grade_graph(selected_graph, oracle, "initial")
        self.assertEqual(default_score["status"], "failed")
        self.assertEqual(default_score["false_negative"], [[self.identity, self.identity]])
        self.assertEqual(selected_score["status"], "passed")

    def test_unsupported_binary_is_not_retried_without_flag(self):
        def unsupported(command, cwd, stem):
            self.calls.append(command)
            if "--include-self-loops" in command:
                raise ValueError("unsupported --include-self-loops")
            return json.dumps(self.default_graph)

        out = self.root / "unsupported"
        with patch.object(hook, "capture", side_effect=unsupported):
            with self.assertRaisesRegex(ValueError, "unsupported"):
                hook.native_observations(
                    Path("/cartograph"),
                    self.project,
                    self.root / "Store",
                    self.catalog,
                    self.requests,
                    out,
                    graph_mode="include-self-loops",
                )
        self.assertEqual(len(self.calls), 2)
        self.assertIn("--include-self-loops", self.calls[-1])
        self.assertTrue((out / "normalized-default-graph.json").is_file())

    def test_unknown_mode_fails_before_running_binary(self):
        with patch.object(hook, "capture", side_effect=self.capture):
            with self.assertRaises(ValueError):
                hook.native_observations(
                    Path("/cartograph"),
                    self.project,
                    self.root / "Store",
                    self.catalog,
                    self.requests,
                    self.root / "unknown",
                    graph_mode="automatic-fallback",
                )
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
