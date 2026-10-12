"""합성 영수증으로 게시 판정의 실제 파일 결합과 형식 경계를 검증한다."""

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import publish_correctness as publication
import state_inputs


class CompletionBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.raw = Path(self.temp.name).resolve()
        self.runtime = dict(
            python=dict(path=sys.executable, sha256="b" * 64, bytes=20),
            code_files={str(publication.ROOT / "state_worker.py"): "c" * 64},
            package=dict(target=str(self.raw / "private-package"), content=dict(content_sha256="a" * 64)),
        )
        self.plan = dict(accepted=dict(sdk_content_identity=None))
        self.write("setup/runtime.json", self.runtime)
        self.write("setup/plan.json", self.plan)
        runtime_ref = state_inputs.reference(self.raw / "setup/runtime.json")
        plan_ref = state_inputs.reference(self.raw / "setup/plan.json")
        arguments = [
            "--plan",
            plan_ref["path"],
            "--plan-sha256",
            plan_ref["sha256"],
            "--runtime",
            runtime_ref["path"],
            "--runtime-sha256",
            runtime_ref["sha256"],
            "--output",
            str(self.raw),
        ]
        command = publication.controller.isolated_measure.bootstrap_command(
            Path(runtime_ref["path"]),
            runtime_ref["sha256"],
            publication.ROOT / "state_worker.py",
            self.raw / "setup/state-runtime/runtime-result.json",
            arguments,
        )
        self.phase = dict(
            command=command,
            completed=True,
            passed=True,
            returncode=0,
            observed_returncode=0,
            failure=None,
            cleanup_root_unfinished=False,
            cleanup_signals=[],
        )
        modules = dict(psutil=dict(path=str(self.raw / "private-package/psutil/__init__.py"), kind="private-package"))
        snapshot = dict(
            modules=modules,
            sha256=hashlib.sha256(json.dumps(modules, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        )
        package = dict(
            matches=True, expected_sha256="a" * 64, actual_sha256="a" * 64, actual=dict(content_sha256="a" * 64)
        )
        self.receipt = dict(
            runtime_receipt_sha256=runtime_ref["sha256"],
            entrypoint=dict(path=str(publication.ROOT / "state_worker.py"), sha256="c" * 64),
            selected_code_files=self.runtime["code_files"],
            arguments_sha256=hashlib.sha256(json.dumps(arguments, separators=(",", ":")).encode()).hexdigest(),
            exit_code=0,
            observed_exit_code=0,
            workload_started=True,
            python=self.runtime["python"],
            status="passed",
            code_after=dict(status="passed"),
            package_before=package,
            package_after=package,
            modules_before=snapshot,
            modules_after=snapshot,
        )
        self.state = dict(
            role="single-restored-state-correctness-validation",
            final_evidence=False,
            status="passed",
            exit_code=0,
            order="AB",
            arms=[
                dict(arm=name, status="passed", exit_code=0, may_continue=True) for name in ["baseline", "cartograph"]
            ],
        )
        self.record = dict(
            schema_version=1,
            status="passed",
            exit_code=0,
            final_evidence=False,
            role="actual-arm-correctness-controller",
            performance_ratio=None,
            superiority_claim=None,
            preparation_wall_seconds=0,
            controller_intervals=[],
            whole_state_process=copy.deepcopy(self.phase),
            contracts=dict(status="passed", exit_code=0),
            terminal_guard=dict(status="passed", generation=self.plan["accepted"]),
            runtime_source_inputs_unchanged=True,
            state_runtime=copy.deepcopy(self.receipt),
            state_result=copy.deepcopy(self.state),
            total_wall_seconds_before_receipt=0,
            cost_accounting="synthetic schema test only",
        )
        self.rewrite()

    def write(self, name, value):
        p = self.raw / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(value))

    def rewrite(self):
        for name, value in [
            ("setup/whole-state.json", self.phase),
            ("setup/state-runtime/runtime-result.json", self.receipt),
            ("results.json", self.state),
            ("setup/controller-result.json", self.record),
        ]:
            self.write(name, value)

    def result(self):
        with mock.patch.object(publication.controller.contract_prerequisites, "verify", return_value={}):
            return publication.completion_receipt(self.raw, dict(exit_code=0))

    def test_consistent_synthetic_files_bind_all_five_hashes(self):
        row = self.result()
        self.assertEqual(row["status"], "verified")
        self.assertEqual(row["outcome"], "passed")
        self.assertEqual(set(row["bound_file_sha256"]), {"phase", "runtime", "state", "plan", "runtime_inputs"})

    def test_missing_actual_phase_or_runtime_is_not_success(self):
        for name in ["setup/whole-state.json", "setup/state-runtime/runtime-result.json"]:
            with self.subTest(name=name):
                data = (self.raw / name).read_bytes()
                (self.raw / name).unlink()
                self.assertEqual(self.result()["status"], "unavailable")
                (self.raw / name).write_bytes(data)

    def test_embedded_state_cannot_override_actual_failure(self):
        self.state.update(status="failed", exit_code=1)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_embedded_runtime_cannot_override_actual_failure(self):
        self.receipt.update(status="failed", exit_code=9)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_boolean_exit_in_any_success_layer_is_refused(self):
        for value, key in [
            (self.record, "exit_code"),
            (self.phase, "returncode"),
            (self.phase, "observed_returncode"),
            (self.state, "exit_code"),
            (self.receipt, "exit_code"),
            (self.receipt, "observed_exit_code"),
        ]:
            with self.subTest(key=key):
                old = value[key]
                value[key] = False
                self.rewrite()
                self.assertEqual(self.result()["status"], "unavailable")
                value[key] = old
        self.rewrite()

    def test_untyped_embedded_duplicate_cannot_equal_typed_actual_zero(self):
        self.record["state_result"]["exit_code"] = False
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_changed_command_or_terminal_generation_is_refused(self):
        self.phase["command"][-1] = "/other-output"
        self.record["whole_state_process"] = copy.deepcopy(self.phase)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_completion_hashes_must_match_the_actual_staged_manifest(self):
        completion = self.result()
        paths = {
            "phase": "setup/whole-state.json",
            "runtime": "setup/state-runtime/runtime-result.json",
            "state": "results.json",
            "plan": "setup/plan.json",
            "runtime_inputs": "setup/runtime.json",
        }
        manifest = dict(
            files=[dict(path="setup/controller-result.json", original_raw_sha256=completion["sha256"])]
            + [
                dict(path=paths[key], original_raw_sha256=value)
                for key, value in completion["bound_file_sha256"].items()
            ]
        )
        publication.verify_completion_manifest(completion, manifest)
        manifest["files"][-1]["original_raw_sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            publication.verify_completion_manifest(completion, manifest)

    def test_completed_failure_is_retained_without_success_certification(self):
        self.record.update(status="failed", exit_code=9)
        self.rewrite()
        row = publication.completion_receipt(self.raw, dict(exit_code=9))
        self.assertEqual(row["outcome"], "retained-failed")
        self.assertNotIn("bound_file_sha256", row)


if __name__ == "__main__":
    unittest.main(verbosity=2)
