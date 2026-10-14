#!/usr/bin/env python3
"""Swift를 실행하지 않고 parity 생성기의 고정 입력·출력 경계를 검증한다."""

import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("dependency_parity", ROOT / "Scripts/prepare-streaming-dependency-parity.py")
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)
PINNED = {path: P.read_blob(ROOT, path) for path in [P.READER, *P.FIXTURES]}
BASELINE = PINNED[P.READER].decode()


class PreparationContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name).resolve()
        self.repository = self.base / "repository"
        self.repository.mkdir()
        self.evidence = self.base / "evidence"
        files = {
            P.READER: P.candidate_from_baseline(BASELINE).encode(),
            **{path: PINNED[path] for path in P.FIXTURES},
            "Package.swift": (ROOT / "Package.swift").read_bytes(),
            "Package.resolved": (ROOT / "Package.resolved").read_bytes(),
            "Scripts/prepare-streaming-dependency-parity.py": (ROOT / "Scripts/prepare-streaming-dependency-parity.py").read_bytes(),
            "Scripts/streaming-dependency-parity/Assertions.swift":
                (ROOT / "Scripts/streaming-dependency-parity/Assertions.swift").read_bytes(),
        }
        for path, data in files.items():
            target = self.repository / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.reader = mock.patch.object(P, "read_blob", side_effect=lambda repository, path: PINNED[path])
        self.reader.start()
        self.addCleanup(self.reader.stop)
        self.addCleanup(self.temporary.cleanup)

    def prepare(self):
        return P.prepare(self.repository, self.evidence)

    def snapshot(self):
        return {str(p.relative_to(self.repository)): p.read_bytes()
            for p in self.repository.rglob("*") if p.is_file()}

    def expect_refusal_without_writes(self):
        before = self.snapshot()
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.evidence.exists())

    def test_exact_baseline_copy_and_candidate_production_bytes(self):
        before = P.product_hashes(self.repository)
        report = self.prepare()
        self.assertEqual(P.product_hashes(self.repository), before)
        self.assertEqual(report["status"], "prepared_not_executed")
        self.assertEqual(len(report["generated_sha256"]), 6)
        generated = self.repository / (P.TEST_ROOT + "EagerDependencyRawIndexStoreReader.generated.swift")
        recovered = generated.read_text().replace("EagerDependencyRawIndexStoreReader", "RawIndexStoreReader")
        recovered = recovered.replace("@testable import CartographIndexStore\n", "", 1)
        recovered = P.replace_once(recovered, "struct RawIndexStoreReader {", P.RESULT + "struct RawIndexStoreReader {")
        self.assertEqual(recovered, BASELINE)
        for path, expected in report["generated_sha256"].items():
            self.assertEqual(P.digest((self.repository / path).read_bytes()), expected)
            self.assertEqual((self.evidence / "generated" / path).read_bytes(), (self.repository / path).read_bytes())
        saved = json.loads((self.evidence / "preparation.json").read_text())
        self.assertEqual(saved, report)

    def test_only_the_six_declared_test_paths_change(self):
        before = self.snapshot()
        report = self.prepare()
        after = self.snapshot()
        changed = {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}
        self.assertEqual(changed, set(report["generated_sha256"]))

    def test_fixture_rewrite_keeps_all_tests_and_static_reader_checks(self):
        self.prepare()
        for path in P.FIXTURES:
            original = PINNED[path].decode()
            generated = (self.repository / path).read_text()
            self.assertEqual(generated.count("@Test"), original.count("@Test"))
            restored = generated.replace("DependencyParityRawReader(", "RawIndexStoreReader(")
            restored = restored.replace("DependencyParityProvider", "IndexStoreProvider")
            self.assertEqual(restored, original)
        raw = (self.repository / (P.TEST_ROOT + "RawIndexStoreReaderTests.swift")).read_text()
        self.assertIn("RawIndexStoreReader.language", raw)

    def test_counted_copies_cover_only_original_getter_sites(self):
        candidate = P.candidate_from_baseline(BASELINE)
        for source, streaming in [(BASELINE, False), (candidate, True)]:
            generated = P.counted_reader(source, "CountedReader", streaming)
            for field in ["path", "module", "name", "system"]:
                self.assertEqual(generated.count("dependencyMetadata." + field + "("), 1)
            for counter in ["dependencies", "recordOrFile", "admittedContexts", "admittedRecords"]:
                self.assertEqual(generated.count("dependencyMetadata." + counter + " += 1"), 1)
            self.assertEqual(generated.count("defer { metadataResult?(dependencyMetadata) }"), 1)
            self.assertIn("var loadedRecords = RecordCache(capacity: 64)", generated)
            self.assertIn("let relationSymbol = rawRelation.symbol", generated)

    def test_unit_metadata_is_owned_before_callback_but_provider_validation_remains_lazy(self):
        candidate = P.candidate_from_baseline(BASELINE)
        prefix, callback = candidate.split("try unit.dependencies.forEach { dependency in", 1)
        callback = callback.split("\n        records.sort", 1)[0]
        self.assertIn("let providerIdentifier = unit.providerIdentifier.string", prefix)
        self.assertIn("let isSystemUnit = unit.isSystemUnit", prefix)
        self.assertEqual(candidate.count("unit.providerIdentifier.string"), 1)
        self.assertEqual(candidate.count("unit.isSystemUnit"), 1)
        self.assertNotRegex(callback, r"\bunit\s*\.")
        self.assertNotIn("try providerKind(", prefix)
        guard = "guard readsOccurrences, kind == .record else { return .continue }"
        parse = "let parsed = try providerKind(providerIdentifier, unit: unitName)"
        self.assertEqual(callback.count(parse), 1)
        self.assertLess(callback.index(guard), callback.index("if let unitProvider"))
        self.assertLess(callback.index("if let unitProvider"), callback.index(parse))
        self.assertIn("unitProvider = parsed", callback)
        self.assertEqual(callback.count("isSystemUnit || isSystem"), 2)

    def test_native_evidence_schema_contains_counts_and_no_identity_fields(self):
        template = (self.repository / "Scripts/streaming-dependency-parity/Assertions.swift").read_text()
        evidence = re.search(r"struct DependencyParityEvidence: Encodable \{(.*?)\n\}", template, re.S).group(1)
        self.assertEqual(re.findall(r"let (\w+): ([\w]+)", evidence), [
            ("schema", "String"), ("eager", "DependencyMetadataCounts"),
            ("streaming", "DependencyMetadataCounts"), ("eagerCacheOpenEvents", "Int"),
            ("streamingCacheOpenEvents", "Int"),
        ])
        counts = re.search(r"struct DependencyMetadataCounts: Codable, Equatable \{(.*?)\n\}", template, re.S).group(1)
        self.assertEqual(re.findall(r"var (\w+) = 0", counts), [
            "dependencies", "recordOrFile", "admittedContexts", "admittedRecords",
            "pathStrings", "moduleStrings", "nameStrings", "systemReads",
        ])
        self.assertIn('print("cartograph-streaming-dependency-parity-v1 "', template)
        self.assertIn('schema: "cartograph-streaming-dependency-parity-v1"', template)
        self.assertNotIn("paritySuccess", template)
        self.assertIn("encoder.outputFormatting = [.sortedKeys]", template)

    def test_changed_candidate_refused(self):
        target = self.repository / P.READER
        target.write_text(target.read_text().replace("record: dependency.name.string", "record: \"ignored\""))
        self.expect_refusal_without_writes()

    def test_unexpected_original_fixture_refused(self):
        target = self.repository / next(iter(P.FIXTURES))
        target.write_bytes(target.read_bytes() + b"\n// changed fixture\n")
        self.expect_refusal_without_writes()

    def test_preexisting_generated_destination_refused(self):
        target = self.repository / (P.TEST_ROOT + "EagerDependencyRawIndexStoreReader.generated.swift")
        target.write_text("must be preserved")
        self.expect_refusal_without_writes()

    def test_wrong_pin_refused(self):
        target = self.repository / "Package.resolved"
        target.write_text(target.read_text().replace(P.INDEXSTORE, "0" * 40))
        self.expect_refusal_without_writes()

    def test_wrong_baseline_blob_refused(self):
        with mock.patch.object(P, "read_blob", return_value=b"wrong baseline"):
            self.expect_refusal_without_writes()

    def test_symlinked_input_refused(self):
        target = self.repository / P.READER
        original = self.base / "original.swift"
        original.write_bytes(target.read_bytes())
        target.unlink()
        target.symlink_to(original)
        self.expect_refusal_without_writes()

    def test_symlinked_destination_refused(self):
        target = self.repository / (P.TEST_ROOT + "CountedStreamingDependencyRawIndexStoreReader.generated.swift")
        outside = self.base / "outside.swift"
        outside.write_text("must be preserved")
        target.symlink_to(outside)
        self.expect_refusal_without_writes()
        self.assertEqual(outside.read_text(), "must be preserved")

    def test_existing_or_in_checkout_evidence_refused(self):
        self.evidence.mkdir()
        before = self.snapshot()
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.snapshot(), before)
        self.evidence = self.repository / "evidence"
        self.expect_refusal_without_writes()

    def test_second_preparation_does_not_rewrite_generated_files(self):
        self.prepare()
        before = self.snapshot()
        self.evidence = self.base / "second-evidence"
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.evidence.exists())

    def test_missing_or_duplicate_transform_anchor_refused(self):
        with self.assertRaises(ValueError):
            P.candidate_from_baseline(BASELINE.replace(P.EAGER_MAP, ""))
        with self.assertRaises(ValueError):
            P.candidate_from_baseline(BASELINE + P.EAGER_MAP)


if __name__ == "__main__":
    unittest.main()
