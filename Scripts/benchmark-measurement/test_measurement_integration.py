#!/usr/bin/env python3
"""고정된 실제 도우미 출력을 현재 공개 정규화기와 함께 검증한다."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import process_tree_measure as measurement
import machine_manifest as machine
import calibrate_observer as calibration

HERE = Path(__file__).resolve().parent


def load(name, path):
    """저장소의 현재 정규화기를 직접 읽어 오래된 사본의 우연한 통과를 막는다."""
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NORMALIZER = load("evidence", HERE.parent / "normalize-indexstore-evidence.py")
BUNDLES = load("bundles", HERE.parent / "normalize-indexstore-bundles.py")


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="measurement-integration-")
        self.root = Path(self.temporary.name)
        self.raw = self.root / "raw"
        (self.raw / "runs").mkdir(parents=True)
        (self.raw / "results.json").write_text('{"status":"synthetic_validation_only"}\n')
        self.args = argparse.Namespace(input=self.raw, output=self.root / "public", prefix=[
            f"WORKSPACE={HERE.parent.parent}", f"PYTHON={Path(sys.executable).parent}", f"TEST={self.root}",
        ])

    def tearDown(self):
        self.temporary.cleanup()

    def run_workload(self, stem, mode, *arguments, **options):
        command = [sys.executable, str(HERE / "synthetic_workload.py"), *map(str, arguments)]
        return measurement.run(command, HERE, self.raw / "runs" / stem, mode=mode, interval=0.005, **options)

    def test_imported_helper_hashes_match_reviewed_provenance(self):
        provenance = json.loads((HERE / "provenance.json").read_text())["files"]
        for name, entry in provenance.items():
            expected = entry.get("reviewed_successor_sha256", entry.get("frozen_sha256"))
            if expected is not None:
                self.assertEqual(measurement.file_sha256(HERE / name), expected, name)

    def test_real_machine_manifest_and_nested_observer_results_normalize(self):
        manifest_dir = self.raw / "setup" / "machine"
        manifest_dir.parent.mkdir()
        result = machine.collect(manifest_dir, "Synthetic test; other work uncontrolled",
                                 "Filesystem caches uncontrolled", "Linux synthetic validation only")
        # 네이티브 하드웨어 실행으로 오인하지 않도록 실제 합성 관찰 결과라고 이름 붙인다.
        timing = self.run_workload("synthetic-machine-query", "timing", "allocate", 1, 0.03)
        result["hardware_queries"]["synthetic_integration_only"] = timing
        result["toolchain_versions"]["synthetic_integration_only"] = {"measurement": timing}
        (manifest_dir / "machine-manifest.json").write_text(json.dumps(result))
        self.args.prefix.append("SYSTEM_ADMIN_BIN=/usr/sbin")
        NORMALIZER.package(self.args)
        public = json.loads((self.args.output / "setup/machine/machine-manifest.json").read_text())
        self.assertEqual(public, result)
        self.assertNotIn(result["helper_sha256"], NORMALIZER.KNOWN_MEASUREMENT_HELPERS)
        self.assertFalse(NORMALIZER.has_process_identity(public))

    def test_actual_tiny_calibration_preserves_nested_memory_receipts(self):
        with mock.patch.dict(calibration.WORKLOADS, {
            "synthetic_tiny_cpu": [sys.executable, str(HERE / "synthetic_workload.py"), "cpu", "2000"],
        }, clear=True):
            plan = copy.deepcopy(calibration.calibration_plan(2, 111, 222, 0.005))
        output = self.raw / "runs" / "calibration"
        summary = calibration.run_calibration(plan, output)
        self.assertTrue(summary["all_outputs_agree"])
        manifest = NORMALIZER.package(self.args)
        bindings = manifest["embedded_memory_result_bindings"]
        self.assertEqual(len(bindings), 2)
        for binding in bindings:
            private = json.loads((self.raw / binding["artifact"]).read_text())
            public = json.loads((self.args.output / binding["artifact"]).read_text())
            expected = copy.deepcopy(private)
            expected["no_observer"]["command"][:2] = [
                "$PYTHON/" + Path(sys.executable).name,
                "$WORKSPACE/Scripts/benchmark-measurement/synthetic_workload.py",
            ]
            self.assertEqual(public, expected)
            self.assertEqual(private["observed"]["measurement_mode"], "memory")
            self.assertTrue((self.args.output / binding["verified_standalone_result"]).is_file())
            standalone = json.loads((self.raw / binding["verified_standalone_result"]).read_text())
            returned = copy.deepcopy(private["observed"])
            self.assertGreaterEqual(returned.pop("caller_elapsed_seconds"), 0)
            self.assertEqual(returned, standalone)

    def test_real_memory_roundtrip_preserves_every_sample_and_artifact_hash(self):
        result = self.run_workload("memory", "memory", "allocate", 1, 0.08)
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(result["helper_sha256"], measurement.file_sha256(HERE / "process_tree_measure.py"))
        self.assertFalse(result["primary_timing_eligible"])
        before = {path.relative_to(self.raw): path.read_bytes() for path in self.raw.rglob("*") if path.is_file()}
        manifest = NORMALIZER.package(self.args)
        count = 0
        for chunk in result["rss"]["sample_chunks"]:
            relative = Path("runs") / chunk["name"]
            original = [json.loads(line) for line in before[relative].splitlines()]
            normalized = [json.loads(line) for line in (self.args.output / relative).read_bytes().splitlines()]
            count += len(original)
            for sample in original:
                for process in sample["processes"]:
                    del process["pid"], process["create_time"]
            self.assertEqual(normalized, original)
            self.assertFalse(NORMALIZER.has_process_identity(normalized))
        self.assertEqual(count, result["rss"]["sample_count"])
        for item in manifest["files"]:
            relative = Path(item["path"])
            self.assertEqual(item["original_raw_sha256"], NORMALIZER.digest(before[relative]))
            self.assertEqual(item["normalized_sha256"], NORMALIZER.digest((self.args.output / relative).read_bytes()))
            self.assertEqual((self.raw / relative).read_bytes(), before[relative])
        public_result = json.loads((self.args.output / "runs/memory.json").read_text())
        self.assertEqual(public_result["rss"], result["rss"])

    def test_private_environment_stays_out_of_evidence(self):
        secret = "synthetic-private-value-438195"
        command = [sys.executable, "-c", "import os; assert os.environ['MEASUREMENT_PRIVATE_SENTINEL']"]
        result = measurement.run(command, HERE, self.raw / "runs/private-env", mode="timing",
                                 environment={**os.environ, "MEASUREMENT_PRIVATE_SENTINEL": secret})
        self.assertEqual(result["status"], "ok", result)
        self.assertIsNone(result["rss"])
        self.assertFalse(list((self.raw / "runs").glob("*.samples*")))
        joined = b"\n".join(path.read_bytes() for path in self.raw.rglob("*") if path.is_file())
        self.assertNotIn(secret.encode(), joined)
        self.assertNotIn(b'"environment"', joined)
        NORMALIZER.package(self.args)
        public = json.loads((self.args.output / "runs/private-env.json").read_text())
        self.assertEqual(public["measurement_mode"], "timing")
        self.assertTrue(public["primary_timing_eligible"])
        self.assertFalse(public["sampling_during_timing"])
        self.assertFalse(public["periodic_tree_discovery_during_timing"])

    def test_real_timeout_failure_survives_normalization(self):
        result = self.run_workload("timeout", "memory", "orphan", self.root / "private-orphan.pid", 10, 10,
                                   timeout=0.5, grace=0.05)
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["cleanup"]["remaining_observed_pids"], [])
        NORMALIZER.package(self.args)
        public = json.loads((self.args.output / "runs/timeout.json").read_text())
        for key in ("status", "failure", "returncode", "timed_out", "wall_seconds", "rss"):
            self.assertEqual(public[key], result[key])
        self.assertEqual(public["cleanup"]["seconds"], result["cleanup"]["seconds"])
        self.assertEqual(public["cleanup"]["remaining_observed_process_count"], 0)
        self.assertFalse(public["cleanup"]["remaining_identity_unresolved"])
        self.assertFalse(NORMALIZER.has_process_identity(public))

    def test_blocked_chunk_bundle_never_publishes_partial_or_raw_fallback(self):
        self.run_workload("memory", "memory", "allocate", 1, 0.03)
        chunk = next((self.raw / "runs").glob("*.samples.*.jsonl"))
        chunk.write_text(chunk.read_text() + '{"pid":12345}\n')
        good = self.root / "good"
        good.mkdir()
        (good / "results.json").write_text('{"status":"synthetic_validation_only"}\n')
        args = argparse.Namespace(output=self.root / "bundles", github_output=None, prefix=self.args.prefix,
                                  synthetic=self.raw, argument_parser=good, mixed_setup=None, mixed_ios=None)
        result = BUNDLES.package(args)
        failed = next(item for item in result["bundles"] if item["name"] == "synthetic")
        self.assertEqual(failed["status"], "blocked")
        self.assertEqual(failed["diagnostic"]["reason"], "sample-chunk-integrity")
        self.assertIn("artifact_identifier_sha256", failed["diagnostic"])
        self.assertEqual(failed["raw_inventory"]["status"], "hashed")
        self.assertFalse((args.output / "synthetic").exists())
        self.assertTrue((args.output / "argument-parser/results.json").exists())
        self.assertFalse(result["raw_fallback"])
        self.assertFalse(result["complete_run_evidence"])
        self.assertFalse(list(self.root.glob(".indexstore-public-*")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
