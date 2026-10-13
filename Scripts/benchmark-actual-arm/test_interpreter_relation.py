"""합성 원래 프로브로 정확한 요청·보고 관계만 허용하고 네이티브 증거로 오인하지 않는다."""

import copy
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

import interpreter_relation as relation
import installation_binding
import profile_collection as collection
import selected_launch
import startup_profile as profile
import test_selected_launch as launch_fixtures


class InterpreterRelationTests(unittest.TestCase):
    def setUp(self):
        self.launch = launch_fixtures.SelectedLaunchTests()
        self.launch.setUp()
        self.addCleanup(self.launch.doCleanups)
        self.root, self.args, self.env = self.launch.root, self.launch.args, self.launch.env
        self.selected, self.current = self.launch.selected, self.launch.current
        self.reported = self.root / "probe-reported-python"
        self.reported.symlink_to(Path(sys.executable).resolve())
        self.target = selected_launch.ROOT / "correctness_controller.py"
        self.extra_source = self.root / "fixture.py"
        self.extra_source.write_text("value = 1\n")
        self.launch.sources = {
            str(path): profile.file_identity(path)["sha256"]
            for path in [Path(profile.__file__), Path(collection.__file__), Path(relation.__file__),
                         self.target, self.extra_source]
        }
        self.path = self.launch.attempt / "startup-profile/results.json"
        self.probe_reports = {}

    def synthetic_runner(self, argv, cwd, stem, environment, timeout):
        request_path, report_path = Path(argv[-5]), Path(argv[-1])
        request_data = request_path.read_bytes()
        request = profile.strict(request_data)
        early = profile.observe_request(request["environment"], environment)
        actual = self.probe_reports.get(argv[0], self.reported if argv[0] == str(self.selected) else self.current)
        observed = dict(
            schema_version=1, role="prospective-python-startup-observation", status="passed", exit_code=0,
            request_sha256=profile.sha(request_data), early=early, after_import=copy.deepcopy(early),
            terminal_guard=dict(status="passed"), actual_interpreter=profile.interpreter(actual),
            wall_seconds_before_receipt=0.0,
        )
        profile.save(report_path, observed)
        stdout, stderr = Path(str(stem) + ".stdout"), Path(str(stem) + ".stderr")
        stdout.write_bytes(b"")
        stderr.write_bytes(b"")
        phase = dict(
            command=argv, cwd=str(cwd), completed=True, passed=True, returncode=0, observed_returncode=0,
            stdout=str(stdout), stderr=str(stderr), wall_seconds=0.0,
        )
        profile.save(Path(str(stem) + ".json"), phase)
        return phase

    def collect(self, initial=None):
        record = collection.collect(
            self.env, initial or self.current, self.selected, self.target,
            [Path(path) for path in self.launch.sources], self.path.parent, self.synthetic_runner,
        )
        self.assertEqual(record["status"], "passed", record)
        self.args.startup_profile_sha256 = profile.sha(self.path.read_bytes())
        return record

    def create(self):
        return relation.from_collection(
            self.path, self.args.startup_profile_sha256, self.env, self.selected, self.target, self.launch.sources
        )

    def validate(self, value, *, python=None, sources=None, accepted=None, current=None):
        requested = value["requested_interpreter"]
        python = python or dict(path=str(self.selected), sha256=requested["sha256"], bytes=requested["bytes"])
        accepted = accepted or profile.strict(self.path.read_bytes())["accepted_profile"]
        return relation.verify_current(
            value, python, sources or self.launch.sources, accepted, current or self.reported
        )

    def rehash_collection(self, value):
        self.path.write_text(json.dumps(value))
        self.args.startup_profile_sha256 = profile.sha(self.path.read_bytes())

    def replacement(self, current=None, execute=None):
        request = self.launch.attempt / "selected-launch-request.json"
        self.args.selected_launch_sha256 = profile.sha(request.read_bytes())
        return self.launch.prepare(current or self.reported, execute)

    def test_relation_uses_selected_original_probe_not_initial_probe(self):
        record = self.collect()
        value = self.create()
        self.assertEqual(value["probe"], 2)
        self.assertEqual(value["requested_interpreter"]["selected_path"], str(self.selected))
        self.assertEqual(value["reported_interpreter"]["selected_path"], str(self.reported))
        self.assertEqual(value["observation_sha256"], record["probes"][-1]["observation_identity"]["sha256"])
        self.assertNotEqual(value["reported_interpreter"]["selected_path"],
                            record["probes"][0]["observation"]["actual_interpreter"]["selected_path"])
        self.validate(value)

    def test_direct_initial_selected_spelling_with_exact_probe_needs_no_exec(self):
        self.probe_reports[str(self.selected)] = self.selected
        self.collect(initial=self.selected)
        execute = mock.Mock(side_effect=AssertionError("unexpected exec"))
        binding, record = self.launch.prepare(self.selected, execute)
        execute.assert_not_called()
        self.assertEqual(record["request"]["mode"], "direct")
        self.assertEqual(record["observation"]["actual_interpreter"]["selected_path"], str(self.selected))
        self.assertEqual(binding["python"]["path"], str(self.selected))

    def test_initial_report_matching_probe_still_gets_exactly_one_selected_exec(self):
        self.probe_reports[str(self.current)] = self.reported
        self.collect()
        execute = mock.Mock(side_effect=launch_fixtures.Replaced)
        with self.assertRaises(launch_fixtures.Replaced):
            self.launch.prepare(self.reported, execute)
        execute.assert_called_once()
        self.assertEqual(execute.call_args.args[0], str(self.selected))
        self.assertEqual(self.launch.request()["mode"], "one-exec")
        replacement_exec = mock.Mock(side_effect=AssertionError("second exec"))
        binding, result = self.replacement(execute=replacement_exec)
        replacement_exec.assert_not_called()
        self.assertEqual(binding["python"]["path"], str(self.selected))
        self.assertEqual(result["observation"]["actual_interpreter"]["selected_path"], str(self.reported))
        self.assertEqual(result["observation"]["startup_profile"]["interpreter_relation"], self.create())
        with self.assertRaisesRegex(ValueError, "Prior interpreter spellings differ"):
            installation_binding.bind(self.args.measurement, self.args.repository, self.reported)

    def test_unobserved_same_physical_alias_is_not_admitted_or_reexecuted(self):
        self.collect()
        with self.assertRaises(launch_fixtures.Replaced):
            self.launch.prepare()
        execute = mock.Mock()
        with self.assertRaisesRegex(ValueError, "Prior interpreter spellings differ") as caught:
            self.replacement(self.current, execute)
        execute.assert_not_called()
        self.assertEqual(caught.exception.summary["selected_request"]["mode"], "one-exec")
        self.assertFalse((self.launch.attempt / "selected-launch-observation.json").exists())

    def test_missing_original_observation_cannot_be_inferred_from_request(self):
        record = self.collect()
        entry = record["probes"][-1]
        entry.pop("observation")
        entry.pop("observation_identity")
        (self.path.parent / "spelling-0002/observation.json").unlink()
        self.rehash_collection(record)
        with self.assertRaisesRegex(ValueError, "startup-probe-evidence-shape"):
            self.create()
        execute = mock.Mock()
        with self.assertRaises(ValueError):
            self.launch.prepare(execve=execute)
        execute.assert_not_called()
        self.assertFalse((self.launch.attempt / "selected-launch-request.json").exists())

    def test_wrong_current_source_profile_requested_or_reported_spelling_refuses(self):
        self.collect()
        value = self.create()
        requested = value["requested_interpreter"]
        cases = {
            "source": dict(sources={**self.launch.sources, str(self.extra_source): "0" * 64}),
            "profile": dict(accepted={"unexpected": True}),
            "request": dict(python={"path": str(self.current), "sha256": requested["sha256"],
                                    "bytes": requested["bytes"]}),
            "report": dict(current=self.current),
        }
        for label, kwargs in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.validate(value, **kwargs)

    def test_changed_source_after_collection_is_rejected(self):
        self.collect()
        value = self.create()
        self.extra_source.write_text("value = 2\n")
        with self.assertRaisesRegex(ValueError, "interpreter-relation-source-changed"):
            self.validate(value)
        with self.assertRaises(ValueError):
            self.create()

    def test_different_physical_executable_with_identical_bytes_is_rejected(self):
        self.collect()
        value = self.create()
        copied = self.root / "copied-python"
        copied.write_bytes(Path(sys.executable).read_bytes())
        with self.assertRaisesRegex(ValueError, "interpreter-relation-reported-differs"):
            self.validate(value, current=copied)
        forged = copy.deepcopy(value)
        forged["reported_interpreter"] = profile.interpreter(copied)
        with self.assertRaisesRegex(ValueError, "interpreter-relation-physical-differs"):
            self.validate(forged, current=copied)

    def test_retargeted_reported_alias_is_rejected(self):
        self.collect()
        value = self.create()
        copied = self.root / "copied-python"
        copied.write_bytes(Path(sys.executable).read_bytes())
        self.reported.unlink()
        self.reported.symlink_to(copied)
        with self.assertRaisesRegex(ValueError, "interpreter-relation-identity-changed"):
            self.validate(value)

    def test_last_collection_reread_still_guards_reported_alias(self):
        self.collect()
        copied = self.root / "copied-python"
        copied.write_bytes(Path(sys.executable).read_bytes())
        original = profile.read_file
        reads = 0

        def changed(path, *args, **kwargs):
            nonlocal reads
            result = original(path, *args, **kwargs)
            if Path(path) == self.path:
                reads += 1
                if reads == 3:
                    self.reported.unlink()
                    self.reported.symlink_to(copied)
            return result

        with mock.patch.object(profile, "read_file", side_effect=changed), self.assertRaisesRegex(
            ValueError, "interpreter-relation-identity-changed"
        ):
            self.create()
        self.assertEqual(reads, 3)

    def test_wrong_selected_probe_request_or_observation_refuses_after_rehash(self):
        record = self.collect()
        original = copy.deepcopy(record)
        for kind in ["request", "report", "profile"]:
            with self.subTest(kind=kind):
                changed = copy.deepcopy(original)
                entry = changed["probes"][-1]
                if kind == "request":
                    entry["request_sha256"] = "0" * 64
                elif kind == "report":
                    entry["observation"]["actual_interpreter"] = profile.interpreter(self.current)
                else:
                    admitted = original["accepted_profile"]["platform"]
                    changed["accepted_profile"]["platform"] = "linux" if admitted == "darwin" else "darwin"
                    self.assertNotEqual(changed["accepted_profile"]["platform"], admitted)
                self.rehash_collection(changed)
                with self.assertRaises(ValueError):
                    self.create()
        self.rehash_collection(original)
        self.create()

    def test_wrong_collection_hash_or_source_hash_cannot_mint_relation(self):
        self.collect()
        original = self.args.startup_profile_sha256
        self.args.startup_profile_sha256 = "0" * 64
        with self.assertRaisesRegex(ValueError, "startup-collection-changed"):
            self.create()
        self.args.startup_profile_sha256 = original
        self.launch.sources[str(self.extra_source)] = "0" * 64
        with self.assertRaisesRegex(ValueError, "probe-projection-source-differs"):
            self.create()

    def test_launch_observation_cannot_substitute_other_same_physical_report(self):
        self.collect()
        with self.assertRaises(launch_fixtures.Replaced):
            self.launch.prepare()
        self.replacement()
        path = self.launch.attempt / "selected-launch-observation.json"
        row = profile.strict(path.read_bytes())
        row["actual_interpreter"] = selected_launch.observation(self.current)
        path.write_text(json.dumps(row))
        with self.assertRaisesRegex(ValueError, "Selected launch actual interpreter differs"):
            selected_launch.verify(self.args, self.root, self.launch.sources)


if __name__ == "__main__":
    unittest.main(verbosity=2)
