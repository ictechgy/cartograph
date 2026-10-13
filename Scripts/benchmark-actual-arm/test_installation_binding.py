"""설치 단계와 현재 런타임의 연결에서 추정·재설치·조용한 입력 교체를 거부한다."""

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import installation_binding as binding


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repository = self.root / "repository"
        self.output = self.root / "measurement"
        self.target = self.root / "measurement-helper-dependencies"
        self.output.mkdir()
        (self.output / "setup").mkdir()
        (self.output / "private-setup").mkdir()
        for name in binding.HELPER_PATHS:
            path = self.repository / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"psutil==7.2.2\n" if name.endswith("requirements.txt") else name.encode())
        (self.target / "psutil").mkdir(parents=True)
        (self.target / "psutil/__init__.py").write_text('__version__ = "7.2.2"\n')
        dist = self.target / "psutil-7.2.2.dist-info"
        dist.mkdir()
        (dist / "METADATA").write_text("Metadata-Version: 2.4\nName: psutil\nVersion: 7.2.2\n")
        (dist / "RECORD").write_text("synthetic control, not an official installation\n")
        raw = b'{"private":"synthetic-contact-must-stay-private"}'
        (self.output / "private-setup/install-report.json").write_bytes(raw)
        self.projection = dict(
            schema_version=1,
            source_format="pip-install-report-v1",
            report_version="1",
            pip_version="26.2.1",
            raw_report=dict(
                bytes=len(raw),
                sha256=hashlib.sha256(raw).hexdigest(),
                private_relative_path="private-setup/install-report.json",
                publication="Original kept private",
            ),
            distributions=[
                dict(
                    name="psutil",
                    version="7.2.2",
                    requested=True,
                    is_direct=False,
                    is_yanked=False,
                    sha256="a" * 64,
                    url="https://files.pythonhosted.org/packages/aa/bb/"
                    + "c" * 60
                    + "/psutil-7.2.2-cp36-abi3-macosx_11_0_arm64.whl",
                )
            ],
            omitted_metadata=binding.OMISSIONS,
        )
        argv = [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--index-url",
            "https://pypi.org/simple",
            "--no-input",
            "--disable-pip-version-check",
            "--no-cache-dir",
            "--only-binary=:all:",
            "--target",
            str(self.target),
            "--report",
            str(self.output / "private-setup/install-report.json"),
            "-r",
            str(self.repository / "Scripts/benchmark-measurement/requirements.txt"),
        ]
        self.install = dict(
            command=argv,
            cwd=str(self.repository),
            completed=True,
            passed=True,
            returncode=0,
            observed_returncode=0,
            failure=None,
            cleanup_root_unfinished=False,
            cleanup_signals=[],
            wall_seconds=2.0,
        )
        self.results = dict(
            status="completed-synthetic-native-validation",
            final_comparison=False,
            phases={name: self.install.copy() for name in ("install", "tests", "machine", "calibration")},
            helper_hashes={
                name: hashlib.sha256((self.repository / name).read_bytes()).hexdigest() for name in binding.HELPER_PATHS
            },
            install_provenance=self.projection,
            install_provenance_wall_seconds=0.25,
            diagnostic_wall_seconds=12.0,
        )
        self.write()

    def write(self):
        for path, value in [
            ("results.json", self.results),
            ("setup/install.json", self.install),
            ("setup/install-provenance.json", self.projection),
        ]:
            (self.output / path).write_text(json.dumps(value))

    def bind(self):
        return binding.bind(
            self.output / "results.json", self.repository, Path(sys.executable), require_prospective=False
        )

    def test_original_receipts_link_to_current_inventory_without_install(self):
        result = self.bind()
        self.assertEqual(result["status"], "bound-for-validation")
        self.assertEqual(result["package"]["version"], "7.2.2")
        self.assertEqual(result["prior_cost_references"]["install_wall_seconds"], 2)
        self.assertEqual(result["prior_cost_references"]["whole_helper_diagnostic_wall_seconds"], 12)
        self.assertNotIn("synthetic-contact-must-stay-private", json.dumps(result))
        self.assertIn("Not captured", result["historical_interpreter_content"])

    def test_duplicate_install_receipts_must_agree(self):
        self.results["phases"]["install"] = {**self.install, "wall_seconds": 9}
        self.write()
        with self.assertRaises(ValueError):
            self.bind()

    def test_extra_install_flags_are_rejected(self):
        self.install["command"].append("--extra-index-url")
        self.write()
        with self.assertRaises(ValueError):
            self.bind()

    def test_missing_binary_only_requirement_is_rejected(self):
        self.install["command"][9] = "--prefer-binary"
        self.write()
        with self.assertRaises(ValueError):
            self.bind()

    def test_incomplete_install_cannot_be_reused(self):
        self.install["returncode"] = 125
        self.results["phases"]["install"] = self.install
        self.write()
        with self.assertRaises(ValueError):
            self.bind()

    def test_projection_change_is_rejected(self):
        self.projection["distributions"][0]["version"] = "7.2.1"
        self.write()
        with self.assertRaises(ValueError):
            self.bind()

    def test_original_private_report_mutation_is_rejected(self):
        (self.output / "private-setup/install-report.json").write_text("changed")
        with self.assertRaises(ValueError):
            self.bind()

    def test_requirement_source_mutation_is_rejected(self):
        (self.repository / "Scripts/benchmark-measurement/requirements.txt").write_text("psutil==7.2.1\n")
        with self.assertRaises(ValueError):
            self.bind()

    def test_alias_target_is_not_silently_accepted(self):
        alias = self.root / "alias"
        alias.symlink_to(self.target, target_is_directory=True)
        self.install["command"][11] = str(alias)
        self.write()
        with self.assertRaises(ValueError):
            self.bind()

    def test_unexpected_installed_package_is_rejected(self):
        (self.target / "another.py").write_text("pass")
        with self.assertRaises(ValueError):
            self.bind()

    def test_duplicate_json_fields_are_rejected(self):
        p = self.output / "results.json"
        p.write_text('{"status":"failed",' + p.read_text()[1:])
        with self.assertRaises(ValueError):
            self.bind()

    def test_symlink_receipt_is_not_read(self):
        p = self.output / "results.json"
        saved = p.with_name("saved.json")
        p.rename(saved)
        p.symlink_to(saved)
        with self.assertRaises(ValueError):
            self.bind()

    def test_prior_input_mutation_during_inventory_is_rejected(self):
        original = binding.runtime.package_snapshot

        def change(*args):
            result = original(*args)
            (self.output / "setup/install.json").write_text("changed after first read")
            return result

        with mock.patch.object(binding.runtime, "package_snapshot", side_effect=change):
            with self.assertRaises(ValueError):
                self.bind()

    def add_prospective_receipt(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "prospective_installer", Path(__file__).with_name("installer-successor.py")
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        before = module.interpreter_observation(sys.executable)
        after = module.interpreter_observation(sys.executable)
        self.results["install_interpreter"] = dict(
            schema_version=1,
            status="matched",
            before=before,
            after=after,
            cost_accounting="Capture costs are nested in diagnostic wall, outside command-only install wall",
            scope="Prospective selected interpreter identity only; no dynamic-loader or wheel equivalence proof",
        )
        (self.output / "setup/install-interpreter.json").write_text(json.dumps(self.results["install_interpreter"]))
        self.write()

    def prospective_bind(self):
        return binding.bind(self.output / "results.json", self.repository, Path(sys.executable))

    def test_real_integration_requires_prospective_receipt_by_default(self):
        with self.assertRaisesRegex(ValueError, "Prospective"):
            self.prospective_bind()

    def test_prospective_receipt_binds_current_bytes_and_historical_cost(self):
        self.add_prospective_receipt()
        result = self.prospective_bind()
        self.assertEqual(result["install_interpreter"]["status"], "matched")
        self.assertEqual(result["prior_cost_references"]["whole_helper_diagnostic_wall_seconds"], 12)
        self.assertIn("setup/install-interpreter.json", result["inputs"]["interpreter"]["path"])

    def test_prospective_duplicate_receipt_disagreement_is_refused(self):
        self.add_prospective_receipt()
        self.results["install_interpreter"]["before"]["wall_seconds"] += 1
        self.write()
        with self.assertRaises(ValueError):
            self.prospective_bind()

    def test_prospective_changed_or_incomplete_identity_cannot_be_upgraded(self):
        for status in ["changed", "incomplete", "unavailable", "pending"]:
            self.add_prospective_receipt()
            row = self.results["install_interpreter"]
            row["status"] = status
            (self.output / "setup/install-interpreter.json").write_text(json.dumps(row))
            self.write()
            with self.assertRaises(ValueError):
                self.prospective_bind()

    def test_prospective_wrong_bytes_path_or_metadata_are_refused(self):
        for key, value in [
            ("sha256", "f" * 64),
            ("resolved_path", str(self.root / "other")),
            ("bytes", 123),
            ("file_identity", [1] * 6),
        ]:
            self.add_prospective_receipt()
            row = self.results["install_interpreter"]
            for when in ["before", "after"]:
                row[when][key] = value
            (self.output / "setup/install-interpreter.json").write_text(json.dumps(row))
            self.write()
            with self.assertRaises(ValueError):
                self.prospective_bind()


if __name__ == "__main__":
    unittest.main(verbosity=2)
