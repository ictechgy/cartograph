"""빌드/신선도/점수 경계의 실패 경로를 고정한다."""

from pathlib import Path
import json
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mixed_adapter as adapter
import observe_mixed as hook
from test_contracts import unit


class HookContracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.project = self.root / "Project"
        (self.project / "Sources").mkdir(parents=True)
        (self.project / "Sources/Core.m").write_text("int f(int x) { return x; }\n")
        (self.project / "Sources/API.h").write_text("int f(int x);\n")
        self.source = self.project / "Sources/Core.m"
        self.obj = self.root / "Core.o"
        self.obj.write_bytes(b"object")
        self.dep = self.root / "Core.d"
        self.dep.write_text(f'{self.obj}: {self.source} \\\n {self.project / "Sources/API.h"}\n')
        argv = [
            "clang",
            "-target",
            "x86_64-unknown-linux-gnu",
            "-MF",
            str(self.dep),
            "-c",
            str(self.source),
            "-o",
            str(self.obj),
        ]
        self.command = dict(args=argv, source_paths=[str(self.source)], outputs=[str(self.obj)])
        self.state = dict(
            project=str(self.project),
            triple="x86_64-unknown-linux-gnu",
            current_sources=hook.source_manifest(self.project),
            active_object_outputs=[str(self.obj)],
            builds=[dict(command=argv, exit_code=0)],
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_compiler_manifest_preserves_header_dependency(self):
        expected, contexts = hook.compile_manifest([self.command], self.state, {})
        self.assertEqual(expected[0]["project_headers"], [str((self.project / "Sources/API.h").resolve())])
        self.assertEqual(contexts["Sources/Core.m"], ["BridgeKit"])

    def test_swift_module_artifact_requires_pre_observation_build_seal(self):
        source = (self.project / "Sources/Shared.swift").resolve()
        source.write_text("public func leaf() {}\n")
        module = (self.root / "FeatureAlpha.swiftmodule").resolve()
        module.write_bytes(b"accepted module")
        sdk = str((self.root / "SDK").resolve())
        argv = [
            "swiftc",
            "-module-name",
            "FeatureAlpha",
            "-target",
            self.state["triple"],
            "-sdk",
            sdk,
            "-emit-module-path",
            str(module),
        ]
        command = dict(args=argv, source_paths=[str(source)], outputs=[str(self.obj)])
        record = dict(
            path=str(module),
            sha256=hook.digest(module),
            module="FeatureAlpha",
            provider="swift",
            target=self.state["triple"],
            sysroot=sdk,
            sources=[str(source.resolve())],
            outputs=[str(self.obj.resolve())],
        )
        state = {
            **self.state,
            "current_sources": hook.source_manifest(self.project),
            "builds": [dict(command=argv, exit_code=0)],
            "module_artifacts": {str(module): record},
        }
        expected, _ = hook.compile_manifest([command], state, {"sdk_path": sdk})
        self.assertEqual(expected[0]["module_artifact"], record)
        for artifacts in [
            {},
            {str(module): {**record, "sha256": "0" * 64}},
            {str(module): record, str(module) + ".extra": record},
        ]:
            with self.subTest(artifacts=artifacts), self.assertRaises(ValueError):
                hook.compile_manifest([command], {**state, "module_artifacts": artifacts}, {"sdk_path": sdk})
        module.write_bytes(b"replaced module")
        with self.assertRaises(ValueError):
            hook.compile_manifest([command], state, {"sdk_path": sdk})

    def test_input_guard_rechecks_accepted_module_bytes(self):
        module = self.root / "M.swiftmodule"
        module.write_bytes(b"before")
        store = self.root / "Store"
        store.mkdir()
        library, cli = self.root / "library", self.root / "cli"
        library.write_bytes(b"library")
        cli.write_bytes(b"cli")
        state = {
            **self.state,
            "store": str(store),
            "index_files": {},
            "module_artifacts": {str(module): dict(path=str(module), sha256=hook.digest(module))},
        }
        hook.input_guard(state, library, hook.digest(library), cli, hook.digest(cli))
        module.write_bytes(b"after")
        with self.assertRaisesRegex(ValueError, "module artifact"):
            hook.input_guard(state, library, hook.digest(library), cli, hook.digest(cli))

    def test_compiler_header_manifest_accepts_project_alias(self):
        alias = self.root / "project-alias"
        alias.symlink_to(self.project, target_is_directory=True)
        self.project = alias
        self.state["project"] = str(alias)
        self.test_compiler_manifest_preserves_header_dependency()

    def test_failed_or_missing_compiler_evidence_rejected(self):
        for builds in [[], [dict(command=self.command["args"], exit_code=1)]]:
            state = {**self.state, "builds": builds}
            with self.assertRaises(ValueError):
                hook.compile_manifest([self.command], state, {})

    def test_current_unit_without_compile_header_dependency_rejected(self):
        expected, _ = hook.compile_manifest([self.command], self.state, {})
        store = self.root / "Store"
        (store / "v5/units").mkdir(parents=True)
        (store / "v5/units/current").write_bytes(b"unit")
        parsed = unit("current", str(self.obj), str(self.source))
        text = "\n".join(f"{key}: {value}" for key, value in parsed["metadata"].items())
        text += f"\nDependencies:\nRecord | user | {self.source} | main-record\n"
        with patch.object(hook, "capture", return_value=text):
            with self.assertRaisesRegex(ValueError, "lacks compiler header dependencies"):
                hook.discover(
                    Path("/index-dump"),
                    Path("/library"),
                    self.project,
                    store,
                    expected,
                    self.state["current_sources"],
                    self.root / "out",
                )

    def test_current_unit_without_main_record_rejected(self):
        expected, _ = hook.compile_manifest([self.command], self.state, {})
        store = self.root / "Store"
        (store / "v5/units").mkdir(parents=True)
        (store / "v5/units/current").write_bytes(b"unit")
        parsed = unit("current", str(self.obj), str(self.source))
        text = "\n".join(f"{key}: {value}" for key, value in parsed["metadata"].items()) + "\nDependencies:\n"
        with patch.object(hook, "capture", return_value=text):
            with self.assertRaisesRegex(ValueError, "lacks its main source record"):
                hook.discover(
                    Path("/index-dump"),
                    Path("/library"),
                    self.project,
                    store,
                    expected,
                    self.state["current_sources"],
                    self.root / "out",
                )

    def test_sdk_mismatch_rejected(self):
        with self.assertRaises(ValueError):
            hook.compile_manifest([self.command], self.state, {"sdk_path": "/real/ios/sdk"})

    def test_active_unit_target_and_provider_mismatch_rejected(self):
        expected, _ = hook.compile_manifest([self.command], self.state, {})
        current = unit("root", str(self.obj), str(self.source))
        for field, value in [("Target", "arm64-apple-ios16.0"), ("Provider Identifier", "swift"), ("Module", "Wrong")]:
            changed = dict(current, metadata={**current["metadata"], field: value})
            with self.assertRaises(ValueError):
                adapter.select_units({"root": changed}, expected)

    def test_ios_target_zero_normalization_preserves_platform(self):
        self.assertEqual(
            adapter.target_key("arm64-apple-ios16.0-simulator"), adapter.target_key("arm64-apple-ios16.0.0-simulator")
        )
        self.assertNotEqual(
            adapter.target_key("arm64-apple-ios16.0-simulator"), adapter.target_key("arm64-apple-ios16.0")
        )

    def test_state_location_does_not_assume_states_basename(self):
        (self.root / "setup.json").write_text("{}")
        self.assertEqual(hook.find_run_root(self.root / "runs/initial/state.json"), self.root)

    def test_source_only_stale_preserves_unsupported_native_baseline(self):
        accepted = dict(current_sources={"Sources/API.h": "old"}, index_files={"record": "same"})
        state = dict(
            current_sources={"Sources/API.h": "new"},
            index_files={"record": "same"},
            changed_since_success=["Sources/API.h"],
            expected_build="not-run",
        )
        result = hook.stale_observation(SimpleNamespace(cartograph=None), state, accepted, self.root / "stale")
        self.assertFalse(result["index_dump_native_freshness"]["scored"])
        self.assertIsNone(result["index_dump_native_freshness"]["recall"])
        self.assertEqual(result["compiler_calls"]["status"], "not-scored")
        state["index_files"]["record"] = "mutated"
        with self.assertRaises(ValueError):
            hook.stale_observation(SimpleNamespace(cartograph=None), state, accepted, self.root / "bad")

    def stale_native_case(self, document, exit_code=0, stderr="", stage="header_edit_unbuilt", before=None, after=None):
        before = before or {"Sources/API.h": "old"}
        after = after if after is not None else {"Sources/API.h": "new"}
        accepted = dict(current_sources=before, index_files={"record": "same"})
        state = dict(
            name=stage,
            current_sources=after,
            index_files={"record": "same"},
            changed_since_success=sorted(
                path for path in before.keys() | after.keys() if before.get(path) != after.get(path)
            ),
            expected_build="not-run",
            project=str(self.project),
            store=str(self.root / "store"),
        )
        out = self.root / "native-stale"
        out.mkdir(exist_ok=True)
        stdout, errors = out / "query.stdout", out / "query.stderr"
        stdout.write_text(json.dumps(document) if isinstance(document, dict) else document)
        errors.write_text(stderr)
        with patch.object(
            hook, "run", return_value={"exit_code": exit_code, "stdout": str(stdout), "stderr": str(errors)}
        ):
            return hook.stale_observation(SimpleNamespace(cartograph=Path("native")), state, accepted, out)[
                "native_cartograph_freshness"
            ]

    def stale_document(self, limitation):
        return {
            "requested": "CGBase",
            "level": "symbol",
            "status": "found",
            "limitations": [limitation],
            "result": {"usedBy": [{"location": {"path": str(self.project / "Sources/API.h")}}]},
        }

    def test_stale_path_must_be_in_the_diagnostic_not_normal_graph_locations(self):
        for warning in [
            "index-staleness: 1 of 10 source files changed",
            "index-staleness: Sources/Other.h changed after its unit",
            "index-staleness: Sources/API.h.backup changed after its unit",
        ]:
            result = self.stale_native_case(self.stale_document(warning))
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["reported_changed_paths"], [])

    def test_stale_matching_partial_output_cannot_hide_timeout_or_native_failure(self):
        document = self.stale_document("index-staleness: Sources/API.h changed after its unit")
        for exit_code in ["timeout", "launch-error", -9, 1, 2, 64]:
            self.assertEqual(self.stale_native_case(document, exit_code)["status"], "failed")
        self.assertEqual(self.stale_native_case("{broken", stderr="index-staleness: Sources/API.h")["status"], "failed")

    def test_stale_state_requires_the_header_or_removed_source_not_a_secondary_edit(self):
        cases = [
            (
                "header_rename_unbuilt",
                {"Sources/Old.h": "old", "Sources/Bridge.h": "old"},
                {"Sources/New.h": "old", "Sources/Bridge.h": "new"},
                "Sources/Bridge.h",
                "Sources/Old.h",
            ),
            (
                "swift_delete_unbuilt",
                {"Sources/Gone.swift": "old", "Sources/Entry.swift": "old"},
                {"Sources/Entry.swift": "new"},
                "Sources/Entry.swift",
                "Sources/Gone.swift",
            ),
        ]
        for stage, before, after, secondary, required in cases:
            warning = self.stale_document(f"missing-sources: {secondary} no longer indexed")
            result = self.stale_native_case(warning, stage=stage, before=before, after=after)
            self.assertEqual(result["status"], "failed")
            self.assertNotIn(secondary, result["required_changed_paths"])
            warning = self.stale_document(f"missing-sources: {required} no longer indexed")
            self.assertEqual(
                self.stale_native_case(warning, stage=stage, before=before, after=after)["status"], "passed"
            )

    def test_stale_structured_limitation_identifies_changed_dependency(self):
        result = self.stale_native_case(self.stale_document("index-staleness: Sources/API.h changed after its unit"))
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["reported_changed_paths"], ["Sources/API.h"])
        self.assertEqual(len(result["matched_diagnostics"]), 1)
        self.assertEqual(
            self.stale_native_case(self.stale_document("Sources/API.h index-staleness: text in wrong position"))[
                "status"
            ],
            "failed",
        )

    def test_known_extra_edge_fails_full_graph_score(self):
        oracle = self.root / "oracle.json"
        hook.save(
            oracle,
            {"variants": {"initial": {"nodes": [{"key": "a", "id": "A"}, {"key": "b", "id": "B"}], "edges": []}}},
        )
        score = hook.grade_graph({"edges": [["A", "B"]], "unresolved": []}, oracle, "initial")
        self.assertEqual(score["status"], "failed")
        self.assertEqual(score["false_positive"], [["A", "B"]])

    def test_source_anchor_disagrees_with_compiler_name_rejected(self):
        catalog = adapter.source_catalog(self.project, {"Sources/Core.m": ["BridgeKit"]})
        text = (
            "Symbols:\nf | function | c:f | definition\nOccurrences:\n1:5 | wrongName | function | c:f | definition\n"
        )
        records = [dict(absolute_path=str(self.source), module="", unit_module="", name="record")]
        with self.assertRaises(ValueError):
            adapter.baseline_graph(self.project, catalog, records, {"record": text})


if __name__ == "__main__":
    unittest.main()
