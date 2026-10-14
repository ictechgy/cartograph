"""전체 SDK 항목 투영의 역변환과 기존 공개 한도 경계를 작은 합성 파일로 검증한다."""

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("projection", HERE / "native_calibration_publication.py")
projection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(projection)


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.sdk, self.chain = self.root / "SDK", self.root / "TOOLCHAIN"
        self.sdk.mkdir()
        self.chain.mkdir()
        for number in range(12):
            (self.sdk / f"header-{number:02d}.h").write_text(f"body {number}")
        self.seal = projection.SEAL.capture({"SDK": self.sdk, "TOOLCHAIN": self.chain})
        self.verification = dict(matches=True, expected_sha256=self.seal["content_sha256"],
                                 actual_sha256=self.seal["content_sha256"], actual=copy.deepcopy(self.seal),
                                 wall_seconds=1.234)
        self.raw = self.root / "raw"
        self.raw.mkdir()
        self.stage = self.root / "stage"
        self.documents = {"before-compilation": self.seal, "after-generation": self.verification,
                          "after-calibration": copy.deepcopy(self.verification)}
        for label, document in self.documents.items():
            self.write_raw(label, document)

    def write_raw(self, label, document):
        path = self.raw / projection.SOURCES[label]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(projection.SEAL.canonical_bytes(document))

    def prepare(self):
        return projection.prepare_projection(self.raw, self.stage)

    def manifest(self):
        path = self.stage / projection.PROJECTION / "projection.json"
        return path, json.loads(path.read_text())

    def first_chunk(self):
        _, manifest = self.manifest()
        row = manifest["records"]["before-compilation"]["chunks"][0]
        return self.stage / projection.PROJECTION / row["path"]

    def test_inverse_keeps_every_original_field_entry_and_cost(self):
        result = self.prepare()
        documents, manifest = projection.restore_documents(self.stage / projection.PROJECTION)
        self.assertEqual(documents, self.documents)
        self.assertEqual(documents["after-generation"]["wall_seconds"], 1.234)
        self.assertEqual(result["status"], "verified-reversible-projection")
        self.assertFalse(result["accepted"])
        self.assertFalse(result["final_protocol_ready"])
        self.assertFalse(result["original_raw_bytes_reproduced"])
        for label in ["after-generation", "after-calibration"]:
            self.assertEqual(manifest["records"][label]["entries_reference"], "before-compilation")
        for label, relative in projection.SOURCES.items():
            self.assertEqual(manifest["records"][label]["raw_identity"]["sha256"],
                             projection.digest((self.raw / relative).read_bytes()))

    def test_mismatched_verification_preserves_own_entries_and_false_status(self):
        (self.sdk / "header-00.h").write_text("different")
        actual = projection.SEAL.capture({"SDK": self.sdk, "TOOLCHAIN": self.chain})
        changed = dict(matches=False, expected_sha256=self.seal["content_sha256"],
                       actual_sha256=actual["content_sha256"], actual=actual, wall_seconds=2.345)
        self.write_raw("after-generation", changed)
        self.prepare()
        restored, manifest = projection.restore_documents(self.stage / projection.PROJECTION)
        self.assertEqual(restored["after-generation"], changed)
        self.assertIn("chunks", manifest["records"]["after-generation"])
        self.assertFalse(restored["after-generation"]["matches"])

    def test_missing_later_receipts_are_explicit(self):
        for label in ["after-generation", "after-calibration"]:
            (self.raw / projection.SOURCES[label]).unlink()
        self.prepare()
        restored, manifest = projection.restore_documents(self.stage / projection.PROJECTION)
        self.assertEqual(list(restored), ["before-compilation"])
        self.assertEqual(manifest["records"]["after-generation"]["state"], "missing")

    def test_no_candidate_is_not_invented(self):
        for relative in projection.SOURCES.values():
            (self.raw / relative).unlink()
        self.prepare()
        restored, manifest = projection.restore_documents(self.stage / projection.PROJECTION)
        self.assertEqual(restored, {})
        self.assertTrue(all(row["state"] == "missing" for row in manifest["records"].values()))

    def test_verification_without_candidate_refuses(self):
        (self.raw / projection.SOURCES["before-compilation"]).unlink()
        with self.assertRaisesRegex(projection.ProjectionError, "verification-without-candidate"):
            self.prepare()
        self.assertFalse((self.stage / projection.PROJECTION).exists())

    def test_deterministic_chunks_preserve_order_and_multiplicity(self):
        with mock.patch.object(projection, "CHUNK_BYTES", 600):
            first = projection.entry_chunks(self.seal["entries"])
            second = projection.entry_chunks(self.seal["entries"])
        self.assertEqual(first, second)
        self.assertGreater(len(first), 1)
        self.assertTrue(all(len(chunk) <= 600 for chunk in first))
        self.assertEqual([entry for chunk in first for entry in projection.strict_array(chunk)], self.seal["entries"])
        values = [{"same": "entry"}, {"same": "entry"}]
        self.assertEqual(projection.strict_array(projection.entry_chunks(values)[0]), values)

    def test_chunks_match_unchanged_normalizer_serialization(self):
        for data in projection.entry_chunks(self.seal["entries"]):
            self.assertEqual(data, projection.encoded(projection.strict_array(data)))

    def test_missing_extra_duplicate_and_reordered_chunks_refuse(self):
        with mock.patch.object(projection, "CHUNK_BYTES", 600):
            self.prepare()
            path, manifest = self.manifest()
            original = copy.deepcopy(manifest)
            chunks = manifest["records"]["before-compilation"]["chunks"]
            chunks[0], chunks[1] = chunks[1], chunks[0]
            path.write_bytes(projection.encoded(manifest))
            with self.assertRaisesRegex(projection.ProjectionError, "invalid-chunk-order-or-schema"):
                projection.verify_projection(self.stage)
            manifest = copy.deepcopy(original)
            manifest["records"]["before-compilation"]["chunks"].append(
                copy.deepcopy(manifest["records"]["before-compilation"]["chunks"][0]))
            path.write_bytes(projection.encoded(manifest))
            with self.assertRaises(projection.ProjectionError):
                projection.verify_projection(self.stage)
            path.write_bytes(projection.encoded(original))
            extra = path.parent / "extra.json"
            extra.write_text("{}")
            with self.assertRaisesRegex(projection.ProjectionError, "extra-projection-files"):
                projection.verify_projection(self.stage)
            extra.unlink()
            self.first_chunk().unlink()
            with self.assertRaisesRegex(projection.ProjectionError, "missing-or-duplicate-chunk"):
                projection.verify_projection(self.stage)

    def test_changed_chunk_bytes_refuse(self):
        self.prepare()
        chunk = self.first_chunk()
        chunk.write_bytes(chunk.read_bytes() + b" ")
        with self.assertRaisesRegex(projection.ProjectionError, "chunk-identity-mismatch"):
            projection.verify_projection(self.stage)

    def test_rehashed_entry_reordering_still_fails_inverse_identity(self):
        self.prepare()
        path, manifest = self.manifest()
        row = manifest["records"]["before-compilation"]["chunks"][0]
        chunk = self.first_chunk()
        entries = projection.strict_array(chunk.read_bytes())
        entries[0], entries[1] = entries[1], entries[0]
        data = projection.encoded(entries)
        chunk.write_bytes(data)
        row.update(bytes=len(data), sha256=projection.digest(data))
        path.write_bytes(projection.encoded(manifest))
        with self.assertRaisesRegex(projection.ProjectionError, "inverse-value-mismatch"):
            projection.verify_projection(self.stage)

    def test_duplicate_entry_with_rehashed_chunk_does_not_pass(self):
        self.prepare()
        path, manifest = self.manifest()
        record = manifest["records"]["before-compilation"]
        row = record["chunks"][0]
        chunk = self.first_chunk()
        entries = projection.strict_array(chunk.read_bytes())
        entries.append(copy.deepcopy(entries[-1]))
        data = projection.encoded(entries)
        chunk.write_bytes(data)
        row.update(bytes=len(data), sha256=projection.digest(data), entry_count=len(entries))
        record["entry_count"] = len(entries)
        path.write_bytes(projection.encoded(manifest))
        with self.assertRaisesRegex(projection.ProjectionError, "inverse-value-mismatch"):
            projection.verify_projection(self.stage)

    def test_oversized_single_entry_is_refused(self):
        with mock.patch.object(projection, "CHUNK_BYTES", 40):
            with self.assertRaisesRegex(projection.ProjectionError, "single-entry-chunk-limit"):
                projection.entry_chunks([{"path": "a" * 50}])

    def test_total_overflow_is_refused_without_larger_caps(self):
        with mock.patch.object(projection, "MAX_TOTAL_BYTES", 100):
            with self.assertRaisesRegex(projection.ProjectionError, "projection-size-limit"):
                self.prepare()
        self.assertFalse((self.stage / projection.PROJECTION).exists())

    def test_file_overflow_is_refused(self):
        self.prepare()
        with mock.patch.object(projection, "MAX_FILE_BYTES", 100):
            with self.assertRaisesRegex(projection.ProjectionError, "projection-size-limit"):
                projection.verify_projection(self.stage)

    def test_symlink_and_fifo_sources_are_not_opened(self):
        path = self.raw / projection.SOURCES["before-compilation"]
        path.unlink()
        os.mkfifo(path)
        with self.assertRaises(projection.SEAL.SealError):
            self.prepare()

    def test_input_output_overlap_refuses(self):
        with self.assertRaisesRegex(projection.ProjectionError, "projection-input-overlap"):
            projection.prepare_projection(self.raw, self.raw / "nested")

    def test_cost_or_original_metadata_mutation_fails_inverse(self):
        self.prepare()
        path, manifest = self.manifest()
        manifest["records"]["after-generation"]["document_without_entries"]["wall_seconds"] = 0.0
        path.write_bytes(projection.encoded(manifest))
        with self.assertRaisesRegex(projection.ProjectionError, "inverse-value-mismatch"):
            projection.verify_projection(self.stage)

    def test_wrong_candidate_reference_is_refused(self):
        self.prepare()
        path, manifest = self.manifest()
        manifest["records"]["after-generation"]["entries_reference"] = "after-calibration"
        path.write_bytes(projection.encoded(manifest))
        with self.assertRaisesRegex(projection.ProjectionError, "invalid-entry-reference"):
            projection.verify_projection(self.stage)


    def normalize(self):
        self.prepare()
        (self.stage / "results.json").write_text('{"status":"candidate-only"}\n')
        source = HERE.parent / "normalize-indexstore-evidence.py"
        spec = importlib.util.spec_from_file_location("sdk_projection_test_normalizer", source)
        normalizer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(normalizer)
        public = self.root / "public"
        manifest = normalizer.package(argparse.Namespace(input=self.stage, output=public,
                                                         prefix=["WORKSPACE=" + str(self.root)]))
        return public, manifest

    def test_unchanged_normalizer_scans_all_projected_bytes_and_retains_identity(self):
        public, manifest = self.normalize()
        result = projection.verify_publication(self.stage, public, manifest)
        self.assertEqual(result["status"], "verified-normalized-projection")
        self.assertTrue(result["entries_content_identity_preserved"])
        self.assertTrue(result["non_entry_fields_normalized"])
        self.assertFalse(result["original_raw_bytes_reproduced"])
        projected = projection.projection_files(public / projection.PROJECTION)
        listed = {row["path"] for row in manifest["files"]}
        self.assertTrue({str(projection.PROJECTION / name) for name in projected} <= listed)
        restored, _ = projection.restore_documents(public / projection.PROJECTION, normalized=True)
        self.assertNotEqual(restored["before-compilation"]["roots"], self.seal["roots"])
        self.assertEqual(restored["before-compilation"]["content_sha256"], self.seal["content_sha256"])
        self.assertEqual(restored["before-compilation"]["entries"], self.seal["entries"])

    def test_normalized_output_or_receipt_mutation_is_refused(self):
        public, manifest = self.normalize()
        copied = copy.deepcopy(manifest)
        copied["source_raw_unchanged"] = False
        with self.assertRaisesRegex(projection.ProjectionError, "normalization-receipt-changed"):
            projection.verify_publication(self.stage, public, copied)
        path = public / projection.PROJECTION / "projection.json"
        value = json.loads(path.read_text())
        value["records"]["after-generation"]["document_without_entries"]["wall_seconds"] = 0
        path.write_bytes(projection.encoded(value))
        with self.assertRaisesRegex(projection.ProjectionError, "normalized-file-mismatch"):
            projection.verify_publication(self.stage, public, manifest)

    def test_symlink_original_is_refused(self):
        source = self.raw / projection.SOURCES["before-compilation"]
        target = self.root / "copy.json"
        target.write_bytes(source.read_bytes())
        source.unlink()
        source.symlink_to(target)
        with self.assertRaises(projection.SEAL.SealError):
            self.prepare()


    def test_raw_source_changed_after_projection_refuses_final_check(self):
        self.prepare()
        self.assertEqual(projection.verify_sources(self.raw, self.stage)["status"], "source-identities-unchanged")
        changed = copy.deepcopy(self.verification)
        changed["wall_seconds"] = 9.0
        self.write_raw("after-calibration", changed)
        with self.assertRaisesRegex(projection.ProjectionError, "source-changed"):
            projection.verify_sources(self.raw, self.stage)

    def test_missing_source_appearing_after_projection_refuses(self):
        (self.raw / projection.SOURCES["after-calibration"]).unlink()
        self.prepare()
        self.write_raw("after-calibration", self.verification)
        with self.assertRaisesRegex(projection.ProjectionError, "missing-source-appeared"):
            projection.verify_sources(self.raw, self.stage)


if __name__ == "__main__":
    unittest.main()
