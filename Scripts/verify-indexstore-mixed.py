#!/usr/bin/env python3
"""혼합 iOS 실행기의 준비 계약과 독립 소스/어댑터 회귀를 검증한다."""

from __future__ import annotations

import importlib.util
import json
import hashlib
import zipfile
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation"
SPEC = importlib.util.spec_from_file_location("mixed_driver", Path(__file__).with_name("benchmark-indexstore-mixed.py"))
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)
EVIDENCE_SPEC = importlib.util.spec_from_file_location(
    "pilot_evidence", Path(__file__).with_name("verify-indexstore-pilot-evidence.py")
)
EVIDENCE = importlib.util.module_from_spec(EVIDENCE_SPEC)
EVIDENCE_SPEC.loader.exec_module(EVIDENCE)


class SetupContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / "binary"
        self.binary.write_bytes(b"verification-only bytes; never executable")
        sha = DRIVER.hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.setup = {
            "status": "passed",
            "revision": DRIVER.REVISION,
            "comparator_setup": {"binary": str(self.binary), "binary_sha256": sha, "checkout": str(self.root)},
            "cartograph": {"binary": str(self.binary), "binary_sha256": sha},
            "toolchain": {"library": str(self.binary), "library_sha256": sha},
        }
        self.path = self.root / "setup.json"
        self.save()

    def save(self):
        self.path.write_text(json.dumps(self.setup))

    def test_hook_reuses_exact_binary_and_explicit_complete_projection(self):
        hook = DRIVER.build_hook(self.path)
        self.assertEqual(hook[hook.index("--cartograph-graph-mode") + 1], "include-self-loops")
        self.assertEqual(hook[hook.index("--cli-build-evidence") + 1], str(self.path))
        self.assertNotIn("--baseline-only", hook)

    def test_failed_diagnostic_or_wrong_pin_setup_cannot_be_promoted(self):
        for key, value in [("status", "failed"), ("status", "baseline_only"), ("revision", "0" * 40)]:
            original = self.setup[key]
            self.setup[key] = value
            self.save()
            with self.assertRaises(ValueError):
                DRIVER.build_hook(self.path)
            self.setup[key] = original

    def test_replaced_bytes_fail_before_subprocess(self):
        self.binary.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            DRIVER.build_hook(self.path)

    def test_nonempty_output_is_preserved(self):
        output = self.root / "output"
        output.mkdir()
        (output / "results.json").write_text("original")
        with mock.patch.object(sys, "argv", ["driver", "--setup-results", str(self.path), "--output", str(output)]):
            with self.assertRaises(SystemExit) as error:
                DRIVER.main()
        self.assertEqual(error.exception.code, 2)
        self.assertEqual((output / "results.json").read_text(), "original")


class EvidenceBundleContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, extra=None, path="runs/sample.stdout", size_delta=0):
        data = b"source-independent retained observation\n"
        manifest = {
            "files": [
                {"path": path, "normalized_bytes": len(data), "normalized_sha256": hashlib.sha256(data).hexdigest()}
            ]
        }
        archive = self.root / "run-test-normalized.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr(path, data)
            output.writestr("manifest.json", json.dumps(manifest))
            if extra:
                output.writestr(*extra)
        with zipfile.ZipFile(archive) as source:
            count, size = len(source.infolist()), sum(entry.file_size for entry in source.infolist())
        bundle = {
            "archive": archive.name,
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            "compressed_bytes": archive.stat().st_size,
            "uncompressed_bytes": size + size_delta,
            "archive_entries": count,
            "verified_normalized_files": 1,
            "manifests": ["manifest.json"],
        }
        (self.root / "bundles.json").write_text(
            json.dumps(
                {
                    "bundles": [bundle],
                    "total_compressed_bytes": archive.stat().st_size,
                    "total_uncompressed_bytes": size,
                }
            )
        )
        return archive

    def test_complete_bounded_bundle_passes_without_extracting(self):
        self.fixture()
        self.assertEqual(EVIDENCE.verify(self.root)["normalized_files"], 1)
        self.assertFalse((self.root / "runs").exists())

    def test_archive_bytes_and_dimensions_cannot_change(self):
        archive = self.fixture()
        archive.write_bytes(archive.read_bytes() + b"extra")
        with self.assertRaisesRegex(ValueError, "Archive bytes"):
            EVIDENCE.verify(self.root)
        self.fixture(size_delta=1)
        with self.assertRaisesRegex(ValueError, "dimensions"):
            EVIDENCE.verify(self.root)

    def test_unmanifested_or_binary_member_is_rejected(self):
        self.fixture(extra=("unrelated.stdout", "extra"))
        with self.assertRaisesRegex(ValueError, "unmanifested"):
            EVIDENCE.verify(self.root)
        self.fixture(extra=("binary", b"\xff\x00"))
        with self.assertRaises(UnicodeDecodeError):
            EVIDENCE.verify(self.root)

    def test_unsafe_member_and_declared_size_limit_are_rejected(self):
        self.fixture(path="../escaped.stdout")
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            EVIDENCE.verify(self.root)
        self.fixture()
        with mock.patch.object(EVIDENCE, "MAX_UNCOMPRESSED", 1):
            with self.assertRaisesRegex(ValueError, "bounds"):
                EVIDENCE.verify(self.root)


def main() -> int:
    suite = unittest.TestSuite(
        unittest.defaultTestLoader.loadTestsFromTestCase(case) for case in (SetupContracts, EvidenceBundleContracts)
    )
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        return 1
    for command in [
        [sys.executable, "-m", "unittest", "discover", "-s", str(FIXTURE), "-p", "test_runner_contracts.py"],
        [sys.executable, "-m", "unittest", "discover", "-s", str(FIXTURE / "adapter/tests")],
    ]:
        subprocess.run(command, cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="cartograph-mixed-offline-") as temporary:
        out = Path(temporary)
        subprocess.run(
            [sys.executable, str(FIXTURE / "verify_offline.py"), "--output", str(out / "offline")], check=True
        )
        subprocess.run(
            [
                sys.executable,
                str(FIXTURE / "adapter/verify_source_catalog.py"),
                "--fixture-root",
                str(FIXTURE),
                "--output",
                str(out / "catalog.json"),
            ],
            check=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
