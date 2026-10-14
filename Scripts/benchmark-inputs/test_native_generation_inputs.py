#!/usr/bin/env python3
"""실제 작은 파일 봉인과 합성 컴파일 영수증으로 세대 계약을 양방향 검증한다."""
from __future__ import annotations
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import native_generation_inputs as M
sys.path.insert(0, str(M.FIXTURE))
G = M.load("generation_fixture_producer", M.FIXTURE / "compiler_generations.py")
RUN = M.load("generation_fixture_runner_controls", M.FIXTURE / "run_ios_validation.py")
CONTROLLER = M.load("generation_fixture_controller", M.ROOT / "Scripts/validate-native-sdk-generations.py")


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def budget(wall=0.0001):
    return dict(wall_seconds=wall, requested_timeout_seconds=300.0,
                lifecycle_remaining_at_launch_seconds=1000.0, lifecycle_elapsed_at_launch_seconds=200.0)


class SyntheticLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.evidence, self.output = self.root / "native-calibration-sdk-raw", self.root / "lifecycle"
        self.output.mkdir()
        self.project = self.output / "Project"
        shutil.copytree(M.FIXTURE / "fixture", self.project)
        sdk = self.root / "Platform/Developer/SDKs/Simulator.sdk"
        chain = self.root / "Toolchain"
        sdk.mkdir(parents=True)
        (sdk / "header.h").write_text("fixed SDK fixture")
        for name in ("usr/bin/swiftc", "usr/bin/clang", "usr/bin/swift-frontend", "usr/lib/libIndexStore.dylib"):
            path = chain / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("authored tool identity " + name)
        roots = dict(SDK=sdk, TOOLCHAIN=chain)
        seal = M.SEAL.capture(roots)
        self.patch(M, "BASELINE_SHA256", seal["content_sha256"])
        self.layout = dict(roots={key: str(path) for key, path in roots.items()})
        self.patch(M.NATIVE, "selected_layout", lambda *_args: copy.deepcopy(self.layout))
        self.patch(M, "validate_candidate", lambda *_args: copy.deepcopy(seal))
        expected, _ = M.NATIVE.expectation()
        with mock.patch.dict(os.environ, dict(DEVELOPER_DIR=expected["developer_lexical"], **expected["runner"]), clear=True):
            self.context = CONTROLLER.create_context(self.root)
        self.environment = CONTROLLER.context_environment(self.context)
        patcher = mock.patch.dict(os.environ, self.environment, clear=True)
        patcher.start(); self.addCleanup(patcher.stop)
        selected = dict(sdk=str(sdk), tools=dict(swift=str(chain / "usr/bin/swiftc"),
            clang=str(chain / "usr/bin/clang"), index_library=str(chain / "usr/lib/libIndexStore.dylib")))
        versions = dict(sdk_version="26.6", sdk_build="fixture", xcode="fixture Xcode", swift="fixture Swift")
        self.candidate = dict(status="captured-candidate", boundary="before-compilation", accepted=False,
            final_protocol_ready=False, expectation_sha256=M.EXPECTATION_SHA256, content_sha256=seal["content_sha256"],
            native=dict(selected=selected, versions=versions, layout=self.layout), seal_path=str(self.evidence / "before-compilation/seal.json"))
        self.evidence.mkdir()
        write(Path(self.candidate["seal_path"]), seal)
        self.request = M.make_request(self.candidate, self.evidence, self.environment, sys.executable,
            environment_creation=dict(fresh=True, directories=M.environment_contract(self.environment, expected)))
        self.request_path = self.evidence / "request.json"
        write(self.request_path, self.request)
        self.request_sha = M.SELECTOR.file_identity(self.request_path)["sha256"]
        tools = selected["tools"]
        self.setup = dict(status="selected", requested_sdk="iphonesimulator", sdk_path=str(sdk),
            swiftc=tools["swift"], clang=tools["clang"], library=tools["index_library"],
            sdk_version=versions["sdk_version"], sdk_build=versions["sdk_build"], xcode=versions["xcode"],
            swift_version=versions["swift"], developer_dir=expected["developer_lexical"],
            target_triple="arm64-apple-ios16.0-simulator", compiler_index_policy="fresh-shared-v2",
            platform_path=str(sdk.parents[2]))
        self.setup["compiler_toolchain_files"] = {str(chain / path): M.SELECTOR.file_identity(chain / path)["sha256"]
            for path in ("usr/bin/swiftc", "usr/bin/clang", "usr/bin/swift-frontend", "usr/lib/libIndexStore.dylib")}
        write(self.output / "setup/setup.json", self.setup)
        for name, command in M.setup_commands(self.setup):
            self.command(self.output / "setup" / name, command, self.output, 0)
        self.session = M.prepare(self.request_path, self.request_sha, self.output, self.setup)
        self.states = []
        self.accepted = None

    def patch(self, target, name, value):
        patcher = mock.patch.object(target, name, value)
        patcher.start(); self.addCleanup(patcher.stop)

    def command(self, stem, argv, cwd, code):
        stem.parent.mkdir(parents=True, exist_ok=True)
        stem.with_suffix(".stdout").write_text("")
        stem.with_suffix(".stderr").write_text("RenamedCore.h: file not found" if code else "")
        row = dict(command=argv, cwd=str(cwd), exit_code=code, stdout=str(stem.with_suffix(".stdout")),
                   stderr=str(stem.with_suffix(".stderr")), **budget())
        write(stem.with_suffix(".json"), row)
        return row

    def stage(self, row):
        name, operation, building, variant = row
        if operation:
            M.COMMON.mutate(self.project, operation)
        state = dict(name=name, status="passed", project=str(self.project), builds=[], execution="executed",
            product_checks="not-run", compiler_index_policy="fresh-shared-v2", expected_build=building or "not-run",
            oracle_variant=variant, sdk="iphonesimulator", triple=self.setup["target_triple"],
            generation_attempt=None, accepted_generation=self.accepted)
        directory = self.output / "runs" / name
        directory.mkdir(parents=True)
        if building:
            attempt = G.begin(self.output, name, self.project, self.setup, False)
            state["generation_attempt"] = attempt
            commands = M.COMMON.command_plan(self.project, Path(attempt["store"]), Path(attempt["build"]),
                self.setup["sdk_path"], self.setup["target_triple"], self.setup["swiftc"], self.setup["clang"],
                self.setup["platform_path"], False)
            write(directory / "commands.json", commands)
            self.assertEqual(commands, M.frozen_command_plan(self.project, Path(attempt["store"]), Path(attempt["build"]),
                self.setup["sdk_path"], self.setup["target_triple"], self.setup["swiftc"], self.setup["clang"],
                self.setup["platform_path"], name))
            self.session.before(name, commands, state)
            for command in commands[:1] if building == "failure" else commands:
                code = 1 if building == "failure" else 0
                if not code:
                    for output in command["outputs"]:
                        path = Path(output); path.parent.mkdir(parents=True, exist_ok=True); path.write_text(command["name"])
                    index = Path(attempt["store"]) / "v5/units" / command["name"]
                    index.parent.mkdir(parents=True, exist_ok=True); index.write_text(command["name"])
                state["builds"].append(self.command(directory / command["name"], command["args"], self.project, code))
            self.session.after(name, commands, state)
            if building == "success":
                G.seal(attempt, self.project, commands)
                self.accepted = attempt
            else:
                G.capture_attempt(attempt); attempt["status"] = "rejected"
            nested = sum(state["sdk_generation"][side]["wall_seconds"] for side in ("before", "after"))
        else:
            self.session.source_only(name, state)
            nested = 0
        compiler = sum(item["wall_seconds"] for item in state["builds"])
        wall = nested + compiler + 0.01
        state.update(accepted_generation=self.accepted, index_files=self.accepted["index_files"],
            current_sources=M.expected_sources(name), shared_input_cost=dict(status="measured", wall_seconds=wall,
                compiler_subprocess_wall_seconds=compiler, charged_wall_seconds_by_arm={arm: wall for arm in M.ARMS}))
        write(directory / "state.json", state)
        self.states.append(copy.deepcopy(state))

    def finish(self):
        for row in M.STAGE_PLAN:
            self.stage(row)
        self.summary = self.session.finish(self.states)
        lifecycle = dict(status="passed", ios_execution="compiler-only", observation_failures=[], runtime_execution="not-run",
                         states=self.states, sdk_generation=copy.deepcopy(self.summary))
        write(self.output / "results.json", lifecycle)
        self.session.finalize_originals()
        return self.summary

    def refresh_copies(self):
        for row in self.summary["original_files"]:
            original, copied = Path(row["original_path"]), Path(row["copied_path"])
            shutil.copyfile(original, copied)
            row["identity"] = M.SELECTOR.file_identity(original)
            row["copied_identity"] = M.SELECTOR.file_identity(copied)

    def test_actual_producer_order_full_states_costs_and_final_inventory_roundtrip(self):
        summary = self.finish()
        result = M.verify_originals(summary)
        self.assertEqual(result["semantic"]["counts"], dict(full_generation_reads=16, planned_commands=48, executed_commands=43))
        embedded = M.retained_document(self.output / "results.json")["sdk_generation"]
        self.assertNotEqual(len(embedded["original_files"]), len(summary["original_files"]))
        self.assertNotIn("originals_finalized", embedded)
        self.assertIs(result["accepted"], False)
        self.assertIs(result["final_protocol_ready"], False)

    def test_complete_synthetic_producer_records_survive_projection_and_scanning(self):
        self.finish()
        projection = M.load("generation_full_projection", M.ROOT / "Scripts/benchmark-inputs/native_calibration_publication.py")
        wrapper = CONTROLLER.load_wrapper()
        baseline = M.retained_document(Path(self.candidate["seal_path"]))
        final = M.SEAL.verify(baseline, {name: Path(path) for name, path in self.layout["roots"].items()})
        write(self.evidence / "after-generation/seal-verification.json", final)
        staging, public = self.root / "staging", self.root / "public"
        calls = self.root / "native-calibration-sdk-calls"
        originals = wrapper.original_small_files(self.evidence, calls, profile=CONTROLLER.PROFILE)
        self.assertIn("calls/generation-context.json", originals)
        self.assertIn("raw/request.json", originals)
        self.assertIn("raw/generation-results.json", originals)
        for stage, _, building, _ in M.STAGE_PLAN:
            self.assertIn(f"raw/lifecycle-originals/runs/{stage}/state.json", originals)
            if building:
                self.assertIn(f"raw/lifecycle-originals/runs/{stage}/commands.json", originals)
        for relative, data in originals.items():
            path = staging / "setup/original" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        write(staging / "results.json", self.summary)
        projection.prepare_projection(self.evidence, staging, profile=CONTROLLER.PROFILE)
        restored, manifest = projection.restore_documents(staging / projection.PROJECTION, profile=CONTROLLER.PROFILE)
        self.assertEqual(len(restored), 18)
        self.assertEqual(manifest["records"]["after-calibration"]["state"], "missing")
        for label, value in restored.items():
            self.assertEqual(value, M.retained_document(self.evidence / projection.GENERATION_SOURCES[label]))
        prefixes = ["WORKSPACE=" + str(M.ROOT), "RUNNER_TEMP=" + str(self.root),
                    "RUNNER_HOME=" + str(Path.home()),
                    "DEVELOPER=" + M.NATIVE.expectation()[0]["developer_physical"],
                    "APPLICATIONS=/Applications", "LIBRARY=/Library", "SYSTEM=/System", "PRIVATE=/private",
                    "USR=/usr", "OPT=/opt", "BIN=/bin", "DEV=/dev", "TEMP=/var", "SBIN=/sbin"]
        publication = projection.NORMALIZER.package(argparse.Namespace(input=staging, output=public, prefix=prefixes))
        rows = {row["path"]: row for row in publication["files"]}
        for relative, data in originals.items():
            row = rows["setup/original/" + relative]
            self.assertEqual((row["original_raw_sha256"], row["original_bytes"]),
                             (hashlib.sha256(data).hexdigest(), len(data)))
            published = public / "setup/original" / relative
            self.assertEqual(row["normalized_sha256"], hashlib.sha256(published.read_bytes()).hexdigest())
        self.assertEqual(projection.verify_publication(staging, public, publication, profile=CONTROLLER.PROFILE)["status"],
                         "verified-normalized-projection")
        normalized, _ = projection.restore_documents(public / projection.PROJECTION, normalized=True, profile=CONTROLLER.PROFILE)
        for label, record in normalized.items():
            seal = record if label == "before-compilation" else record["actual"]
            self.assertEqual(seal["entries"], baseline["entries"])
            self.assertEqual(seal["content_sha256"], baseline["content_sha256"])
        self.assertEqual(wrapper.original_small_files(self.evidence, calls, profile=CONTROLLER.PROFILE), originals)
        self.assertEqual(projection.verify_sources(self.evidence, staging, profile=CONTROLLER.PROFILE)["status"],
                         "source-identities-unchanged")
        self.assertEqual(M.verify_originals(self.summary)["semantic"]["counts"],
                         dict(full_generation_reads=16, planned_commands=48, executed_commands=43))
        context_path = self.root / CONTROLLER.CONTEXT
        self.assertEqual(CONTROLLER.verify_context(context_path, CONTROLLER.reference(context_path)["sha256"], self.root),
                         self.context)

    def test_rehashed_lower_cost_or_altered_command_plan_cannot_be_accepted(self):
        self.finish()
        target = self.output / "runs/initial/state.json"
        original = target.read_bytes()
        state = json.loads(original)
        state["shared_input_cost"]["wall_seconds"] = 0
        state["shared_input_cost"]["charged_wall_seconds_by_arm"] = {arm: 0 for arm in M.ARMS}
        write(target, state); self.refresh_copies()
        with self.assertRaisesRegex(ValueError, "generation-cost-interval-mismatch"):
            M.verify_originals(self.summary)
        target.write_bytes(original)
        plan = self.output / "runs/initial/commands.json"
        altered = M.retained_document(plan)
        altered[0]["args"].append("-DUNREVIEWED=1")
        write(plan, altered); self.refresh_copies()
        with self.assertRaises(ValueError):
            M.verify_originals(self.summary)

    def test_rehashed_boundary_state_and_verification_content_still_refuse(self):
        self.finish()
        path = self.evidence / "generations/initial/before/results.json"
        original = path.read_bytes()
        value = json.loads(original)
        value["accepted"] = True
        write(path, value)
        state_path = self.output / "runs/initial/state.json"
        state = M.retained_document(state_path)
        state["sdk_generation"]["before"] = value
        write(state_path, state); self.refresh_copies()
        with self.assertRaisesRegex(ValueError, "generation-boundary-binding"):
            M.verify_originals(self.summary)

    def test_missing_middle_state_and_boolean_count_refuse(self):
        self.finish()
        original = copy.deepcopy(self.summary)
        self.summary["full_generation_reads"] = True
        with self.assertRaisesRegex(ValueError, "generation-count-mismatch"):
            M.verify_originals(self.summary)
        self.summary = original
        target = self.output / "runs/header_edit_rebuilt/state.json"
        target.unlink()
        with self.assertRaises(ValueError):
            M.verify_originals(self.summary)

    def test_partial_prefix_preserves_missing_later_generations(self):
        for row in M.STAGE_PLAN[:3]:
            self.stage(row)
        self.summary = self.session.summary
        self.summary.update(status="failed", failed_stage="header_rename_unbuilt")
        write(self.output / "results.json", dict(status="failed", retained_states=self.states))
        self.session.finalize_originals()
        result = M.verify_originals(self.summary)
        self.assertEqual(result["semantic"]["status"], "incomplete-prefix")
        self.assertEqual(result["semantic"]["counts"], dict(full_generation_reads=4, planned_commands=12, executed_commands=12))

    def test_unstarted_build_prefix_keeps_zero_commands_and_checks(self):
        for row in M.STAGE_PLAN[:2]:
            self.stage(row)
        name, _, building, variant = M.STAGE_PLAN[2]
        state = dict(name=name, status="failed", project=str(self.project), builds=[], execution="executed",
            product_checks="not-run", compiler_index_policy="fresh-shared-v2", expected_build=building,
            oracle_variant=variant, generation_attempt=None, accepted_generation=self.accepted)
        write(self.output / "runs" / name / "state.json", state)
        self.states.append(state)
        self.summary = self.session.summary
        self.summary.update(status="failed", failed_stage=name)
        write(self.output / "results.json", dict(status="failed", retained_states=self.states))
        self.session.finalize_originals()
        result = M.verify_originals(self.summary)
        self.assertEqual(result["semantic"]["counts"], dict(full_generation_reads=2, planned_commands=6, executed_commands=6))
        self.assertEqual(result["semantic"]["status"], "incomplete-prefix")



class EnvironmentAndBudgetTests(unittest.TestCase):
    def environment(self):
        return dict(PATH=":".join(M.PATH_COMPONENTS), LC_ALL="C", LANG="C", DEVELOPER_DIR="/declared",
                    ImageOS="macos26", ImageVersion="fixed", HOME="/owned/home", TMPDIR="/owned/tmp")

    def test_normalized_command_tokens_preserve_complete_fields_and_boundaries(self):
        state = dict(project="/project", generation_attempt=dict(store="/project/store", build="/project/build"))
        setup = dict(sdk_path="/SDK", swiftc="/tools/swiftc", clang="/tools/clang")
        commands = [dict(name="declared", args=["/tools/clang", "/SDK", "/SDK/usr/include",
            "/project/Sources/BridgeKit/include", "/project/build/module.o", "/project/store",
            "/project-sibling/file", "/project/build-sibling/file", "/SDK-sibling/file",
            "/tools/swiftc-other", "-I/project/include", "/tools/swiftc"],
            outputs=["/project/build/module.o"], source_paths=["/project/Source.swift"],
            output_file_map={"/project/Source.swift": {"object": "/project/build/module.o"}},
            unchanged=[True, 1, None, "literal"]) ]
        original = copy.deepcopy(commands)
        expected = [dict(name="declared", args=["$CLANG", "$SDK", "$SDK/usr/include",
            "$PROJECT/Sources/BridgeKit/include", "$BUILD/module.o", "$STORE",
            "/project-sibling/file", "$PROJECT/build-sibling/file", "/SDK-sibling/file",
            "/tools/swiftc-other", "-I/project/include", "$SWIFTC"],
            outputs=["$BUILD/module.o"], source_paths=["$PROJECT/Source.swift"],
            output_file_map={"$PROJECT/Source.swift": {"object": "$BUILD/module.o"}},
            unchanged=[True, 1, None, "literal"]) ]
        self.assertEqual(M.normalize_commands(commands, state, setup), expected)
        self.assertEqual(commands, original)

    def test_exact_environment_rows_roundtrip_and_path_schema(self):
        env = self.environment()
        rows = M.environment_rows(env)
        self.assertEqual(M.request_environment(dict(environment=rows)), env)
        self.assertEqual(next(row["value"] for row in rows if row["name"] == "PATH"), M.PATH_COMPONENTS)
        for value in (env["PATH"], list(reversed(M.PATH_COMPONENTS)), M.PATH_COMPONENTS + ["/extra"],
                      ["/usr/bin", "/bin", "/usr/sbin", "/changed"], [True] * 4):
            altered = copy.deepcopy(rows)
            next(row for row in altered if row["name"] == "PATH")["value"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                M.request_environment(dict(environment=altered))
        for change in (lambda value: value.pop(), lambda value: value.append(value[0]),
                       lambda value: value[0].update(name="UNEXPECTED"), lambda value: value[0].update(value=["/wrong"])):
            altered = copy.deepcopy(rows); change(altered)
            with self.subTest(change=change), self.assertRaises(ValueError):
                M.request_environment(dict(environment=altered))

    def test_typed_budget_and_late_zero_refusal(self):
        M.validate_command_budget(budget())
        for key, value in (("wall_seconds", True), ("wall_seconds", float("nan")), ("wall_seconds", 300.001),
                           ("requested_timeout_seconds", 301), ("lifecycle_remaining_at_launch_seconds", 1201),
                           ("lifecycle_elapsed_at_launch_seconds", 201)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                M.validate_command_budget({**budget(), key: value})

    def test_default_run_receipt_remains_unchanged_and_late_profile_retains_actual_zero(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve()
            process = mock.Mock(stdout=b"actual output", stderr=b"", returncode=0)
            with mock.patch.object(RUN.subprocess, "run", return_value=process), \
                 mock.patch.object(RUN.time, "perf_counter", side_effect=[0.0, 0.1]):
                result = RUN.run(["authored-command"], root, root / "default")
            self.assertNotIn("requested_timeout_seconds", result)
            deadline = mock.Mock(expires=1200.0, launch_monotonic=0.0)
            deadline.remaining.return_value = 300.0
            with mock.patch.object(RUN.subprocess, "run", return_value=process), \
                 mock.patch.object(RUN.time, "perf_counter", side_effect=[0.0, 300.001]):
                with self.assertRaises(RUN.generations.IncompleteProcess):
                    RUN.run(["authored-command"], root, root / "late", deadline=deadline)
            result = json.loads((root / "late.json").read_text())
            self.assertEqual(result["exit_code"], 0)
            self.assertEqual(result["wall_seconds"], 300.001)
            self.assertEqual((root / "late.stdout").read_bytes(), b"actual output")
            deadline.check.assert_not_called()


if __name__ == "__main__":
    unittest.main()
