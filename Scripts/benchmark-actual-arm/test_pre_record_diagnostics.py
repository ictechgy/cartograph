"""사전 기록 실패의 한정된 단계·이유만 원래 종료·로그 지문과 함께 보존한다."""

import json
import copy
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import attempt_receipts as receipts
import correctness_controller as controller


class PreRecordDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "stderr"

    def capture(self, value, code=1, observed=1, failure=None):
        self.log.write_text(json.dumps(value))
        return receipts.pre_record_diagnostic(
            dict(stderr=str(self.log), returncode=code, observed_returncode=observed, failure=failure),
            receipts.log_identity(self.log),
        )

    def test_controlled_reason_has_no_raw_exception_message(self):
        error = receipts.PreRecordFailure("installation-binding", ValueError("Prior interpreter spellings differ"))
        row = error.diagnostic
        self.assertEqual(row["reason"], "installation-interpreter-spelling-mismatch")
        self.assertIsNone(row["message_sha256"])
        self.assertEqual(self.capture(row), row)

    def test_unknown_private_or_credential_message_is_only_a_hash(self):
        message = '/private/person/file AWS_SECRET_ACCESS_KEY="synthetic-secret"'
        row = receipts.PreRecordFailure("state-inputs", ValueError(message)).diagnostic
        self.assertEqual(row["reason"], "unclassified-error")
        self.assertEqual(row["message_sha256"], receipts.sha(message.encode()))
        self.assertNotIn("synthetic", json.dumps(row))
        self.assertEqual(self.capture(row), row)

    def test_interrupt_keeps_reserved_incomplete_exit(self):
        error = receipts.PreRecordFailure("sdk-binding", KeyboardInterrupt())
        self.assertEqual(error.exit_code, 125)
        self.assertEqual(self.capture(error.diagnostic, 125, 125, "nested-incomplete"), error.diagnostic)

    def test_signal_timeout_and_contradictory_return_do_not_certify_diagnostic(self):
        row = receipts.PreRecordFailure("state-inputs", ValueError("private")).diagnostic
        for code, observed, failure in [(125, -15, "signal"), (125, -15, "timeout"), (0, 0, None), (1, 2, None)]:
            with self.subTest(code=code, observed=observed, failure=failure):
                self.assertIsNone(self.capture(row, code, observed, failure))

    def test_unknown_stage_reason_fields_and_boolean_exit_are_not_admitted(self):
        row = receipts.PreRecordFailure("state-inputs", ValueError("private")).diagnostic
        for changed in [
            dict(row, stage="/private/x"),
            dict(row, reason="GITHUB_TOKEN=x"),
            dict(row, extra="secret"),
            dict(row, exit_code=True),
            dict(row, schema_version=True),
            dict(row, message_sha256="short"),
        ]:
            with self.subTest(changed=changed):
                self.assertIsNone(self.capture(changed))

    def test_duplicate_keys_nontext_and_oversize_keep_unavailable_diagnostic(self):
        phase = dict(stderr=str(self.log), returncode=1, observed_returncode=1, failure=None)
        for data in [b'{"stage":"a","stage":"b"}', b"\xff", b"X" * 4097]:
            self.log.write_bytes(data)
            self.assertIsNone(receipts.pre_record_diagnostic(phase, receipts.log_identity(self.log)))

    def test_changed_or_historically_unavailable_log_cannot_upgrade(self):
        row = receipts.PreRecordFailure("state-inputs", ValueError("private")).diagnostic
        self.log.write_text(json.dumps(row))
        historic = receipts.log_identity(self.log)
        self.log.write_text(json.dumps(row) + " ")
        phase = dict(stderr=str(self.log), returncode=1, observed_returncode=1, failure=None)
        self.assertIsNone(receipts.pre_record_diagnostic(phase, historic))
        self.assertIsNone(receipts.pre_record_diagnostic(phase, dict(status="unavailable", reason="unreadable-input")))

    def test_preflight_wrap_retains_failure_and_does_not_retry(self):
        operation = mock.Mock(side_effect=ValueError("Prior interpreter spellings differ"))
        with self.assertRaises(receipts.PreRecordFailure) as caught:
            receipts.pre_record("installation-binding", operation, "same argument")
        operation.assert_called_once_with("same argument")
        self.assertEqual(caught.exception.exit_code, 1)
        self.assertEqual(caught.exception.diagnostic["stage"], "installation-binding")

    def test_successful_operation_is_unchanged_and_system_exit_is_not_swallowed(self):
        self.assertEqual(receipts.pre_record("state-inputs", lambda: 42), 42)
        with self.assertRaises(SystemExit):
            receipts.pre_record("state-inputs", mock.Mock(side_effect=SystemExit(9)))

    def test_public_envelope_reader_does_not_accept_legacy_generic_text_as_stage(self):
        self.assertIsNone(self.capture(dict(status="refused-before-record", failure="ValueError")))


class PrivateEnvironmentDiagnosticTests(unittest.TestCase):
    setUp = PreRecordDiagnosticsTests.setUp
    capture = PreRecordDiagnosticsTests.capture

    # 기존 계약을 재실행하지 않고 새 공개 진단만 독립적으로 검사한다.
    def expected(self):
        return {key: "synthetic-private-value" for key in receipts.EXPECTED_ENVIRONMENT_KEYS}

    def row(self, actual=None):
        expected = self.expected()
        actual = dict(expected, LC_CTYPE="synthetic-locale") if actual is None else actual
        return receipts.PreRecordFailure(
            "selected-launch", receipts.PrivateEnvironmentMismatch(expected, actual)
        ).diagnostic

    def test_missing_changed_and_extra_are_fixed_identifiers_only(self):
        actual = self.expected()
        del actual["HOME"]
        actual["TMPDIR"] = "/private/person/secret"
        actual["unknown-secret-key"] = "AWS_SECRET_ACCESS_KEY=synthetic-secret"
        row = self.row(actual)
        diff = row["environment_difference"]
        self.assertEqual(diff["missing_expected_keys"], ["home-directory"])
        self.assertEqual(diff["changed_expected_keys"], ["temporary-directory"])
        self.assertEqual(diff["extra_key_count"], 1)
        self.assertEqual(diff["extra_key_names_sha256"], receipts.sha(b'["unknown-secret-key"]'))
        self.assertEqual(diff["known_extra_keys"], [])
        self.assertNotIn("secret", json.dumps(row))
        self.assertEqual(self.capture(row), row)

    def test_predefined_startup_candidates_never_publish_values(self):
        actual = dict(
            self.expected(), LC_CTYPE="private", __CF_USER_TEXT_ENCODING="private", __PYVENV_LAUNCHER__="private"
        )
        diff = self.row(actual)["environment_difference"]
        self.assertEqual(diff["extra_key_count"], 3)
        self.assertEqual(diff["known_extra_keys"], sorted(receipts.KNOWN_STARTUP_KEYS.values()))
        self.assertNotIn("private", json.dumps(diff))

    def test_unknown_key_hash_order_is_deterministic(self):
        left = self.row(dict(self.expected(), z="one", a="two"))
        right = self.row(dict(self.expected(), a="changed-value", z="different-value"))
        self.assertEqual(left, right)
        self.assertEqual(left["environment_difference"]["extra_key_names_sha256"], receipts.sha(b'["a","z"]'))

    def test_summary_requires_exact_stage_reason_and_value_error(self):
        row = self.row()
        for changes in [
            dict(stage="installation-binding"),
            dict(reason="unclassified-error", message_sha256="a" * 64),
            dict(failure="RuntimeError"),
        ]:
            self.assertIsNone(self.capture(dict(row, **changes)))

    def test_summary_rejects_unknown_identifiers_values_duplicates_and_boolean_counts(self):
        row = self.row()
        for changes in [
            dict(missing_expected_keys=["/private/secret"]),
            dict(changed_expected_keys=["home-directory", "home-directory"]),
            dict(known_extra_keys=["AWS_SECRET_ACCESS_KEY"]),
            dict(extra_key_count=True),
            dict(extra_key_count=0),
            dict(extra_key_names_sha256="short"),
            dict(raw_value="secret"),
        ]:
            changed = copy.deepcopy(row)
            changed["environment_difference"].update(changes)
            self.assertIsNone(self.capture(changed))

    def test_equal_environment_cannot_be_a_mismatch_summary(self):
        with self.assertRaisesRegex(ValueError, "Environment mismatch diagnostic requires a difference"):
            receipts.PrivateEnvironmentMismatch(self.expected(), self.expected())

    def test_unknown_expected_schema_is_not_published(self):
        with self.assertRaisesRegex(ValueError, "Fixed private environment schema differs"):
            receipts.PrivateEnvironmentMismatch({"private-key": "private"}, {})

    def test_actual_isolated_startup_observation_is_hash_only(self):
        expected = self.expected()
        expected.update(
            PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C", TZ="UTC", PYTHONDONTWRITEBYTECODE="1"
        )
        code = "import json,os,sys;sys.path.insert(0,sys.argv[1]);import attempt_receipts as r;expected=json.load(sys.stdin);print(json.dumps(r.environment_difference(expected,dict(os.environ)),sort_keys=True))"
        result = subprocess.run(
            [sys.executable, "-I", "-S", "-B", "-c", code, str(Path(receipts.__file__).parent)],
            input=json.dumps(expected),
            env=expected,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        diff = json.loads(result.stdout)
        self.assertEqual(diff["missing_expected_keys"], [])
        self.assertEqual(diff["changed_expected_keys"], [])
        self.assertNotIn("synthetic-private-value", result.stdout)
        self.assertIs(type(diff["extra_key_count"]), int)


if __name__ == "__main__":
    unittest.main(verbosity=2)
