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
            schema_version=1,
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
        plan = self.write(
            "setup/plan.json", dict(accepted="synthetic", engine_config=dict(developer_directory=str(self.raw)))
        )
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
        self.write("runs/restored_rebuilt/baseline/whole-arm.observer.json", dict(
            observed_helper_returncode=0,
            command=projection.isolated_measure.bootstrap_command(
                config, ref["sha256"], projection.isolated_measure.HELPER,
                folder / "observer-runtime/runtime-result.json", ["--worker"],
            ),
        ))
        p = projection.Projection(self.raw).collect()
        self.assertEqual(len(p.bindings), 3)
        self.package()

    def setup_observer(self):
        config = self.raw / "setup/runtime.json"
        ref = projection.state_inputs.reference(config)
        folder = self.raw / "runs/restored_rebuilt/baseline"
        report = self.write("runs/restored_rebuilt/baseline/observer-runtime/runtime-result.json",
                            self.receipt(config, projection.isolated_measure.HELPER, ["--worker"]))
        command = projection.isolated_measure.bootstrap_command(
            config, ref["sha256"], projection.isolated_measure.HELPER, report, ["--worker"]
        )
        self.write("setup/plan.json", dict(engine_config=dict(developer_directory=str(self.raw))))
        path = self.write("runs/restored_rebuilt/baseline/whole-arm.observer.json",
                          dict(command=command, observed_helper_returncode=0))
        return path, command

    def test_observer_original_argv_is_verified_when_retained(self):
        path, command = self.setup_observer()
        self.assertEqual(len(projection.Projection(self.raw).collect().bindings), 1)
        command[0] = "/different-helper-python"
        path.write_text(json.dumps(dict(command=command, observed_helper_returncode=0)))
        with self.assertRaisesRegex(ValueError, "Runtime projection request differs"):
            projection.Projection(self.raw).collect()

    def test_schema3_observer_without_original_argv_is_not_projected(self):
        path, _ = self.setup_observer()
        path.write_text(json.dumps(dict(observed_helper_returncode=0)))
        self.config["schema_version"] = 3
        self.write("setup/runtime.json", self.config)
        with self.assertRaisesRegex(ValueError, "Observer launch argv is missing"):
            projection.Projection(self.raw).collect()

    def setup_catalog(self, arms=("baseline",), lexeme="start"):
        project = self.raw.parent / "Project"
        sources = project / "Sources"
        sources.mkdir(parents=True)
        (sources / "Entry.swift").write_text("struct Entry {\n    func token() {}\n}\n")
        (sources / "Bridge.h").write_text(f"int {lexeme}(void);\n")
        (sources / "Bridge.c").write_text(f"int {lexeme}(void) {{ return 0; }}\n")
        contexts = {"Sources/" + name: ["BridgeKit"] for name in ["Entry.swift", "Bridge.h", "Bridge.c"]}
        derived = dict(contexts=contexts, accepted_generation_sha256="f" * 64)
        references = {
            name: projection.state_inputs.reference(self.write("setup/catalog-generation/" + name + ".json", {}))
            for name in ("lifecycle", "state", "commands")
        }
        producer = projection.state_inputs.reference(Path(projection.state_inputs.generation.observer.adapter.__file__))
        config = dict(
            project=str(project), developer_directory=str(self.raw), state_id="restored_rebuilt",
            accepted_sources=projection.state_inputs.source_snapshot(project), generation_receipts=references,
            helper_sha256={"vendor/mixed/adapter/mixed_adapter.py": producer["sha256"]},
        )
        self.write("setup/plan.json", dict(engine_config=config, accepted=derived))
        patcher = mock.patch.object(projection.state_inputs.generation, "verify", return_value=derived)
        self.generation_verify = patcher.start()
        self.addCleanup(patcher.stop)
        catalog = projection.state_inputs.generation.observer.adapter.source_catalog(project, contexts)
        runtime = self.raw / "setup/runtime.json"
        runtime_ref = projection.state_inputs.reference(runtime)
        for arm in arms:
            relative = "runs/restored_rebuilt/" + arm
            folder = self.raw / relative
            inputs = self.write(relative + "/input.json", dict(config, arm=arm, output=str(folder)))
            args = ["--input", str(inputs), "--sha256", projection.state_inputs.reference(inputs)["sha256"]]
            receipt = self.receipt(runtime, projection.ROOT / "engine_worker.py", args)
            receipt.update(status="failed", exit_code=1, observed_exit_code=1)
            report = self.write(relative + "/engine-runtime/runtime-result.json", receipt)
            command = projection.isolated_measure.bootstrap_command(
                runtime, runtime_ref["sha256"], projection.ROOT / "engine_worker.py", report, args
            )
            self.write(relative + "/whole-arm.command.json", dict(command=command))
            self.write(relative + "/whole-arm.json", dict(
                root_returncode=1, helper_sha256=projection.isolated_measure.HELPER_SHA256,
                measurement_mode="timing", sampling_during_timing=False,
            ))
            self.write(relative + "/source-catalog.json", catalog)
        return catalog, self.raw / "runs/restored_rebuilt/baseline/source-catalog.json", project

    def test_exact_source_catalogs_roundtrip_and_keep_failed_engine_outcomes(self):
        catalog, path, _ = self.setup_catalog(("baseline", "cartograph"))
        original = path.read_bytes()
        self.assertTrue(any("alias_of" in row for row in catalog))
        manifest = self.package()
        mapping = manifest["source_catalog_projection"]
        self.assertEqual(mapping["field_mapping"], dict(original_field="token", public_field="declaration_lexeme"))
        self.assertEqual(len(mapping["original_catalogs"]), 2)
        self.assertEqual(len(mapping["transformed_artifacts"]), 2)
        for binding in mapping["original_catalogs"]:
            public = json.loads((self.raw.parent / "public" / binding["artifact"]).read_text())
            self.assertEqual(projection.restore_catalog(public), catalog)
            self.assertEqual(binding["original_raw_sha256"], hashlib.sha256(original).hexdigest())
            self.assertEqual(binding["original_catalog_content_sha256"], projection.digest(catalog))
            row = next(row for row in manifest["files"] if row["path"] == binding["artifact"])
            self.assertEqual(row["original_raw_sha256"], binding["original_raw_sha256"])
            self.assertNotEqual(row["normalized_sha256"], row["original_raw_sha256"])
            report = (self.raw.parent / "public" / binding["artifact"]).parent / "engine-runtime/runtime-result.json"
            self.assertEqual(json.loads(report.read_text())["exit_code"], 1)
            self.assertEqual(json.loads(report.read_text())["status"], "failed")
        self.assertEqual(path.read_bytes(), original)

    def test_source_catalog_schema_and_exact_types_are_required(self):
        catalog, path, _ = self.setup_catalog()
        for changes in [dict(extra="unknown"), dict(declaration_lexeme="collision"), dict(line=True),
                        dict(column=False), dict(definition=1), dict(alias_of=7), dict(token={}),
                        dict(language="unknown"), dict(path="../escape.swift")]:
            with self.subTest(changes=changes):
                changed = copy.deepcopy(catalog)
                changed[0].update(changes)
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    projection.Projection(self.raw).collect()
        self.assertFalse((self.raw.parent / "public").exists())

    def test_changed_or_incomplete_source_catalog_is_not_projected(self):
        catalog, path, _ = self.setup_catalog()
        changed = copy.deepcopy(catalog)
        changed[0]["token"] = "differentDeclaration"
        for value in [changed, catalog[:-1], list(reversed(catalog)), catalog + catalog[:1], []]:
            path.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                projection.Projection(self.raw).collect()

    def test_source_catalog_requires_bound_original_engine_request(self):
        _, path, _ = self.setup_catalog()
        (path.parent / "engine-runtime/runtime-result.json").unlink()
        with self.assertRaisesRegex(ValueError, "no bound original engine request"):
            projection.Projection(self.raw).collect()

    def test_source_catalog_requires_selected_generation_and_contexts(self):
        self.setup_catalog()
        derived = self.generation_verify.return_value
        for value in [dict(derived, accepted_generation_sha256="0" * 64), dict(derived, contexts={})]:
            self.generation_verify.return_value = value
            with self.assertRaisesRegex(ValueError, "generation differs"):
                projection.Projection(self.raw).collect()
        self.generation_verify.side_effect = ValueError("Accepted compiler generation bytes changed")
        with self.assertRaisesRegex(ValueError, "Accepted compiler generation bytes changed"):
            projection.Projection(self.raw).collect()

    def test_source_catalog_requires_exact_selected_plan_and_producer(self):
        self.setup_catalog()
        path = self.raw / "setup/plan.json"
        plan = json.loads(path.read_text())
        plan["engine_config"]["state_id"] = "different-state"
        path.write_text(json.dumps(plan))
        with self.assertRaisesRegex(ValueError, "input differs"):
            projection.Projection(self.raw).collect()
        plan["engine_config"]["state_id"] = "restored_rebuilt"
        path.write_text(json.dumps(plan))
        original = projection.state_inputs.reference

        def wrong_producer(path):
            result = original(path)
            if Path(path).name == "mixed_adapter.py":
                result["sha256"] = "0" * 64
            return result

        with mock.patch.object(projection.state_inputs, "reference", side_effect=wrong_producer):
            with self.assertRaisesRegex(ValueError, "producer changed"):
                projection.Projection(self.raw).collect()

    def test_unrecognized_or_embedded_catalog_is_not_projected(self):
        catalog, _, _ = self.setup_catalog()
        p = projection.Projection(self.raw).collect()
        for relative, value in [("source-catalog.json", catalog),
                                ("runs/other/baseline/source-catalog.json", catalog),
                                ("results.json", dict(catalog=catalog))]:
            data = json.dumps(value).encode()
            self.assertEqual(p.transform(data, relative), data)
            with self.assertRaises(publication.NORMALIZER.PublicationBlocked):
                publication.NORMALIZER.check_sensitive(data.decode(), relative)

    def test_real_credential_in_source_derived_catalog_still_blocks(self):
        self.setup_catalog(lexeme="ghp_" + "x" * 40)
        with self.assertRaises(publication.NORMALIZER.PublicationBlocked):
            self.package()
        self.assertFalse((self.raw.parent / "public").exists())

    def test_unknown_credential_field_is_not_hidden_by_catalog_projection(self):
        catalog, path, _ = self.setup_catalog()
        catalog[0]["password"] = "synthetic-secret"
        path.write_text(json.dumps(catalog))
        with self.assertRaisesRegex(ValueError, "Unexpected source catalog fields"):
            projection.Projection(self.raw).collect()
        with self.assertRaises(publication.NORMALIZER.PublicationBlocked):
            publication.NORMALIZER.check_sensitive(json.dumps(catalog), str(path.relative_to(self.raw)))

    def test_catalog_and_source_changes_after_binding_are_refused(self):
        catalog, path, project = self.setup_catalog()
        p = projection.Projection(self.raw).collect()
        catalog[0]["anchor"] += " changed"
        path.write_text(json.dumps(catalog))
        with self.assertRaisesRegex(ValueError, "Bound source catalog changed"):
            p.transform(path.read_bytes(), str(path.relative_to(self.raw)))
        with self.assertRaisesRegex(ValueError, "projection source changed"):
            p.unchanged()
        (project / "Sources/New.swift").write_text("func added() {}\n")
        with self.assertRaisesRegex(ValueError, "source inventory changed"):
            p.unchanged()
        with self.assertRaisesRegex(ValueError, "sources changed"):
            projection.Projection(self.raw).collect()

    def test_catalog_reconstruction_rejects_collision_and_type_changes(self):
        catalog, _, _ = self.setup_catalog()
        for changes in [dict(token="collision"), dict(line=True), dict(definition=1), dict(declaration_lexeme={})]:
            projected = projection.project_catalog(catalog)
            projected[0].update(changes)
            with self.assertRaises(ValueError):
                projection.restore_catalog(projected)

    def test_credential_named_arbitrary_module_payload_is_rejected(self):
        receipt, report = self.setup_integration()
        receipt["modules_before"]["modules"]["AWS_SECRET_ACCESS_KEY"] = "synthetic-secret-scalar"
        receipt["modules_before"]["sha256"] = projection.digest(receipt["modules_before"]["modules"])
        report.write_text(json.dumps(receipt))
        with self.assertRaises(ValueError):
            projection.Projection(self.raw).collect()


if __name__ == "__main__":
    unittest.main(verbosity=2)
