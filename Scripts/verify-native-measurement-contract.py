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

    def install_report(self):
        return dict(
            version="1",
            pip_version="26.2.1",
            environment={"SYNTHETIC_PRIVATE_FIELD": "not published"},
            install=[
                dict(
                    download_info=dict(
                        url="https://files.pythonhosted.org/packages/aa/bb/"
                        + "c" * 60
                        + "/psutil-7.2.2-cp36-abi3-macosx_11_0_arm64.whl",
                        archive_info=dict(hash="sha256=" + "a" * 64, hashes={"sha256": "a" * 64}),
                    ),
                    is_direct=False,
                    is_yanked=False,
                    requested=True,
                    metadata=dict(
                        name="psutil",
                        version="7.2.2",
                        author_email="maintainer@example.invalid",
                        description="SYNTHETIC_PRIVATE_DESCRIPTION",
                    ),
                )
            ],
        )

    def write_install_report(self, report):
        path = self.root / "raw/private-setup/install-report.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report))
        return path

    def test_pip_projection_retains_exact_provenance_and_omits_contact_metadata(self):
        path = self.write_install_report(self.install_report())
        raw = path.read_bytes()
        projected = MODULE.install_provenance(self.root / "raw")
        self.assertEqual(projected["raw_report"]["sha256"], MODULE.hashlib.sha256(raw).hexdigest())
        self.assertEqual(projected["raw_report"]["bytes"], len(raw))
        self.assertEqual(projected["distributions"][0]["sha256"], "a" * 64)
        self.assertEqual(projected["distributions"][0]["version"], "7.2.2")
        self.assertNotIn("maintainer@", json.dumps(projected))
        self.assertNotIn("SYNTHETIC_PRIVATE", json.dumps(projected))
        self.assertEqual(path.read_bytes(), raw)

    def test_pip_projection_rejects_wrong_package_version_hash_and_urls(self):
        changes = [
            ("name", "unexpected"),
            ("version", "7.2.3"),
            ("sha256", "z" * 64),
            ("url", "https://evil.invalid/psutil.whl"),
            ("url", "https://files.pythonhosted.org/pkg.whl?token=synthetic"),
            ("url", "https://user:secret@files.pythonhosted.org/pkg.whl"),
        ]
        for key, value in changes:
            report = self.install_report()
            entry = report["install"][0]
            if key in ("name", "version"):
                entry["metadata"][key] = value
            elif key == "sha256":
                entry["download_info"]["archive_info"]["hashes"][key] = value
            else:
                entry["download_info"][key] = value
            self.write_install_report(report)
            with self.assertRaises(ValueError):
                MODULE.install_provenance(self.root / "raw")

    def test_pip_projection_rejects_missing_duplicate_and_unexpected_distribution(self):
        for count in [0, 2]:
            report = self.install_report()
            report["install"] = report["install"] * count
            self.write_install_report(report)
            with self.assertRaises(ValueError):
                MODULE.install_provenance(self.root / "raw")
        path = self.write_install_report(self.install_report())
        path.write_text(path.read_text().replace('"version": "1"', '"version": "2", "version": "1"', 1))
        with self.assertRaises(ValueError):
            MODULE.install_provenance(self.root / "raw")

    def test_pip_projection_rejects_schema_flags_and_inconsistent_hash(self):
        for kind in ["report", "entry", "hash", "flags", "missing-hash"]:
            report = self.install_report()
            entry = report["install"][0]
            if kind == "report":
                report["version"] = "2"
            elif kind == "entry":
                entry["unknown"] = True
            elif kind == "hash":
                entry["download_info"]["archive_info"]["hash"] = "sha256=" + "b" * 64
            elif kind == "flags":
                entry["is_yanked"] = True
            else:
                del entry["download_info"]["archive_info"]["hashes"]["sha256"]
            self.write_install_report(report)
            with self.assertRaises(ValueError):
                MODULE.install_provenance(self.root / "raw")

    def test_projection_failure_prevents_next_phase_and_retains_install_cost(self):
        calls = []

        def installed(argv, cwd, stem, environment, timeout):
            calls.append(argv)
            report_path = MODULE.Path(argv[argv.index("--report") + 1])
            report_path.write_text('{"version": "unsupported"}')
            return dict(passed=True, completed=True, returncode=0, wall_seconds=0.25)

        with mock.patch.object(MODULE.sys, "platform", "darwin"), mock.patch.object(MODULE, "command", installed):
            result = MODULE.validate(self.root / "raw", self.root / "deps")
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["failed_phase"], "install-provenance")
        self.assertEqual(result["phases"]["install"]["wall_seconds"], 0.25)
        self.assertGreater(result["install_provenance_wall_seconds"], 0)
        self.assertTrue((self.root / "raw/setup/install-report-retention.json").exists())

    def test_private_report_is_excluded_but_derived_provenance_is_normalized(self):
        report = self.install_report()
        report["install"][0]["metadata"]["GITHUB_TOKEN"] = "synthetic credential-shaped metadata"
        path = self.write_install_report(report)
        before = path.read_bytes()
        MODULE.install_provenance(self.root / "raw")
        MODULE.save(self.root / "raw/results.json", dict(status="synthetic-projection-test"))
        spec = importlib.util.spec_from_file_location(
            "normalizer_projection", ROOT / "Scripts/normalize-indexstore-evidence.py"
        )
        normalizer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(normalizer)
        args = normalizer.argparse.Namespace(input=self.root / "raw", output=self.root / "public", prefix=[])
        manifest = normalizer.package(args)
        selected = {entry["path"] for entry in manifest["files"]}
        self.assertIn("setup/install-provenance.json", selected)
        self.assertIn("setup/install-report-retention.json", selected)
        self.assertNotIn("private-setup/install-report.json", selected)
        public = (self.root / "public/setup/install-provenance.json").read_text()
        for private in ["maintainer@", "SYNTHETIC_PRIVATE", "GITHUB_TOKEN", "synthetic credential"]:
            self.assertNotIn(private, public)
        self.assertEqual(path.read_bytes(), before)

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
