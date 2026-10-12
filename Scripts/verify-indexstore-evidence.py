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
