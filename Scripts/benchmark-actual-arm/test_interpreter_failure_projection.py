"""자식 실행 없이 실패 진단·요청 결합·공개 투영의 반대 방향 대조군을 고정한다."""

import argparse
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import correctness_controller as controller
import attempt_receipts as receipts
import installation_binding as installation
import profile_collection as collection
import publish_correctness as publication
import selected_launch
import startup_profile as probe


def mismatch():
    return receipts.InterpreterSpellingMismatch(
        "install",
        "/private/requested-python",
        "/private/reported-python",
        "a" * 64,
        dict(status="observed-at-failure", equal=True),
    )


class InterpreterDiagnosticTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.stderr = self.root / "stderr"

    def capture(self, row, *, historical=None, code=1):
        self.stderr.write_text(json.dumps(row))
        phase = dict(stderr=str(self.stderr), returncode=code, observed_returncode=code, failure=None)
        return receipts.pre_record_diagnostic(phase, historical or receipts.log_identity(self.stderr))

    def row(self):
        return receipts.PreRecordFailure("selected-launch", mismatch()).diagnostic

    def test_typed_failure_stays_value_error_and_hash_only(self):
        row = self.row()
        self.assertEqual(row["failure"], "ValueError")
        self.assertEqual(row["reason"], "installation-interpreter-spelling-mismatch")
        self.assertEqual(row["interpreter_spelling"]["phase"], "install")
        self.assertEqual(self.capture(row), row)
        self.assertNotIn("/private", json.dumps(row))
        self.assertLess(len(json.dumps(row).encode()), 4096)
        publication.NORMALIZER.check_sensitive(json.dumps(row), "typed-interpreter.json")

    def test_extension_requires_matching_stage_reason_value_error_exit(self):
        row = self.row()
        for changed in [
            dict(row, stage="state-inputs"),
            dict(row, reason="selected-launch-request-changed"),
            dict(row, failure="RuntimeError"),
            dict(row, failure="KeyboardInterrupt", exit_code=125),
            dict(row, exit_code=True),
        ]:
            with self.subTest(changed=changed):
                self.assertIsNone(self.capture(changed, code=125 if changed["exit_code"] == 125 else 1))
        self.assertEqual(self.capture(dict(row, stage="installation-binding"))["failure"], "ValueError")

    def test_fields_phases_hashes_and_physical_state_are_strict(self):
        row = self.row()
        for changes in [
            dict(phase="/private/arbitrary-phase"),
            dict(schema_version=True),
            dict(measurement_sha256="short"),
            dict(phase_command_spelling_sha256=row["interpreter_spelling"]["interpreter_spelling_sha256"]),
            dict(physical_identity=dict(status="observed-at-failure", equal=1)),
            dict(physical_identity=dict(status="unavailable", equal=True)),
            dict(selected_request=dict(status="bound-request", mode="one-exec", request_sha256="a" * 64)),
            dict(raw_interpreter="/private/secret"),
        ]:
            changed = copy.deepcopy(row)
            changed["interpreter_spelling"].update(changes)
            with self.subTest(changes=changes):
                self.assertIsNone(self.capture(changed))

    def test_historical_unavailable_and_changed_log_never_upgrade(self):
        row = self.row()
        self.assertIsNone(self.capture(row, historical=dict(status="unavailable", reason="unreadable-input")))
        self.stderr.write_text(json.dumps(row) + " ")
        prior = receipts.log_identity(self.stderr)
        self.assertIsNone(self.capture(row, historical=prior))

    def test_plain_historical_reason_does_not_gain_new_payload(self):
        old = receipts.PreRecordFailure("selected-launch", ValueError("Prior interpreter spellings differ")).diagnostic
        self.assertNotIn("interpreter_spelling", self.capture(old))

    def test_missing_physical_observation_is_typed_unavailable(self):
        observed = dict(selected_path="/private/a", resolved_path="/private/physical", sha256="b" * 64)
        for values, count in [(OSError("private-first"), 1), ([observed, OSError("private-second")], 2)]:
            with self.subTest(executable=count), mock.patch.object(probe, "interpreter", side_effect=values) as read:
                error = installation.spelling_failure("install", "/private/a", "/private/b", "a" * 64)
            self.assertEqual(read.call_count, count)
            self.assertEqual(
                error.summary["physical_identity"],
                dict(status="unavailable", reason="interpreter-identity-not-observed"),
            )
            self.assertEqual(str(error), "Prior interpreter spellings differ")
            self.assertNotIn("private", json.dumps(error.summary))
            row = receipts.PreRecordFailure("selected-launch", error).diagnostic
            self.assertEqual(row["failure"], "ValueError")
            self.assertEqual(row["reason"], "installation-interpreter-spelling-mismatch")
            self.assertEqual(row["exit_code"], 1)
            self.assertEqual(self.capture(row), row)

    def test_unequal_physical_identity_is_observed_without_changing_refusal(self):
        left = dict(selected_path="/private/a", resolved_path="/private/a", sha256="a" * 64)
        right = dict(selected_path="/private/b", resolved_path="/private/b", sha256="b" * 64)
        with mock.patch.object(probe, "interpreter", side_effect=[left, right]):
            error = installation.spelling_failure("tests", "/private/a", "/private/b", "a" * 64)
        self.assertEqual(error.summary["physical_identity"], dict(status="observed-at-failure", equal=False))
        self.assertIsInstance(error, ValueError)

    def test_original_equality_predicate_still_refuses_same_physical_alias(self):
        phase = dict(
            command=["/private/requested-python"],
            completed=True,
            passed=True,
            returncode=0,
            observed_returncode=0,
            failure=None,
            cleanup_root_unfinished=False,
            cleanup_signals=[],
            wall_seconds=1.0,
        )
        measurement = dict(
            status="completed-synthetic-native-validation",
            final_comparison=False,
            phases={name: copy.deepcopy(phase) for name in sorted(receipts.HELPER_PHASES)},
        )
        path = self.root / "measurement.json"
        path.write_text(json.dumps(measurement))
        identity = dict(selected_path="ignored", resolved_path="/private/same", sha256="b" * 64)
        with mock.patch.object(probe, "interpreter", return_value=identity), self.assertRaises(
            receipts.InterpreterSpellingMismatch
        ) as caught:
            installation.bind(path, self.root, Path("/private/reported-python"))
        self.assertEqual(caught.exception.summary["physical_identity"], dict(status="observed-at-failure", equal=True))
        self.assertEqual(caught.exception.summary["measurement_sha256"], receipts.sha(path.read_bytes()))
        self.assertEqual(caught.exception.summary["phase"], "calibration")


class SelectedRequestDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.sources = {"/private/source.py": "b" * 64}
        self.args = argparse.Namespace(
            measurement=Path("/private/measurement"), repository=Path("/private/repo"), selected_launch_sha256=None
        )
        self.projected = dict(
            status="bound-request",
            mode="direct",
            request_sha256="c" * 64,
            source_inputs_sha256=probe.sha(probe.encoded(self.sources)),
        )

    def capture(self, projected=None, side_effect=None):
        error = mismatch()
        with mock.patch.object(installation, "bind", side_effect=error) as binding, mock.patch.object(
            selected_launch, "request_projection", return_value=projected or self.projected, side_effect=side_effect
        ), self.assertRaises(receipts.InterpreterSpellingMismatch) as caught:
            selected_launch.bind_current(
                self.args, Path("/private/root"), Path("/private/reported-python"), lambda: self.sources
            )
        binding.assert_called_once()
        self.assertIs(caught.exception, error)
        return error.summary["selected_request"]

    def test_direct_and_one_exec_bind_exact_request_without_retry(self):
        self.assertEqual(self.capture(), self.projected)
        self.args.selected_launch_sha256 = "c" * 64
        expected = dict(self.projected, mode="one-exec")
        self.assertEqual(self.capture(expected), expected)

    def test_wrong_marker_and_wrong_mode_do_not_certify_context(self):
        for marker, mode in [("d" * 64, "one-exec"), ("c" * 64, "direct"), (None, "one-exec")]:
            with self.subTest(marker=marker, mode=mode):
                self.args.selected_launch_sha256 = marker
                self.assertEqual(self.capture(dict(self.projected, mode=mode)), receipts.unavailable_selected_request())

    def test_missing_or_invalid_request_keeps_original_failure_unavailable(self):
        for error in [FileNotFoundError("private"), ValueError("Selected launch source changed")]:
            self.assertEqual(self.capture(side_effect=error), receipts.unavailable_selected_request())

    def test_request_projection_revalidates_installation_and_request(self):
        request = dict(mode="one-exec")
        reference = dict(sha256="c" * 64)
        with mock.patch.object(
            selected_launch, "paths", return_value=(Path("request"), Path("observation"))
        ), mock.patch.object(selected_launch, "read", return_value=(request, reference)), mock.patch.object(
            selected_launch, "selected_binding", return_value=(Path("selected"), "binding")
        ) as bind, mock.patch.object(
            selected_launch, "validate_request"
        ) as validate:
            row = selected_launch.request_projection(self.args, Path("root"), self.sources)
            bind.assert_called_once_with(self.args)
            validate.assert_called_once_with(self.args, request, "binding", self.sources)
            self.assertEqual(row["mode"], "one-exec")
            validate.side_effect = ValueError("Selected launch source changed")
            with self.assertRaises(ValueError):
                selected_launch.request_projection(self.args, Path("root"), self.sources)

    def test_mode_is_not_inferred_when_only_hash_and_missing_observation_exist(self):
        args = argparse.Namespace()

        def reference(path):
            if str(path).endswith("selected-launch-request.json"):
                return dict(sha256="c" * 64)
            if str(path).endswith("startup-profile/results.json"):
                return dict(sha256="e" * 64)
            raise FileNotFoundError()

        with mock.patch.object(publication.state_inputs, "reference", side_effect=reference), mock.patch.object(
            selected_launch, "verify", side_effect=FileNotFoundError()
        ), mock.patch.object(selected_launch, "request_projection", side_effect=ValueError()), mock.patch.object(
            controller, "source_hashes", return_value=self.sources
        ):
            row = publication.selected_launch_summary(args, Path("/private/attempt"), self.sources)
        self.assertEqual(row["status"], "unavailable")
        self.assertEqual(row["request_sha256"], "c" * 64)
        self.assertIsNone(row["observation_sha256"])
        self.assertEqual(row["request_projection"], receipts.unavailable_selected_request())
        self.assertNotIn("mode", row)


class ProbeProjectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.path = self.root / "results.json"
        self.folder = self.root / "spelling-0001"
        self.folder.mkdir()
        self.sources = {"/private/bound-source.py": "f" * 64}
        self.environment = dict(probe.FIXED, HOME=str(self.root), TMPDIR=str(self.root), XDG_CACHE_HOME=str(self.root))
        environment = probe.environment_request(self.environment)
        interpreter = dict(
            selected_path="/private/requested-python",
            resolved_path="/private/physical-python",
            bytes=19,
            sha256="a" * 64,
            metadata=[1, 2, 3, 19, 5, 6],
        )
        self.request = dict(
            environment=environment,
            interpreter=interpreter,
            source_inputs={name: dict(sha256=value) for name, value in self.sources.items()},
        )
        self.request_path = self.folder / "request.json"
        self.report = self.folder / "observation.json"
        self.request_path.write_bytes(probe.encoded(self.request) + b"\n")
        request_hash = probe.sha(self.request_path.read_bytes())
        argv = [
            interpreter["selected_path"],
            "-I",
            "-S",
            "-B",
            str(Path(probe.__file__).resolve()),
            "--request",
            str(self.request_path),
            "--sha256",
            request_hash,
            "--report",
            str(self.report),
        ]
        phase = dict(
            command=argv,
            cwd=str(self.root),
            completed=True,
            passed=True,
            returncode=0,
            observed_returncode=0,
            stdout=str(self.folder / "process.stdout"),
            stderr=str(self.folder / "process.stderr"),
            wall_seconds=1.0,
        )
        (self.folder / "process.json").write_bytes(probe.encoded(phase))
        for kind in ["stdout", "stderr"]:
            (self.folder / ("process." + kind)).write_bytes(b"")
        early = probe.observe_request(environment, self.environment, platform="linux")
        observed = dict(
            schema_version=1,
            role="prospective-python-startup-observation",
            status="passed",
            exit_code=0,
            request_sha256=request_hash,
            early=early,
            after_import=copy.deepcopy(early),
            terminal_guard=dict(status="passed"),
            wall_seconds_before_receipt=0.5,
            actual_interpreter=dict(interpreter, selected_path="/private/reported-python"),
        )
        self.report.write_bytes(probe.encoded(observed))
        self.entry = dict(
            request_sha256=request_hash,
            request_path=str(self.request_path),
            requested_command=argv,
            process=phase,
            terminal_guard=dict(status="passed"),
            observation=observed,
            observation_identity=dict(sha256=probe.sha(self.report.read_bytes()), bytes=self.report.stat().st_size),
            process_identity=probe.file_identity(self.folder / "process.json"),
            stdout_identity=probe.file_identity(self.folder / "process.stdout"),
            stderr_identity=probe.file_identity(self.folder / "process.stderr"),
        )

    def project(self, entry=None, guard=None):
        with mock.patch.object(probe, "request", return_value=self.request), mock.patch.object(
            probe, "guard", side_effect=guard
        ):
            return collection.interpreter_projection(
                self.path,
                entry or self.entry,
                1,
                self.environment,
                Path("/private/correctness_controller.py"),
                self.sources,
            )

    def final_reread_mutation(self, reason):
        original = probe.file_identity
        state = dict(report_reads=0, changed=False)

        def reread(path, limit):
            identity = original(path, limit)
            if Path(path) == self.report:
                state["report_reads"] += 1
                if state["report_reads"] == 2:
                    state["changed"] = True
            return identity

        def guard(request):
            self.assertEqual(request, self.request)
            if state["changed"]:
                raise ValueError(reason)

        with mock.patch.object(probe, "file_identity", side_effect=reread):
            with self.assertRaisesRegex(ValueError, reason):
                self.project(guard=guard)
        self.assertEqual(state["report_reads"], 2)

    def test_final_reference_reread_source_mutation_is_refused(self):
        self.final_reread_mutation("source-inputs-changed")

    def test_final_reference_reread_directory_mutation_is_refused(self):
        self.final_reread_mutation("private-directory-changed")

    def test_exact_request_reported_spellings_and_same_physical_identity_are_hash_only(self):
        row = self.project()
        self.assertEqual(row["status"], "verified-observation")
        self.assertTrue(row["physical_identity_equal"])
        self.assertEqual(row["request_sha256"], self.entry["request_sha256"])
        self.assertEqual(row["observation_sha256"], self.entry["observation_identity"]["sha256"])
        self.assertNotEqual(row["requested_spelling_sha256"], row["reported_spelling_sha256"])
        self.assertEqual(row["source_inputs_sha256"], probe.sha(probe.encoded(self.sources)))
        self.assertNotIn("/private", json.dumps(row))
        publication.NORMALIZER.check_sensitive(json.dumps(row), "probe-interpreter.json")

    def test_wrong_request_hash_is_rejected(self):
        entry = copy.deepcopy(self.entry)
        entry["request_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "request-hash"):
            self.project(entry)

    def test_wrong_request_bytes_and_source_hash_are_rejected(self):
        self.request_path.write_bytes(b"{}\n")
        with self.assertRaisesRegex(ValueError, "request-differs"):
            self.project()
        self.request_path.write_bytes(probe.encoded(self.request) + b"\n")
        self.sources["/private/bound-source.py"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "source-differs"):
            self.project()

    def test_wrong_observation_request_is_rejected_even_after_resealing(self):
        entry = copy.deepcopy(self.entry)
        entry["observation"]["request_sha256"] = "0" * 64
        self.report.write_bytes(probe.encoded(entry["observation"]))
        entry["observation_identity"] = dict(
            sha256=probe.sha(self.report.read_bytes()), bytes=self.report.stat().st_size
        )
        with self.assertRaisesRegex(ValueError, "observation-not-passed"):
            self.project(entry)

    def test_missing_current_observation_stays_unavailable(self):
        self.report.unlink()
        with self.assertRaises(OSError):
            self.project()

    def test_historical_missing_observation_is_not_upgraded_from_current_file(self):
        entry = copy.deepcopy(self.entry)
        del entry["observation"]
        self.assertTrue(self.report.exists())
        with self.assertRaisesRegex(ValueError, "historical-observation-unavailable"):
            self.project(entry)

    def test_changed_process_and_observation_identity_are_rejected(self):
        for key in ["process_identity", "observation_identity"]:
            entry = copy.deepcopy(self.entry)
            entry[key]["sha256"] = "0" * 64
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.project(entry)

    def test_per_probe_failure_keeps_aggregate_outcome_and_cost(self):
        value = dict(
            schema_version=1,
            role="prospective-startup-profile-collection",
            status="passed",
            exit_code=0,
            final_evidence=False,
            probes=[self.entry, self.entry],
            wall_seconds_before_receipt=12.25,
        )
        self.path.write_bytes(probe.encoded(value))
        attempt = self.root.parent
        # 수집 요약 위치만 고정해 한 프로브의 실패가 다른 관측을 지우지 않는지 본다.
        with mock.patch.object(
            publication.state_inputs, "reference", return_value=dict(sha256="a" * 64)
        ), mock.patch.object(publication.state_inputs, "document", return_value=value), mock.patch.object(
            controller, "source_hashes", return_value=self.sources
        ), mock.patch.object(
            selected_launch, "private_environment", return_value=self.environment
        ), mock.patch.object(
            collection,
            "interpreter_projection",
            side_effect=[ValueError("missing"), dict(status="verified-observation", probe=2)],
        ):
            row = publication.profile_summary(attempt, self.sources)
        self.assertEqual(row["status"], "retained")
        self.assertEqual(row["outcome"], "passed")
        self.assertEqual(row["wall_seconds_before_receipt"], 12.25)
        self.assertEqual(row["interpreter_probes"][0]["status"], "unavailable")
        self.assertEqual(row["interpreter_probes"][1]["status"], "verified-observation")

    def test_collection_change_downgrades_all_projections(self):
        value = dict(
            schema_version=1,
            role="prospective-startup-profile-collection",
            status="passed",
            exit_code=0,
            final_evidence=False,
            probes=[self.entry],
            wall_seconds_before_receipt=12.25,
        )
        with mock.patch.object(
            publication.state_inputs, "reference", side_effect=[dict(sha256="a" * 64), dict(sha256="b" * 64)]
        ), mock.patch.object(publication.state_inputs, "document", return_value=value), mock.patch.object(
            controller, "source_hashes", return_value=self.sources
        ), mock.patch.object(
            selected_launch, "private_environment", return_value=self.environment
        ), mock.patch.object(
            collection, "interpreter_projection", return_value=dict(status="verified-observation", probe=1)
        ):
            row = publication.profile_summary(self.root, self.sources)
        self.assertEqual(row["status"], "unavailable")
        self.assertEqual(row["interpreter_probes"][0]["status"], "unavailable")


class PublicationFailureBindingTests(unittest.TestCase):
    def test_projection_rechecks_measurement_command_and_selected_request(self):
        summary = mismatch().summary
        sources = {"/private/source.py": "b" * 64}
        summary["selected_request"] = dict(
            status="bound-request",
            mode="one-exec",
            request_sha256="c" * 64,
            source_inputs_sha256=probe.sha(probe.encoded(sources)),
        )
        args = argparse.Namespace(measurement=Path("/private/measurement"))
        phase = dict(command=["/private/requested-python"])

        def reference(path):
            return dict(sha256="a" * 64 if path == args.measurement else "d" * 64)

        with mock.patch.object(controller, "source_hashes", return_value=sources), mock.patch.object(
            publication.state_inputs, "reference", side_effect=reference
        ), mock.patch.object(
            publication.state_inputs, "document", return_value=dict(phases=dict(install=phase))
        ), mock.patch.object(
            installation, "completed"
        ), mock.patch.object(
            selected_launch, "request_projection", return_value=summary["selected_request"]
        ) as projected:
            publication.verify_interpreter_spelling(args, Path("/private/attempt"), sources, summary)
            projected.return_value = dict(summary["selected_request"], request_sha256="0" * 64)
            with self.assertRaises(ValueError):
                publication.verify_interpreter_spelling(args, Path("/private/attempt"), sources, summary)
            projected.return_value = summary["selected_request"]
            phase["command"][0] = "/private/wrong-request"
            with self.assertRaises(ValueError):
                publication.verify_interpreter_spelling(args, Path("/private/attempt"), sources, summary)


if __name__ == "__main__":
    unittest.main(verbosity=2)
