"""다른 호출 별칭을 원래 설치 선택으로 한 번만 돌리고 실제 정체성 경계를 보존한다."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

import installation_binding
import selected_launch
import test_installation_binding as fixtures


class Replaced(Exception):
    pass


class SelectedLaunchTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.InstallationTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.selected = self.root / "selected-python"
        self.selected.symlink_to(Path(sys.executable).resolve())
        self.current = self.root / "current-python"
        self.current.symlink_to(Path(sys.executable).resolve())
        self.args = argparse.Namespace(
            repository=self.fixture.repository,
            lifecycle=self.root / "lifecycle.json",
            setup=self.root / "tools.json",
            measurement=self.fixture.output / "results.json",
            scratch_root=self.root,
            selected_launch_sha256=None,
        )
        self.attempt = self.root / "actual-arm-correctness-attempt"
        self.attempt.mkdir()
        self.sources = {str(Path(__file__).resolve()): hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        for row in self.fixture.results["phases"].values():
            row["command"] = list(row["command"])
            row["command"][0] = str(self.selected)
        self.fixture.install = self.fixture.results["phases"]["install"]
        with mock.patch.object(sys, "executable", str(self.selected)):
            self.fixture.add_prospective_receipt()
        self.env = selected_launch.private_environment(self.root, create=True)

    def save(self, path, value):
        with Path(path).open("x") as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")

    def prepare(self, current=None, execve=None):
        return selected_launch.prepare(
            self.args,
            self.root,
            Path(current or self.current),
            lambda: self.sources,
            self.save,
            execve=execve or mock.Mock(side_effect=Replaced),
            environment=self.env,
        )

    def request(self):
        return json.loads((self.attempt / "selected-launch-request.json").read_text())

    def replacement(self):
        path = self.attempt / "selected-launch-request.json"
        self.args.selected_launch_sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
        return self.prepare(self.selected)

    def test_actual_alias_spelling_hits_original_guard_then_selected_spelling_passes(self):
        command = [str(self.current), "-I", "-S", "-B", "-c", "import sys; print(sys.executable)"]
        observed = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(observed.returncode, 0, observed.stderr)
        self.assertNotEqual(observed.stdout.strip(), str(self.selected))
        with self.assertRaisesRegex(ValueError, "Prior interpreter spellings differ"):
            installation_binding.bind(self.args.measurement, self.args.repository, Path(observed.stdout.strip()))
        observed = subprocess.run(
            [str(self.selected), *command[1:]], env=self.env, capture_output=True, text=True, timeout=10
        )
        # 프레임워크 런처가 표시 경로를 바꾸는 플랫폼은 선택 성공을 추정하지 않는다.
        if observed.stdout.strip() == str(self.selected):
            bound = installation_binding.bind(
                self.args.measurement, self.args.repository, Path(observed.stdout.strip())
            )
            self.assertEqual(bound["python"]["path"], str(self.selected))
        else:
            with self.assertRaisesRegex(ValueError, "Prior interpreter spellings differ"):
                installation_binding.bind(self.args.measurement, self.args.repository, Path(observed.stdout.strip()))

    def test_one_exact_selected_exec_preserves_private_environment_and_original_arguments(self):
        execute = mock.Mock(side_effect=Replaced)
        with self.assertRaises(Replaced):
            self.prepare(execve=execute)
        execute.assert_called_once()
        executable, argv, environment = execute.call_args.args
        self.assertEqual(executable, str(self.selected))
        self.assertEqual(argv[:-2], selected_launch.command(self.args, self.selected))
        self.assertEqual(argv[-2], "--selected-launch-sha256")
        self.assertEqual(environment, self.env)
        request = self.request()
        self.assertEqual(request["mode"], "one-exec")
        self.assertEqual(request["initial_interpreter"]["selected_path"], str(self.current))
        self.assertNotIn("environment", request)
        bound, record = self.replacement()
        self.assertEqual(bound["python"]["path"], str(self.selected))
        self.assertEqual(record["observation"]["status"], "selected-interpreter-bound")
        self.assertEqual(record["observation"]["actual_interpreter"]["selected_path"], str(self.selected))

    def test_already_selected_process_records_zero_exec(self):
        execute = mock.Mock(side_effect=AssertionError("unexpected exec"))
        bound, record = self.prepare(self.selected, execute)
        execute.assert_not_called()
        self.assertEqual(record["request"]["mode"], "direct")
        self.assertEqual(bound["python"]["path"], str(self.selected))

    def test_replacement_that_still_reports_other_spelling_fails_without_second_exec(self):
        with self.assertRaises(Replaced):
            self.prepare()
        self.args.selected_launch_sha256 = hashlib.sha256(
            (self.attempt / "selected-launch-request.json").read_bytes()
        ).hexdigest()
        execute = mock.Mock()
        with self.assertRaisesRegex(ValueError, "Prior interpreter spellings differ"):
            self.prepare(self.current, execute)
        execute.assert_not_called()
        self.assertFalse((self.attempt / "selected-launch-observation.json").exists())

    def test_identical_bytes_at_different_physical_file_are_refused(self):
        copied = self.root / "copied-python"
        copied.write_bytes(Path(sys.executable).read_bytes())
        with self.assertRaisesRegex(ValueError, "physical interpreter"):
            self.prepare(copied)
        self.assertFalse((self.attempt / "selected-launch-request.json").exists())

    def test_changed_receipt_or_source_after_exclusive_write_prevents_exec(self):
        original = self.save
        for kind in ["receipt", "source"]:
            with self.subTest(kind=kind):

                def mutate(path, value):
                    original(path, value)
                    if kind == "receipt":
                        self.args.measurement.write_text("{}")
                    else:
                        self.sources = {**self.sources, "unexpected": "a" * 64}

                execute = mock.Mock()
                with mock.patch.object(self, "save", side_effect=mutate), self.assertRaises(ValueError):
                    self.prepare(execve=execute)
                execute.assert_not_called()
                (self.attempt / "selected-launch-request.json").unlink()
                self.fixture.write()
                self.sources.pop("unexpected", None)

    def test_marker_without_original_request_or_changed_request_refuses(self):
        self.args.selected_launch_sha256 = "a" * 64
        with self.assertRaises((ValueError, OSError)):
            self.prepare(self.selected)
        self.args.selected_launch_sha256 = None
        with self.assertRaises(Replaced):
            self.prepare()
        with self.assertRaises(ValueError):
            self.prepare(self.selected)

    def test_replacement_arguments_or_sources_changed_are_refused(self):
        with self.assertRaises(Replaced):
            self.prepare()
        original = self.args.setup
        self.args.setup = self.root / "different.json"
        with self.assertRaises(ValueError):
            self.replacement()
        self.args.setup = original
        self.sources["changed"] = "b" * 64
        with self.assertRaises(ValueError):
            self.replacement()

    def test_existing_request_or_observation_cannot_be_reused(self):
        with self.assertRaises(Replaced):
            self.prepare()
        with self.assertRaises(ValueError):
            self.prepare()
        self.replacement()
        with self.assertRaises(ValueError):
            self.replacement()

    def test_exec_error_is_original_failure_without_success_observation(self):
        execute = mock.Mock(side_effect=OSError("synthetic launch failure"))
        with self.assertRaises(OSError):
            self.prepare(execve=execute)
        self.assertTrue((self.attempt / "selected-launch-request.json").exists())
        self.assertFalse((self.attempt / "selected-launch-observation.json").exists())

    def test_ambient_environment_cannot_be_forwarded(self):
        self.env["UNEXPECTED_PRIVATE_VALUE"] = "do-not-forward"
        execute = mock.Mock()
        with self.assertRaisesRegex(ValueError, "Private launch environment differs") as caught:
            self.prepare(execve=execute)
        execute.assert_not_called()
        self.assertEqual(caught.exception.summary["extra_key_count"], 1)
        self.assertNotIn("UNEXPECTED_PRIVATE_VALUE", json.dumps(caught.exception.summary))
        self.assertFalse((self.attempt / "selected-launch-request.json").exists())
        self.assertFalse((self.attempt / "selected-launch-observation.json").exists())

    def test_retargeted_selected_alias_is_not_same_physical_installation(self):
        copied = self.root / "copied-selected"
        copied.write_bytes(Path(sys.executable).read_bytes())
        self.selected.unlink()
        self.selected.symlink_to(copied)
        with self.assertRaisesRegex(ValueError, "Prospective interpreter identity"):
            self.prepare()
        self.assertFalse((self.attempt / "selected-launch-request.json").exists())

    def test_changed_prospective_metadata_refuses_before_request_or_exec(self):
        row = self.fixture.results["install_interpreter"]
        row["before"]["file_identity"][1] += 1
        self.fixture.results["install_interpreter"] = row
        (self.fixture.output / "setup/install-interpreter.json").write_text(json.dumps(row))
        self.fixture.write()
        with self.assertRaisesRegex(ValueError, "Prospective interpreter identity"):
            self.prepare()
        self.assertFalse((self.attempt / "selected-launch-request.json").exists())

    def test_completed_publication_requires_actual_launch_copies_and_runtime_identity(self):
        import publish_correctness as publication

        binding, launch = self.prepare(self.selected)
        raw = self.root / "raw"
        (raw / "setup").mkdir(parents=True)
        for key in ("request", "observation"):
            (raw / ("setup/selected-launch-" + key + ".json")).write_bytes(
                Path(launch[key + "_ref"]["path"]).read_bytes()
            )
        (raw / "setup/installation-binding.json").write_text(json.dumps(binding))
        summary = publication.selected_launch_summary(self.args, self.attempt, self.sources)
        attempt = dict(selected_launch=summary)
        record = dict(selected_launch={key: launch[key + "_ref"]["sha256"] for key in ("request", "observation")})
        runtime = dict(python=binding["python"], code_files=self.sources)
        good = publication.completed_launch(record, raw, attempt, runtime)
        self.assertEqual(set(good), {"selected_launch_request", "selected_launch_observation", "installation_binding"})
        for field in ("summary", "copy", "runtime", "binding"):
            with self.subTest(field=field):
                bad_attempt, bad_runtime = copy.deepcopy(attempt), copy.deepcopy(runtime)
                path = raw / "setup/installation-binding.json"
                prior_binding = path.read_bytes()
                observation_path = raw / "setup/selected-launch-observation.json"
                prior_observation = observation_path.read_bytes()
                if field == "summary":
                    bad_attempt["selected_launch"] = {"status": "verified"}
                elif field == "copy":
                    observation_path.write_text("{}")
                elif field == "runtime":
                    bad_runtime["python"]["path"] = str(self.current)
                else:
                    changed = copy.deepcopy(binding)
                    changed["python"]["sha256"] = "0" * 64
                    path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    publication.completed_launch(record, raw, bad_attempt, bad_runtime)
                path.write_bytes(prior_binding)
                observation_path.write_bytes(prior_observation)

    def test_launch_receipts_keep_strict_path_and_credential_scanning(self):
        import publish_correctness as publication

        _, launch = self.prepare(self.selected)
        for field, value in [("GITHUB_TOKEN", "synthetic-secret"), ("note", "/private-unmapped-tenant/input")]:
            raw = self.root / ("publication-" + field)
            (raw / "setup").mkdir(parents=True)
            (raw / "results.json").write_text("{}")
            malicious = copy.deepcopy(launch["request"])
            malicious[field] = value
            (raw / "setup/selected-launch-request.json").write_text(json.dumps(malicious))
            with self.subTest(field=field), self.assertRaises(publication.NORMALIZER.PublicationBlocked):
                publication.NORMALIZER.package(
                    argparse.Namespace(
                        input=raw,
                        output=raw.with_name(raw.name + "-output"),
                        prefix=[
                            "FIXTURE=" + str(self.root),
                            "USR=/usr",
                            "OPT=/opt",
                            "CODE=" + str(selected_launch.ROOT),
                        ],
                    )
                )

    def test_publication_verifies_original_request_actual_observation_and_binding(self):
        with self.assertRaises(Replaced):
            self.prepare()
        binding, record = self.replacement()
        result = selected_launch.verify(self.args, self.root, self.sources)
        self.assertEqual(result["observation"], record["observation"])
        path = self.attempt / "selected-launch-observation.json"
        bad = json.loads(path.read_text())
        bad["actual_interpreter"]["selected_path"] = str(self.current)
        path.write_text(json.dumps(bad))
        with self.assertRaises(ValueError):
            selected_launch.verify(self.args, self.root, self.sources)


if __name__ == "__main__":
    unittest.main(verbosity=2)
