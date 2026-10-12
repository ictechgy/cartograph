"""기존 단일 설치 앞뒤 인터프리터 정체성과 실패·비용 보존을 검증한다."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("installer_successor", Path(__file__).with_name("installer-successor.py"))
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallerIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.binary = self.root / "python-real"
        self.binary.write_bytes(b"synthetic interpreter content")
        self.alias = self.root / "python-selected"
        self.alias.symlink_to(self.binary)

    def capture(self):
        return installer.interpreter_observation(str(self.alias))

    def validate(self, command):
        with (
            mock.patch.object(installer.sys, "platform", "darwin"),
            mock.patch.object(installer.sys, "executable", str(self.alias)),
            mock.patch.object(installer, "helper_hashes", return_value={"synthetic": "a" * 64}),
            mock.patch.object(installer, "command", side_effect=command),
            mock.patch.object(installer, "install_provenance", return_value={"synthetic": True}),
            mock.patch.object(installer, "calibration_passed", return_value=True),
        ):
            return installer.validate(self.root / "evidence", self.root / "dependencies")

    @staticmethod
    def completed(argv, *args):
        return dict(command=argv, completed=True, passed=True, returncode=0, observed_returncode=0)

    def test_selected_alias_and_resolved_bytes_are_both_retained(self):
        row = self.capture()
        self.assertEqual(row["status"], "available")
        self.assertEqual(row["selected_path"], str(self.alias))
        self.assertEqual(row["resolved_path"], str(self.binary))
        self.assertEqual(row["sha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertEqual(row["bytes"], self.binary.stat().st_size)
        self.assertGreaterEqual(row["wall_seconds"], 0)

    def test_missing_target_failure_has_cost_without_partial_hash(self):
        self.binary.unlink()
        row = self.capture()
        self.assertEqual(row["status"], "unavailable")
        self.assertNotIn("sha256", row)
        self.assertGreaterEqual(row["wall_seconds"], 0)

    def test_fifo_target_refuses_without_blocking(self):
        self.binary.unlink()
        os.mkfifo(self.binary)
        row = self.capture()
        self.assertEqual(row["status"], "unavailable")
        self.assertLess(row["wall_seconds"], 1)

    def test_read_mutation_and_alias_retarget_are_refused(self):
        original = installer.os.read
        other = self.root / "other"
        other.write_bytes(self.binary.read_bytes())

        def read(fd, count):
            value = original(fd, count)
            if self.alias.resolve() == self.binary:
                self.alias.unlink()
                self.alias.symlink_to(other)
            return value

        with mock.patch.object(installer.os, "read", side_effect=read):
            row = self.capture()
        self.assertEqual(row["status"], "unavailable")
        self.assertEqual(row["failure"], "interpreter-changed-during-capture")
        self.assertNotIn("sha256", row)

    def test_success_has_one_install_and_equal_prospective_identity(self):
        calls = []

        def command(argv, *args):
            calls.append(argv)
            return self.completed(argv)

        row = self.validate(command)
        seal = row["install_interpreter"]
        self.assertEqual(row["status"], "completed-synthetic-native-validation")
        self.assertEqual(seal["status"], "matched")
        self.assertEqual(sum("pip" in argv for argv in calls), 1)
        self.assertEqual(len(calls), 4)
        self.assertEqual(seal["before"]["sha256"], seal["after"]["sha256"])
        self.assertIn("nested", seal["cost_accounting"])
        self.assertEqual(json.loads((self.root / "evidence/setup/install-interpreter.json").read_text()), seal)

    def test_replaced_interpreter_after_install_stops_next_phase(self):
        calls = []

        def command(argv, *args):
            calls.append(argv)
            self.binary.write_bytes(b"changed interpreter")
            return self.completed(argv)

        row = self.validate(command)
        self.assertEqual(len(calls), 1)
        self.assertEqual(row["install_interpreter"]["status"], "changed")
        self.assertEqual(row["phases"]["install"]["observed_returncode"], 0)
        self.assertEqual(row["failed_phase"], "install-interpreter")

    def test_completed_install_failure_still_gets_terminal_identity(self):
        calls = []

        def command(argv, *args):
            calls.append(argv)
            return dict(command=argv, completed=True, passed=False, returncode=9, observed_returncode=9)

        row = self.validate(command)
        self.assertEqual(len(calls), 1)
        self.assertEqual(row["install_interpreter"]["status"], "matched")
        self.assertEqual(row["phases"]["install"]["observed_returncode"], 9)
        self.assertEqual(row["failure"], "phase-failed")

    def test_incomplete_install_keeps_observation_unavailable_and_no_later_phase(self):
        calls = []

        def command(argv, *args):
            calls.append(argv)
            return dict(command=argv, completed=False, passed=False, returncode=125, observed_returncode=-15)

        row = self.validate(command)
        self.assertEqual(len(calls), 1)
        self.assertEqual(row["install_interpreter"]["status"], "incomplete")
        self.assertEqual(row["install_interpreter"]["after"]["failure"], "install-incomplete")
        self.assertEqual(row["phases"]["install"]["observed_returncode"], -15)

    def test_before_capture_failure_prevents_any_install(self):
        self.binary.unlink()
        calls = []
        row = self.validate(lambda *args: calls.append(args))
        self.assertEqual(calls, [])
        self.assertEqual(row["install_interpreter"]["status"], "unavailable")
        self.assertEqual(row["phases"], {})

    def test_actual_selected_python_is_read_without_executing_install(self):
        import sys

        row = installer.interpreter_observation(sys.executable)
        self.assertEqual(row["status"], "available")
        self.assertEqual(row["resolved_path"], str(Path(sys.executable).resolve()))

    def test_capture_interrupt_stays_incomplete_without_install(self):
        with mock.patch.object(installer.os, "read", side_effect=KeyboardInterrupt):
            row = self.validate(lambda *args: self.fail("Install must not start"))
        self.assertEqual(row["install_interpreter"]["status"], "incomplete")
        self.assertEqual(row["phases"], {})
        with (
            mock.patch.object(installer, "validate", return_value=row),
            mock.patch.object(installer.sys, "argv", ["installer", "--output", "raw", "--dependencies", "deps"]),
        ):
            self.assertEqual(installer.main(), 125)

    def test_content_mutation_during_read_does_not_publish_partial_hash(self):
        original = installer.os.read
        mutated = False

        def read(fd, count):
            nonlocal mutated
            value = original(fd, count)
            if not mutated:
                self.binary.write_bytes(b"changed on read")
                mutated = True
            return value

        with mock.patch.object(installer.os, "read", side_effect=read):
            row = self.capture()
        self.assertEqual(row["status"], "unavailable")
        self.assertNotIn("sha256", row)

    def test_failed_install_and_changed_identity_retain_original_exit(self):
        def command(argv, *args):
            self.binary.write_bytes(b"changed on failed install")
            return dict(command=argv, completed=True, passed=False, returncode=9, observed_returncode=9)

        row = self.validate(command)
        self.assertEqual(row["phases"]["install"]["observed_returncode"], 9)
        self.assertEqual(row["install_interpreter"]["status"], "changed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
