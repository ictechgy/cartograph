#!/usr/bin/env python3
"""고정 수동 교정의 단계·원본·공개 경계를 네이티브 실행 없이 검증한다."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/validate-native-calibration-inputs.py"
WORKFLOW = ROOT / ".github/workflows/native-calibration.yml"
SPEC = importlib.util.spec_from_file_location("native_calibration_contract", SCRIPT)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

STAGES = ("before-compilation", "after-generation", "after-calibration")
CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD = "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"


def workflow_step(name):
    match = re.search(
        r"^      - name: " + re.escape(name) + r"\n(.*?)(?=^      - |\Z)",
        WORKFLOW.read_text(), re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"Missing workflow step: {name}")
    return match.group(1)


def write_document(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


class ScratchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cartograph-calibration-contract-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.raw = self.root / "native-calibration-sdk-raw"
        self.staging = self.root / "native-calibration-sdk-staging"
        self.public = self.root / "native-calibration-sdk-public"

    def patch(self, target, name, **kwargs):
        patcher = mock.patch.object(target, name, **kwargs)
        selected = patcher.start()
        self.addCleanup(patcher.stop)
        return selected

    def read(self, path):
        return json.loads(path.read_text())


class NativeCalibrationStageTests(ScratchTests):
    def setUp(self):
        super().setUp()
        self.hashes = {"Scripts/fixture.py": "a" * 64}
        self.patch(M, "helper_hashes", side_effect=lambda: copy.deepcopy(self.hashes))
        self.machine = mock.Mock(name="machine_fields")
        self.binding = dict(package=dict(target=str(self.root / "existing-dependencies")), status="bound")
        self.bound = self.patch(M, "bound_machine_fields", return_value=(self.machine, self.binding))
        self.begin = self.patch(M.admission, "begin", side_effect=self.capture)
        self.verify = self.patch(M.admission, "verify_boundary", side_effect=self.verify_candidate)
        self.bind = self.patch(M.admission, "bind_discovery", return_value={
            "status": "bound-candidate", "wall_seconds": 0.375, "runtime_closure_proven": False,
        })
        self.request = self.root / "sdk-discovery-raw/setup/selector-request.json"
        self.discovery = self.root / "sdk-discovery-raw/setup/discovery/results.json"
        self.controller = self.root / "actual-arm-correctness-raw/setup/controller-result.json"
        write_document(self.request, dict(request="original compiler search paths"))
        write_document(self.discovery, dict(status="awaiting-root-review", accepted=False))
        write_document(self.controller, dict(status="passed", exit_code=0))

    def capture(self, output, **options):
        result = dict(status="captured-candidate", boundary="before-compilation", accepted=False,
                      final_protocol_ready=False, native_admission_wall_seconds=0.25,
                      seal_capture_wall_seconds=0.5, wall_seconds=0.875)
        write_document(output / "results.json", result)
        return result

    def verify_candidate(self, candidate, output, *, boundary, **options):
        result = dict(status="verified-candidate", boundary=boundary, accepted=False,
                      final_protocol_ready=False, native_admission_wall_seconds=0.125,
                      seal_verification_wall_seconds=0.75, wall_seconds=1.125)
        write_document(output / "results.json", result)
        return result

    def phase_path(self, stage):
        return self.raw / "setup/phases" / (stage + ".json")

    def phase(self, stage):
        return self.read(self.phase_path(stage))

    def summary(self):
        return self.read(self.raw / "results.json")

    def through_generation(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        self.assertEqual(M.stage("after-generation", self.root), 0)

    def test_pre_and_post_stages_preserve_immutable_refs_helpers_and_costs(self):
        for stage in STAGES:
            with self.subTest(stage=stage):
                self.assertEqual(M.stage(stage, self.root), 0)
                phase = self.phase(stage)
                self.assertEqual(phase["helper_sha256"], self.hashes)
                self.assertEqual(phase["installation_binding"], self.binding)
                self.assertEqual(phase["status"], "passed")
                self.assertIs(type(phase["exit_code"]), int)
                self.assertIs(phase["accepted"], False)
                self.assertIs(phase["final_protocol_ready"], False)
                self.assertGreaterEqual(phase["wall_seconds_before_receipt"], 0)
                self.assertEqual(self.summary()["stages"][stage]["original"],
                                 M.state_inputs.reference(self.phase_path(stage)))
                self.assertEqual(phase["observation"], self.read(self.raw / stage / "results.json"))
        summary = self.summary()
        self.assertEqual(summary["status"], "candidate-evidence-ready")
        self.assertIs(summary["accepted"], False)
        self.assertIs(summary["final_protocol_ready"], False)
        self.assertNotIn("first_failure", summary)
        self.assertEqual(self.phase("before-compilation")["observation"]["seal_capture_wall_seconds"], 0.5)
        after = self.phase("after-generation")
        self.assertEqual(after["discovery_inputs"], dict(
            request=M.state_inputs.reference(self.request), result=M.state_inputs.reference(self.discovery)))
        self.assertEqual(after["discovery_binding"]["wall_seconds"], 0.375)
        self.assertGreaterEqual(after["discovery_binding_wall_seconds"], 0)
        self.assertEqual(self.phase("after-calibration")["calibration_controller"],
                         M.state_inputs.reference(self.controller))
        self.assertEqual(self.begin.call_args.kwargs["machine_fields"], self.machine)
        self.assertIs(self.begin.call_args.kwargs["command"], M.COMMAND.command)

    def test_failed_first_stage_blocks_later_native_reads_and_keeps_first_failure(self):
        self.begin.side_effect = None
        self.begin.return_value = dict(status="incomplete", wall_seconds=3.25)
        self.assertEqual(M.stage("before-compilation", self.root), 125)
        first = self.phase_path("before-compilation").read_bytes()
        self.bound.reset_mock()
        self.assertEqual(M.stage("after-generation", self.root), 1)
        self.assertEqual(self.phase_path("before-compilation").read_bytes(), first)
        self.assertEqual(self.summary()["first_failure"], dict(stage="before-compilation", exit_code=125))
        self.assertEqual(self.summary()["status"], "retained-failure")
        self.bound.assert_not_called()
        self.verify.assert_not_called()
        self.bind.assert_not_called()

    def test_boolean_summary_exit_cannot_pass_prior_stage_gate(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        summary = self.summary()
        summary["stages"]["before-compilation"]["exit_code"] = False
        write_document(self.raw / "results.json", summary)
        self.bound.reset_mock()
        self.assertEqual(M.stage("after-generation", self.root), 1)
        self.bound.assert_not_called()
        self.verify.assert_not_called()

    def test_skipped_generation_cannot_reach_post_calibration(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        self.bound.reset_mock()
        self.assertEqual(M.stage("after-calibration", self.root), 1)
        self.bound.assert_not_called()
        self.verify.assert_not_called()

    def test_changed_prior_phase_refuses_before_native_reads(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        original = self.phase("before-compilation")
        original["wall_seconds_before_receipt"] += 1
        write_document(self.phase_path("before-compilation"), original)
        self.bound.reset_mock()
        self.assertEqual(M.stage("after-generation", self.root), 1)
        self.bound.assert_not_called()
        self.verify.assert_not_called()

    def test_mutable_summary_cannot_promote_a_failed_immutable_phase(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        original = self.phase("before-compilation")
        original.update(status="failed", exit_code=1)
        write_document(self.phase_path("before-compilation"), original)
        summary = self.summary()
        summary["stages"]["before-compilation"]["original"] = M.state_inputs.reference(
            self.phase_path("before-compilation"))
        write_document(self.raw / "results.json", summary)
        self.bound.reset_mock()
        self.assertEqual(M.stage("after-generation", self.root), 1)
        self.bound.assert_not_called()
        self.verify.assert_not_called()

    def test_changed_candidate_result_refuses_before_native_reads(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        candidate = self.read(self.raw / "before-compilation/results.json")
        candidate["wall_seconds"] += 1
        write_document(self.raw / "before-compilation/results.json", candidate)
        self.bound.reset_mock()
        self.assertEqual(M.stage("after-generation", self.root), 1)
        self.bound.assert_not_called()
        self.verify.assert_not_called()

    def test_candidate_boolean_cannot_be_replaced_by_equal_numeric_value(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        candidate = self.read(self.raw / "before-compilation/results.json")
        candidate["accepted"] = 0
        write_document(self.raw / "before-compilation/results.json", candidate)
        self.bound.reset_mock()
        self.assertEqual(M.stage("after-generation", self.root), 1)
        self.bound.assert_not_called()
        self.verify.assert_not_called()

    def test_helper_change_before_stage_refuses_without_overwriting_prior_evidence(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        original = self.phase_path("before-compilation").read_bytes()
        self.hashes["Scripts/fixture.py"] = "b" * 64
        self.bound.reset_mock()
        with self.assertRaisesRegex(ValueError, "calibration-input-source-changed"):
            M.stage("after-generation", self.root)
        self.assertEqual(self.phase_path("before-compilation").read_bytes(), original)
        self.bound.assert_not_called()
        self.verify.assert_not_called()

    def test_helper_change_during_stage_is_retained_failure(self):
        def changed(output, **options):
            observed = self.capture(output, **options)
            self.hashes["Scripts/fixture.py"] = "b" * 64
            return observed

        self.begin.side_effect = changed
        self.assertEqual(M.stage("before-compilation", self.root), 1)
        phase = self.phase("before-compilation")
        self.assertEqual(phase["helper_sha256"]["Scripts/fixture.py"], "a" * 64)
        self.assertEqual(phase["status"], "failed")
        self.assertEqual(self.summary()["first_failure"], dict(stage="before-compilation", exit_code=1))
        self.assertEqual(phase["observation"]["seal_capture_wall_seconds"], 0.5)

    def test_existing_pre_or_post_receipt_is_never_replaced(self):
        self.through_generation()
        before = {stage: self.phase_path(stage).read_bytes() for stage in STAGES[:2]}
        for stage in STAGES[:2]:
            with self.subTest(stage=stage), self.assertRaises((FileExistsError, ValueError)):
                M.stage(stage, self.root)
        self.assertEqual({stage: self.phase_path(stage).read_bytes() for stage in STAGES[:2]}, before)
        self.assertEqual(self.begin.call_count, 1)
        self.assertEqual(self.verify.call_count, 1)

    def test_discovery_failure_is_charged_and_prevents_candidate_ready(self):
        self.assertEqual(M.stage("before-compilation", self.root), 0)
        self.bind.side_effect = ValueError("changed discovery")
        self.assertEqual(M.stage("after-generation", self.root), 1)
        phase = self.phase("after-generation")
        self.assertGreaterEqual(phase["discovery_binding_wall_seconds"], 0)
        self.assertEqual(phase["discovery_inputs"]["result"], M.state_inputs.reference(self.discovery))
        self.assertEqual(self.summary()["status"], "retained-failure")

    def test_interrupted_pre_stage_is_durable_incomplete(self):
        self.begin.side_effect = KeyboardInterrupt
        self.assertEqual(M.stage("before-compilation", self.root), 125)
        phase = self.phase("before-compilation")
        self.assertEqual(phase["status"], "incomplete")
        self.assertEqual(phase["failure_type"], "KeyboardInterrupt")
        self.assertGreaterEqual(phase["wall_seconds_before_receipt"], 0)

    def test_post_calibration_does_not_promote_boolean_controller_exit(self):
        self.through_generation()
        write_document(self.controller, dict(status="passed", exit_code=False))
        self.assertEqual(M.stage("after-calibration", self.root), 1)
        phase = self.phase("after-calibration")
        self.assertEqual(phase["calibration_status"], dict(status="passed", exit_code=False))
        self.assertEqual(phase["calibration_controller"], M.state_inputs.reference(self.controller))
        self.assertEqual(self.summary()["status"], "retained-failure")

    def test_post_calibration_retains_failed_controller_status_and_original(self):
        self.through_generation()
        write_document(self.controller, dict(status="failed", exit_code=1))
        self.assertEqual(M.stage("after-calibration", self.root), 1)
        phase = self.phase("after-calibration")
        self.assertEqual(phase["calibration_status"], dict(status="failed", exit_code=1))
        self.assertEqual(phase["calibration_controller"], M.state_inputs.reference(self.controller))
        self.assertEqual(self.summary()["status"], "retained-failure")


class NativeCalibrationSupervisionTests(ScratchTests):
    def setUp(self):
        super().setUp()
        self.hashes = {"Scripts/fixture.py": "a" * 64}
        self.patch(M, "helper_hashes", return_value=self.hashes)
        self.command_result = dict(completed=True, passed=True, returncode=0, observed_returncode=0,
                                   failure=None, cleanup_signals=[], cleanup_root_unfinished=False,
                                   wall_seconds=2.5)
        self.phase_path = self.raw / "setup/phases/before-compilation.json"
        self.original = dict(stage="before-compilation", status="passed", exit_code=0,
                             helper_sha256=self.hashes, accepted=False, final_protocol_ready=False)
        self.command = self.patch(M.COMMAND, "command", side_effect=self.child)

    def child(self, argv, cwd, stem, environment, timeout):
        write_document(self.phase_path, self.original)
        return copy.deepcopy(self.command_result)

    def result(self):
        return self.read(self.root / "native-calibration-sdk-calls/before-compilation/results.json")

    def test_supervised_child_has_isolated_flags_fixed_deadline_and_immutable_phase(self):
        self.assertEqual(M.supervise("before-compilation", self.root), 0)
        argv, cwd, stem, environment, timeout = self.command.call_args.args
        self.assertEqual(argv, [sys.executable, "-I", "-S", "-B", str(SCRIPT), "--stage", "before-compilation",
                                "--scratch-root", str(self.root), "--execute-stage"])
        self.assertEqual(cwd, ROOT)
        self.assertEqual(stem, self.root / "native-calibration-sdk-calls/before-compilation/command")
        self.assertEqual(environment, dict(os.environ))
        self.assertEqual(timeout, 570)
        result = self.result()
        self.assertEqual(result["command"], self.command_result)
        self.assertEqual(result["original_phase"], M.state_inputs.reference(self.phase_path))
        self.assertEqual(result["helper_sha256"], self.hashes)
        self.assertGreaterEqual(result["full_call_wall_seconds_before_receipt"], 0)
        self.assertIs(result["accepted"], False)
        self.assertIs(result["final_protocol_ready"], False)

    def test_successful_child_without_original_phase_does_not_pass(self):
        self.command.side_effect = None
        self.command.return_value = self.command_result
        self.assertEqual(M.supervise("before-compilation", self.root), 1)
        self.assertEqual(self.result()["status"], "failed")
        self.assertEqual(self.result()["command"]["wall_seconds"], 2.5)

    def test_incomplete_child_preserves_original_exit_and_full_observation(self):
        self.command_result.update(completed=False, passed=False, returncode=125, observed_returncode=-15,
                                   failure="timeout", cleanup_signals=["SIGTERM"])
        self.assertEqual(M.supervise("before-compilation", self.root), 125)
        result = self.result()
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["command"], self.command_result)
        self.assertEqual(result["original_phase"], M.state_inputs.reference(self.phase_path))

    def test_forged_passing_phase_helpers_are_rejected(self):
        self.original["helper_sha256"] = {"Scripts/fixture.py": "b" * 64}
        self.assertEqual(M.supervise("before-compilation", self.root), 1)
        self.assertEqual(self.result()["status"], "failed")

    def test_cleanup_activity_cannot_be_hidden_by_zero_child_exit(self):
        self.command_result["cleanup_signals"] = ["SIGTERM"]
        self.assertEqual(M.supervise("before-compilation", self.root), 1)
        self.assertEqual(self.result()["command"]["cleanup_signals"], ["SIGTERM"])

    def test_boolean_observed_exit_is_not_exact_zero(self):
        self.command_result["observed_returncode"] = False
        self.assertEqual(M.supervise("before-compilation", self.root), 1)
        self.assertEqual(self.result()["status"], "failed")

    def test_phase_cannot_promote_sdk_candidate_to_accepted(self):
        self.original["accepted"] = True
        self.assertEqual(M.supervise("before-compilation", self.root), 1)
        self.assertIs(self.result()["accepted"], False)

    def test_launch_error_has_durable_incomplete_receipt(self):
        self.command.side_effect = OSError("synthetic launch failure")
        self.assertEqual(M.supervise("before-compilation", self.root), 125)
        result = self.result()
        self.assertEqual(result["status"], "incomplete")
        self.assertIsNone(result["command"])
        self.assertEqual(result["failure_type"], "OSError")
        self.assertGreaterEqual(result["full_call_wall_seconds_before_receipt"], 0)

    def test_interrupted_launch_has_durable_incomplete_receipt(self):
        self.command.side_effect = KeyboardInterrupt
        self.assertEqual(M.supervise("before-compilation", self.root), 125)
        self.assertEqual(self.result()["status"], "incomplete")
        self.assertEqual(self.result()["failure_type"], "KeyboardInterrupt")

    def test_supervised_receipt_is_not_overwritten_or_retried(self):
        self.assertEqual(M.supervise("before-compilation", self.root), 0)
        path = self.root / "native-calibration-sdk-calls/before-compilation/results.json"
        original = path.read_bytes()
        with self.assertRaises(FileExistsError):
            M.supervise("before-compilation", self.root)
        self.assertEqual(path.read_bytes(), original)
        self.command.assert_called_once()


class NativeCalibrationPublicationTests(ScratchTests):
    def setUp(self):
        super().setUp()
        self.calls = self.root / "native-calibration-sdk-calls"
        self.receipt = self.root / "native-calibration-sdk-publication.json"
        self.events = []
        self.prepare_cost = dict(status="verified-reversible-projection", wall_seconds=0.5,
                                 prepare_wall_seconds=1.25)
        self.verify_cost = dict(status="verified-normalized-projection", wall_seconds=1.5)
        self.source_cost = dict(status="source-identities-unchanged", wall_seconds=2.5)
        self.projection = SimpleNamespace(
            prepare_projection=mock.Mock(side_effect=self.prepare),
            verify_publication=mock.Mock(side_effect=self.verify_publication),
            verify_sources=mock.Mock(side_effect=self.verify_sources),
        )
        self.loader = self.patch(M, "load", return_value=self.projection)
        self.patch(M.admission, "expectation", return_value=(dict(developer_physical="/Applications/Xcode.app"),
                                                             "a" * 64))
        self.package = self.patch(M.NORMALIZER, "package", side_effect=self.normalize)
        self.summary = dict(status="retained-failure", accepted=False, final_protocol_ready=False,
                            first_failure=dict(stage="after-generation", exit_code=125),
                            stages={}, helper_sha256={"Scripts/fixture.py": "a" * 64})
        self.helpers = self.patch(M, "helper_hashes", return_value=copy.deepcopy(self.summary["helper_sha256"]))
        write_document(self.raw / "results.json", self.summary)
        write_document(self.raw / "setup/phases/before-compilation.json",
                       dict(status="passed", native_admission_wall_seconds=1.25))
        write_document(self.raw / "before-compilation/results.json", dict(status="captured-candidate"))
        write_document(self.raw / "before-compilation/seal.json", dict(large="retained only via projection"))
        write_document(self.raw / "after-generation/seal-verification.json", dict(large="verification"))
        write_document(self.calls / "before-compilation/results.json",
                       dict(status="passed", command=dict(wall_seconds=2.75)))
        log = self.calls / "before-compilation/command.stderr"
        log.write_bytes(b"original stderr\n")
        self.originals = M.original_small_files(self.raw, self.calls)
        self.after_publication = lambda: None

    def prepare(self, raw, staging):
        self.events.append("prepare-projection")
        self.assertEqual((raw, staging), (self.raw, self.staging))
        self.assertEqual(self.read(staging / "results.json"), self.summary)
        for relative, data in self.originals.items():
            self.assertEqual((staging / "setup/original" / relative).read_bytes(), data)
        self.assertFalse((staging / "setup/original/raw/before-compilation/seal.json").exists())
        self.assertFalse((staging / "setup/original/raw/after-generation/seal-verification.json").exists())
        return copy.deepcopy(self.prepare_cost)

    def normalize(self, args):
        self.events.append("normalize")
        self.assertEqual((args.input, args.output), (self.staging, self.public))
        self.assertIn("WORKSPACE=" + str(ROOT), args.prefix)
        self.assertIn("RUNNER_TEMP=" + str(self.root), args.prefix)
        expected = [dict(path=name, sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
                    for name, data in sorted(self.originals.items())]
        self.assertEqual(self.read(self.staging / "setup/original-copy-manifest.json"), dict(files=expected))
        manifest = dict(status="normalized_for_review", source_raw_unchanged=True, files=[])
        write_document(self.public / "manifest.json", manifest)
        return manifest

    def verify_publication(self, staging, public, manifest):
        self.events.append("verify-publication")
        self.assertEqual((staging, public), (self.staging, self.public))
        self.assertEqual(manifest, self.read(self.public / "manifest.json"))
        self.after_publication()
        return copy.deepcopy(self.verify_cost)

    def verify_sources(self, raw, staging):
        self.events.append("verify-sources")
        self.assertEqual((raw, staging), (self.raw, self.staging))
        return copy.deepcopy(self.source_cost)

    def publish(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            result = M.publish(self.root)
        self.logged = json.loads(output.getvalue())
        return result

    def test_original_copy_projection_normalization_and_source_readback_order(self):
        self.assertEqual(self.publish(), 0)
        self.assertEqual(self.events, ["prepare-projection", "normalize", "verify-publication", "verify-sources"])
        self.assertEqual(M.original_small_files(self.raw, self.calls), self.originals)
        self.assertIn("raw/results.json", self.originals)
        self.assertIn("calls/before-compilation/results.json", self.originals)
        receipt = self.read(self.receipt)
        self.assertEqual(receipt["status"], "passed")
        self.assertIs(receipt["accepted"], False)
        self.assertIs(receipt["final_protocol_ready"], False)
        for name, expected in (("prepare_projection", self.prepare_cost),
                               ("verify_publication", self.verify_cost), ("verify_sources", self.source_cost)):
            self.assertEqual(receipt["costs"][name]["status"], "passed")
            self.assertEqual(receipt["costs"][name]["result"], expected)
            self.assertGreaterEqual(receipt["costs"][name]["full_wall_seconds"], 0)
        self.assertEqual(receipt["costs"]["normalizer"]["status"], "passed")
        self.assertGreaterEqual(receipt["costs"]["normalizer"]["full_wall_seconds"], 0)
        self.assertGreaterEqual(receipt["full_wall_seconds_before_receipt"], 0)
        self.assertEqual(receipt["public_manifest"], M.state_inputs.reference(self.public / "manifest.json"))
        self.assertEqual(self.read(self.staging / "setup/original/raw/results.json"), self.summary)
        self.assertEqual(set(self.logged), {"status", "exit_code", "costs", "full_wall_seconds_before_receipt"})
        self.assertNotIn(str(self.root), json.dumps(self.logged))

    def assert_changed_original_refuses(self):
        self.assertEqual(self.publish(), 1)
        self.assertEqual(self.events[-1], "verify-sources")
        receipt = self.read(self.receipt)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["failure_sha256"],
                         hashlib.sha256(b"original-publication-input-changed").hexdigest())
        self.assertNotIn("public_manifest", receipt)

    def test_projection_source_drift_refuses_before_load_and_after_publication(self):
        for before in (True, False):
            if not before:
                self.setUp()
            with self.subTest(before_load=before):
                def change():
                    self.helpers.return_value = {"Scripts/fixture.py": "b" * 64}
                if before:
                    change()
                else:
                    self.after_publication = change
                self.assertEqual(self.publish(), 1)
                self.assertEqual(self.loader.call_count, 0 if before else 1)
                self.assertEqual(self.read(self.receipt)["failure_sha256"],
                                 hashlib.sha256(b"calibration-input-source-changed").hexdigest())
                self.assertNotIn("public_manifest", self.read(self.receipt))

    def test_changed_raw_root_summary_cannot_escape_original_readback(self):
        self.after_publication = lambda: write_document(self.raw / "results.json", dict(status="forged"))
        self.assert_changed_original_refuses()

    def test_added_original_after_projection_is_rejected(self):
        self.after_publication = lambda: write_document(self.raw / "setup/new.json", dict(extra="new evidence"))
        self.assert_changed_original_refuses()

    def test_removed_original_after_projection_is_rejected(self):
        self.after_publication = lambda: (self.calls / "before-compilation/command.stderr").unlink()
        self.assert_changed_original_refuses()

    def test_changed_supervised_call_after_projection_is_rejected(self):
        self.after_publication = lambda: write_document(
            self.calls / "before-compilation/results.json", dict(status="forged"))
        self.assert_changed_original_refuses()

    def test_original_sdk_verification_failure_cannot_return_success(self):
        self.projection.verify_sources.side_effect = ValueError("original SDK source changed")
        self.assertEqual(self.publish(), 1)
        self.projection.verify_sources.assert_called_once_with(self.raw, self.staging)
        receipt = self.read(self.receipt)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["costs"]["verify_sources"]["status"], "failed")
        self.assertGreaterEqual(receipt["costs"]["verify_sources"]["full_wall_seconds"], 0)
        self.assertEqual(receipt["costs"]["prepare_projection"]["result"], self.prepare_cost)
        self.assertEqual(receipt["costs"]["verify_publication"]["result"], self.verify_cost)

    def test_normalizer_rejection_cannot_fall_back_to_raw_publication(self):
        self.package.side_effect = ValueError("synthetic publication refusal")
        self.assertEqual(self.publish(), 1)
        self.projection.verify_publication.assert_not_called()
        self.projection.verify_sources.assert_not_called()
        self.assertFalse(self.public.exists())
        self.assertEqual(M.original_small_files(self.raw, self.calls), self.originals)
        receipt = self.read(self.receipt)
        self.assertEqual(receipt["costs"]["prepare_projection"]["result"], self.prepare_cost)
        self.assertEqual(receipt["costs"]["normalizer"]["status"], "failed")
        self.assertGreaterEqual(receipt["costs"]["normalizer"]["full_wall_seconds"], 0)

    def test_projection_failure_retains_its_elapsed_cost_and_stops_normalization(self):
        self.projection.prepare_projection.side_effect = ValueError("synthetic projection refusal")
        self.assertEqual(self.publish(), 1)
        self.package.assert_not_called()
        self.assertFalse(self.public.exists())
        receipt = self.read(self.receipt)
        self.assertEqual(set(receipt["costs"]), {"prepare_projection"})
        self.assertEqual(receipt["costs"]["prepare_projection"]["status"], "failed")
        self.assertGreaterEqual(receipt["costs"]["prepare_projection"]["full_wall_seconds"], 0)

    def test_publication_verification_failure_preserves_completed_costs(self):
        self.projection.verify_publication.side_effect = ValueError("synthetic normalized mismatch")
        self.assertEqual(self.publish(), 1)
        self.projection.verify_sources.assert_not_called()
        receipt = self.read(self.receipt)
        self.assertEqual(receipt["costs"]["prepare_projection"]["result"], self.prepare_cost)
        self.assertEqual(receipt["costs"]["normalizer"]["status"], "passed")
        self.assertEqual(receipt["costs"]["verify_publication"]["status"], "failed")
        self.assertGreaterEqual(receipt["costs"]["verify_publication"]["full_wall_seconds"], 0)

    def test_interrupted_publication_retains_incomplete_status_and_failed_stage_cost(self):
        self.projection.verify_sources.side_effect = KeyboardInterrupt
        self.assertEqual(self.publish(), 125)
        receipt = self.read(self.receipt)
        self.assertEqual(receipt["status"], "incomplete")
        self.assertEqual(receipt["costs"]["verify_sources"]["status"], "failed")
        self.assertGreaterEqual(receipt["costs"]["verify_sources"]["full_wall_seconds"], 0)

    def test_existing_public_or_staging_evidence_is_not_overwritten(self):
        self.public.mkdir()
        retained = self.public / "manifest.json"
        retained.write_bytes(b"retained original\n")
        self.assertEqual(self.publish(), 1)
        self.assertEqual(retained.read_bytes(), b"retained original\n")
        self.assertFalse(self.staging.exists())
        self.package.assert_not_called()
        self.projection.prepare_projection.assert_not_called()

    def test_existing_publication_receipt_is_never_overwritten_or_retried(self):
        self.assertEqual(self.publish(), 0)
        original = self.receipt.read_bytes()
        with self.assertRaisesRegex(ValueError, "preserve-publication-receipt"):
            M.publish(self.root)
        self.assertEqual(self.receipt.read_bytes(), original)
        self.package.assert_called_once()

    def test_unexpected_binary_or_symlink_source_is_refused_before_projection(self):
        binary = self.raw / "setup/object.o"
        binary.write_bytes(b"not-public")
        with self.assertRaisesRegex(ValueError, "unexpected-publication-file"):
            M.original_small_files(self.raw, self.calls)
        binary.unlink()
        (self.raw / "setup/link.json").symlink_to(self.raw / "results.json")
        with self.assertRaisesRegex(ValueError, "unexpected-publication-file"):
            M.original_small_files(self.raw, self.calls)
        self.projection.prepare_projection.assert_not_called()

    def test_dangling_source_root_is_not_silently_treated_as_missing(self):
        dangling = self.root / "dangling-calls"
        dangling.symlink_to(self.root / "missing-target", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "publication-source-type"):
            M.original_small_files(self.raw, dangling)


class NativeCalibrationEntryTests(ScratchTests):
    def test_helper_manifest_contains_exact_current_wrapper_and_workflow_bytes(self):
        hashes = M.helper_hashes()
        for relative in (
            "Scripts/validate-native-calibration-inputs.py",
            "Scripts/benchmark-inputs/native_calibration_inputs.py",
            "Scripts/benchmark-inputs/native_calibration_expectation.json",
            "Scripts/benchmark-inputs/native_calibration_publication.py",
            "Scripts/benchmark-inputs/sdk_content_seal.py",
            "Scripts/benchmark-inputs/select_sdk_roots.py",
            "Scripts/normalize-indexstore-evidence.py",
            ".github/workflows/native-calibration.yml",
        ):
            with self.subTest(relative=relative):
                self.assertEqual(hashes[relative], hashlib.sha256((ROOT / relative).read_bytes()).hexdigest())

    def test_installation_is_bound_before_importing_the_existing_machine_observer(self):
        measurement = self.root / "measurement-helper-raw/results.json"
        write_document(measurement, dict(install_interpreter=dict(before=dict(selected_path=sys.executable))))
        target = self.root / "already-installed-dependencies"
        binding = dict(package=dict(target=str(target)))
        observer = mock.Mock(name="macos_fields")
        calls = []

        def bind(path, repository, selected):
            calls.append("bind-existing-installation")
            self.assertEqual((path, repository, selected), (measurement, ROOT, Path(sys.executable)))
            return binding

        def load(name, path):
            calls.append("load-existing-observer")
            self.assertEqual(name, "calibration_machine_fields")
            self.assertEqual(path, ROOT / "Scripts/benchmark-measurement/machine_manifest.py")
            self.assertIn(str(target), sys.path)
            return SimpleNamespace(macos_fields=observer)

        self.patch(M.sys, "path", new=list(sys.path))
        self.patch(M.installation_binding, "bind", side_effect=bind)
        self.patch(M, "load", side_effect=load)
        self.assertEqual(M.bound_machine_fields(self.root), (observer, binding))
        self.assertEqual(calls, ["bind-existing-installation", "load-existing-observer"])

    def test_different_interpreter_cannot_import_or_reinstall_measurement_package(self):
        measurement = self.root / "measurement-helper-raw/results.json"
        write_document(measurement, dict(install_interpreter=dict(before=dict(selected_path=str(SCRIPT)))))
        bind = self.patch(M.installation_binding, "bind")
        load = self.patch(M, "load")
        with self.assertRaisesRegex(ValueError, "different-current-interpreter"):
            M.bound_machine_fields(self.root)
        bind.assert_not_called()
        load.assert_not_called()

    def invoke(self, stage, internal=False):
        argv = [str(SCRIPT), "--stage", stage, "--scratch-root", str(self.root)]
        if internal:
            argv.append("--execute-stage")
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            return M.main()

    def test_cli_uses_supervision_and_only_internal_stage_dispatch_executes_body(self):
        self.patch(M, "fixed_root", return_value=self.root)
        supervised = self.patch(M, "supervise", return_value=125)
        stage = self.patch(M, "stage", return_value=0)
        publish = self.patch(M, "publish", return_value=0)
        self.assertEqual(self.invoke("before-compilation"), 125)
        supervised.assert_called_once_with("before-compilation", self.root)
        stage.assert_not_called()
        publish.assert_not_called()
        self.assertEqual(self.invoke("after-generation", internal=True), 0)
        stage.assert_called_once_with("after-generation", self.root)
        self.assertEqual(self.invoke("publish"), 0)
        publish.assert_called_once_with(self.root)
        self.assertEqual(self.invoke("publish", internal=True), 1)
        publish.assert_called_once_with(self.root)

    def test_scratch_must_match_current_runner_temp_without_repository_overlap(self):
        self.patch(M.admission, "expectation", return_value=({}, "a" * 64))
        boundary = self.patch(M.admission, "evidence_boundary")
        with mock.patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}, clear=True):
            self.assertEqual(M.fixed_root(self.root), self.root)
            for path in (Path("relative"), self.root / ".." / self.root.name, Path("/"), ROOT):
                with self.subTest(path=path), self.assertRaises(ValueError):
                    M.fixed_root(path)
        with mock.patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "missing-current-scratch"):
            M.fixed_root(self.root)
        boundary.assert_called_once()
        with mock.patch.dict(os.environ, {"RUNNER_TEMP": str(ROOT)}, clear=True):
            with self.assertRaisesRegex(ValueError, "repository-scratch-overlap"):
                M.fixed_root(ROOT)


class NativeCalibrationWorkflowTests(unittest.TestCase):
    def test_workflow_is_manual_read_only_single_native_job(self):
        workflow = WORKFLOW.read_text()
        trigger = workflow.split("\non:\n", 1)[1].split("\npermissions:\n", 1)[0]
        self.assertEqual(re.findall(r"^  ([a-z_]+):", trigger, re.MULTILINE), ["workflow_dispatch"])
        self.assertIn("source_sha:\n", trigger)
        self.assertIn("required: true", trigger)
        self.assertIn("type: string", trigger)
        permissions = workflow.split("\npermissions:\n", 1)[1].split("\nconcurrency:\n", 1)[0]
        self.assertEqual(permissions.strip(), "contents: read")
        self.assertIn("group: native-observer-sdk-admission", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("if: github.repository == 'ictechgy/cartograph'", workflow)
        self.assertEqual(re.findall(r"^  ([A-Za-z_]+):", workflow.split("\njobs:\n", 1)[1], re.MULTILINE),
                         ["calibration"])
        self.assertIn("    runs-on: macos-26\n", workflow)
        self.assertIn("    timeout-minutes: 45\n", workflow)
        self.assertIn("DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer", workflow)
        for forbidden in ("continue-on-error:", "strategy:", "matrix:", "environment:", "secrets:"):
            self.assertNotIn(forbidden, workflow)

    def guard(self, changes=None):
        body = workflow_step("Require exact dispatch source and native image")
        shell = textwrap.dedent(body.split("        run: |\n", 1)[1])
        match = re.fullmatch(r"python3 - <<'PY'\n(.*?)\nPY\s*", shell, re.DOTALL)
        self.assertIsNotNone(match)
        env = dict(SOURCE_SHA="a" * 40, DISPATCH_SHA="a" * 40,
                   ImageOS="macos26", ImageVersion="20260907.0351.1")
        env.update(changes or {})
        with mock.patch.dict(os.environ, env, clear=True):
            exec(compile(match.group(1), str(WORKFLOW) + ":dispatch-guard", "exec"), {})

    def test_dispatch_guard_accepts_only_exact_sha_and_image(self):
        self.guard()
        for changes in (
            {"SOURCE_SHA": "main"}, {"SOURCE_SHA": "a" * 39}, {"SOURCE_SHA": "A" * 40},
            {"SOURCE_SHA": "a" * 40 + "\n"}, {"DISPATCH_SHA": "b" * 40},
            {"ImageOS": "macos15"}, {"ImageVersion": "20260908.1"},
            {"ImageVersion": ""},
        ):
            with self.subTest(changes=changes), self.assertRaises(AssertionError):
                self.guard(changes)

    def test_checkout_actions_and_artifact_actions_are_exact_pins(self):
        workflow = WORKFLOW.read_text()
        self.assertEqual(re.findall(r"^\s+(?:- )?uses: (\S+)\s*$", workflow, re.MULTILINE),
                         [CHECKOUT, UPLOAD, UPLOAD, UPLOAD, UPLOAD, UPLOAD])
        checkout = workflow.split("- uses: " + CHECKOUT, 1)[1].split("\n      - ", 1)[0]
        self.assertIn("ref: ${{ inputs.source_sha }}", checkout)
        self.assertIn("persist-credentials: false", checkout)
        self.assertLess(workflow.index("name: Require exact dispatch source and native image"),
                        workflow.index("- uses: " + CHECKOUT))

    def test_checkout_and_contracts_precede_any_install_or_compilation(self):
        workflow = WORKFLOW.read_text()
        verify = workflow_step("Verify exact checkout and local contracts")
        self.assertIn('test "$(git rev-parse HEAD)" = "$SOURCE_SHA"', verify)
        self.assertIn('test -z "$(git status --porcelain)"', verify)
        self.assertIn("python3 Scripts/verify-native-calibration-contract.py", verify)
        self.assertIn("-p 'test_native_calibration*.py'", verify)
        names = [
            "Verify exact checkout and local contracts",
            "Prepare the existing isolated measurement installation",
            "Capture SDK and toolchain before covered compilation",
            "Build the existing source-pinned tools and validation fixture",
            "Compile the existing mixed validation generations",
            "Bind actual compiler search paths",
            "Verify precompilation content and discovery relation",
            "Execute the fixed 32 actual-engine calibration invocations",
            "Verify content after the completed calibration attempt",
        ]
        positions = [workflow.index("name: " + name) for name in names]
        self.assertEqual(positions, sorted(positions))
        for name in names[:-1]:
            self.assertNotIn("        if:", workflow_step(name))

    def test_workflow_uses_supervision_and_retains_only_gated_public_artifacts(self):
        names = {
            "before-compilation": "Capture SDK and toolchain before covered compilation",
            "after-generation": "Verify precompilation content and discovery relation",
            "after-calibration": "Verify content after the completed calibration attempt",
            "publish": "Prepare safe SDK candidate evidence",
        }
        for stage, name in names.items():
            with self.subTest(stage=stage):
                body = workflow_step(name)
                self.assertIn("python3 -I -S -B Scripts/validate-native-calibration-inputs.py", body)
                self.assertIn('--stage ' + stage + ' --scratch-root "$RUNNER_TEMP"', body)
                self.assertNotIn("--execute-stage", body)
        post = workflow_step(names["after-calibration"])
        self.assertIn("always() && !cancelled()", post)
        self.assertIn("steps.after_generation.outcome == 'success'", post)
        self.assertIn("steps.engines.outcome != 'skipped'", post)
        engine = workflow_step("Execute the fixed 32 actual-engine calibration invocations")
        self.assertIn("--calibration-mode native-observer-v1", engine)
        actual = workflow_step("Retain normalized calibration evidence")
        sdk = workflow_step("Retain normalized SDK candidate evidence")
        self.assertIn("steps.engines_public.outputs.ready == 'true'", actual)
        self.assertIn("steps.sdk_public.outcome == 'success'", sdk)
        self.assertIn("path: ${{ runner.temp }}/actual-arm-correctness-public/", actual)
        self.assertIn("path: ${{ runner.temp }}/native-calibration-sdk-public/", sdk)
        for body in (actual, sdk):
            self.assertIn("if-no-files-found: error", body)
            self.assertIn("retention-days: 14", body)
            self.assertNotRegex(body, r"path:.*(?:-raw|staging|runner\.temp\s*}}/\s*$)")

    def test_shared_originals_use_existing_normalizers_and_public_only_gates(self):
        workflow = WORKFLOW.read_text()
        groups = [
            ("Prepare normalized measurement evidence", "Preserve normalized measurement evidence",
             "Scripts/normalize-indexstore-evidence.py", "measurement_normalize.outcome == 'success'",
             "measurement-helper-public"),
            ("Prepare safe SDK discovery evidence", "Preserve normalized SDK discovery evidence",
             "Scripts/normalize-sdk-discovery-evidence.py", "sdk_normalize.outputs.ready == 'true'",
             "sdk-discovery-public"),
            ("Prepare portable public evidence", "Preserve normalized comparison evidence",
             "Scripts/normalize-indexstore-bundles.py", "normalize.outputs.ready == 'true'",
             "indexstore-cli-public"),
        ]
        for prepare_name, upload_name, script, gate, output in groups:
            with self.subTest(output=output):
                prepare, upload = workflow_step(prepare_name), workflow_step(upload_name)
                self.assertIn("python3 " + script, prepare)
                self.assertIn("timeout-minutes: 4", prepare)
                self.assertIn("always() && !cancelled()", prepare)
                self.assertIn('"$RUNNER_TEMP/' + output + '"', prepare)
                self.assertIn("if: always() && steps." + gate, upload)
                self.assertIn("uses: " + UPLOAD, upload)
                self.assertIn("path: ${{ runner.temp }}/" + output + "/", upload)
                self.assertIn("if-no-files-found: error", upload)
                self.assertIn("retention-days: 14", upload)
                self.assertNotRegex(upload, r"path:.*(?:-raw|staging)")
                self.assertLess(workflow.index("name: " + prepare_name), workflow.index("name: " + upload_name))


if __name__ == "__main__":
    unittest.main()
