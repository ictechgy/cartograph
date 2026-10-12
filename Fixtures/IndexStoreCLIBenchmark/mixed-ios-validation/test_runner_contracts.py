#!/usr/bin/env python3
"""Offline wrapper contracts; compiler stubs never establish native iOS coverage."""

from __future__ import annotations

from contextlib import ExitStack, redirect_stderr, redirect_stdout
import argparse
import hashlib
import importlib.util
import io
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import run_ios_validation as runner
from validation_common import STAGES, manifest, save, source_manifest


def peer_module(name, relative):
    path = runner.ROOT / relative
    with patch.object(sys, "path", [str(path.parent), *sys.path]):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


def archive_manifest(path):
    with tarfile.open(path) as archive:
        return {
            member.name.removeprefix("./"): hashlib.sha256(archive.extractfile(member).read()).hexdigest()
            for member in archive.getmembers()
            if member.isfile()
        }


class RunnerContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mixed-wrapper-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "evidence"
        self.toolchain = self.root / "selected-toolchain"
        self.swift = self.toolchain / "usr/bin/swiftc"
        self.clang = self.toolchain / "usr/bin/clang"
        self.library = self.toolchain / "usr/lib/libIndexStore.dylib"
        self.library.parent.mkdir(parents=True)
        self.library.write_bytes(b"stub-library-not-native-evidence")
        self.compiler_calls = []
        self.hook_calls = []
        self.failure = None
        self.hook_action = None
        self.original_run = subprocess.run

    def invoke(self, *args, native=False, stages=None):
        with ExitStack() as stack:
            stack.enter_context(
                patch.object(sys, "argv", ["run_ios_validation.py", "--output", str(self.output), *args])
            )
            stack.enter_context(redirect_stdout(io.StringIO()))
            stack.enter_context(redirect_stderr(io.StringIO()))
            if native:
                stack.enter_context(patch.object(runner.platform, "system", return_value="Darwin"))
                stack.enter_context(patch.object(runner.platform, "platform", return_value="stub-host-not-native"))
                stack.enter_context(patch.object(runner.platform, "machine", return_value="x86_64"))
                stack.enter_context(patch.object(runner.subprocess, "run", side_effect=self.stub_process))
                stack.enter_context(patch.object(runner.time, "sleep"))
            if stages is not None:
                stack.enter_context(patch.object(runner, "STAGES", stages))
            return runner.main()

    def read(self, relative):
        return json.loads((self.output / relative).read_text())

    def stub_process(self, args, **kwargs):
        # 네이티브 실행 없이 실패 보존과 배치만 검증한다.
        setup = {
            "--show-sdk-path": str(self.root / "SelectedSDK"),
            "--show-sdk-platform-path": str(self.root / "SelectedPlatform"),
            "--show-sdk-version": "stub-sdk-version",
            "--show-sdk-build-version": "stub-sdk-build",
        }
        if args[0] == "xcrun":
            if self.failure == "setup":
                return subprocess.CompletedProcess(args, 9, b"setup output", b"setup failure")
            text = str(self.swift if args[-1] == "swiftc" else self.clang) if "--find" in args else setup[args[-1]]
            return subprocess.CompletedProcess(args, 0, text.encode() + b"\n", b"")
        if args[0] == "stub-observer":
            self.hook_calls.append(args)
            state = json.loads(Path(args[-1]).read_text())
            if self.hook_action == "timeout-real-child":
                script = (
                    "import subprocess,sys,time,os,json; from pathlib import Path; "
                    "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                    f"Path({str(self.root / 'timed-hook-identities.jsonl')!r}).open('a').write(json.dumps([os.getpid(),child.pid])+'\\n'); "
                    "time.sleep(30)"
                )
                return self.original_run(
                    [sys.executable, "-c", script], capture_output=True, timeout=0.25, start_new_session=True
                )
            if self.hook_action == "launch-error":
                raise FileNotFoundError("observer executable missing")
            if self.hook_action == "signal":
                return subprocess.CompletedProcess(args, -9, b"partial observer", b"killed")
            if self.hook_action == "fail-and-mutate":
                (Path(state["store"]) / "hook-tamper").write_bytes(b"tampered")
            if self.hook_action in {"fail", "fail-and-mutate"}:
                return subprocess.CompletedProcess(args, 17, b"observer output", b"observer failed")
            if self.hook_action == "mutate":
                (Path(state["store"]) / "hook-tamper").write_bytes(b"tampered")
            return subprocess.CompletedProcess(args, 0, b"observer output", b"")
        if "-index-store-path" not in args:
            return subprocess.CompletedProcess(args, 0, b"stub version or help", b"")
        self.compiler_calls.append(args)
        if self.failure == "compiler":
            return subprocess.CompletedProcess(args, 1, b"partial compiler output", b"compiler failed")
        if self.failure == "interrupt":
            raise KeyboardInterrupt()
        if self.failure == "wrong-diagnostic":
            return subprocess.CompletedProcess(args, 1, b"", b"unrelated syntax failure")
        if self.failure == "expected-diagnostic":
            return subprocess.CompletedProcess(args, 1, b"", b"fatal error: 'RenamedCore.h' file not found")
        if self.failure == "launch-with-diagnostic":
            raise FileNotFoundError("RenamedCore.h file not found")
        store = Path(args[args.index("-index-store-path") + 1])
        if self.failure != "missing-units":
            (store / "v5/units").mkdir(parents=True, exist_ok=True)
            (store / "v5/units/stub-unit").write_bytes(b"stub-index-not-native-evidence")
        if self.failure != "missing-output":
            if "-output-file-map" in args:
                mapping = json.loads(Path(args[args.index("-output-file-map") + 1]).read_text())
                for entry in mapping.values():
                    Path(entry["object"]).write_bytes(b"stub-object")
            else:
                obj = Path(args[args.index("-o") + 1])
                obj.write_bytes(b"stub-object")
                obj.with_suffix(".d").write_text("stub.o: CGCore.h\n")
        return subprocess.CompletedProcess(args, 0, b"stub compile success", b"")

    def test_plan_layout_preserves_all_states_and_sources(self):
        self.assertEqual(self.invoke("--plan", "--with-tests"), 0)
        result = self.read("results.json")
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["ios_execution"], "not-run")
        self.assertIsNone(result["superiority_claim"])
        self.assertEqual([s["name"] for s in result["states"]], [s[0] for s in STAGES])
        self.assertEqual(self.read("setup/setup.json")["status"], "plan-only-not-executed")
        for name, _, expected, _ in STAGES:
            state = self.read(f"runs/{name}/state.json")
            self.assertEqual(state["execution"], "plan-only")
            self.assertEqual(state["builds"], [])
            self.assertEqual((self.output / "runs" / name / "commands.json").exists(), expected is not None)
        self.assertEqual(source_manifest(self.output / "Project"), source_manifest(runner.ROOT / "fixture"))
        for absent in ["setup.json", "result.json", "states", "private-snapshots"]:
            self.assertFalse((self.output / absent).exists(), absent)

    def test_plan_with_hook_never_claims_observation(self):
        hook = self.root / "hook.json"
        save(hook, ["must-not-execute"])
        self.assertEqual(self.invoke("--plan", "--hook-json", str(hook)), 0)
        result = self.read("results.json")
        self.assertEqual(result["caller_correctness"], "not-run")
        self.assertEqual(result["native_unit_provenance_gate"], "not-run")
        self.assertTrue(all(state["product_checks"] == "not-run" for state in result["states"]))

    def test_existing_evidence_is_not_overwritten(self):
        self.output.mkdir()
        save(self.output / "results.json", {"original": True})
        before = manifest(self.output)
        with self.assertRaises(SystemExit) as error:
            self.invoke("--plan")
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(manifest(self.output), before)

    def test_native_mode_refuses_non_macos_before_writing_output(self):
        with patch.object(runner.platform, "system", return_value="Linux"):
            with self.assertRaises(SystemExit) as error:
                self.invoke()
        self.assertEqual(error.exception.code, 2)
        self.assertFalse(self.output.exists())

    def test_launch_error_keeps_command_logs_and_record(self):
        stem = self.root / "launch"
        with patch.object(runner.subprocess, "run", side_effect=FileNotFoundError("missing executable")):
            record = runner.run(["missing-executable"], self.root, stem)
        self.assertEqual(record["exit_code"], "launch-error")
        self.assertIn("FileNotFoundError", record["error"])
        self.assertTrue(Path(record["stderr"]).is_file())
        self.assertEqual(json.loads(stem.with_suffix(".json").read_text()), record)

    def test_timeout_keeps_partial_output(self):
        with patch.object(
            runner.subprocess, "run", side_effect=subprocess.TimeoutExpired(["slow"], 1, b"partial", b"diagnostic")
        ):
            record = runner.run(["slow"], self.root, self.root / "timeout", 1)
        self.assertEqual(record["exit_code"], "timeout")
        self.assertEqual(Path(record["stdout"]).read_bytes(), b"partial")
        self.assertEqual(Path(record["stderr"]).read_bytes(), b"diagnostic")

    def test_interrupt_keeps_command_record_before_propagating(self):
        stem = self.root / "interrupted"
        with patch.object(runner.subprocess, "run", side_effect=KeyboardInterrupt()):
            with self.assertRaises(KeyboardInterrupt):
                runner.run(["interrupted"], self.root, stem)
        record = json.loads(stem.with_suffix(".json").read_text())
        self.assertEqual(record["exit_code"], "interrupted")
        self.assertTrue(Path(record["stderr"]).is_file())

    def test_setup_failure_keeps_setup_summary_and_command_logs(self):
        self.failure = "setup"
        self.assertEqual(self.invoke(native=True), 2)
        self.assertEqual(self.read("results.json")["status"], "failed")
        self.assertEqual(self.read("setup/setup.json")["status"], "failed")
        self.assertEqual(self.read("setup/sdk-path.json")["exit_code"], 9)
        self.assertEqual((self.output / "setup/sdk-path.stderr").read_bytes(), b"setup failure")

    def test_failed_compiler_stage_is_retained_with_private_snapshots(self):
        self.failure = "compiler"
        self.assertEqual(self.invoke(native=True), 2)
        result = self.read("results.json")
        state = self.read("runs/initial/state.json")
        self.assertEqual(result["retained_states"], [state])
        self.assertEqual(state["status"], "failed")
        self.assertIsNone(state["last_successful_build"])
        self.assertEqual(state["builds"][0]["exit_code"], 1)
        self.assertTrue(Path(state["source_snapshot"]).is_file())
        self.assertTrue(Path(state["index_snapshot"]).is_file())
        self.assertTrue(
            Path(state["index_snapshot"]).resolve().is_relative_to((self.output / "private-snapshots").resolve())
        )
        self.assertEqual(archive_manifest(state["source_snapshot"]), source_manifest(runner.ROOT / "fixture"))
        self.assertEqual(archive_manifest(state["index_snapshot"]), state["failure_index_files"])
        self.assertFalse(list((self.output / "runs").rglob("*.tar.gz")))
        self.assertFalse((self.output / "runs/header_edit_unbuilt").exists())

    def test_failed_compiler_snapshot_containment_accepts_output_alias(self):
        target = self.root / "real-output"
        target.mkdir()
        alias = self.root / "output-alias"
        alias.symlink_to(target, target_is_directory=True)
        self.output = alias
        self.test_failed_compiler_stage_is_retained_with_private_snapshots()

    def test_compiler_success_without_units_or_outputs_is_not_promoted(self):
        for failure in ["missing-units", "missing-output"]:
            with self.subTest(failure=failure):
                self.output = self.root / failure
                self.failure = failure
                self.assertEqual(self.invoke(native=True), 2)
                state = self.read("runs/initial/state.json")
                self.assertEqual(state["status"], "failed")
                self.assertIsNone(state["last_successful_build"])
                self.assertTrue(state["builds"])

    def test_unexpected_failure_diagnostic_is_not_accepted(self):
        self.failure = "wrong-diagnostic"
        stage = [("expected_failure", None, "failure", None)]
        self.assertEqual(self.invoke(native=True, stages=stage), 2)
        state = self.read("runs/expected_failure/state.json")
        self.assertEqual(state["status"], "failed")
        self.assertIn("missing-header diagnostic", state["error"])

    def test_expected_missing_header_failure_is_accepted(self):
        self.failure = "expected-diagnostic"
        stage = [("expected_failure", None, "failure", None)]
        self.assertEqual(self.invoke(native=True, stages=stage), 0)
        self.assertEqual(self.read("results.json")["status"], "passed")
        self.assertIsNone(self.read("runs/expected_failure/state.json")["last_successful_build"])

    def test_launch_error_text_cannot_satisfy_expected_compiler_failure(self):
        self.failure = "launch-with-diagnostic"
        stage = [("expected_failure", None, "failure", None)]
        self.assertEqual(self.invoke(native=True, stages=stage), 2)
        self.assertEqual(self.read("runs/expected_failure/state.json")["builds"][0]["exit_code"], "launch-error")

    def test_hook_failure_and_input_mutation_stop_after_retaining_state(self):
        hook = self.root / "hook.json"
        save(hook, ["stub-observer"])
        for action in ["fail", "mutate"]:
            with self.subTest(action=action):
                self.output = self.root / action
                self.hook_action = action
                self.assertEqual(self.invoke("--hook-json", str(hook), native=True), 2)
                state = self.read("runs/initial/state.json")
                self.assertEqual(state["status"], "failed")
                self.assertEqual(self.read("results.json")["retained_states"], [state])
                self.assertTrue(Path(state["index_snapshot"]).is_file())
                self.assertTrue((self.output / "runs/initial/observation-hook.json").is_file())
                self.assertFalse((self.output / "runs/header_edit_unbuilt").exists())
                self.assertEqual(archive_manifest(state["index_snapshot"]), state["index_files"])
                self.assertEqual(archive_manifest(state["failure_index_snapshot"]), state["failure_index_files"])
                if action == "mutate":
                    self.assertNotIn("hook-tamper", state["index_files"])
                    self.assertIn("hook-tamper", state["failure_index_files"])

    def test_corrupt_retained_state_does_not_hide_original_failure(self):
        def fail(args, output):
            (output / "runs/broken").mkdir(parents=True)
            (output / "runs/broken/state.json").write_text("{truncated")
            raise RuntimeError("original failure")

        with patch.object(runner, "execute", side_effect=fail):
            self.assertEqual(self.invoke("--plan"), 2)
        result = self.read("results.json")
        self.assertIn("original failure", result["error"])
        self.assertEqual(result["retained_states"], [])
        self.assertEqual(len(result["retention_errors"]), 1)
        self.assertEqual((self.output / "runs/broken/state.json").read_text(), "{truncated")

    def test_interrupted_compiler_keeps_failed_state_and_command_record(self):
        self.failure = "interrupt"
        self.assertEqual(self.invoke(native=True), 2)
        state = self.read("runs/initial/state.json")
        self.assertEqual(state["status"], "failed")
        self.assertIn("KeyboardInterrupt", state["error"])
        self.assertEqual(json.loads(Path(state["command_record"]).read_text())["exit_code"], "interrupted")
        self.assertTrue(Path(state["source_snapshot"]).is_file())

    def test_explicit_continue_retains_every_observation_failure_and_returns_failure(self):
        hook = self.root / "hook.json"
        save(hook, ["stub-observer"])
        self.hook_action = "fail"
        self.assertEqual(
            self.invoke("--hook-json", str(hook), "--continue-observation-failures", native=True, stages=STAGES[:2]), 1
        )
        result = self.read("results.json")
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["observation_failures"], ["initial", "header_edit_unbuilt"])
        self.assertEqual(len(result["states"]), 2)
        self.assertEqual(len(self.hook_calls), 2)
        for state in result["states"]:
            self.assertEqual(state["status"], "failed")
            self.assertEqual(state["observation_hook"]["exit_code"], 17)
            self.assertIn("Observation failed", state["error"])
        self.assertEqual(result["states"][1]["last_successful_build"], "initial")

    def test_continue_never_accepts_mutated_shared_input_even_when_hook_fails(self):
        hook = self.root / "hook.json"
        save(hook, ["stub-observer"])
        self.hook_action = "fail-and-mutate"
        self.assertEqual(
            self.invoke("--hook-json", str(hook), "--continue-observation-failures", native=True, stages=STAGES[:2]), 2
        )
        self.assertIn("changed shared input", self.read("results.json")["error"])
        self.assertEqual(len(self.hook_calls), 1)
        self.assertFalse((self.output / "runs/header_edit_unbuilt").exists())

    def test_continue_aborts_timeout_with_live_child_before_next_state(self):
        hook = self.root / "hook.json"
        save(hook, ["stub-observer"])
        self.hook_action = "timeout-real-child"
        try:
            self.assertEqual(
                self.invoke(
                    "--hook-json", str(hook), "--continue-observation-failures", native=True, stages=STAGES[:2]
                ),
                2,
            )
            self.assertEqual(len(self.hook_calls), 1)
            self.assertEqual(self.read("runs/initial/state.json")["observation_hook"]["exit_code"], "timeout")
            self.assertFalse(
                self.read("runs/initial/state.json")["observation_process_lifecycle"]["descendant_cleanup_verified"]
            )
            self.assertFalse((self.output / "runs/header_edit_unbuilt").exists())
            self.assertEqual(source_manifest(self.output / "Project"), source_manifest(runner.ROOT / "fixture"))
        finally:
            identities = self.root / "timed-hook-identities.jsonl"
            if identities.exists():
                for line in identities.read_text().splitlines():
                    group, child = json.loads(line)
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_continue_aborts_launch_and_signal_failures(self):
        hook = self.root / "hook.json"
        save(hook, ["stub-observer"])
        for action in ["launch-error", "signal"]:
            self.output = self.root / action
            self.hook_action = action
            self.hook_calls = []
            self.assertEqual(
                self.invoke(
                    "--hook-json", str(hook), "--continue-observation-failures", native=True, stages=STAGES[:2]
                ),
                2,
            )
            self.assertEqual(len(self.hook_calls), 1)
            self.assertFalse((self.output / "runs/header_edit_unbuilt").exists())

    def test_secondary_snapshot_failure_does_not_hide_compiler_failure(self):
        self.failure = "compiler"
        with patch.object(runner.shutil, "make_archive", side_effect=OSError("snapshot unavailable")):
            self.assertEqual(self.invoke(native=True), 2)
        state = self.read("runs/initial/state.json")
        self.assertIn("expected success", state["error"])
        self.assertIn("snapshot unavailable", state["retention_errors"][0])
        self.assertIn("expected success", self.read("results.json")["error"])

    def test_source_only_state_reuses_private_index_archive(self):
        self.assertEqual(self.invoke(native=True, stages=STAGES[:2]), 0)
        initial = self.read("runs/initial/state.json")
        changed = self.read("runs/header_edit_unbuilt/state.json")
        self.assertEqual(changed["index_snapshot"], initial["index_snapshot"])
        self.assertEqual(changed["index_files"], initial["index_files"])
        self.assertNotEqual(changed["source_snapshot"], initial["source_snapshot"])
        self.assertEqual(changed["last_successful_build"], "initial")
        self.assertFalse(changed["expected_fresh"])
        self.assertEqual(changed["changed_since_success"], ["Sources/BridgeKit/include/CGCore.h"])

    def test_malformed_hook_config_keeps_failure_summary_without_running_states(self):
        hook = self.root / "hook.json"
        save(hook, "shell syntax is not an argv list")
        self.assertEqual(self.invoke("--plan", "--hook-json", str(hook)), 2)
        self.assertIn("nonempty JSON argv array", self.read("results.json")["error"])
        self.assertFalse((self.output / "runs").exists())

    def test_fixture_hash_drift_stops_before_copying_sources(self):
        with patch.object(runner, "source_manifest", return_value={"changed": "hash"}):
            self.assertEqual(self.invoke("--plan"), 2)
        self.assertIn("Fixture source hashes changed", self.read("results.json")["error"])
        self.assertFalse((self.output / "Project").exists())

    def test_actual_plan_layout_is_discovered_by_peer_adapter(self):
        hook = peer_module("integration_observer", "adapter/observe_mixed.py")
        self.assertEqual(self.invoke("--plan"), 0)
        for name, _, _, _ in STAGES:
            self.assertEqual(hook.find_run_root(self.output / "runs" / name / "state.json"), self.output)
        self.assertEqual(hook.setup_path_for(self.output), self.output / "setup/setup.json")

    def test_public_selection_excludes_raw_source_binary_and_archives(self):
        normalizer = peer_module("integration_normalizer", "../../../Scripts/normalize-indexstore-evidence.py")
        self.failure = "compiler"
        self.assertEqual(self.invoke(native=True), 2)
        for relative in ["IndexStore/binary", "Build/binary.o", "Project/full-checkout.txt"]:
            (self.output / relative).write_bytes(b"RAW_PRIVATE_SENTINEL\x00")
        before = manifest(self.output)
        public = self.root / "normalized-review"
        args = argparse.Namespace(
            input=self.output,
            output=public,
            prefix=[
                f"TOOLCHAIN={self.toolchain}",
                f"IOS_SDK={self.root / 'SelectedSDK'}",
                f"IOS_PLATFORM={self.root / 'SelectedPlatform'}",
            ],
        )
        result = normalizer.package(args)
        selected = [entry["path"] for entry in result["files"]]
        self.assertIn("results.json", selected)
        self.assertIn("setup/setup.json", selected)
        self.assertIn("runs/initial/state.json", selected)
        self.assertTrue(all(path == "results.json" or path.startswith(("setup/", "runs/")) for path in selected))
        self.assertFalse(any(path.endswith((".o", ".tar.gz", ".swift", ".m", ".mm", ".h")) for path in selected))
        for path in public.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"RAW_PRIVATE_SENTINEL", path.read_bytes())
                self.assertNotIn(str(self.root).encode(), path.read_bytes())
        self.assertEqual(manifest(self.output), before)

    def test_xctest_plan_fake_platform_remains_blocked_by_privacy_guard(self):
        normalizer = peer_module("integration_normalizer_plan", "../../../Scripts/normalize-indexstore-evidence.py")
        self.assertEqual(self.invoke("--plan", "--with-tests"), 0)
        before = manifest(self.output)
        public = self.root / "blocked-normalization"
        args = argparse.Namespace(input=self.output, output=public, prefix=[])
        with self.assertRaisesRegex(normalizer.PublicationBlocked, "unmapped-absolute-path"):
            normalizer.package(args)
        self.assertFalse(public.exists())
        self.assertEqual(manifest(self.output), before)

    def test_non_xctest_plan_normalizes_without_fake_prefix_allowance(self):
        normalizer = peer_module(
            "integration_normalizer_plan_plain", "../../../Scripts/normalize-indexstore-evidence.py"
        )
        self.assertEqual(self.invoke("--plan"), 0)
        before = manifest(self.output)
        public = self.root / "normalized-plan"
        result = normalizer.package(argparse.Namespace(input=self.output, output=public, prefix=[]))
        self.assertEqual(result["status"], "normalized_for_review")
        self.assertEqual(manifest(self.output), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
