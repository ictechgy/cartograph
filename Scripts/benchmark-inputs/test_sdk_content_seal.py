"""SDK 트리 봉인의 내용·경계·경쟁 상태 계약을 고정한다."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("sdk_seal", Path(__file__).with_name("sdk_content_seal.py"))
SEAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SEAL)


class SealContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.sdk = self.home / "sdk"
        self.sdk.mkdir()
        (self.sdk / "Header.h").write_text("int first(void);\n")
        self.roots = {"SDK": self.sdk}

    def test_complete_content_and_empty_directory_are_deterministic(self):
        (self.sdk / "empty").mkdir()
        first = SEAL.capture(self.roots)
        second = SEAL.capture(self.roots)
        self.assertEqual(first["content_sha256"], second["content_sha256"])
        self.assertEqual([e["path"] for e in first["entries"]], [".", "Header.h", "empty"])
        self.assertGreater(first["wall_seconds"], 0)
        self.assertEqual(first["files"], 1)
        self.assertEqual(first["bytes"], len("int first(void);\n"))

    def test_same_size_replacement_and_restoration_are_observed(self):
        first = SEAL.capture(self.roots)
        old = (self.sdk / "Header.h").read_bytes()
        (self.sdk / "Header.h").write_bytes(old.replace(b"first", b"other"))
        self.assertFalse(SEAL.verify(first, self.roots)["matches"])
        (self.sdk / "Header.h").write_bytes(old)
        self.assertTrue(SEAL.verify(first, self.roots)["matches"])

    def test_mtime_only_change_does_not_change_content_identity(self):
        first = SEAL.capture(self.roots)
        os.utime(self.sdk / "Header.h", (1, 1))
        self.assertTrue(SEAL.verify(first, self.roots)["matches"])

    def test_added_removed_and_renamed_files_change_identity(self):
        first = SEAL.capture(self.roots)
        path = self.sdk / "Added.h"
        path.write_text("new")
        self.assertFalse(SEAL.verify(first, self.roots)["matches"])
        path.unlink()
        self.assertTrue(SEAL.verify(first, self.roots)["matches"])
        (self.sdk / "Header.h").rename(self.sdk / "Moved.h")
        self.assertFalse(SEAL.verify(first, self.roots)["matches"])

    def test_internal_file_and_directory_links_are_bound_without_duplicate_bytes(self):
        (self.sdk / "Alias.h").symlink_to("Header.h")
        (self.sdk / "Directory").mkdir()
        (self.sdk / "DirAlias").symlink_to("Directory")
        result = SEAL.capture(self.roots)
        links = [e for e in result["entries"] if e["type"] == "symlink"]
        self.assertEqual(len(links), 2)
        self.assertEqual(result["files"], 1)
        self.assertEqual(links[0]["target"], {"root": "SDK", "path": "Header.h"})

    def test_explicit_other_root_link_is_covered_and_target_change_is_observed(self):
        resources = self.home / "resources"
        resources.mkdir()
        (resources / "module").write_text("a")
        (self.sdk / "Resource").symlink_to(resources / "module")
        roots = {"SDK": self.sdk, "RESOURCE": resources}
        first = SEAL.capture(roots)
        (resources / "module").write_text("b")
        self.assertFalse(SEAL.verify(first, roots)["matches"])

    def test_external_link_is_refused_without_reading_external_file(self):
        outside = self.home / "outside"
        outside.write_text("private synthetic content")
        (self.sdk / "Escape").symlink_to(outside)
        with mock.patch.object(SEAL, "hash_file", side_effect=AssertionError("must not hash before scope check")):
            with self.assertRaisesRegex(SEAL.SealError, "escaping-link"):
                SEAL.capture(self.roots)

    def test_broken_and_cyclic_links_fail_closed(self):
        link = self.sdk / "Link"
        for target in ["absent", "Link"]:
            with self.subTest(target=target):
                link.symlink_to(target)
                with self.assertRaises(SEAL.SealError):
                    SEAL.capture(self.roots)
                link.unlink()

    def test_root_alias_resolves_but_nested_or_duplicate_roots_are_refused(self):
        alias = self.home / "alias"
        alias.symlink_to(self.sdk, target_is_directory=True)
        self.assertEqual(SEAL.capture({"SDK": alias})["roots"]["SDK"], str(self.sdk.resolve()))
        (self.sdk / "Nested").mkdir()
        for roots in [{"SDK": self.sdk, "ALIAS": alias}, {"SDK": self.sdk, "NESTED": self.sdk / "Nested"}]:
            with self.assertRaisesRegex(SEAL.SealError, "overlapping-roots"):
                SEAL.capture(roots)

    def test_special_file_is_rejected_without_opening(self):
        os.mkfifo(self.sdk / "pipe")
        with self.assertRaisesRegex(SEAL.SealError, "unsupported-entry"):
            SEAL.capture(self.roots)

    def test_limits_fail_without_truncation(self):
        for limits in [dict(max_entries=1), dict(max_bytes=1)]:
            with self.assertRaisesRegex(SEAL.SealError, "limit"):
                SEAL.capture(self.roots, **limits)

    def test_mutation_during_hashing_is_refused(self):
        actual = SEAL.hash_file

        def mutate(path, expected):
            result = actual(path, expected)
            path.write_bytes(path.read_bytes().replace(b"first", b"other"))
            return result

        with mock.patch.object(SEAL, "hash_file", side_effect=mutate):
            with self.assertRaisesRegex(SEAL.SealError, "input-mutated"):
                SEAL.capture(self.roots)

    def test_unreadable_file_is_a_retained_failure(self):
        with mock.patch.object(SEAL.os, "open", side_effect=PermissionError("synthetic")):
            with self.assertRaisesRegex(SEAL.SealError, "unreadable-file"):
                SEAL.capture(self.roots)

    def test_tampered_expected_manifest_and_root_set_are_rejected(self):
        first = SEAL.capture(self.roots)
        damaged = json.loads(json.dumps(first))
        damaged["entries"][1]["sha256"] = "0" * 64
        with self.assertRaisesRegex(SEAL.SealError, "invalid-seal"):
            SEAL.verify(damaged, self.roots)
        with self.assertRaisesRegex(SEAL.SealError, "root-set-changed"):
            SEAL.verify(first, {"OTHER": self.sdk})

    def test_result_records_success_failure_cost_and_never_overwrites(self):
        output = self.home / "success"
        result = SEAL.record(self.roots, output)
        self.assertEqual(result["status"], "passed")
        self.assertGreater(result["wall_seconds"], 0)
        self.assertTrue((output / "seal.json").is_file())
        with self.assertRaisesRegex(SEAL.SealError, "existing-output"):
            SEAL.record(self.roots, output)
        failed = SEAL.record(self.roots, self.home / "failed", max_bytes=1)
        self.assertEqual(failed["status"], "failed")
        self.assertIn("limit", failed["failure"])
        self.assertGreater(failed["wall_seconds"], 0)
        self.assertFalse((self.home / "failed/seal.json").exists())

    def test_output_inside_input_and_input_inside_output_are_refused(self):
        for output in [self.sdk / "evidence", self.home]:
            with self.assertRaises(SEAL.SealError):
                SEAL.record(self.roots, output)
        self.assertFalse((self.sdk / "evidence").exists())

    def test_path_and_entry_bounds_stop_enumeration(self):
        with self.assertRaisesRegex(SEAL.SealError, "path-byte-limit"):
            SEAL.capture(self.roots, max_path_bytes=3)
        for n in range(8):
            (self.sdk / f"header{n}.h").write_text("a")
        with self.assertRaisesRegex(SEAL.SealError, "entry-limit"):
            SEAL.capture(self.roots, max_entries=2)

    def test_initial_inventory_mutation_is_refused(self):
        actual = SEAL.inventory
        calls = []

        def mutate(*args):
            result = actual(*args)
            if not calls:
                (self.sdk / "Later.h").write_text("new")
            calls.append(True)
            return result

        with mock.patch.object(SEAL, "inventory", side_effect=mutate):
            with self.assertRaisesRegex(SEAL.SealError, "input-mutated"):
                SEAL.capture(self.roots)

    def test_manifest_tampering_in_roots_limits_and_counts_is_rejected(self):
        first = SEAL.capture(self.roots)
        for key, value in [("roots", {"SDK": "/synthetic"}), ("limits", {}), ("files", 100)]:
            changed = {**first, key: value}
            with self.assertRaisesRegex(SEAL.SealError, "invalid-seal"):
                SEAL.verify(changed, self.roots)

    def test_failed_verification_keeps_both_identities_and_actual_manifest(self):
        first = SEAL.capture(self.roots)
        (self.sdk / "Header.h").write_text("changed")
        result = SEAL.record(self.roots, self.home / "changed", expected=first)
        self.assertEqual(result["status"], "mismatch")
        self.assertNotEqual(result["expected_sha256"], result["actual_sha256"])
        self.assertTrue((self.home / "changed/seal.json").is_file())

    def test_root_labels_and_limits_are_strict(self):
        for roots in [{}, {1: self.sdk}, {"bad label": self.sdk}, {"SDK": self.sdk / "Header.h"}]:
            with self.assertRaises(SEAL.SealError):
                SEAL.capture(roots)
        for limits in [dict(max_bytes=True), dict(max_entries=0), dict(max_bytes=SEAL.MAX_BYTES + 1)]:
            with self.assertRaisesRegex(SEAL.SealError, "invalid-limits"):
                SEAL.capture(self.roots, **limits)

    def test_malformed_expected_file_failure_has_cost_and_never_promotes(self):
        expected = self.home / "expected.json"
        expected.write_text("{broken")
        result = SEAL.record(self.roots, self.home / "malformed", expected_path=expected)
        self.assertEqual(result["status"], "failed")
        self.assertGreater(result["wall_seconds"], 0)
        self.assertIn("expected_file_sha256", result)
        self.assertFalse((self.home / "malformed/seal.json").exists())

    def test_interrupted_capture_preserves_incomplete_receipt(self):
        with mock.patch.object(SEAL, "capture", side_effect=KeyboardInterrupt):
            result = SEAL.record(self.roots, self.home / "interrupt")
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["failure"], "interrupt")
        self.assertGreater(result["wall_seconds"], 0)

    def test_manifest_byte_limit_preserves_failed_status(self):
        with mock.patch.object(SEAL, "MAX_MANIFEST_BYTES", 10):
            result = SEAL.record(self.roots, self.home / "small")
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["failure"], "manifest-byte-limit")
        self.assertFalse((self.home / "small/seal.json").exists())

    def test_rechecks_schema_counts_limits_and_types_after_checksum_recomputed(self):
        first = SEAL.capture(self.roots)
        changes = [
            ("schema_version", True),
            ("files", 999),
            ("bytes", -1),
            ("limits", {"max_entries": True, "max_bytes": 100, "max_path_bytes": 100}),
            ("wall_seconds", False),
            ("entries", []),
        ]
        for key, value in changes:
            changed = {**first, key: value}
            changed["manifest_sha256"] = SEAL.manifest_identity(changed)
            with self.assertRaisesRegex(SEAL.SealError, "invalid-seal"):
                SEAL.verify(changed, self.roots)

    def test_duplicate_expected_json_keys_are_rejected(self):
        first = SEAL.capture(self.roots)
        text = json.dumps(first).replace('"schema_version": 1', '"schema_version": 999, "schema_version": 1')
        path = self.home / "duplicate.json"
        path.write_text(text)
        result = SEAL.record(self.roots, self.home / "duplicate", expected_path=path)
        self.assertEqual(result["status"], "failed")
        self.assertFalse((self.home / "duplicate/seal.json").exists())

    def test_symlink_expected_receipt_is_refused(self):
        path = self.home / "actual.json"
        path.write_text(json.dumps(SEAL.capture(self.roots)))
        alias = self.home / "alias.json"
        alias.symlink_to(path)
        result = SEAL.record(self.roots, self.home / "alias-result", expected_path=alias)
        self.assertEqual(result["status"], "failed")
        self.assertFalse((self.home / "alias-result/seal.json").exists())

    def test_fifo_expected_receipt_does_not_block(self):
        path = self.home / "pipe"
        os.mkfifo(path)
        result = subprocess.run(
            [
                sys.executable,
                str(Path(SEAL.__file__)),
                "--root",
                "SDK=" + str(self.sdk),
                "--verify",
                str(path),
                "--output",
                str(self.home / "fifo-result"),
            ],
            capture_output=True,
            timeout=1,
        )
        self.assertEqual(result.returncode, 1)
        receipt = json.loads((self.home / "fifo-result/result.json").read_text())
        self.assertEqual(receipt["status"], "failed")
        self.assertGreater(receipt["wall_seconds"], 0)

    def test_expected_receipt_rewrite_during_read_is_refused(self):
        path = self.home / "changing.json"
        path.write_text(json.dumps(SEAL.capture(self.roots)))
        actual = SEAL.os.fstat
        calls = []

        def mutated(descriptor):
            result = actual(descriptor)
            if not calls:
                path.write_bytes(path.read_bytes().replace(b"explicit", b"modified"))
            calls.append(True)
            return result

        with mock.patch.object(SEAL.os, "fstat", side_effect=mutated):
            result = SEAL.record(self.roots, self.home / "mutating-receipt", expected_path=path)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["failure"], "expected-file-mutated")

    def test_cyclic_expected_link_keeps_failed_cost_receipt(self):
        path = self.home / "cycle.json"
        path.symlink_to(path.name)
        result = SEAL.record(self.roots, self.home / "cycle-result", expected_path=path)
        self.assertEqual(result["status"], "failed")
        self.assertGreater(result["wall_seconds"], 0)

    def test_impossible_entry_shape_and_nonfinite_json_are_rejected(self):
        first = SEAL.capture(self.roots)
        damaged = json.loads(json.dumps(first))
        damaged["entries"][1]["mode"] = True
        damaged["content_sha256"] = SEAL.identity(sorted(damaged["roots"]), damaged["entries"])
        damaged["manifest_sha256"] = SEAL.manifest_identity(damaged)
        with self.assertRaisesRegex(SEAL.SealError, "invalid-seal"):
            SEAL.validate_expected(damaged)
        for value in [b'{"value": NaN}', b'{"value": Infinity}', b'{"value": -Infinity}']:
            with self.assertRaisesRegex(SEAL.SealError, "invalid-seal"):
                SEAL.strict_expected_json(value)

    def test_executable_permission_change_is_observed(self):
        first = SEAL.capture(self.roots)
        (self.sdk / "Header.h").chmod(0o700)
        self.assertFalse(SEAL.verify(first, self.roots)["matches"])


if __name__ == "__main__":
    unittest.main()
