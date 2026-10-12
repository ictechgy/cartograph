"""전체 제어 흐름의 비용 구간과 완료 실패 뒤 종료 검사를 고정한다."""

import argparse
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import correctness_controller as controller


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repository"
        self.repo.mkdir()
        self.project = self.root / "project"
        self.project.mkdir()
        self.args = argparse.Namespace(
            repository=self.repo,
            lifecycle=self.root / "life/results.json",
            setup=self.root / "tools/results.json",
            measurement=self.root / "measurement/results.json",
            scratch_root=self.root,
        )
        self.plan = dict(
            input_roots=[str(self.project)],
            engine_config=dict(project=str(self.project), developer_directory=str(self.root)),
            inputs={},
            prior_costs={},
        )
        self.binding = dict(package={"target": str(self.root / "package")}, python={})
        self.contract_result = dict(status="passed", exit_code=0)
        self.phase = dict(completed=True, returncode=0, passed=True, wall_seconds=0.0)
        self.raw = self.root / "actual-arm-correctness-raw"

    def execute(self, receipt_error=None):
        def command(*args):
            if self.phase["completed"]:
                controller.save(
                    self.raw / "results.json", dict(status="passed" if self.phase["returncode"] == 0 else "failed")
                )
            controller.save(self.raw / "setup/whole-state.json", self.phase)
            return self.phase

        with mock.patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}), mock.patch.object(
            controller, "isolation"
        ), mock.patch.object(controller.state_inputs, "prepare", return_value=self.plan), mock.patch.object(
            controller.state_inputs, "bind_sdk_discovery"
        ), mock.patch.object(
            controller.installation_binding, "bind", return_value=self.binding
        ), mock.patch.object(
            controller.command_runner, "command", side_effect=command
        ) as commands, mock.patch.object(
            controller.contract_prerequisites, "run", return_value=self.contract_result
        ), mock.patch.object(
            controller.isolated_measure,
            "verify_runtime_receipt",
            return_value={"status": "passed"},
            side_effect=receipt_error,
        ), mock.patch.object(
            controller.state_inputs, "guard", return_value={"status": "passed"}
        ) as guard:
            result = controller.execute(self.args)
        self.commands = commands
        return result, guard

    def test_success_closes_contiguous_outer_components_and_receipts(self):
        result, guard = self.execute()
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(guard.call_count, 1)
        phases = result["controller_intervals"]
        self.assertEqual(
            [p["name"] for p in phases],
            ["preparation", "whole-state-supervision-call", "terminal-verification-or-failed-work"],
        )
        for previous, current in zip(phases, phases[1:]):
            self.assertEqual(previous["end"], current["start"])
        self.assertAlmostEqual(sum(p["seconds"] for p in phases), result["total_wall_seconds_before_receipt"])
        self.assertEqual(json.loads((self.raw / "setup/controller-result.json").read_text()), result)
        self.assertIsNone(result["performance_ratio"])

    def test_completed_failure_runs_guard_even_if_runtime_receipt_is_unavailable(self):
        self.phase.update(returncode=9, passed=False)
        result, guard = self.execute(ValueError("missing runtime receipt"))
        self.assertEqual(result["whole_state_process"]["returncode"], 9)
        self.assertEqual(guard.call_count, 1)
        self.assertEqual(result["terminal_guard"]["status"], "passed")
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["exit_code"], 125)

    def test_incomplete_state_does_not_claim_terminal_guard(self):
        self.phase.update(completed=False, returncode=125, passed=False)
        result, guard = self.execute()
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(guard.call_count, 0)
        self.assertNotIn("terminal_guard", result)

    def test_failed_contracts_prevent_whole_state_and_preserve_exit(self):
        self.contract_result.update(status="failed", exit_code=1)
        result, guard = self.execute()
        self.assertEqual(result["exit_code"], 1)
        self.assertEqual(result["contracts"], self.contract_result)
        failure = json.loads((self.raw / "results.json").read_text())
        self.assertEqual(failure["exit_code"], 1)
        self.assertFalse(failure["whole_state_started"])
        self.commands.assert_not_called()
        guard.assert_not_called()

    def test_incomplete_contracts_remain125_without_next_phase(self):
        self.contract_result.update(status="incomplete", exit_code=125)
        result, guard = self.execute()
        self.assertEqual(result["exit_code"], 125)
        failure = json.loads((self.raw / "results.json").read_text())
        self.assertEqual(failure["exit_code"], 125)
        self.assertFalse(failure["whole_state_started"])
        self.commands.assert_not_called()
        guard.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
