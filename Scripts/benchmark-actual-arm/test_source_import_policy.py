"""제어기·게시기의 실제 초기 import는 그럴듯한 캐시나 로컬 우회 경로를 실행하지 않는다."""

import os
import importlib.machinery
import types
from unittest import mock
import source_import_policy as policy
from pathlib import Path
import py_compile
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class SourceImportPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        shutil.copytree(ROOT, self.source, ignore=shutil.ignore_patterns("__pycache__"))

    def invoke(self, script):
        return subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(self.source / script), "--help"], capture_output=True, timeout=15
        )

    def cache_substitute(self, name):
        path = self.source / name
        original = path.read_bytes()
        metadata = path.stat()
        bad = b"raise SystemExit(93)\n"
        bad += b"#" * (len(original) - len(bad) - 1) + b"\n"
        path.write_bytes(bad)
        os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        cache = path.parent / "__pycache__" / (path.stem + "." + sys.implementation.cache_tag + ".pyc")
        py_compile.compile(str(path), cfile=str(cache), doraise=True)
        path.write_bytes(original)
        os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))

    def test_actual_controller_ignores_valid_looking_local_bytecode(self):
        self.cache_substitute("attempt_receipts.py")
        result = self.invoke("correctness_controller.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"--scratch-root", result.stdout)

    def test_actual_publisher_ignores_valid_looking_controller_bytecode(self):
        self.cache_substitute("correctness_controller.py")
        result = self.invoke("publish_correctness.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"--scratch-root", result.stdout)

    def test_unbound_initial_local_source_refuses_before_body(self):
        with (self.source / "attempt_receipts.py").open("a") as stream:
            stream.write("\nimport unexpected_side_input\n")
        (self.source / "unexpected_side_input.py").write_text("raise SystemExit(93)\n")
        result = self.invoke("correctness_controller.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.returncode, 93)
        self.assertIn(b"Unbound initial local source", result.stderr)

    def test_local_alias_cannot_load_unbound_outside_source(self):
        with (self.source / "attempt_receipts.py").open("a") as stream:
            stream.write("\nimport unexpected_side_input\n")
        outside = self.root / "outside.py"
        outside.write_text("raise SystemExit(93)\n")
        (self.source / "unexpected_side_input.py").symlink_to(outside)
        result = self.invoke("correctness_controller.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.returncode, 93)
        self.assertIn(b"Unbound initial local source", result.stderr)

    def test_local_extension_create_and_exec_refuse_before_native_loader(self):
        self.check_extension(self.source / "unexpected.so", blocked=True)

    def test_lexical_extension_alias_refuses_before_native_loader(self):
        outside = self.root / "outside.so"
        outside.write_bytes(b"not-a-native-binary")
        local = self.source / "unexpected.so"
        local.symlink_to(outside)
        self.check_extension(local, blocked=True)

    def test_outside_native_origin_keeps_original_loader_policy(self):
        self.check_extension(self.root / "outside.so", blocked=False)

    def check_extension(self, path, blocked):
        if not path.exists():
            path.write_bytes(b"not-a-native-binary")
        loader = importlib.machinery.ExtensionFileLoader("synthetic", str(path))
        spec = importlib.machinery.ModuleSpec("synthetic", loader)
        for method, argument in [("create_module", spec), ("exec_module", types.ModuleType("synthetic"))]:
            with self.subTest(method=method), mock.patch.object(
                importlib.machinery.ExtensionFileLoader, method, return_value=None
            ) as original:
                with policy.guarded_imports(self.source):
                    if blocked:
                        with self.assertRaises(ValueError):
                            getattr(loader, method)(argument)
                    else:
                        getattr(loader, method)(argument)
                self.assertEqual(original.call_count, 0 if blocked else 1)


if __name__ == "__main__":
    unittest.main()
