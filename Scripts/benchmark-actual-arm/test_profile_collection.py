"""수집기의 실제 명령·로그·관측 영수증과 두 경로의 중단 계약을 확인한다."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import startup_profile as probe
import profile_collection as collection


class CollectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.env = dict(probe.FIXED)
        for key, name in [("HOME", "home"), ("TMPDIR", "tmp"), ("XDG_CACHE_HOME", "cache")]:
            path = self.root / name
            path.mkdir()
            self.env[key] = str(path)
        self.target = self.root / "correctness_controller.py"
        self.target.write_text("value = 1\n")
        self.sources = [Path(probe.__file__).resolve(), Path(collection.__file__).resolve(), self.target]
        self.alias = self.root / "python-alias"
        self.alias.symlink_to(sys.executable)
        self.calls = []

    def runner(self, argv, cwd, stem, env, timeout):
        self.calls.append(argv)
        result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=timeout)
        out, err = Path(str(stem) + ".stdout"), Path(str(stem) + ".stderr")
        out.write_bytes(result.stdout)
        err.write_bytes(result.stderr)
        phase = dict(
            command=argv,
            cwd=str(cwd),
            completed=True,
            passed=result.returncode == 0,
            returncode=result.returncode,
            observed_returncode=result.returncode,
            stdout=str(out),
            stderr=str(err),
            wall_seconds=0.0,
        )
        Path(str(stem) + ".json").write_text(json.dumps(phase))
        return phase

    def collect(self, runner=None, initial=None, selected=None):
        return collection.collect(
            self.env,
            initial or Path(sys.executable),
            selected or self.alias,
            self.target,
            self.sources,
            self.root / "profile",
            runner or self.runner,
        )

    def test_two_actual_alias_launches_agree(self):
        row = self.collect()
        self.assertEqual(row["status"], "passed")
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(row["requested_environment"], probe.environment_request(self.env))
        self.assertEqual([x["process"]["returncode"] for x in row["probes"]], [0, 0])
        self.assertFalse(row["final_evidence"])

    def test_identical_spelling_runs_once(self):
        row = self.collect(selected=Path(sys.executable))
        self.assertEqual(row["status"], "passed")
        self.assertEqual(len(self.calls), 1)

    def test_different_binary_refuses_before_mkdir(self):
        with self.assertRaisesRegex(ValueError, "different-profile-interpreters"):
            self.collect(selected=Path("/bin/true"))
        self.assertFalse((self.root / "profile").exists())
        self.assertEqual(self.calls, [])

    def test_reserved_125_stops_before_second_probe(self):
        def failed(*args):
            row = self.runner(*args)
            row.update(completed=False, passed=False, returncode=125, observed_returncode=125)
            return row

        row = self.collect(failed)
        self.assertEqual(row["exit_code"], 125)
        self.assertEqual(len(self.calls), 1)
        self.assertIsNone(row["accepted_profile"])

    def test_signal_and_timeout_and_boolean_exit_are_incomplete(self):
        for observed in [-15, None, True]:
            with self.subTest(observed=observed), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary).resolve() / "out"

                def failed(argv, cwd, stem, env, timeout):
                    return dict(completed=False, passed=False, returncode=125, observed_returncode=observed)

                row = collection.collect(
                    self.env, Path(sys.executable), self.alias, self.target, self.sources, output, failed
                )
                self.assertEqual(row["exit_code"], 125)
                self.assertEqual(len(row["probes"]), 1)

    def test_completed_failure_keeps_guard_and_stops(self):
        self.target.write_text('raise ValueError("synthetic-private")\n')
        row = self.collect()
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(row["probes"][0]["terminal_guard"]["status"], "passed")
        self.assertIsNone(row["accepted_profile"])

    def test_missing_actual_observation_cannot_pass(self):
        def missing(*args):
            row = self.runner(*args)
            Path(args[0][-1]).unlink()
            return row

        row = self.collect(missing)
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(len(self.calls), 1)

    def test_actual_process_receipt_must_agree(self):
        def changed(*args):
            row = self.runner(*args)
            row["command"] = ["unbound"]
            return row

        row = self.collect(changed)
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(len(self.calls), 1)

    def test_post_capture_log_change_refuses_final_profile(self):
        def changed(*args):
            row = self.runner(*args)
            if len(self.calls) == 2:
                path = self.root / "profile/spelling-0001/process.stdout"
                path.write_text("changed")
            return row

        row = self.collect(changed)
        self.assertEqual(row["exit_code"], 1)
        self.assertIsNone(row["accepted_profile"])

    def test_earlier_request_change_during_second_probe_refuses(self):
        def changed(*args):
            row = self.runner(*args)
            if len(self.calls) == 2:
                path = self.root / "profile/spelling-0001/request.json"
                value = json.loads(path.read_text())
                value["role"] = "replaced"
                path.write_text(json.dumps(value))
            return row

        row = self.collect(changed)
        self.assertEqual(row["exit_code"], 1)
        self.assertIsNone(row["accepted_profile"])

    def test_actual_process_boolean_and_float_zero_cannot_equal_integer_exit(self):
        for bad in [False, 0.0]:
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary).resolve() / "out"

                def changed(*args):
                    row = self.runner(*args)
                    path = Path(str(args[2]) + ".json")
                    actual = json.loads(path.read_text())
                    actual["returncode"] = bad
                    path.write_text(json.dumps(actual))
                    return row

                row = collection.collect(
                    self.env, Path(sys.executable), self.alias, self.target, self.sources, output, changed
                )
                self.assertEqual(row["exit_code"], 1)

    def test_rehashed_observation_with_boolean_exit_refuses(self):
        def changed(*args):
            row = self.runner(*args)
            path = Path(args[0][-1])
            value = json.loads(path.read_text())
            value["exit_code"] = False
            path.write_text(json.dumps(value))
            return row

        row = self.collect(changed)
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(len(self.calls), 1)

    def test_runtime_directory_change_during_second_probe_refuses(self):
        def changed(*args):
            row = self.runner(*args)
            if len(self.calls) == 2:
                home = Path(self.env["HOME"])
                home.rename(self.root / "old-home")
                home.mkdir()
            return row

        row = self.collect(changed)
        self.assertEqual(row["exit_code"], 1)
        self.assertIsNone(row["accepted_profile"])

    def test_runner_cannot_mutate_original_launch_values(self):
        def changed(argv, cwd, stem, env, timeout):
            row = self.runner(argv, cwd, stem, env, timeout)
            env["LANG"] = "changed"
            return row

        row = self.collect(changed)
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(self.env["LANG"], "C")

    def test_last_observation_reread_cannot_hide_source_mutation(self):
        original = probe.read_file
        reads = 0

        def changed(path, *args, **kwargs):
            nonlocal reads
            result = original(path, *args, **kwargs)
            if str(path).endswith("spelling-0002/observation.json"):
                reads += 1
                if reads == 2:
                    self.target.write_text("value = 2\n")
            return result

        with mock.patch.object(probe, "read_file", side_effect=changed):
            row = self.collect()
        self.assertEqual(reads, 2)
        self.assertEqual(row["exit_code"], 1)

    def test_last_observation_reread_cannot_hide_directory_replacement(self):
        original = probe.read_file
        reads = 0

        def changed(path, *args, **kwargs):
            nonlocal reads
            result = original(path, *args, **kwargs)
            if str(path).endswith("spelling-0002/observation.json"):
                reads += 1
                if reads == 2:
                    home = Path(self.env["HOME"])
                    home.rename(self.root / "old-home")
                    home.mkdir()
            return result

        with mock.patch.object(probe, "read_file", side_effect=changed):
            row = self.collect()
        self.assertEqual(reads, 2)
        self.assertEqual(row["exit_code"], 1)

    def verify_current(self):
        path = self.root / "profile/results.json"
        return collection.verify_collection(
            path, probe.sha(path.read_bytes()), self.env, self.alias, self.target, self.sources
        )

    def test_completion_reconstructs_both_actual_probe_requests(self):
        value = self.collect()
        self.assertEqual(self.verify_current(), value)

    def test_completion_rejects_changed_actual_probe_log(self):
        self.collect()
        (self.root / "profile/spelling-0001/process.stdout").write_text("forged-after-capture")
        with self.assertRaises(ValueError):
            self.verify_current()

    def test_completion_rejects_rehashed_untyped_collection(self):
        self.collect()
        path = self.root / "profile/results.json"
        value = json.loads(path.read_text())
        value["exit_code"] = False
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError):
            self.verify_current()

    def test_completion_rejects_different_original_environment(self):
        self.collect()
        self.env["TZ"] = "different"
        with self.assertRaises(ValueError):
            self.verify_current()

    def test_completion_final_reread_still_guards_source(self):
        self.collect()
        original = probe.read_file
        count = 0

        def changed(path, *args, **kwargs):
            nonlocal count
            result = original(path, *args, **kwargs)
            if Path(path) == self.root / "profile/results.json":
                count += 1
                if count == 2:
                    self.target.write_text("value = 2\n")
            return result

        with mock.patch.object(probe, "read_file", side_effect=changed), self.assertRaises(ValueError):
            self.verify_current()

    def test_completion_final_reread_still_guards_private_directory(self):
        self.collect()
        original = probe.read_file
        count = 0

        def changed(path, *args, **kwargs):
            nonlocal count
            result = original(path, *args, **kwargs)
            if Path(path) == self.root / "profile/results.json":
                count += 1
                if count == 2:
                    home = Path(self.env["HOME"])
                    home.rename(self.root / "old-home")
                    home.mkdir()
            return result

        with mock.patch.object(probe, "read_file", side_effect=changed), self.assertRaises(ValueError):
            self.verify_current()

    def test_outgoing_values_are_not_serialized(self):
        row = self.collect()
        self.assertNotIn(probe.KEY, self.env)
        for path in (self.root / "profile").rglob("*.json"):
            value = json.loads(path.read_text())
            self.assertNotIn("environment_values", value)
        self.assertIsNone(row["accepted_profile"]["addition"])


if __name__ == "__main__":
    unittest.main()
