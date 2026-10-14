"""네이티브 실행 없이 후보 입력 경계의 누락·변경 거부를 검증한다."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("admission", HERE / "native_calibration_inputs.py")
admission = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admission)


class NativeInputTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.expected = json.loads((HERE / "native_calibration_expectation.json").read_text())
        self.developer = self.root / "Xcode_26.6.app/Contents/Developer"
        self.chain = self.developer / "Toolchains/XcodeDefault.xctoolchain"
        self.sdk = self.developer / "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        self.expected.update(developer_lexical=str(self.developer), developer_physical=str(self.developer),
                             roots={"SDK": str(self.sdk), "TOOLCHAIN": str(self.chain)}, sdk_aliases=[str(self.sdk)])
        for p in [self.sdk / "usr/include", self.sdk / "Library", self.chain / "usr/bin", self.chain / "usr/include"]:
            p.mkdir(parents=True, exist_ok=True)
        self.body = self.sdk / "usr/include/input.h"
        self.body.write_bytes(b"original")
        paths = {"swift": self.chain / "usr/bin/swiftc", "swift_frontend": self.chain / "usr/bin/swift-frontend",
                 "clang": self.chain / "usr/bin/clang", "index_library": self.chain / "usr/lib/libIndexStore.dylib",
                 "xcrun": self.root / "usr/bin/xcrun"}
        for name, path in paths.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            if name != "swift":
                path.write_bytes(name.encode())
        paths["swift"].symlink_to("swift-frontend")
        self.expected["tools"] = {
            name: dict(allowed_paths=[str(path)], physical_path=str(path.resolve()),
                       **{k: v for k, v in admission.SELECTOR.file_identity(path.resolve()).items()
                          if k in {"bytes", "sha256"}}) for name, path in paths.items()
        }
        self.selected = dict(sdk=str(self.sdk), tools={name: str(path) for name, path in paths.items()})
        self.patch = mock.patch.object(admission, "expectation", return_value=(self.expected, "a" * 64))
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.collect = mock.patch.object(admission, "collect_native", side_effect=self.observed)
        self.collect_mock = self.collect.start()
        self.addCleanup(self.collect.stop)
        self.counter = 0

    def observed(self, *args, **kwargs):
        return dict(platform="darwin", runner=copy.deepcopy(self.expected["runner"]),
                    machine=copy.deepcopy(self.expected["machine"]), versions=copy.deepcopy(self.expected["versions"]),
                    selected=copy.deepcopy(self.selected),
                    layout=admission.selected_layout(self.expected, self.selected))

    def begin(self):
        self.counter += 1
        return admission.begin(self.root / f"candidate-{self.counter}", machine_fields=None,
                               command=None, environment={})

    def verify(self, candidate, boundary="after-generation"):
        self.counter += 1
        return admission.verify_boundary(candidate, self.root / f"verify-{self.counter}", machine_fields=None,
                                         command=None, environment={}, boundary=boundary)

    def test_exact_native_fields_are_required(self):
        observed = self.observed()
        admission.assert_native(observed, self.expected)
        for group in ["runner", "machine", "versions"]:
            for key in observed[group]:
                changed = copy.deepcopy(observed)
                changed[group][key] = "unexpected"
                with self.subTest(group=group, key=key), self.assertRaises(admission.AdmissionError):
                    admission.assert_native(changed, self.expected)
        observed["platform"] = "linux"
        with self.assertRaisesRegex(admission.AdmissionError, "native-macos-required"):
            admission.assert_native(observed, self.expected)

    def test_missing_native_field_is_not_guessed(self):
        observed = self.observed()
        del observed["machine"]["cpu_model"]
        with self.assertRaisesRegex(admission.AdmissionError, "native-machine-mismatch"):
            admission.assert_native(observed, self.expected)

    def test_source_declares_standard_profile_and_preserves_prior_expectation(self):
        expected = json.loads((HERE / "native_calibration_expectation.json").read_text())
        regime = expected.get("resource_regime", {})
        self.assertEqual(regime.get("id"), "github-hosted-macos-26-standard-m1-3core-7gib-v1")
        self.assertEqual(regime.get("class"), "standard")
        self.assertEqual(expected["runner_label"], "macos-26")
        self.assertIn("https://docs.github.com/en/actions/reference/runners/github-hosted-runners",
                      expected["source_urls"])
        workflow = (HERE.parents[1] / ".github/workflows/native-calibration.yml").read_text()
        self.assertEqual([line.strip() for line in workflow.splitlines() if line.strip().startswith("runs-on:")],
                         [f"runs-on: {expected['runner_label']}"])
        self.assertEqual(expected["machine"], dict(
            architecture="arm64", cpu_model="Apple M1 (Virtual)", kernel_release="25.6.0",
            logical_core_count=3, os="macOS", os_version="26.6.2", physical_core_count=3, ram_bytes=7516192768))
        self.assertEqual(expected.get("preserved_prior_expectation"), dict(
            commit="5a9ee5e4da14c9bcd36941ae004e949f94ba2c98",
            path="Scripts/benchmark-inputs/native_calibration_expectation.json",
            sha256="484080a6ea231795c81349da13ab55bb8f6670942d353ef74838db6956d11cde",
            failed_run_url="https://github.com/ictechgy/cartograph/actions/runs/38556206718"))

    def test_standard_profile_refuses_prior_or_changed_or_missing_resources(self):
        expected = json.loads((HERE / "native_calibration_expectation.json").read_text())
        observed = dict(platform="darwin", runner=copy.deepcopy(expected["runner"]),
                        machine=dict(architecture="arm64", cpu_model="Apple M1 (Virtual)", kernel_release="25.6.0",
                                     logical_core_count=3, os="macOS", os_version="26.6.2",
                                     physical_core_count=3, ram_bytes=7516192768),
                        versions=copy.deepcopy(expected["versions"]))
        admission.assert_native(observed, expected)
        prior_resources = dict(cpu_model="Apple M2 Pro (Virtual)", logical_core_count=5,
                               physical_core_count=5, ram_bytes=15032385536)
        prior = copy.deepcopy(observed)
        prior["machine"].update(prior_resources)
        with self.assertRaisesRegex(admission.AdmissionError, "native-machine-mismatch"):
            admission.assert_native(prior, expected)
        for key, value in prior_resources.items():
            changed = copy.deepcopy(observed)
            changed["machine"][key] = value
            with self.subTest(key=key, mutation="changed"), self.assertRaisesRegex(
                    admission.AdmissionError, "native-machine-mismatch"):
                admission.assert_native(changed, expected)
            missing = copy.deepcopy(observed)
            del missing["machine"][key]
            with self.subTest(key=key, mutation="missing"), self.assertRaisesRegex(
                    admission.AdmissionError, "native-machine-mismatch"):
                admission.assert_native(missing, expected)

    def test_environment_is_explicit_and_override_free(self):
        environment = {key: "untrusted" for key in admission.SELECTOR.OVERRIDES}
        environment.update(DEVELOPER_DIR=str(self.developer), KEEP="value")
        clean = admission.clean_environment(environment, self.expected)
        self.assertEqual(clean, {"KEEP": "value", "DEVELOPER_DIR": str(self.developer), "LC_ALL": "C"})
        with self.assertRaisesRegex(admission.AdmissionError, "developer-environment-mismatch"):
            admission.clean_environment({}, self.expected)

    def test_absence_retains_lexical_parent_and_nearest_ancestor(self):
        layout = admission.selected_layout(self.expected, self.selected)
        item = layout["absences"]["compiler-libcxx"]
        self.assertIn("/usr/bin/../include/", item["lexical_path"])
        self.assertEqual(item["canonical_path"], str(self.chain / "usr/include/c++/v1"))
        self.assertEqual(item["nearest_existing_ancestor"]["canonical_path"], str(self.chain / "usr/include"))
        self.assertEqual(item["missing_components"], ["c++", "v1"])
        self.assertEqual(set(layout["absences"]), {"sdk-local-include", "sdk-library-frameworks", "compiler-libcxx"})

    def test_present_absence_dependency_refuses(self):
        for suffix in ["usr/local/include", "Library/Frameworks"]:
            path = self.sdk / suffix
            path.mkdir(parents=True)
            with self.subTest(suffix=suffix), self.assertRaisesRegex(
                    admission.AdmissionError, "absence-dependency-exists"):
                admission.selected_layout(self.expected, self.selected)
            path.rmdir()

    def test_broken_absence_symlink_is_not_missing(self):
        (self.sdk / "usr/local").symlink_to(self.root / "gone")
        with self.assertRaises((OSError, admission.AdmissionError)):
            admission.selected_layout(self.expected, self.selected)

    def test_permission_error_is_not_missing(self):
        with mock.patch.object(Path, "lstat", side_effect=PermissionError("denied")):
            with self.assertRaises(PermissionError):
                admission.path_chain(self.sdk / "usr/local/include", absent=True)

    def test_special_absence_ancestor_refuses_without_opening(self):
        os.mkfifo(self.sdk / "usr/local")
        with self.assertRaisesRegex(admission.AdmissionError, "unexpected-boundary-entry"):
            admission.selected_layout(self.expected, self.selected)

    def test_added_root_refuses(self):
        self.expected["roots"]["EXTRA"] = str(self.root)
        with self.assertRaisesRegex(admission.AdmissionError, "unexpected-root-set"):
            admission.selected_layout(self.expected, self.selected)

    def test_new_tool_hash_is_not_accepted(self):
        Path(self.selected["tools"]["clang"]).write_bytes(b"replacement")
        with self.assertRaisesRegex(admission.AdmissionError, "native-tool-mismatch"):
            admission.selected_layout(self.expected, self.selected)

    def test_unlisted_identical_tool_alias_refuses(self):
        other = self.root / "other-clang"
        other.symlink_to(self.selected["tools"]["clang"])
        self.selected["tools"]["clang"] = str(other)
        with self.assertRaisesRegex(admission.AdmissionError, "unexpected-tool-alias"):
            admission.selected_layout(self.expected, self.selected)

    def test_capture_and_both_verifications_stay_candidates(self):
        candidate = self.begin()
        self.assertEqual(candidate["status"], "captured-candidate")
        self.assertEqual(candidate["boundary"], "before-compilation")
        for row in [candidate, self.verify(candidate), self.verify(candidate, "after-calibration")]:
            self.assertFalse(row["accepted"])
            self.assertFalse(row["final_protocol_ready"])
            self.assertFalse(row["runtime_closure_proven"])
            self.assertGreaterEqual(row["wall_seconds"], 0)
        verified = self.verify(candidate)
        self.assertEqual(verified["status"], "verified-candidate")
        self.assertTrue(verified["verification"]["matches"])
        self.assertGreaterEqual(verified["seal_verification_wall_seconds"], 0)
        self.assertGreaterEqual(candidate["seal_capture_wall_seconds"], 0)

    def test_content_mutation_fails_full_verification(self):
        candidate = self.begin()
        self.body.write_bytes(b"mutated!")
        result = self.verify(candidate)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["failure"], "sdk-content-changed")
        self.assertFalse(result["verification"]["matches"])
        self.assertGreaterEqual(result["seal_verification_wall_seconds"], 0)

    def test_new_absence_path_fails_before_verification(self):
        candidate = self.begin()
        (self.sdk / "usr/local/include").mkdir(parents=True)
        with mock.patch.object(admission.SEAL, "verify") as verify:
            result = self.verify(candidate)
        verify.assert_not_called()
        self.assertEqual(result["failure"], "absence-dependency-exists")

    def test_expectation_mutation_refuses(self):
        candidate = self.begin()
        with mock.patch.object(admission, "expectation", return_value=(self.expected, "b" * 64)):
            result = self.verify(candidate)
        self.assertEqual(result["failure"], "expectation-changed")

    def test_unreviewed_boundary_and_candidate_status_refuse(self):
        candidate = self.begin()
        self.assertEqual(self.verify(candidate, "after-link")["failure"], "invalid-boundary")
        candidate["accepted"] = True
        self.assertEqual(self.verify(candidate)["failure"], "invalid-candidate")

    def test_capture_failure_retains_cost(self):
        with mock.patch.object(admission.SEAL, "capture", side_effect=admission.SEAL.SealError("escaping-link")):
            result = self.begin()
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["failure"], "escaping-link")
        self.assertGreaterEqual(result["seal_capture_wall_seconds"], 0)

    def test_incomplete_native_probe_remains_incomplete(self):
        self.collect_mock.side_effect = admission.IncompleteAdmission("native-probe-incomplete")
        result = self.begin()
        self.assertEqual(result["status"], "incomplete")
        self.assertGreaterEqual(result["native_admission_wall_seconds"], 0)

    def test_capture_final_guard_detects_new_absence(self):
        capture = admission.SEAL.capture

        def changed(*args, **kwargs):
            result = capture(*args, **kwargs)
            (self.sdk / "Library/Frameworks").mkdir()
            return result

        with mock.patch.object(admission.SEAL, "capture", side_effect=changed):
            result = self.begin()
        self.assertEqual(result["failure"], "absence-dependency-exists")
        self.assertNotEqual(result["status"], "captured-candidate")

    def test_existing_evidence_is_not_overwritten(self):
        output = self.root / "existing"
        output.mkdir()
        receipt = output / "results.json"
        receipt.write_bytes(b"keep original")
        result = admission.begin(output, machine_fields=None, command=None, environment={})
        self.assertEqual(result["status"], "failed")
        self.assertEqual(receipt.read_bytes(), b"keep original")

    def test_input_output_overlap_is_refused(self):
        result = admission.begin(self.sdk / "evidence", machine_fields=None, command=None, environment={})
        self.assertEqual(result["failure"], "evidence-input-overlap")
        self.assertFalse((self.sdk / "evidence").exists())

    def test_manifest_size_is_not_silently_raised(self):
        with mock.patch.object(admission.SEAL, "MAX_MANIFEST_BYTES", 1):
            result = self.begin()
        self.assertEqual(result["failure"], "seal-manifest-byte-limit")


    def discovery(self):
        project = self.root / "Project"
        build = self.root / "Generations/restored_rebuilt/Build"
        modules = build / "modules"
        for path in [project / "Sources/BridgeKit/include", project / "Sources/AppFlow", modules,
                     self.sdk / "usr/include/c++/v1", self.sdk / "usr/lib/swift",
                     self.sdk / "System/Library/Frameworks", self.sdk / "System/Library/SubFrameworks",
                     self.chain / "usr/lib/clang/21/include", self.chain / "usr/lib/swift/iphonesimulator"]:
            path.mkdir(parents=True, exist_ok=True)
        for name in ["Checkout.swift", "Legacy.swift"]:
            (project / "Sources/AppFlow" / name).write_text("// fixture")
        common_path = HERE.parents[1] / "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/validation_common.py"
        spec = importlib.util.spec_from_file_location("native_input_test_common", common_path)
        common = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(common)
        request = dict(schema_version=1, sdk_name="iphonesimulator", sdk=str(self.sdk), target=self.expected["target"],
                       tools={name: dict(path=path, sha256=self.expected["tools"][name]["sha256"])
                              for name, path in self.selected["tools"].items() if name != "swift_frontend"},
                       contexts=admission.SELECTOR.CONTEXTS, additional_immutable_roots={},
                       project_roots={"PROJECT": dict(path=str(project), manifest_sha256="b" * 64),
                                      "MODULES": dict(path=str(modules), manifest_sha256="c" * 64)},
                       search_flags={"clang": ["-I", str(project / "Sources/BridgeKit/include")],
                                     "swift": ["-I", str(project / "Sources/BridgeKit/include"), "-I", str(modules)]},
                       context_options={"c": [], "objective-c": [], "c++": ["-std=c++17"],
                                        "objective-c++": ["-std=c++17"]},
                       extra_contexts=[dict(id="objective-c-arc", language="objective-c", options=["-fobjc-arc"])])
        commands = common.command_plan(project, build.parent / "IndexStore", build, str(self.sdk),
                                       self.expected["target"], self.selected["tools"]["swift"],
                                       self.selected["tools"]["clang"], "unused", False)
        request["compile_phase"] = dict(profile=admission.SELECTOR.COMPILE_PHASE_PROFILE, commands=commands,
                                        commands_sha256=admission.SELECTOR.content_digest(commands))
        hashes = {name: self.expected["tools"][name]["sha256"] for name in ["swift", "clang"]}
        patch = mock.patch.object(admission.SELECTOR, "REVIEWED_COMPILER_SHA256", hashes)
        patch.start()
        self.addCleanup(patch.stop)
        observation = dict(entry_type="directory", canonical_path="/usr/lib/swift", content_read=False,
                           components=[dict(component=p, entry_type="directory") for p in ["usr", "lib", "swift"]])
        patch = mock.patch.object(admission.SELECTOR, "path_observation", return_value=observation)
        patch.start()
        self.addCleanup(patch.stop)
        candidate = self.begin()
        selection = admission.SELECTOR.prepare(request)
        selection["compiler_alias_state"] = admission.SELECTOR.compiler_alias_state(selection)
        swift_paths = {
            "runtimeResourcePath": str(self.chain / "usr/lib/swift"),
            "runtimeLibraryPaths": [str(self.chain / "usr/lib/swift/iphonesimulator"), "/usr/lib/swift"],
            "runtimeLibraryImportPaths": [str(self.chain / "usr/lib/swift/iphonesimulator"),
                                          str(self.sdk / "usr/lib/swift")],
            "sdkPath": str(self.sdk),
        }
        stdout = self.root / "swift-target.stdout"
        stdout.write_text(json.dumps(dict(compilerVersion=admission.SELECTOR.REVIEWED_SWIFT_VERSION,
                                         swiftCompilerTag="swiftlang-6.3.3.1.3",
                                         target=dict(triple=self.expected["target"], platform="iphonesimulator"),
                                         paths=swift_paths)))
        result = dict(status="awaiting-root-review", accepted=False, final_protocol_ready=False, exit_code=0,
                      unresolved_effective_paths=[], compile_phase=selection["compile_phase"],
                      selected_tools=selection["tools"], compiler_path_aliases=selection["compiler_alias_state"],
                      probes=[dict(name="swift-target", stdout=str(stdout))])
        runtime = admission.deferred_reference(result, selection["compile_phase"], selection["roots"], self.expected)
        searches, absences = admission.expected_searches(selection, request)
        roots, projects = selection["roots"], request["project_roots"]
        def cover(path):
            return admission.covered(path, roots, {})
        result["proposal"] = dict(
            roots=candidate["native"]["layout"]["roots"], project_roots=projects,
            explicit_search_paths=selection["explicit_search_paths"], search_flags=request["search_flags"],
            sdk_name="iphonesimulator", sdk_version="26.5", sdk_build="23F81a", target=request["target"],
            clang_resource=cover(self.chain / "usr/lib/clang/21"),
            swift_paths={"runtimeResourcePath": [cover(self.chain / "usr/lib/swift")],
                         "runtimeLibraryPaths": [cover(self.chain / "usr/lib/swift/iphonesimulator"), runtime],
                         "runtimeLibraryImportPaths": [cover(self.chain / "usr/lib/swift/iphonesimulator"),
                                                       cover(self.sdk / "usr/lib/swift")],
                         "sdkPath": [cover(self.sdk)]},
            clang_search_paths=searches, unsealed_absence_dependencies=absences)
        result["deferred_target_runtime_references"] = [runtime]
        return candidate, request, result

    def test_discovery_binds_six_commands_absences_and_single_deferral(self):
        candidate, request, result = self.discovery()
        bound = admission.bind_discovery(candidate, request, result)
        self.assertEqual(bound["status"], "bound-candidate")
        self.assertEqual(bound["precompilation_content_sha256"], candidate["content_sha256"])
        self.assertEqual(len(bound["absence_dependencies"]), 3)
        self.assertEqual(len(bound["deferred_target_runtime_references"]), 1)
        self.assertFalse(bound["accepted"])
        self.assertFalse(bound["final_protocol_ready"])

    def test_discovery_rejects_new_root(self):
        candidate, request, result = self.discovery()
        request["additional_immutable_roots"]["EXTRA"] = str(self.root / "Extra")
        with self.assertRaisesRegex(admission.AdmissionError, "discovery-context-mismatch"):
            admission.bind_discovery(candidate, request, result)

    def test_discovery_rejects_link_phase_even_with_updated_digest(self):
        candidate, request, result = self.discovery()
        request["compile_phase"]["commands"][-1]["args"].append("-emit-executable")
        request["compile_phase"]["commands_sha256"] = admission.SELECTOR.content_digest(
            request["compile_phase"]["commands"])
        with self.assertRaisesRegex(admission.SELECTOR.DiscoveryError, "unreviewed-compile-phase"):
            admission.bind_discovery(candidate, request, result)

    def test_discovery_rejects_added_effective_path_and_dropped_absence(self):
        candidate, request, result = self.discovery()
        changed = copy.deepcopy(result)
        changed["proposal"]["clang_search_paths"][0]["effective"].append(
            copy.deepcopy(changed["proposal"]["clang_search_paths"][0]["effective"][0]))
        with self.assertRaisesRegex(admission.AdmissionError, "unexpected-effective-search-context"):
            admission.bind_discovery(candidate, request, changed)
        changed = copy.deepcopy(result)
        changed["proposal"]["unsealed_absence_dependencies"].pop()
        with self.assertRaisesRegex(admission.AdmissionError, "unexpected-effective-search-context"):
            admission.bind_discovery(candidate, request, changed)

    def test_discovery_rejects_forged_runtime_closure(self):
        candidate, request, result = self.discovery()
        result["deferred_target_runtime_references"][0]["runtime_closure_proven"] = True
        with self.assertRaisesRegex(admission.AdmissionError, "unexpected-effective-search-context"):
            admission.bind_discovery(candidate, request, result)

    def test_discovery_rejects_changed_original_swift_paths(self):
        candidate, request, result = self.discovery()
        path = Path(result["probes"][0]["stdout"])
        swift = json.loads(path.read_text())
        swift["paths"]["runtimeLibraryImportPaths"].append("/usr/lib/swift")
        path.write_text(json.dumps(swift))
        with self.assertRaisesRegex(admission.AdmissionError, "unreviewed-swift-paths"):
            admission.bind_discovery(candidate, request, result)


if __name__ == "__main__":
    unittest.main()
