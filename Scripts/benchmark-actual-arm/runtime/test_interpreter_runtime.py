"""선택 요청과 실제 보고 경로를 새 스키마에서만 구별한다."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import unittest

import interpreter_relation
import isolated_measure
import runtime_identity
import startup_binding
import startup_profile
import test_startup_runtime

ROOT = Path(__file__).resolve().parent


class InterpreterRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.owner = test_startup_runtime.StartupRuntimeTests()
        self.owner.setUp()
        self.addCleanup(self.owner.doCleanups)
        self.f = self.owner.f
        self.environment = self.owner.environment
        source = ROOT / "interpreter_relation.py"
        self.f.config["code_files"][str(source)] = runtime_identity.file_identity(source)["sha256"]
        inputs = dict(self.f.config["code_files"])
        actual = startup_profile.interpreter(sys.executable)
        self.relation = dict(
            schema_version=1, role="selected-probe-interpreter-relation", collection_sha256="1" * 64,
            probe=1, request_sha256="2" * 64, observation_sha256="3" * 64, process_sha256="4" * 64,
            source_inputs_sha256=startup_profile.sha(startup_profile.encoded(inputs)),
            startup_profile_sha256=startup_profile.sha(startup_profile.encoded(self.owner.profile)),
            source_inputs=inputs, requested_interpreter=actual, reported_interpreter=actual,
            scope=interpreter_relation.SCOPE,
        )
        self.f.config.update(schema_version=3, interpreter_relation=self.relation)
        self.owner.write_config()

    def command(self):
        return isolated_measure.bootstrap_command(
            self.f.receipt, self.owner.digest, self.f.script, self.f.report, runtime=self.f.config
        )

    def launch(self):
        command = self.command()
        isolated_measure.bind_launch(command, self.f.receipt, self.owner.digest, self.f.config, self.environment)
        return subprocess.run(command, env=self.environment, capture_output=True, text=True, timeout=15)

    def test_actual_runtime_records_exact_before_after_relation(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        row = self.owner.verify()
        self.assertEqual(row["interpreter_before"], self.relation["reported_interpreter"])
        self.assertEqual(row["interpreter_after"], row["interpreter_before"])

    def test_request_uses_selected_spelling_instead_of_parent_report(self):
        selected = self.f.root / "selected-python"
        selected.symlink_to(sys.executable)
        self.relation["requested_interpreter"] = startup_profile.interpreter(selected)
        self.f.config["python"]["path"] = str(selected)
        self.owner.write_config()
        command = self.command()
        self.assertEqual(command[0], str(selected))
        command[0] = sys.executable
        with self.assertRaises(ValueError):
            isolated_measure.engine_request(command, self.f.receipt, self.owner.digest, self.f.config)

    def test_unobserved_reported_alias_refuses_before_workload(self):
        alias = self.f.root / "unobserved-python"
        alias.symlink_to(sys.executable)
        self.relation["reported_interpreter"] = startup_profile.interpreter(alias)
        self.owner.write_config()
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertFalse(json.loads(self.f.report.read_text())["workload_started"])

    def test_environment_request_relation_substitution_refuses(self):
        command = self.command()
        isolated_measure.bind_launch(command, self.f.receipt, self.owner.digest, self.f.config, self.environment)
        path = startup_binding.launch_path(self.f.report)
        row = json.loads(path.read_text())
        row["interpreter_relation_sha256"] = "f" * 64
        path.write_text(json.dumps(row))
        result = subprocess.run(command, env=self.environment, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_receipt_reported_path_substitution_refuses(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        row = json.loads(self.f.report.read_text())
        alias = self.f.root / "different-spelling"
        alias.symlink_to(sys.executable)
        row["python"]["path"] = str(alias)
        self.f.report.write_text(json.dumps(row))
        with self.assertRaises(ValueError):
            self.owner.verify()

    def test_schema_two_cannot_gain_relation_admission(self):
        self.f.config["schema_version"] = 2
        self.owner.write_config()
        result = self.f.invoke(self.environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_both_actual_engine_and_observer_use_schema_three(self):
        engine_report = self.f.root / "engine/runtime-result.json"
        command = isolated_measure.bootstrap_command(
            self.f.receipt, self.owner.digest, self.f.script, engine_report, runtime=self.f.config
        )
        observer_environment = runtime_identity.private_environment(self.f.root / "observer-private")
        result = isolated_measure.run(command, self.f.root, self.f.root / "measured/whole", self.f.receipt,
                                      self.owner.digest, self.environment, observer_environment, timeout=5)
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["command"][0], self.f.config["python"]["path"])
        for receipt in [result["runtime"], result["engine_runtime"]]:
            self.assertEqual(receipt["interpreter_before"], self.relation["reported_interpreter"])
            self.assertEqual(receipt["interpreter_after"], receipt["interpreter_before"])


if __name__ == "__main__":
    unittest.main()
