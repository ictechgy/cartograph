"""프로필 실패는 선택 exec나 실제 두 팔을 시작하기 전에 중단되어야 한다."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import correctness_controller as controller
import publish_correctness as publication
import startup_profile


class StartupWiringTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.attempt = self.root / "actual-arm-correctness-attempt"
        self.attempt.mkdir()
        self.env = controller.selected_launch.private_environment(self.root, create=True)
        self.args = argparse.Namespace(selected_launch_sha256=None, startup_profile_sha256=None)

    def invoke(self, value, marker=None):
        self.args.selected_launch_sha256 = marker
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(
            controller.selected_launch, "selected_binding", return_value=(Path(controller.sys.executable), {})
        ), mock.patch.object(
            controller.profile_collection, "collect", return_value=value
        ) as collect, mock.patch.object(
            controller.selected_launch, "startup_binding", return_value={}
        ) as binding, mock.patch.object(
            controller.state_inputs, "reference", return_value={"sha256": "a" * 64}
        ):
            controller.prepare_startup_profile(self.args, self.root)
        return collect, binding

    def test_passed_collection_sets_exact_marker_before_selected_launch(self):
        collect, binding = self.invoke(dict(status="passed", exit_code=0))
        self.assertEqual(self.args.startup_profile_sha256, "a" * 64)
        self.assertEqual(collect.call_count, 1)
        self.assertEqual(collect.call_args.args[0], self.env)
        self.assertEqual(binding.call_count, 1)

    def test_failed_collection_does_not_set_marker(self):
        with self.assertRaises(ValueError):
            self.invoke(dict(status="failed", exit_code=1))
        self.assertIsNone(self.args.startup_profile_sha256)

    def test_incomplete_collection_preserves125_before_exec(self):
        with self.assertRaises(KeyboardInterrupt):
            self.invoke(dict(status="incomplete", exit_code=125))
        self.assertIsNone(self.args.startup_profile_sha256)

    def test_initial_process_cannot_inject_prior_profile(self):
        self.args.startup_profile_sha256 = "b" * 64
        with self.assertRaises(ValueError):
            self.invoke(dict(status="passed", exit_code=0))

    def test_replacement_reuses_verified_profile_without_new_probe(self):
        self.args.startup_profile_sha256 = "b" * 64
        collect, binding = self.invoke(None, "c" * 64)
        collect.assert_not_called()
        binding.assert_called_once()

    def test_replacement_without_profile_is_refused(self):
        with self.assertRaises(ValueError):
            self.invoke(None, "c" * 64)

    def test_unknown_extra_key_is_refused_before_probe(self):
        with mock.patch.dict(os.environ, dict(self.env, UNKNOWN_EXTRA="synthetic"), clear=True), mock.patch.object(
            controller.profile_collection, "collect"
        ) as collect, self.assertRaises(ValueError):
            controller.prepare_startup_profile(self.args, self.root)
        collect.assert_not_called()

    def test_changed_expected_key_is_refused_before_probe(self):
        with mock.patch.dict(os.environ, dict(self.env, TZ="different"), clear=True), mock.patch.object(
            controller.profile_collection, "collect"
        ) as collect, self.assertRaises(ValueError):
            controller.prepare_startup_profile(self.args, self.root)
        collect.assert_not_called()

    def test_failed_profile_prevents_selected_launch_and_actual_arms(self):
        self.assert_profile_stops(ValueError("synthetic refusal"), 1)

    def test_incomplete_profile_prevents_selected_launch_and_actual_arms(self):
        self.assert_profile_stops(KeyboardInterrupt("synthetic incomplete"), 125)

    def assert_profile_stops(self, error, expected):
        self.args.scratch_root = self.root
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(
            controller, "isolation"
        ), mock.patch.object(controller, "before_write"), mock.patch.object(
            controller.state_inputs, "prepare"
        ), mock.patch.object(
            controller, "prepare_startup_profile", side_effect=error
        ), mock.patch.object(
            controller.selected_launch, "prepare"
        ) as launch, mock.patch.object(
            controller.contract_prerequisites, "run"
        ) as contracts, mock.patch.object(
            controller.command_runner, "command"
        ) as command:
            self.args.repository = self.root / "repository"
            self.args.lifecycle = self.root / "lifecycle.json"
            self.args.setup = self.root / "setup.json"
            self.args.measurement = self.root / "measurement.json"
            with self.assertRaises(controller.attempt_receipts.PreRecordFailure) as raised:
                controller.execute(self.args)
            self.assertEqual(raised.exception.exit_code, expected)
            launch.assert_not_called()
            contracts.assert_not_called()
            command.assert_not_called()
            self.assertFalse((self.root / "actual-arm-correctness-raw").exists())

    def test_failed_collection_hash_and_cost_remain_in_public_summary(self):
        path = self.attempt / "startup-profile/results.json"
        path.parent.mkdir()
        value = dict(
            schema_version=1,
            role="prospective-startup-profile-collection",
            status="failed",
            exit_code=1,
            final_evidence=False,
            probes=[],
            wall_seconds_before_receipt=1.5,
        )
        path.write_text(json.dumps(value))
        row = publication.profile_summary(self.attempt)
        self.assertEqual(row["status"], "retained")
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(row["wall_seconds_before_receipt"], 1.5)
        self.assertEqual(row["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())

    def test_untyped_collection_exit_is_unavailable(self):
        path = self.attempt / "startup-profile/results.json"
        path.parent.mkdir()
        path.write_text(
            json.dumps(
                dict(
                    schema_version=1,
                    role="prospective-startup-profile-collection",
                    status="passed",
                    exit_code=False,
                    final_evidence=False,
                    probes=[],
                    wall_seconds_before_receipt=0,
                )
            )
        )
        self.assertEqual(publication.profile_summary(self.attempt)["status"], "unavailable")


if __name__ == "__main__":
    unittest.main()
