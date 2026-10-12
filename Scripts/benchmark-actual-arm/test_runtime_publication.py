"""모듈 지도의 이름을 옮겨도 원래 요청·해시·민감값 검사는 사라지지 않는지 확인한다."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import runtime_publication as projection
import publish_correctness as publication


class RuntimePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.raw = Path(self.temp.name).resolve() / "raw"
        self.raw.mkdir()
        self.write("results.json", dict(status="synthetic-publication-control"))
        self.modules = {
            "psutil": dict(
                kind="private-package", path=str(self.raw / "package/psutil/__init__.py"), sha256="e" * 64, bytes=30
            ),
            "token": dict(kind="observed-stdlib", path=str(self.raw / "stdlib/token.py"), sha256="a" * 64, bytes=20),
        }
        self.config = dict(
            python=dict(path=sys.executable, sha256="b" * 64, bytes=20),
            package=dict(target=str(self.raw / "package"), content=dict(content_sha256="c" * 64)),
            code_files={
                str(projection.ROOT / name): "d" * 64
                for name in [
                    "contract_suite.py",
                    "state_worker.py",
                    "engine_worker.py",
                    "runtime/vendor/process_tree_measure.py",
                ]
            },
        )
        self.write("setup/runtime.json", self.config)
        self.write("setup/contracts/runtime.json", self.config)

    def write(self, name, value):
        path = self.raw / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return path

    def receipt(self, config_path, script, arguments):
        ref = projection.state_inputs.reference(config_path)
        snapshot = dict(modules=copy.deepcopy(self.modules), sha256=projection.digest(self.modules))
        package = dict(
            matches=True, expected_sha256="c" * 64, actual_sha256="c" * 64, actual=dict(content_sha256="c" * 64)
        )
        return dict(
            runtime_receipt_sha256=ref["sha256"],
            entrypoint=dict(path=str(script), sha256="d" * 64),
            selected_code_files=self.config["code_files"],
            arguments_sha256=hashlib.sha256(json.dumps(arguments, separators=(",", ":")).encode()).hexdigest(),
            exit_code=0,
            observed_exit_code=0,
            workload_started=True,
            python=self.config["python"],
            status="passed",
            code_after=dict(status="passed"),
            package_before=package,
            package_after=package,
            modules_before=snapshot,
            modules_after=copy.deepcopy(snapshot),
        )

    def setup_integration(self):
        config = self.raw / "setup/contracts/runtime.json"
        folder = self.raw / "setup/contracts/integration"
        args = ["--suite", "integration", "--output", str(folder / "summary.json")]
        receipt = self.receipt(config, projection.ROOT / "contract_suite.py", args)
        report = self.write("setup/contracts/integration/runtime-result.json", receipt)
        argv = projection.isolated_measure.bootstrap_command(
            config,
            projection.state_inputs.reference(config)["sha256"],
            projection.ROOT / "contract_suite.py",
            report,
            args,
        )
        self.write(
            "setup/contracts/integration/process.json",
            dict(command=argv, returncode=0, observed_returncode=0, completed=True, failure=None),
        )
        return receipt, report

    def package(self):
        return projection.package(
            publication.NORMALIZER,
            argparse.Namespace(
                input=self.raw,
                output=self.raw.parent / "public",
                prefix=[
                    "SCRATCH=" + str(self.raw.parent),
                    "SOURCES=" + str(projection.ROOT),
                    "PYTHON=" + str(Path(sys.executable).parent),
                    "TEMP=/tmp",
                    "OPT=/opt",
                    "USR=/usr",
                ],
            ),
        )

    def test_exact_integration_and_embedded_copies_roundtrip(self):
        receipt, report = self.setup_integration()
        self.write("setup/contracts/results.json", dict(suites=[dict(runtime=receipt)]))
        p = projection.Projection(self.raw).collect()
        rendered = json.loads(p.transform(report.read_bytes(), "setup/contracts/integration/runtime-result.json"))
        self.assertEqual(projection.restore(rendered), receipt)
        projection.module_record("_sysconfigdata__linux_x86_64-linux-gnu", self.modules["token"])
        self.assertEqual([x["name"] for x in rendered["modules_before"]["modules"]], ["psutil", "token"])
        transformed = json.loads(
            p.transform((self.raw / "setup/contracts/results.json").read_bytes(), "setup/contracts/results.json")
        )
        self.assertEqual(projection.restore(transformed["suites"][0]["runtime"]), receipt)

    def test_duplicates_or_reordering_cannot_reconstruct(self):
        receipt, _ = self.setup_integration()
        for rows in [
            [dict(name="token", record={}), dict(name="token", record={})],
            list(reversed(projection.project(receipt)["modules_before"]["modules"])),
        ]:
            value = projection.project(receipt)
            value["modules_before"]["modules"] = rows
            with self.assertRaises(ValueError):
                projection.restore(value)

    def test_changed_module_content_cannot_reconstruct(self):
        receipt, _ = self.setup_integration()
        value = projection.project(receipt)
        value["modules_after"]["modules"][0]["record"]["kind"] = "changed"
        with self.assertRaises(ValueError):
            projection.restore(value)

    def test_wrong_original_map_digest_refuses_projection(self):
        receipt, _ = self.setup_integration()
        receipt["modules_before"]["sha256"] = "f" * 64
        with self.assertRaises(ValueError):
            projection.project(receipt)

    def test_unknown_receipt_is_not_shape_projected(self):
        receipt, _ = self.setup_integration()
        p = projection.Projection(self.raw).collect()
        receipt["extra"] = "unbound"
        data = json.dumps(receipt).encode()
        self.assertEqual(p.transform(data, "setup/unbound.json"), data)
        with self.assertRaises(publication.NORMALIZER.PublicationBlocked):
            publication.NORMALIZER.check_sensitive(data.decode(), "setup/unbound.json")

    def test_real_credential_inside_module_record_still_blocks(self):
        receipt, report = self.setup_integration()
        receipt["modules_before"]["modules"]["token"]["path"] = str(self.raw / ("ghp_" + "x" * 40))
        receipt["modules_before"]["sha256"] = projection.digest(receipt["modules_before"]["modules"])
        report.write_text(json.dumps(receipt))
        with self.assertRaises(publication.NORMALIZER.PublicationBlocked):
            self.package()
        self.assertFalse((self.raw.parent / "public").exists())

    def test_private_module_path_still_blocks(self):
        receipt, report = self.setup_integration()
        receipt["modules_before"]["modules"]["token"]["path"] = "/unmapped-private/location"
        receipt["modules_before"]["sha256"] = projection.digest(receipt["modules_before"]["modules"])
        report.write_text(json.dumps(receipt))
        with self.assertRaises(publication.NORMALIZER.PublicationBlocked):
            self.package()

    def test_original_file_hashes_remain_original_after_projection(self):
        receipt, report = self.setup_integration()
        raw_hash = hashlib.sha256(report.read_bytes()).hexdigest()
        manifest = self.package()
        row = next(x for x in manifest["files"] if x["path"] == "setup/contracts/integration/runtime-result.json")
        self.assertEqual(row["original_raw_sha256"], raw_hash)
        self.assertNotEqual(row["normalized_sha256"], raw_hash)
        self.assertEqual(manifest["runtime_module_projection"]["original_receipts"][0]["original_raw_sha256"], raw_hash)

    def test_request_mismatch_is_not_publication_authority(self):
        self.setup_integration()
        path = self.raw / "setup/contracts/integration/process.json"
        phase = json.loads(path.read_text())
        phase["command"][-1] = "wrong"
        path.write_text(json.dumps(phase))
        with self.assertRaises(ValueError):
            projection.Projection(self.raw).collect()

    def test_post_projection_source_mutation_blocks(self):
        _, report = self.setup_integration()
        p = projection.Projection(self.raw).collect()
        report.write_text("{}")
        with self.assertRaises(ValueError):
            p.unchanged()

    def test_default_normalizer_still_rejects_module_credential_key(self):
        self.setup_integration()
        with self.assertRaises(publication.NORMALIZER.PublicationBlocked):
            publication.NORMALIZER.package(
                argparse.Namespace(
                    input=self.raw, output=self.raw.parent / "default", prefix=["SCRATCH=" + str(self.raw.parent)]
                )
            )

    def test_state_and_engine_observer_shapes_bind_original_requests(self):
        config = self.raw / "setup/runtime.json"
        ref = projection.state_inputs.reference(config)
        plan = self.write("setup/plan.json", dict(accepted="synthetic"))
        planref = projection.state_inputs.reference(plan)
        args = [
            "--plan",
            str(plan),
            "--plan-sha256",
            planref["sha256"],
            "--runtime",
            str(config),
            "--runtime-sha256",
            ref["sha256"],
            "--output",
            str(self.raw),
        ]
        report = self.write(
            "setup/state-runtime/runtime-result.json", self.receipt(config, projection.ROOT / "state_worker.py", args)
        )
        command = projection.isolated_measure.bootstrap_command(
            config, ref["sha256"], projection.ROOT / "state_worker.py", report, args
        )
        self.write(
            "setup/whole-state.json",
            dict(command=command, returncode=0, observed_returncode=0, completed=True, failure=None),
        )
        folder = self.raw / "runs/restored_rebuilt/baseline"
        inputs = self.write("runs/restored_rebuilt/baseline/input.json", dict(arm="baseline"))
        args = ["--input", str(inputs), "--sha256", projection.state_inputs.reference(inputs)["sha256"]]
        report = self.write(
            "runs/restored_rebuilt/baseline/engine-runtime/runtime-result.json",
            self.receipt(config, projection.ROOT / "engine_worker.py", args),
        )
        self.write(
            "runs/restored_rebuilt/baseline/whole-arm.json",
            dict(
                root_returncode=0,
                helper_sha256=projection.isolated_measure.HELPER_SHA256,
                measurement_mode="timing",
                sampling_during_timing=False,
            ),
        )
        self.write(
            "runs/restored_rebuilt/baseline/whole-arm.command.json",
            dict(
                command=projection.isolated_measure.bootstrap_command(
                    config, ref["sha256"], projection.ROOT / "engine_worker.py", report, args
                )
            ),
        )
        self.write(
            "runs/restored_rebuilt/baseline/observer-runtime/runtime-result.json",
            self.receipt(config, projection.isolated_measure.HELPER, ["--worker"]),
        )
        self.write("runs/restored_rebuilt/baseline/whole-arm.observer.json", dict(observed_helper_returncode=0))
        p = projection.Projection(self.raw).collect()
        self.assertEqual(len(p.bindings), 3)
        self.package()

    def test_credential_named_arbitrary_module_payload_is_rejected(self):
        receipt, report = self.setup_integration()
        receipt["modules_before"]["modules"]["AWS_SECRET_ACCESS_KEY"] = "synthetic-secret-scalar"
        receipt["modules_before"]["sha256"] = projection.digest(receipt["modules_before"]["modules"])
        report.write_text(json.dumps(receipt))
        with self.assertRaises(ValueError):
            projection.Projection(self.raw).collect()


if __name__ == "__main__":
    unittest.main(verbosity=2)
