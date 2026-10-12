"""정규화 실패와 사전 기록 실패도 원래 종료·비용을 잃지 않는지 확인한다."""

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
import publish_correctness as publication
import attempt_receipts

ROOT = Path(__file__).resolve().parent


class PublicationTests(unittest.TestCase):
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
        self.values = []
        for name in ["repository", "lifecycle", "setup", "measurement", "scratch_root"]:
            self.values += ["--" + name.replace("_", "-"), str(getattr(self.args, name))]
        result = subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(ROOT / "correctness_controller.py"), *self.values],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.attempt = self.root / "actual-arm-correctness-attempt"
        self.raw = self.root / "actual-arm-correctness-raw"
        self.public = self.root / "actual-arm-correctness-public"
        phase = json.loads((self.attempt / "process.json").read_text())
        selected = phase["command"][0]
        # 별칭/TMP 문제를 구분하되 경로 원문이나 환경 덤프를 진단에 싣지 않는다.
        diagnostic = dict(
            selected_spelling_matches=selected == sys.executable,
            resolved_interpreter_matches=Path(selected).resolve() == Path(sys.executable).resolve(),
            selected_sha256=hashlib.sha256(selected.encode()).hexdigest(),
            current_sha256=hashlib.sha256(sys.executable.encode()).hexdigest(),
            scratch_is_canonical=self.root == self.root.resolve(),
        )
        self.assertTrue(selected == sys.executable, json.dumps(diagnostic, sort_keys=True))

    def publish(self):
        with mock.patch.object(controller, "isolation"), mock.patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}):
            return publication.publish(self.args)

    def test_missing_raw_keeps_verified_original_exit_cost(self):
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["bundle_status"], "missing")
        receipt = json.loads((self.public / "attempt.json").read_text())
        self.assertEqual(receipt["observed_returncode"], 1)
        self.assertGreater(receipt["child_wall_seconds"], 0)
        self.assertEqual(receipt["pre_record_diagnostic"]["stage"], "state-inputs")
        self.assertNotIn(str(self.root), json.dumps(receipt["pre_record_diagnostic"]))
        self.assertFalse(status["complete_run_evidence"])
        self.assertEqual(set(p.name for p in self.public.iterdir()), {"attempt.json", "publication-status.json"})

    def test_changed_typed_stage_cannot_be_published_against_original_log(self):
        path = self.attempt / "results.json"
        row = json.loads(path.read_text())
        row["pre_record_diagnostic"]["stage"] = "installation-binding"
        path.write_text(json.dumps(row))
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "blocked")
        self.assertFalse((self.public / "attempt.json").exists())

    def test_actual_publication_cli_is_isolated_and_preserves_red(self):
        result = subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(ROOT / "publish_correctness.py"), *self.values],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue((self.public / "attempt.json").is_file())
        self.assertIn("safe-publication-ready", result.stdout)

    def test_safe_whole_normalized_tree_publishes_atomically_with_raw_hashes(self):
        self.raw.mkdir()
        (self.raw / "results.json").write_text('{"status":"failed","synthetic":true}')
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["bundle_status"], "normalized")
        self.assertFalse(status["complete_run_evidence"])
        self.assertEqual(status["controller_completion"]["status"], "unavailable")
        manifest = json.loads((self.public / "validation/manifest.json").read_text())
        row = next(r for r in manifest["files"] if r["path"] == "results.json")
        self.assertEqual(
            row["original_raw_sha256"], hashlib.sha256((self.raw / "results.json").read_bytes()).hexdigest()
        )

    def test_credential_or_unknown_path_blocks_whole_subtree_without_raw_fallback(self):
        self.raw.mkdir()
        (self.raw / "results.json").write_text('{"GITHUB_TOKEN":"synthetic secret only"}')
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["bundle_status"], "blocked")
        self.assertFalse((self.public / "validation").exists())
        self.assertTrue((self.public / "attempt.json").exists())
        self.assertNotIn("synthetic secret", json.dumps(status))
        self.assertFalse(status["raw_fallback"])

    def test_historical_unavailable_then_readable_keeps_original_exit_and_red(self):
        path = self.attempt / "results.json"
        row = json.loads(path.read_text())
        row["stdout"] = dict(status="unavailable", reason="input-changed-during-read")
        path.write_text(json.dumps(row))
        self.raw.mkdir()
        (self.raw / "results.json").write_text("{}")
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["failure"], "capture-log-identity-unavailable")
        public = json.loads((self.public / "attempt.json").read_text())
        self.assertEqual(public["observed_returncode"], 1)
        self.assertEqual(public["stdout"]["status"], "unavailable")
        self.assertEqual(public["publication_log_identities"]["stdout"]["status"], "available")
        self.assertFalse(status["complete_run_evidence"])

    def test_unavailable_current_source_identity_keeps_original_exit_and_cost(self):
        with mock.patch.object(controller, "source_hashes", side_effect=FileNotFoundError):
            status, code = self.publish()
        self.assertEqual(code, 1)
        public = json.loads((self.public / "attempt.json").read_text())
        self.assertEqual(public["observed_returncode"], 1)
        self.assertGreater(public["child_wall_seconds"], 0)
        self.assertEqual(public["publication_source_status"], "unavailable")
        self.assertIsNone(public["publication_source_sha256"])
        self.assertFalse(status["complete_run_evidence"])

    def test_changed_available_log_is_refused_without_fabricated_outcome(self):
        (self.attempt / "process.stdout").write_text("changed")
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "blocked")
        self.assertFalse((self.public / "attempt.json").exists())
        self.assertIsNone(status["exit_code"])

    def test_publication_alias_into_sdk_is_refused_before_write(self):
        sdk = self.root / "SDK.sdk"
        sdk.mkdir()
        self.public.symlink_to(sdk, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(list(sdk.iterdir()), [])

    def test_unavailable_log_extra_field_is_not_published(self):
        path = self.attempt / "results.json"
        row = json.loads(path.read_text())
        row["stdout"] = dict(status="unavailable", reason="unreadable-input", extra="unrelated contact metadata")
        path.write_text(json.dumps(row))
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "blocked")
        self.assertFalse((self.public / "attempt.json").exists())

    def test_untyped_source_guard_is_not_accepted(self):
        path = self.attempt / "results.json"
        row = json.loads(path.read_text())
        row["source_inputs_unchanged"] = "true"
        path.write_text(json.dumps(row))
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "blocked")

    def test_unrecognized_normalizer_metadata_is_not_echoed(self):
        self.raw.mkdir()
        (self.raw / "results.json").write_text("{}")
        error = publication.NORMALIZER.PublicationBlocked(
            "private diagnostic",
            reason="unrelated personal details",
            artifact_sha256="invalid",
            value_sha256="also invalid",
        )
        with mock.patch.object(publication.NORMALIZER, "package", side_effect=error):
            status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertNotIn("normalization_diagnostic", status)
        self.assertNotIn("unrelated personal", json.dumps(status))

    def test_selected_launch_change_during_staging_blocks_whole_subtree(self):
        self.raw.mkdir()
        (self.raw / "results.json").write_text("{}")
        before = dict(status="verified", mode="direct", request_sha256="a" * 64, observation_sha256="b" * 64)
        after = dict(
            status="unavailable",
            reason="selected-launch-not-verified",
            request_sha256="a" * 64,
            observation_sha256="c" * 64,
        )
        with mock.patch.object(publication, "selected_launch_summary", side_effect=[before, after]):
            status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["bundle_status"], "blocked")
        self.assertFalse((self.public / "validation").exists())
        self.assertEqual(json.loads((self.public / "attempt-after-staging.json").read_text())["selected_launch"], after)

    def test_source_change_during_staging_keeps_second_observation_and_blocks_promotion(self):
        self.raw.mkdir()
        (self.raw / "results.json").write_text("{}")
        actual = controller.source_hashes()
        changed = dict(actual)
        changed[next(iter(changed))] = "0" * 64
        staged = False
        original_package = publication.runtime_publication.package

        def stage(*args, **kwargs):
            nonlocal staged
            manifest = original_package(*args, **kwargs)
            staged = True
            return manifest

        with mock.patch.object(
            controller, "source_hashes", side_effect=lambda: changed if staged else actual
        ), mock.patch.object(publication.runtime_publication, "package", side_effect=stage) as package:
            status, code = self.publish()
        self.assertTrue(staged)
        package.assert_called_once()
        self.assertEqual(code, 1)
        self.assertEqual(status["bundle_status"], "blocked")
        self.assertFalse((self.public / "validation").exists())
        before = json.loads((self.public / "attempt.json").read_text())
        after = json.loads((self.public / "attempt-after-staging.json").read_text())
        self.assertTrue(before["publication_source_inputs_unchanged"])
        self.assertFalse(after["publication_source_inputs_unchanged"])
        self.assertEqual(after["observed_returncode"], before["observed_returncode"])
        self.assertEqual(after["child_wall_seconds"], before["child_wall_seconds"])

    def test_source_unavailable_during_staging_keeps_failed_observation(self):
        self.raw.mkdir()
        (self.raw / "results.json").write_text("{}")
        actual = controller.source_hashes()
        staged = False
        original_package = publication.runtime_publication.package

        def stage(*args, **kwargs):
            nonlocal staged
            manifest = original_package(*args, **kwargs)
            staged = True
            return manifest

        def current_sources():
            if staged:
                raise FileNotFoundError("Synthetic source became unavailable after staging")
            return actual

        with mock.patch.object(controller, "source_hashes", side_effect=current_sources), mock.patch.object(
            publication.runtime_publication, "package", side_effect=stage
        ) as package:
            status, code = self.publish()
        self.assertTrue(staged)
        package.assert_called_once()
        self.assertEqual(code, 1)
        self.assertEqual(status["bundle_status"], "blocked")
        self.assertFalse((self.public / "validation").exists())
        after = json.loads((self.public / "attempt-after-staging.json").read_text())
        self.assertEqual(after["publication_source_status"], "unavailable")
        self.assertEqual(after["observed_returncode"], 1)

    def test_boolean_exit_and_summary_only_completion_are_not_verified(self):
        (self.raw / "setup").mkdir(parents=True)
        record = dict(
            role="actual-arm-correctness-controller",
            final_evidence=False,
            exit_code=False,
            status="passed",
            state_result=dict(status="passed"),
            state_runtime=dict(status="passed"),
            terminal_guard=dict(status="passed"),
            runtime_source_inputs_unchanged=True,
        )
        (self.raw / "setup/controller-result.json").write_text(json.dumps(record))
        (self.raw / "results.json").write_text('{"status":"failed"}')
        for code in [False, 0]:
            record["exit_code"] = code
            (self.raw / "setup/controller-result.json").write_text(json.dumps(record))
            actual = publication.completion_receipt(self.raw, dict(exit_code=0))
            self.assertEqual(actual["status"], "unavailable")

    def test_argv_input_mismatch_blocks_attempt(self):
        path = self.attempt / "process.json"
        row = json.loads(path.read_text())
        row["command"][-1] = "/other-scratch"
        path.write_text(json.dumps(row))
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "blocked")

    def test_same_physical_interpreter_alias_does_not_relax_request_binding(self):
        alias = self.root / "python-alias"
        alias.symlink_to(Path(sys.executable).resolve())
        self.assertEqual(alias.resolve(), Path(sys.executable).resolve())
        with mock.patch.object(sys, "executable", str(alias)):
            with self.assertRaises(ValueError):
                publication.public_attempt(self.args, self.attempt)

    def test_scratch_alias_keeps_existing_physical_path_contract(self):
        alias = self.root / "scratch-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.args.scratch_root = alias
        status, code = self.publish()
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "verified")
        self.assertTrue((self.public / "attempt.json").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
