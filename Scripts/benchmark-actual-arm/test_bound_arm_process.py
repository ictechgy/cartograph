"""실제 격리 프로세스의 125·신호·일반 실패를 새 순서 제어까지 전달한다."""

import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import psutil
import state_worker as worker

ROOT = Path(__file__).resolve().parent


class BoundArmProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.target = self.root / "packages"
        self.target.mkdir()
        shutil.copytree(Path(psutil.__file__).parent, self.target / "psutil")
        dist = importlib.metadata.distribution("psutil")
        self.assertEqual(dist.version, "7.2.2")
        metadata = next(Path(dist.locate_file(p)).parent for p in dist.files if str(p).endswith(".dist-info/METADATA"))
        shutil.copytree(metadata, self.target / "psutil-7.2.2.dist-info")
        projection = dict(
            schema_version=1,
            source_format="pip-install-report-v1",
            distributions=[
                dict(
                    name="psutil",
                    version="7.2.2",
                    url="https://files.pythonhosted.org/packages/aa/bb/"
                    + "c" * 60
                    + "/psutil-7.2.2-cp36-abi3-macosx_11_0_arm64.whl",
                    sha256="a" * 64,
                    is_direct=False,
                    is_yanked=False,
                    requested=True,
                )
            ],
        )
        self.package = worker.identity.package_snapshot(self.target, projection)
        self.scripts = self.root / "selected-code"
        self.scripts.mkdir()
        self.engine = self.scripts / "engine_worker.py"
        self.raw = self.root / "raw"
        self.raw.mkdir()
        self.project = self.root / "project"
        self.project.mkdir()
        self.developer = self.root / "Developer"
        self.developer.mkdir()
        self.plan = dict(
            engine_config=dict(project=str(self.project), developer_directory=str(self.developer)),
            input_roots=[str(self.project), str(self.target), str(self.scripts)],
            raw_output=str(self.raw),
            inputs={},
            accepted=dict(sdk_content_identity=None),
            prior_costs={},
        )

    def configure(self, body):
        self.engine.write_text(
            'import argparse,json,os,signal,sys,time\nfrom pathlib import Path\np=argparse.ArgumentParser();p.add_argument("--input");p.add_argument("--sha256");a=p.parse_args();c=json.loads(Path(a.input).read_text())\n'
            + body
            + "\n"
        )
        sources = [
            ROOT / "runtime/runtime_bootstrap.py",
            ROOT / "runtime/runtime_identity.py",
            ROOT / "runtime/vendor/sdk_content_seal.py",
            ROOT / "runtime/vendor/process_tree_measure.py",
            self.engine,
        ]
        self.runtime = self.root / "runtime.json"
        self.runtime.write_text(
            json.dumps(
                dict(
                    schema_version=1,
                    package=self.package,
                    python=dict(path=sys.executable, **worker.identity.file_identity(Path(sys.executable))),
                    code_files={str(p): worker.identity.file_identity(p)["sha256"] for p in sources},
                )
            )
        )
        self.runtime_sha = hashlib.sha256(self.runtime.read_bytes()).hexdigest()

    def run_arm(self):
        with mock.patch.object(worker, "ROOT", self.scripts), mock.patch.object(
            worker, "guard", return_value=dict(status="passed")
        ) as guards:
            result = worker.run_arm(
                self.plan, "baseline", self.raw / "runs/restored_rebuilt/baseline", self.runtime, self.runtime_sha
            )
        return result, guards.call_count

    def test_successful_actual_bootstrap_has_both_runtime_receipts_and_private_caches(self):
        self.configure(
            'print(json.dumps({"home":os.environ["HOME"],"tmp":os.environ["TMPDIR"],"pythonpath":os.environ.get("PYTHONPATH"),"secret":os.environ.get("SYNTHETIC_SECRET")}));time.sleep(.025);Path(c["output"],"worker-result.json").write_text(json.dumps({"status":"ok"}))'
        )
        with mock.patch.dict(
            os.environ, {"PYTHONPATH": "/ambient-unaccepted", "SYNTHETIC_SECRET": "synthetic-private-value"}
        ):
            row, guards = self.run_arm()
        self.assertEqual(row["status"], "passed", row)
        self.assertEqual(guards, 2)
        observed = json.loads((self.raw / "runs/restored_rebuilt/baseline/whole-arm.stdout").read_text())
        self.assertIsNone(observed["pythonpath"])
        self.assertIsNone(observed["secret"])
        self.assertNotEqual(observed["home"], observed["tmp"])
        self.assertTrue(Path(observed["tmp"]).is_relative_to(self.raw / "private-readers/baseline/engine"))
        self.assertGreater(row["observer"]["measurement"]["wall_seconds"], 0.025)
        for key in ["runtime", "engine_runtime"]:
            self.assertEqual(row["observer"][key]["status"], "passed")
            self.assertEqual(row["observer"][key]["modules_before"]["modules"]["psutil"]["kind"], "private-package")

    def test_actual_exit125_stops_before_second_arm_and_evaluation(self):
        self.configure("raise SystemExit(125)")
        with mock.patch.object(worker, "ROOT", self.scripts), mock.patch.object(
            worker, "guard", return_value=dict(status="passed")
        ):
            result = worker.execute(self.plan, self.runtime, self.runtime_sha, self.raw)
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["skipped_arms"], ["cartograph"])
        self.assertEqual(result["evaluation"]["status"], "not-run")
        arm = result["arms"][0]
        self.assertEqual(arm["observer"]["workload_returncode"], 125)
        self.assertEqual(arm["guard_after"]["status"], "unavailable")

    def test_actual_signal_preserves_raw_negative_code_and_incomplete_status(self):
        self.configure("os.kill(os.getpid(),signal.SIGTERM)")
        row, guards = self.run_arm()
        self.assertEqual(row["exit_code"], 125)
        self.assertEqual(guards, 1)
        self.assertEqual(row["observer"]["workload_returncode"], -15)
        self.assertFalse(row["may_continue"])

    def test_actual_ordinary_nonzero_gets_terminal_guards(self):
        self.configure(
            'Path(c["output"],"worker-result.json").write_text(json.dumps({"status":"failed"}));raise SystemExit(9)'
        )
        row, guards = self.run_arm()
        self.assertEqual(row["exit_code"], 9)
        self.assertEqual(guards, 2)
        self.assertTrue(row["may_continue"])
        self.assertEqual(row["observer"]["engine_runtime"]["status"], "failed")

    def test_actual_launch_failure_remains_incomplete(self):
        self.configure("raise SystemExit(0)")
        self.project.rmdir()
        row, guards = self.run_arm()
        self.assertEqual(row["exit_code"], 125)
        self.assertEqual(guards, 1)
        self.assertFalse(row["may_continue"])
        self.assertIn(row["observer"]["measurement"]["failure"], {"launch_error", "FileNotFoundError"})

    def test_actual_timeout_retains_failure_and_prevents_continuation(self):
        self.configure("time.sleep(5)")
        actual = worker.isolated_measure.run

        def bounded(*args, **kwargs):
            kwargs["timeout"] = 0.1
            return actual(*args, **kwargs)

        with mock.patch.object(worker.isolated_measure, "run", side_effect=bounded):
            row, guards = self.run_arm()
        self.assertEqual(row["exit_code"], 125)
        self.assertEqual(guards, 1)
        self.assertFalse(row["may_continue"])
        self.assertEqual(row["observer"]["measurement"]["failure"], "timeout")


if __name__ == "__main__":
    unittest.main(verbosity=2)
