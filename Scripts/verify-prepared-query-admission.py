#!/usr/bin/env python3
"""Query admission mapping controls; no native execution or timing claim."""
import copy
from contextlib import nullcontext
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


with patch.dict(sys.modules, {"resource": types.ModuleType("resource")}) if os.name == "nt" else nullcontext():
    D = load("prepared_query", "diagnose-query-phases.py")
P = load("prepared_query_tools", "prepared-comparison-tools.py")


class QueryAdmissionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.out = self.root / "query"
        self.path = self.root / "baseline.json"
        self.admission_path = self.root / "admission.json"
        compiler = self.root / "swift-frontend"
        compiler.write_bytes(b"consumer compiler")
        self.value = {"toolchain": {"identity": {"tools_sha256": {"swift-frontend": P.digest(compiler)}},
                                   "paths": {"swift-frontend": str(compiler)}}, "tools": {}}
        for role in ("candidate", "baseline"):
            source = self.root / (role + "-source")
            source.mkdir()
            (source / "Package.swift").write_bytes(b"source bytes")
            artifact = self.root / role
            (artifact / "bin").mkdir(parents=True)
            binary = artifact / "bin/tool"
            binary.write_bytes(role.encode())
            src = {"revision": P.BASELINE if role == "baseline" else "a" * 40,
                   "input_sha256": {"Package.swift": P.digest(source / "Package.swift")}}
            manifest = {"files": {"bin/tool": {"sha256": P.digest(binary)}},
                        "build_evidence": {"version": "fixture", "setup": {"build": {
                            "command": ["/producer/swift", "build", "--package-path", "/producer/source"],
                            "wall_seconds": 19.0}}}, "producer": {"runner": "producer"}}
            P.save(artifact / "manifest.json", manifest)
            self.value["tools"][role] = {"manifest": str(artifact / "manifest.json"),
                "manifest_sha256": P.digest(artifact / "manifest.json"), "binary": str(binary),
                "binary_sha256": P.digest(binary), "source": src, "consumer_source": str(source)}
        P.save(self.admission_path, self.value)
        self.setup = {"status": "passed", "cartograph": P.prepared_product(self.value, "candidate")}
        self.setup["cartograph"]["setup"]["admission_path"] = str(self.admission_path)
        self.baseline = {"status": "admitted-preparation-only", "cartograph": P.prepared_product(self.value, "baseline"),
                         "toolchain_identity": self.value["toolchain"]["identity"], "admission": str(self.admission_path)}
        self.config = {"hashes": {}}
        self.module = types.SimpleNamespace(read_admission=lambda path: copy.deepcopy(self.value),
                                            prepared_product=P.prepared_product, read_json=P.read_json,
                                            verify_source_links=P.verify_source_links)

    def invoke(self):
        self.path.write_text(json.dumps(self.baseline))
        def verify(config):
            for path, expected in config["hashes"].items():
                if P.digest(path) != expected:
                    raise ValueError("Admitted file changed: " + path)
        with patch.object(D, "prepared_module", return_value=self.module), patch.object(D.PREP, "verify_bytes", side_effect=verify):
            return D.admit_baseline(self.path, P.BASELINE, self.setup, self.config, self.out)

    def test_consumer_mapping_keeps_producer_receipt_and_binds_real_bytes(self):
        before = copy.deepcopy(self.baseline)
        self.assertEqual(self.invoke(), before)
        self.assertEqual(self.baseline, before)
        self.assertIn(str(self.root / "baseline-source/Package.swift"), self.config["hashes"])
        self.assertIn(str(self.root / "swift-frontend"), self.config["hashes"])
        self.assertFalse(any(path.startswith("/producer") for path in self.config["hashes"]))

    def test_prepared_receipt_cannot_replace_actual_candidate_comparison(self):
        self.setup["status"] = "admitted-preparation-only"
        with self.assertRaisesRegex(ValueError, "Successful actual candidate"):
            self.invoke()
        self.assertFalse((self.out / "baseline-admission.json").exists())

    def test_mismatched_admission_or_rewritten_producer_receipt_is_rejected(self):
        original = copy.deepcopy(self.setup)
        self.setup["cartograph"]["setup"]["admission_path"] = str(self.root / "other.json")
        with self.assertRaisesRegex(ValueError, "consumer admission differs"):
            self.invoke()
        self.setup = original
        self.baseline["cartograph"]["setup"]["producer_evidence"]["setup"]["build"]["command"][3] = "/consumer/source"
        with self.assertRaisesRegex(ValueError, "product mapping differs"):
            self.invoke()

    def test_consumer_source_drift_refuses_baseline(self):
        (self.root / "baseline-source/Package.swift").write_bytes(b"changed after admission")
        with self.assertRaisesRegex(ValueError, "Admitted file changed"):
            self.invoke()
        self.assertFalse((self.out / "baseline-admission.json").exists())


if __name__ == "__main__":
    unittest.main()
