"""사전 기록 실패의 한정된 단계·이유만 원래 종료·로그 지문과 함께 보존한다."""

import json
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
