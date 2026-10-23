#!/usr/bin/env python3
"""Portable checks of diagnostic parsing boundaries, not native package support."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("observer", Path(__file__).with_name("observe-xcode-local-package.py"))
OBS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OBS)


class ObservationParsing(unittest.TestCase):
    def preserve_native_process(self, root, name):
        destination = os.environ.get("CARTOGRAPH_OBSERVATION_PROCESS_EVIDENCE")
        if not destination:
            return
        output = Path(destination)
        self.assertTrue(output.is_absolute())
        self.assertFalse(output.resolve().is_relative_to(OBS.ROOT.resolve()))
        output.mkdir(exist_ok=True)
        for suffix in (".json", ".stdout", ".stderr"):
            source = root / (name + suffix)
            if source.is_file():
                data = OBS.SCOPE.bounded(source, 16 * 1024)
                with (output / (name + suffix)).open("xb") as target:
                    target.write(data)

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
                # 기존 supervisor 회귀와 같이 TERM을 무시해 실제 KILL 경로를 검사한다.
                name = "kill-" + stream
                code = ("import os,signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                        f"try: os.write({descriptor}, b'x'*32768)\n"
                        "except BrokenPipeError: pass\n"
                        "time.sleep(120)\n")
                try:
                    with self.assertRaises(RuntimeError):
                        OBS.run([sys.executable, "-c", code], root, root, name, 30, 2048)
                finally:
                    self.preserve_native_process(root, name)
                receipt = json.loads((root / (name + ".json")).read_text())
                self.assertEqual(receipt["output_limit_exceeded"], stream)
                self.assertFalse(receipt["timed_out"])
                self.assertEqual(receipt["raw_returncode"], -signal.SIGKILL)
                self.assertTrue(receipt["owned_root_reaped"])
                self.assertFalse(receipt["ownership_lost"])
                self.assertEqual(receipt["cleanup_errors"], [])
                self.assertLess(receipt["wall_seconds"], 20)
                for channel in ("stdout", "stderr"):
                    self.assertLessEqual((root / (name + "." + channel)).stat().st_size, 1024)
            normal = [sys.executable, "-c", "import os;os.write(1,b'out');os.write(2,b'err')"]
            try:
                self.assertEqual(OBS.run(normal, root, root, "normal", 30, 2048), b"out")
            finally:
                self.preserve_native_process(root, "normal")

    @unittest.skipUnless(os.name == "posix", "Owned process-group runtime checks require POSIX")
    def test_cooperative_overflow_still_refuses_and_preserves_cleanup_uncertainty(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve())
            for stream, descriptor in (("stdout", 1), ("stderr", 2)):
                name = "cooperative-" + stream
                command = [sys.executable, "-c", f"import os,time;os.write({descriptor}, b'x'*32768);time.sleep(120)"]
                try:
                    with self.assertRaises(RuntimeError):
                        OBS.run(command, root, root, name, 30, 2048)
                finally:
                    self.preserve_native_process(root, name)
                receipt = json.loads((root / (name + ".json")).read_text())
                self.assertEqual(receipt["output_limit_exceeded"], stream)
                self.assertFalse(receipt["timed_out"])
                self.assertTrue(receipt["owned_root_reaped"])
                self.assertFalse(receipt["ownership_lost"])
                # Darwin의 TERM 후 KILL 거부는 정리 성공으로 바꾸지 않는다.
                # 이 경우도 run()은 실패해야 하며 원래 receipt를 보존한다.
                errors = receipt["cleanup_errors"]
                if errors:
                    self.assertEqual(sys.platform, "darwin")
                    self.assertEqual(errors, [f"signal-{signal.SIGKILL}:PermissionError"])
                self.assertLess(receipt["wall_seconds"], 20)
                for channel in ("stdout", "stderr"):
                    self.assertLessEqual((root / (name + "." + channel)).stat().st_size, 1024)

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

    def test_link_map_column_headers_do_not_end_symbol_sections(self):
        # Apple ld64 OutputFile.cpp는 각 심볼 구역 뒤에 열 제목을 출력한다.
        value = OBS.link_map('''# Object files:
[ 0] linker synthesized
[ 1] /build/Math.o
# Sections:
# Address\tSize\tSegment\tSection
0x1000 0x10 __TEXT __text
# Symbols:
# Address\tSize    \tFile  Name
0x1000 0x10 [ 1] _packageValue
# Dead Stripped Symbols:
# Address\tSize    \tFile  Name
<<dead>> 0x10 [ 1] _unused
''')
        self.assertEqual(value["liveSymbolCountByOwner"], {"1": 1})
        self.assertEqual(value["deadSymbolCountByOwner"], {"1": 1})
        self.assertEqual(value["unparsedSymbolRows"], 0)
        self.assertIn("# Address\tSize    \tFile  Name", value["headers"])
        unknown = OBS.link_map("# Symbols:\n# Address Size File Name\nunrecognized row\n")
        self.assertEqual(unknown["unparsedSymbolRows"], 1)
        self.assertEqual(unknown["liveSymbolCountByOwner"], {})

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
