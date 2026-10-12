"""격리 시작과 실제 사전 기록 실패가 안전한 외부 영수증까지 전달되는지 검증한다."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import correctness_controller as controller
import attempt_receipts

ROOT = Path(__file__).resolve().parent


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.args = argparse.Namespace(
            repository=self.root / "repository",
            lifecycle=self.root / "lifecycle/results.json",
            setup=self.root / "tools/results.json",
            measurement=self.root / "measurement/results.json",
            scratch_root=self.root,
        )
        self.args.repository.mkdir()
        self.env = dict(os.environ, RUNNER_TEMP=str(self.root))
        self.command = [sys.executable, "-I", "-S", "-B", str(ROOT / "correctness_controller.py")]
        for name in ["repository", "lifecycle", "setup", "measurement", "scratch_root"]:
            self.command += ["--" + name.replace("_", "-"), str(getattr(self.args, name))]

    def invoke(self):
        return subprocess.run(self.command, env=self.env, capture_output=True, text=True, timeout=15)

    def test_isolated_controller_starts_without_ambient_psutil_or_import_paths(self):
        poison = self.root / "poison"
        poison.mkdir()
        (poison / "psutil.py").write_text("raise RuntimeError('ambient import')")
        command = [
            sys.executable,
            "-I",
            "-S",
            "-B",
            "-c",
            f"import sys;sys.path.insert(0,{str(ROOT)!r});import correctness_controller;assert 'psutil' not in sys.modules;print('stdlib preparation only')",
        ]
        result = subprocess.run(
            command, env=dict(self.env, PYTHONPATH=str(poison)), capture_output=True, text=True, timeout=10
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stdlib preparation only", result.stdout)

    def test_missing_lifecycle_actual_cli_retains_failed_attempt_without_raw_output(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 1, result.stderr)
        attempt = self.root / "actual-arm-correctness-attempt"
        row = json.loads((attempt / "results.json").read_text())
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(row["observed_returncode"], 1)
        self.assertTrue(row["completed"])
        self.assertGreater(row["child_wall_seconds"], 0)
        self.assertGreaterEqual(row["supervisor_wall_seconds"], row["child_wall_seconds"])
        self.assertEqual(row["stderr"]["sha256"], hashlib.sha256((attempt / "process.stderr").read_bytes()).hexdigest())
        self.assertFalse((self.root / "actual-arm-correctness-raw").exists())

    def test_malformed_lifecycle_still_has_safe_original_attempt(self):
        self.args.lifecycle.parent.mkdir()
        self.args.lifecycle.write_text("{bad JSON")
        result = self.invoke()
        self.assertEqual(result.returncode, 1, result.stderr)
        row = json.loads((self.root / "actual-arm-correctness-attempt/results.json").read_text())
        self.assertEqual(row["observed_returncode"], 1)

    def test_nonobject_lifecycle_still_has_original_attempt(self):
        self.args.lifecycle.parent.mkdir()
        self.args.lifecycle.write_text("[]")
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        row = json.loads((self.root / "actual-arm-correctness-attempt/results.json").read_text())
        self.assertEqual(row["observed_returncode"], 1)

    def test_output_alias_into_inputs_is_refused_without_input_write(self):
        raw = self.root / "actual-arm-correctness-raw"
        raw.symlink_to(self.args.repository, target_is_directory=True)
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(list(self.args.repository.iterdir()), [])
        self.assertTrue((self.root / "actual-arm-correctness-attempt/results.json").is_file())

    def test_existing_attempt_is_not_overwritten(self):
        attempt = self.root / "actual-arm-correctness-attempt"
        attempt.mkdir()
        old = attempt / "old"
        old.write_bytes(b"retained")
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(old.read_bytes(), b"retained")
        self.assertFalse((attempt / "process.json").exists())

    def test_unverified_scratch_root_refuses_before_writes(self):
        self.env["RUNNER_TEMP"] = str(self.args.repository)
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.root / "actual-arm-correctness-attempt").exists())

    def test_large_and_nontext_logs_keep_whole_byte_identity(self):
        log = self.root / "log"
        data = b"X" * (4 * 1024**2 + 1) + b"\xff\xfe"
        log.write_bytes(data)
        row = attempt_receipts.log_identity(log)
        self.assertEqual(row, dict(status="available", bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))

    def test_historical_unavailable_log_is_not_upgraded_on_read(self):
        out = self.root / "out"
        err = self.root / "err"
        out.write_bytes(b"now readable")
        err.write_bytes(b"")
        receipt = dict(
            stdout=dict(status="unavailable", reason="input-changed-during-read"),
            stderr=attempt_receipts.log_identity(err),
        )
        before = json.loads(json.dumps(receipt))
        present = attempt_receipts.verify_historical_logs(receipt, dict(stdout=str(out), stderr=str(err)))
        self.assertEqual(receipt, before)
        self.assertEqual(present["stdout"]["status"], "available")

    def test_available_log_change_is_not_accepted(self):
        out = self.root / "out"
        err = self.root / "err"
        out.write_bytes(b"first")
        err.write_bytes(b"")
        receipt = dict(stdout=attempt_receipts.log_identity(out), stderr=attempt_receipts.log_identity(err))
        out.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            attempt_receipts.verify_historical_logs(receipt, dict(stdout=str(out), stderr=str(err)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
