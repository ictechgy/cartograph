#!/usr/bin/env python3
"""컴파일러를 시작하지 않고 고정 세대 호출·환경·발행 경계를 검증한다."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
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
        self.assertIn("steps.before.outcome != 'skipped' || steps.generations.outcome != 'skipped'", text)
        self.assertEqual(text.count("uses: actions/upload-artifact@"), 5)
        self.assertNotIn("continue-on-error", text)
        self.assertNotIn("secrets.", text)


if __name__ == "__main__":
    unittest.main()
