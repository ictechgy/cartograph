#!/usr/bin/env python3
"""네이티브 측정 진단의 범위·실패 보존·공개 업로드 계약을 검증한다."""

from __future__ import annotations
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("native_diagnostic", ROOT / "Scripts/validate-native-measurement.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DiagnosticContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_plan_freezes_small_synthetic_scope_and_distinct_modes(self):
        plan = MODULE.plan()
        self.assertEqual(plan["pairs_per_workload_mode"], 4)
        self.assertEqual(plan["randomization_seed"], 20261012)
        self.assertFalse(plan["final_comparison"])
        self.assertIn("moving", plan["runner_regime"])

    def test_non_macos_is_rejected_before_creating_output(self):
        output = self.root / "raw"
        with mock.patch.object(MODULE.sys, "platform", "linux"):
            with self.assertRaisesRegex(ValueError, "native macOS"):
                MODULE.validate(output, self.root / "deps")
        self.assertFalse(output.exists())

    def test_command_failure_retains_all_output_and_cost(self):
        row = MODULE.command(
            [sys.executable, "-c", "print('synthetic failure'); raise SystemExit(7)"],
            self.root,
            self.root / "failure",
            {},
            5,
        )
        self.assertEqual(row["returncode"], 7)
        self.assertFalse(row["passed"])
        self.assertTrue(row["completed"])
        self.assertGreater(row["wall_seconds"], 0)
        self.assertIn("synthetic failure", (self.root / "failure.stdout").read_text())

    def test_timeout_is_incomplete_and_retains_partial_output(self):
        row = MODULE.command(
            [sys.executable, "-u", "-c", "import time; print('partial'); time.sleep(5)"],
            self.root,
            self.root / "timeout",
            {},
            0.1,
        )
        self.assertFalse(row["completed"])
        self.assertEqual(row["returncode"], 125)
        self.assertFalse(row["descendant_cleanup_verified"])
        self.assertIn("partial", (self.root / "timeout.stdout").read_text())
        self.assertEqual(row["observed_returncode"], -MODULE.signal.SIGTERM)
        self.assertEqual(row["cleanup_signals"], ["term-sent"])

    def test_failed_phase_stops_later_launches_and_never_claims_native_proof(self):
        output = self.root / "raw"
        calls = []

        def failed(argv, cwd, stem, environment, timeout):
            calls.append(argv)
            return dict(passed=False, completed=True, returncode=1, wall_seconds=0.3)

        with mock.patch.object(MODULE.sys, "platform", "darwin"), mock.patch.object(MODULE, "command", failed):
            result = MODULE.validate(output, self.root / "deps")
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["status"], "failed")
        self.assertFalse(result["final_comparison"])
        self.assertEqual(result["failed_phase"], "install")
        self.assertTrue((output / "results.json").exists())
        self.assertTrue((output / "runs").is_dir())

    def test_nonempty_evidence_is_never_overwritten(self):
        output = self.root / "raw"
        output.mkdir()
        (output / "old.json").write_text("{}")
        with mock.patch.object(MODULE.sys, "platform", "darwin"):
            with self.assertRaises(ValueError):
                MODULE.validate(output, self.root / "deps")
        self.assertEqual((output / "old.json").read_text(), "{}")

    def test_signal_and_launch_failures_remain_incomplete(self):
        commands = [
            [sys.executable, "-c", "import os,signal; os.kill(os.getpid(),signal.SIGTERM)"],
            [str(self.root / "missing-program")],
        ]
        for number, argv in enumerate(commands):
            row = MODULE.command(argv, self.root, self.root / f"incomplete-{number}", {}, 2)
            self.assertEqual(row["returncode"], 125)
            self.assertFalse(row["completed"])

    def test_nested_incomplete_exit_stops_later_phases_and_preserves_raw_code(self):
        actual_command = MODULE.command
        calls = []

        def nested_incomplete(argv, cwd, stem, environment, timeout):
            calls.append(argv)
            return actual_command([sys.executable, "-c", "raise SystemExit(125)"], cwd, stem, environment, timeout)

        with mock.patch.object(MODULE.sys, "platform", "darwin"), mock.patch.object(
            MODULE, "command", nested_incomplete
        ):
            result = MODULE.validate(self.root / "raw", self.root / "deps")
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["failed_phase"], "install")
        row = result["phases"]["install"]
        self.assertFalse(row["completed"])
        self.assertEqual(row["returncode"], 125)
        self.assertEqual(row["observed_returncode"], 125)
        self.assertEqual(row["failure"], "nested-incomplete")

    def test_signal_retains_original_negative_return_code(self):
        row = MODULE.command(
            [sys.executable, "-c", "import os,signal; os.kill(os.getpid(),signal.SIGTERM)"],
            self.root,
            self.root / "signal",
            {},
            2,
        )
        self.assertEqual(row["returncode"], 125)
        self.assertEqual(row["observed_returncode"], -MODULE.signal.SIGTERM)
        self.assertEqual(row["failure"], "signal")

    def test_existing_command_evidence_is_unchanged(self):
        (self.root / "old.json").write_text("retained")
        with self.assertRaises(ValueError):
            MODULE.command([sys.executable, "-c", "pass"], self.root, self.root / "old", {}, 1)
        self.assertEqual((self.root / "old.json").read_text(), "retained")
        self.assertFalse((self.root / "old.stdout").exists())

    def test_log_references_are_exact_absolute_paths_for_nested_normalization(self):
        row = MODULE.command([sys.executable, "-c", "pass"], self.root, self.root / "logs", {}, 2)
        self.assertEqual(row["stdout"], str((self.root / "logs.stdout").resolve()))
        self.assertEqual(row["stderr"], str((self.root / "logs.stderr").resolve()))

    def test_calibration_requires_complete_balanced_successful_groups(self):
        output = self.root / "raw"
        directory = output / "runs/calibration"
        directory.mkdir(parents=True)
        (directory / "plan.json").write_text("{}")
        summary = dict(
            all_outputs_agree=True,
            plan_sha256=MODULE.hashlib.sha256(b"{}").hexdigest(),
            groups=[
                dict(workload=w, mode=m, pair_count=4, AB_count=2, BA_count=2, failed_pairs=[])
                for w in ["one_sustained_process", "twelve_cli_subprocesses"]
                for m in ["timing", "memory"]
            ],
        )
        path = directory / "summary.json"
        path.write_text(json.dumps(summary))
        self.assertTrue(MODULE.calibration_passed(output, MODULE.plan()))
        summary["groups"][0]["failed_pairs"] = [1]
        path.write_text(json.dumps(summary))
        self.assertFalse(MODULE.calibration_passed(output, MODULE.plan()))
        summary["groups"].pop()
        path.write_text(json.dumps(summary))
        self.assertFalse(MODULE.calibration_passed(output, MODULE.plan()))

    def test_package_source_is_official_and_private_environment_is_not_persisted(self):
        secret = "SYNTHETIC_PRIVATE_ENVIRONMENT_VALUE"

        def failed(argv, cwd, stem, environment, timeout):
            self.assertNotIn("PIP_EXTRA_INDEX_URL", environment)
            self.assertEqual(environment["PIP_CONFIG_FILE"], MODULE.os.devnull)
            self.assertEqual(argv[argv.index("--index-url") + 1], "https://pypi.org/simple")
            return dict(passed=False, completed=True, returncode=1, wall_seconds=0.1)

        with mock.patch.object(MODULE.sys, "platform", "darwin"), mock.patch.dict(
            MODULE.os.environ, {"PIP_EXTRA_INDEX_URL": secret}
        ), mock.patch.object(MODULE, "command", failed):
            MODULE.validate(self.root / "raw", self.root / "deps")
        self.assertNotIn(secret, (self.root / "raw/results.json").read_text())

    def test_interrupt_is_an_incomplete_retained_command(self):
        with mock.patch.object(MODULE.subprocess, "Popen", side_effect=KeyboardInterrupt):
            row = MODULE.command(["synthetic"], self.root, self.root / "interrupted", {}, 2)
        self.assertEqual(row["failure"], "interrupt")
        self.assertEqual(row["returncode"], 125)
        self.assertFalse(row["completed"])

    def test_workflow_has_separate_normalized_ready_gated_artifact(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("name: Validate native measurement helpers", workflow)
        self.assertLess(
            workflow.index("name: Validate fresh shared compiler generations for mixed iOS"),
            workflow.index("name: Validate native measurement helpers"),
        )
        self.assertIn("steps.measurement_normalize.outcome == 'success'", workflow)
        self.assertIn("name: measurement-helper-validation", workflow)
        self.assertIn("path: ${{ runner.temp }}/measurement-helper-public/", workflow)
        self.assertNotIn("path: ${{ runner.temp }}/measurement-helper-raw/", workflow)


if __name__ == "__main__":
    unittest.main()
