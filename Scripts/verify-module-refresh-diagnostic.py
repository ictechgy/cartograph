#!/usr/bin/env python3
"""모듈 재인덱싱 진단의 독립 출력 판정과 전용 캐시 경계를 검증한다."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "diagnostic", Path(__file__).with_name("diagnose-indexstore-module-refresh.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DiagnosticContracts(unittest.TestCase):
    def test_reviewed_local_evidence_archives(self):
        path = Path(__file__).with_name("verify-indexstore-pilot-evidence.py")
        spec = importlib.util.spec_from_file_location("evidence", path)
        evidence = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(evidence)
        result = evidence.verify(module.ROOT / "docs/evaluation/module-refresh-evidence/2026-10-12")
        self.assertEqual(result["archives"], 3)
        self.assertIsNone(result["superiority_claim"])

    def test_elf_and_macho_relocations_are_not_symbol_declarations(self):
        self.assertEqual(module.object_targets("a: R_X86_64_PLT32 alternate-0x4"), {"alternate"})
        self.assertEqual(module.object_targets("ARM64_RELOC_BRANCH26 _base"), {"base"})
        self.assertEqual(module.object_targets("000 <alternate>:\n R_X86_64_PLT32 database-0x4"), set())

    def test_ir_calls_are_not_declarations_or_substring_names(self):
        text = "declare i32 @base(i32)\n%v = call i32 @alternate(i32 %x)\n%w = call i32 @database(i32 0)"
        self.assertEqual(module.classify_ir(text), {"alternate"})
        self.assertEqual(module.classify_ir("call i32 @base(i32 0)\ncall i32 @alternate(i32 0)"), {"base", "alternate"})

    def test_refresh_preserves_every_owned_byte(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "cache"
            source.mkdir()
            (source / "module.pcm").write_bytes(b"private binary\x00")
            result = module.move_owned_tree(source, root / "retained", root)
            self.assertEqual(list(source.iterdir()), [])
            self.assertEqual((root / "retained/module.pcm").read_bytes(), b"private binary\x00")
            self.assertEqual(result["retained_sha256"], module.manifest(root / "retained"))
            self.assertGreaterEqual(result["wall_seconds"], 0)

    def test_refresh_rejects_alias_outside_workspace_and_existing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            workspace, outside = root / "private", root / "outside"
            workspace.mkdir()
            outside.mkdir()
            alias = workspace / "alias"
            alias.symlink_to(outside, target_is_directory=True)
            for source, retained in [(alias, workspace / "retained"), (outside, workspace / "retained")]:
                with self.subTest(source=source), self.assertRaises(ValueError):
                    module.move_owned_tree(source, retained, workspace)
            owned = workspace / "owned"
            owned.mkdir()
            existing = workspace / "retained"
            existing.mkdir()
            with self.assertRaises(ValueError):
                module.move_owned_tree(owned, existing, workspace)

    def test_compiler_invocation_preserves_driver_alias(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output, workspace = root / "output", root / "private"
            workspace.mkdir()
            driver = root / "swift-driver"
            driver.write_bytes(b"synthetic tool bytes")
            swiftc = root / "swiftc"
            swiftc.symlink_to(driver)
            library, cli, objdump = [root / name for name in ["library", "index-dump", "objdump"]]
            for path in (library, cli, objdump):
                path.write_bytes(b"synthetic tool bytes")
            setup = {
                "toolchain": {"swiftc": str(swiftc), "library": str(library), "library_sha256": module.digest(library)},
                "comparator_setup": {"binary": str(cli), "checkout": str(root)},
            }
            with patch.object(module.observe_mixed, "verify_cli", return_value={}), patch.object(
                module.Diagnostic, "capture", return_value=""
            ) as capture:
                diagnostic = module.Diagnostic(setup, root / "setup.json", output, workspace, "", objdump)
            self.assertEqual(diagnostic.swiftc, swiftc)
            self.assertEqual(capture.call_args_list[0].args[0][0], swiftc)


if __name__ == "__main__":
    unittest.main()
