"""새 Python 프로세스가 주위 설치 대신 봉인된 --target만 가져오는지 확인한다."""

import hashlib
import copy
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import psutil
import runtime_identity as runtime
import startup_profile

ROOT = Path(__file__).resolve().parent


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.target = self.root / "packages"
        self.target.mkdir()
        shutil.copytree(Path(psutil.__file__).parent, self.target / "psutil")
        distribution = importlib.metadata.distribution("psutil")
        self.assertEqual(distribution.version, "7.2.2")
        metadata = next(
            Path(distribution.locate_file(f)).parent
            for f in distribution.files
            if str(f).endswith(".dist-info/METADATA")
        )
        shutil.copytree(metadata, self.target / "psutil-7.2.2.dist-info")
        self.script = self.root / "workload.py"
        self.script.write_text(
            'import psutil,json,sys;print(json.dumps({"version":psutil.__version__,"origin":psutil.__file__,"isolated":sys.flags.isolated,"no_site":sys.flags.no_site}))\n'
        )
        self.projection = {
            "schema_version": 1,
            "source_format": "pip-install-report-v1",
            "distributions": [
                {
                    "name": "psutil",
                    "version": "7.2.2",
                    "url": "https://files.pythonhosted.org/packages/aa/bb/"
                    + "c" * 60
                    + "/psutil-7.2.2-cp36-abi3-macosx_11_0_arm64.whl",
                    "sha256": "a" * 64,
                    "is_direct": False,
                    "is_yanked": False,
                    "requested": True,
                }
            ],
        }
        self.seal = runtime.package_snapshot(self.target, self.projection)
        self.config = dict(
            schema_version=1,
            package=self.seal,
            python=dict(path=sys.executable, **runtime.file_identity(Path(sys.executable))),
            code_files={
                str(p): runtime.file_identity(p)["sha256"]
                for p in [
                    ROOT / "runtime_bootstrap.py",
                    ROOT / "runtime_identity.py",
                    ROOT / "vendor/sdk_content_seal.py",
                    self.script,
                ]
            },
        )
        self.receipt = self.root / "runtime.json"
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        self.report = self.root / "out/runtime-result.json"

    def invoke(self, environment=None):
        command = [
            sys.executable,
            "-I",
            "-S",
            "-B",
            str(ROOT / "runtime_bootstrap.py"),
            "--runtime",
            str(self.receipt),
            "--runtime-sha256",
            hashlib.sha256(self.receipt.read_bytes()).hexdigest(),
            "--script",
            str(self.script),
            "--report",
            str(self.report),
        ]
        return subprocess.run(command, env=environment, capture_output=True, text=True, timeout=15)

    def test_unchanged_helper_and_nested_worker_both_use_verified_bootstrap(self):
        import isolated_measure

        helper = ROOT / "vendor/process_tree_measure.py"
        self.config["code_files"][str(helper)] = runtime.file_identity(helper)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        reference = hashlib.sha256(self.receipt.read_bytes()).hexdigest()
        engine_report = self.root / "engine/runtime-result.json"
        command = isolated_measure.bootstrap_command(self.receipt, reference, self.script, engine_report)
        environment = runtime.private_environment(self.root / "engine-private")
        observer_environment = runtime.private_environment(self.root / "observer-private")
        result = isolated_measure.run(
            command,
            self.root,
            self.root / "measurement/whole",
            self.receipt,
            reference,
            environment,
            observer_environment,
            timeout=5,
        )
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["measurement"]["helper_sha256"], isolated_measure.HELPER_SHA256)
        self.assertFalse(result["measurement"]["sampling_during_timing"])
        for report in [result["runtime"], json.loads(engine_report.read_text())]:
            self.assertEqual(report["status"], "passed")
            self.assertEqual(report["modules_before"]["modules"]["psutil"]["kind"], "private-package")
            self.assertEqual(
                Path(report["modules_before"]["modules"]["psutil"]["path"]), self.target / "psutil/__init__.py"
            )
        self.assertGreater(result["observer_call_wall_seconds"], result["measurement"]["wall_seconds"])

    def test_interpreter_schema_unknown_fields_refuse_before_import(self):
        self.config["python"]["extra"] = "unaccepted"
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")

    def test_observer_refuses_input_overlap_before_any_write(self):
        import isolated_measure

        stem = self.target / "new-evidence/whole"
        with self.assertRaises(ValueError):
            isolated_measure.run(
                [sys.executable, "-c", "pass"],
                self.root,
                stem,
                self.receipt,
                hashlib.sha256(self.receipt.read_bytes()).hexdigest(),
                runtime.private_environment(self.root / "engine-private"),
                runtime.private_environment(self.root / "observer-private"),
                timeout=1,
            )
        self.assertFalse(stem.parent.exists())

    def test_observer_rejects_ambient_environment_key_before_write(self):
        import isolated_measure

        environment = runtime.private_environment(self.root / "engine-private")
        environment["PYTHONPATH"] = str(self.root / "ambient")
        stem = self.root / "measurement/whole"
        with self.assertRaises(ValueError):
            isolated_measure.run(
                [sys.executable, "-c", "pass"],
                self.root,
                stem,
                self.receipt,
                hashlib.sha256(self.receipt.read_bytes()).hexdigest(),
                environment,
                runtime.private_environment(self.root / "observer-private"),
                timeout=1,
            )
        self.assertFalse(stem.parent.exists())

    def measured_workload(self, source, timeout=5, command_override=None, cwd_override=None, mode=None, direct=False):
        import isolated_measure

        self.script.write_text(source)
        self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
        helper = ROOT / "vendor/process_tree_measure.py"
        self.config["code_files"][str(helper)] = runtime.file_identity(helper)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        digest = hashlib.sha256(self.receipt.read_bytes()).hexdigest()
        command = command_override or isolated_measure.bootstrap_command(
            self.receipt, digest, self.script, self.root / "engine/runtime-result.json"
        )
        arguments = [
            command,
            cwd_override or self.root,
            self.root / "measurement/whole",
            self.receipt,
            digest,
            runtime.private_environment(self.root / "engine-private"),
        ]
        if not direct:
            arguments.append(runtime.private_environment(self.root / "observer-private"))
        runner = isolated_measure.run_direct if direct else isolated_measure.run
        return runner(*arguments, timeout=timeout, **({} if mode is None else {"mode": mode}))

    def test_default_and_explicit_timing_keep_same_contract_and_original_output(self):
        summaries = []
        for mode in [None, "timing"]:
            fixture = BootstrapTests()
            fixture.setUp()
            try:
                result = fixture.measured_workload("print('original output')", mode=mode)
                measured = result["measurement"]
                command = json.loads((fixture.root / "measurement/whole.command.json").read_text())
                summaries.append((result["status"], result["mode"], result["periodic_sampling"],
                                  command["measurement_mode"], measured["measurement_mode"],
                                  measured["sampling_during_timing"], measured["helper_sha256"],
                                  (fixture.root / "measurement/whole.stdout").read_bytes()))
            finally:
                fixture.doCleanups()
        self.assertEqual(summaries[0], summaries[1])
        self.assertEqual(summaries[0][:6], ("passed", "timing", False, "timing", "timing", False))
        self.assertEqual(summaries[0][-1], b"original output\n")

    def test_invalid_mode_refuses_before_launch_or_measurement_write(self):
        import isolated_measure

        for mode in ["MEMORY", "direct", "", None, True, 1, ["memory"]]:
            with self.subTest(mode=mode), mock.patch.object(isolated_measure.subprocess, "Popen") as launch:
                with self.assertRaises(ValueError):
                    isolated_measure.run([], self.root, self.root / "measurement/whole", self.receipt,
                                         "unused", {}, {}, mode=mode)
                launch.assert_not_called()
                self.assertFalse((self.root / "measurement").exists())

    def test_memory_mode_binds_actual_runtime_and_every_sample(self):
        result = self.measured_workload("import time;print('memory original');time.sleep(.05)", mode="memory")
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["mode"], "memory")
        self.assertTrue(result["periodic_sampling"])
        self.assertFalse(result["measurement"]["primary_timing_eligible"])
        self.assertEqual(result["measurement"]["rss"]["read_errors"], [])
        self.assertGreater(result["measurement"]["rss"]["sample_count"], 0)
        self.assertEqual(result["engine_runtime"]["observed_exit_code"], 0)
        self.assertEqual(result["runtime"]["observed_exit_code"], 0)
        self.assertEqual((self.root / "measurement/whole.stdout").read_bytes(), b"memory original\n")

    def test_direct_preserves_original_output_and_runtime_return_link(self):
        result = self.measured_workload("import sys;print('out');print('err',file=sys.stderr)", direct=True)
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]), ("passed", 0, 0))
        self.assertEqual(result["engine_runtime"]["observed_exit_code"], 0)
        self.assertEqual(result["measurement"]["measurement_mode"], "direct")
        self.assertEqual(result["measurement"]["wall_seconds"], result["engine_wall_seconds"])
        self.assertGreater(result["direct_call_wall_seconds"], result["engine_wall_seconds"])
        self.assertGreater(result["admission_wall_seconds"], 0)
        self.assertGreater(result["receipt_verification_wall_seconds"], 0)
        self.assertEqual((self.root / "measurement/whole.stdout").read_bytes(), b"out\n")
        self.assertEqual((self.root / "measurement/whole.stderr").read_bytes(), b"err\n")
        self.assertEqual(json.loads((self.root / "measurement/whole.direct.json").read_text()), result)

    def test_direct_failed_exit_preserves_both_runtime_guards(self):
        result = self.measured_workload("print('before failure');raise SystemExit(9)", direct=True)
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]), ("failed", 9, 9))
        self.assertEqual(result["engine_runtime"]["exit_code"], 9)
        self.assertTrue(result["engine_runtime"]["package_after"]["matches"])
        self.assertEqual(result["measurement"]["failure"], "nonzero_exit")
        self.assertEqual((self.root / "measurement/whole.stdout").read_bytes(), b"before failure\n")

    def test_direct_missing_receipt_cannot_score_success(self):
        result = self.measured_workload("import os;os._exit(0)", direct=True)
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]), ("incomplete", 125, 0))
        self.assertIsNone(result["engine_runtime"])

    def test_direct_reserved125_stays_incomplete(self):
        result = self.measured_workload("raise SystemExit(125)", direct=True)
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]),
                         ("incomplete", 125, 125))
        self.assertEqual(result["engine_runtime"]["status"], "incomplete")

    def test_direct_timeout_preserves_output_and_original_negative_return(self):
        result = self.measured_workload("import time;print('before timeout',flush=True);time.sleep(20)",
                                        timeout=.5, direct=True)
        self.assertEqual((result["status"], result["exit_code"], result["failure"]), ("incomplete", 125, "timeout"))
        self.assertLess(result["workload_returncode"], 0)
        self.assertIsNone(result["engine_wall_seconds"])
        self.assertEqual(result["measurement"]["root_returncode"], result["workload_returncode"])
        self.assertEqual((self.root / "measurement/whole.stdout").read_bytes(), b"before timeout\n")
        self.assertTrue(result["cleanup_signals"])

    def test_direct_launch_failure_is_incomplete_and_preserves_files(self):
        result = self.measured_workload("pass", direct=True, cwd_override=self.root / "missing-directory")
        self.assertEqual((result["status"], result["exit_code"]), ("incomplete", 125))
        self.assertIsNone(result["workload_returncode"])
        self.assertIsNone(result["engine_wall_seconds"])
        self.assertTrue((self.root / "measurement/whole.stdout").is_file())

    def test_direct_rejects_raw_command_and_timeout_before_launch(self):
        import isolated_measure

        with self.assertRaises(ValueError):
            self.measured_workload("pass", command_override=[sys.executable, "-c", "pass"], direct=True)
        self.assertFalse((self.root / "measurement").exists())
        for timeout in [True, 0, 240.1, float("inf")]:
            with self.subTest(timeout=timeout), mock.patch.object(isolated_measure.subprocess, "Popen") as launch:
                with self.assertRaises(ValueError):
                    isolated_measure.run_direct([], self.root, self.root / "measurement/whole",
                                                self.receipt, "unused", {}, timeout=timeout)
                launch.assert_not_called()

    def test_direct_rejects_ambient_environment_before_launch_or_write(self):
        import isolated_measure

        digest = hashlib.sha256(self.receipt.read_bytes()).hexdigest()
        command = isolated_measure.bootstrap_command(self.receipt, digest, self.script, self.report)
        environment = runtime.private_environment(self.root / "direct-private")
        environment["PYTHONPATH"] = str(self.root / "ambient")
        with mock.patch.object(isolated_measure.subprocess, "Popen") as launch:
            with self.assertRaises(ValueError):
                isolated_measure.run_direct(command, self.root, self.root / "measurement/whole",
                                            self.receipt, digest, environment)
            launch.assert_not_called()
        self.assertFalse((self.root / "measurement").exists())

    def test_direct_signal_preserves_observed_negative_exit(self):
        result = self.measured_workload("import os,signal;os.kill(os.getpid(),signal.SIGTERM)", direct=True)
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]),
                         ("incomplete", 125, -15))

    def test_direct_receipt_wrong_observed_return_remains_incomplete(self):
        import isolated_measure

        verify = isolated_measure.verify_runtime_receipt

        def mismatched_return(path, config, digest, script, arguments, code, environment):
            return verify(path, config, digest, script, arguments, code + 1, environment)

        with mock.patch.object(isolated_measure, "verify_runtime_receipt", side_effect=mismatched_return):
            result = self.measured_workload("pass", direct=True)
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]), ("incomplete", 125, 0))
        self.assertIn("contradicts", result["failure_reason"])

    def test_direct_wall_excludes_file_opening_and_receipts_and_uses_blocking_wait(self):
        import isolated_measure

        clock = [0.0]
        original_open = Path.open
        process = mock.Mock(returncode=0)
        process.poll.return_value = 0

        def opening(path, *args, **kwargs):
            if path.suffix in (".stdout", ".stderr"):
                clock[0] += 5
            return original_open(path, *args, **kwargs)

        def launch(*args, **kwargs):
            clock[0] += .125
            return process

        def wait():
            clock[0] += .25
            return 0

        def receipt(*args):
            clock[0] += 7
            return {"observed_exit_code": 0}

        process.wait.side_effect = wait
        with mock.patch.object(Path, "open", opening), \
                mock.patch.object(isolated_measure.time, "perf_counter", side_effect=lambda: clock[0]), \
                mock.patch.object(isolated_measure.subprocess, "Popen", side_effect=launch), \
                mock.patch.object(isolated_measure, "verify_runtime_receipt", side_effect=receipt):
            result = self.measured_workload("pass", direct=True)
        self.assertEqual(result["status"], "passed", result)
        process.wait.assert_called_once_with()
        self.assertEqual(result["engine_wall_seconds"], .375)
        self.assertEqual(result["receipt_verification_wall_seconds"], 7)
        self.assertEqual(result["direct_call_wall_seconds"], 17.375)

    def test_direct_cleanup_errors_preserve_primary_failure_and_terminal_receipt(self):
        import isolated_measure

        for primary in [None, "timeout", "cancelled", "receipt"]:
            with self.subTest(primary=primary):
                fixture = BootstrapTests()
                fixture.setUp()
                try:
                    code = None if primary in ("timeout", "cancelled") else 9 if primary == "receipt" else 0
                    process = mock.Mock(pid=12345, returncode=code)
                    process.poll.side_effect = OSError("private secondary poll detail")

                    def wait(timeout=None):
                        if timeout is not None:
                            raise RuntimeError("private secondary wait detail")
                        if primary in ("timeout", "cancelled"):
                            sig = (isolated_measure.signal.SIGALRM if primary == "timeout"
                                   else isolated_measure.signal.SIGTERM)
                            isolated_measure.signal.getsignal(sig)(sig, None)
                        return process.returncode

                    def launch(*args, **kwargs):
                        kwargs["stdout"].write(b"original output\n")
                        kwargs["stderr"].write(b"original error\n")
                        return process

                    process.wait.side_effect = wait
                    receipt = mock.Mock(return_value={"observed_exit_code": 0})
                    if primary == "receipt":
                        receipt.side_effect = ValueError("primary receipt failed")
                    with mock.patch.object(isolated_measure.subprocess, "Popen", side_effect=launch), \
                            mock.patch.object(isolated_measure.signal, "setitimer"), \
                            mock.patch.object(isolated_measure.os, "killpg"), \
                            mock.patch.object(isolated_measure, "verify_runtime_receipt", receipt):
                        result = fixture.measured_workload("pass", direct=True)
                    expected_failure = {None: "cleanup-incomplete", "receipt": "ValueError"}.get(primary, primary)
                    self.assertEqual((result["status"], result["exit_code"], result["failure"]),
                                     ("incomplete", 125, expected_failure))
                    self.assertEqual(result["workload_returncode"],
                                     None if primary in ("timeout", "cancelled") else process.returncode)
                    if primary == "receipt":
                        self.assertEqual(result["failure_reason"], "primary receipt failed")
                    if primary == "timeout":
                        self.assertEqual(result["failure_reason"], "Direct engine deadline reached")
                    if primary == "cancelled":
                        self.assertEqual(result["failure_reason"], "Direct engine cancelled")
                    self.assertTrue(result["cleanup_root_unfinished"])
                    self.assertEqual(result["cleanup_errors"], [
                        dict(operation="poll-before-cleanup", type="OSError"),
                        dict(operation="term-wait", type="RuntimeError"),
                        dict(operation="kill-wait", type="RuntimeError"),
                        dict(operation="poll-after-cleanup", type="OSError"),
                    ])
                    path = fixture.root / "measurement/whole.direct.json"
                    self.assertEqual(json.loads(path.read_text()), result)
                    self.assertNotIn("private secondary", path.read_text())
                    self.assertEqual((fixture.root / "measurement/whole.stdout").read_bytes(), b"original output\n")
                    self.assertEqual((fixture.root / "measurement/whole.stderr").read_bytes(), b"original error\n")
                finally:
                    fixture.doCleanups()

    def test_direct_cleanup_error_records_are_bounded_and_redacted(self):
        import isolated_measure

        result = {"cleanup_errors": []}
        error = type("X" * 200, (RuntimeError,), {})("private secondary detail")
        for _ in range(20):
            isolated_measure.direct_cleanup_error(result, "poll-after-cleanup", error)
        self.assertEqual(len(result["cleanup_errors"]), 12)
        self.assertTrue(all(row == dict(operation="poll-after-cleanup", type="X" * 80)
                            for row in result["cleanup_errors"]))
        self.assertNotIn("private secondary detail", json.dumps(result))

    def test_direct_cleanup_wait_return_survives_later_poll_failure(self):
        import isolated_measure

        process = mock.Mock(pid=12345, returncode=None)
        process.poll.side_effect = [None, OSError("private secondary poll detail")]

        def wait(timeout=None):
            if timeout is None:
                sig = isolated_measure.signal.SIGALRM
                isolated_measure.signal.getsignal(sig)(sig, None)
            return -15

        process.wait.side_effect = wait
        with mock.patch.object(isolated_measure.subprocess, "Popen", return_value=process), \
                mock.patch.object(isolated_measure.signal, "setitimer"), \
                mock.patch.object(isolated_measure.os, "killpg"), \
                mock.patch.object(isolated_measure, "verify_runtime_receipt") as verify:
            result = self.measured_workload("pass", direct=True)
        verify.assert_not_called()
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]),
                         ("incomplete", 125, -15))
        self.assertEqual(result["failure"], "timeout")
        self.assertEqual(result["failure_reason"], "Direct engine deadline reached")
        self.assertEqual(result["cleanup_errors"], [dict(operation="poll-after-cleanup", type="OSError")])
        self.assertEqual(process.wait.call_args_list, [mock.call(), mock.call(timeout=2)])
        self.assertEqual(json.loads((self.root / "measurement/whole.direct.json").read_text()), result)

    def test_direct_cleanup_wait_rejects_noninteger_or_changed_return(self):
        import isolated_measure

        for code in [True, None, 9]:
            with self.subTest(code=code):
                result = dict(workload_returncode=0, cleanup_errors=[], cleanup_signals=[])
                process = mock.Mock(pid=12345)
                process.wait.return_value = code
                with mock.patch.object(isolated_measure.os, "killpg"):
                    isolated_measure.cleanup_direct(process, result)
                self.assertEqual(result["workload_returncode"], 0)
                self.assertTrue(result["cleanup_root_unfinished"])
                self.assertEqual(result["cleanup_errors"], [
                    dict(operation="term-wait", type="ValueError"), dict(operation="kill-wait", type="ValueError"),
                ])

    def test_direct_unproved_reaping_cannot_leave_success(self):
        import isolated_measure

        process = mock.Mock(pid=12345, returncode=0)
        process.poll.return_value = None
        process.wait.side_effect = [0, subprocess.TimeoutExpired("direct", 2), subprocess.TimeoutExpired("direct", 5)]
        with mock.patch.object(isolated_measure.subprocess, "Popen", return_value=process), \
                mock.patch.object(isolated_measure.signal, "setitimer"), \
                mock.patch.object(isolated_measure.os, "killpg"), \
                mock.patch.object(isolated_measure, "verify_runtime_receipt", return_value={"observed_exit_code": 0}):
            result = self.measured_workload("pass", direct=True)
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]), ("incomplete", 125, 0))
        self.assertEqual(result["failure"], "cleanup-incomplete")
        self.assertTrue(result["cleanup_root_unfinished"])
        self.assertEqual(json.loads((self.root / "measurement/whole.direct.json").read_text()), result)

    def test_direct_invalid_or_late_completed_wall_cannot_score_success(self):
        import isolated_measure

        for elapsed in [0, -1, float("nan"), float("inf"), 2]:
            with self.subTest(elapsed=elapsed):
                fixture = BootstrapTests()
                fixture.setUp()
                try:
                    process = mock.Mock(pid=12345, returncode=0)
                    process.poll.return_value = 0
                    with mock.patch.object(isolated_measure.subprocess, "Popen", return_value=process), \
                            mock.patch.object(isolated_measure.signal, "setitimer"), \
                            mock.patch.object(isolated_measure.os, "killpg"), \
                            mock.patch.object(isolated_measure.time, "perf_counter",
                                              side_effect=[0, .01, 1, 1.01, 1 + elapsed, 10]), \
                            mock.patch.object(isolated_measure, "verify_runtime_receipt") as verify:
                        result = fixture.measured_workload("pass", timeout=1, direct=True)
                    verify.assert_not_called()
                    self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]),
                                     ("incomplete", 125, 0))
                    self.assertIn("bounded deadline", result["failure_reason"])
                    self.assertEqual(json.loads((fixture.root / "measurement/whole.direct.json").read_text()), result)
                finally:
                    fixture.doCleanups()

    def test_direct_true_cannot_bypass_engine_runtime(self):
        with self.assertRaises(ValueError):
            self.measured_workload("pass", command_override=[sys.executable])
        self.assertFalse((self.root / "measurement").exists())

    def test_direct_python_cannot_bypass_engine_runtime(self):
        with self.assertRaises(ValueError):
            self.measured_workload("pass", command_override=[sys.executable, "-c", "pass"])
        self.assertFalse((self.root / "measurement").exists())

    def test_engine_runtime_receipt_rejects_changed_request_return_and_guards(self):
        import isolated_measure

        result = self.measured_workload("pass")
        self.assertEqual(result["status"], "passed", result)
        path = self.root / "engine/runtime-result.json"
        original = json.loads(path.read_text())
        digest = hashlib.sha256(self.receipt.read_bytes()).hexdigest()
        mutations = [
            ("runtime_receipt_sha256", "0" * 64),
            ("entrypoint", {"path": str(self.script), "sha256": "0" * 64}),
            ("arguments_sha256", "0" * 64),
            ("observed_exit_code", 9),
            ("exit_code", 9),
            ("code_after", {"status": "unavailable"}),
            ("package_after", {"matches": False}),
            ("modules_after", {}),
            ("package_before", {"matches": False}),
            ("python", {"sha256": "0" * 64}),
        ]
        for key, value in mutations:
            with self.subTest(key=key):
                changed = {**original, key: value}
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    isolated_measure.verify_runtime_receipt(path, self.config, digest, self.script, [], 0)
        path.write_text(json.dumps(original))

    def test_engine_success_without_runtime_receipt_is_incomplete(self):
        result = self.measured_workload("import os;os._exit(0)")
        self.assertEqual(result["workload_returncode"], 0)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["exit_code"], 125)
        self.assertIsNone(result["engine_runtime"])

    def test_measured_reserved125_remains_incomplete(self):
        result = self.measured_workload("raise SystemExit(125)")
        self.assertEqual(
            (result["status"], result["exit_code"], result["workload_returncode"]), ("incomplete", 125, 125)
        )
        self.assertEqual(result["runtime"]["status"], "passed")

    def test_measured_signal_preserves_observed_negative_exit(self):
        result = self.measured_workload("import os,signal;os.kill(os.getpid(),signal.SIGTERM)")
        self.assertEqual(
            (result["status"], result["exit_code"], result["workload_returncode"]), ("incomplete", 125, -15)
        )

    def test_measured_timeout_keeps_failed_work_and_original_return(self):
        result = self.measured_workload("import time;time.sleep(20)", timeout=0.3)
        self.assertEqual((result["status"], result["exit_code"]), ("incomplete", 125))
        self.assertEqual(result["measurement"]["failure"], "timeout")
        self.assertLess(result["workload_returncode"], 0)
        self.assertGreater(result["observer_call_wall_seconds"], 0)

    def test_measured_launch_failure_is_incomplete(self):
        result = self.measured_workload("pass", cwd_override=self.root / "missing-working-directory")
        self.assertEqual((result["status"], result["exit_code"]), ("incomplete", 125))
        self.assertIsNone(result["workload_returncode"])
        self.assertIsNotNone(result["measurement"]["failure"])

    def test_measured_normal_nonzero_keeps_both_runtime_guards(self):
        result = self.measured_workload("raise SystemExit(9)")
        self.assertEqual((result["status"], result["exit_code"], result["workload_returncode"]), ("failed", 9, 9))
        self.assertTrue(result["runtime"]["package_after"]["matches"])
        engine = json.loads((self.root / "engine/runtime-result.json").read_text())
        self.assertEqual(engine["observed_exit_code"], 9)
        self.assertTrue(engine["package_after"]["matches"])

    def test_missing_runtime_vendor_binding_refuses_before_import(self):
        del self.config["code_files"][str(ROOT / "vendor/sdk_content_seal.py")]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertFalse(json.loads(self.report.read_text())["workload_started"])

    def test_package_schema_bool_and_unknown_fields_refuse(self):
        for changed in ["bool", "extra"]:
            config = json.loads(json.dumps(self.config))
            if changed == "bool":
                config["package"]["schema_version"] = True
            else:
                config["package"]["unexpected"] = "not accepted"
            self.receipt.write_text(json.dumps(config, sort_keys=True))
            result = self.invoke()
            self.assertEqual(result.returncode, 1, changed)
            self.assertFalse(json.loads(self.report.read_text())["workload_started"])
            self.report.unlink()

    def test_workload_script_changed_during_execution_is_failed(self):
        self.script.write_text('from pathlib import Path;Path(__file__).write_text("# changed while running")')
        self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(self.report.read_text())["observed_exit_code"], 0)

    def test_bytecode_cache_write_remains_failed_after_normal_exit(self):
        self.script.write_text(
            'from pathlib import Path;import sys;Path(sys.pycache_prefix,"unexpected.pyc").write_bytes(b"x")'
        )
        self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        report = json.loads(self.report.read_text())
        self.assertEqual(report["observed_exit_code"], 0)
        self.assertEqual(report["status"], "failed")

    def test_actual_import_is_private_and_isolated(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["version"], "7.2.2")
        self.assertTrue(Path(data["origin"]).is_relative_to(self.target))
        self.assertEqual((data["isolated"], data["no_site"]), (1, 1))
        report = json.loads(self.report.read_text())
        self.assertEqual(report["status"], "passed")
        self.assertTrue(report["package_after"]["matches"])
        self.assertTrue(
            any(
                v["kind"] == "private-package" and ".so" in v.get("path", "")
                for v in report["modules_before"]["modules"].values()
            )
        )

    def test_ambient_pythonpath_never_executes(self):
        ambient = self.root / "ambient"
        ambient.mkdir()
        sentinel = self.root / "ambient-executed"
        (ambient / "psutil.py").write_text(
            "from pathlib import Path;Path(" + repr(str(sentinel)) + ').write_text("bad");raise RuntimeError("ambient")'
        )
        environment = dict(os.environ, PYTHONPATH=str(ambient), GITHUB_TOKEN="synthetic-never-published")
        result = self.invoke(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertNotIn("synthetic-never-published", self.report.read_text())
        self.assertNotIn("GITHUB_TOKEN", self.report.read_text())

    def test_actual_child_has_only_explicit_private_environment(self):
        self.script.write_text("import os,json;print(json.dumps(dict(os.environ),sort_keys=True))")
        self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        environment = runtime.private_environment(self.root / "private")
        result = self.invoke(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = startup_profile.environment_request(environment)

        def observe(actual, platform):
            # 발신 값은 그대로 비교하고 운영체제의 제한된 시작 추가만 따로 검증한다.
            observation = startup_profile.observe_request(expected, actual, platform=platform)
            startup_profile.validate_observation(observation)
            self.assertEqual({key: actual[key] for key in environment}, environment)
            return observation

        observe(json.loads(result.stdout), sys.platform)
        for platform in ["linux", "darwin"]:
            with self.subTest(platform=platform):
                self.assertIsNone(observe(dict(environment), platform)["addition"])
                for changed in [
                    dict(environment, UNKNOWN_STARTUP_KEY="synthetic"),
                    dict(environment, TZ="changed"),
                    {key: value for key, value in environment.items() if key != "HOME"},
                ]:
                    with self.assertRaises(ValueError):
                        observe(changed, platform)
        added = dict(environment, __CF_USER_TEXT_ENCODING="synthetic-darwin-value")
        addition = observe(added, "darwin")["addition"]
        self.assertEqual(addition["identifier"], startup_profile.IDENTIFIER)
        self.assertEqual(addition["sha256"], hashlib.sha256(b"synthetic-darwin-value").hexdigest())
        with self.assertRaises(ValueError):
            observe(added, "linux")

    def test_captured_stale_package_bytecode_is_never_loaded(self):
        import importlib.util
        import marshal
        import struct

        source = self.target / "psutil/__init__.py"
        # 바깥 계약 런타임의 캐시 prefix가 아니라 패키지 안의 낡은 캐시를 재현한다.
        with mock.patch.object(sys, "pycache_prefix", None):
            cache = Path(importlib.util.cache_from_source(str(source)))
        self.assertTrue(cache.is_relative_to(self.target))
        cache.parent.mkdir(exist_ok=True)
        header = importlib.util.MAGIC_NUMBER + struct.pack(
            "<III", 0, int(source.stat().st_mtime), source.stat().st_size
        )
        cache.write_bytes(
            header + marshal.dumps(compile('raise RuntimeError("stale cached code")', str(source), "exec"))
        )
        self.config["package"] = runtime.package_snapshot(self.target, self.projection)
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["version"], "7.2.2")
        report = json.loads(self.report.read_text())
        self.assertFalse(report["modules_before"]["modules"]["psutil"]["bytecode_cache"]["exists"])

    def test_added_target_module_refuses_before_workload(self):
        (self.target / "unexpected.py").write_text('raise RuntimeError("must not import")')
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        report = json.loads(self.report.read_text())
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["workload_started"])

    def test_changed_script_refuses_before_execution(self):
        self.script.write_text('print("should never execute")')
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertFalse(json.loads(self.report.read_text())["workload_started"])

    def test_ordinary_workload_exceptions_retain_receipt_and_terminal_guards(self):
        for index, source in enumerate(
            [
                'raise ValueError("workload value error")',
                'raise AssertionError("workload assertion")',
                "1 / 0",
            ]
        ):
            with self.subTest(source=source):
                self.script.write_text(source)
                self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
                self.receipt.write_text(json.dumps(self.config, sort_keys=True))
                self.report = self.root / f"exception-{index}/runtime-result.json"
                result = self.invoke()
                self.assertEqual(result.returncode, 1)
                self.assertTrue(self.report.is_file(), result.stderr)
                report = json.loads(self.report.read_text())
                self.assertEqual(report["observed_exit_code"], 1)
                self.assertEqual(report["exit_code_origin"], "mapped-unhandled-python-exception")
                self.assertEqual(report["status"], "failed")
                self.assertEqual(report["code_after"]["status"], "passed")
                self.assertTrue(report["package_after"]["matches"])
                self.assertIn("modules", report["modules_after"])
                self.assertIn(report["workload_exception"]["type"], result.stderr)
                self.assertNotIn("failure_category", report)

    def test_workload_exception_and_terminal_binding_failure_are_both_retained(self):
        self.script.write_text(
            'from pathlib import Path;Path(__file__).write_text("# modified");raise ValueError("failed")'
        )
        self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        report = json.loads(self.report.read_text())
        self.assertEqual(report["workload_exception"]["type"], "ValueError")
        self.assertEqual(report["observed_exit_code"], 1)
        self.assertEqual(report["failure_category"], "runtime-binding-failed")
        self.assertEqual(report["code_after"]["status"], "checking")

    def test_completed_nonzero_retains_terminal_guards(self):
        self.script.write_text("raise SystemExit(9)")
        self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 9)
        report = json.loads(self.report.read_text())
        self.assertEqual(report["observed_exit_code"], 9)
        self.assertTrue(report["package_after"]["matches"])

    def test_system_exit_values_keep_python_process_semantics(self):
        for index, (value, expected) in enumerate([(False, 0), (True, 1), (-1, 255), (256, 0), ("text exit", 1)]):
            with self.subTest(value=value):
                self.script.write_text("raise SystemExit(" + repr(value) + ")")
                self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
                self.receipt.write_text(json.dumps(self.config, sort_keys=True))
                self.report = self.root / f"exit-{index}/runtime-result.json"
                result = self.invoke()
                self.assertEqual(result.returncode, expected)
                report = json.loads(self.report.read_text())
                self.assertEqual(report["observed_exit_code"], expected)
                self.assertEqual(report["exit_code_origin"], "workload-system-exit")
                self.assertTrue(report["package_after"]["matches"])
                if isinstance(value, str):
                    self.assertEqual(result.stderr, value + "\n")
                else:
                    self.assertEqual(report["system_exit_integer"], int(value))

    def test_keyboard_interrupt_is_incomplete_without_terminal_guards(self):
        self.script.write_text("raise KeyboardInterrupt")
        self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 125)
        report = json.loads(self.report.read_text())
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["failure_category"], "interrupt")
        self.assertEqual(report["code_after"]["status"], "unavailable")
        self.assertNotIn("workload_exception", report)

    def test_reserved125_keeps_post_guard_unavailable(self):
        self.script.write_text("raise SystemExit(125)")
        self.config["code_files"][str(self.script)] = runtime.file_identity(self.script)["sha256"]
        self.receipt.write_text(json.dumps(self.config, sort_keys=True))
        result = self.invoke()
        self.assertEqual(result.returncode, 125)
        report = json.loads(self.report.read_text())
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["package_after"]["status"], "unavailable")


class MemoryVerificationTests(unittest.TestCase):
    def setUp(self):
        import isolated_measure

        self.measure = isolated_measure
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stem = Path(self.temp.name).resolve() / "whole"
        self.command = dict(command=["selected-bootstrap"], cwd=str(self.stem.parent),
                            timeout_seconds=5, interval_seconds=.01, measurement_mode="memory")
        self.command_path = Path(str(self.stem) + ".command.json")
        self.command_path.write_text(json.dumps(self.command))
        self.paths = []
        self.result = dict(
            schema_version=2, helper_sha256=self.measure.HELPER_SHA256, measurement_mode="memory",
            primary_timing_eligible=False, status="ok", failure=None, root_returncode=0, returncode=0,
            timed_out=False, cleanup=None, wall_seconds=.04, root_exit_observed_seconds=.015,
            artifacts=dict(command=dict(name=self.command_path.name,
                                         sha256=hashlib.sha256(self.command_path.read_bytes()).hexdigest())),
            rss=dict(metric="observed_sampled_near_simultaneous_process_tree_rss_bytes", sample_chunks=[],
                     sample_total_bytes=0, sample_chunk_limit_bytes=self.measure.SAMPLE_CHUNK_LIMIT,
                     sample_count=2, observed_peak_bytes=3, observed_process_count=1, read_errors=[],
                     requested_interval_seconds=.01, actual_interval_median_seconds=.02,
                     actual_interval_max_seconds=.02, sweep_max_seconds=.01),
        )
        for index, (begin, end, rss) in enumerate([(0.0, .01, 2), (.02, .03, 3)], 1):
            sample = dict(start_seconds=begin, end_seconds=end, rss_bytes=rss, process_count=1,
                          processes=[dict(process_id=1, pid=123, create_time=1.0, rss_bytes=rss)])
            path = Path(str(self.stem) + f".samples.{index:04d}.jsonl")
            path.write_text(json.dumps(sample) + "\n")
            self.paths.append(path)
            self.result["rss"]["sample_chunks"].append(self.chunk(path))
        self.result["rss"]["sample_total_bytes"] = sum(path.stat().st_size for path in self.paths)
        self.result["rss"]["sweep_max_seconds"] = max(.01 - 0.0, .03 - .02)

    def chunk(self, path):
        data = path.read_bytes()
        return dict(name=path.name, sha256=hashlib.sha256(data).hexdigest(), bytes=len(data),
                    sample_count=len(data.splitlines()))

    def verify(self, result=None, mode="memory"):
        result = self.result if result is None else result
        Path(str(self.stem) + ".json").write_text(json.dumps(result))
        return self.measure.verify_measurement(self.stem, result, mode, self.command)

    def test_every_rotated_chunk_and_exact_summary_is_accepted(self):
        self.verify()
        self.assertEqual(len(self.result["rss"]["sample_chunks"]), 2)

    def test_sample_after_root_exit_is_valid_within_enclosing_wall(self):
        self.result["wall_seconds"] = .03
        self.verify()
        sample = json.loads(self.paths[-1].read_text())
        self.assertGreater(sample["start_seconds"], self.result["root_exit_observed_seconds"])
        self.assertEqual(sample["end_seconds"], self.result["wall_seconds"])

    def test_successful_memory_intervals_reject_invalid_or_incoherent_numbers(self):
        for key in ["wall_seconds", "root_exit_observed_seconds"]:
            for value in [None, True, 0, -1, float("nan"), float("inf"), "1", 6]:
                with self.subTest(key=key, value=value):
                    changed = copy.deepcopy(self.result)
                    changed[key] = value
                    with self.assertRaises(ValueError):
                        self.verify(changed)

    def test_shortened_wall_and_rehashed_late_sample_cannot_lower_memory_ratio(self):
        changed = copy.deepcopy(self.result)
        changed["wall_seconds"] = .025
        with self.assertRaisesRegex(ValueError, "beyond enclosing measured wall"):
            self.verify(changed)
        sample = json.loads(self.paths[1].read_text())
        sample["end_seconds"] = .05
        self.paths[1].write_text(json.dumps(sample) + "\n")
        changed = copy.deepcopy(self.result)
        changed["rss"]["sample_chunks"][1] = self.chunk(self.paths[1])
        changed["rss"]["sample_total_bytes"] = sum(path.stat().st_size for path in self.paths)
        changed["rss"]["sweep_max_seconds"] = .05 - .02
        with self.assertRaisesRegex(ValueError, "beyond enclosing measured wall"):
            self.verify(changed)

    def test_successful_timing_intervals_require_frozen_root_and_supervision_relationship(self):
        self.command["measurement_mode"] = "timing"
        self.command_path.write_text(json.dumps(self.command))
        self.result.update(measurement_mode="timing", sampling_during_timing=False, rss=None,
                           primary_timing_eligible=True, wall_seconds=1.0, root_exit_observed_seconds=1.0,
                           supervision_total_seconds=1.1)
        self.result["artifacts"]["command"]["sha256"] = hashlib.sha256(self.command_path.read_bytes()).hexdigest()
        self.verify(mode="timing")
        mutations = [
            ("wall_seconds", None), ("wall_seconds", True), ("wall_seconds", 0),
            ("wall_seconds", -1), ("wall_seconds", float("nan")), ("wall_seconds", float("inf")),
            ("root_exit_observed_seconds", None), ("root_exit_observed_seconds", True),
            ("root_exit_observed_seconds", 0), ("root_exit_observed_seconds", -1),
            ("root_exit_observed_seconds", float("nan")), ("root_exit_observed_seconds", float("inf")),
            ("root_exit_observed_seconds", .9), ("root_exit_observed_seconds", 1.01),
            ("supervision_total_seconds", None), ("supervision_total_seconds", True),
            ("supervision_total_seconds", -1), ("supervision_total_seconds", float("nan")),
            ("supervision_total_seconds", float("inf")), ("supervision_total_seconds", .9),
        ]
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                changed = copy.deepcopy(self.result)
                changed[key] = value
                with self.assertRaises(ValueError):
                    self.verify(changed, mode="timing")
        changed = copy.deepcopy(self.result)
        changed.update(wall_seconds=6, root_exit_observed_seconds=6, supervision_total_seconds=6.1)
        with self.assertRaisesRegex(ValueError, "declared deadline"):
            self.verify(changed, mode="timing")

    def test_wrong_mode_command_artifact_and_failure_cannot_pass(self):
        mutations = [
            lambda r: r.update(measurement_mode="timing"),
            lambda r: r.update(helper_sha256="0" * 64),
            lambda r: r.update(schema_version=True),
            lambda r: r.update(timed_out=0),
            lambda r: r.update(root_returncode=True),
            lambda r: r.update(returncode=True),
            lambda r: r.update(failure="incomplete_process_observation"),
            lambda r: r["artifacts"]["command"].update(sha256="0" * 64),
            lambda r: r["rss"].update(read_errors=["access_denied_during_rss_read"]),
            lambda r: r["rss"].update(sample_count=True),
            lambda r: r["rss"].update(observed_peak_bytes=True),
            lambda r: r["rss"].update(observed_process_count=True),
            lambda r: r["rss"].update(sweep_max_seconds=True),
            lambda r: r["rss"]["sample_chunks"][1].update(sha256="0" * 64),
            lambda r: r["rss"]["sample_chunks"][1].update(bytes=True),
            lambda r: r["rss"]["sample_chunks"][1].update(sample_count=True),
            lambda r: r["rss"]["sample_chunks"][1].update(name="../outside.jsonl"),
            lambda r: r["rss"]["sample_chunks"].reverse(),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                changed = copy.deepcopy(self.result)
                mutate(changed)
                with self.assertRaises(ValueError):
                    self.verify(changed)

    def test_missing_extra_and_changed_late_chunk_all_fail(self):
        original = self.paths[1].read_bytes()
        self.paths[1].unlink()
        with self.assertRaises((OSError, ValueError)):
            self.verify()
        self.paths[1].write_bytes(original + b"\n")
        with self.assertRaises(ValueError):
            self.verify()
        self.paths[1].write_bytes(original)
        extra = Path(str(self.stem) + ".samples.0003.jsonl")
        extra.write_bytes(original)
        with self.assertRaises(ValueError):
            self.verify()

    def test_rehashed_invalid_late_sample_cannot_evade_strict_types_or_identity(self):
        original = json.loads(self.paths[1].read_text())
        mutations = [
            lambda row: row.update(rss_bytes=True),
            lambda row: row.update(process_count=True),
            lambda row: row.update(start_seconds=True),
            lambda row: row["processes"][0].update(pid=True),
            lambda row: row["processes"][0].update(process_id=True),
            lambda row: row["processes"][0].update(create_time=True),
            lambda row: row["processes"][0].update(pid=456),
            lambda row: row["processes"][0].update(rss_bytes=99),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                sample = copy.deepcopy(original)
                mutate(sample)
                self.paths[1].write_text(json.dumps(sample) + "\n")
                changed = copy.deepcopy(self.result)
                changed["rss"]["sample_chunks"][1] = self.chunk(self.paths[1])
                changed["rss"]["sample_total_bytes"] = sum(path.stat().st_size for path in self.paths)
                with self.assertRaises(ValueError):
                    self.verify(changed)

    def test_rewritten_command_mode_is_rejected_even_with_matching_new_hash(self):
        self.command_path.write_text(json.dumps({**self.command, "measurement_mode": "timing"}))
        self.result["artifacts"]["command"]["sha256"] = hashlib.sha256(self.command_path.read_bytes()).hexdigest()
        with self.assertRaises(ValueError):
            self.verify()


if __name__ == "__main__":
    unittest.main(verbosity=2)
