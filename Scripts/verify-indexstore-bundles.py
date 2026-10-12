#!/usr/bin/env python3
"""한 묶음의 공개 차단이 독립적인 증거와 안전한 실패 지문을 숨기지 않는지 검증한다."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("normalize-indexstore-bundles.py")
SPEC = importlib.util.spec_from_file_location("normalize_indexstore_bundles", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.public = self.root / "public"
        self.github_output = self.root / "github-output"

    def tearDown(self):
        self.temporary.cleanup()

    def raw(self, name, values=None):
        directory = self.root / name
        directory.mkdir(parents=True)
        (directory / "results.json").write_text(json.dumps(values or {"status": "ok", "count": 4}))
        return directory

    def argv(self, **inputs):
        values = ["--output", str(self.public), "--github-output", str(self.github_output)]
        for name, value in inputs.items():
            values.extend(["--" + name.replace("_", "-"), str(value)])
        return values

    def run_main(self, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = MODULE.main(argv)
        return code, stdout.getvalue() + stderr.getvalue()

    def statuses(self):
        manifest = json.loads((self.public / "bundle-status.json").read_text())
        return manifest, {item["name"]: item for item in manifest["bundles"]}

    def published_text(self):
        return "\n".join(path.read_text() for path in sorted(self.public.rglob("*")) if path.is_file())

    def test_good_bundle_survives_blocked_peer_with_hash_only_diagnostics(self):
        good = self.raw("good")
        private_path = "/Users/unmapped-person/private/source.swift"
        blocked = self.raw("blocked", {"source": private_path})
        raw_data = (blocked / "results.json").read_bytes()
        code, logs = self.run_main(self.argv(synthetic=good, argument_parser=blocked))
        manifest, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["status"], "normalized_for_review")
        self.assertEqual(states["argument-parser"]["status"], "blocked")
        self.assertEqual(states["argument-parser"]["diagnostic"]["reason"], "unmapped-absolute-path")
        self.assertEqual(manifest["blocked_bundles"], 1)
        inventory = states["argument-parser"]["raw_inventory"]
        self.assertEqual(inventory["file_count"], 1)
        self.assertEqual(inventory["total_bytes"], len(raw_data))
        self.assertEqual(inventory["files"][0]["original_raw_sha256"], hashlib.sha256(raw_data).hexdigest())
        self.assertTrue((self.public / "synthetic/results.json").is_file())
        self.assertFalse((self.public / "argument-parser").exists())
        self.assertEqual(self.github_output.read_text(), "ready=true\n")
        for private in (str(self.root), private_path, "unmapped-person"):
            self.assertNotIn(private, self.published_text() + logs)
        self.assertEqual((blocked / "results.json").read_bytes(), raw_data)

    def test_blocked_first_bundle_does_not_skip_later_success(self):
        blocked = self.raw("blocked", {"password": "synthetic-secret-value"})
        good = self.raw("good")
        code, logs = self.run_main(self.argv(synthetic=blocked, mixed_ios=good))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["mixed-ios"]["status"], "normalized_for_review")
        self.assertEqual(states["synthetic"]["status"], "blocked")
        self.assertNotIn("synthetic-secret-value", self.published_text() + logs)
        self.assertFalse((self.public / "synthetic").exists())

    def test_partial_normalizer_filesystem_failure_is_never_published(self):
        failing, good = self.raw("failing"), self.raw("good")
        original = MODULE.EVIDENCE.package

        def fail_after_write(args):
            if args.input.resolve() == failing:
                args.output.mkdir(parents=True)
                (args.output / "partial.stdout").write_bytes(b"RAW PRIVATE BYTES\x00")
                raise OSError(28, "No space: /Users/private-person/secret")
            return original(args)

        with mock.patch.object(MODULE.EVIDENCE, "package", side_effect=fail_after_write):
            code, logs = self.run_main(self.argv(synthetic=failing, mixed_ios=good))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["diagnostic"]["reason"], "filesystem-error")
        self.assertEqual(states["synthetic"]["diagnostic"]["errno"], 28)
        self.assertEqual(states["mixed-ios"]["status"], "normalized_for_review")
        self.assertFalse((self.public / "synthetic").exists())
        self.assertNotIn("PRIVATE", self.published_text() + logs)
        self.assertNotIn("private-person", self.published_text() + logs)
        self.assertFalse(list(self.root.glob(".indexstore-public-*")))

    def test_actual_partial_write_failure_keeps_only_complete_bundle(self):
        failing, good = self.raw("failing"), self.raw("good")
        (failing / "setup").mkdir()
        (failing / "setup/first.stdout").write_text("already validated\n")
        (failing / "setup/second.stdout").write_text("still validated\n")
        original = Path.open
        observed_partial = []

        def fail_open(path, mode="r", *args, **kwargs):
            if "pending" in path.parts and path.name == "second.stdout" and mode == "xb":
                observed_partial.append((path.parent / "first.stdout").exists())
                raise OSError(28, "disk full")
            return original(path, mode, *args, **kwargs)

        with mock.patch.object(Path, "open", fail_open):
            code, _ = self.run_main(self.argv(synthetic=failing, mixed_setup=good))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(observed_partial, [True])
        self.assertEqual(states["synthetic"]["status"], "blocked")
        self.assertTrue((self.public / "mixed-setup/manifest.json").is_file())
        self.assertFalse((self.public / "synthetic").exists())

    def test_binary_and_raw_build_files_have_no_fallback(self):
        raw = self.raw("raw", {"accessToken": "synthetic-secret"})
        binary = raw / "build/records/blob"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"\x00RAW-INDEX-SECRET\xff")
        code, logs = self.run_main(self.argv(synthetic=raw))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["raw_inventory"]["file_count"], 1)
        self.assertEqual({p.name for p in self.public.iterdir()}, {"bundle-status.json"})
        for value in ("synthetic-secret", "RAW-INDEX-SECRET", "build/records/blob"):
            self.assertNotIn(value, self.published_text() + logs)

    def test_nonempty_output_preserved_and_not_marked_ready(self):
        raw = self.raw("raw")
        self.public.mkdir()
        (self.public / "bundle-status.json").write_text("preexisting unsafe text")
        (self.public / "keep.txt").write_bytes(b"keep\x00")
        before = {p.name: p.read_bytes() for p in self.public.iterdir()}
        code, _ = self.run_main(self.argv(synthetic=raw))
        self.assertEqual(code, 2)
        self.assertEqual({p.name: p.read_bytes() for p in self.public.iterdir()}, before)
        self.assertFalse(self.github_output.exists())

    def test_empty_output_can_be_atomically_replaced(self):
        raw = self.raw("raw")
        self.public.mkdir()
        code, _ = self.run_main(self.argv(synthetic=raw))
        self.assertEqual(code, 0)
        self.assertTrue((self.public / "synthetic/manifest.json").is_file())

    def test_symlink_output_is_not_followed(self):
        raw = self.raw("raw")
        target = self.root / "existing-empty"
        target.mkdir()
        self.public.symlink_to(target, target_is_directory=True)
        code, _ = self.run_main(self.argv(synthetic=raw))
        self.assertEqual(code, 2)
        self.assertTrue(self.public.is_symlink())
        self.assertEqual(list(target.iterdir()), [])
        self.assertFalse(self.github_output.exists())

    def test_input_and_output_aliases_normalize_both_path_spellings(self):
        real = self.root / "real"
        real.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(real, target_is_directory=True)
        raw = real / "raw"
        raw.mkdir()
        (raw / "results.json").write_text(
            json.dumps({"provided": str(alias / "raw/source.swift"), "resolved": str(raw / "source.swift")})
        )
        self.public = alias / "public"
        code, logs = self.run_main(self.argv(synthetic=alias / "raw"))
        self.assertEqual(code, 0)
        result = json.loads((real / "public/synthetic/results.json").read_text())
        self.assertEqual(result, {"provided": "$EVIDENCE/source.swift", "resolved": "$EVIDENCE/source.swift"})
        self.assertNotIn(str(self.root), self.published_text() + logs)

    def test_missing_and_unrequested_inputs_have_explicit_status(self):
        code, _ = self.run_main(self.argv(synthetic=self.root / "missing"))
        manifest, states = self.statuses()
        self.assertEqual(code, 0)
        self.assertEqual(states["synthetic"]["status"], "unavailable")
        self.assertEqual(states["synthetic"]["diagnostic"]["reason"], "input-missing")
        for name in ("argument-parser", "mixed-setup", "mixed-ios"):
            self.assertEqual(states[name]["status"], "skipped")
        self.assertEqual(manifest["normalized_bundles"], 0)
        self.assertEqual(manifest["blocked_bundles"], 0)
        self.assertEqual(manifest["unavailable_bundles"], 1)
        self.assertEqual(manifest["skipped_bundles"], 3)
        self.assertEqual(manifest["status"], "publication_prepared")
        self.assertIs(manifest["complete_run_evidence"], False)

    def test_unresolvable_input_does_not_discard_independent_success(self):
        loop = self.root / "symlink-loop"
        loop.symlink_to(loop)
        good = self.raw("good")
        code, logs = self.run_main(self.argv(synthetic=loop, mixed_ios=good))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["status"], "blocked")
        self.assertEqual(states["mixed-ios"]["status"], "normalized_for_review")
        self.assertNotIn(str(self.root), self.published_text() + logs)

    def test_existing_non_directory_input_is_a_failure(self):
        raw = self.root / "file-input"
        raw.write_text("not a directory")
        code, _ = self.run_main(self.argv(synthetic=raw))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["status"], "blocked")
        self.assertFalse((self.public / "synthetic").exists())

    def test_unreadable_or_symlinked_candidate_has_unavailable_inventory(self):
        raw = self.raw("raw")
        (raw / "setup").symlink_to(self.root, target_is_directory=True)
        code, _ = self.run_main(self.argv(synthetic=raw))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["raw_inventory"]["status"], "unavailable")
        self.assertFalse((self.public / "synthetic").exists())

    def test_input_output_overlap_through_alias_fails_without_changes(self):
        raw = self.raw("raw")
        alias = self.root / "alias"
        alias.symlink_to(raw, target_is_directory=True)
        self.public = alias / "public"
        before = (raw / "results.json").read_bytes()
        code, _ = self.run_main(self.argv(synthetic=raw))
        self.assertEqual(code, 2)
        self.assertEqual((raw / "results.json").read_bytes(), before)
        self.assertFalse(self.public.exists())
        self.assertFalse(self.github_output.exists())

    def test_project_synthetic_prefix_is_scoped_and_not_duplicated(self):
        synthetic = self.raw("synthetic")
        project = self.raw("project", {"setup_results": str(synthetic / "results.json")})
        mixed_setup = self.raw("mixed-setup")
        mixed_ios = self.raw("mixed-ios")
        alias = self.root / "synthetic-alias"
        alias.symlink_to(synthetic, target_is_directory=True)
        args = self.argv(synthetic=synthetic, argument_parser=project, mixed_setup=mixed_setup, mixed_ios=mixed_ios)
        args.extend(["--prefix", "SYNTHETIC_EVIDENCE=" + str(alias)])
        code, _ = self.run_main(args)
        _, states = self.statuses()
        self.assertEqual(code, 0)
        self.assertTrue(all(item["status"] == "normalized_for_review" for item in states.values()))
        value = json.loads((self.public / "argument-parser/results.json").read_text())
        self.assertEqual(value["setup_results"], "$SYNTHETIC_EVIDENCE/results.json")
        manifest = json.loads((self.public / "argument-parser/manifest.json").read_text())
        mappings = [item for item in manifest["prefix_mappings"] if item["token"] == "$SYNTHETIC_EVIDENCE"]
        self.assertEqual(len(mappings), 1)

    def test_project_prefix_is_derived_without_overriding_other_bundles(self):
        synthetic = self.raw("synthetic")
        project = self.raw("project", {"setup_results": str(synthetic / "results.json")})
        code, _ = self.run_main(self.argv(synthetic=synthetic, argument_parser=project))
        self.assertEqual(code, 0)
        value = json.loads((self.public / "argument-parser/results.json").read_text())
        self.assertEqual(value["setup_results"], "$SYNTHETIC_EVIDENCE/results.json")

    def test_final_manifest_write_failure_publishes_nothing(self):
        raw = self.raw("raw")
        original = Path.open

        def fail_open(path, mode="r", *args, **kwargs):
            if path.name == "bundle-status.json" and mode == "x":
                raise OSError(28, "failure at /Users/private-person/file")
            return original(path, mode, *args, **kwargs)

        with mock.patch.object(Path, "open", fail_open):
            code, logs = self.run_main(self.argv(synthetic=raw))
        self.assertEqual(code, 2)
        self.assertFalse(self.public.exists())
        self.assertFalse(self.github_output.exists())
        self.assertNotIn("private-person", logs)
        self.assertFalse(list(self.root.glob(".indexstore-public-*")))

    def test_final_atomic_publish_failure_exposes_nothing(self):
        raw = self.raw("raw")
        original = MODULE.os.replace

        def fail_final(source, destination):
            if source.name == "ready":
                raise OSError(5, "failed at /Users/private-person/path")
            return original(source, destination)

        with mock.patch.object(MODULE.os, "replace", side_effect=fail_final):
            code, logs = self.run_main(self.argv(synthetic=raw))
        self.assertEqual(code, 2)
        self.assertFalse(self.public.exists())
        self.assertFalse(self.github_output.exists())
        self.assertFalse(list(self.root.glob(".indexstore-public-*")))
        self.assertNotIn("private-person", logs)

    def test_output_changed_during_preparation_is_preserved(self):
        raw = self.raw("raw")
        original = MODULE.EVIDENCE.package

        def change_output(args):
            manifest = original(args)
            self.public.mkdir()
            (self.public / "keep.txt").write_text("concurrent output")
            return manifest

        with mock.patch.object(MODULE.EVIDENCE, "package", side_effect=change_output):
            code, _ = self.run_main(self.argv(synthetic=raw))
        self.assertEqual(code, 2)
        self.assertEqual((self.public / "keep.txt").read_text(), "concurrent output")
        self.assertEqual([p.name for p in self.public.iterdir()], ["keep.txt"])
        self.assertFalse(self.github_output.exists())

    def test_conflicting_project_prefix_blocks_only_the_project(self):
        synthetic, project = self.raw("synthetic"), self.raw("project")
        args = self.argv(synthetic=synthetic, argument_parser=project)
        args.extend(["--prefix", "SYNTHETIC_EVIDENCE=" + str(self.root / "different")])
        code, _ = self.run_main(args)
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["status"], "normalized_for_review")
        self.assertEqual(states["argument-parser"]["status"], "blocked")
        self.assertEqual(states["argument-parser"]["diagnostic"]["reason"], "synthetic-prefix-conflict")

    def test_cli_exits_red_but_exposes_ready_successes(self):
        good = self.raw("good")
        bad = self.raw("bad", {"password": "synthetic-value"})
        process = subprocess.run(
            [sys.executable, str(SCRIPT), *self.argv(synthetic=good, mixed_ios=bad)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(process.returncode, 2)
        self.assertEqual(self.github_output.read_text(), "ready=true\n")
        self.assertTrue((self.public / "synthetic/manifest.json").is_file())
        self.assertFalse((self.public / "mixed-ios").exists())
        self.assertNotIn(str(self.root), process.stdout + process.stderr)

    def test_private_filenames_are_hashed_in_blocked_inventory(self):
        raw = self.raw("raw")
        (raw / "setup").mkdir()
        name = "ghp_012345678901234567890123456789.stdout"
        (raw / "setup" / name).write_text("safe content")
        code, logs = self.run_main(self.argv(synthetic=raw))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["raw_inventory"]["file_count"], 2)
        self.assertNotIn(name, self.published_text() + logs)
        self.assertFalse((self.public / "synthetic").exists())

    def test_structured_blocker_hashes_identify_artifact_without_raw_text(self):
        artifact, value = "setup/private-person.stdout", "/Users/private-person/private-file"
        with self.assertRaises(MODULE.EVIDENCE.PublicationBlocked) as raised:
            MODULE.EVIDENCE.block("unmapped-absolute-path", artifact, value)
        diagnostic = MODULE.diagnostic(raised.exception)
        self.assertEqual(diagnostic["artifact_identifier_sha256"], hashlib.sha256(artifact.encode()).hexdigest())
        self.assertEqual(diagnostic["offending_value_sha256"], hashlib.sha256(value.encode()).hexdigest())
        self.assertNotIn("private-person", json.dumps(diagnostic))

    def test_unstructured_or_malformed_blocker_fields_are_never_parsed_as_metadata(self):
        error = MODULE.EVIDENCE.PublicationBlocked(
            "unmapped-absolute-path; artifact=/private; value_sha256_prefix=secret"
        )
        self.assertEqual(MODULE.diagnostic(error)["reason"], "normalization-blocked")
        error.reason = "unmapped-absolute-path"
        error.artifact_sha256 = "private-path-not-a-digest"
        error.value_sha256 = "1" * 63
        diagnostic = MODULE.diagnostic(error)
        self.assertNotIn("artifact_identifier_sha256", diagnostic)
        self.assertNotIn("offending_value_sha256", diagnostic)
        self.assertNotIn("private-path-not-a-digest", json.dumps(diagnostic))

    def test_unexpected_exception_text_is_never_exposed(self):
        raw = self.raw("raw")
        with mock.patch.object(MODULE.EVIDENCE, "package", side_effect=RuntimeError("password=synthetic-PRIVATE")):
            code, logs = self.run_main(self.argv(synthetic=raw))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["diagnostic"]["reason"], "unexpected-normalization-error")
        self.assertNotIn("synthetic-PRIVATE", self.published_text() + logs)

    def test_input_changed_since_inventory_is_blocked(self):
        raw = self.raw("raw")
        original = MODULE.EVIDENCE.package

        def change_before_normalization(args):
            (args.input / "results.json").write_text('{"changed": true}')
            return original(args)

        with mock.patch.object(MODULE.EVIDENCE, "package", side_effect=change_before_normalization):
            code, _ = self.run_main(self.argv(synthetic=raw))
        _, states = self.statuses()
        self.assertEqual(code, 2)
        self.assertEqual(states["synthetic"]["diagnostic"]["reason"], "raw-evidence-changed-during-normalization")
        self.assertFalse((self.public / "synthetic").exists())

    def test_github_output_must_not_mutate_raw_or_published_files(self):
        raw = self.raw("raw")
        original = (raw / "results.json").read_bytes()
        for target in (raw / "results.json", self.public / "bundle-status.json"):
            with self.subTest(target=target):
                self.github_output = target
                code, _ = self.run_main(self.argv(synthetic=raw))
                self.assertEqual(code, 2)
                self.assertEqual((raw / "results.json").read_bytes(), original)
                self.assertFalse(self.public.exists())

    def test_ci_upload_is_ready_gated_even_when_normalization_step_fails(self):
        workflow = SCRIPT.parents[1] / ".github/workflows/ci.yml"
        text = workflow.read_text()
        self.assertIn("python3 Scripts/verify-indexstore-bundles.py", text)
        self.assertIn("python3 Scripts/normalize-indexstore-bundles.py", text)
        self.assertIn("if: always() && steps.normalize.outputs.ready == 'true'", text)
        self.assertNotIn("steps.normalize.outcome == 'success'", text)
        self.assertIn("timeout-minutes: 35", text)
        self.assertIn('--github-output "$GITHUB_OUTPUT"', text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
