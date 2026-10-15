#!/usr/bin/env python3
"""컴파일러를 시작하지 않고 고정 세대 호출·환경·발행 경계를 검증한다."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import importlib.machinery
import platform
import signal
import subprocess
import time
import types
import contextlib
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/native-calibration.yml"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


M = load("generation_controller_controls", ROOT / "Scripts/validate-native-sdk-generations.py")
W = M.load_wrapper()


def legacy_workflow(data):
    """명시한 추가 부분만 역변환하여 이전 두 모드의 전체 원본 바이트와 비교한다."""
    for before, after in ((b'        timeout-minutes: 31\n        env:\n          SOURCE_SHA: ${{ inputs.source_sha }}\n        run: |\n          fresh=true\n          for subtree in native-generation-supervisor native-calibration-sdk-calls native-calibration-sdk-raw native-sdk-generations-lifecycle sdk-discovery-raw native-generation-home native-generation-tmp; do\n            if [[ -e "$RUNNER_TEMP/$subtree" || -L "$RUNNER_TEMP/$subtree" ]]; then fresh=false; fi\n          done\n          [[ "$GITHUB_RUN_ID" =~ ^[1-9][0-9]*$ && "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]\n          set +e\n          python3 -I -S -B Scripts/validate-native-sdk-generations.py \\\n            --scratch-root "$RUNNER_TEMP"\n          actual=$?\n          set -e\n          if [[ -e "$RUNNER_TEMP/generation-invocation-status.json" || -L "$RUNNER_TEMP/generation-invocation-status.json" ]]; then\n            if [[ "$actual" == 0 ]]; then exit 125; fi\n            exit "$actual"\n          fi\n          if (set -o noclobber; printf \'{"schema_version":1,"mode":"sdk-generation-only","source_sha":"%s","run_id":%s,"run_attempt":%s,"actual_shell_exit":%d,"checkpoint":"invocation-returned","prelaunch_outputs_absent":%s}\\n\' "$SOURCE_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$actual" "$fresh" > "$RUNNER_TEMP/generation-invocation-status.json"); then\n            printf \'status_finalized=true\\n\' >> "$GITHUB_OUTPUT"\n          elif [[ "$actual" == 0 ]]; then\n            exit 125\n          fi\n          exit "$actual"\n', b'        timeout-minutes: 31\n        run: |\n          python3 -I -S -B Scripts/validate-native-sdk-generations.py \\\n            --scratch-root "$RUNNER_TEMP"\n'),
        (b'          GENERATION_STATUS_FINALIZED: ${{ steps.generations.outputs.status_finalized }}\n', b''),
        (b"(steps.before.outcome != 'skipped' || (steps.generations.outcome != 'skipped' && steps.generations.outputs.status_finalized == 'true'))", b"(steps.before.outcome != 'skipped' || steps.generations.outcome != 'skipped')"),
        (b"          name: ${{ inputs.mode == 'sdk-generation-only' && steps.generations.outcome != 'success' && 'native-sdk-generation-failure-capsule' || 'native-sdk-content-candidate' }}\n", b'          name: native-sdk-content-candidate\n')):
        if data.count(before) != 1:
            raise AssertionError("Failure capsule workflow inverse must match once")
        data = data.replace(before, after)
    changes = [
        (b"          - sdk-generation-only\n", b""),
        (b"('calibration', 'sdk-publication-only', 'sdk-generation-only')",
         b"('calibration', 'sdk-publication-only')"),
        (b"          python3 Scripts/verify-native-generation-contract.py\n"
         b"          python3 -m unittest discover -s Scripts/benchmark-inputs -p 'test_native_generation_inputs.py' -v\n", b""),
        (b"        if: inputs.mode != 'sdk-generation-only'\n", b""),
        (b"      # \xec\x9d\xb4 \xeb\xaa\xa8\xeb\x93\x9c\xeb\x8a\x94 \xec\x9b\x90\xeb\xb3\xb8 \xeb\x8f\x84\xea\xb5\xac/\xec\xa7\x88\xec\x9d\x98 \xec\x97\x86\xec\x9d\xb4 \xea\xb3\xa0\xec\xa0\x95\xeb\x90\x9c \xec\xbb\xb4\xed\x8c\x8c\xec\x9d\xbc \xec\x84\xb8\xeb\x8c\x80\xeb\xa7\x8c \xec\x8b\xa4\xed\x96\x89\xed\x95\x9c\xeb\x8b\xa4.\n"
         + "      # 45분 전체 제한에서 중단되면 뒤의 공개 업로드는 보장되지 않는다.\n".encode()
         + b"      - name: Validate the fixed compiler-only SDK generation brackets\n"
         b"        id: generations\n        if: inputs.mode == 'sdk-generation-only'\n"
         b"        timeout-minutes: 31\n        run: |\n"
         b"          python3 -I -S -B Scripts/validate-native-sdk-generations.py \\\n"
         b'            --scratch-root "$RUNNER_TEMP"\n\n', b""),
        (b"(steps.before.outcome != 'skipped' || steps.generations.outcome != 'skipped')",
         b"steps.before.outcome != 'skipped'"),
        (b"        id: sdk_public\n        env:\n          RUN_MODE: ${{ inputs.mode }}\n",
         b"        id: sdk_public\n"),
        (b"          generation=()\n"
         b'          if [[ "$RUN_MODE" == \'sdk-generation-only\' ]]; then generation=(--generation-publication); fi\n', b""),
        (b'--stage publish --scratch-root "$RUNNER_TEMP" "${generation[@]}"',
         b'--stage publish --scratch-root "$RUNNER_TEMP"'),
    ]
    for before, after in changes:
        if data.count(before) != 1:
            raise AssertionError("Workflow inverse must match exactly one declared delta")
        data = data.replace(before, after)
    return data


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        expected, _ = M.GENERATIONS.NATIVE.expectation()
        environment = mock.patch.dict(os.environ, {**expected["runner"], "DEVELOPER_DIR": expected["developer_lexical"]})
        environment.start()
        self.addCleanup(environment.stop)

    def test_exact_context_roundtrip_and_eight_environment_rows(self):
        context = M.create_context(self.root)
        path = self.root / M.CONTEXT
        digest = M.reference(path)["sha256"]
        environment = M.context_environment(context)
        self.assertEqual(set(environment), M.GENERATIONS.ENVIRONMENT_KEYS)
        with mock.patch.dict(os.environ, environment, clear=True):
            self.assertEqual(M.verify_context(path, digest, self.root), context)
            Path(environment["HOME"], "ordinary-cache").write_text("expected compiler cache")
            self.assertEqual(M.verify_context(path, digest, self.root), context)
            for name in ("CPATH", "SWIFT_EXEC", "DYLD_INSERT_LIBRARIES", "PYTHONPATH"):
                with self.subTest(name=name), mock.patch.dict(os.environ, {name: "unreviewed"}):
                    with self.assertRaisesRegex(ValueError, "generation-environment-changed"):
                        M.verify_context(path, digest, self.root)

    def test_context_refuses_directory_replacement_source_drift_and_rehashed_shapes(self):
        context = M.create_context(self.root)
        path = self.root / M.CONTEXT
        original = path.read_bytes()
        digest = M.reference(path)["sha256"]
        for change in (lambda row: row.update(accepted=True),
                       lambda row: row["environment"].append(row["environment"][0]),
                       lambda row: row["environment"].pop(),
                       lambda row: row["environment"][0].update(name="UNEXPECTED"),
                       lambda row: row["helper_sha256"].update(extra="0" * 64)):
            altered = copy.deepcopy(context)
            change(altered)
            path.write_text(json.dumps(altered))
            with self.subTest(change=change), self.assertRaises(ValueError):
                M.verify_context(path, M.reference(path)["sha256"], self.root, current_environment=False)
        path.write_bytes(original)
        environment = M.context_environment(context)
        home = Path(environment["HOME"])
        home.rename(home.with_name("previous-owned-home"))
        home.mkdir()
        with self.assertRaisesRegex(ValueError, "generation-environment-changed"):
            M.verify_context(path, digest, self.root, current_environment=False)

    def test_context_never_reuses_existing_directories_or_receipts(self):
        M.create_context(self.root)
        original = (self.root / M.CONTEXT).read_bytes()
        with self.assertRaises(FileExistsError):
            M.create_context(self.root)
        self.assertEqual((self.root / M.CONTEXT).read_bytes(), original)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        expected, _ = M.GENERATIONS.NATIVE.expectation()
        environment = mock.patch.dict(os.environ, {**expected["runner"], "DEVELOPER_DIR": expected["developer_lexical"]})
        environment.start()
        self.addCleanup(environment.stop)
        self.calls = []
        self.fail_at = None
        self.time = 1.0
        self.environment = None
        self.wrapper = mock.Mock()
        self.wrapper.COMMAND.command.side_effect = self.command
        for target, name, value in (
            (M, "load_wrapper", self.wrapper),
            (M, "verify_context", {}),
            (M.GENERATIONS, "make_request", {}),
            (M.GENERATIONS, "verify_originals", {"status": "verified-candidate"}),
        ):
            patcher = mock.patch.object(target, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def write(self, relative, value):
        path = self.root / relative
        M.save(path, value)

    def command(self, argv, cwd, stem, environment, timeout):
        name = stem.parent.name
        self.calls.append((name, argv, timeout))
        self.environment = self.environment or environment
        self.assertEqual(environment, self.environment)
        self.assertEqual(set(environment), M.GENERATIONS.ENVIRONMENT_KEYS)
        stem.parent.mkdir(parents=True, exist_ok=True)
        row = dict(command=argv, cwd=str(cwd), completed=True, passed=name != self.fail_at,
                   returncode=1 if name == self.fail_at else 0, observed_returncode=1 if name == self.fail_at else 0,
                   failure=None, cleanup_signals=[], cleanup_root_unfinished=False, wall_seconds=0.1,
                   stdout=str(stem) + ".stdout", stderr=str(stem) + ".stderr")
        M.save(Path(str(stem) + ".json"), row)
        Path(row["stdout"]).write_text("")
        Path(row["stderr"]).write_text("")
        if name == "before-compilation":
            self.write("native-calibration-sdk-raw/before-compilation/results.json", {})
        if name in ("before-compilation", "after-generation"):
            observation = (dict(content_sha256=M.GENERATIONS.BASELINE_SHA256) if name == "before-compilation"
                           else dict(verification=dict(matches=True, expected_sha256=M.GENERATIONS.BASELINE_SHA256,
                                                       actual_sha256=M.GENERATIONS.BASELINE_SHA256)))
            self.write("native-calibration-sdk-raw/setup/phases/" + name + ".json",
                       dict(status="passed", exit_code=0, accepted=False, final_protocol_ready=False,
                            observation=observation))
        elif name == "compiler-lifecycle":
            self.write("native-calibration-sdk-raw/generation-results.json",
                       dict(status="verified-candidate", accepted=False, final_protocol_ready=False,
                            lifecycle_output=str(self.root / "native-sdk-generations-lifecycle"),
                            request_sha256=M.reference(self.root / "native-calibration-sdk-raw/setup/generation-request.json")["sha256"],
                            full_generation_reads=16, planned_commands=48, executed_commands=43))
        else:
            self.write("sdk-discovery-raw/results.json", dict(status="awaiting-root-review", exit_code=0,
                                                             accepted=False, final_protocol_ready=False))
            self.write("sdk-discovery-raw/setup/discovery/results.json", dict(probes=[copy.deepcopy(row) for _ in range(10)]))
        self.time += 0.5
        return row

    def execute(self):
        result = M.execute(self.root, clock=lambda: self.time)
        self.supervisor_fixture(result)
        return result

    def supervisor_fixture(self, inner, code=None):
        output = self.root / "native-generation-supervisor"
        output.mkdir(exist_ok=True)
        actual_code = inner["exit_code"] if code is None else code
        row = dict(command=M.controller_argv(self.root), cwd=str(ROOT), completed=actual_code != 125,
                   passed=actual_code == 0, returncode=actual_code, observed_returncode=actual_code,
                   failure=None if actual_code == 0 else "nested-incomplete", cleanup_signals=[],
                   cleanup_root_unfinished=False, wall_seconds=0.25)
        originals = {}
        for suffix in (".json", ".stdout", ".stderr"):
            path = output / ("command" + suffix)
            path.write_text(json.dumps(row) if suffix == ".json" else "")
            originals[suffix] = M.reference(path)
        value = dict(profile=M.PROFILE, accepted=False, final_protocol_ready=False, actual_engine_calls=0,
                     command=row, helper_sha256=M.source_hashes(),
                     python=M.GENERATIONS.interpreter_identity(sys.executable), source_inputs_unchanged=True,
                     child_timeout_seconds=1815, originals=originals,
                     child_diagnostic=M.child_diagnostic(output, row, originals),
                     exit_code=0 if actual_code == 0 else 125,
                     full_call_wall_seconds_before_receipt=0.5,
                     charged_wall_seconds_by_arm={arm: 0.5 for arm in M.GENERATIONS.ARMS})
        (output / "results.json").write_text(json.dumps(value))

    def test_exact_fixed_schedule_environment_and_nonpromoted_success(self):
        result = self.execute()
        self.assertEqual([(name, bound) for name, _, bound in self.calls], list(M.PHASES))
        self.assertEqual(result["status"], "validation-candidate-complete")
        self.assertEqual(result["exit_code"], 0)
        self.assertIs(result["accepted"], False)
        self.assertIs(result["final_protocol_ready"], False)
        self.assertEqual(result["actual_engine_calls"], 0)
        for _, argv, _ in self.calls:
            self.assertNotIn("--hook-json", argv)
            self.assertNotIn("--with-tests", argv)
            self.assertNotIn("--continue-observation-failures", argv)
        self.assertIn("--sdk-generation-request-sha256", self.calls[1][1])
        self.assertEqual(result["charged_wall_seconds_by_arm"],
                         {arm: result["caller_wall_seconds_before_receipt"] for arm in M.GENERATIONS.ARMS})

    def test_first_failed_child_stops_and_preserves_exact_originals(self):
        self.fail_at = "compiler-lifecycle"
        result = self.execute()
        self.assertEqual([row[0] for row in self.calls], ["before-compilation", "compiler-lifecycle"])
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["first_failure"]["phase"], "compiler-lifecycle")
        phase = result["phases"]["compiler-lifecycle"]
        self.assertEqual(phase["command_result"]["observed_returncode"], 1)
        for key in ("sdk-discovery", "after-generation"):
            self.assertEqual(result["phases"][key]["status"], "not-started")
        for ref in phase["originals"].values():
            self.assertEqual(M.reference(Path(ref["path"])), ref)

    def test_unstartable_phase_and_post_command_expiry_refuse_without_replacement(self):
        original = self.wrapper.COMMAND.command.side_effect
        def slow(*args):
            row = original(*args)
            self.time = 650.0
            return row
        self.wrapper.COMMAND.command.side_effect = slow
        result = self.execute()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(result["phases"]["compiler-lifecycle"]["status"], "not-started")
        self.assertEqual(result["exit_code"], 125)

    def test_admission_consuming_budget_prevents_launch(self):
        def admission(*_args, **_kwargs):
            self.time = 1300.0
            return {}
        with mock.patch.object(M, "verify_context", side_effect=admission):
            result = self.execute()
        self.assertEqual(self.calls, [])
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["phases"]["before-compilation"]["status"], "not-started")
        self.assertEqual(result["phases"]["before-compilation"]["reason"], "phase-admission-or-deadline-refused")
        original = M.read(self.root / "native-calibration-sdk-calls/before-compilation/started.json")
        self.assertEqual(original["status"], "not-started")
        self.assertEqual(original["reason"], "launch-admission")

    def test_final_receipt_expiry_retains_failure_and_actual_successful_children(self):
        original = M.json.dump
        def delayed(value, stream, **kwargs):
            original(value, stream, **kwargs)
            if "phase_order" in value:
                self.time = 1802.0
        with mock.patch.object(M.json, "dump", side_effect=delayed):
            result = self.execute()
        self.assertEqual(len(self.calls), 4)
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["first_failure"]["phase"], "final-receipt")
        self.assertEqual(M.read(self.root / "native-calibration-sdk-calls/generation-controller.json"), result)

    def test_late_reaped_zero_child_retains_original_but_stops_schedule(self):
        original = self.wrapper.COMMAND.command.side_effect
        def late(argv, cwd, stem, environment, timeout):
            row = original(argv, cwd, stem, environment, timeout)
            row["wall_seconds"] = timeout + 0.001
            Path(str(stem) + ".json").write_text(json.dumps(row))
            return row
        self.wrapper.COMMAND.command.side_effect = late
        result = self.execute()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(result["exit_code"], 125)
        child = result["phases"]["before-compilation"]["command_result"]
        self.assertEqual(child["observed_returncode"], 0)
        self.assertEqual(child["returncode"], 0)
        self.assertEqual(child["wall_seconds"], 570.001)
        self.assertEqual(result["phases"]["before-compilation"]["status"], "incomplete")
        self.assertEqual(M.verify_controller(self.root), M.reference(
            self.root / "native-calibration-sdk-calls/generation-controller.json"))

    def test_racing_existing_receipt_preserved_and_primary_failure_not_replaced(self):
        self.fail_at = "compiler-lifecycle"
        original = self.wrapper.COMMAND.command.side_effect
        target = self.root / "native-calibration-sdk-calls/generation-controller.json"
        def raced(*args):
            row = original(*args)
            if args[2].parent.name == self.fail_at:
                target.write_bytes(b"prior original bytes")
            return row
        self.wrapper.COMMAND.command.side_effect = raced
        result = self.execute()
        self.assertEqual(target.read_bytes(), b"prior original bytes")
        self.assertEqual(result["first_failure"]["phase"], "compiler-lifecycle")
        self.assertEqual(result["receipt_failure"]["failure_type"], "FileExistsError")
        self.assertEqual(result["exit_code"], 125)

    def test_publication_regrade_binds_calls_counts_costs_and_original_bytes(self):
        self.execute()
        result_path = self.root / "native-calibration-sdk-calls/generation-controller.json"
        summary_path = self.root / "native-calibration-sdk-raw/generation-results.json"
        result, summary = M.read(result_path), M.read(summary_path)
        self.assertEqual(M.verify_controller(self.root), M.reference(result_path))
        for field, value in (("executed_commands", 42), ("full_generation_reads", True),
                             ("planned_commands", 47), ("accepted", True)):
            summary_path.write_text(json.dumps({**summary, field: value}))
            with self.subTest(field=field), self.assertRaises(ValueError):
                M.verify_controller(self.root)
        summary_path.write_text(json.dumps(summary))
        for mutate in (lambda row: row.update(actual_engine_calls=True),
                       lambda row: row["phases"].pop("sdk-discovery"),
                       lambda row: row["charged_wall_seconds_by_arm"].update(cartograph=0),
                       lambda row: row["phases"]["compiler-lifecycle"]["command"].append("--hook-json")):
            altered = copy.deepcopy(result)
            mutate(altered)
            result_path.write_text(json.dumps(altered))
            with self.subTest(mutate=mutate), self.assertRaises((ValueError, KeyError)):
                M.verify_controller(self.root)
        result_path.write_text(json.dumps(result))
        log = self.root / "native-calibration-sdk-calls/compiler-lifecycle/command.stderr"
        log.write_text("changed original")
        with self.assertRaisesRegex(ValueError, "generation-command-original-changed"):
            M.verify_controller(self.root)

    def test_publication_recomputes_typed_diagnostic_from_original_streams(self):
        self.execute()
        path = self.root / "native-generation-supervisor/results.json"
        original = M.read(path)
        for mutate in (lambda value: value["child_diagnostic"].update(observed_returncode=False),
                       lambda value: value["child_diagnostic"].update(status="decoded"),
                       lambda value: value["child_diagnostic"].update(wall_seconds=0),
                       lambda value: value["child_diagnostic"]["original_sha256"].update(stdout="a" * 64),
                       lambda value: value.pop("child_diagnostic")):
            value = copy.deepcopy(original)
            mutate(value)
            path.write_text(json.dumps(value))
            with self.subTest(mutate=mutate), self.assertRaisesRegex(ValueError, "generation-diagnostic-changed"):
                M.verify_controller(self.root)
        path.write_text(json.dumps(original))
        self.assertEqual(M.verify_controller(self.root), M.reference(
            self.root / "native-calibration-sdk-calls/generation-controller.json"))

    def test_complete_inner_cannot_hide_controller_close_failure_or_outer_lateness(self):
        result = self.execute()
        self.supervisor_fixture(result, code=125)
        with self.assertRaisesRegex(ValueError, "generation-controller-exit-mismatch"):
            M.verify_controller(self.root)
        self.supervisor_fixture(result)
        directory = self.root / "native-generation-supervisor"
        value = M.read(directory / "results.json")
        value["command"]["wall_seconds"] = 1815.001
        (directory / "command.json").write_text(json.dumps(value["command"]))
        value["originals"][".json"] = M.reference(directory / "command.json")
        value["exit_code"] = 125
        value["full_call_wall_seconds_before_receipt"] = 1816.0
        value["charged_wall_seconds_by_arm"] = {arm: 1816.0 for arm in M.GENERATIONS.ARMS}
        (directory / "results.json").write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "generation-controller-exit-mismatch"):
            M.verify_controller(self.root)

    def test_typed_command_completion_refuses_cleanup_nonfinite_and_boolean_exits(self):
        good = dict(completed=True, passed=True, returncode=0, observed_returncode=0, failure=None,
                    cleanup_signals=[], cleanup_root_unfinished=False, wall_seconds=0.1)
        self.assertTrue(M.complete_command(good))
        for key, value in (("returncode", False), ("observed_returncode", False), ("wall_seconds", True),
                           ("wall_seconds", float("inf")), ("wall_seconds", float("nan")),
                           ("wall_seconds", 0), ("cleanup_signals", ["term-sent"]),
                           ("cleanup_root_unfinished", True), ("completed", False), ("failure", "timeout")):
            with self.subTest(key=key, value=value):
                self.assertFalse(M.complete_command({**good, key: value}))


class GenerationPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.raw = self.root / "native-calibration-sdk-raw"
        self.calls = self.root / "native-calibration-sdk-calls"
        self.projection = W.load("generation_projection_controls", W.INPUTS / "native_calibration_publication.py")

    def probe_projection_fixture(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        staging, public = root / "staging", root / "public"
        originals = {W.EMPTY_PROBE_ORIGINAL: b""}
        W.save(staging / "results.json", dict(accepted=False, final_protocol_ready=False))
        W.save(staging / W.EMPTY_PROBE_PROJECTED, W.empty_probe_descriptor())
        W.save(staging / "setup/original-copy-manifest.json", dict(files=W.original_copy_rows(originals, M.PROFILE)))
        manifest = W.NORMALIZER.package(W.argparse.Namespace(input=staging, output=public, prefix=[]))
        return staging, public, manifest, originals

    def test_empty_probe_real_normalization_preserves_exact_inverse_and_copy_binding(self):
        staging, public, manifest, originals = self.probe_projection_fixture()
        W.verify_empty_probe_projection(staging, public, manifest, originals, M.PROFILE)
        self.assertEqual(W.document(public / W.EMPTY_PROBE_PROJECTED), W.empty_probe_descriptor())
        self.assertEqual(W.document(public / W.EMPTY_PROBE_PROJECTED)["content"].encode(), b"")
        row = W.document(public / "setup/original-copy-manifest.json")["files"][0]
        self.assertEqual(row["path"], W.EMPTY_PROBE_ORIGINAL)
        self.assertEqual(row["projection"]["path"], W.EMPTY_PROBE_PROJECTED)

    def test_empty_probe_admission_is_fixed_profile_path_regular_and_empty(self):
        target = self.root / "sdk-discovery-raw/setup/discovery/probe-input"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"")
        self.assertEqual(W.original_small_files(self.raw, self.calls, profile=M.PROFILE), {W.EMPTY_PROBE_ORIGINAL: b""})
        with self.assertRaisesRegex(ValueError, "invalid-empty-probe-original"):
            W.original_copy_rows({W.EMPTY_PROBE_ORIGINAL: b""}, "calibration")
        for kind in ("nonempty", "symlink", "sibling", "collision"):
            with self.subTest(kind=kind):
                target.unlink()
                target.write_bytes(b"changed" if kind == "nonempty" else b"")
                extra = None
                if kind == "symlink":
                    target.unlink(); target.symlink_to(self.root / "missing")
                elif kind in ("sibling", "collision"):
                    extra = target.with_name("probe-input-other" if kind == "sibling" else "probe-input.json")
                    extra.write_bytes(b"{}")
                with self.assertRaises((OSError, ValueError)):
                    W.original_small_files(self.raw, self.calls, profile=M.PROFILE)
                if extra is not None: extra.unlink()
        raw_probe = self.raw / "probe-input"
        self.raw.mkdir(); raw_probe.write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "unexpected-publication-file"):
            W.original_small_files(self.raw, self.calls)

    def test_empty_probe_rehashed_descriptor_and_manifest_mutations_refuse(self):
        for kind in ("schema", "bytes", "role", "encoding", "content", "hash", "path", "extra", "missing", "copy", "manifest"):
            with self.subTest(kind=kind):
                staging, public, manifest, originals = self.probe_projection_fixture()
                relative = W.EMPTY_PROBE_PROJECTED
                value = W.document(public / relative)
                if kind == "schema": value["schema_version"] = True
                elif kind == "bytes": value["bytes"] = False
                elif kind == "role": value["role"] = "other"
                elif kind == "encoding": value["encoding"] = "other"
                elif kind == "content": value["content"] = "x"
                elif kind == "hash": value["sha256"] = "f" * 64
                elif kind == "path": value["original_path"] += "-other"
                elif kind == "extra": value["extra"] = False
                elif kind == "copy":
                    relative = "setup/original-copy-manifest.json"
                    value = W.document(public / relative)
                    value["files"][0]["projection"]["path"] += ".other"
                if kind == "missing":
                    (public / relative).unlink()
                elif kind == "manifest":
                    row = next(row for row in manifest["files"] if row["path"] == relative)
                    row["normalized_bytes"] = float(row["normalized_bytes"])
                else:
                    data = W.json_bytes(value)
                    for base in (staging, public): (base / relative).write_bytes(data)
                    row = next(row for row in manifest["files"] if row["path"] == relative)
                    row.update(original_raw_sha256=hashlib.sha256(data).hexdigest(), normalized_sha256=hashlib.sha256(data).hexdigest(),
                               original_bytes=len(data), normalized_bytes=len(data))
                with self.assertRaises((OSError, ValueError)):
                    W.verify_empty_probe_projection(staging, public, manifest, originals, M.PROFILE)

    def test_empty_probe_original_endpoint_remains_in_membership(self):
        target = self.root / "sdk-discovery-raw/setup/discovery/probe-input"
        target.parent.mkdir(parents=True); target.write_bytes(b"")
        before = W.original_small_files(self.raw, self.calls, profile=M.PROFILE)
        target.unlink()
        self.assertNotEqual(W.original_small_files(self.raw, self.calls, profile=M.PROFILE), before)
        target.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "nonempty-discovery-probe-input"):
            W.original_small_files(self.raw, self.calls, profile=M.PROFILE)

    def test_fixed_large_seals_only_are_excluded_and_discovery_is_included(self):
        for relative in self.projection.GENERATION_SOURCES.values():
            target = self.raw / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("large seal remains separately bound by projection")
        for relative in ("native-calibration-sdk-raw/results.json", "native-calibration-sdk-calls/command.json",
                         "sdk-discovery-raw/setup/probe.stdout"):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("retained original")
        rows = W.original_small_files(self.raw, self.calls, profile=M.PROFILE)
        self.assertEqual(set(rows), {"raw/results.json", "calls/command.json", "discovery/setup/probe.stdout"})
        unknown = self.raw / "generations/unknown/seal-verification.json"
        unknown.parent.mkdir(parents=True)
        unknown.write_text("not silently excluded")
        self.assertIn("raw/generations/unknown/seal-verification.json",
                      W.original_small_files(self.raw, self.calls, profile=M.PROFILE))

    def test_generation_publication_regrades_originals_and_profile_at_both_endpoints(self):
        M.save(self.raw / "results.json", dict(profile=M.PROFILE, helper_sha256={"pinned": "a" * 64}))
        M.save(self.raw / "generation-results.json", dict(status="verified-candidate"))
        controller = mock.Mock(CONTEXT=M.CONTEXT)
        controller.reference.return_value = dict(sha256="b" * 64)
        controller.invocation_status.return_value = dict(actual_shell_exit=0)
        projection = mock.Mock()
        projection.prepare_projection.return_value = {"projection": "fixed"}
        projection.verify_publication.return_value = {"status": "verified"}
        projection.verify_sources.return_value = {"status": "verified"}
        controller.GENERATIONS.verify_originals.return_value = {"status": "verified-candidate"}
        public = self.root / "native-calibration-sdk-public"
        def package(_args):
            M.save(public / "manifest.json", dict(files=[]))
            return dict(files=[])
        with mock.patch.object(W, "profile_hashes", return_value={"pinned": "a" * 64}), \
             mock.patch.object(W, "generation_controller", return_value=controller), \
             mock.patch.object(W, "load", return_value=projection), \
             mock.patch.object(W, "original_small_files", return_value={}), \
             mock.patch.object(W.NORMALIZER, "package", side_effect=package):
            costs = {}
            W.publish_bundle(self.root, costs, profile=M.PROFILE)
        self.assertEqual(controller.verify_controller.call_args_list, [mock.call(self.root), mock.call(self.root)])
        self.assertEqual(controller.GENERATIONS.verify_originals.call_count, 2)
        projection.prepare_projection.assert_called_once_with(self.raw, self.root / "native-calibration-sdk-staging",
                                                             profile=M.PROFILE)
        projection.verify_sources.assert_called_once_with(self.raw, self.root / "native-calibration-sdk-staging",
                                                         profile=M.PROFILE)
        self.assertEqual(set(costs), {"prepare_projection", "normalizer", "verify_publication", "verify_sources"})
        self.assertTrue(all(row["full_wall_seconds"] >= 0 for row in costs.values()))



class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.output = self.root / "native-generation-supervisor"
        self.failure = dict(phase="before-compilation", failure_type="GenerationError", failure_sha256="c" * 64)
        self.inner = dict(status="incomplete", exit_code=125, actual_engine_calls=0, accepted=False,
                          final_protocol_ready=False, first_failure=self.failure)
        self.row = dict(completed=True, passed=False, returncode=125, observed_returncode=125, failure=None,
                        cleanup_signals=[], cleanup_root_unfinished=False, wall_seconds=0.25)

    def files(self, stdout=None, stderr=""):
        self.output.mkdir(exist_ok=True)
        data = json.dumps(self.inner) if stdout is None else stdout
        values = {".json": json.dumps(self.row), ".stdout": data, ".stderr": stderr}
        for suffix, text in values.items():
            (self.output / ("command" + suffix)).write_text(text)
        return {suffix: M.reference(self.output / ("command" + suffix)) for suffix in values}

    def diagnostic(self, stdout=None, stderr=""):
        return M.child_diagnostic(self.output, self.row, self.files(stdout, stderr))

    def supervised(self, stdout=None, stderr="", *, clock=None, mutate=None):
        wrapper = mock.Mock()
        def command(argv, cwd, stem, environment, timeout):
            self.assertEqual(argv, M.controller_argv(self.root))
            self.assertEqual(timeout, 1815)
            values = {".json": json.dumps(self.row), ".stdout": json.dumps(self.inner) if stdout is None else stdout,
                      ".stderr": stderr}
            for suffix, text in values.items():
                (self.output / ("command" + suffix)).write_text(text)
            if mutate is not None:
                mutate(self.output)
            return self.row
        wrapper.COMMAND.command.side_effect = command
        with contextlib.ExitStack() as stack:
            for owner, name, value in ((M, "load_wrapper", wrapper), (M, "source_hashes", {"fixed": "a" * 64}),
                                      (M.GENERATIONS, "interpreter_identity", {"fixed": "b" * 64}),
                                      (M.GENERATIONS, "verify_interpreter_identity", True)):
                stack.enter_context(mock.patch.object(owner, name, return_value=value))
            if clock is not None:
                stack.enter_context(mock.patch.object(M.time, "monotonic", side_effect=clock))
            result = M.supervise(self.root)
        wrapper.COMMAND.command.assert_called_once()
        return result

    def test_supervisor_emits_safe_failure_and_actual_child_status(self):
        result = self.supervised(clock=[1.0, 2.0])
        self.assertIn("child_diagnostic", result)
        summary = result["child_diagnostic"]
        self.assertEqual(summary["status"], "decoded")
        self.assertEqual(summary["failures"], {"first_failure": self.failure})
        self.assertEqual((summary["returncode"], summary["observed_returncode"], summary["wall_seconds"]),
                         (125, 125, 0.25))
        self.assertEqual(set(summary["original_sha256"]), {"command", "stdout", "stderr"})
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["full_call_wall_seconds_before_receipt"], 1.0)
        self.assertEqual(result["charged_wall_seconds_by_arm"], {arm: 1.0 for arm in M.GENERATIONS.ARMS})
        with mock.patch.object(M, "load_wrapper") as wrapper, mock.patch.object(M, "supervise", return_value=result), \
             mock.patch.object(sys, "argv", ["controller", "--scratch-root", str(self.root)]), \
             contextlib.redirect_stdout(io.StringIO()) as stdout:
            wrapper.return_value.fixed_root.return_value = self.root
            self.assertEqual(M.main(), 125)
        public = json.loads(stdout.getvalue())
        self.assertEqual(public["child_diagnostic"], summary)
        self.assertNotIn(str(self.root), stdout.getvalue())
        self.assertIs(public["accepted"], False)

    def test_early_refusal_and_close_recovery_fields_are_safe_projections(self):
        refusal = dict(status="refused", failure_type="PermissionError", failure_sha256="d" * 64)
        value = self.diagnostic("", json.dumps(refusal))
        self.assertEqual(value["source"], "stderr")
        self.assertEqual(value["failures"]["first_failure"]["phase"], None)
        self.inner["receipt_failure"] = dict(self.failure, phase="final-receipt")
        self.inner["receipt_recovery_failure"] = dict(failure_type="OSError", failure_sha256="e" * 64)
        value = self.diagnostic()
        self.assertEqual(set(value["failures"]), {"first_failure", "receipt_failure", "receipt_recovery_failure"})
        self.assertEqual(value["failures"]["first_failure"], self.failure)

    def test_arbitrary_paths_secrets_fields_types_and_hashes_never_escape(self):
        secret = "/private/customer/token=secret-value"
        variants = []
        for key in ("phase", "failure_type", "failure_sha256", "extra"):
            value = copy.deepcopy(self.inner)
            value["first_failure"][key] = secret
            variants.append(value)
        for key, entry in (("phase", ["before-compilation"]), ("failure_sha256", "A" * 64),
                           ("failure_sha256", "c" * 63), ("failure_type", True)):
            value = copy.deepcopy(self.inner)
            value["first_failure"][key] = entry
            variants.append(value)
        variants.extend(({**self.inner, "unexpected": secret}, {**self.inner, "accepted": 0},
                         {**self.inner, "actual_engine_calls": False}, {**self.inner, "exit_code": False}))
        for inner in variants:
            with self.subTest(inner=inner):
                value = self.diagnostic(json.dumps(inner), secret)
                self.assertEqual(value["status"], "unavailable")
                self.assertEqual(value["failures"], {})
                self.assertNotIn(secret, json.dumps(value))
        with tempfile.TemporaryDirectory() as directory:
            self.root = Path(directory).resolve()
            self.output = self.root / "native-generation-supervisor"
            result = self.supervised(json.dumps(variants[0]), secret)
        self.assertEqual(result["exit_code"], 125)
        self.assertNotIn(secret, json.dumps(result["child_diagnostic"]))

    def test_missing_malformed_duplicate_and_nonregular_receipts_are_unavailable(self):
        for text in ("", "not json /private/secret", "[]", "null", '{"status":1,"status":2}',
                     '{"status":NaN}', '{"status":Infinity}', json.dumps({"status": "refused"})):
            with self.subTest(text=text):
                self.assertEqual(self.diagnostic(text)["status"], "unavailable")
        originals = self.files()
        target = self.output / "command.stdout"
        target.unlink()
        self.assertEqual(M.child_diagnostic(self.output, self.row, originals)["status"], "unavailable")
        target.symlink_to(self.output / "command.stderr")
        self.assertEqual(M.child_diagnostic(self.output, self.row, originals)["status"], "unavailable")
        target.unlink()
        target.mkdir()
        self.assertEqual(M.child_diagnostic(self.output, self.row, originals)["status"], "unavailable")

    def test_changed_oversize_or_unreadable_receipt_preserves_failure(self):
        originals = self.files()
        path = self.output / "command.stdout"
        path.write_text(json.dumps({**self.inner, "first_failure": dict(self.failure, phase="after-generation")}))
        self.assertEqual(M.child_diagnostic(self.output, self.row, originals)["status"], "unavailable")
        with path.open("w") as stream:
            stream.truncate(8 * 1024**2 + 1)
        self.assertEqual(M.child_diagnostic(self.output, self.row, originals)["status"], "unavailable")
        with mock.patch.object(M.GENERATIONS.SELECTOR, "file_identity", side_effect=PermissionError("secret-path")):
            value = M.child_diagnostic(self.output, self.row, originals)
        self.assertEqual(value["status"], "unavailable")
        self.assertNotIn("secret-path", json.dumps(value))

    def test_typed_child_values_refuse_booleans_nonfinite_and_missing(self):
        for field, value in (("returncode", True), ("observed_returncode", False), ("returncode", "125"),
                             ("returncode", 256), ("wall_seconds", True), ("wall_seconds", float("inf")),
                             ("wall_seconds", float("nan")), ("wall_seconds", -1), ("wall_seconds", 10**400)):
            with self.subTest(field=field, value=value):
                row = {**self.row, field: value}
                result = M.child_diagnostic(self.output, row, {})
                self.assertIsNone(result[field])
                json.dumps(result, allow_nan=False)
        self.assertEqual(M.child_diagnostic(self.output, {}, {})["status"], "unavailable")

    def test_unfinished_or_unknown_cleanup_never_reads_originals(self):
        for change in ({"cleanup_root_unfinished": True}, {"cleanup_root_unfinished": None},
                       {"observed_returncode": None}, {"observed_returncode": False}):
            with self.subTest(change=change), mock.patch.object(M.GENERATIONS.SELECTOR, "file_identity") as identity:
                result = M.child_diagnostic(self.output, {**self.row, **change}, {})
                self.assertEqual(result["status"], "unavailable")
                identity.assert_not_called()
        self.row["cleanup_root_unfinished"] = True
        with mock.patch.object(M, "reference") as reference:
            result = self.supervised()
        reference.assert_not_called()
        self.assertEqual(result["originals"], {})
        self.assertEqual(result["exit_code"], 125)

    def test_success_json_does_not_override_actual_125_and_success_has_no_failure(self):
        self.inner.pop("first_failure")
        self.inner.update(status="validation-candidate-complete", exit_code=0)
        result = self.supervised()
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["child_diagnostic"]["failures"], {})
        self.assertEqual(result["child_diagnostic"]["observed_returncode"], 125)
        with tempfile.TemporaryDirectory() as directory:
            self.root = Path(directory).resolve()
            self.output = self.root / "native-generation-supervisor"
            self.row.update(returncode=0, observed_returncode=0, passed=True)
            result = self.supervised()
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["child_diagnostic"]["failures"], {})
        self.assertIs(result["accepted"], False)

    def test_supervisor_unavailable_originals_preserve_actual_failure_and_refuse_success(self):
        def corrupt(output, kind):
            target = output / "command.stdout"
            target.unlink()
            if kind == "symlink":
                target.symlink_to(output / "command.stderr")
            elif kind == "oversize":
                with target.open("w") as stream:
                    stream.truncate(8 * 1024**2 + 1)
        for code in (0, 125):
            self.row.update(returncode=code, observed_returncode=code, passed=code == 0)
            for kind in ("missing", "symlink", "oversize", "unreadable"):
                with self.subTest(code=code, kind=kind), tempfile.TemporaryDirectory() as directory:
                    self.root = Path(directory).resolve()
                    self.output = self.root / "native-generation-supervisor"
                    with contextlib.ExitStack() as stack:
                        if kind == "unreadable":
                            stack.enter_context(mock.patch.object(M, "reference", side_effect=PermissionError("secret")))
                        result = self.supervised(mutate=lambda output: corrupt(output, kind))
                    self.assertEqual(result["exit_code"], 125)
                    self.assertEqual(result["command"]["observed_returncode"], code)
                    self.assertEqual(result["child_diagnostic"]["observed_returncode"], code)
                    self.assertEqual(result["child_diagnostic"]["status"], "unavailable")
                    self.assertEqual(result["originals"], {})
                    self.assertNotIn("secret", json.dumps(result))

    def test_diagnostic_reads_are_inside_existing_full_caller_cost(self):
        now = [1.0]
        original = M.child_diagnostic
        def slow(*args):
            value = original(*args)
            now[0] += 0.75
            return value
        with mock.patch.object(M, "child_diagnostic", side_effect=slow):
            result = self.supervised(clock=lambda: now[0])
        self.assertEqual(result["full_call_wall_seconds_before_receipt"], 0.75)
        self.assertEqual(result["command"]["wall_seconds"], 0.25)
        self.assertEqual(result["charged_wall_seconds_by_arm"], {arm: 0.75 for arm in M.GENERATIONS.ARMS})


class FailureCapsuleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        expected, _ = M.GENERATIONS.NATIVE.expectation()
        self.env = mock.patch.dict(os.environ, {**expected["runner"], "DEVELOPER_DIR": expected["developer_lexical"],
                                               "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
                                               "GENERATION_STATUS_FINALIZED": "true"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.mode = "installation"
        self.mutate = None
        self.calls = []
        for owner, name, kwargs in ((M, "load_wrapper", dict(return_value=W)),
                                   (W, "generation_controller", dict(return_value=M)),
                                   (W, "fixed_root", dict(return_value=self.root)),
                                   (W.COMMAND, "command", dict(side_effect=self.command))):
            patch = mock.patch.object(owner, name, **kwargs)
            patch.start()
            self.addCleanup(patch.stop)
        # 소유한 명령 seam 밖에서는 합성 제어도 프로세스를 시작하지 못한다.
        patch = mock.patch.object(W.COMMAND.subprocess, "Popen", side_effect=AssertionError("unplanned subprocess"))
        patch.start()
        self.addCleanup(patch.stop)

    def command(self, argv, cwd, stem, environment, bound):
        self.calls.append((argv, bound))
        out, err = io.StringIO(), io.StringIO()
        stem.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
             mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(sys, "argv", argv[4:]):
            if "--execute-controller" in argv:
                code = M.main()
            elif "--execute-stage" in argv:
                code = W.main()
            else:
                raise AssertionError("Unplanned command")
        row = dict(command=argv, cwd=str(cwd), returncode=code, observed_returncode=code,
                   completed=code != 125, passed=code == 0, failure="nested-incomplete" if code == 125 else None,
                   wall_seconds=0.01, cleanup_signals=[], cleanup_root_unfinished=False,
                   stdout=str(stem) + ".stdout", stderr=str(stem) + ".stderr")
        if self.mutate is not None:
            self.mutate(stem, row)
        M.save(Path(str(stem) + ".json"), row)
        Path(row["stdout"]).write_text(out.getvalue())
        Path(row["stderr"]).write_text(err.getvalue())
        return row

    def execute(self, *, before_context=False, pre_receipt=False, capture_error=False):
        with contextlib.ExitStack() as stack:
            if before_context:
                stack.enter_context(mock.patch.object(M, "create_context", side_effect=ValueError("private /context")))
            if pre_receipt:
                stack.enter_context(mock.patch.object(W, "stage", side_effect=ValueError("private /pre-receipt")))
            elif capture_error:
                stack.enter_context(mock.patch.object(W, "bound_machine_fields", return_value=(None, {})))
                def native(output, **options):
                    options["diagnostic"].update(checkpoint="native-admission", nested_material_safe=True,
                                                 probes={}, probe_order=[], active_probe=None)
                    return dict(layout=dict(roots={"SDK": str(self.root / "sdk")}), selected={})
                stack.enter_context(mock.patch.object(W.admission, "collect_native", side_effect=native))
                stack.enter_context(mock.patch.object(W.admission.SEAL, "capture", side_effect=OSError("private capture secret")))
            else:
                stack.enter_context(mock.patch.object(W, "bound_machine_fields", side_effect=ValueError("private installation token")))
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                 mock.patch.object(sys, "argv", ["controller", "--scratch-root", str(self.root)]):
                code = M.main()
        M.save(self.root / "generation-invocation-status.json", dict(schema_version=1, mode="sdk-generation-only",
               source_sha="a" * 40, actual_shell_exit=code, checkpoint="invocation-returned",
               run_id=123, run_attempt=1, prelaunch_outputs_absent=True))
        self.assertNotEqual(code, 0)
        return code

    def publish(self, expected=0):
        with contextlib.redirect_stdout(io.StringIO()) as stdout, contextlib.redirect_stderr(io.StringIO()) as stderr, \
             mock.patch.object(sys, "argv", ["wrapper", "--stage", "publish", "--scratch-root", str(self.root),
                                             "--generation-publication"]):
            code = W.main()
        self.assertEqual(code, expected, stderr.getvalue())
        emitted = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn(str(self.root), emitted)
        self.assertNotIn("private", emitted)
        if code == 0:
            value = M.read(self.root / "native-calibration-sdk-public/results.json")
            self.assertEqual(value["role"], "sdk-generation-failure-capsule-v1")
            self.assertFalse(value["accepted"])
            self.assertFalse(value["final_protocol_ready"])
            self.assertIsNone(value["actual_compiler_commands"])
            self.assertIsNone(value["actual_full_sdk_reads"])
            self.assertEqual(value["actual_engine_calls"], 0)
            self.assertEqual(len(value["slots"]), 78)
            self.assertNotIn(str(self.root), json.dumps(value))
            return value
        return None

    def test_precontext_failure_publishes_without_any_sdk_results(self):
        code = self.execute(before_context=True)
        self.assertFalse((self.root / "native-calibration-sdk-raw").exists())
        value = self.publish()
        self.assertEqual(value["execution_exit"], code)
        slots = {x["slot"]: x for x in value["slots"]}
        self.assertEqual(slots["context"]["status"], "unavailable")
        self.assertEqual(slots["phase-command:before-compilation"]["status"], "withheld-unstable")

    def test_exact_run7_shaped_safe_stderr_survives_missing_phase_parent(self):
        self.execute(pre_receipt=True)
        self.assertFalse((self.root / "native-calibration-sdk-raw").exists())
        value = self.publish()
        slots = {x["slot"]: x for x in value["slots"]}
        observed = slots["phase-command:before-compilation"]["observation"]
        self.assertEqual(observed["reported_observed_returncode"], 1)
        self.assertEqual(observed["streams"]["stderr"]["safe_json"]["schema"], "early-refusal")
        self.assertEqual(slots["phase-result:before-compilation"]["status"], "unavailable")
        self.assertEqual(observed["streams"]["stderr"]["safe_json"]["failure"]["failure_sha256"],
                         hashlib.sha256(b"private /pre-receipt").hexdigest())

    def test_real_stage_installation_failure_publishes_safe_chain(self):
        self.execute()
        value = self.publish()
        slots = {x["slot"]: x for x in value["slots"]}
        chain = slots["phase-result:before-compilation"]["observation"]["failure_chain"]
        self.assertEqual(chain[0]["checkpoint"], "installation-binding")
        self.assertEqual(chain[0]["failure_type"], "ValueError")
        self.assertFalse((self.root / "native-calibration-sdk-raw/before-compilation/seal.json").exists())

    def test_real_admission_capture_failure_retains_original_reason_hash(self):
        self.execute(capture_error=True)
        value = self.publish()
        slots = {x["slot"]: x for x in value["slots"]}
        observed = slots["sdk-admission:before-compilation"]["observation"]
        self.assertEqual(observed["checkpoint"], "sdk-capture")
        self.assertEqual(observed["failure_chain"][-1]["failure_sha256"],
                         hashlib.sha256(b"private capture secret").hexdigest())

    def test_unfinished_phase_blocks_its_streams_and_lower_writer_reads(self):
        def change(stem, row):
            if stem.parent.name == "before-compilation":
                row.update(cleanup_root_unfinished=True, observed_returncode=None)
        self.mutate = change
        self.execute()
        value = self.publish()
        slots = {x["slot"]: x for x in value["slots"]}
        self.assertEqual(slots["phase-command:before-compilation"]["observation"]["streams"]["stderr"]["status"],
                         "withheld-unstable")
        self.assertEqual(slots["sdk-admission:before-compilation"]["status"], "withheld-unstable")

    def test_unfinished_supervisor_blocks_all_lower_reads(self):
        def change(stem, row):
            if stem.parent.name == "native-generation-supervisor":
                row.update(cleanup_root_unfinished=True, observed_returncode=None)
        self.mutate = change
        self.execute()
        value = self.publish()
        slots = {x["slot"]: x for x in value["slots"]}
        self.assertEqual(slots["controller"]["status"], "withheld-unstable")
        self.assertEqual(slots["context"]["status"], "withheld-unstable")

    def test_disk_success_never_replaces_actual_nonzero_invocation(self):
        self.execute(before_context=True)
        path = self.root / "native-calibration-sdk-calls/generation-controller.json"
        value = M.read(path);value.update(status="validation-candidate-complete",exit_code=0)
        path.write_text(json.dumps(value))
        capsule = self.publish()
        self.assertEqual(capsule["execution_exit"],125)
        self.assertEqual(capsule["status"],"incomplete")

    def test_actual_zero_never_downgrades_failed_candidate_verification(self):
        self.execute(before_context=True)
        path=self.root/'generation-invocation-status.json';value=M.read(path);value['actual_shell_exit']=0
        path.write_text(json.dumps(value))
        with mock.patch.object(M, "publish_failure_capsule", side_effect=AssertionError("forbidden downgrade")) as capsule:
            self.publish(expected=1)
        capsule.assert_not_called()
        self.assertFalse((self.root/'native-calibration-sdk-public').exists())

    def test_missing_shell_receipt_cannot_certify_or_publish(self):
        self.execute(before_context=True)
        (self.root/'generation-invocation-status.json').unlink()
        self.publish(expected=1)

    def test_rehashed_shell_status_fields_refuse(self):
        self.execute(before_context=True)
        path=self.root/'generation-invocation-status.json';original=M.read(path)
        for key,value in (('actual_shell_exit',True),('actual_shell_exit',256),('source_sha','b'*40),
                          ('checkpoint','secret /path'),('mode','calibration'),('extra','value')):
            changed=dict(original);changed[key]=value;path.write_text(json.dumps(changed))
            with self.subTest(key=key,value=value), self.assertRaises(ValueError):M.failure_capsule(self.root)
        path.write_text(json.dumps(original))

    def test_safe_stream_projection_rejects_unknown_duplicate_nonfinite_and_secrets(self):
        good=dict(status='refused',failure_type='ValueError',failure_sha256='f'*64)
        self.assertEqual(M.safe_stream(json.dumps(good))['status'],'decoded')
        bad=[json.dumps(dict(good,extra='private /path')),json.dumps(dict(good,failure_type='token=secret')),
             json.dumps(dict(good,failure_sha256='F'*64)),json.dumps(good)+'\n'+json.dumps(good),
             '{"status":"refused","status":"refused"}', '{"value":NaN}', 'x'*65537,
             '/private/unstructured', json.dumps(dict(good,failure_type=['ValueError']))]
        for value in bad:
            with self.subTest(value=value[:40]):self.assertEqual(M.safe_stream(value),dict(status='unavailable'))

    def test_original_stream_mutation_refuses_even_with_safe_replacement(self):
        self.execute(pre_receipt=True)
        path=self.root/'native-calibration-sdk-calls/before-compilation/command.stderr'
        path.write_text(json.dumps(dict(status='refused',failure_type='ValueError',failure_sha256='f'*64)))
        self.publish(expected=1)

    def test_endpoint_mutation_and_missing_file_refuse(self):
        self.execute(pre_receipt=True)
        original=W.NORMALIZER.package
        def package(args):
            value=original(args)
            (self.root/'native-calibration-sdk-calls/before-compilation/command.stderr').unlink()
            return value
        with mock.patch.object(W.NORMALIZER,'package',side_effect=package):self.publish(expected=1)

    def test_scanner_refusal_stays_refusal_and_never_uploads_raw(self):
        self.execute(pre_receipt=True)
        with mock.patch.object(W.NORMALIZER,'package',side_effect=W.NORMALIZER.PublicationBlocked('private refusal')):
            self.publish(expected=1)
        self.assertFalse((self.root/'native-calibration-sdk-public').exists())
        self.assertEqual(sorted(p.name for p in (self.root/'native-calibration-sdk-staging').iterdir()),['results.json'])

    def test_fixed_slots_caps_and_symlink_oversize_are_not_bypassed(self):
        self.assertEqual(len(M.CAPSULE_SLOTS),78)
        self.assertEqual(len(M.CAPSULE_PATHS),150)
        self.assertEqual((M.CAPSULE_MAX_FILE,M.CAPSULE_MAX_TOTAL),(8*1024**2,64*1024**2))
        path=self.root/'generation-invocation-status.json';path.symlink_to('/dev/null')
        with self.assertRaises(ValueError):M.CapsuleReader(self.root).original('generation-invocation-status.json')
        path.unlink()
        with path.open('wb') as stream:stream.truncate(M.CAPSULE_MAX_FILE+1)
        with self.assertRaises(ValueError):M.CapsuleReader(self.root).original('generation-invocation-status.json')
        with self.assertRaises(ValueError):M.CapsuleReader(self.root).original('unknown.json')

    def test_existing_shell_receipt_and_publication_are_never_overwritten(self):
        self.execute(before_context=True)
        path=self.root/'generation-invocation-status.json';before=path.read_bytes()
        with self.assertRaises(FileExistsError):M.save(path,dict(actual_shell_exit=0))
        self.assertEqual(path.read_bytes(),before)
        self.publish()
        before=(self.root/'native-calibration-sdk-public/results.json').read_bytes()
        with self.assertRaises(FileExistsError):M.publish_failure_capsule(self.root,{},W.NORMALIZER)
        self.assertEqual((self.root/'native-calibration-sdk-public/results.json').read_bytes(),before)


class CapsuleProducerFixture:
    """네이티브 관측만 합성하고 모든 생산자·검증·정규화 함수를 실제로 호출한다."""
    def __init__(self, case, name="route", fault=None):
        self.case, self.fault = case, fault
        self.stack = contextlib.ExitStack()
        case.addCleanup(self.stack.close)
        self.base = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.root = self.base / name
        self.root.mkdir()
        self.developer = self.base / "inputs/Xcode.app/Contents/Developer"
        self.chain = self.developer / "Toolchains/XcodeDefault.xctoolchain"
        self.sdk = self.developer / "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        self.expected = copy.deepcopy(M.GENERATIONS.NATIVE.expectation()[0])
        self.expected.update(developer_lexical=str(self.developer), developer_physical=str(self.developer),
                             roots=dict(SDK=str(self.sdk), TOOLCHAIN=str(self.chain)), sdk_aliases=[str(self.sdk)])
        for path in (self.sdk / "usr/include/c++/v1", self.sdk / "usr/lib/swift", self.sdk / "Library",
                     self.sdk / "System/Library/Frameworks", self.sdk / "System/Library/SubFrameworks",
                     self.chain / "usr/include", self.chain / "usr/lib/clang/21/include",
                     self.chain / "usr/lib/swift/iphonesimulator", self.developer / "host-runtime"):
            path.mkdir(parents=True, exist_ok=True)
        (self.sdk / "usr/include/input.h").write_text("synthetic SDK bytes\n")
        self.tools = {name: self.chain / suffix for name, suffix in dict(
            swift="usr/bin/swiftc", swift_frontend="usr/bin/swift-frontend", clang="usr/bin/clang",
            index_library="usr/lib/libIndexStore.dylib").items()}
        self.tools["xcrun"] = self.developer / "usr/bin/xcrun"
        for name, path in self.tools.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            if name == "swift": path.symlink_to("swift-frontend")
            else: path.write_text("synthetic native tool " + name + "\n")
        self.expected["tools"] = {name: dict(allowed_paths=["/usr/bin/xcrun" if name == "xcrun" else str(path)],
            physical_path=str(path.resolve()), **{k: v for k, v in M.GENERATIONS.SELECTOR.file_identity(path.resolve()).items()
                                                    if k in ("sha256", "bytes")}) for name, path in self.tools.items()}
        self.expected_path = self.base / "fixture-expectation.json"
        self.expected_path.write_text(json.dumps(self.expected, sort_keys=True))
        self.expected_sha = hashlib.sha256(self.expected_path.read_bytes()).hexdigest()
        self.baseline = M.GENERATIONS.SEAL.capture({k: Path(v) for k, v in self.expected["roots"].items()})["content_sha256"]
        self.calls, self.compiler_calls, self.sleeps = [], [], []
        self.timer_stack = [dict(timer=(0.0, 0.0), handler=signal.SIG_DFL)]
        self.processes, self.next_pid = {}, 1000
        self.changed = False
        self.old_spec = importlib.util.spec_from_file_location
        self.old_exec = importlib.machinery.SourceFileLoader.exec_module
        self.old_resolve, self.old_stat, self.old_open, self.old_mkdir = Path.resolve, Path.stat, Path.open, Path.mkdir
        self.original_command_save = W.COMMAND.save
        self.configure(M.GENERATIONS)
        self.configure(W.admission)
        self.patch(M, "load_wrapper", lambda: W)
        self.patch(W, "generation_controller", lambda: M)
        self.patch(importlib.machinery.SourceFileLoader, "exec_module", lambda loader, module: self.exec_module(loader, module))
        self.patch(Path, "resolve", lambda path, strict=False: self.resolve(path, strict))
        self.patch(Path, "stat", lambda path, **kwargs: self.stat(path, **kwargs))
        self.patch(Path, "open", lambda path, *args, **kwargs: self.open(path, *args, **kwargs))
        self.patch(Path, "mkdir", lambda path, *args, **kwargs: self.mkdir(path, *args, **kwargs))
        self.patch(W.COMMAND, "save", self.command_save)
        self.patch(sys, "platform", "darwin")
        self.patch(platform, "system", lambda: "Darwin")
        self.patch(platform, "machine", lambda: "arm64")
        self.patch(platform, "platform", lambda: "synthetic-darwin-observation")
        self.patch(signal, "getitimer", self.getitimer)
        self.patch(signal, "setitimer", self.setitimer)
        self.patch(signal, "signal", self.signal)
        self.patch(time, "sleep", self.sleep)
        self.patch(subprocess, "Popen", self.popen)
        self.patch(subprocess, "run", self.compiler_run)
        self.patch(os, "killpg", self.killpg)
        self.stack.enter_context(mock.patch.dict(os.environ, {**self.expected["runner"],
            "DEVELOPER_DIR": str(self.developer), "RUNNER_TEMP": str(self.root), "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "GENERATION_STATUS_FINALIZED": "true"}, clear=True))
        self.stack.enter_context(mock.patch.dict(sys.modules, {"psutil": types.SimpleNamespace(__version__="7.2.2")}))
        self.original_sys_path = list(sys.path)
        self.stack.callback(lambda: sys.path.__setitem__(slice(None), self.original_sys_path))
        self.installation()
        if self.fault == "installation":
            target = self.root / "measurement-helper-raw/setup/install.json"
            value = M.read(target); value["observed_returncode"] = 1
            target.write_text(json.dumps(value))
        elif self.fault == "installation-python":
            target = self.root / "measurement-helper-raw/setup/install-interpreter.json"
            value = M.read(target); value["after"]["sha256"] = "f" * 64
            target.write_text(json.dumps(value))

    def patch(self, owner, name, value):
        return self.stack.enter_context(mock.patch.object(owner, name, value))

    def configure(self, module):
        name = Path(module.__file__).name
        if name == "native_generation_inputs.py":
            self.patch(module, "BASELINE_SHA256", self.baseline)
            self.patch(module, "EXPECTATION_SHA256", self.expected_sha)
            self.configure(module.NATIVE)
            self.configure(module.SELECTOR)
        elif name == "native_calibration_inputs.py":
            self.patch(module, "EXPECTATION", self.expected_path)
            self.configure(module.SELECTOR)
        elif name == "select_sdk_roots.py":
            self.patch(module, "REVIEWED_COMPILER_SHA256", {
                key: self.expected["tools"][key]["sha256"] for key in module.REVIEWED_COMPILER_SHA256})
        elif name == "validate-native-sdk-discovery.py":
            self.configure(module.SELECTOR)

    def exec_module(self, loader, module):
        self.old_exec(loader, module)
        if Path(module.__file__).name in ("native_generation_inputs.py", "native_calibration_inputs.py",
                                          "select_sdk_roots.py", "validate-native-sdk-discovery.py"):
            self.configure(module)

    def resolve(self, path, strict=False):
        if str(path) == "/usr/bin/xcrun": return self.old_resolve(self.tools["xcrun"], strict=strict)
        if str(path) == "/usr/lib/swift": return path
        return self.old_resolve(path, strict=strict)

    def stat(self, path, **kwargs):
        if self.fault == "capture-inventory" and path == self.sdk / "usr/include/input.h" and len(self.calls) >= 17:
            raise PermissionError("private inventory failure")
        mapped = self.tools["xcrun"] if str(path) == "/usr/bin/xcrun" else (
            self.developer / "host-runtime" if str(path) == "/usr/lib/swift" else path)
        return self.old_stat(mapped, **kwargs)

    def mkdir(self, path, *args, **kwargs):
        if self.fault == "pre-context" and path == self.root / "native-generation-home":
            raise PermissionError("private pre-context")
        return self.old_mkdir(path, *args, **kwargs)

    def open(self, path, *args, **kwargs):
        mode = args[0] if args else kwargs.get("mode", "r")
        writing = any(flag in mode for flag in ("w", "a", "x", "+"))
        relative = str(path.relative_to(self.root)) if path.is_relative_to(self.root) else ""
        targets = {
            "pre-phase-receipt": "native-calibration-sdk-raw/results.json",
            "capture-write": "native-calibration-sdk-raw/before-compilation/seal.json",
        }
        if writing and relative == targets.get(self.fault):
            raise PermissionError("private receipt write")
        stream = self.old_open(self.tools["xcrun"] if str(path) == "/usr/bin/xcrun" else path, *args, **kwargs)
        close_targets = {
            "capture-close": "native-calibration-sdk-raw/before-compilation/seal.json",
            "admission-close": "native-calibration-sdk-raw/before-compilation/results.json",
            "phase-close": "native-calibration-sdk-raw/setup/phases/before-compilation.json",
            "controller-close": "native-calibration-sdk-calls/generation-controller.json",
            "post-capture-alias": "native-calibration-sdk-raw/before-compilation/seal.json",
            "context-admission": "native-calibration-sdk-calls/generation-context.json",
        }
        if writing and relative == close_targets.get(self.fault) and not self.changed:
            fixture = self
            class CloseBoundary:
                def __getattr__(self, key): return getattr(stream, key)
                def __enter__(self): return self
                def __exit__(self, *ignored): self.close()
                def close(self):
                    stream.close()
                    if fixture.changed: return
                    fixture.changed = True
                    if fixture.fault == "post-capture-alias":
                        (fixture.chain / "usr/include/c++/v1").mkdir(parents=True)
                    elif fixture.fault == "context-admission":
                        value = json.loads(path.read_text()); value["helper_sha256"] = {}
                        path.write_text(json.dumps(value))
                    else: raise OSError("private close failure")
            return CloseBoundary()
        return stream

    def command_save(self, path, value):
        # 재해시된 모순 영수증도 안전 판정을 통과하지 못하는지 실제 호출 경로에서 검사한다.
        if path.name == "machine-hw_machine.json" and self.fault in (
                "probe-contradiction", "probe-bool", "probe-late", "probe-ownership", "probe-wait-ownership"):
            if self.fault == "probe-contradiction": value.update(observed_returncode=1, returncode=0, completed=True, passed=True)
            elif self.fault == "probe-bool": value["observed_returncode"] = False
            elif self.fault == "probe-late": value["wall_seconds"] = 30.001
            elif self.fault == "probe-ownership": value["ownership_uncertain"] = True
            else: value["wait_ownership_uncertain"] = True
        if path.parent.name == "before-compilation" and path.name == "command.json" and self.fault == "phase-late":
            value["wall_seconds"] = 570.001
        if path.parent.name == "before-compilation" and path.name == "command.json" and self.fault in (
                "phase-ownership", "phase-wait-ownership"):
            value["ownership_uncertain" if self.fault == "phase-ownership" else "wait_ownership_uncertain"] = True
        self.original_command_save(path, value)

    def getitimer(self, kind):
        self.case.assertEqual(kind, signal.ITIMER_REAL)
        return self.timer_stack[-1]["timer"]

    def setitimer(self, kind, seconds, interval=0.0):
        self.case.assertEqual(kind, signal.ITIMER_REAL)
        old = self.timer_stack[-1]["timer"]
        self.timer_stack[-1]["timer"] = (float(seconds), float(interval))
        return old

    def signal(self, kind, handler):
        self.case.assertEqual(kind, signal.SIGALRM)
        old = self.timer_stack[-1]["handler"]
        self.timer_stack[-1]["handler"] = handler
        return old

    def sleep(self, seconds):
        self.case.assertEqual(seconds, 1.1)
        self.sleeps.append(seconds)

    def installation(self):
        # 공식 설치를 가장하지 않는 작은 파일 fixture를 기존 설치 검증기로 다시 읽는다.
        binding = W.installation_binding
        output = self.root / "measurement-helper-raw"
        target = self.root / "measurement-helper-dependencies"
        (target / "psutil").mkdir(parents=True)
        (target / "psutil/__init__.py").write_text('__version__ = "7.2.2"\n')
        dist = target / "psutil-7.2.2.dist-info"; dist.mkdir()
        (dist / "METADATA").write_text("Metadata-Version: 2.4\nName: psutil\nVersion: 7.2.2\n")
        (dist / "RECORD").write_text("synthetic fixture only\n")
        raw = b'{"fixture":"synthetic-installation-observation"}'
        report = output / "private-setup/install-report.json"
        report.parent.mkdir(parents=True); report.write_bytes(raw)
        provenance = dict(schema_version=1, source_format="pip-install-report-v1", report_version="1", pip_version="26.2.1",
            raw_report=dict(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                private_relative_path="private-setup/install-report.json", publication="Original kept private"),
            distributions=[dict(name="psutil", version="7.2.2", requested=True, is_direct=False, is_yanked=False,
                sha256="a" * 64, url="https://files.pythonhosted.org/packages/aa/bb/" + "c" * 60 +
                "/psutil-7.2.2-cp36-abi3-macosx_11_0_arm64.whl")], omitted_metadata=binding.OMISSIONS)
        argv = [sys.executable, "-m", "pip", "install", "--index-url", "https://pypi.org/simple", "--no-input",
                "--disable-pip-version-check", "--no-cache-dir", "--only-binary=:all:", "--target", str(target),
                "--report", str(report), "-r", str(ROOT / "Scripts/benchmark-measurement/requirements.txt")]
        install = dict(command=argv, cwd=str(ROOT), completed=True, passed=True, returncode=0, observed_returncode=0,
                       failure=None, cleanup_root_unfinished=False, cleanup_signals=[], wall_seconds=0.001)
        python = W.COMMAND.interpreter_observation(sys.executable)
        interpreter = dict(schema_version=1, status="matched", before=python, after=copy.deepcopy(python),
            cost_accounting="Capture costs are nested in diagnostic wall, outside command-only install wall",
            scope="Prospective selected interpreter identity only; no dynamic-loader or wheel equivalence proof")
        results = dict(status="completed-synthetic-native-validation", final_comparison=False,
            phases={key: copy.deepcopy(install) for key in ("install", "tests", "machine", "calibration")},
            helper_hashes={p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in binding.HELPER_PATHS},
            install_provenance=provenance, install_interpreter=interpreter,
            install_provenance_wall_seconds=0.001, diagnostic_wall_seconds=0.01)
        for relative, value in (("results.json", results), ("setup/install.json", install),
                                ("setup/install-provenance.json", provenance), ("setup/install-interpreter.json", interpreter)):
            M.save(output / relative, value)

    def native_output(self, argv):
        if argv[0] == "/usr/sbin/sysctl":
            if self.fault == "machine-mismatch" and argv[-1] == "hw.memsize": return "1", ""
            if self.fault == "malformed-native" and argv[-1] == "hw.physicalcpu": return "private-invalid-int", ""
            fields = dict(zip(("hw.machine", "hw.physicalcpu", "hw.logicalcpu", "hw.memsize", "machdep.cpu.brand_string",
                               "kern.osrelease", "kern.osproductversion"),
                              ("architecture", "physical_core_count", "logical_core_count", "ram_bytes", "cpu_model",
                               "kernel_release", "os_version")))
            return str(self.expected["machine"][fields[argv[-1]]]), ""
        if "--show-sdk-path" in argv: return str(self.sdk), ""
        if "--show-sdk-platform-path" in argv: return str(self.sdk.parents[2]), ""
        if "--find" in argv: return str(self.tools["swift" if argv[-1] == "swiftc" else "clang"]), ""
        if "-buildVersion" in argv: return self.expected["versions"]["os_build"], ""
        if Path(argv[0]).name == "xcodebuild": return self.expected["versions"]["xcode"], ""
        if "--show-sdk-version" in argv:
            return "0.0" if self.fault == "version-mismatch" else self.expected["versions"]["sdk_version"], ""
        if "--show-sdk-build-version" in argv: return self.expected["versions"]["sdk_build"], ""
        if "--version" in argv: return self.expected["versions"]["swift"] if Path(argv[0]).name == "swiftc" else "synthetic clang", ""
        if "-help" in argv or "--help" in argv: return "synthetic help", ""
        if "-print-resource-dir" in argv: return str(self.chain / "usr/lib/clang/21"), ""
        if "-print-target-info" in argv:
            return json.dumps(dict(compilerVersion=M.GENERATIONS.SELECTOR.REVIEWED_SWIFT_VERSION,
                swiftCompilerTag="swiftlang-6.3.3.1.3", target=dict(triple=self.expected["target"], platform="iphonesimulator"),
                paths=dict(runtimeResourcePath=str(self.chain / "usr/lib/swift"),
                    runtimeLibraryPaths=[str(self.chain / "usr/lib/swift/iphonesimulator"), "/usr/lib/swift"],
                    runtimeLibraryImportPaths=[str(self.chain / "usr/lib/swift/iphonesimulator"), str(self.sdk / "usr/lib/swift")],
                    sdkPath=str(self.sdk)))), ""
        if "-E" in argv:
            language = argv[argv.index("-x") + 1]
            paths = [(argv[argv.index("-I") + 1], False)]
            absent = []
            if language in ("c++", "objective-c++"):
                paths.append((str(self.sdk / "usr/include/c++/v1"), False))
                absent.append(str(self.tools["clang"].parent / "../include/c++/v1"))
            absent += [str(self.sdk / p) for p in ("usr/local/include", "Library/Frameworks")]
            paths += [(str(p), framework) for p, framework in (
                (self.chain / "usr/lib/clang/21/include", False), (self.sdk / "usr/include", False),
                (self.chain / "usr/include", False), (self.sdk / "System/Library/Frameworks", True),
                (self.sdk / "System/Library/SubFrameworks", True))]
            text = "".join(f'ignoring nonexistent directory "{p}"\n' for p in absent)
            text += '#include "..." search starts here:\n#include <...> search starts here:\n'
            text += "".join(" " + p + (" (framework directory)" if framework else "") + "\n" for p, framework in paths)
            return "", text + "End of search list.\n"
        raise AssertionError("Unplanned native observation: " + repr(argv))

    def compiler_run(self, argv, *, cwd, capture_output, timeout):
        self.case.assertTrue(capture_output); self.case.assertGreater(timeout, 0)
        if "-index-store-path" not in argv:
            out, err = self.native_output(argv)
            return subprocess.CompletedProcess(argv, 0, out.encode(), err.encode())
        self.compiler_calls.append(list(argv))
        store = Path(argv[argv.index("-index-store-path") + 1])
        stage = store.parent.name
        if self.fault == "lifecycle-nonzero" and stage == "header_edit_rebuilt":
            return subprocess.CompletedProcess(argv, 3, b"", b"synthetic compiler refusal")
        if self.fault == "lifecycle-timeout" and stage == "header_edit_rebuilt":
            raise subprocess.TimeoutExpired(argv, timeout, output=b"synthetic partial compiler output")
        if stage == "header_delete_build_failed":
            return subprocess.CompletedProcess(argv, 1, b"", b"RenamedCore.h: file not found\n")
        outputs = []
        for flag in ("-o", "-emit-module-path", "-MF"):
            if flag in argv: outputs.append(Path(argv[argv.index(flag) + 1]))
        if "-output-file-map" in argv:
            mapping = json.loads(Path(argv[argv.index("-output-file-map") + 1]).read_text())
            outputs += [Path(row["object"]) for row in mapping.values()]
        for path in outputs:
            path.parent.mkdir(parents=True, exist_ok=True)
            text = "RenamedCore.h\n" if (Path(cwd) / "Sources/BridgeKit/include/RenamedCore.h").exists() else "CGCore.h\n"
            path.write_text(text if path.suffix == ".d" else "synthetic compiler output " + path.name)
        unit = store / "v5/units" / str(len(self.compiler_calls)); unit.parent.mkdir(parents=True, exist_ok=True)
        unit.write_text("synthetic completed unit")
        return subprocess.CompletedProcess(argv, 0, b"", b"")

    def popen(self, argv, *, cwd, env, stdout, stderr, start_new_session):
        self.case.assertTrue(start_new_session)
        if self.fault == "phase-launch" and "--execute-stage" in argv:
            raise OSError("private launch failure")
        if self.fault == "discovery-launch" and any(x.endswith("select_sdk_roots.py") for x in argv):
            raise OSError("private selector launch")
        self.next_pid += 1
        process = types.SimpleNamespace(pid=self.next_pid, returncode=None, invoked=False, argv=list(argv),
                                        cwd=Path(cwd), environment=dict(env), stdout=stdout, stderr=stderr)
        self.processes[process.pid] = process
        self.calls.append(list(argv))
        def wait(timeout):
            self.case.assertGreater(timeout, 0)
            if not process.invoked:
                process.invoked = True
                if argv[0] == "/usr/sbin/sysctl" and argv[-1] == "hw.physicalcpu" and self.fault in ("probe-timeout", "probe-cancel"):
                    if self.fault == "probe-timeout": raise subprocess.TimeoutExpired(argv, timeout)
                    raise KeyboardInterrupt("synthetic cancellation")
                process.returncode = self.dispatch(process)
            if process.returncode is None:
                raise subprocess.TimeoutExpired(argv, timeout)
            return process.returncode
        process.wait, process.poll = wait, lambda: process.returncode
        return process

    def killpg(self, pid, kind):
        self.case.assertIn(pid, self.processes)
        self.case.assertIn(kind, (signal.SIGTERM, signal.SIGKILL))
        self.processes[pid].returncode = -int(kind)

    def dispatch(self, process):
        argv = process.argv
        out, err = io.StringIO(), io.StringIO()
        self.timer_stack.append(dict(timer=(0.0, 0.0), handler=signal.SIG_DFL))
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                 mock.patch.dict(os.environ, process.environment, clear=True):
                script = next((Path(x) for x in argv if x.endswith(".py")), None)
                if script is None:
                    stdout, stderr = self.native_output(argv)
                    out.write(stdout); err.write(stderr); code = 0
                    if argv[0] == "/usr/sbin/sysctl" and argv[-1] == "hw.physicalcpu":
                        if self.fault == "probe-nonzero": code = 7
                        elif self.fault == "probe-125": code = 125
                        elif self.fault == "post-generation" and "/after-generation/" in str(process.cwd) + "/": code = 7
                else:
                    index = argv.index(str(script))
                    with mock.patch.object(sys, "argv", argv[index:]):
                        if script.name == "validate-native-sdk-generations.py": code = M.main()
                        elif script.name == "validate-native-calibration-inputs.py": code = W.main()
                        elif script.name == "run_ios_validation.py":
                            # 실제 별도 Python처럼 이 두 이름의 부모 vendor 모듈 캐시를 상속하지 않는다.
                            with mock.patch.dict(sys.modules), mock.patch.object(sys, "path", [str(script.parent), *sys.path]):
                                for name in ("compiler_generations", "validation_common"):
                                    sys.modules.pop(name, None)
                                module = load("capsule_real_lifecycle", script)
                                self.case.assertEqual(module.ROOT, script.parent)
                                self.case.assertEqual(Path(module.generations.__file__), script.parent / "compiler_generations.py")
                                code = module.main()
                        elif script.name == "validate-native-sdk-discovery.py":
                            with mock.patch.dict(sys.modules), mock.patch.object(sys, "path", list(sys.path)):
                                for name in ("compiler_generations", "validation_common"):
                                    sys.modules.pop(name, None)
                                module = load("capsule_real_discovery", script)
                                self.case.assertEqual(Path(module.GENERATIONS.__file__), module.FIXTURE / "compiler_generations.py")
                                self.case.assertEqual(Path(module.COMMON.__file__), module.FIXTURE / "validation_common.py")
                                try: module.main()
                                except SystemExit as error: code = error.code
                        elif script.name == "select_sdk_roots.py":
                            module = load("capsule_real_selector", script)
                            try: module.main()
                            except SystemExit as error: code = error.code
                        else: raise AssertionError("Unplanned helper: " + str(script))
        finally:
            self.timer_stack.pop()
        process.stdout.write(out.getvalue().encode()); process.stderr.write(err.getvalue().encode())
        return code

    def execute(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
             mock.patch.object(sys, "argv", ["controller", "--scratch-root", str(self.root)]):
            code = M.main()
        M.save(self.root / "generation-invocation-status.json", dict(schema_version=1, mode="sdk-generation-only",
            source_sha="a" * 40, actual_shell_exit=code, checkpoint="invocation-returned", run_id=123, run_attempt=1,
            prelaunch_outputs_absent=True))
        return code

    def publish(self):
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err, \
             mock.patch.object(sys, "argv", ["wrapper", "--stage", "publish", "--scratch-root", str(self.root), "--generation-publication"]):
            code = W.main()
        return code, out.getvalue() + err.getvalue()

    def diagnostics(self):
        # 실패 단정에도 고정된 합성 영수증의 안전한 관측/해시를 남겨 임시 파일 삭제 뒤 원인을 잃지 않는다.
        result = {}
        paths = {"controller": "native-calibration-sdk-calls/generation-controller.json",
                 "phase": "native-calibration-sdk-raw/setup/phases/before-compilation.json",
                 "lifecycle": "native-sdk-generations-lifecycle/results.json",
                 "setup": "native-sdk-generations-lifecycle/setup/setup.json",
                 "publication": "native-calibration-sdk-publication.json"}
        for role, relative in paths.items():
            try:
                value = M.read(self.root / relative)
                row = dict(observation=M.safe_record(value), sha256=M.reference(self.root / relative)["sha256"])
                if type(value.get("error")) is str:
                    row["error_sha256"] = hashlib.sha256(value["error"].encode()).hexdigest()
                result[role] = row
            except (OSError, ValueError, RuntimeError, TypeError, KeyError):
                result[role] = dict(status="unavailable")
        return json.dumps(result, sort_keys=True, allow_nan=False)

    def finish(self):
        code = self.execute()
        self.case.assertEqual(code, 0, self.diagnostics())
        controller = M.read(self.root / "native-calibration-sdk-calls/generation-controller.json")
        self.case.assertEqual(controller["status"], "validation-candidate-complete")
        self.case.assertEqual(len(self.compiler_calls), 43)
        summary = M.read(self.root / "native-calibration-sdk-raw/generation-results.json")
        self.case.assertEqual(summary["full_generation_reads"], 16)
        self.case.assertEqual(len(summary["stages"]), 13)
        code, text = self.publish()
        self.case.assertEqual(code, 0, text + self.diagnostics())
        return controller


class CapsuleProducerRouteTests(unittest.TestCase):
    def failed(self, fault):
        fixture = CapsuleProducerFixture(self, fault=fault)
        self.assertNotEqual(fixture.execute(), 0)
        code, text = fixture.publish()
        self.assertEqual(code, 0, text + fixture.diagnostics())
        value = M.read(fixture.root / "native-calibration-sdk-public/results.json")
        self.assertEqual(value["role"], M.CAPSULE_ROLE)
        self.assertIsNone(value["actual_compiler_commands"])
        self.assertIsNone(value["actual_full_sdk_reads"])
        self.assertIs(value["accepted"], False)
        self.assertIs(value["final_protocol_ready"], False)
        self.assertNotIn(str(fixture.base), json.dumps(value))
        self.assertNotIn("private", json.dumps(value))
        return fixture, value, {row["slot"]: row for row in value["slots"]}

    def test_complete_actual_producer_candidate_publication_with_synthetic_native_inputs(self):
        fixture = CapsuleProducerFixture(self)
        controller = fixture.finish()
        probe = fixture.root / "sdk-discovery-raw/setup/discovery/probe-input"
        self.assertEqual(probe.read_bytes(), b"")
        self.assertEqual(W.document(fixture.root / "native-calibration-sdk-public" / W.EMPTY_PROBE_PROJECTED),
                         W.empty_probe_descriptor())
        self.assertEqual([row for row in controller["phase_order"]], [name for name, _ in M.PHASES])
        self.assertEqual(fixture.sleeps, [1.1] * 7)
        lifecycle = M.read(fixture.root / "native-sdk-generations-lifecycle/results.json")
        self.assertEqual(len(lifecycle["states"]), 13)
        self.assertEqual(lifecycle["ios_execution"], "compiler-only")
        self.assertEqual(lifecycle["runtime_execution"], "not-run")
        self.assertTrue(all(row["product_checks"] == "not-run" for row in lifecycle["states"]))
        self.assertEqual(len([argv for argv in fixture.calls if argv[0] == "/usr/sbin/sysctl"]), 14)
        public = M.read(fixture.root / "native-calibration-sdk-public/results.json")
        self.assertNotEqual(public.get("role"), M.CAPSULE_ROLE)
        self.assertIs(public["accepted"], False)
        self.assertEqual(set(fixture.timer_stack[0]), {"timer", "handler"})
        self.assertEqual(fixture.timer_stack[0]["timer"], (0.0, 0.0))

    def test_real_early_context_launch_and_pre_receipt_failures(self):
        for fault in ("pre-context", "context-admission", "phase-launch", "pre-phase-receipt", "installation"):
            with self.subTest(fault=fault):
                fixture, value, slots = self.failed(fault)
                try:
                    self.assertEqual(fixture.compiler_calls, [])
                    self.assertEqual(value["execution_exit"], 125)
                    if fault == "context-admission":
                        self.assertEqual(slots["context"]["observation"]["admission_status"], "refused-before-any-phase")
                        self.assertEqual(len(fixture.calls), 1)
                    if fault == "pre-phase-receipt":
                        self.assertEqual(slots["phase-command:before-compilation"]["observation"]["streams"]["stderr"]
                                         ["safe_json"]["schema"], "early-refusal")
                        self.assertEqual(slots["phase-result:before-compilation"]["status"], "unavailable")
                finally: fixture.stack.close()

    def test_real_probe_prefix_nonzero_125_timeout_and_cancellation(self):
        for fault in ("probe-nonzero", "probe-125", "probe-timeout", "probe-cancel"):
            with self.subTest(fault=fault):
                fixture, _value, slots = self.failed(fault)
                try:
                    first = slots["native-probe:before-compilation:machine-hw_machine"]
                    failed = slots["native-probe:before-compilation:machine-hw_physicalcpu"]
                    self.assertEqual(first["observation"]["completion_class"], "completed-zero-within-bound")
                    self.assertEqual(failed["observation"]["completion_class"], "incomplete-or-nonzero")
                    if fault in ("probe-timeout", "probe-cancel"):
                        self.assertEqual(failed["observation"]["streams"]["stdout"]["status"], "withheld-unstable")
                    self.assertEqual(fixture.compiler_calls, [])
                finally: fixture.stack.close()

    def test_actual_installation_and_native_admission_refusals_keep_strict_pins(self):
        for fault in ("installation-python", "machine-mismatch", "version-mismatch", "malformed-native"):
            with self.subTest(fault=fault):
                fixture, _value, slots = self.failed(fault)
                try:
                    self.assertEqual(fixture.compiler_calls, [])
                    self.assertEqual(slots["phase-result:before-compilation"]["observation"]["reported_status"], "failed")
                    if fault != "installation-python":
                        self.assertEqual(slots["sdk-admission:before-compilation"]["observation"]["checkpoint"], "native-admission")
                    self.assertFalse((fixture.root / "native-calibration-sdk-raw/before-compilation/seal.json").exists())
                finally: fixture.stack.close()

    def test_rehashed_native_actual_exit_and_ownership_conflicts_do_not_read_stdout(self):
        for fault in ("probe-contradiction", "probe-bool", "probe-late", "probe-ownership", "probe-wait-ownership"):
            with self.subTest(fault=fault):
                fixture = CapsuleProducerFixture(self, fault=fault)
                try:
                    self.assertNotEqual(fixture.execute(), 0)
                    result = M.read(fixture.root / "native-calibration-sdk-raw/before-compilation/results.json")
                    self.assertNotEqual(result["status"], "captured-candidate")
                    ledger = result["diagnostic"]["probes"]["machine-hw_machine"]
                    self.assertNotIn("stdout_identity", ledger)
                    # 명백하게 잘못된 exit 타입은 안전한 슬롯 문서로도 인정하지 않는다.
                    self.assertEqual(fixture.publish()[0], 1 if fault == "probe-bool" else 0)
                    self.assertEqual(fixture.compiler_calls, [])
                finally: fixture.stack.close()

    def test_real_capture_inventory_write_close_and_postseal_alias_failures(self):
        for fault in ("capture-inventory", "capture-write", "capture-close", "post-capture-alias"):
            with self.subTest(fault=fault):
                fixture, _value, slots = self.failed(fault)
                try:
                    observed = slots["sdk-admission:before-compilation"]["observation"]
                    self.assertEqual(observed["reported_status"], "failed")
                    self.assertEqual(observed["checkpoint"], "sdk-postcheck" if fault == "post-capture-alias" else "sdk-capture")
                    self.assertEqual(fixture.compiler_calls, [])
                finally: fixture.stack.close()

    def test_admission_close_missing_result_keeps_independently_bound_probe_prefix(self):
        fixture = CapsuleProducerFixture(self, fault="admission-close")
        self.assertNotEqual(fixture.execute(), 0)
        (fixture.root / "native-calibration-sdk-raw/before-compilation/results.json").unlink()
        self.assertEqual(fixture.publish()[0], 0)
        capsule = M.read(fixture.root / "native-calibration-sdk-public/results.json")
        slots = {row["slot"]: row for row in capsule["slots"]}
        self.assertEqual(slots["sdk-admission:before-compilation"]["status"], "unavailable")
        self.assertEqual(slots["native-probe:before-compilation:sdk-build"]["status"], "available")

    def test_phase_close_preserves_its_actual_nonzero_with_complete_disk_observation(self):
        fixture, _value, slots = self.failed("phase-close")
        self.assertEqual(slots["phase-result:before-compilation"]["observation"]["reported_exit_code"], 0)
        self.assertIs(slots["phase-result:before-compilation"]["observation"]["actual_exit_conflict"], True)
        self.assertEqual(fixture.compiler_calls, [])
        self.assertEqual(slots["sdk-summary"]["observation"]["summary_checkpoint"], "initial")
        self.assertEqual(slots["sdk-summary"]["observation"]["reported_status"], "started")

    def test_initial_and_progressed_summary_schema_mutations_refuse(self):
        cases = [("phase-close", kind) for kind in ("status", "stages", "helper", "extra", "profile", "schema", "role")]
        cases += [("installation", kind) for kind in ("schema", "role")]
        for fault, kind in cases:
            with self.subTest(fault=fault, kind=kind):
                fixture = CapsuleProducerFixture(self, fault=fault)
                try:
                    self.assertEqual(fixture.execute(), 125)
                    target = fixture.root / "native-calibration-sdk-raw/results.json"
                    value = M.read(target)
                    if kind == "status": value["status"] = "candidate-in-progress"
                    elif kind == "stages": value["stages"] = {"before-compilation": {}}
                    elif kind == "helper": value["helper_sha256"] = {"changed": "f" * 64}
                    elif kind == "extra": value["extra"] = False
                    elif kind == "profile": value["profile"] = M.PROFILE
                    elif kind == "schema": value["schema_version"] = True
                    else: value["role"] = "other"
                    target.write_text(json.dumps(value))
                    code, text = fixture.publish()
                    self.assertEqual(code, 1, text + fixture.diagnostics())
                    receipt = M.read(fixture.root / "native-calibration-sdk-publication.json")
                    self.assertEqual(receipt["failure_sha256"], hashlib.sha256(b"capsule-summary-source").hexdigest())
                    self.assertFalse((fixture.root / "native-calibration-sdk-public").exists())
                finally: fixture.stack.close()

    def test_real_lifecycle_stops_preserve_source_states_and_uncertified_after_boundary(self):
        for fault in ("lifecycle-nonzero", "lifecycle-timeout"):
            with self.subTest(fault=fault):
                fixture, _value, slots = self.failed(fault)
                try:
                    self.assertEqual(len(fixture.compiler_calls), 7)
                    self.assertEqual(slots["lifecycle-state:initial"]["observation"]["reported_status"], "passed")
                    self.assertEqual(slots["lifecycle-state:header_edit_rebuilt"]["observation"]["reported_status"], "failed")
                    self.assertEqual(slots["lifecycle-state:header_rename_unbuilt"]["status"], "unavailable")
                    controller = M.read(fixture.root / "native-calibration-sdk-calls/generation-controller.json")
                    self.assertEqual(controller["first_failure"]["phase"], "compiler-lifecycle")
                    self.assertEqual(controller["phases"]["sdk-discovery"]["status"], "not-started")
                finally: fixture.stack.close()

    def test_real_discovery_and_final_native_stops_retain_complete_prior_generations(self):
        for fault, phase in (("discovery-launch", "sdk-discovery"), ("post-generation", "after-generation")):
            with self.subTest(fault=fault):
                fixture, _value, slots = self.failed(fault)
                try:
                    self.assertEqual(len(fixture.compiler_calls), 43)
                    self.assertEqual(slots["lifecycle-state:restored_rebuilt"]["observation"]["reported_status"], "passed")
                    controller = M.read(fixture.root / "native-calibration-sdk-calls/generation-controller.json")
                    self.assertEqual(controller["first_failure"]["phase"], phase)
                finally: fixture.stack.close()

    def test_phase_late_zero_is_explicitly_incomplete_without_rewriting_exit(self):
        fixture, _value, slots = self.failed("phase-late")
        observed = slots["phase-command:before-compilation"]["observation"]
        self.assertEqual(observed["reported_observed_returncode"], 0)
        self.assertEqual(observed["completion_class"], "late-zero")
        self.assertEqual(fixture.compiler_calls, [])

    def test_uncertain_phase_prefix_retains_incomplete_and_refuses_forged_completion(self):
        for fault in ("phase-ownership", "phase-wait-ownership"):
            for forged in (False, True):
                with self.subTest(fault=fault, forged=forged):
                    fixture = CapsuleProducerFixture(self, fault=fault)
                    try:
                        self.assertEqual(fixture.execute(), 125)
                        path = fixture.root / "native-calibration-sdk-calls/generation-controller.json"
                        controller = M.read(path)
                        phase = controller["phases"]["before-compilation"]
                        self.assertEqual(phase["status"], "incomplete")
                        self.assertEqual(phase["command_result"]["observed_returncode"], 0)
                        if forged:
                            phase["status"] = "completed"
                            path.write_text(json.dumps(controller))
                        later = "native-calibration-sdk-calls/sdk-discovery/command.json"
                        M.save(fixture.root / later, dict(status="untrusted later file"))
                        original, reads = M.CapsuleReader.original, []
                        def observed(reader, relative, **options):
                            reads.append(relative)
                            return original(reader, relative, **options)
                        with mock.patch.object(M.CapsuleReader, "original", observed):
                            self.assertEqual(fixture.publish()[0], 1 if forged else 0)
                        self.assertNotIn(later, reads)
                        self.assertNotIn("native-calibration-sdk-calls/before-compilation/command.stdout", reads)
                        if not forged:
                            capsule = M.read(fixture.root / "native-calibration-sdk-public/results.json")
                            slots = {row["slot"]: row for row in capsule["slots"]}
                            self.assertEqual(slots["phase-result:before-compilation"]["status"], "withheld-unstable")
                        self.assertEqual(fixture.compiler_calls, [])
                    finally: fixture.stack.close()

    def test_complete_controller_disk_json_close_failure_does_not_override_actual_125(self):
        fixture, value, slots = self.failed("controller-close")
        self.assertEqual(len(fixture.compiler_calls), 43)
        self.assertTrue(value["disk_completion_conflict"])
        self.assertEqual(slots["supervisor-command"]["observation"]["reported_observed_returncode"], 125)
        self.assertEqual(slots["controller"]["observation"]["reported_exit_code"], 0)

    def test_actual_zero_candidate_verification_failure_is_never_downgraded(self):
        fixture = CapsuleProducerFixture(self)
        self.assertEqual(fixture.execute(), 0)
        target = fixture.root / "native-calibration-sdk-raw/generation-results.json"
        row = M.read(target); row["executed_commands"] = 42; target.write_text(json.dumps(row))
        with mock.patch.object(M, "publish_failure_capsule", side_effect=AssertionError("forbidden downgrade")) as capsule:
            self.assertEqual(fixture.publish()[0], 1)
        capsule.assert_not_called()

    def test_rehashed_phase_prefix_context_reference_and_cross_source_records_refuse(self):
        fixture = CapsuleProducerFixture(self, fault="installation")
        self.assertNotEqual(fixture.execute(), 0)
        controller_path = fixture.root / "native-calibration-sdk-calls/generation-controller.json"
        original = controller_path.read_bytes()
        controller = M.read(controller_path)
        variants = []
        row = copy.deepcopy(controller); row["phase_order"].reverse(); variants.append(row)
        row = copy.deepcopy(controller); row["context"]["sha256"] = "f" * 64; variants.append(row)
        row = copy.deepcopy(controller); row["context"]["bytes"] += 1; variants.append(row)
        row = copy.deepcopy(controller); row["phases"]["sdk-discovery"] = copy.deepcopy(row["phases"]["before-compilation"]); variants.append(row)
        for row in variants:
            controller_path.write_text(json.dumps(row))
            with self.subTest(row=row["context"]), self.assertRaises(ValueError): M.failure_capsule(fixture.root)
        controller_path.write_bytes(original)
        phase_path = fixture.root / "native-calibration-sdk-raw/setup/phases/before-compilation.json"
        phase = M.read(phase_path)
        for mutation in (dict(stage="after-generation"), dict(helper_sha256={}), dict(accepted=True)):
            phase_path.write_text(json.dumps({**phase, **mutation}))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): M.failure_capsule(fixture.root)
        phase_path.write_text(json.dumps(phase))

    def test_stale_lower_tree_withholds_all_lstat_reads_and_stale_status_is_not_finalized(self):
        fixture = CapsuleProducerFixture(self, fault="pre-context")
        self.assertNotEqual(fixture.execute(), 0)
        status = fixture.root / "generation-invocation-status.json"
        row = M.read(status); row["prelaunch_outputs_absent"] = False; status.write_text(json.dumps(row))
        old = M.CapsuleReader.original
        seen = []
        def read(reader, relative, **kwargs):
            seen.append(relative)
            self.assertEqual(relative, "generation-invocation-status.json")
            return old(reader, relative, **kwargs)
        # 남아 있는 파일과 dangling 링크 모두 하위 읽기 권한을 주지 않는다.
        (fixture.root / "sdk-discovery-raw").symlink_to(fixture.root / "missing")
        with mock.patch.object(M.CapsuleReader, "original", read):
            self.assertEqual(fixture.publish()[0], 0)
        self.assertEqual(seen, ["generation-invocation-status.json"] * 2)
        with mock.patch.dict(os.environ, {"GENERATION_STATUS_FINALIZED": ""}), mock.patch.object(M, "read") as read:
            with self.assertRaises(ValueError): M.invocation_status(fixture.root)
            read.assert_not_called()

    def test_full_route_unknown_private_streams_and_malformed_phase_are_unavailable(self):
        for text in ('{"status":"refused","failure_type":"token=private-value","failure_sha256":"' + 'f' * 64 + '"}',
                     '{"status":"refused","status":"refused"}', '{"wall_seconds":NaN}',
                     '/private/unstructured?token=secret', 'x' * 65537):
            with self.subTest(text=text[:40]):
                fixture = CapsuleProducerFixture(self, fault="pre-phase-receipt")
                try:
                    self.assertNotEqual(fixture.execute(), 0)
                    stderr = fixture.root / "native-calibration-sdk-calls/before-compilation/command.stderr"
                    stderr.write_text(text)
                    controller_path = fixture.root / "native-calibration-sdk-calls/generation-controller.json"
                    controller = M.read(controller_path)
                    controller["phases"]["before-compilation"]["originals"][".stderr"] = M.reference(stderr)
                    controller_path.write_text(json.dumps(controller))
                    phase = fixture.root / "native-calibration-sdk-raw/setup/phases/before-compilation.json"
                    phase.parent.mkdir(parents=True, exist_ok=True)
                    phase.write_text('{"status":"failed","status":"private-secret"}')
                    code, emitted = fixture.publish()
                    self.assertEqual(code, 0, emitted)
                    value = M.read(fixture.root / "native-calibration-sdk-public/results.json")
                    slots = {row["slot"]: row for row in value["slots"]}
                    self.assertEqual(slots["phase-result:before-compilation"]["status"], "malformed")
                    self.assertEqual(slots["phase-command:before-compilation"]["observation"]["streams"]["stderr"]
                                     ["safe_json"], dict(status="unavailable"))
                    self.assertNotIn("private", json.dumps(value) + emitted)
                    self.assertNotIn("secret", json.dumps(value) + emitted)
                finally: fixture.stack.close()

    def test_existing_two_field_phase_reference_keeps_strict_path_hash_and_shape(self):
        for mutation in ("path", "sha256", "bytes"):
            with self.subTest(mutation=mutation):
                fixture = CapsuleProducerFixture(self, fault="installation")
                try:
                    self.assertEqual(fixture.execute(), 125)
                    target = fixture.root / "native-calibration-sdk-raw/results.json"
                    summary = M.read(target)
                    reference = summary["stages"]["before-compilation"]["original"]
                    self.assertEqual(set(reference), {"path", "sha256"})
                    if mutation == "path": reference["path"] += ".other"
                    elif mutation == "sha256": reference["sha256"] = "f" * 64
                    else: reference["bytes"] = 1
                    target.write_text(json.dumps(summary))
                    self.assertEqual(fixture.publish()[0], 1)
                    receipt = M.read(fixture.root / "native-calibration-sdk-publication.json")
                    self.assertEqual(receipt["failure_sha256"], hashlib.sha256(b"capsule-summary-phase-changed").hexdigest())
                finally: fixture.stack.close()

    def test_full_route_rehashed_lifecycle_plan_boundary_and_source_records_refuse(self):
        reasons = {"plan": "capsule-generation-command-plan", "request": "capsule-generation-boundary-role",
                   "stage": "capsule-generation-boundary-role", "output": "capsule-generation-output-path",
                   "orphan": "capsule-boundary-without-state"}
        for kind, reason in reasons.items():
            with self.subTest(kind=kind):
                fixture = CapsuleProducerFixture(self, fault="post-generation")
                try:
                    self.assertNotEqual(fixture.execute(), 0)
                    state_path = fixture.root / "native-sdk-generations-lifecycle/runs/initial/state.json"
                    boundary_path = fixture.root / "native-calibration-sdk-raw/generations/initial/before/results.json"
                    self.assertTrue(state_path.is_file() and boundary_path.is_file(), fixture.diagnostics())
                    state, boundary = M.read(state_path), M.read(boundary_path)
                    if kind == "plan":
                        boundary["command_plan"][0]["args"].append("-unreviewed")
                        boundary["commands_sha256"] = M.GENERATIONS.identity(boundary["command_plan"])
                    elif kind == "request": boundary["request_sha256"] = "f" * 64
                    elif kind == "stage": boundary["stage"] = "restored_rebuilt"
                    elif kind == "output": state["generation_attempt"]["build"] += "-other"
                    state["sdk_generation"]["before"] = boundary
                    state_path.write_text(json.dumps(state))
                    boundary_path.write_text(json.dumps(boundary))
                    if kind == "orphan": state_path.unlink()
                    # 매 변형의 첫 발행만 실행하여 이전 실패 영수증이 검증 경로를 가리지 않게 한다.
                    self.assertFalse((fixture.root / "native-calibration-sdk-publication.json").exists())
                    self.assertEqual(fixture.publish()[0], 1)
                    receipt = M.read(fixture.root / "native-calibration-sdk-publication.json")
                    self.assertEqual(receipt["failure_sha256"], hashlib.sha256(reason.encode()).hexdigest())
                finally: fixture.stack.close()

    def test_missing_or_malformed_controller_does_not_prove_prephase_context_refusal(self):
        for kind in ("missing", "malformed"):
            with self.subTest(kind=kind):
                fixture = CapsuleProducerFixture(self, fault="context-admission")
                try:
                    self.assertEqual(fixture.execute(), 125)
                    path = fixture.root / "native-calibration-sdk-calls/generation-controller.json"
                    if kind == "missing": path.unlink()
                    else: path.write_text('{"phases":{},"phases":{}}')
                    old, seen = M.CapsuleReader.original, []
                    def original(reader, relative, **kwargs):
                        seen.append(relative)
                        return old(reader, relative, **kwargs)
                    with mock.patch.object(M.CapsuleReader, "original", original):
                        code, emitted = fixture.publish()
                    self.assertEqual(code, 0, emitted)
                    value = M.read(fixture.root / "native-calibration-sdk-public/results.json")
                    slots = {row["slot"]: row for row in value["slots"]}
                    self.assertEqual(slots["controller"]["status"], "unavailable" if kind == "missing" else "malformed")
                    self.assertEqual(slots["context"]["observation"], dict(admission_status="unavailable"))
                    self.assertTrue(all(row["status"] == "withheld-unstable" for role, row in slots.items()
                                        if role.startswith(("phase-", "sdk-admission:", "native-probe:", "generation-"))))
                    self.assertFalse(any("/before-compilation/" in path for path in seen))
                    self.assertIsNone(value["actual_compiler_commands"])
                    self.assertEqual(fixture.compiler_calls, [])
                finally: fixture.stack.close()

    def test_endpoint_new_missing_source_and_aggregate_refusals_use_real_publisher(self):
        for mutation in ("new-slot", "missing", "source", "aggregate"):
            with self.subTest(mutation=mutation):
                fixture = CapsuleProducerFixture(self, fault="pre-phase-receipt")
                try:
                    self.assertNotEqual(fixture.execute(), 0)
                    normalizer = W.NORMALIZER.package
                    hashes = M.source_hashes
                    changed = [False]
                    def package(args):
                        result = normalizer(args)
                        if mutation == "new-slot":
                            M.save(fixture.root / "native-calibration-sdk-raw/setup/phases/before-compilation.json", {})
                        elif mutation == "missing":
                            (fixture.root / "native-calibration-sdk-calls/before-compilation/command.stderr").unlink()
                        changed[0] = True
                        return result
                    with contextlib.ExitStack() as stack:
                        stack.enter_context(mock.patch.object(W.NORMALIZER, "package", side_effect=package))
                        if mutation == "source":
                            stack.enter_context(mock.patch.object(M, "source_hashes", side_effect=lambda:
                                {**hashes(), "source-drift": "f" * 64} if changed[0] else hashes()))
                        if mutation == "aggregate":
                            original = M.CapsuleReader.__init__
                            def init(reader, root): original(reader, root); reader.total = M.CAPSULE_MAX_TOTAL - 1
                            stack.enter_context(mock.patch.object(M.CapsuleReader, "__init__", init))
                        self.assertEqual(fixture.publish()[0], 1)
                finally: fixture.stack.close()


class WorkflowTests(unittest.TestCase):
    def test_exact_inverse_preserves_previous_full_workflow(self):
        self.assertEqual(hashlib.sha256(legacy_workflow(WORKFLOW.read_bytes())).hexdigest(),
                         "152c26e6e9e67631e2c15ccfbd29a0b9160ac0cda44781cb6d757ee929bfbac2")

    def test_only_new_mode_and_one_generation_step_with_unchanged_caps(self):
        text = WORKFLOW.read_text()
        self.assertEqual(re.findall(r"^          - (.*)$", text, re.MULTILINE),
                         ["calibration", "sdk-publication-only", "sdk-generation-only"])
        self.assertIn("assert os.environ['RUN_MODE'] in ('calibration', 'sdk-publication-only', 'sdk-generation-only')", text)
        self.assertIn("    timeout-minutes: 45\n", text)
        self.assertIn("        timeout-minutes: 31\n", text)
        self.assertEqual(text.count("Scripts/validate-native-sdk-generations.py"), 1)
        self.assertIn("if: inputs.mode != 'sdk-generation-only'", text)
        self.assertIn("if: inputs.mode == 'sdk-generation-only'", text)
        self.assertIn("steps.generations.outputs.status_finalized == 'true'", text)
        self.assertIn('[[ -e "$RUNNER_TEMP/$subtree" || -L "$RUNNER_TEMP/$subtree" ]]', text)
        self.assertIn("set -o noclobber", text)
        self.assertIn('[[ -e "$RUNNER_TEMP/generation-invocation-status.json" || -L "$RUNNER_TEMP/generation-invocation-status.json" ]]', text)
        self.assertIn("GENERATION_STATUS_FINALIZED: ${{ steps.generations.outputs.status_finalized }}", text)
        self.assertEqual(text.count("uses: actions/upload-artifact@"), 5)
        self.assertNotIn("continue-on-error", text)
        self.assertNotIn("secrets.", text)


    def test_status_writer_refuses_existing_regular_symlink_fifo_and_directory_without_opening(self):
        text = WORKFLOW.read_text().split("        id: generations\n", 1)[1].split("\n      #", 1)[0]
        tail = text.split("          set -e\n", 1)[1]
        fragment = "set -e\n" + "\n".join(line[10:] for line in tail.splitlines() if line.strip())
        self.assertEqual(fragment.count("set -o noclobber"), 1)
        def stable_identity(path):
            info = path.lstat()
            return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
                    os.readlink(path) if path.is_symlink() else None)
        # 고정된 shell 내장 명령만 14회 실행한다. FIFO를 열면 3초 제한 안에서 실패한다.
        for kind in ("absent", "regular", "symlink", "fifo", "fifo-symlink", "dangling", "directory"):
            for actual in (0, 125):
                with self.subTest(kind=kind, actual=actual), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    path, output = root / "generation-invocation-status.json", root / "github-output"
                    target = root / "target"
                    if kind == "regular": path.write_bytes(b"keep-original")
                    elif kind == "symlink": target.write_bytes(b"keep-target"); path.symlink_to(target)
                    elif kind == "fifo": os.mkfifo(path)
                    elif kind == "fifo-symlink": os.mkfifo(target); path.symlink_to(target)
                    elif kind == "dangling": path.symlink_to(target)
                    elif kind == "directory": path.mkdir()
                    before = stable_identity(path) if kind != "absent" else None
                    target_before = stable_identity(target) if target.exists() else None
                    environment = dict(PATH="/usr/bin:/bin", RUNNER_TEMP=str(root), GITHUB_OUTPUT=str(output),
                                       SOURCE_SHA="a" * 40, GITHUB_RUN_ID="7", GITHUB_RUN_ATTEMPT="1",
                                       actual=str(actual), fresh="true")
                    result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", fragment],
                                            env=environment, capture_output=True, text=True, timeout=3)
                    self.assertEqual(result.returncode, actual if kind == "absent" or actual else 125)
                    self.assertEqual(result.stdout + result.stderr, "")
                    if kind == "absent":
                        self.assertEqual(json.loads(path.read_text())["actual_shell_exit"], actual)
                        self.assertEqual(output.read_text(), "status_finalized=true\n")
                    else:
                        self.assertEqual(stable_identity(path), before)
                        self.assertFalse(output.exists())
                        if target_before is not None: self.assertEqual(stable_identity(target), target_before)
                        if kind == "regular": self.assertEqual(path.read_bytes(), b"keep-original")
                        if kind == "symlink": self.assertEqual(target.read_bytes(), b"keep-target")


if __name__ == "__main__":
    unittest.main()
