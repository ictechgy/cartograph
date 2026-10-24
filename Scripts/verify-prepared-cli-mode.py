#!/usr/bin/env python3
"""Verify admission/result state transitions without running a native compiler or tool."""
import copy
from contextlib import ExitStack, nullcontext, redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).with_name("benchmark-indexstore-cli.py")
SPEC = importlib.util.spec_from_file_location("prepared_cli_mode_test_driver", SCRIPT)
DRIVER = importlib.util.module_from_spec(SPEC)
# 이 회귀는 프로세스를 실행하지 않는다. Windows에서 import만 허용하고 POSIX 실행은 모의한다.
with patch.dict(sys.modules, {"resource": types.ModuleType("resource")}) if os.name == "nt" else nullcontext():
    SPEC.loader.exec_module(DRIVER)


class PreparedCLIModeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "results"
        self.admission_path = self.root / "admission.json"
        self.admission_path.write_text("{}")
        self.swiftc, self.library, self.candidate, self.comparator = [self.root / name for name in (
            "swiftc", "libIndexStore", "cartograph", "index-dump")]
        for item in (self.swiftc, self.library, self.candidate, self.comparator):
            item.write_bytes(item.name.encode())
            item.chmod(0o755)
        self.fixtures = self.root / "fixtures"
        for name in ("basic", "holdout"):
            (self.fixtures / name).mkdir(parents=True)
            (self.fixtures / name / "oracle.json").write_text("{}")
        self.compiler = {"version": "fixture Swift", "swiftc": str(self.swiftc), "library": str(self.library),
                         "library_sha256": DRIVER.sha256(self.library)}
        self.identity = {"swift_version": self.compiler["version"], "tools_sha256": {
            "swiftc": DRIVER.sha256(self.swiftc), "libIndexStore": DRIVER.sha256(self.library)}}
        self.value = {"status": "admitted-preparation-only", "toolchain": {"identity": self.identity},
                      "consumer": {"runner": "consumer-host", "admission_seconds": 1.5}}
        self.commands = [{"command": ["/producer/swift", "build", "--product", "index-dump"],
                          "cwd": "/producer/source", "returncode": 0, "timed_out": False, "wall_seconds": 12.5}]
        self.products = {}
        for role, binary in (("candidate", self.candidate), ("comparator", self.comparator)):
            self.products[role] = {"binary": str(binary), "binary_sha256": DRIVER.sha256(binary),
                "version": "fixture 1", "setup": {
                    "mode": "verified-prepared-artifact", "source": {"revision": DRIVER.REVISION},
                    "consumer_source": str(self.root / f"{role}-source"),
                    "producer_evidence": {"commands": copy.deepcopy(self.commands), "checkout": "/producer/source",
                                          "binary": "/producer/bin/index-dump"},
                    "producer": {"runner": "producer-host", "preparation_seconds": 15},
                    "admission": {"artifact_id": "123"}, "build_cost_measured": "producer-only"}}
        self.prepared = types.SimpleNamespace(
            read_admission=Mock(side_effect=lambda path: copy.deepcopy(self.value)),
            prepared_product=Mock(side_effect=lambda value, role: copy.deepcopy(self.products[role])))

    def invoke(self, extra=None, fixture=None, prepared=True):
        arguments = ["--output", str(self.output), "--fixtures", str(self.fixtures)]
        arguments += ["--prepared-tools", str(self.admission_path)] if prepared else []
        arguments += extra or []
        with ExitStack() as stack:
            stack.enter_context(redirect_stdout(io.StringIO()))
            stack.enter_context(redirect_stderr(io.StringIO()))
            self.loader = stack.enter_context(patch.object(DRIVER, "prepared_tools_module", return_value=self.prepared))
            self.compiler_read = stack.enter_context(patch.object(DRIVER, "toolchain", return_value=(
                self.swiftc, self.library, copy.deepcopy(self.compiler))))
            self.library_check = stack.enter_context(patch.object(DRIVER, "verify_cartograph_library", return_value={"checked": True}))
            self.fixture = stack.enter_context(patch.object(DRIVER, "fixture_run", side_effect=fixture,
                                                          return_value={"passed": True}))
            self.prepare_cli = stack.enter_context(patch.object(DRIVER, "prepare_cli", return_value=(
                self.comparator, {"revision": DRIVER.REVISION, "binary": str(self.comparator)})))
            self.prepare_product = stack.enter_context(patch.object(DRIVER, "prepare_cartograph",
                                                                   return_value={"binary": str(self.candidate)}))
            # 모의하지 않은 실제 프로세스 호출은 검증 실패다.
            stack.enter_context(patch.object(DRIVER, "run", side_effect=AssertionError("Unexpected native process")))
            code = DRIVER.main(arguments)
        return code, json.loads((self.output / "results.json").read_text())

    def test_prepared_mode_runs_both_fixtures_before_pass_and_preserves_producer_receipts(self):
        seen = []
        def fixture(args, source, cli, library, swiftc, root):
            seen.append(source.name)
            self.assertEqual(json.loads((root / "results.json").read_text())["status"], "running")
            self.assertEqual((args.cartograph, cli, library, swiftc),
                             (self.candidate, self.comparator, self.library, self.swiftc))
            return {"passed": True}
        code, result = self.invoke(fixture=fixture)
        self.assertEqual((code, result["status"], seen), (0, "passed", ["basic", "holdout"]))
        self.assertEqual(self.prepared.read_admission.call_count, 2)
        self.library_check.assert_called_once()
        self.prepare_cli.assert_not_called()
        self.prepare_product.assert_not_called()
        self.assertEqual(result["cartograph"]["setup"]["admission_path"], str(self.admission_path.resolve()))
        comparator = result["comparator_setup"]
        self.assertEqual(comparator["commands"], self.commands)
        self.assertEqual(comparator["build_evidence"], self.products["comparator"]["setup"]["producer_evidence"])
        self.assertEqual(comparator["checkout"], str(self.root / "comparator-source"))
        self.assertEqual(comparator["binary"], str(self.comparator))
        self.assertIn("producer", comparator["command_scope"])
        self.assertNotIn("total_measured_setup_seconds", comparator)
        self.assertEqual(result["toolchain_identity"], self.identity)
        self.assertIn("No single-host", result["measurement_contract"]["setup"])

    def test_preparation_alone_is_not_comparison_success(self):
        code, result = self.invoke(fixture=RuntimeError("fixture has not completed"))
        self.assertEqual((code, result["status"]), (2, "failed"))
        self.assertNotIn("correctness_and_freshness_passed", result)

    def test_fixture_failure_is_retained(self):
        code, result = self.invoke(fixture=[{"passed": True}, {"passed": False}])
        self.assertEqual((code, result["status"], result["correctness_and_freshness_passed"]), (1, "failed", False))

    def test_admission_rejection_does_not_run_fixtures_or_build(self):
        self.prepared.read_admission.side_effect = ValueError("Manifest bytes changed")
        code, result = self.invoke()
        self.assertEqual((code, result["status"]), (2, "blocked"))
        self.fixture.assert_not_called()
        self.prepare_cli.assert_not_called()
        self.prepare_product.assert_not_called()

    def test_post_comparison_revalidation_failure_is_not_passed(self):
        self.prepared.read_admission.side_effect = [copy.deepcopy(self.value), ValueError("Binary changed")]
        code, result = self.invoke()
        self.assertEqual((code, result["status"], self.fixture.call_count), (2, "failed", 2))

    def test_different_admission_after_comparison_is_not_passed(self):
        self.prepared.read_admission.side_effect = [copy.deepcopy(self.value), {**self.value, "changed": True}]
        code, result = self.invoke()
        self.assertEqual((code, result["status"]), (2, "failed"))

    def test_consumer_compiler_identity_must_match_admission(self):
        self.identity["tools_sha256"]["swiftc"] = "0" * 64
        code, result = self.invoke()
        self.assertEqual((code, result["status"]), (2, "blocked"))
        self.fixture.assert_not_called()

    def test_comparator_pin_must_match_existing_gate(self):
        self.products["comparator"]["setup"]["source"]["revision"] = "0" * 40
        code, result = self.invoke()
        self.assertEqual((code, result["status"]), (2, "blocked"))
        self.fixture.assert_not_called()

    def test_prepared_mode_rejects_conflicting_selection(self):
        for arguments in (["--baseline-only"], ["--cartograph", str(self.candidate)],
                          ["--cartograph-package", str(self.root)], ["--indexstore-checkout", str(self.root)],
                          ["--swiftc", str(self.swiftc)], ["--lib-index-store", str(self.library)]):
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit) as error:
                self.invoke(extra=arguments)
            self.assertEqual(error.exception.code, 2)
            self.loader.assert_not_called()
            self.assertFalse(self.output.exists())

    def test_legacy_modes_do_not_load_admission_or_change_setup_path(self):
        for index, arguments in enumerate((["--baseline-only"], ["--cartograph", str(self.candidate)],
                                            ["--cartograph-package", str(self.root)])):
            self.output = self.root / f"legacy-{index}"
            code, result = self.invoke(extra=arguments, prepared=False)
            self.assertEqual((code, result["status"]), (0, "baseline_only" if index == 0 else "passed"))
            self.loader.assert_not_called()
            self.prepare_cli.assert_called_once()
            self.assertEqual(self.prepare_product.call_count, 0 if index == 0 else 1)
            self.assertNotIn("toolchain_identity", result)


if __name__ == "__main__":
    unittest.main()
