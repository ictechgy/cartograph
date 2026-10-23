#!/usr/bin/env python3
"""Portable checks of diagnostic parsing boundaries, not native package support."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("observer", Path(__file__).with_name("observe-xcode-local-package.py"))
OBS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OBS)


class ObservationParsing(unittest.TestCase):
    def test_combined_budget_and_cleanup_receipt_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve())
            receipts = []

            def supervised(argv, cwd, stem, timeout, *, stream_limit):
                self.assertEqual(stream_limit, 32)
                paths = {stream: str(stem) + "." + stream for stream in ("stdout", "stderr")}
                Path(paths["stdout"]).write_bytes(b"result")
                Path(paths["stderr"]).write_bytes(b"diagnostic")
                receipt = dict(returncode=0, timed_out=False, owned_root_reaped=True, ownership_lost=False,
                               cleanup_errors=[], output_limit_exceeded=None, stream_limit_bytes=stream_limit,
                               retained_stream_bytes={"stdout": 6, "stderr": 10}, **paths)
                receipt.update(receipts.pop(0))
                return receipt

            with patch.object(OBS, "process_supervisor", return_value=SimpleNamespace(run=supervised)):
                receipts.append({})
                self.assertEqual(OBS.run(["synthetic"], root, root, "good", 5, 64), b"result")
                bad = [{"ownership_lost": True}, {"owned_root_reaped": False}, {"cleanup_errors": ["unresolved"]},
                       {"timed_out": True}, {"output_limit_exceeded": "stderr"}, {"exception_type": "OSError"},
                       {"retained_stream_bytes": {"stdout": 5, "stderr": 10}}, {"stream_limit_bytes": 64}]
                for index, change in enumerate(bad):
                    receipts.append(change)
                    with self.assertRaises(OBS.SCOPE.CaptureError):
                        OBS.run(["synthetic"], root, root, f"bad-{index}", 5, 64)
                with self.assertRaises(OBS.SCOPE.CaptureError):
                    OBS.run(["synthetic"], root, root, "good", 5, 64)
                for maximum in (True, 0, 1, 63):
                    with self.assertRaises(OBS.SCOPE.CaptureError):
                        OBS.run(["synthetic"], root, root, "invalid", 5, maximum)

    @unittest.skipUnless(os.name == "posix", "Owned process-group runtime checks require POSIX")
    def test_live_stdout_and_stderr_overflow_stop_and_reap_owned_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve())
            for stream, descriptor in (("stdout", 1), ("stderr", 2)):
                command = [sys.executable, "-c", f"import os,time;os.write({descriptor}, b'x'*32768);time.sleep(120)"]
                with self.assertRaises(RuntimeError):
                    OBS.run(command, root, root, stream, 30, 2048)
                receipt = json.loads((root / (stream + ".json")).read_text())
                self.assertEqual(receipt["output_limit_exceeded"], stream)
                self.assertFalse(receipt["timed_out"])
                self.assertTrue(receipt["owned_root_reaped"])
                self.assertFalse(receipt["ownership_lost"])
                self.assertEqual(receipt["cleanup_errors"], [])
                self.assertLess(receipt["wall_seconds"], 20)
                for channel in ("stdout", "stderr"):
                    self.assertLessEqual((root / (stream + "." + channel)).stat().st_size, 1024)
            normal = [sys.executable, "-c", "import os;os.write(1,b'out');os.write(2,b'err')"]
            self.assertEqual(OBS.run(normal, root, root, "normal", 30, 2048), b"out")

    def test_compiler_and_linker_operands_are_observed_separately(self):
        log = '''    /tool/swiftc -module-name ArithmeticCore -output-file-map "/build/map.json" @/build/ArithmeticCore.SwiftFileList
    /tool/clang -filelist /build/Core.LinkFileList -Xlinker -map -Xlinker /build/Core.map -o /build/CoreKit
'''
        rows = OBS.commands(log)
        self.assertEqual(len(rows), 2)
        self.assertEqual(OBS.operand(rows[0], "-module-name"), "ArithmeticCore")
        self.assertEqual(OBS.operand(rows[1], "-map"), "/build/Core.map")
        self.assertIsNone(OBS.operand(rows[1], "-module-name"))

    def test_ambiguous_or_missing_operands_are_not_invented(self):
        self.assertIsNone(OBS.operand(["clang", "-o", "one", "-o", "two"], "-o"))
        self.assertIsNone(OBS.operand(["clang", "-map", "-Xlinker"], "-map"))
        with self.assertRaises(OBS.SCOPE.CaptureError):
            OBS.commands('/tool/swiftc -output-file-map "unterminated')

    def test_object_presence_live_and_dead_are_distinct(self):
        value = OBS.link_map('''# Object files:
[ 0] linker synthesized
[ 1] /build/ArithmeticCore.o
[ 2] /build/Core.o
# Symbols:
0x1000 0x10 [ 2] _core
# Dead Stripped Symbols:
<<dead>> 0x10 [ 1] _package
''')
        self.assertIn("1", value["objectFiles"])
        self.assertNotIn("1", value["liveSymbolCountByOwner"])
        self.assertEqual(value["deadSymbolCountByOwner"], {"1": 1})
        self.assertEqual(value["liveSymbolCountByOwner"], {"2": 1})
        with self.assertRaises(OBS.SCOPE.CaptureError):
            OBS.link_map("# Object files:\n[ 1] /a.o\n[ 1] /b.o\n")
        unknown = OBS.link_map("# Symbols:\n0x1000 0x10 [ 9] _unknown\n")
        self.assertEqual(unknown["unresolvedOwnerIndices"], ["9"])

    def test_outside_and_relative_observed_paths_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve())
            self.assertEqual(OBS.checked(root / "inside.o", [root]), root / "inside.o")
            for path in (root / "../outside.o", "relative.o"):
                with self.assertRaises(OBS.SCOPE.CaptureError):
                    OBS.checked(path, [root])

    def test_same_path_byte_change_is_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve())
            source = root / "Map.json"
            source.write_text("{}")
            original = source.stat()
            observed = OBS.ObservedFiles(root, root)
            observed.read(source)
            source.write_text('{"changed":true}')
            os.utime(source, ns=(original.st_atime_ns, original.st_mtime_ns))
            with self.assertRaises(OBS.SCOPE.CaptureError):
                observed.read(source)


if __name__ == "__main__":
    unittest.main()
