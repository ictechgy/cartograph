"""전체 SDK 항목 투영의 역변환과 기존 공개 한도 경계를 작은 합성 파일로 검증한다."""

import argparse
import ast
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
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

    def rewrite_first_chunk(self, entries):
        path, manifest = self.manifest()
        record = manifest["records"]["before-compilation"]
        self.assertEqual(len(record["chunks"]), 1)
        data = projection.encoded(entries)
        self.first_chunk().write_bytes(data)
        record["chunks"][0].update(bytes=len(data), sha256=projection.digest(data), entry_count=len(entries))
        record["entry_count"] = len(entries)
        path.write_bytes(projection.encoded(manifest))

    def test_v2_encodes_only_known_paths_without_mutating_originals(self):
        originals = copy.deepcopy(self.documents)
        self.prepare()
        _, manifest = self.manifest()
        self.assertEqual((manifest["schema_version"], manifest["kind"]),
                         (2, "native-calibration-sdk-entry-chunks-v2"))
        entries = projection.strict_array(self.first_chunk().read_bytes())
        for original, projected in zip(self.seal["entries"], entries, strict=True):
            self.assertNotIn("path", projected)
            self.assertEqual(projected["path_components"], original["path"].split("/"))
            self.assertEqual(projection.restore_entry(projected, "test.json"), original)
        self.assertEqual(entries[0]["path_components"], ["."])
        link = dict(root="SDK", path="libcxx", mode=0o777, type="symlink", link_text_sha256="a" * 64,
                    target=dict(root="SDK", path="include/c++/v1"))
        original_link = copy.deepcopy(link)
        with mock.patch.object(projection.NORMALIZER, "check_sensitive",
                               wraps=projection.NORMALIZER.check_sensitive) as sensitive:
            projected = projection.project_entry(link, "test.json")
        self.assertEqual(sensitive.call_args_list,
                         [mock.call("libcxx", "test.json"), mock.call("include/c++/v1", "test.json")])
        self.assertEqual(projected["target"], dict(root="SDK", path_components=["include", "c++", "v1"]))
        self.assertEqual(projection.restore_entry(projected, "test.json"), original_link)
        self.assertEqual(link, original_link)
        self.assertEqual(self.documents, originals)

    def test_v1_and_mixed_projection_versions_are_refused(self):
        self.prepare()
        path, original = self.manifest()
        for version, kind in [(1, "native-calibration-sdk-entry-chunks-v1"),
                              (1, "native-calibration-sdk-entry-chunks-v2"),
                              (2, "native-calibration-sdk-entry-chunks-v1"),
                              (True, "native-calibration-sdk-entry-chunks-v2")]:
            with self.subTest(version=version, kind=kind):
                manifest = dict(original, schema_version=version, kind=kind)
                path.write_bytes(projection.encoded(manifest))
                with self.assertRaisesRegex(projection.ProjectionError, "invalid-projection-status"):
                    projection.verify_projection(self.stage)

    def test_windows_pattern_matches_unchanged_normalizer_source(self):
        source = ast.parse(Path(projection.NORMALIZER.__file__).read_text())
        assignments = [node for node in ast.walk(source) if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == "windows_path"
                               for target in node.targets)]
        self.assertEqual(len(assignments), 1)
        call = assignments[0].value
        self.assertEqual((call.func.value.id, call.func.attr), ("re", "search"))
        self.assertEqual(projection.WINDOWS_PATH.pattern, ast.literal_eval(call.args[0]))

    def test_unsplit_entry_and_target_paths_cannot_hide_sensitive_or_windows_text(self):
        cases = [
            ("include/password=/secret_value", "secret-assignment"),
            ("include/Bearer abcdef/ghijklmnop", "bearer-token"),
            ("include/https://user:secret@localhost/path", "credential-url"),
            ("include/https://example.invalid/a/b?X-Amz-Signature=abcdefgh", "token-bearing-or-signed-url"),
            ("include/C:/private/file", "unmapped-windows-absolute-path"),
            (r"include/C:\private\file", "unmapped-windows-absolute-path"),
            (r"include/\\server\share/file", "unmapped-windows-absolute-path"),
            ("include/control\x00/child", "unexpected-control-or-binary-content"),
        ]
        for value, reason in cases:
            for location in ["entry", "target"]:
                with self.subTest(value=value, location=location):
                    entry = dict(root="SDK", path="alias", mode=0o777, type="symlink",
                                 link_text_sha256="a" * 64, target=dict(root="SDK", path="."))
                    (entry if location == "entry" else entry["target"])["path"] = value
                    with self.assertRaises(projection.NORMALIZER.PublicationBlocked) as blocked:
                        projection.project_entry(entry, "test.json")
                    self.assertEqual(blocked.exception.reason, reason)
                    self.assertNotIn(value, str(blocked.exception))

    def test_rehashed_invalid_original_seals_are_rejected_before_projection(self):
        mutations = [
            lambda entries: entries.append(copy.deepcopy(entries[0])),
            lambda entries: entries[1].update(extra="unexpected"),
            lambda entries: entries[1].update(path_components=["header-00.h"]),
            lambda entries: entries[1].update(path="../outside.h"),
            lambda entries: entries[1].update(root="UNKNOWN"),
            lambda entries: entries.append(dict(root="SDK", path="link", mode=0o777, type="symlink",
                                                link_text_sha256="a" * 64,
                                                target=dict(root="UNKNOWN", path="."))),
        ]
        for number, mutate in enumerate(mutations):
            with self.subTest(number=number):
                seal = copy.deepcopy(self.seal)
                mutate(seal["entries"])
                seal["content_sha256"] = projection.SEAL.identity(sorted(seal["roots"]), seal["entries"])
                seal["manifest_sha256"] = projection.SEAL.manifest_identity(seal)
                self.write_raw("before-compilation", seal)
                stage = self.root / f"invalid-source-{number}"
                with mock.patch.object(projection, "project_entry", side_effect=AssertionError("must validate first")):
                    with self.assertRaisesRegex(projection.SEAL.SealError, "invalid-seal"):
                        projection.prepare_projection(self.raw, stage)
                self.assertFalse((stage / projection.PROJECTION).exists())

    def test_real_presplit_failure_retains_safe_publication_receipt(self):
        value = "Bearer abcdef/ghijkl"
        (self.sdk / value).mkdir(parents=True)
        seal = projection.SEAL.capture({"SDK": self.sdk, "TOOLCHAIN": self.chain})
        verification = dict(matches=True, expected_sha256=seal["content_sha256"],
                            actual_sha256=seal["content_sha256"], actual=seal, wall_seconds=1.234)
        for label in projection.SOURCES:
            self.write_raw(label, seal if label == "before-compilation" else verification)
        spec = importlib.util.spec_from_file_location("projection_publication_wrapper",
                                                     HERE.parent / "validate-native-calibration-inputs.py")
        wrapper = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, "path", sys.path.copy()):
            spec.loader.exec_module(wrapper)
        raw = self.root / "native-calibration-sdk-raw"
        self.raw.rename(raw)
        wrapper.save(raw / "results.json", dict(status="captured-candidate", accepted=False,
                                                final_protocol_ready=False, helper_sha256=wrapper.helper_hashes()))
        originals = {path.relative_to(raw): path.read_bytes() for path in raw.rglob("*") if path.is_file()}
        with mock.patch.object(wrapper.NORMALIZER, "package", wraps=wrapper.NORMALIZER.package) as package:
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(wrapper.publish(self.root), 1)
        package.assert_not_called()
        receipt = json.loads((self.root / "native-calibration-sdk-publication.json").read_text())
        logged = json.loads(output.getvalue())
        safe_failure = dict(category="publication-failure", artifact_sha256=None, value_sha256=None)
        for result in [receipt, logged]:
            self.assertEqual((result["status"], result["exit_code"]), ("failed", 1))
            self.assertEqual(result["publication_failure"], safe_failure)
            self.assertEqual(set(result["costs"]), {"prepare_projection"})
            self.assertEqual(result["costs"]["prepare_projection"]["status"], "failed")
            self.assertGreaterEqual(result["costs"]["prepare_projection"]["full_wall_seconds"], 0)
        self.assertEqual(receipt["failure_type"], "PublicationBlocked")
        self.assertFalse(receipt["accepted"])
        self.assertFalse(receipt["final_protocol_ready"])
        self.assertFalse((self.root / "native-calibration-sdk-public").exists())
        self.assertFalse((self.root / "native-calibration-sdk-staging" / projection.PROJECTION).exists())
        for text in [output.getvalue(), json.dumps(receipt)]:
            self.assertNotIn(value, text)
            self.assertNotIn("Bearer abcdef", text)
            self.assertNotIn(str(self.root), text)
        self.assertEqual({path.relative_to(raw): path.read_bytes() for path in raw.rglob("*") if path.is_file()},
                         originals)

    def test_rehashed_malformed_projected_entries_are_rejected_before_inverse(self):
        self.prepare()
        original = projection.strict_array(self.first_chunk().read_bytes())
        base = original[0]
        scalar = {key: value for key, value in base.items() if key != "path_components"}
        cases = [(value, "invalid-projected-entry") for value in [None, [], 7, {},
                 dict(base, root=[]), dict(base, mode=True), dict(base, mode=-1),
                 dict(base, type="unknown"), dict(base, type=[]), dict(base, path="."),
                 dict(base, extra="unexpected"), scalar, dict(scalar, path=".")]]
        cases += [(dict(base, path_components=parts), "invalid-path-components")
                  for parts in [None, "include", [], [True], [""], ["/private"], ["a/b"], [".."],
                                [".", "child"], ["include", "."], ["include", "..", "outside"]]]
        cases += [(dict(base, root="UNKNOWN"), "entry-root-mismatch")]
        file = next(entry for entry in original if entry["type"] == "file")
        cases += [(dict(file, **change), "invalid-projected-entry")
                  for change in [dict(bytes=True), dict(bytes=-1), dict(sha256="invalid"), dict(target={})]]
        for value, reason in cases:
            with self.subTest(value=value):
                entries = copy.deepcopy(original)
                entries[0] = value
                self.rewrite_first_chunk(entries)
                for normalized in [False, True]:
                    with self.assertRaisesRegex(projection.ProjectionError, reason):
                        projection.restore_documents(self.stage / projection.PROJECTION, normalized=normalized)

    def test_rehashed_malformed_symlink_targets_are_rejected_before_inverse(self):
        self.prepare()
        original = projection.strict_array(self.first_chunk().read_bytes())
        link = dict(root="SDK", path_components=["alias"], mode=0o777, type="symlink",
                    link_text_sha256="a" * 64, target=dict(root="SDK", path_components=["."]))
        target = link["target"]
        cases = [(value, "invalid-projected-target") for value in [None, [], {}, dict(target, path="."),
                 dict(target, root=[]), dict(target, extra="unexpected"), dict(root="SDK"),
                 dict(root="SDK", path=".")]]
        cases += [(dict(target, path_components=parts), "invalid-path-components")
                  for parts in [[], [""], ["/private"], [".."], ["include", ".."], [".", "child"], ["a/b"]]]
        cases += [(dict(target, root="UNKNOWN"), "entry-root-mismatch")]
        for value, reason in cases:
            with self.subTest(value=value):
                entries = copy.deepcopy(original)
                entries[0] = dict(link, target=value)
                self.rewrite_first_chunk(entries)
                for normalized in [False, True]:
                    with self.assertRaisesRegex(projection.ProjectionError, reason):
                        projection.restore_documents(self.stage / projection.PROJECTION, normalized=normalized)

    def test_rehashed_components_are_rejoined_before_sensitive_checks(self):
        self.prepare()
        original = projection.strict_array(self.first_chunk().read_bytes())
        for parts, reason in [(["include", "password=", "secret_value"], "secret-assignment"),
                              (["include", "Bearer abcdef", "ghijklmnop"], "bearer-token"),
                              (["include", "C:", "private", "file"], "unmapped-windows-absolute-path")]:
            for location in ["entry", "target"]:
                with self.subTest(parts=parts, location=location):
                    entry = dict(root="SDK", path_components=["alias"], mode=0o777, type="symlink",
                                 link_text_sha256="a" * 64, target=dict(root="SDK", path_components=["."]))
                    (entry if location == "entry" else entry["target"])["path_components"] = parts
                    entries = copy.deepcopy(original)
                    entries[0] = entry
                    self.rewrite_first_chunk(entries)
                    with self.assertRaises(projection.NORMALIZER.PublicationBlocked) as blocked:
                        projection.verify_projection(self.stage)
                    self.assertEqual(blocked.exception.reason, reason)

    def test_referenced_entries_still_require_declared_roots(self):
        self.prepare()
        path, manifest = self.manifest()
        del manifest["records"]["after-generation"]["document_without_entries"]["actual"]["roots"]["SDK"]
        path.write_bytes(projection.encoded(manifest))
        with self.assertRaisesRegex(projection.ProjectionError, "entry-root-mismatch"):
            projection.verify_projection(self.stage)

    def test_non_sdk_paths_still_receive_the_unchanged_generic_scan(self):
        self.prepare()
        (self.stage / "results.json").write_text('{"note":"include/c++/v1"}\n')
        with self.assertRaises(projection.NORMALIZER.PublicationBlocked) as blocked:
            projection.NORMALIZER.package(argparse.Namespace(input=self.stage, output=self.root / "public",
                                                             prefix=["WORKSPACE=" + str(self.root)]))
        self.assertEqual(blocked.exception.reason, "unmapped-absolute-path")

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

    def test_cpp_relative_paths_and_symlink_targets_publish_losslessly(self):
        headers = self.sdk / "include/c++/v1"
        headers.mkdir(parents=True)
        (headers / "vector").write_text("template<class T> class vector;\n")
        (self.sdk / "libcxx").symlink_to("include/c++/v1", target_is_directory=True)
        self.seal = projection.SEAL.capture({"SDK": self.sdk, "TOOLCHAIN": self.chain})
        self.verification = dict(matches=True, expected_sha256=self.seal["content_sha256"],
                                 actual_sha256=self.seal["content_sha256"], actual=copy.deepcopy(self.seal),
                                 wall_seconds=1.234)
        self.documents = {"before-compilation": self.seal, "after-generation": self.verification,
                          "after-calibration": copy.deepcopy(self.verification)}
        for label, document in self.documents.items():
            self.write_raw(label, document)
        public, manifest = self.normalize()
        result = projection.verify_publication(self.stage, public, manifest)
        self.assertEqual(result["status"], "verified-normalized-projection")
        restored, _ = projection.restore_documents(public / projection.PROJECTION, normalized=True)
        self.assertEqual(set(restored), set(self.documents))
        for label, document in restored.items():
            seal = document if label == "before-compilation" else document["actual"]
            self.assertEqual(seal["entries"], self.seal["entries"])
            self.assertEqual(seal["content_sha256"], self.seal["content_sha256"])

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
