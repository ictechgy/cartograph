#!/usr/bin/env python3
"""Portable byte/identity proof controls; synthetic files do not claim native compilation."""
import copy
import datetime
import importlib.util
import io
import json
import os
import contextlib
import hashlib
from pathlib import Path
import plistlib
import shlex
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("package_evidence", ROOT / "Scripts/xcode-local-package-evidence.py")
E = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(E)
NATIVE_SPEC = importlib.util.spec_from_file_location("native_package_checks", ROOT / "Scripts/verify-xcode-local-package-native.py")
NATIVE = importlib.util.module_from_spec(NATIVE_SPEC)
NATIVE_SPEC.loader.exec_module(NATIVE)


class AffectedProcessTests(unittest.TestCase):
    @staticmethod
    def supervisor(code=2, changes=None, missing=None, output=b"", error=RuntimeError):
        def run(argv, cwd, stem, timeout, stream_limit):
            value = {"command": argv, "cwd": str(cwd), "pid": 123, "returncode": code, "raw_returncode": code,
                     "timed_out": False, "owned_root_reaped": True, "ownership_lost": False,
                     "cleanup_errors": [], "output_limit_exceeded": None, "stream_limit_bytes": stream_limit,
                     "retained_stream_bytes": {"stdout": len(output), "stderr": 7},
                     "stdout": str(stem) + ".stdout", "stderr": str(stem) + ".stderr"}
            value.update(changes or {})
            files = {"json": json.dumps(value).encode(), "stdout": output, "stderr": b"refused"}
            for name, data in files.items():
                if name != missing:
                    Path(str(stem) + "." + name).write_bytes(data)
            if code or changes or missing:
                raise error("supervisor refusal")
            return value
        return types.SimpleNamespace(run=mock.Mock(side_effect=run))

    def test_expected_nonzero_receipt_passes_after_prior_uncaught_supervisor_failure(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            root = Path(folder); argv = ["cartograph", "affected"]
            before = self.supervisor()
            with self.assertRaisesRegex(RuntimeError, "supervisor refusal"):
                before.run(argv, root, root / "old", 120, 4 * 1024 * 1024)
            after = self.supervisor()
            result = NATIVE.affected_process(after, argv, root, root / "new", 2)
            self.assertEqual(result["returncode"], 2)
            after.run.assert_called_once_with(argv, root, root / "new", 120, stream_limit=4 * 1024 * 1024)
            self.assertEqual(NATIVE.affected_process(self.supervisor(0), argv, root, root / "success", 0)["returncode"], 0)
            self.assertEqual(NATIVE.affected_process(self.supervisor(1), argv, root, root / "positive", None)["returncode"], 1)

    def test_expected_refusal_never_accepts_timeout_overflow_cleanup_ownership_or_tampering(self):
        changes = [{"timed_out": True}, {"owned_root_reaped": False}, {"ownership_lost": True},
                   {"cleanup_errors": ["unknown"]}, {"output_limit_exceeded": "stdout"},
                   {"exception_type": "RuntimeError"}, {"raw_returncode": -9}, {"pid": None},
                   {"command": ["different"]}, {"cwd": "different"}, {"stdout": "different"},
                   {"stream_limit_bytes": 100}, {"retained_stream_bytes": {"stdout": 1, "stderr": 7}}]
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(NATIVE.OBS, "record_process_failure"):
            root = Path(folder)
            for i, changed in enumerate(changes):
                with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                    NATIVE.affected_process(self.supervisor(changes=changed), ["cartograph"], root, root / str(i), 2)
            for code, expected in ((0, 2), (1, 2), (-9, None), (124, 2)):
                with self.subTest(code=code, expected=expected), self.assertRaises(RuntimeError):
                    NATIVE.affected_process(self.supervisor(code), ["cartograph"], root, root / (str(code) + "code"), expected)
            with self.assertRaises(RuntimeError):
                NATIVE.affected_process(self.supervisor(1, {"raw_returncode": True}),
                                        ["cartograph"], root, root / "boolean-code", None)

    def test_stale_missing_receipts_and_startup_errors_remain_failures(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(NATIVE.OBS, "record_process_failure"):
            root = Path(folder); argv = ["cartograph"]
            for name in ("json", "stdout", "stderr"):
                stem = root / ("old-" + name); Path(str(stem) + "." + name).write_bytes(b"stale")
                runner = self.supervisor()
                with self.assertRaisesRegex(RuntimeError, "already exists"):
                    NATIVE.affected_process(runner, argv, root, stem, 2)
                runner.run.assert_not_called()
                with self.assertRaisesRegex(RuntimeError, "missing or redirected"):
                    NATIVE.affected_process(self.supervisor(missing=name), argv, root, root / ("missing-" + name), 2)
            with self.assertRaisesRegex(RuntimeError, "supervisor refusal"):
                NATIVE.affected_process(self.supervisor(), argv, root, root / "unexpected", 0)
            with self.assertRaises(OSError):
                NATIVE.affected_process(self.supervisor(error=OSError), argv, root, root / "startup", 2)
            def malformed(argv, cwd, stem, timeout, stream_limit):
                for name, data in (("json", b'{"returncode":'), ("stdout", b""), ("stderr", b"refusal")):
                    Path(str(stem) + "." + name).write_bytes(data)
                raise RuntimeError("supervisor refusal")
            with self.assertRaises(ValueError):
                NATIVE.affected_process(types.SimpleNamespace(run=malformed), argv, root, root / "malformed", 2)

    @unittest.skipUnless(os.name == "posix", "Actual capped subprocess ownership requires native CI")
    def test_real_supervised_nonzero_is_accepted_only_with_exact_clean_receipt(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            root = Path(folder)
            process = NATIVE.affected_process(NATIVE.OBS.process_supervisor(),
                [NATIVE.sys.executable, "-c", "import sys; sys.stderr.write('expected fixture refusal'); sys.exit(2)"],
                root, root / "actual-refused", 2)
            self.assertEqual(process["returncode"], 2)
            self.assertEqual(process["cleanup_errors"], [])


class TestExecutionTests(unittest.TestCase):
    @staticmethod
    def observed_method_selection():
        # ca46313 native job120698648990의 실제 SELECTOR_OBSERVATION을 재생한다. 실행 성공 증거는 아니다.
        return ({"targetScope": {"evidenceStatus": "matched-capture", "xcode": {
                    "selectionStatus": "review-candidates", "selectorTargetByModule": {
                        "ChecksModule": "ChecksBlueprint", "OtherModule": "OtherBlueprint"}}},
                 "tests": [{"symbol": {"usr": "c:@M@ChecksModule@objc(cs)ChangedTests(im)testChanged",
                     "name": "testChanged()", "qualifiedName": "ChecksModule.testChanged()",
                     "module": "ChecksModule", "kind": "method"},
                     "xcodebuildIdentifier": "ChecksModule/ChangedTests/testChanged"}], "uncertainTestCandidates": []},
                ["-only-testing:ChecksBlueprint/ChangedTests/testChanged"])

    def test_observed_compiler_method_passes_exact_selection_while_prior_target_assertion_fails(self):
        document, selectors = self.observed_method_selection()
        before = copy.deepcopy((document, selectors))
        with self.assertRaisesRegex(RuntimeError, "Expected honest whole-target selector fallback"):
            NATIVE.require(selectors == ["-only-testing:ChecksBlueprint"], "Expected honest whole-target selector fallback")
        self.assertEqual(NATIVE.fixture_method_selection(document, selectors), "method")
        self.assertEqual((document, selectors), before)
        del document["uncertainTestCandidates"]
        self.assertEqual(NATIVE.fixture_method_selection(document, selectors), "method")

    def test_method_selection_refuses_missing_extra_other_uncertain_and_unknown_tests(self):
        document, selectors = self.observed_method_selection()
        invalid = [None, {}, {**document, "tests": []}, {**document, "tests": None},
                   {**document, "tests": document["tests"] * 2}, {**document, "tests": [{}]}]
        for value in (None, {}, "unknown", [document["tests"][0]]):
            invalid.append({**document, "uncertainTestCandidates": value})
        for key in ("usr", "name", "qualifiedName", "module", "kind"):
            changed = copy.deepcopy(document)
            changed["tests"][0]["symbol"][key] = "OtherModule" if key == "module" else "unknown"
            invalid.append(changed)
            changed = copy.deepcopy(document)
            del changed["tests"][0]["symbol"][key]
            invalid.append(changed)
        for changed in invalid:
            with self.subTest(document=changed), self.assertRaises(RuntimeError):
                NATIVE.fixture_method_selection(changed, selectors)

    def test_method_selection_refuses_unknown_scope_wrong_mapping_identifiers_and_target_fallback(self):
        document, selectors = self.observed_method_selection()
        invalid = []
        for key in ("targetScope", "tests"):
            changed = copy.deepcopy(document); del changed[key]; invalid.append(changed)
        changed = copy.deepcopy(document); changed["targetScope"]["evidenceStatus"] = "unknown"; invalid.append(changed)
        changed = copy.deepcopy(document); changed["targetScope"]["xcode"]["selectionStatus"] = "unknown"; invalid.append(changed)
        for mapping in ({}, {"ChecksModule": "ChecksModule"}, {"ChecksModule": "OtherBlueprint", "OtherModule": "OtherBlueprint"}):
            changed = copy.deepcopy(document)
            changed["targetScope"]["xcode"]["selectorTargetByModule"] = mapping
            invalid.append(changed)
        for identifier in (None, "ChecksBlueprint/ChangedTests/testChanged", "OtherModule/OtherTests/testOther"):
            changed = copy.deepcopy(document); changed["tests"][0]["xcodebuildIdentifier"] = identifier; invalid.append(changed)
        for changed in invalid:
            with self.subTest(document=changed), self.assertRaises(RuntimeError):
                NATIVE.fixture_method_selection(changed, selectors)
        for arguments in ([], selectors * 2, ["-only-testing:ChecksBlueprint"],
                          ["-only-testing:ChecksModule/ChangedTests/testChanged"],
                          ["-only-testing:OtherBlueprint/OtherTests/testOther"],
                          selectors + ["-only-testing:OtherBlueprint"]):
            with self.subTest(arguments=arguments), self.assertRaises(RuntimeError):
                NATIVE.fixture_method_selection(document, arguments)

    def test_selector_observation_preserves_exact_arguments_and_compiler_identity(self):
        document = {"tests": [{"symbol": {"usr": "s:test", "qualifiedName": "ChangedTests.testChanged()",
                    "name": "testChanged()", "module": "ChecksModule", "kind": "method", "body": "not printed"},
                    "xcodebuildIdentifier": "ChecksModule/ChangedTests/testChanged"}],
                    "uncertainTestCandidates": [{"symbol": {"module": "OtherModule", "name": "testMaybe"}}],
                    "targetScope": {"xcode": {"selectorTargetByModule": {
                        "ChecksModule": "ChecksBlueprint", "OtherModule": "OtherBlueprint"}}}}
        selectors = ["-only-testing:ChecksBlueprint/ChangedTests/testChanged", "unexpected\u001bargument"]
        before = copy.deepcopy((document, selectors))
        with mock.patch("builtins.print") as printer:
            report = NATIVE.record_selector_observation(document, selectors)
        self.assertEqual(report["arguments"], selectors)
        self.assertEqual(report["tests"][0]["blueprint"], "ChecksBlueprint")
        self.assertEqual(report["tests"][0]["symbol"]["qualifiedName"], "ChangedTests.testChanged()")
        self.assertEqual(report["tests"][0]["xcodebuildIdentifier"], "ChecksModule/ChangedTests/testChanged")
        self.assertIsNone(report["uncertainTestCandidates"][0]["xcodebuildIdentifier"])
        self.assertEqual((document, selectors), before)
        encoded = printer.call_args.args[0]
        self.assertNotIn("\u001b", encoded)
        self.assertNotIn("not printed", encoded)
        self.assertEqual(json.loads(encoded.removeprefix("SELECTOR_OBSERVATION ")), report)
        with self.assertRaisesRegex(RuntimeError, "original selector assertion"):
            NATIVE.require(selectors == ["-only-testing:ChecksBlueprint"], "original selector assertion")

    def test_selector_observation_refuses_schema_and_bounds_output_without_replacing_failure(self):
        with mock.patch("builtins.print", side_effect=BrokenPipeError("closed")):
            report = NATIVE.record_selector_observation({"tests": [{"symbol": {"module": b"invalid"}}]}, [])
        self.assertEqual(report["status"], "diagnostic-refused")
        with mock.patch("builtins.print") as printer:
            report = NATIVE.record_selector_observation({"tests": []}, ["x" * 4096] * 30)
        self.assertEqual(report["status"], "diagnostic-output-budget-exceeded")
        self.assertLess(len(printer.call_args.args[0]), 64 * 1024)
        self.assertEqual(len(report["sha256"]), 64)

    def test_test_run_observation_reads_actual_dependencies_and_limits_printed_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.xctestrun"
            row = {"BlueprintName": "Checks", "TestBundlePath": "__TESTROOT__/Checks.xctest",
                   "DependentProductPaths": ["__TESTROOT__/ArithmeticCore.o"], "OtherMetadata": "not printed"}
            data = plistlib.dumps({"TestConfigurations": [{"TestTargets": [row]}]})
            path.write_bytes(data)
            receipt = {"testRunPath": str(path), "testRunSHA256": "old-hash",
                       "localPackage": {"aggregate": {"output": "/actual/ArithmeticCore.o"}},
                       "products": {"do-not-infer-this-path": "ignored"}}
            with mock.patch("builtins.print") as printer:
                report = NATIVE.record_test_run_observation(receipt)
            self.assertEqual(report["status"], "observed")
            self.assertEqual(report["testRunSHA256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(report["capturedTestRunSHA256"], "old-hash")
            self.assertEqual(report["testTargets"][0]["DependentProductPaths"], row["DependentProductPaths"])
            encoded = printer.call_args.args[0]
            self.assertNotIn("not printed", encoded)
            self.assertNotIn("do-not-infer-this-path", encoded)
            self.assertEqual(json.loads(encoded.removeprefix("TEST_RUN_OBSERVATION ")), report)
            del row["DependentProductPaths"]
            path.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [row]}]}))
            with mock.patch("builtins.print"):
                missing = NATIVE.record_test_run_observation(receipt)
            self.assertEqual(missing["status"], "observed")
            self.assertIsNone(missing["testTargets"][0]["DependentProductPaths"])

    def test_test_run_observation_keeps_malformed_budget_and_closed_pipe_diagnostic_only(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.xctestrun"
            receipt = {"testRunPath": str(path), "testRunSHA256": "hash",
                       "localPackage": {"aggregate": {"output": "/aggregate.o"}}}
            malformed = [b"not a plist", plistlib.dumps({"TestConfigurations": []}), b"x" * (8 * 1024 * 1024 + 1)]
            for invalid in (b"plist data", datetime.datetime(2026, 10, 23)):
                for key in ("BlueprintName", "TestBundlePath", "DependentProductPaths"):
                    row = {"BlueprintName": "Checks", "TestBundlePath": "__TESTROOT__/Checks.xctest",
                           "DependentProductPaths": ["__TESTROOT__/ArithmeticCore.o"]}
                    row[key] = [invalid] if key == "DependentProductPaths" else invalid
                    malformed.append(plistlib.dumps({"TestConfigurations": [{"TestTargets": [row]}]}))
            for data in malformed:
                path.write_bytes(data)
                with mock.patch("builtins.print", side_effect=BrokenPipeError("closed")):
                    report = NATIVE.record_test_run_observation(receipt)
                self.assertEqual(report["status"], "diagnostic-refused")
            path.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
                "BlueprintName": "Checks", "TestBundlePath": "__TESTROOT__/Checks.xctest",
                "DependentProductPaths": ["x" * (64 * 1024)]}]}]}))
            with mock.patch("builtins.print"):
                report = NATIVE.record_test_run_observation(receipt)
            self.assertEqual(report["status"], "diagnostic-output-budget-exceeded")
            with self.assertRaisesRegex(RuntimeError, "original product gate"):
                NATIVE.require(False, "original product gate")

    def test_scope_diagnostic_preserves_refusal_and_escapes_controls(self):
        document = {"targetScope": {"evidenceStatus": "unknown", "limitations": ["bad\u001b input"]},
                    "limitations": ["incomplete"], "unusedBody": "not printed"}
        receipt = {"version": 2, "inputFingerprint": "a" * 64, "selectedTargetIDs": ["Checks"],
                   "localPackage": {"files": {"private-looking": "not printed"}}}
        before = copy.deepcopy((document, receipt))
        with mock.patch("builtins.print") as printer:
            report = NATIVE.record_scope_observation(document, receipt)
        encoded = printer.call_args.args[0]
        self.assertEqual(report["targetScope"], document["targetScope"])
        self.assertEqual(report["limitations"], ["incomplete"])
        self.assertEqual((document, receipt), before)
        self.assertNotIn("\u001b", encoded)
        self.assertNotIn("not printed", encoded)
        self.assertEqual(json.loads(encoded.removeprefix("SCOPE_OBSERVATION ")), report)

    def test_scope_diagnostic_budget_and_closed_pipe_do_not_replace_product_assertion(self):
        document = {"targetScope": {"evidenceStatus": "unknown"}, "limitations": ["x" * (64 * 1024)]}
        with mock.patch("builtins.print", side_effect=BrokenPipeError("closed")):
            report = NATIVE.record_scope_observation(document, {})
        self.assertEqual(report["status"], "diagnostic-output-budget-exceeded")
        self.assertGreater(report["bytes"], 64 * 1024)
        self.assertEqual(len(report["sha256"]), 64)
        with self.assertRaisesRegex(RuntimeError, "original product gate"):
            NATIVE.require(document["targetScope"]["evidenceStatus"] == "matched-capture", "original product gate")

    def test_generated_metadata_observation_is_finite_and_not_source_discovery(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve() / ".swiftpm"
            self.assertFalse(NATIVE.generated_metadata(root)["exists"])
            root.mkdir()
            document = root / "workspace.xcworkspacedata"
            document.write_bytes(b"<Workspace/>\n")
            (root / "unknown.swift").write_bytes(b"doNotPublishSource()")
            result = NATIVE.generated_metadata(root)
            self.assertEqual(result["totalBytes"], 33)
            self.assertNotIn("utf8Metadata", result["entries"][0])
            self.assertEqual(result["entries"][1]["utf8Metadata"], "<Workspace/>\n")
            document.write_bytes(b"x" * (8 * 1024 + 1))
            with self.assertRaisesRegex(RuntimeError, "byte budget"):
                NATIVE.generated_metadata(root)
            document.unlink()
            path = root
            for i in range(9):
                path = path / str(i)
                path.mkdir()
            with self.assertRaisesRegex(RuntimeError, "depth budget"):
                NATIVE.generated_metadata(root)

    def test_generated_metadata_total_budget_and_diagnostic_errors_preserve_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            for i in range(5):
                (root / (str(i) + ".plist")).write_bytes(b"x" * (8 * 1024))
            with self.assertRaisesRegex(RuntimeError, "byte budget"):
                NATIVE.generated_metadata(root)
            with mock.patch.object(NATIVE.SCOPE, "save", side_effect=OSError("disk error")), \
                 mock.patch("builtins.print", side_effect=BrokenPipeError("closed")):
                report = NATIVE.record_generated_metadata(root, root, "after-capture-failure")
            self.assertEqual(report["persistenceError"], "OSError")
            self.assertEqual(report["phase"], "after-capture-failure")

    def test_generated_metadata_entries_are_bounded_before_sorting(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            seen = []
            def entries():
                for i in range(1000):
                    seen.append(i)
                    yield type("Entry", (), {"path": str(root / str(i))})()
            with mock.patch.object(NATIVE.os, "scandir", return_value=contextlib.nullcontext(entries())), \
                 self.assertRaisesRegex(RuntimeError, "entry budget"):
                NATIVE.generated_metadata(root)
            self.assertEqual(len(seen), 129)

    @unittest.skipUnless(os.name == "posix", "Native POSIX symlink boundary control")
    def test_generated_metadata_does_not_follow_external_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder).resolve()
            root = base / "metadata"
            root.mkdir()
            outside = base / "outside.plist"
            outside.write_bytes(b"not admitted")
            (root / "escape.plist").symlink_to(outside)
            with self.assertRaisesRegex(RuntimeError, "path boundary"):
                NATIVE.generated_metadata(root)

    def test_terminal_aggregate_and_actual_test_case_are_both_required(self):
        # Format from main4f native39982616827; this is a parser control, not a test run.
        log = """Test Suite 'All tests' started at 2026-10-23 16:09:35.991.
Test Case '-[ChecksModule.ChangedTests testChanged]' started.
Test Case '-[ChecksModule.ChangedTests testChanged]' passed (0.010 seconds).
Test Suite 'ChangedTests' passed at 2026-10-23 16:09:36.011.
 Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.014) seconds
Test Suite 'All tests' passed at 2026-10-23 16:09:36.011.
 Executed 1 test, with 0 failures (0 unexpected) in 0.010 (0.020) seconds
** TEST EXECUTE SUCCEEDED **
"""
        self.assertEqual(NATIVE.executed_tests(log)["executedTestCount"], 1)
        other = "Test Case '-[OtherModule.OtherTests testOther]' started.\nTest Case '-[OtherModule.OtherTests testOther]' passed (0.010 seconds).\n"
        bad = log.replace("Test Suite 'All tests' passed", other + "Test Suite 'All tests' passed")
        bad = bad.replace("in 0.010 (0.020) seconds", "in 0.020 (0.030) seconds").replace(
            " Executed 1 test, with 0 failures (0 unexpected) in 0.020", " Executed 2 tests, with 0 failures (0 unexpected) in 0.020")
        # The old expression incorrectly accepted a two-case log with one-test child suites.
        self.assertTrue("testChanged" in bad and "Executed 1 test" in bad and "testOther'" not in bad)
        head, _, tail = log.rpartition("Executed 1 test")
        for candidate in (bad, head + "Executed 2 tests" + tail,
                log.replace("passed (0.010 seconds)", "failed (0.010 seconds)"),
                log + "Test Case '-[OtherModule.OtherTests testOther]' started.\n"):
            with self.assertRaises(RuntimeError):
                NATIVE.executed_tests(candidate)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "project"
        self.derived = self.root / "DerivedData"
        self.store = self.derived / "Index.noindex/DataStore"
        self.build = self.derived / "Build"
        self.source = self.write(self.project / "Packages/LocalMath/Sources/ArithmeticCore/Math.swift", b"func value() {}")
        self.obj = self.write(self.build / "Intermediates/Math.o", b"compiler bytes")
        self.aggregate = self.write(self.build / "Products/Debug/ArithmeticCore.o", b"aggregate bytes")
        self.native = self.write(self.build / "Products/Debug/CoreKit.framework/CoreKit", b"native bytes")
        self.other = self.write(self.build / "Intermediates/Core.o", b"native object")
        self.record = self.write(self.store / "v5/records/AB/Math.swift-AB", b"actual raw record bytes")
        self.response = self.write(self.build / "Intermediates/linker.resp", b"-lswiftCore")
        self.virtual = "/LocalMath.build/Debug/ArithmeticCore.build/Objects-normal/arm64/Math.o"
        self.map = self.write(self.build / "Intermediates/OutputFileMap.json", json.dumps({str(self.source): {
            "object": str(self.obj), "index-unit-output-path": self.virtual}}).encode())
        self.source_list = self.write(self.build / "Intermediates/Input.SwiftFileList", (shlex.quote(str(self.source)) + "\n").encode())
        self.object_list = self.write(self.build / "Intermediates/Input.LinkFileList", (shlex.quote(str(self.obj)) + "\n").encode())
        self.native_list = self.write(self.build / "Intermediates/Native.LinkFileList",
                                      (shlex.quote(str(self.other)) + "\n" + shlex.quote(str(self.aggregate)) + "\n").encode())
        self.aggregate_map = self.write(self.build / "Intermediates/Aggregate.map", self.map_bytes(self.aggregate, [self.obj]))
        self.native_map = self.write(self.build / "Intermediates/Native.map", self.map_bytes(self.native, [self.other, self.aggregate]))
        self.compiler = ["builtin-SwiftDriver", "--", "/tool/swiftc", "-module-name", "ArithmeticCore", "@" + str(self.source_list),
                         "-output-file-map", str(self.map), "-target", "arm64-apple-macos10.13", "-index-store-path", str(self.store)]
        self.aggregate_argv = ["/tool/clang", "-r", "-filelist", str(self.object_list), "-target", "arm64-apple-macos10.13",
                               "-Xlinker", "-map", "-Xlinker", str(self.aggregate_map), "@" + str(self.response), "-o", str(self.aggregate)]
        self.native_argv = ["/tool/clang", "-filelist", str(self.native_list), "-target", "arm64-apple-macos13.0",
                            "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                            "-Xlinker", "-map", "-Xlinker", str(self.native_map), "@" + str(self.response), "-o", str(self.native)]
        self.spec = {"path": "Packages/LocalMath", "name": "LocalMath", "module": "ArithmeticCore", "product": "ArithmeticProduct",
                     "referenceID": "REF", "productReferenceID": "PRODUCT", "consumers": ["CORE"],
                     "inventory": {"Sources/ArithmeticCore/Math.swift": "bound-by-preflight"}}
        self.snapshot = {"snapshot": {"sourceRecordAdmissions": [{"path": str(self.source), "unit": "Math.o-UNIT",
            "module": "ArithmeticCore", "record": self.record.name, "unitOutputIdentity": self.virtual,
            "unitTargetTriple": "arm64-apple-macos10.13"}]}}
        self.targets = {"CORE": {"name": "CoreBlueprint", "module": "CoreKit", "dependencies": []},
                        "CHECKS": {"name": "ChecksBlueprint", "module": "ChecksModule", "dependencies": ["CORE"]}}
        self.settings = [{"target": "CoreBlueprint", "buildSettings": {"TARGET_BUILD_DIR": str(self.native.parent),
                                                                       "EXECUTABLE_PATH": self.native.name}}]

    @staticmethod
    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    @staticmethod
    def map_bytes(output, objects):
        return (f"# Path: {output}\n# Arch: arm64\n# Object files:\n" +
                "".join(f"[ {i}] {path}\n" for i, path in enumerate(objects, 1)) +
                "# Sections:\n# Address\tSize\tSegment\tSection\n0x1 0x1 __TEXT __text\n# Symbols:\n# Address\tSize\tFile  Name\n" +
                "".join(f"0x{i:X} 0x1 [ {i}] _symbol{i}\n" for i in range(1, len(objects) + 1))).encode()

    def capture(self, extra=None):
        commands = [self.compiler, self.aggregate_argv, self.native_argv] + (extra or [])
        log = "\n".join(shlex.join(args) for args in commands)
        return E.assemble(self.spec, self.project, self.derived, self.store, log, self.snapshot,
                          self.targets, self.settings, ["CHECKS"], "arm64")

    def test_positive_distinct_virtual_output_and_actual_live_chain(self):
        duplicate = list(self.compiler)
        duplicate[0] = "builtin-Swift-Compilation"
        proof = self.capture([duplicate])
        self.assertEqual(len(proof["compilations"]), 1)
        self.assertEqual(proof["records"][0]["unitOutputIdentity"], self.virtual)
        self.assertEqual(proof["compilations"][0]["object"], str(self.obj))
        self.assertEqual(proof["links"][0]["targetID"], "CORE")
        self.assertEqual(proof["files"][str(self.response)]["kind"], "document")

    def test_conflicting_compiler_wrapper_or_record_identity_refuses(self):
        conflicting = list(self.compiler)
        conflicting[conflicting.index("-target") + 1] = "arm64-apple-macos13.0"
        with self.assertRaisesRegex(E.EvidenceError, "Conflicting"):
            self.capture([conflicting])
        for key, value in (("module", "Other"), ("unitOutputIdentity", str(self.obj)), ("unitTargetTriple", "arm64-apple-ios13.0")):
            original = copy.deepcopy(self.snapshot)
            self.snapshot["snapshot"]["sourceRecordAdmissions"][0][key] = value
            with self.assertRaises(E.EvidenceError):
                self.capture()
            self.snapshot = original

    def test_compiled_package_without_native_live_contribution_is_unknown(self):
        self.native_map.write_bytes(self.map_bytes(self.native, [self.other]))
        with self.assertRaisesRegex(E.EvidenceError, "no positive"):
            self.capture()

    def test_missing_and_duplicate_record_never_use_unit_name_as_freshness(self):
        original = self.record.read_bytes()
        self.record.unlink()
        with self.assertRaisesRegex(E.EvidenceError, "record is absent"):
            self.capture()
        self.record.write_bytes(original)
        self.write(self.store / "v5/records/CD" / self.record.name, original)
        with self.assertRaisesRegex(E.EvidenceError, "Ambiguous index"):
            self.capture()

    def test_multiple_actual_units_for_one_source_are_not_collapsed(self):
        additional = copy.deepcopy(self.snapshot["snapshot"]["sourceRecordAdmissions"][0])
        additional["unit"] = "OtherUnit.o-UNIT"
        self.snapshot["snapshot"]["sourceRecordAdmissions"].append(additional)
        with self.assertRaisesRegex(E.EvidenceError, "contexts are shared or ambiguous"):
            self.capture()

    def test_nested_response_and_malformed_map_refuse(self):
        self.response.write_text("@nested.resp")
        with self.assertRaisesRegex(E.EvidenceError, "Nested"):
            self.capture()
        self.response.write_text("-lswiftCore")
        with self.native_map.open("ab") as stream:
            stream.write(b"unknown symbol line\n")
        with self.assertRaisesRegex(E.EvidenceError, "Unparsed"):
            self.capture()

    def test_mtime_preserved_proof_mutation_changes_identity(self):
        import os
        proof = self.capture()
        stamp = self.record.stat().st_mtime_ns
        self.record.write_bytes(b"changed record bytes")
        os.utime(self.record, ns=(stamp, stamp))
        current = self.capture()
        self.assertNotEqual(proof["files"][str(self.record)], current["files"][str(self.record)])
        files = E.Files(self.build, self.store)
        files.read(str(self.obj), "object")
        self.obj.write_bytes(b"changed object bytes")
        with self.assertRaisesRegex(E.EvidenceError, "changed"):
            files.finish()


if __name__ == "__main__":
    unittest.main()
