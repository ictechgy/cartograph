#!/usr/bin/env python3
"""실제 생산자 구조와 모의 수치로 고정 비교의 거부 경로만 검사한다. 네이티브 증거가 아니다."""

import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest
from unittest import mock


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


P = load("dependency_pilot", "pilot-dependency-admission.py")
V = load("dependency_phase_controls", "verify-query-phases.py")


class PilotContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.helper = V.PhaseContracts()
        self.helper.root = self.root
        self.config, self.graph = self.helper.fixture()
        self.path = self.helper.path
        self.out = self.path.parent / "runs" / "dependency-admission-pilot"
        self.out.mkdir(parents=True)
        self.candidate = self.root / "candidate"
        self.swiftc = self.root / "compiler" / "swiftc"
        self.swiftc.parent.mkdir()
        self.swiftc.write_bytes(b"fixture compiler")
        (self.swiftc.parent / "swift").write_bytes(b"fixture package driver")
        self.populate(self.candidate, "candidate")
        self.args = argparse.Namespace(project_results=self.path, candidate_package=self.candidate,
                                       candidate_revision="a" * 40, workspace=self.root / "baseline-work")
        self.patches = [mock.patch.object(P.BASE, "capture", side_effect=self.tool_capture),
                        mock.patch.object(P.BASE, "run", side_effect=self.tool_run),
                        mock.patch.object(P.PREP, "admit", return_value=(self.config, self.graph)),
                        mock.patch.object(P.PREP, "verify_bytes", side_effect=self.verify_bytes)]
        for patch in self.patches:
            patch.start()
            self.addCleanup(patch.stop)
        # 실제 생산자 함수를 호출하고 git/컴파일러 프로세스만 모의한다.
        candidate = P.BASE.prepare_cartograph(argparse.Namespace(cartograph_package=self.candidate,
                    jobs=3, setup_timeout=1500), self.swiftc, self.root / "candidate-build")
        self.config["cartograph"] = candidate["binary"]
        self.config["hashes"] = {candidate["binary"]: candidate["binary_sha256"]}
        self.setup = {"cartograph": candidate, "toolchain": {"swiftc": str(self.swiftc), "version": "fixture"}}
        self.setup_path = self.root / "candidate-setup.json"
        P.BASE.save(self.setup_path, self.setup)
        P.BASE.save(self.path, {"reused_tools": {"setup_results": str(self.setup_path),
                    "swiftc": str(self.swiftc), "swiftc_sha256": P.BASE.sha256(self.swiftc)}})
        self.state = {}
        self.report = {"status": "running", "runs": [], "byte_checks": []}

    def tearDown(self):
        self.temporary.cleanup()

    def populate(self, package, arm):
        (package / Path(P.CHANGED).parent).mkdir(parents=True, exist_ok=True)
        (package / "Package.swift").write_text("// fixture manifest\n")
        (package / "Package.resolved").write_text("{}\n")
        (package / P.CHANGED).write_text(f"// {arm} fixture\n")
        (package / "Sources" / "Other.swift").write_text("// unchanged\n")

    def tool_run(self, command, cwd, stem, timeout=300):
        stem.parent.mkdir(parents=True, exist_ok=True)
        Path(str(stem) + ".stdout").write_bytes(b"")
        Path(str(stem) + ".stderr").write_bytes(b"")
        if "fetch" in command:
            self.populate(cwd, "baseline")
        if "--product" in command:
            scratch = Path(command[command.index("--scratch-path") + 1])
            binary = scratch / "release" / "cartograph"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"candidate binary" if cwd == self.candidate else b"baseline binary")
        result = {"command": command, "cwd": str(cwd), "returncode": 0, "timed_out": False,
                  "wall_seconds": 1.0, "user_seconds": 0.5, "system_seconds": 0.1,
                  "wait4_maxrss_bytes": 1000, "stdout": str(stem) + ".stdout", "stderr": str(stem) + ".stderr"}
        P.BASE.save(Path(str(stem) + ".json"), result)
        return result

    def tool_capture(self, command, cwd, stem, timeout=300):
        measurement = self.tool_run(command, cwd, stem, timeout)
        if command[:2] == ["git", "rev-parse"]:
            output = ("a" * 40 if cwd == self.candidate else P.REVISION) + "\n"
        elif "--show-bin-path" in command:
            output = str(Path(command[command.index("--scratch-path") + 1]) / "release") + "\n"
        elif "--version" in command:
            output = "fixture version\n"
        else:
            output = ""
        Path(measurement["stdout"]).write_text(output)
        return output, measurement

    def verify_bytes(self, config):
        for path, digest in config["hashes"].items():
            P.require(P.BASE.sha256(Path(path)) == digest, "Admitted file changed")
        return {"seconds": 0, "source_index_and_config_bytes_unchanged": True}

    def query_capture(self, command, project, stem, enabled):
        measured, raw = self.helper.fake_capture(command, project, stem, enabled)
        measured["measurement"].update(cwd=str(project), user_seconds=0.5, system_seconds=0.1,
                                       wait4_maxrss_bytes=1000)
        P.BASE.save(Path(str(stem) + ".json"), measured["measurement"])
        return measured, raw

    def prepare(self):
        P.prepare(self.args, self.out, self.report, self.state)

    def capture(self, function=None, deadline=None):
        with mock.patch.object(P.D, "capture", side_effect=function or self.query_capture):
            P.capture(self.args, self.out, self.report, self.state, deadline or time.monotonic() + 300)

    def test_producer_receipts_and_fixed_twenty_two_sample_schedule(self):
        self.prepare()
        self.capture()
        self.assertEqual(self.report["status"], "passed")
        self.assertEqual(len(self.report["runs"]), 22)
        self.assertEqual([(row["arm"], row["enabled"]) for row in self.report["runs"][:6]],
                         [("baseline", True), ("candidate", True)] * 3)
        for enabled in (True, False):
            self.assertEqual([row["arm"] for row in self.report["runs"]
                              if row["case"] == "found" and row["enabled"] == enabled], P.ARMS)
        self.assertEqual(set(self.report["arms"]["baseline"]), set(self.setup["cartograph"]))
        self.assertEqual(self.report["arms"]["baseline"]["setup"]["source"]["revision"], P.REVISION)
        self.assertEqual(len(self.report["byte_checks"]), 24)

    def test_exact_revision_build_binary_and_source_receipts(self):
        mutations = [lambda receipt: receipt["setup"]["source"].update(revision="b" * 40),
                     lambda receipt: receipt["setup"].update(mode="supplied-binary"),
                     lambda receipt: receipt["setup"]["source"]["input_sha256"].update({P.CHANGED: "0" * 64}),
                     lambda receipt: receipt["setup"]["build"]["command"].append("-Xswiftc"),
                     lambda receipt: receipt.update(binary=str(self.root / "wrong-binary")),
                     lambda receipt: receipt.update(binary_sha256="0" * 64),
                     lambda receipt: receipt["setup"]["build"].update(returncode=1)]
        for mutate in mutations:
            receipt = json.loads(json.dumps(self.setup["cartograph"]))
            mutate(receipt)
            with self.subTest(mutate=mutate), self.assertRaises((ValueError, FileNotFoundError)):
                P.verify_build(receipt, self.candidate, "a" * 40, self.swiftc, 3, P.source_hashes(self.candidate))
        with self.assertRaisesRegex(ValueError, "revision"):
            P.verify_source(self.candidate, "b" * 40, self.out / "wrong-revision")

    def test_extra_product_change_fails_before_baseline_build(self):
        (self.candidate / "Sources" / "Other.swift").write_text("// unexpected product change\n")
        self.setup["cartograph"]["setup"]["source"]["input_sha256"]["Sources/Other.swift"] = \
            P.BASE.sha256(self.candidate / "Sources" / "Other.swift")
        P.BASE.save(self.setup_path, self.setup)
        with self.assertRaisesRegex(ValueError, "exactly RawIndexStoreReader"):
            self.prepare()
        self.assertFalse((self.args.workspace / "cartograph-release-build").exists())

    def test_final_bytes_additions_and_receipt_link_are_checked(self):
        self.prepare()
        path = self.args.workspace / "source" / "Sources" / "Added.swift"
        path.write_text("// extra\n")
        with self.assertRaisesRegex(ValueError, "source bytes"):
            P.unchanged(self.state)
        path.unlink()
        binary = Path(self.report["arms"]["baseline"]["binary"])
        original = binary.read_bytes()
        binary.write_bytes(b"wrong")
        with self.assertRaisesRegex(ValueError, "Admitted file"):
            P.unchanged(self.state)
        binary.write_bytes(original)
        (self.args.workspace / "setup").unlink()
        (self.args.workspace / "setup").symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, "receipt link"):
            P.unchanged(self.state)

    def test_parity_unknown_phase_invalid_wall_and_exit_refuse(self):
        self.prepare()
        mutations = [("stdout", lambda measured, raw: (measured, (raw[0], raw[1] + b" ", raw[2]))),
                     ("stderr", lambda measured, raw: (measured, (raw[0], raw[1], b"changed"))),
                     ("exit", lambda measured, raw: (measured, (2, raw[1], raw[2]))),
                     ("unknown", lambda measured, raw: ({**measured, "phases": {**measured["phases"],
                                                                             "unknown": 0.0}}, raw))]
        for label, mutation in mutations:
            self.report.update(runs=[], byte_checks=[], status="running")
            def changed(*args):
                measured, raw = self.query_capture(*args)
                return mutation(measured, raw) if "candidate" in args[0][0] else (measured, raw)
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.capture(changed)
            self.assertNotIn("found_medians", self.report)
        for wall in (float("nan"), float("inf"), -1, True, 0.001):
            self.report.update(runs=[], byte_checks=[], status="running")
            def changed_wall(*args):
                measured, raw = self.query_capture(*args)
                measured["measurement"]["wall_seconds"] = wall
                return measured, raw
            with self.subTest(wall=wall), self.assertRaisesRegex(ValueError, "wall"):
                self.capture(changed_wall)
            self.assertNotIn("found_medians", self.report)

    def test_shared_deadline_prevents_launch_and_refuses_late_capture(self):
        self.prepare()
        with mock.patch.object(P.D, "capture") as capture, self.assertRaisesRegex(ValueError, "deadline"):
            P.capture(self.args, self.out, self.report, self.state, time.monotonic() - 1)
        capture.assert_not_called()
        self.report["runs"] = []
        clock = [10]
        def late(*args):
            value = self.query_capture(*args)
            clock[0] = 400
            return value
        with mock.patch.object(P.time, "monotonic", side_effect=lambda: clock[0]), \
                self.assertRaisesRegex(ValueError, "deadline"):
            self.capture(late, deadline=300)
        self.assertEqual(len(self.report["runs"]), 1)

    def test_main_failure_returns_nonzero_preserves_raw_measurement_and_checks_final_bytes(self):
        shutil.rmtree(self.out)
        argv = ["pilot", "--project-results", str(self.path), "--candidate-package", str(self.candidate),
                "--candidate-revision", "a" * 40, "--workspace", str(self.args.workspace)]
        def refuses(*args):
            self.query_capture(*args)
            raise ValueError("Controlled capture refusal")
        with mock.patch.object(sys, "argv", argv), mock.patch.object(P.D, "capture", side_effect=refuses):
            self.assertEqual(P.main(), 1)
        report = P.PROJECT.read_json(self.out / "results.json")
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["runs"][0]["status"], "failed")
        self.assertIn("measurement", report["runs"][0])
        self.assertTrue(report["final_byte_check"]["source_index_and_config_bytes_unchanged"])
        self.assertGreaterEqual(report["final_check_elapsed_seconds"], 0)
        self.assertGreaterEqual(report["driver_elapsed_seconds"], report["final_check_elapsed_seconds"])

    def test_terminal_final_check_cannot_publish_a_late_capture(self):
        shutil.rmtree(self.out)
        argv = ["pilot", "--project-results", str(self.path), "--candidate-package", str(self.candidate),
                "--candidate-revision", "a" * 40, "--workspace", str(self.args.workspace)]
        original, clock, checks = P.unchanged, [10], [0]
        def late_final(state):
            result = original(state)
            checks[0] += 1
            if checks[0] == 25:
                clock[0] = 400
            return result
        with mock.patch.object(sys, "argv", argv), mock.patch.object(P.D, "capture", side_effect=self.query_capture), \
                mock.patch.object(P, "unchanged", side_effect=late_final), \
                mock.patch.object(P.time, "monotonic", side_effect=lambda: clock[0]):
            self.assertEqual(P.main(), 1)
        report = P.PROJECT.read_json(self.out / "results.json")
        self.assertEqual(report["status"], "failed")
        self.assertIn("deadline", report["final_check_error"])

    def test_setup_endpoint_uses_the_absolute_deadline(self):
        shutil.rmtree(self.out)
        argv = ["pilot", "--project-results", str(self.path), "--candidate-package", str(self.candidate),
                "--candidate-revision", "a" * 40, "--workspace", str(self.args.workspace)]
        original, clock = P.unchanged, [10]
        def late_setup(state):
            result = original(state)
            clock[0] = 1600
            return result
        with mock.patch.object(sys, "argv", argv), mock.patch.object(P, "unchanged", side_effect=late_setup), \
                mock.patch.object(P.D, "capture") as capture, \
                mock.patch.object(P.time, "monotonic", side_effect=lambda: clock[0]):
            self.assertEqual(P.main(), 1)
        capture.assert_not_called()
        report = P.PROJECT.read_json(self.out / "results.json")
        self.assertEqual(report["failed_stage"], "setup")
        self.assertIn("deadline", report["error"])

    def test_existing_normalizer_resolves_producer_receipts_without_scanner_changes(self):
        self.prepare()
        self.capture()
        P.BASE.save(self.out / "results.json", self.report)
        destination = self.root / "public"
        V.NORMALIZE.package(argparse.Namespace(input=self.path.parent, output=destination,
                                               prefix=[f"TEMP={self.root}",
                                                       f"REPO={Path(__file__).resolve().parent.parent}"]))
        report = P.PROJECT.read_json(destination / "runs" / "dependency-admission-pilot" / "results.json")
        for key in ("build", "binary_discovery"):
            for stream in ("stdout", "stderr"):
                reference = report["arms"]["baseline"]["setup"][key][stream]
                self.assertTrue((destination / reference).is_file(), reference)
        self.assertFalse(any(path.is_symlink() for path in destination.rglob("*")))


if __name__ == "__main__":
    unittest.main()
