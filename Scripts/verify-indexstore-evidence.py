#!/usr/bin/env python3
"""가상 비밀값만 사용해 공개 증거의 경로 치환과 실패 시 차단을 검증한다."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("normalize-indexstore-evidence.py")
SPEC = importlib.util.spec_from_file_location("normalize_indexstore_evidence", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.raw, self.public = self.root / "raw", self.root / "public"
        self.workspace, self.toolchain, self.cache = (
            self.root / "workspace",
            self.root / "toolchain",
            self.root / "cache",
        )
        self.raw.mkdir()
        self.args = argparse.Namespace(
            input=self.raw,
            output=self.public,
            prefix=[f"WORKSPACE={self.workspace}", f"TOOLCHAIN={self.toolchain}", f"CACHE={self.cache}"],
        )
        self.values = {
            "status": "failed",
            "returncode": 64,
            "timed_out": False,
            "wall_seconds": 1.234567891234,
            "wait4_maxrss_bytes": 123456789,
            "cwd": str(self.workspace),
            "command": [
                str(self.toolchain / "usr/bin/swift"),
                "-I" + str(self.cache / "modules"),
                str(self.workspace / "file.swift"),
            ],
            "stdout": str(self.raw / "runs/query.stdout"),
            "stderr": str(self.raw / "setup/build.stderr"),
        }
        self.write("results.json", json.dumps(self.values))
        self.write("runs/query.stdout", json.dumps({"stdout": str(self.raw / "setup/build.stderr"), "value": 2.5}))
        self.write("setup/build.stderr", f"Failure at {self.workspace}/Sources/File.swift:7; elapsed=1.25\n")
        self.write("fixtures/basic/Sources/Calls.swift", "func value() -> Int { 2 / 1 }\n")
        self.write("fixtures/basic/oracle.json", '{"expected": [1, 2]}')
        self.write("fixtures/basic/.cartograph.yml", 'include: ["Sources/**"]\n')
        self.write(
            "fixtures/basic/.build/output-file-map.json",
            json.dumps(
                {
                    str(self.raw / "fixtures/basic/Sources/Calls.swift"): {
                        "object": str(self.raw / "fixtures/basic/.build/Calls.o")
                    }
                }
            ),
        )
        self.write("fixtures/basic/.build/Calls.o", b"\x00OBJECT")
        self.write("fixtures/basic/.build/index-store/v5/records/record", b"\x00INDEX")
        self.write("fixtures/basic/.build/fixture", b"\x7fELF\x00")
        self.write("upstream-indexstore-db/.build/log.stdout", b"DO NOT COPY")
        self.write("cartograph-release-build/object.json", b"DO NOT COPY")

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, relative, value):
        path = self.raw / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value.encode() if isinstance(value, str) else value)

    def snapshot(self):
        return {
            str(path.relative_to(self.raw)): MODULE.digest(path.read_bytes())
            for path in self.raw.rglob("*")
            if path.is_file()
        }

    def assert_blocked_without_output(self, category):
        before = self.snapshot()
        with self.assertRaisesRegex(MODULE.PublicationBlocked, category):
            MODULE.package(self.args)
        self.assertFalse(self.public.exists() and any(self.public.iterdir()))
        self.assertEqual(before, self.snapshot())

    def test_complete_jsonl_samples_preserve_values_hashes_and_relative_links(self):
        relative = "runs/pair01/memory.samples.jsonl"
        samples = [
            {"time": 0.1234567890123, "rss_bytes": 123456789, "paths": [str(self.workspace / "a.swift")]},
            {"time": 1.1234567890123, "rss_bytes": 0, "failed": True, "missing": None},
        ]
        raw_samples = "\n".join(json.dumps(item) for item in samples) + "\n"
        self.write(relative, raw_samples)
        self.values["samples"] = str(self.raw / relative)
        self.write("results.json", json.dumps(self.values))
        manifest = MODULE.package(self.args)
        result = json.loads((self.public / "results.json").read_text())
        self.assertEqual(result["samples"], relative)
        actual = [json.loads(line) for line in (self.public / relative).read_text().splitlines()]
        samples[0]["paths"] = ["$WORKSPACE/a.swift"]
        self.assertEqual(actual, samples)
        entry = next(item for item in manifest["files"] if item["path"] == relative)
        self.assertEqual(entry["original_raw_sha256"], MODULE.digest(raw_samples.encode()))
        self.assertEqual(entry["normalized_sha256"], MODULE.digest((self.public / relative).read_bytes()))
        self.assertEqual((self.raw / relative).read_text(), raw_samples)

    def helper_sample(self, pid=12345, identity=1, created=1700000000.25):
        return {
            "start_seconds": 0.5,
            "end_seconds": 0.5001,
            "rss_bytes": 4096,
            "process_count": 1,
            "processes": [{"process_id": identity, "pid": pid, "create_time": created, "rss_bytes": 4096}],
        }

    def write_helper_samples(
        self, samples, helper_hash="03a6cc72657a560e983b95fa99b7df4ff907a6d41f37fcd3692f6ed694d92101"
    ):
        relative = "runs/helper.samples.0001.jsonl"
        raw = "".join(json.dumps(sample) + "\n" for sample in samples)
        self.write(relative, raw)
        self.write(
            "runs/helper.json",
            json.dumps(
                {
                    "schema_version": 2,
                    "measurement_mode": "memory",
                    "helper_sha256": helper_hash,
                    "rss": {
                        "metric": "observed_sampled_near_simultaneous_process_tree_rss_bytes",
                        "sample_chunks": [
                            {
                                "name": Path(relative).name,
                                "sha256": MODULE.digest(raw.encode()),
                                "bytes": len(raw.encode()),
                                "sample_count": len(samples),
                            }
                        ],
                        "sample_count": len(samples),
                        "sample_total_bytes": len(raw.encode()),
                    },
                }
            ),
        )

    def test_helper_identity_requires_verified_known_result(self):
        self.write("runs/helper.samples.0001.jsonl", json.dumps(self.helper_sample()) + "\n")
        self.assert_blocked_without_output("helper-process-identity-unbound")
        self.write_helper_samples([self.helper_sample()], helper_hash="0" * 64)
        self.assert_blocked_without_output("helper-process-identity-unbound")

    def test_legacy_helper_without_creation_identity_is_rejected(self):
        sample = self.helper_sample()
        del sample["processes"][0]["create_time"]
        self.write_helper_samples(
            [sample], helper_hash="6f4e368ba6282ebd4b9591af61ef044ca4574ce217aec1a846fd6698b451fdb3"
        )
        self.assert_blocked_without_output("helper-process-identity-unbound")

    def test_unknown_or_legacy_helper_cleanup_never_leaks_raw_identity(self):
        for helper in ("0" * 64, "6f4e368ba6282ebd4b9591af61ef044ca4574ce217aec1a846fd6698b451fdb3", None):
            with self.subTest(helper=helper):
                self.write("runs/failed.json", json.dumps({
                    "schema_version": 2, "measurement_mode": "timing", "helper_sha256": helper,
                    "status": "failed", "cleanup": {"remaining_observed_pids": [12345], "seconds": 2.5,
                    "method": "identity_checked_individual_TERM_then_STOP_discover_KILL; process-group independent"},
                }))
                self.assert_blocked_without_output("helper-process-identity-unbound")

    def test_malformed_unbound_helper_samples_never_pass_raw_identity(self):
        for sample in ({**self.helper_sample(), "extra": True}, {"processes": [{"pid": 12345}]},
                       {"pid": 12345, "create_time": 1700000000.25}):
            with self.subTest(sample=sample):
                self.write("runs/helper.samples.jsonl", json.dumps(sample) + "\n")
                self.assert_blocked_without_output("helper-process-identity-unbound")

    def test_successor_requires_complete_finite_creation_identity(self):
        for value in (None, 0, -1, True, float("inf")):
            with self.subTest(value=value):
                sample = self.helper_sample(created=value)
                if value is None:
                    del sample["processes"][0]["create_time"]
                self.write_helper_samples([sample])
                self.assert_blocked_without_output("helper-process-identity-schema|invalid-or-ambiguous-jsonl")

    def test_helper_sample_timing_schema_cannot_be_invalid(self):
        for changes in ({"start_seconds": -1}, {"end_seconds": 0.4}, {"start_seconds": True},
                        {"end_seconds": "0.5001"}):
            with self.subTest(changes=changes):
                self.write_helper_samples([{**self.helper_sample(), **changes}])
                self.assert_blocked_without_output("helper-process-identity-schema")

    def test_helper_identity_metadata_is_omitted_without_losing_sample_values(self):
        relative = "runs/helper.samples.0001.jsonl"
        samples = [self.helper_sample(), self.helper_sample(pid=12345, identity=2, created=1700000001.25)]
        raw = "".join(json.dumps(sample) + "\n" for sample in samples)
        self.write(relative, raw)
        self.write(
            "runs/helper.json",
            json.dumps(
                {
                    "schema_version": 2,
                    "measurement_mode": "memory",
                    "status": "failed",
                    "failure": "cleanup_incomplete",
                    "helper_sha256": "03a6cc72657a560e983b95fa99b7df4ff907a6d41f37fcd3692f6ed694d92101",
                    "cleanup": {
                        "seconds": 2.5,
                        "remaining_observed_pids": [12345],
                        "method": "identity_checked_individual_TERM_then_STOP_discover_KILL; process-group independent",
                    },
                    "rss": {
                        "metric": "observed_sampled_near_simultaneous_process_tree_rss_bytes",
                        "sample_chunks": [
                            {
                                "name": Path(relative).name,
                                "sha256": MODULE.digest(raw.encode()),
                                "bytes": len(raw.encode()),
                                "sample_count": len(samples),
                            }
                        ],
                        "sample_count": len(samples),
                        "sample_total_bytes": len(raw.encode()),
                    },
                }
            ),
        )
        before = self.snapshot()
        manifest = MODULE.package(self.args)
        actual = [json.loads(line) for line in (self.public / relative).read_text().splitlines()]
        for sample in samples:
            for member in sample["processes"]:
                del member["pid"], member["create_time"]
        self.assertEqual(actual, samples)
        result = json.loads((self.public / "runs/helper.json").read_text())
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["failure"], "cleanup_incomplete")
        self.assertEqual(result["cleanup"]["seconds"], 2.5)
        self.assertNotIn("remaining_observed_pids", result["cleanup"])
        self.assertEqual(result["cleanup"]["remaining_observed_process_count"], 1)
        self.assertTrue(result["cleanup"]["remaining_identity_unresolved"])
        self.assertEqual(before, self.snapshot())
        self.assertIn("processes[].pid", manifest["omitted_helper_identity_fields"])
        self.assertIn("processes[].create_time", manifest["omitted_helper_identity_fields"])

    def test_identity_transform_is_schema_bound_and_rejects_reassigned_ids(self):
        unrelated = {"pid": 22, "create_time": 4.5, "semantic": "unrelated domain object"}
        self.write("runs/unrelated.json", json.dumps(unrelated))
        MODULE.package(self.args)
        self.assertEqual(json.loads((self.public / "runs/unrelated.json").read_text()), unrelated)
        import shutil

        shutil.rmtree(self.public)
        samples = [self.helper_sample(), self.helper_sample(pid=54321)]
        self.write_helper_samples(samples)
        self.assert_blocked_without_output("helper-process-identity")

    def test_helper_process_ids_remain_injective_and_members_cannot_disappear(self):
        first, second = self.helper_sample(), self.helper_sample(identity=2)
        self.write_helper_samples([first, second])
        self.assert_blocked_without_output("helper-process-identity-not-injective")
        second = self.helper_sample(pid=12346, identity=2)
        first["processes"].extend(second["processes"])
        first["process_count"], first["rss_bytes"] = 2, 8192
        self.write_helper_samples([first])
        MODULE.package(self.args)
        actual = json.loads((self.public / "runs/helper.samples.0001.jsonl").read_text())
        self.assertEqual(actual["process_count"], 2)
        self.assertEqual(actual["rss_bytes"], 8192)
        self.assertEqual([item["process_id"] for item in actual["processes"]], [1, 2])
        self.assertEqual([item["rss_bytes"] for item in actual["processes"]], [4096, 4096])

    def test_bound_helper_result_schema_and_cleanup_fail_closed(self):
        for changes in ({"schema_version": 1}, {"measurement_mode": "legacy"}, {"rss": None},
                        {"cleanup": {"remaining_observed_pids": [12345], "method": "unknown"}},
                        {"cleanup": {"remaining_observed_pids": [12345, 12345], "seconds": 2.5,
                         "method": "identity_checked_individual_TERM_then_STOP_discover_KILL; process-group independent"}},
                        ):
            with self.subTest(changes=changes):
                self.write_helper_samples([self.helper_sample()])
                path = self.raw / "runs/helper.json"
                value = json.loads(path.read_text())
                value.update(changes)
                path.write_text(json.dumps(value))
                self.assert_blocked_without_output("helper-process-identity")

    def test_embedded_memory_requires_exact_verified_standalone_result(self):
        for mutation in (
            lambda value: value.update(status="manufactured-success"),
            lambda value: value["rss"].update(sample_count=100),
            lambda value: value.update(unreviewed_extra=True),
        ):
            self.write_helper_samples([self.helper_sample()])
            value = json.loads((self.raw / "runs/helper.json").read_text())
            value["caller_elapsed_seconds"] = 0.9
            mutation(value)
            self.write("runs/embedded.json", json.dumps({"observed": value}))
            self.assert_blocked_without_output("helper-process-identity-unbound")

    def test_embedded_memory_without_standalone_or_with_ambiguous_copy_blocks(self):
        self.write_helper_samples([self.helper_sample()])
        path = self.raw / "runs/helper.json"
        value = json.loads(path.read_text())
        self.write("runs/embedded.json", json.dumps({"observed": value}))
        path.unlink()
        self.assert_blocked_without_output("helper-process-identity-unbound")
        self.write_helper_samples([self.helper_sample()])
        for name in ("helper.json", "helper.samples.0001.jsonl"):
            self.write("setup/" + name, (self.raw / "runs" / name).read_bytes())
        self.assert_blocked_without_output("helper-process-identity-unbound")

    def test_embedded_memory_caller_elapsed_must_be_finite_nonnegative(self):
        for elapsed in (-1, True, None, float("inf")):
            with self.subTest(elapsed=elapsed):
                self.write_helper_samples([self.helper_sample()])
                value = json.loads((self.raw / "runs/helper.json").read_text())
                value["caller_elapsed_seconds"] = elapsed
                self.write("runs/embedded.json", json.dumps({"observed": value}))
                self.assert_blocked_without_output("helper-process-identity-schema|invalid-or-ambiguous-json")

    def test_unrelated_helper_provenance_does_not_authorize_process_identity(self):
        self.write("setup/provenance.json", json.dumps({
            "helper_sha256": next(iter(MODULE.KNOWN_MEASUREMENT_HELPERS)), "scope": "provenance only",
        }))
        self.write("setup/manifest.json", json.dumps({"helper_sha256": "c" * 64, "machine": {"cores": 4}}))
        MODULE.package(self.args)
        value = json.loads((self.public / "setup/manifest.json").read_text())
        self.assertEqual(value, {"helper_sha256": "c" * 64, "machine": {"cores": 4}})
        import shutil

        shutil.rmtree(self.public)
        self.write("setup/manifest.json", json.dumps({"helper_sha256": "c" * 64,
                                                       "cleanup": {"remaining_observed_pids": [12345]}}))
        self.assert_blocked_without_output("helper-process-identity-unbound")

    def test_nested_process_metadata_cannot_bypass_identity_screen(self):
        for value in ({"nested": {"pid": 12345}}, {"nested": [{"create_time": 1700000000.25}]}):
            with self.subTest(value=value):
                self.write("runs/unbound.samples.jsonl", json.dumps(value) + "\n")
                self.assert_blocked_without_output("helper-process-identity-unbound")
        (self.raw / "runs/unbound.samples.jsonl").unlink()
        self.write("runs/nested.json", json.dumps({"nested": {"cleanup": {"remaining_observed_pids": [12345]}}}))
        self.assert_blocked_without_output("helper-process-identity-unbound")

    def test_known_helper_does_not_exempt_extra_process_metadata(self):
        self.write_helper_samples([self.helper_sample()])
        path = self.raw / "runs/helper.json"
        value = json.loads(path.read_text())
        value["unexpected"] = {"create_time": 1700000000.25}
        path.write_text(json.dumps(value))
        self.assert_blocked_without_output("helper-process-identity-schema")

    def test_helper_identity_binding_spans_all_chunks(self):
        self.write_helper_samples([self.helper_sample()])
        second = self.helper_sample(pid=23456)
        data = json.dumps(second) + "\n"
        name = "helper.samples.0002.jsonl"
        self.write("runs/" + name, data)
        path = self.raw / "runs/helper.json"
        value = json.loads(path.read_text())
        rss = value["rss"]
        rss["sample_chunks"].append({"name": name, "sha256": MODULE.digest(data.encode()),
                                     "bytes": len(data), "sample_count": 1})
        rss["sample_count"] += 1
        rss["sample_total_bytes"] += len(data)
        path.write_text(json.dumps(value))
        self.assert_blocked_without_output("helper-process-identity-reassigned")

    def test_chunk_duplicate_noncontiguous_and_corruption_block(self):
        for mutation in (lambda chunks: chunks.append(chunks[0]),
                         lambda chunks: chunks[1].update(name="memory.samples.0003.jsonl")):
            result = self.chunked_memory()
            mutation(result["rss"]["sample_chunks"])
            self.write("runs/memory.json", json.dumps(result))
            self.assert_blocked_without_output("sample-chunk-integrity")
        self.chunked_memory()
        self.write("runs/memory.samples.0001.jsonl", '{"time": 99}\n')
        self.assert_blocked_without_output("sample-chunk-integrity")

    def test_cleanup_only_timing_failure_keeps_counts_and_failure(self):
        self.write("runs/timing.json", json.dumps({
            "schema_version": 2, "measurement_mode": "timing", "status": "failed", "failure": "cleanup_incomplete",
            "helper_sha256": "03a6cc72657a560e983b95fa99b7df4ff907a6d41f37fcd3692f6ed694d92101", "rss": None,
            "cleanup": {"remaining_observed_pids": [12345], "seconds": 2.5,
                "method": "identity_checked_individual_TERM_then_STOP_discover_KILL; process-group independent"},
        }))
        MODULE.package(self.args)
        value = json.loads((self.public / "runs/timing.json").read_text())
        self.assertEqual(value["status"], "failed")
        self.assertEqual(value["failure"], "cleanup_incomplete")
        self.assertEqual(value["cleanup"]["seconds"], 2.5)
        self.assertEqual(value["cleanup"]["remaining_observed_process_count"], 1)
        self.assertTrue(value["cleanup"]["remaining_identity_unresolved"])
        self.assertNotIn("remaining_observed_pids", value["cleanup"])

    def test_jsonl_rotated_sample_chunks_are_included(self):
        for number in (1, 2):
            self.write(f"runs/tree.samples.{number:04d}.jsonl", json.dumps({"sequence": number}) + "\n")
        manifest = MODULE.package(self.args)
        selected = {item["path"] for item in manifest["files"]}
        self.assertTrue({"runs/tree.samples.0001.jsonl", "runs/tree.samples.0002.jsonl"} <= selected)

    def test_jsonl_empty_file_is_valid_zero_samples_but_blank_lines_fail(self):
        self.write("runs/empty.samples.jsonl", "")
        MODULE.package(self.args)
        self.assertEqual((self.public / "runs/empty.samples.jsonl").read_text(), "")
        self.public = self.root / "another-public"
        self.args.output = self.public
        self.write("runs/empty.samples.jsonl", "\n")
        self.assert_blocked_without_output("invalid-or-ambiguous-jsonl")

    def test_jsonl_malformed_duplicate_nonfinite_and_nonobject_values_block(self):
        for value in ('{"x":1,"x":2}\n', '{"x":NaN}\n', '{"x":1e999}\n',
                      "{}\nnot-json\n", "[1,2]\n", "null\n"):
            with self.subTest(value=value):
                self.write("runs/bad.samples.jsonl", value)
                self.assert_blocked_without_output("invalid-or-ambiguous-jsonl")

    def test_jsonl_escaped_credentials_and_unmapped_paths_block(self):
        self.write("runs/bad.samples.jsonl", '{"GITHUB\\u005fTOKEN":"synthetic-credential-only"}\n')
        self.assert_blocked_without_output("credential-json-field")
        self.write("runs/bad.samples.jsonl", '{"path":"/unmapped/secret-workspace/file"}\n')
        self.assert_blocked_without_output("unmapped-absolute-path")

    def test_jsonl_missing_sample_reference_blocks(self):
        self.values["samples"] = str(self.raw / "runs/missing.samples.jsonl")
        self.write("results.json", json.dumps(self.values))
        self.assert_blocked_without_output("log-reference-not-in-public-bundle")

    def test_arbitrary_jsonl_is_not_silently_selected(self):
        self.write("runs/unrelated.jsonl", '{"unrelated":true}\n')
        manifest = MODULE.package(self.args)
        self.assertNotIn("runs/unrelated.jsonl", {item["path"] for item in manifest["files"]})

    def chunked_memory(self):
        chunks = []
        for number in (1, 2):
            name = f"memory.samples.{number:04d}.jsonl"
            data = json.dumps({"time": number, "rss_bytes": number * 1024}) + "\n"
            self.write("runs/" + name, data)
            chunks.append({"name": name, "sha256": MODULE.digest(data.encode()), "bytes": len(data), "sample_count": 1})
        result = {
            "rss": {"sample_chunks": chunks, "sample_total_bytes": sum(c["bytes"] for c in chunks), "sample_count": 2}
        }
        self.write("runs/memory.json", json.dumps(result))
        return result

    def test_chunk_manifest_is_verified_against_complete_raw_evidence(self):
        self.chunked_memory()
        manifest = MODULE.package(self.args)
        self.assertEqual(manifest["verified_sample_chunk_results"], ["runs/memory.json"])

    def test_chunk_missing_extra_reordered_or_wrong_metadata_blocks(self):
        mutations = [
            lambda rss: rss["sample_chunks"].reverse(),
            lambda rss: rss["sample_chunks"][0].update(sha256="0" * 64),
            lambda rss: rss["sample_chunks"][0].update(bytes=1),
            lambda rss: rss["sample_chunks"][0].update(sample_count=2),
            lambda rss: rss.update(sample_total_bytes=1),
            lambda rss: rss.update(sample_count=1),
            lambda rss: rss["sample_chunks"].pop(),
            lambda rss: rss["sample_chunks"][0].update(name="../memory.samples.0001.jsonl"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                result = self.chunked_memory()
                mutate(result["rss"])
                self.write("runs/memory.json", json.dumps(result))
                self.assert_blocked_without_output("sample-chunk-integrity")
        self.chunked_memory()
        (self.raw / "runs/memory.samples.0001.jsonl").unlink()
        self.assert_blocked_without_output("sample-chunk-integrity")

    def test_unlisted_chunk_blocks_even_if_manifest_otherwise_valid(self):
        self.chunked_memory()
        self.write("runs/memory.samples.0003.jsonl", '{"time":3}\n')
        self.assert_blocked_without_output("sample-chunk-integrity")

    def test_unlisted_legacy_sample_file_cannot_hide_next_to_chunk_manifest(self):
        self.chunked_memory()
        self.write("runs/memory.samples.jsonl", '{"time":0}\n')
        self.assert_blocked_without_output("sample-chunk-integrity")

    def test_values_paths_hashes_and_originals_preserved(self):
        original = self.snapshot()
        manifest = MODULE.package(self.args)
        self.assertEqual(self.snapshot(), original)
        normalized = json.loads((self.public / "results.json").read_text())
        for key in ("status", "returncode", "timed_out", "wall_seconds", "wait4_maxrss_bytes"):
            self.assertEqual(normalized[key], self.values[key])
        self.assertEqual(normalized["cwd"], "$WORKSPACE")
        self.assertEqual(
            normalized["command"], ["$TOOLCHAIN/usr/bin/swift", "-I$CACHE/modules", "$WORKSPACE/file.swift"]
        )
        self.assertEqual(normalized["stdout"], "runs/query.stdout")
        self.assertEqual(json.loads((self.public / "runs/query.stdout").read_text())["stdout"], "setup/build.stderr")
        self.assertIn(
            "Failure at $WORKSPACE/Sources/File.swift:7; elapsed=1.25", (self.public / "setup/build.stderr").read_text()
        )
        for item in manifest["files"]:
            self.assertEqual(item["original_raw_sha256"], original[item["path"]])
            self.assertEqual(item["normalized_sha256"], MODULE.digest((self.public / item["path"]).read_bytes()))
        joined = "\n".join(path.read_text() for path in self.public.rglob("*") if path.is_file())
        self.assertNotIn(str(self.root), joined)

    def test_binary_indexes_objects_builds_are_excluded(self):
        manifest = MODULE.package(self.args)
        selected = {item["path"] for item in manifest["files"]}
        self.assertEqual(len(selected), 7)
        self.assertFalse(
            any("index-store" in path or path.endswith(".o") or "release-build" in path for path in selected)
        )
        self.assertFalse((self.public / "fixtures/basic/.build/fixture").exists())

    def test_public_project_observations_have_relative_references(self):
        self.write("setup/cartograph.yml", 'include: ["Sources/**"]\n')
        self.write("runs/normalized.json", '{"answer": [1]}')
        self.write("runs/graph-cache.json", '{"edges": []}')
        self.write(
            "runs/observation.json",
            json.dumps(
                {
                    "normalized_result": str(self.raw / "runs/normalized.json"),
                    "graph": str(self.raw / "runs/graph-cache.json"),
                    "cg_config": str(self.raw / "setup/cartograph.yml"),
                }
            ),
        )
        MODULE.package(self.args)
        observation = json.loads((self.public / "runs/observation.json").read_text())
        self.assertEqual(
            observation,
            {
                "normalized_result": "runs/normalized.json",
                "graph": "runs/graph-cache.json",
                "cg_config": "setup/cartograph.yml",
            },
        )
        self.assertTrue((self.public / observation["cg_config"]).is_file())

    def test_exact_clang_help_flag_is_preserved_without_path_exemption(self):
        line = "  --show-includes         Print cl.exe style /showIncludes to stdout\n"
        self.assertEqual(MODULE.digest(b"/showIncludes")[:16], "4481f48fee5de938")
        self.write("setup/clang-frontend-help.stdout", line)
        MODULE.package(self.args)
        self.assertEqual((self.public / "setup/clang-frontend-help.stdout").read_text(), line)

    def test_clang_help_exception_cannot_hide_another_path(self):
        for line in (
            "  --show-includes         Print cl.exe style /showIncludes/private to stdout\n",
            "  --show-includes         Print cl.exe style /showIncludes to stdout /unknown/private\n",
            "  --show-includes /unknown/private Print cl.exe style /showIncludes to stdout\n",
            "/showIncludes\n",
        ):
            with self.subTest(line=line):
                self.write("setup/clang-frontend-help.stdout", line)
                self.assert_blocked_without_output("unmapped-absolute-path")

    def test_clang_help_exception_is_artifact_scoped(self):
        self.write("setup/other.stdout", "  --show-includes         Print cl.exe style /showIncludes to stdout\n")
        self.assert_blocked_without_output("unmapped-absolute-path")

    def test_clang_help_exception_does_not_skip_credential_screen(self):
        for separator in (" ", "\n"):
            with self.subTest(separator=separator):
                self.write(
                    "setup/clang-frontend-help.stdout",
                    "  --show-includes         Print cl.exe style /showIncludes to stdout"
                    + separator
                    + '{"\\u0041WS_SECRET_ACCESS_KEY":"synthetic-only"}',
                )
                self.assert_blocked_without_output("credential-json-field")

    def test_complete_official_compiler_help_corpus_preserves_bytes(self):
        corpus = SCRIPT.parents[1] / "Fixtures/IndexStoreCLIBenchmark/compiler-help-validation"
        manifest = json.loads((corpus / "manifest.json").read_text())
        for item in manifest["files"]:
            data = (corpus / item["path"]).read_bytes()
            self.assertEqual(MODULE.digest(data), item["sha256"])
            self.assertEqual(len(data), item["bytes"])
            self.write("setup/" + item["path"], data)
        MODULE.package(self.args)
        for item in manifest["files"]:
            self.assertEqual((self.public / "setup" / item["path"]).read_bytes(), (corpus / item["path"]).read_bytes())

    def test_swift_help_tokens_do_not_exempt_suffixes_neighbors_or_generic_text(self):
        profile = "  Generate instrumented code to collect execution counts into <directory>/default.profraw (overridden by LLVM_PROFILE_FILE env var)"
        language = "  -Xcc <arg>              Pass <arg> to the C/C++/Objective-C compiler"
        for text in (
            profile.replace("/default.profraw", "/default.profraw/private"),
            profile + " /Users/private/file",
            profile.replace("<directory>", "<arbitrary>"),
            language.replace("/Objective-C", "/Objective-C/private"),
            language + " /Users/private/file",
            "C/C++/Objective-C",
            "<directory>/default.profraw",
        ):
            with self.subTest(text=text):
                self.write("setup/swift-help.stdout", text + "\n")
                self.assert_blocked_without_output("unmapped-absolute-path")
        self.write("setup/swift-help.stdout", "safe\n")
        self.write("setup/other-help.stdout", profile + "\n" + language + "\n")
        self.assert_blocked_without_output("unmapped-absolute-path")

    def test_swift_help_tokens_still_screen_escaped_credentials(self):
        self.write(
            "setup/swift-help.stdout",
            "  -Xcc <arg>              Pass <arg> to the C/C++/Objective-C compiler "
            '{"\\u0041WS_SESSION_TOKEN":"synthetic-only"}',
        )
        self.assert_blocked_without_output("credential-json-field")

    def test_mapped_compiler_libcxx_absence_witness_preserves_paths(self):
        developer = "/Applications/Xcode_26.6.app/Contents/Developer"
        self.args.prefix.append("DEVELOPER=" + developer)
        suffixes = [
            "/Toolchains/XcodeDefault.xctoolchain/usr/include/c++/v1",
            "/Toolchains/XcodeDefault.xctoolchain/usr/bin/../include/c++/v1",
        ]
        relative = "setup/original/raw/before-compilation/results.json"
        witness = {"canonical_path": developer + suffixes[0], "lexical_path": developer + suffixes[1], "exists": False}
        raw = json.dumps(witness)
        self.write(relative, raw)
        before = self.snapshot()
        manifest = MODULE.package(self.args)
        expected = {"canonical_path": "$DEVELOPER" + suffixes[0], "lexical_path": "$DEVELOPER" + suffixes[1], "exists": False}
        self.assertEqual(json.loads((self.public / relative).read_text()), expected)
        self.assertEqual(self.snapshot(), before)
        entry = next(item for item in manifest["files"] if item["path"] == relative)
        self.assertEqual(entry["original_raw_sha256"], MODULE.digest(raw.encode()))
        self.assertEqual(entry["normalized_sha256"], MODULE.digest((self.public / relative).read_bytes()))
        self.assertEqual(MODULE.digest(b"/v1"), "2d234c97703ce824eaa4d98fbd2701668ef5e63e46f1574f2ea72e7927b1f57e")

    def test_mapped_path_validation_preserves_exact_public_text(self):
        paths = [
            str(self.toolchain) + suffix for suffix in (
                "/usr/include/c++/v1", "/usr/bin/../include/c++/v1", "/a/.././b+/v1/",
            )
        ]
        paths.extend(["/usr/include/c++/v1", "file://" + str(self.toolchain) + "/usr/include/c++/v1"])
        text = "\n".join(paths + ["-I" + paths[0], "[" + paths[0] + ", '" + paths[1] + "']"]) + "\n"
        self.write("runs/mapped.stdout", text)
        before = self.snapshot()
        MODULE.package(self.args)
        expected = text.replace(str(self.toolchain), "$TOOLCHAIN").replace("\n/usr/include", "\n$SYSTEM_INCLUDE")
        self.assertEqual((self.public / "runs/mapped.stdout").read_text(), expected)
        self.assertEqual(self.snapshot(), before)

    def test_unsupported_python_paths_preserve_prior_public_tokens(self):
        self.args.prefix.append("OPT=/opt")
        suffixes = [
            "/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/bin/python3.14",
            "/homebrew/opt/python@3.14/bin/python3.14",
        ]
        self.assertEqual([MODULE.digest(s.encode()) for s in suffixes], [
            "f8240862f65b6fd9a3e9fec3656680528b49a33325a8cb109452e0950292db9c",
            "c76bd4634343cc0aa8bcba770ac21fd3a4c1004651d9767583f81e7237d64647",
        ])
        self.write("results.json", json.dumps({"interpreters": ["/opt" + suffix for suffix in suffixes]}))
        before = self.snapshot()
        MODULE.package(self.args)
        self.assertEqual(json.loads((self.public / "results.json").read_text()), {
            "interpreters": ["$OPT" + suffix for suffix in suffixes],
        })
        self.assertEqual(self.snapshot(), before)

    def test_unsupported_mapped_suffixes_preserve_legacy_output(self):
        normalizer = MODULE.Normalizer(self.args, self.raw, [], [])
        for suffix in (
            "/Python@3.14/bin/python", "/Application Support/data", "/name%2Fvalue/item",
            "/name=value/item", "/name:revision/item", "/caf\u00e9-name/item", "/name~value/item",
            "/name#value/item", "/name?value/item",
        ):
            with self.subTest(suffix=suffix):
                value = str(self.toolchain) + suffix
                self.assertEqual(normalizer.string(value, "runs/mapped.stdout"), "$TOOLCHAIN" + suffix)
                for separator in (" ", "=", ":", "'", '"', ",", ";", "]"):
                    with self.subTest(separator=separator):
                        category = "unmapped-windows-absolute-path" if separator == ":" else "unmapped-absolute-path"
                        with self.assertRaisesRegex(MODULE.PublicationBlocked, category):
                            normalizer.string(value + separator + "/unknown/private", "runs/mapped.stdout")

        # 기존 ASCII 경계 검사에서 거부하던 비 ASCII 문자 뒤의 '/'는 유지한다.
        with self.assertRaisesRegex(MODULE.PublicationBlocked, "unmapped-absolute-path"):
            normalizer.string(str(self.toolchain) + "/caf\u00e9/item", "runs/mapped.stdout")

    def test_unsupported_mapped_suffixes_keep_sensitive_and_windows_guards(self):
        for suffix in ("/Python@3.14/bin/python", "/Application Support/data", "/name%2Fvalue/item"):
            for tail, category in (
                (" password=synthetic-only", "secret-assignment"),
                (r" C:\Users\private\file", "unmapped-windows-absolute-path"),
                ("\x000\x00", "unexpected-control-or-binary-content"),
                (" https://example.invalid/?to%6ben=synthetic", "token-bearing-or-signed-url"),
            ):
                with self.subTest(suffix=suffix, category=category):
                    self.write("runs/mapped.stdout", str(self.toolchain) + suffix + tail)
                    self.assert_blocked_without_output(category)

    def test_mapped_path_trust_requires_actual_prefix_replacement(self):
        for value in (
            "/unknown/include/c++/v1", "$TOOLCHAIN/usr/include/c++/v1", "$UNKNOWN/usr/include/c++/v1",
            str(self.toolchain) + "-sibling/include/c++/v1", str(self.toolchain) + "_sibling/include/c++/v1",
            str(self.toolchain) + "X/include/c++/v1", str(self.toolchain) + "/unsafe%2fcomponent/c++/v1",
        ):
            with self.subTest(value=value):
                self.write("runs/mapped.stdout", value)
                self.assert_blocked_without_output("unmapped-absolute-path")

    def test_broad_root_cannot_mask_specific_alias_siblings(self):
        alias = str(self.toolchain) + "/usr/include/c++/v1"
        self.args.prefix.append("CXX_HEADERS=" + alias)
        normalizer = MODULE.Normalizer(self.args, self.raw, [], [])
        self.assertEqual(normalizer.string(alias, "runs/mapped.stdout"), "$CXX_HEADERS")
        self.assertEqual(normalizer.string(alias + "/vector", "runs/mapped.stdout"), "$CXX_HEADERS/vector")
        for suffix in ("-unreviewed", "_unreviewed", "X", "+private"):
            with self.subTest(suffix=suffix):
                self.write("runs/mapped.stdout", alias + suffix)
                self.assert_blocked_without_output("unmapped-absolute-path")

    def test_mapped_path_above_root_traversal_is_refused(self):
        for suffix in ("/../outside", "/a/../../outside", "/./../outside", "/a/../..", "/../../include/c++/v1"):
            with self.subTest(suffix=suffix):
                self.write("runs/mapped.stdout", str(self.toolchain) + suffix)
                self.assert_blocked_without_output("unmapped-absolute-path")

    def test_mapped_path_does_not_hide_appended_unmapped_paths(self):
        mapped = str(self.toolchain) + "/usr/include/c++/v1"
        for separator in (":", "=", " ", "\t", "\n", "'", '"', "`", ",", ";", ")", "]", "}", "|", ">"):
            with self.subTest(separator=separator):
                self.write("runs/mapped.stdout", mapped + separator + "/unknown/private/file")
                self.assert_blocked_without_output("unmapped-absolute-path")

    def test_mapped_path_keeps_windows_secret_and_control_screening(self):
        mapped = str(self.toolchain) + "/usr/include/c++/v1"
        cases = [
            (mapped + r" C:\Users\private\file", "unmapped-windows-absolute-path"),
            (mapped + r"/C:\Users\private\file", "unmapped-windows-absolute-path"),
            (mapped + r" \\server\private", "unmapped-windows-absolute-path"),
            (mapped + "/ghp_" + "a" * 24, "github-token"),
            (mapped + " password=synthetic-only", "secret-assignment"),
            (mapped + " https://example.invalid/?to%6ben=synthetic", "token-bearing-or-signed-url"),
            ("\x000\x00/usr/include/c++/v1", "unexpected-control-or-binary-content"),
            (mapped + "\x00", "unexpected-control-or-binary-content"),
        ]
        for value, category in cases:
            with self.subTest(category=category):
                self.write("runs/mapped.stdout", value)
                self.assert_blocked_without_output(category)
        self.write("runs/mapped.stdout", "safe")
        self.write("runs/mapped.json", json.dumps({"path": mapped + "\x001\x00"}))
        self.assert_blocked_without_output("unexpected-control-or-binary-content")

    def test_mapped_path_cannot_bypass_existing_bundle_caps(self):
        from unittest.mock import patch
        self.assertEqual((MODULE.MAX_FILES, MODULE.MAX_FILE_BYTES, MODULE.MAX_TOTAL_BYTES), (10_000, 8 * 1024 * 1024, 64 * 1024 * 1024))
        self.write("runs/mapped.stdout", str(self.toolchain) + "/usr/include/c++/v1")
        for name, cap, category in (
            ("MAX_FILES", 1, "file-count-limit"),
            ("MAX_FILE_BYTES", 1, "per-file-size-limit"),
            ("MAX_TOTAL_BYTES", 1, "total-size-limit"),
        ):
            with self.subTest(name=name), patch.object(MODULE, name, cap):
                self.assert_blocked_without_output(category)

    def test_unmapped_absolute_path_blocks(self):
        self.write("setup/build.stderr", "Failure: /Users/unknown-person/private/file.swift\n")
        self.assert_blocked_without_output("unmapped-absolute-path")

    def test_unmapped_file_url_and_windows_path_block(self):
        for value in ("file:///Users/unknown/file.swift", r"C:\Users\unknown\file.swift"):
            with self.subTest(value=value):
                self.write("setup/build.stderr", value)
                self.assert_blocked_without_output("unmapped")

    def test_known_secret_json_fields_block_even_one_or_two(self):
        for fields in (
            {"AWS_SECRET_ACCESS_KEY": "synthetic-only"},
            {"AWS_SESSION_TOKEN": "synthetic-one", "GITHUB_TOKEN": "synthetic-two"},
            {"accessToken": "synthetic-three"},
        ):
            with self.subTest(fields=fields):
                self.write("runs/credentials.json", json.dumps(fields))
                self.assert_blocked_without_output("credential-json-field|credential-field-or-assignment")

    def test_escaped_credential_key_is_checked_after_parsing(self):
        self.write("runs/escaped.json", r'{"\u0041WS_SECRET_ACCESS_KEY": "synthetic-only"}')
        self.assert_blocked_without_output("credential-json-field")

    def test_signed_url_and_encoded_token_parameters_block(self):
        for query in (
            "token=synthetic",
            "X-Amz-Security-Token=synthetic",
            "signature=synthetic",
            "sig=synthetic",
            "to%6ben=synthetic",
            "X-Amz-Credential=synthetic",
        ):
            with self.subTest(query=query):
                self.write("setup/build.stderr", "https://example.invalid/evidence?" + query)
                self.assert_blocked_without_output("token-bearing-or-signed-url|credential-field-or-assignment")

    def test_raw_secret_and_environment_dump_block(self):
        for text in (
            "GITHUB_TOKEN=synthetic-only\n",
            "Authorization: Bearer synthetic-only-value-12345\n",
            "HOME=/known\nUSER=synthetic\nPATH=/known\n",
        ):
            with self.subTest(text=text):
                self.write("setup/build.stderr", text)
                self.assert_blocked_without_output("environment-dump|bearer-token")

    def test_single_raw_credential_assignment_and_uppercase_url_block(self):
        for value in (
            "AWS_SESSION_TOKEN=synthetic-only",
            "apiToken: synthetic-only",
            "HTTPS://example.invalid/evidence?token=synthetic",
        ):
            with self.subTest(value=value):
                self.write("setup/build.stderr", value)
                self.assert_blocked_without_output("credential-field-or-assignment|token-bearing-or-signed-url")

    def test_binary_disguised_as_log_blocks(self):
        self.write("runs/bad.stdout", b"\x00binary")
        self.assert_blocked_without_output("binary-content")

    def test_nonempty_output_is_never_overwritten(self):
        self.public.mkdir()
        (self.public / "keep.txt").write_text("keep")
        with self.assertRaisesRegex(MODULE.PublicationBlocked, "absent or empty"):
            MODULE.package(self.args)
        self.assertEqual((self.public / "keep.txt").read_text(), "keep")

    def test_missing_log_reference_blocks(self):
        value = copy.deepcopy(self.values)
        value["stdout"] = str(self.raw / "runs/missing.stdout")
        self.write("results.json", json.dumps(value))
        self.assert_blocked_without_output("log-reference-not-in-public-bundle")

    def test_division_operator_dump_is_not_a_file_path(self):
        text = (
            "Symbols:\n/(_:_:) | staticMethod | usr | reference, call\n"
            "Occurrences:\n3:20 | /(_:_:) | staticMethod | usr | call\n"
        )
        self.write("runs/division.stdout", text)
        MODULE.package(self.args)
        self.assertEqual((self.public / "runs/division.stdout").read_text(), text)

    def test_duplicate_json_and_symlink_inputs_block(self):
        self.write("runs/duplicate.json", '{"a": 1, "a": 2}')
        self.assert_blocked_without_output("invalid-or-ambiguous-json")
        (self.raw / "runs/duplicate.json").unlink()
        (self.raw / "runs/linked.stdout").symlink_to(self.raw / "runs/query.stdout")
        self.assert_blocked_without_output("symlink-artifact")


if __name__ == "__main__":
    unittest.main(verbosity=2)
