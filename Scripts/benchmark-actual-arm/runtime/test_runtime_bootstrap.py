"""새 Python 프로세스가 주위 설치 대신 봉인된 --target만 가져오는지 확인한다."""

import hashlib
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

    def measured_workload(self, source, timeout=5, command_override=None, cwd_override=None):
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
        return isolated_measure.run(
            command,
            cwd_override or self.root,
            self.root / "measurement/whole",
            self.receipt,
            digest,
            runtime.private_environment(self.root / "engine-private"),
            runtime.private_environment(self.root / "observer-private"),
            timeout=timeout,
        )

    def test_direct_true_cannot_bypass_engine_runtime(self):
        with self.assertRaises(ValueError):
            self.measured_workload("pass", command_override=["/bin/true"])
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
        self.assertEqual(json.loads(result.stdout), environment)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
