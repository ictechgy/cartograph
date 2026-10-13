"""공유 프로필은 두 실제 bootstrap과 발신 환경 영수증 모두에 적용되어야 한다."""

import copy
import hashlib
import json
from pathlib import Path
import sys
import subprocess
import unittest
from unittest import mock

import isolated_measure
import runtime_identity
import startup_binding
import startup_profile
import test_runtime_bootstrap as fixtures

ROOT = Path(__file__).resolve().parent


class StartupRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.BootstrapTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.f = self.fixture
        self.environment = runtime_identity.private_environment(self.f.root / "engine-private")
        target = self.f.root / "correctness_controller.py"
        target.write_text("value = 1\n")
        request = self.f.root / "startup-request.json"
        report = self.f.root / "startup-observation.json"
        startup_profile.save(
            request,
            startup_profile.request(
                self.environment, Path(sys.executable), target, [Path(startup_profile.__file__).resolve(), target]
            ),
        )
        attempt = subprocess.run(
            [
                sys.executable,
                "-I",
                "-S",
                "-B",
                str(Path(startup_profile.__file__).resolve()),
                "--request",
                str(request),
                "--sha256",
                hashlib.sha256(request.read_bytes()).hexdigest(),
                "--report",
                str(report),
            ],
            env=self.environment,
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(attempt.returncode, 0, attempt.stderr)
        observed = json.loads(report.read_text())
        self.assertEqual(observed["status"], "passed")
        self.profile = startup_profile.profile(observed["early"])
        self.f.config.update(schema_version=2, startup_profile=self.profile)
        for path in [ROOT / "startup_profile.py", ROOT / "startup_binding.py", isolated_measure.HELPER]:
            self.f.config["code_files"][str(path)] = runtime_identity.file_identity(path)["sha256"]
        self.write_config()

    def write_config(self):
        self.f.receipt.write_text(json.dumps(self.f.config, sort_keys=True))
        self.digest = hashlib.sha256(self.f.receipt.read_bytes()).hexdigest()

    def request(self):
        command = isolated_measure.bootstrap_command(self.f.receipt, self.digest, self.f.script, self.f.report)
        return isolated_measure.bind_launch(command, self.f.receipt, self.digest, self.f.config, self.environment)

    def verify(self, code=0):
        return isolated_measure.verify_runtime_receipt(
            self.f.report, self.f.config, self.digest, self.f.script, [], code, self.environment
        )

    def test_actual_bound_startup_before_and_after(self):
        request = self.request()
        result = self.f.invoke(self.environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = self.verify()
        self.assertEqual(receipt["environment_request_sha256"], request["sha256"])
        self.assertEqual(receipt["environment_before"], receipt["environment_after"])
        self.assertEqual(startup_profile.profile(receipt["environment_before"]), self.profile)

    def test_missing_environment_request_refuses_before_workload(self):
        result = self.f.invoke(self.environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertFalse(json.loads(self.f.report.read_text())["workload_started"])

    def test_changed_profile_request_refuses_before_workload(self):
        self.request()
        path = startup_binding.launch_path(self.f.report)
        row = json.loads(path.read_text())
        row["startup_profile_sha256"] = "f" * 64
        path.write_text(json.dumps(row))
        result = self.f.invoke(self.environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_unexpected_outgoing_environment_key_refuses(self):
        self.request()
        result = self.f.invoke(dict(self.environment, EXTRA_UNACCEPTED="synthetic"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_changed_expected_environment_refuses(self):
        self.request()
        result = self.f.invoke(dict(self.environment, TZ="different"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_workload_environment_mutation_fails_terminal_guard(self):
        self.f.script.write_text('import os; os.environ["UNEXPECTED_AFTER"]="synthetic"\n')
        self.f.config["code_files"][str(self.f.script)] = runtime_identity.file_identity(self.f.script)["sha256"]
        self.write_config()
        self.request()
        result = self.f.invoke(self.environment)
        self.assertEqual(result.returncode, 1)
        with self.assertRaises(ValueError):
            self.verify(1)

    def test_request_mutation_after_execution_is_not_verified(self):
        self.request()
        result = self.f.invoke(self.environment)
        self.assertEqual(result.returncode, 0)
        path = startup_binding.launch_path(self.f.report)
        row = json.loads(path.read_text())
        row["requested_environment"]["sha256"] = "e" * 64
        path.write_text(json.dumps(row))
        with self.assertRaises(ValueError):
            self.verify()

    def test_actual_observer_and_engine_share_profile_but_bind_distinct_environments(self):
        report = self.f.root / "engine/runtime-result.json"
        command = isolated_measure.bootstrap_command(self.f.receipt, self.digest, self.f.script, report)
        observer = runtime_identity.private_environment(self.f.root / "observer-private")
        result = isolated_measure.run(
            command,
            self.f.root,
            self.f.root / "measurement/whole",
            self.f.receipt,
            self.digest,
            self.environment,
            observer,
            timeout=5,
        )
        self.assertEqual(result["status"], "passed", result)
        engine = json.loads(report.read_text())
        self.assertEqual(startup_profile.profile(engine["environment_before"]), self.profile)
        self.assertEqual(startup_profile.profile(result["runtime"]["environment_before"]), self.profile)
        self.assertNotEqual(
            engine["environment_before"]["requested_environment"],
            result["runtime"]["environment_before"]["requested_environment"],
        )

    def test_profile_boolean_schema_and_unknown_addition_refuse(self):
        for mutate in [lambda p: p.update(schema_version=True), lambda p: p.update(addition={"unknown": "value"})]:
            with self.subTest(mutate=mutate):
                bad = copy.deepcopy(self.profile)
                mutate(bad)
                with self.assertRaises(ValueError):
                    startup_binding.validate_profile(bad)

    def test_darwin_addition_requires_exact_prospective_value_hash(self):
        expected = startup_profile.environment_request(self.environment)
        accepted = startup_profile.observe_request(
            expected, dict(self.environment, __CF_USER_TEXT_ENCODING="synthetic-a"), platform="darwin"
        )
        other = startup_profile.observe_request(
            expected, dict(self.environment, __CF_USER_TEXT_ENCODING="synthetic-b"), platform="darwin"
        )
        with self.assertRaises(ValueError):
            startup_profile.verify_observation(other, expected, startup_profile.profile(accepted))


if __name__ == "__main__":
    unittest.main()
