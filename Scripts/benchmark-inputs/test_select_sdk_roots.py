"""명시한 Apple 입력 경계를 제안만 하고 자동 승인하지 않는지 검증한다."""

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("selector", HERE / "select_sdk_roots.py")
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class RootSelectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.toolchain = self.developer / "Toolchains/XcodeDefault.xctoolchain"
        self.sdk = self.developer / "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        self.resource = self.toolchain / "usr/lib/clang/21"
        self.swift_resource = self.toolchain / "usr/lib/swift"
        for path in [
            self.sdk / "usr/include",
            self.sdk / "System/Library/Frameworks",
            self.resource / "include",
            self.swift_resource / "iphonesimulator",
        ]:
            path.mkdir(parents=True)
        self.tools = {
            name: self.toolchain / suffix
            for name, suffix in {
                "swift": "usr/bin/swift",
                "clang": "usr/bin/clang",
                "index_library": "usr/lib/libIndexStore.dylib",
            }.items()
        }
        self.tools["xcrun"] = self.root / "usr/bin/xcrun"
        for name, path in self.tools.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("synthetic " + name).encode())
        self.request = dict(
            schema_version=1,
            sdk_name="iphonesimulator",
            sdk=str(self.sdk),
            target="arm64-apple-ios16.0-simulator",
            tools={k: dict(path=str(v), sha256=selector.file_identity(v)["sha256"]) for k, v in self.tools.items()},
            contexts=["c", "objective-c", "c++", "objective-c++"],
            additional_immutable_roots={},
            project_roots={},
            search_flags={"clang": [], "swift": []},
            context_options={language: [] for language in selector.CONTEXTS},
            extra_contexts=[],
        )
        self.commands = []

    def runner(self, argv, cwd, stem, environment, timeout):
        self.commands.append((argv, environment))
        text = ""
        if "--show-sdk-path" in argv:
            text = str(self.sdk) + "\n"
        elif "--show-sdk-version" in argv:
            text = "26.5\n"
        elif "--show-sdk-build-version" in argv:
            text = "23F81a\n"
        elif "-print-resource-dir" in argv:
            text = str(self.resource) + "\n"
        elif "-print-target-info" in argv:
            text = json.dumps(
                {
                    "compilerVersion": "synthetic Swift",
                    "target": {"triple": self.request["target"]},
                    "paths": {
                        "runtimeResourcePath": str(self.swift_resource),
                        "runtimeLibraryPaths": [str(self.swift_resource / "iphonesimulator")],
                        "runtimeLibraryImportPaths": [str(self.swift_resource / "iphonesimulator")],
                    },
                }
            )
        stderr = ""
        if "-E" in argv:
            stderr = (
                '#include "..." search starts here:\n#include <...> search starts here:\n '
                + str(self.resource / "include")
                + "\n "
                + str(self.sdk / "usr/include")
                + "\n "
                + str(self.sdk / "System/Library/Frameworks")
                + " (framework directory)\nEnd of search list.\n"
            )
        stem.parent.mkdir(parents=True, exist_ok=True)
        out, err = Path(str(stem) + ".stdout"), Path(str(stem) + ".stderr")
        out.write_text(text)
        err.write_text(stderr)
        row = dict(
            command=argv,
            completed=True,
            passed=True,
            returncode=0,
            observed_returncode=0,
            failure=None,
            wall_seconds=0.0,
            stdout=str(out),
            stderr=str(err),
            descendant_cleanup_verified=False,
        )
        Path(str(stem) + ".json").write_text(json.dumps(row))
        return row

    def run_select(self, request=None, runner=None):
        return selector.record(request or self.request, self.root / "evidence", runner=runner or self.runner)

    def test_apple_optional_sdk_path_matches_selected_sdk(self):
        def run(*args):
            row = self.runner(*args)
            if "-print-target-info" in args[0]:
                path = Path(row["stdout"])
                doc = json.loads(path.read_text())
                doc["paths"]["sdkPath"] = str(self.sdk)
                path.write_text(json.dumps(doc))
            return row

        result = self.run_select(runner=run)
        self.assertEqual(result["status"], "awaiting-root-review")
        self.assertEqual(result["proposal"]["swift_paths"]["sdkPath"][0]["root"], "SDK")
        self.assertFalse(result["accepted"])

    def test_apple_sdk_path_mismatch_refuses_before_language_probes(self):
        def run(*args):
            row = self.runner(*args)
            if "-print-target-info" in args[0]:
                path = Path(row["stdout"])
                doc = json.loads(path.read_text())
                doc["paths"]["sdkPath"] = str(self.toolchain)
                path.write_text(json.dumps(doc))
            return row

        result = self.run_select(runner=run)
        self.assertEqual(result["failure"], "swift-sdk-mismatch")
        self.assertEqual(len(self.commands), 5)

    def test_all_uncovered_paths_remain_diagnostic_without_root_expansion(self):
        external = self.root / "runtime"
        external.mkdir()
        link = self.root / "runtime-alias"
        link.symlink_to(external, target_is_directory=True)
        missing = self.root / "missing-runtime"

        def run(*args):
            row = self.runner(*args)
            if "-print-target-info" in args[0]:
                path = Path(row["stdout"])
                doc = json.loads(path.read_text())
                doc["paths"]["runtimeLibraryPaths"] += [str(link), str(missing)]
                path.write_text(json.dumps(doc))
            if "-E" in args[0]:
                path = Path(row["stderr"])
                path.write_text(path.read_text().replace("End of search list.", f" {external}\nEnd of search list."))
            return row

        result = self.run_select(runner=run)
        self.assertEqual(len(self.commands), 9)
        self.assertEqual(result["exit_code"], 1)
        self.assertFalse(result["accepted"])
        self.assertEqual(result["proposal"]["roots"], {"SDK": str(self.sdk), "TOOLCHAIN": str(self.toolchain)})
        issues = result["unresolved_effective_paths"]
        self.assertEqual(len(issues), 6)
        linked = next(item for item in issues if item["path"] == str(link))
        self.assertEqual(linked["observation"]["entry_type"], "symlink")
        self.assertEqual(linked["observation"]["canonical_path"], str(external))
        self.assertEqual(linked["usage"], "swift-runtime-library-search")
        self.assertEqual(
            next(item for item in issues if item["path"] == str(missing))["observation"]["entry_type"], "missing"
        )
        self.assertTrue(all(item["scope"] == "diagnostic-only-uncovered-path" for item in issues))

    def test_incomplete_probe_still_stops_after_uncovered_path(self):
        external = self.root / "runtime"
        external.mkdir()

        def run(*args):
            row = self.runner(*args)
            if "-print-target-info" in args[0]:
                path = Path(row["stdout"])
                doc = json.loads(path.read_text())
                doc["paths"]["runtimeLibraryPaths"] += [str(external)]
                path.write_text(json.dumps(doc))
            if "-E" in args[0]:
                row.update(
                    completed=False, passed=False, returncode=125, observed_returncode=125, failure="nested-incomplete"
                )
            return row

        result = self.run_select(runner=run)
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(len(self.commands), 6)
        self.assertEqual(len(result["unresolved_effective_paths"]), 1)
        self.assertNotIn("proposal", result)

    def test_retained_apple_target_info_fixture_preserves_diagnostic_boundary(self):
        runtime = self.root / "runtime-library"
        (runtime / "swift").mkdir(parents=True)
        (self.sdk / "usr/lib/swift").mkdir(parents=True)
        fixture = (HERE / "fixtures/apple-swift-target-info-6.3.3.json").read_text()

        def run(*args):
            row = self.runner(*args)
            if "-print-target-info" in args[0]:
                Path(row["stdout"]).write_text(
                    fixture.replace("$DEVELOPER", str(self.developer)).replace("$SYSTEM_LIB", str(runtime))
                )
            return row

        result = self.run_select(runner=run)
        self.assertEqual(result["failure"], "unresolved-effective-paths")
        self.assertEqual(result["exit_code"], 1)
        self.assertEqual(len(self.commands), 9)
        self.assertEqual(result["unresolved_effective_paths"][0]["usage"], "swift-runtime-library-search")
        self.assertEqual(result["proposal"]["swift_paths"]["sdkPath"][0]["canonical_path"], str(self.sdk))
        self.assertFalse(result["accepted"])

    def test_sdk_path_wrong_type_stays_a_schema_failure(self):
        def run(*args):
            row = self.runner(*args)
            if "-print-target-info" in args[0]:
                path = Path(row["stdout"])
                doc = json.loads(path.read_text())
                doc["paths"]["sdkPath"] = [str(self.sdk)]
                path.write_text(json.dumps(doc))
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "unexpected-swift-path-schema")

    def test_path_diagnostics_are_bounded_and_do_not_open_content(self):
        outside = self.root / "outside"
        outside.mkdir()
        with mock.patch.object(selector.os, "open", side_effect=AssertionError("no content reads")):
            observed = selector.path_observation(str(outside))
        self.assertEqual(observed["entry_type"], "directory")
        self.assertFalse(observed["content_read"])
        with self.assertRaisesRegex(selector.DiscoveryError, "diagnostic-component-limit"):
            selector.path_observation("/" + "/".join(["part"] * 65))
        result = {"observed_path_count": selector.MAX_DISCOVERED_PATHS, "unresolved_effective_paths": []}
        with self.assertRaisesRegex(selector.DiscoveryError, "diagnostic-path-count-limit"):
            selector.diagnostic_binding(str(outside), {}, result, "test")
        result = {"observed_path_count": 0, "unresolved_effective_paths": []}
        with mock.patch.object(selector, "MAX_PATH_DIAGNOSTIC_BYTES", 4):
            with self.assertRaisesRegex(selector.DiscoveryError, "diagnostic-byte-limit"):
                selector.diagnostic_binding(str(outside), {}, result, "test")
        self.assertEqual(result["unresolved_effective_paths"], [])

    def test_complete_proposal_stays_unaccepted_and_probes_objcxx(self):
        result = self.run_select()
        self.assertEqual(result["status"], "awaiting-root-review")
        self.assertFalse(result["accepted"])
        self.assertFalse(result["final_protocol_ready"])
        self.assertEqual(result["proposal"]["roots"], {"SDK": str(self.sdk), "TOOLCHAIN": str(self.toolchain)})
        self.assertEqual(len(self.commands), 9)
        self.assertEqual(result["probe_wall_seconds"], 0.0)
        self.assertGreaterEqual(result["setup_and_guard_wall_seconds"], 0.0)
        self.assertEqual([r["language"] for r in result["proposal"]["clang_search_paths"]], self.request["contexts"])
        self.assertTrue(all("-target" in c[0] and "-isysroot" in c[0] for c in self.commands if "-E" in c[0]))
        self.assertEqual(result["proposal"]["unsealed_absence_dependencies"], [])

    def test_no_environment_values_are_recorded(self):
        with mock.patch.dict(
            os.environ, {"CPATH": "synthetic-private-value", "SDKROOT": "synthetic-private-sdk"}, clear=False
        ):
            result = self.run_select()
        self.assertTrue(all("CPATH" not in env and "SDKROOT" not in env for _, env in self.commands))
        self.assertTrue(all(env["DEVELOPER_DIR"] == str(self.developer) for _, env in self.commands))
        for path in (self.root / "evidence").rglob("*"):
            if path.is_file():
                self.assertNotIn("synthetic-private", path.read_text())

    def test_wrong_tool_hash_refuses_before_launch(self):
        self.request["tools"]["swift"]["sha256"] = "0" * 64
        r = self.run_select()
        self.assertEqual(r["failure"], "tool-identity-mismatch")
        self.assertEqual(self.commands, [])

    def test_compilers_from_different_toolchains_refuse(self):
        other = self.developer / "Toolchains/Other.xctoolchain/usr/bin/clang"
        other.parent.mkdir(parents=True)
        other.write_bytes(b"other")
        self.request["tools"]["clang"] = {"path": str(other), "sha256": selector.file_identity(other)["sha256"]}
        self.assertEqual(self.run_select()["failure"], "mixed-toolchains")
        self.assertEqual(self.commands, [])

    def test_selected_driver_alias_is_used_for_argv_not_only_canonical_binary(self):
        original = self.tools["swift"]
        target = original.with_name("swift-driver")
        original.rename(target)
        original.symlink_to(target)
        result = self.run_select()
        self.assertEqual(result["status"], "awaiting-root-review")
        argv = next(argv for argv, _ in self.commands if "-print-target-info" in argv)
        self.assertEqual(argv[0], str(original))
        self.assertEqual(result["selected_tools"]["swift"]["path"], str(target))

    def test_tool_symlink_outside_declared_toolchain_refuses(self):
        external = self.root / "outside"
        external.write_bytes(b"outside")
        self.tools["clang"].unlink()
        self.tools["clang"].symlink_to(external)
        self.request["tools"]["clang"]["sha256"] = selector.file_identity(external)["sha256"]
        self.assertEqual(self.run_select()["failure"], "missing-toolchain-ancestor")

    def test_probe_nested_125_stops_later_launches(self):
        def run(*a):
            row = self.runner(*a)
            row.update(
                completed=False, passed=False, returncode=125, observed_returncode=125, failure="nested-incomplete"
            )
            return row

        r = self.run_select(runner=run)
        self.assertEqual(r["status"], "incomplete")
        self.assertEqual(r["exit_code"], 125)
        self.assertEqual(len(self.commands), 1)
        self.assertNotIn("proposal", r)

    def test_completed_nonzero_is_failed_without_next_probe(self):
        def run(*a):
            row = self.runner(*a)
            row.update(passed=False, returncode=2, observed_returncode=2)
            return row

        r = self.run_select(runner=run)
        self.assertEqual(r["status"], "failed")
        self.assertEqual(r["exit_code"], 1)
        self.assertEqual(len(self.commands), 1)

    def test_failed_probe_retains_original_outcome_and_post_guard_failure(self):
        def run(*args):
            row = self.runner(*args)
            row.update(passed=False, returncode=2, observed_returncode=2)
            self.tools["clang"].write_bytes(b"changed")
            return row

        result = self.run_select(runner=run)
        self.assertEqual(result["failure"], "failed-probe")
        self.assertEqual(result["probes"][0]["observed_returncode"], 2)
        self.assertEqual(result["probes"][0]["post_probe_guard"]["status"], "failed")
        self.assertEqual(result["probes"][0]["post_probe_guard"]["failure"], "tool-generation-changed")
        self.assertEqual(len(self.commands), 1)

    def test_incomplete_probe_records_guard_unavailability_without_hiding_exit(self):
        def run(*args):
            row = self.runner(*args)
            row.update(completed=False, passed=False, returncode=125, observed_returncode=-15, failure="signal")
            return row

        result = self.run_select(runner=run)
        probe = result["probes"][0]
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(probe["observed_returncode"], -15)
        self.assertEqual(probe["post_probe_guard"]["status"], "unavailable")
        self.assertEqual(probe["post_probe_guard"]["reason"], "incomplete-process-cleanup-unverified")

    def test_tool_mutation_after_probe_is_failed_and_stops(self):
        def run(*a):
            row = self.runner(*a)
            self.tools["clang"].write_bytes(b"changed")
            return row

        r = self.run_select(runner=run)
        self.assertEqual(r["failure"], "tool-generation-changed")
        self.assertEqual(len(self.commands), 1)

    def test_sdk_alias_retarget_after_probe_is_failed(self):
        alias = self.root / "SDK-alias"
        alias.symlink_to(self.sdk, target_is_directory=True)
        self.request["sdk"] = str(alias)
        other = self.root / "Other.sdk"
        other.mkdir()

        def run(*a):
            row = self.runner(*a)
            alias.unlink()
            alias.symlink_to(other, target_is_directory=True)
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "root-selection-changed")
        self.assertEqual(len(self.commands), 1)

    def test_xcrun_different_sdk_refuses(self):
        def run(*a):
            row = self.runner(*a)
            Path(row["stdout"]).write_text(str(self.root) + "\n")
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "sdk-probe-mismatch")
        self.assertEqual(len(self.commands), 1)

    def test_external_existing_clang_search_path_blocks(self):
        extra = self.root / "outside"
        extra.mkdir()

        def run(*a):
            row = self.runner(*a)
            if "-E" in a[0]:
                path = Path(row["stderr"])
                path.write_text(path.read_text().replace("End of search list.", f" {extra}\nEnd of search list."))
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "unresolved-effective-paths")

    def test_ignored_external_absence_is_explicit_unsealed_gate(self):
        extra = self.root / "not-present"

        def run(*a):
            row = self.runner(*a)
            if "-E" in a[0]:
                path = Path(row["stderr"])
                path.write_text(f'ignoring nonexistent directory "{extra}"\n' + path.read_text())
            return row

        r = self.run_select(runner=run)
        self.assertEqual(r["status"], "awaiting-root-review")
        self.assertEqual(len(r["proposal"]["unsealed_absence_dependencies"]), 4)
        self.assertFalse(r["final_protocol_ready"])

    def test_ignored_existing_path_cannot_claim_absence(self):
        def run(*a):
            row = self.runner(*a)
            if "-E" in a[0]:
                path = Path(row["stderr"])
                path.write_text(f'ignoring nonexistent directory "{self.sdk}"\n' + path.read_text())
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "ignored-absence-exists")

    def test_swift_external_resource_path_blocks(self):
        extra = self.root / "other-resources"
        extra.mkdir()

        def run(*a):
            row = self.runner(*a)
            if "-print-target-info" in a[0]:
                doc = json.loads(Path(row["stdout"]).read_text())
                doc["paths"]["runtimeResourcePath"] = str(extra)
                Path(row["stdout"]).write_text(json.dumps(doc))
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "unresolved-effective-paths")

    def test_duplicate_swift_json_key_blocks(self):
        def run(*a):
            row = self.runner(*a)
            if "-print-target-info" in a[0]:
                Path(row["stdout"]).write_text('{"paths":{},"paths":{}}')
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "duplicate-json-key")

    def test_unknown_swift_path_shape_blocks(self):
        def run(*a):
            row = self.runner(*a)
            if "-print-target-info" in a[0]:
                doc = json.loads(Path(row["stdout"]).read_text())
                doc["paths"]["unknownPath"] = str(self.root)
                Path(row["stdout"]).write_text(json.dumps(doc))
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "unexpected-swift-path-schema")

    def test_incomplete_or_duplicate_search_list_blocks(self):
        for value in [
            "#include <...> search starts here:\n /tmp\n",
            "End of search list.\n",
            '#include "..." search starts here:\n#include <...> search starts here:\nEnd of search list.\n#include <...> search starts here:\nEnd of search list.\n',
        ]:
            with self.subTest(value=value), self.assertRaises(selector.DiscoveryError):
                selector.parse_clang_search(value)

    def test_same_context_order_and_framework_type_retained(self):
        value = '#include "..." search starts here:\n /first\n#include <...> search starts here:\n /second (framework directory)\n /third\nEnd of search list.\n'
        parsed = selector.parse_clang_search(value)
        self.assertEqual(
            [(r["path"], r["kind"], r["group"]) for r in parsed["effective"]],
            [("/first", "include", "quote"), ("/second", "framework", "angle"), ("/third", "include", "angle")],
        )

    def test_relative_or_ambiguous_search_path_rejected(self):
        for line in [" relative", " /first (unrecognized annotation)", " /first\x00suffix"]:
            with self.subTest(line=line), self.assertRaises(selector.DiscoveryError):
                selector.parse_clang_search(
                    '#include "..." search starts here:\n#include <...> search starts here:\n'
                    + line
                    + "\nEnd of search list.\n"
                )

    def test_actual_cpp17_and_objc_arc_variants_are_probed(self):
        self.request["context_options"]["objective-c++"] = ["-std=c++17"]
        self.request["context_options"]["c++"] = ["-std=c++17"]
        self.request["extra_contexts"] = [
            {"id": "objective-c-arc", "language": "objective-c", "options": ["-fobjc-arc"]}
        ]
        result = self.run_select()
        self.assertEqual(result["status"], "awaiting-root-review")
        self.assertEqual(len(self.commands), 10)
        probes = result["proposal"]["clang_search_paths"]
        self.assertEqual(len(probes), 5)
        self.assertEqual(probes[-1]["context_id"], "objective-c-arc")
        self.assertEqual(probes[-1]["context_options"], ["-fobjc-arc"])
        clang = [argv for argv, _ in self.commands if "-E" in argv]
        self.assertEqual(sum("-std=c++17" in argv for argv in clang), 2)
        self.assertEqual(sum("-fobjc-arc" in argv for argv in clang), 1)

    def test_context_plugin_or_duplicate_variants_refuse_before_execution(self):
        self.request["context_options"]["objective-c++"] = ["-Xclang", "-load"]
        self.assertEqual(self.run_select()["failure"], "unsupported-context-options")
        self.assertEqual(self.commands, [])

    def test_duplicate_extra_context_identity_refuses(self):
        self.request["extra_contexts"] = [{"id": "objective-c", "language": "objective-c", "options": ["-fobjc-arc"]}]
        self.assertEqual(self.run_select()["failure"], "invalid-extra-context")
        self.assertEqual(self.commands, [])

    def test_missing_objcxx_context_refuses(self):
        self.request["contexts"].remove("objective-c++")
        self.assertEqual(self.run_select()["failure"], "invalid-contexts")
        self.assertEqual(self.commands, [])

    def test_boolean_schema_and_unexpected_fields_refuse(self):
        self.request["schema_version"] = True
        self.assertEqual(self.run_select()["failure"], "invalid-request-schema")

    def test_evidence_output_inside_selected_root_refuses_without_write(self):
        with self.assertRaises(selector.DiscoveryError):
            selector.record(self.request, self.sdk / "evidence", runner=self.runner)
        self.assertFalse((self.sdk / "evidence").exists())

    def test_external_tool_aliases_cannot_hide_physical_output_overlap(self):
        aliases = self.root / "aliases"
        aliases.mkdir()
        for name in ("swift", "clang", "index_library"):
            alias = aliases / name
            alias.symlink_to(self.tools[name])
            self.request["tools"][name]["path"] = str(alias)
        output = self.toolchain / "discovery-output"
        with self.assertRaises(selector.DiscoveryError):
            selector.record(self.request, output, runner=self.runner)
        self.assertFalse(output.exists())
        self.assertEqual(self.commands, [])

    def test_cli_input_file_overlap_is_explicitly_refused(self):
        directory = self.root / "existing-inputs"
        directory.mkdir()
        request = directory / "request.json"
        request.write_text(json.dumps(self.request))
        before = request.read_bytes()
        row = self.run_cli(request, directory)
        self.assertEqual(row.returncode, 1)
        self.assertEqual(json.loads(row.stderr)["reason"], "evidence-input-file-overlap")
        self.assertEqual(request.read_bytes(), before)
        self.assertFalse((directory / "results.json").exists())

    def test_cli_runner_alias_overlap_is_explicitly_refused(self):
        directory = self.root / "runner-input"
        directory.mkdir()
        runner = directory / "runner.py"
        runner.write_text('raise Exception("must not execute")')
        alias = self.root / "runner-alias"
        alias.symlink_to(runner)
        request = self.root / "request.json"
        request.write_text(json.dumps(self.request))
        row = self.run_cli(request, directory, alias)
        self.assertEqual(row.returncode, 1)
        self.assertEqual(json.loads(row.stderr)["reason"], "evidence-input-file-overlap")
        self.assertFalse((directory / "results.json").exists())

    def test_existing_evidence_is_not_overwritten(self):
        self.run_select()
        with self.assertRaises(FileExistsError):
            self.run_select()

    def test_optional_roots_are_explicit_not_discovered(self):
        extra = self.developer / "Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
        extra.mkdir(parents=True)
        self.request["additional_immutable_roots"] = {"XCTEST_FRAMEWORKS": str(extra)}
        r = self.run_select()
        self.assertEqual(r["proposal"]["roots"]["XCTEST_FRAMEWORKS"], str(extra))
        self.assertTrue(all("-F" not in c[0] for c in self.commands))

    def test_explicit_project_flags_keep_separate_manifest_reference(self):
        project = self.root / "Project"
        headers = project / "include"
        headers.mkdir(parents=True)
        self.request["project_roots"] = {"PROJECT": {"path": str(project), "manifest_sha256": "1" * 64}}
        self.request["search_flags"] = {"clang": ["-I", str(headers)], "swift": ["-I", str(headers)]}
        r = self.run_select()
        self.assertEqual(r["status"], "awaiting-root-review")
        self.assertEqual(
            r["proposal"]["explicit_search_paths"]["clang"][0]["coverage"]["scope"], "project-generation-reference"
        )
        self.assertEqual(r["proposal"]["project_roots"]["PROJECT"]["manifest_sha256"], "1" * 64)
        self.assertTrue(all("-I" in c[0] for c in self.commands if "-E" in c[0] or "-print-target-info" in c[0]))
        self.assertNotIn("PROJECT", r["proposal"]["roots"])

    def test_unsupported_flags_and_unbound_search_paths_fail_before_probes(self):
        self.request["search_flags"]["clang"] = ["-Xclang", "-load"]
        self.assertEqual(self.run_select()["failure"], "unsupported-search-flags")
        self.assertEqual(self.commands, [])

    def test_project_manifest_reference_required(self):
        project = self.root / "Project"
        project.mkdir()
        self.request["project_roots"] = {"PROJECT": {"path": str(project)}}
        self.assertEqual(self.run_select()["failure"], "invalid-project-root")

    def test_explicit_external_include_is_not_implicitly_added(self):
        path = self.root / "outside"
        path.mkdir()
        self.request["search_flags"]["clang"] = ["-I", str(path)]
        self.assertEqual(self.run_select()["failure"], "external-search-path")
        self.assertEqual(self.commands, [])

    def test_nonfinite_probe_cost_fails_without_later_phase(self):
        def run(*a):
            row = self.runner(*a)
            row["wall_seconds"] = float("nan")
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "invalid-probe-receipt")
        self.assertEqual(len(self.commands), 1)

    def test_swift_target_mismatch_preserves_failure(self):
        def run(*a):
            row = self.runner(*a)
            if "-print-target-info" in a[0]:
                doc = json.loads(Path(row["stdout"]).read_text())
                doc["target"]["triple"] = "x86_64-apple-macosx"
                Path(row["stdout"]).write_text(json.dumps(doc))
            return row

        self.assertEqual(self.run_select(runner=run)["failure"], "swift-target-mismatch")

    def run_cli(self, request_path, output, runner_path=None):
        runner_path = runner_path or (HERE.parent / "validate-native-measurement.py")
        return subprocess.run(
            [
                sys.executable,
                str(HERE / "select_sdk_roots.py"),
                "--request",
                str(request_path),
                "--output",
                str(output),
                "--command-runner",
                str(runner_path),
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_cli_request_fifo_fails_promptly_with_cost(self):
        fifo = self.root / "request-fifo"
        os.mkfifo(fifo)
        row = self.run_cli(fifo, self.root / "cli-output")
        self.assertEqual(row.returncode, 1)
        receipt = json.loads(row.stderr)
        self.assertEqual(receipt["reason"], "input-not-regular-file")
        self.assertGreaterEqual(receipt["wall_seconds"], 0)

    def test_cli_duplicate_request_keys_fail_before_runner(self):
        request = self.root / "request.json"
        request.write_text('{"schema_version":999,"schema_version":1}')
        row = self.run_cli(request, self.root / "cli-output")
        self.assertEqual(row.returncode, 1)
        self.assertEqual(json.loads(row.stderr)["reason"], "duplicate-json-key")

    def test_cli_unreviewed_runner_is_never_executed(self):
        request = self.root / "request.json"
        request.write_text(json.dumps(self.request))
        marker = self.root / "marker"
        runner = self.root / "runner.py"
        runner.write_text(f"from pathlib import Path;Path({str(marker)!r}).write_text('bad')")
        row = self.run_cli(request, self.root / "cli-output", runner)
        self.assertEqual(row.returncode, 1)
        self.assertFalse(marker.exists())
        self.assertEqual(json.loads(row.stderr)["reason"], "unreviewed-command-runner")

    def test_cli_actual_nested125_preserves_root_return_and_stops(self):
        tool = self.tools["xcrun"]
        tool.write_text("#!" + sys.executable + "\nimport sys\nsys.exit(125)\n")
        tool.chmod(0o755)
        self.request["tools"]["xcrun"]["sha256"] = selector.file_identity(tool)["sha256"]
        request = self.root / "request.json"
        request.write_text(json.dumps(self.request))
        output = self.root / "cli-output"
        row = self.run_cli(request, output)
        self.assertEqual(row.returncode, 125, row.stderr)
        result = json.loads((output / "results.json").read_text())
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(len(result["probes"]), 1)
        self.assertEqual(result["probes"][0]["observed_returncode"], 125)
        self.assertFalse(result["probes"][0]["completed"])
        self.assertNotIn("proposal", result)
        self.assertFalse((output / "probes/sdk-version.json").exists())

    def test_cli_actual_signal_preserves_original_return(self):
        tool = self.tools["xcrun"]
        tool.write_text("#!" + sys.executable + "\nimport os,signal\nos.kill(os.getpid(),signal.SIGTERM)\n")
        tool.chmod(0o755)
        self.request["tools"]["xcrun"]["sha256"] = selector.file_identity(tool)["sha256"]
        request = self.root / "request.json"
        request.write_text(json.dumps(self.request))
        output = self.root / "cli-output"
        row = self.run_cli(request, output)
        self.assertEqual(row.returncode, 125, row.stderr)
        result = json.loads((output / "results.json").read_text())
        self.assertEqual(result["probes"][0]["observed_returncode"], -15)
        self.assertEqual(result["probes"][0]["failure"], "signal")
        self.assertEqual(len(result["probes"]), 1)

    def test_file_identity_rejects_fifo_and_symlink(self):
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        with self.assertRaises(selector.DiscoveryError):
            selector.file_identity(fifo)
        link = self.root / "link"
        link.symlink_to(self.tools["swift"])
        with self.assertRaises(selector.DiscoveryError):
            selector.file_identity(link)


if __name__ == "__main__":
    unittest.main(verbosity=2)
