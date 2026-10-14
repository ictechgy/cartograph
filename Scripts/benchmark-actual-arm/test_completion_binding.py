"""합성 영수증으로 게시 판정의 실제 파일 결합과 형식 경계를 검증한다."""

import argparse
import copy
import hashlib
import json
import shutil
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import publish_correctness as publication
import state_inputs


class CompletionBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.raw = Path(self.temp.name).resolve()
        env = publication.controller.identity.private_environment(self.raw / "private-state")
        startup = publication.controller.startup_profile
        observed = startup.observe_request(startup.environment_request(env), env)
        self.runtime = dict(
            schema_version=2,
            startup_profile=startup.profile(observed),
            python=dict(path=sys.executable, sha256="b" * 64, bytes=20),
            code_files={str(publication.ROOT / name): "c" * 64 for name in (
                "state_worker.py", "engine_worker.py", "runtime/vendor/process_tree_measure.py"
            )},
            package=dict(target=str(self.raw / "private-package"), content=dict(content_sha256="a" * 64)),
        )
        self.plan = dict(
            accepted=dict(sdk_content_identity=None),
            engine_config=dict(developer_directory=str(self.raw), project=str(self.raw), state_id="restored_rebuilt"),
        )
        env["DEVELOPER_DIR"] = str(self.raw)
        observed = startup.observe_request(startup.environment_request(env), env)
        self.write("setup/runtime.json", self.runtime)
        self.write("setup/plan.json", self.plan)
        runtime_ref = state_inputs.reference(self.raw / "setup/runtime.json")
        plan_ref = state_inputs.reference(self.raw / "setup/plan.json")
        arguments = [
            "--plan",
            plan_ref["path"],
            "--plan-sha256",
            plan_ref["sha256"],
            "--runtime",
            runtime_ref["path"],
            "--runtime-sha256",
            runtime_ref["sha256"],
            "--output",
            str(self.raw),
        ]
        command = publication.controller.isolated_measure.bootstrap_command(
            Path(runtime_ref["path"]),
            runtime_ref["sha256"],
            publication.ROOT / "state_worker.py",
            self.raw / "setup/state-runtime/runtime-result.json",
            arguments,
        )
        self.phase = dict(
            command=command,
            completed=True,
            passed=True,
            returncode=0,
            observed_returncode=0,
            failure=None,
            cleanup_root_unfinished=False,
            cleanup_signals=[],
        )
        modules = dict(psutil=dict(path=str(self.raw / "private-package/psutil/__init__.py"), kind="private-package"))
        snapshot = dict(
            modules=modules,
            sha256=hashlib.sha256(json.dumps(modules, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        )
        package = dict(
            matches=True, expected_sha256="a" * 64, actual_sha256="a" * 64, actual=dict(content_sha256="a" * 64)
        )
        self.receipt = dict(
            runtime_receipt_sha256=runtime_ref["sha256"],
            entrypoint=dict(path=str(publication.ROOT / "state_worker.py"), sha256="c" * 64),
            selected_code_files=self.runtime["code_files"],
            arguments_sha256=hashlib.sha256(json.dumps(arguments, separators=(",", ":")).encode()).hexdigest(),
            exit_code=0,
            observed_exit_code=0,
            workload_started=True,
            python=self.runtime["python"],
            status="passed",
            code_after=dict(status="passed"),
            package_before=package,
            package_after=package,
            modules_before=snapshot,
            modules_after=snapshot,
        )
        request = publication.controller.isolated_measure.STARTUP.launch_row(
            self.runtime, runtime_ref["sha256"], publication.ROOT / "state_worker.py", arguments, env
        )
        self.write("setup/state-runtime/environment-request.json", request)
        self.receipt.update(
            environment_request_sha256=state_inputs.reference(
                self.raw / "setup/state-runtime/environment-request.json"
            )["sha256"],
            environment_before=observed,
            environment_after=observed,
        )
        self.state = dict(
            role="single-restored-state-correctness-validation",
            final_evidence=False,
            status="passed",
            exit_code=0,
            order="AB",
            arms=[
                dict(arm=name, status="passed", exit_code=0, may_continue=True) for name in ["baseline", "cartograph"]
            ],
        )
        self.state["arms"] = [self.arm(name) for name in ("baseline", "cartograph")]
        self.record = dict(
            schema_version=1,
            status="passed",
            exit_code=0,
            final_evidence=False,
            role="actual-arm-correctness-controller",
            performance_ratio=None,
            superiority_claim=None,
            preparation_wall_seconds=0,
            controller_intervals=[],
            whole_state_process=copy.deepcopy(self.phase),
            contracts=dict(status="passed", exit_code=0),
            terminal_guard=dict(status="passed", generation=self.plan["accepted"]),
            runtime_source_inputs_unchanged=True,
            state_runtime=copy.deepcopy(self.receipt),
            state_result=copy.deepcopy(self.state),
            total_wall_seconds_before_receipt=0,
            cost_accounting="synthetic schema test only",
            selected_launch={},
        )
        self.rewrite()

    def arm(self, name, folder=None):
        folder = folder or self.raw / "runs/restored_rebuilt" / name
        inputs = dict(self.plan["engine_config"], arm=name, output=str(folder))
        self.write(str(folder.relative_to(self.raw) / "input.json"), inputs)
        input_ref = state_inputs.reference(folder / "input.json")
        runtime_ref = state_inputs.reference(self.raw / "setup/runtime.json")
        arguments = ["--input", input_ref["path"], "--sha256", input_ref["sha256"]]
        original = {}
        commands = {}
        for role, script, args in (
            ("engine", publication.ROOT / "engine_worker.py", arguments),
            ("observer", publication.controller.isolated_measure.HELPER, ["--worker"]),
        ):
            env = publication.controller.identity.private_environment(
                self.raw / "private-readers" / folder.name / role, self.raw
            )
            report = folder / (role + "-runtime/runtime-result.json")
            commands[role] = publication.controller.isolated_measure.bootstrap_command(
                self.raw / "setup/runtime.json", runtime_ref["sha256"], script, report, args
            )
            request = publication.controller.isolated_measure.STARTUP.launch_row(
                self.runtime, runtime_ref["sha256"], script, args, env
            )
            env_path = report.parent / "environment-request.json"
            self.write(str(env_path.relative_to(self.raw)), request)
            observed = publication.controller.startup_profile.observe_request(
                publication.controller.startup_profile.environment_request(env), env
            )
            receipt = copy.deepcopy(self.receipt)
            receipt.update(
                entrypoint=dict(path=str(script), sha256="c" * 64),
                arguments_sha256=hashlib.sha256(json.dumps(args, separators=(",", ":")).encode()).hexdigest(),
                environment_request_sha256=state_inputs.reference(env_path)["sha256"],
                environment_before=observed,
                environment_after=observed,
            )
            self.write(str(report.relative_to(self.raw)), receipt)
            original[role] = receipt
        command = dict(
            command=commands["engine"], cwd=str(self.raw), timeout_seconds=240,
            interval_seconds=0.01, measurement_mode="timing",
        )
        self.write(str(folder.relative_to(self.raw) / "whole-arm.command.json"), command)
        measured = dict(
            status="ok", returncode=0, root_returncode=0, failure=None, timed_out=False,
            helper_sha256=publication.controller.isolated_measure.HELPER_SHA256,
            measurement_mode="timing", sampling_during_timing=False, primary_timing_eligible=True,
            containment=dict(read_errors=[]), cleanup=None, wall_seconds=1.0,
            root_exit_observed_seconds=1.0, supervision_total_seconds=1.0,
            artifacts=dict(command=dict(name="whole-arm.command.json",
                sha256=state_inputs.reference(folder / "whole-arm.command.json")["sha256"])),
        )
        observer = dict(
            command=commands["observer"], status="passed", exit_code=0, observed_helper_returncode=0,
            workload_returncode=0, cleanup_signals=[], final_evidence=False,
            mode="timing", periodic_sampling=False, measurement=measured,
            runtime=original["observer"], engine_runtime=original["engine"],
        )
        worker = dict(arm=name, state_id="restored_rebuilt", status="ok")
        row = dict(
            arm=name, status="passed", exit_code=0, may_continue=True, final_evidence=False,
            guard_before=dict(status="passed", generation=self.plan["accepted"]),
            guard_after=dict(status="passed", generation=self.plan["accepted"]),
            observer=observer, worker=worker,
        )
        for path, value in (
            ("arm-result.json", row), ("worker-result.json", worker),
            ("whole-arm.observer.json", observer), ("whole-arm.json", measured),
        ):
            self.write(str(folder.relative_to(self.raw) / path), value)
        return copy.deepcopy(row)

    def write(self, name, value):
        p = self.raw / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(value))

    def rewrite(self):
        for name, value in [
            ("setup/whole-state.json", self.phase),
            ("setup/state-runtime/runtime-result.json", self.receipt),
            ("results.json", self.state),
            ("setup/controller-result.json", self.record),
        ]:
            self.write(name, value)

    def result(self):
        with mock.patch.object(
            publication.controller.contract_prerequisites, "verify", return_value={}
        ), mock.patch.object(publication, "completed_launch", return_value={}):
            return publication.completion_receipt(self.raw, dict(exit_code=0))

    def test_consistent_original_files_bind_all_state_and_both_arm_hashes(self):
        row = self.result()
        self.assertEqual(row["status"], "verified")
        self.assertEqual(row["outcome"], "passed")
        self.assertEqual(
            set(row["bound_file_sha256"]),
            {"phase", "runtime", "state", "plan", "runtime_inputs", "runtime_environment"}
            | {"arm-copy:runs/restored_rebuilt/" + arm + "/" + name
               for arm in ("baseline", "cartograph") for name in publication.ARM_COMPLETION_FILES},
        )

    def test_missing_actual_phase_or_runtime_is_not_success(self):
        for name in ["setup/whole-state.json", "setup/state-runtime/runtime-result.json"]:
            with self.subTest(name=name):
                data = (self.raw / name).read_bytes()
                (self.raw / name).unlink()
                self.assertEqual(self.result()["status"], "unavailable")
                (self.raw / name).write_bytes(data)

    def test_embedded_state_cannot_override_actual_failure(self):
        self.state.update(status="failed", exit_code=1)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_embedded_runtime_cannot_override_actual_failure(self):
        self.receipt.update(status="failed", exit_code=9)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_boolean_exit_in_any_success_layer_is_refused(self):
        for value, key in [
            (self.record, "exit_code"),
            (self.phase, "returncode"),
            (self.phase, "observed_returncode"),
            (self.state, "exit_code"),
            (self.receipt, "exit_code"),
            (self.receipt, "observed_exit_code"),
        ]:
            with self.subTest(key=key):
                old = value[key]
                value[key] = False
                self.rewrite()
                self.assertEqual(self.result()["status"], "unavailable")
                value[key] = old
        self.rewrite()

    def test_untyped_embedded_duplicate_cannot_equal_typed_actual_zero(self):
        self.record["state_result"]["exit_code"] = False
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_changed_command_or_terminal_generation_is_refused(self):
        self.phase["command"][-1] = "/other-output"
        self.record["whole_state_process"] = copy.deepcopy(self.phase)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_completion_hashes_must_match_the_actual_staged_manifest(self):
        completion = self.result()
        paths = {
            "phase": "setup/whole-state.json",
            "runtime": "setup/state-runtime/runtime-result.json",
            "state": "results.json",
            "plan": "setup/plan.json",
            "runtime_inputs": "setup/runtime.json",
            "runtime_environment": "setup/state-runtime/environment-request.json",
        }
        manifest = dict(
            files=[dict(path="setup/controller-result.json", original_raw_sha256=completion["sha256"])]
            + [
                dict(path=key.removeprefix("arm-copy:") if key.startswith("arm-copy:") else paths[key],
                     original_raw_sha256=value)
                for key, value in completion["bound_file_sha256"].items()
            ]
        )
        publication.verify_completion_manifest(completion, manifest)
        for row in manifest["files"]:
            with self.subTest(path=row["path"]):
                original = row["original_raw_sha256"]
                row["original_raw_sha256"] = "0" * 64
                with self.assertRaises(ValueError):
                    publication.verify_completion_manifest(completion, manifest)
                row["original_raw_sha256"] = original

    def test_each_original_arm_receipt_is_required_despite_successful_duplicates(self):
        for arm in ("baseline", "cartograph"):
            for name in publication.ARM_COMPLETION_FILES:
                with self.subTest(arm=arm, name=name):
                    path = self.raw / "runs/restored_rebuilt" / arm / name
                    original = path.read_bytes()
                    path.unlink()
                    self.assertEqual(self.result()["status"], "unavailable")
                    path.write_bytes(original)

    def test_each_original_arm_receipt_contradiction_is_refused(self):
        for arm in ("baseline", "cartograph"):
            for name in publication.ARM_COMPLETION_FILES:
                with self.subTest(arm=arm, name=name):
                    path = self.raw / "runs/restored_rebuilt" / arm / name
                    original = path.read_bytes()
                    value = json.loads(original)
                    value["unbound_change"] = True
                    path.write_text(json.dumps(value))
                    self.assertEqual(self.result()["status"], "unavailable")
                    path.write_bytes(original)

    def test_helper_argv_must_use_original_selected_request(self):
        folder = self.raw / "runs/restored_rebuilt/baseline"
        row = copy.deepcopy(self.state["arms"][0])
        row["observer"]["command"][0] = "/different-python"
        self.state["arms"][0] = row
        self.record["state_result"] = copy.deepcopy(self.state)
        self.write(str(folder.relative_to(self.raw) / "arm-result.json"), row)
        self.write(str(folder.relative_to(self.raw) / "whole-arm.observer.json"), row["observer"])
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_original_command_hash_cannot_be_replaced_by_rebound_duplicates(self):
        folder = self.raw / "runs/restored_rebuilt/baseline"
        path = folder / "whole-arm.command.json"
        value = json.loads(path.read_text())
        value["command"][0] = "/different-python"
        path.write_text(json.dumps(value))
        row = copy.deepcopy(self.state["arms"][0])
        row["observer"]["measurement"]["artifacts"]["command"]["sha256"] = state_inputs.reference(path)["sha256"]
        self.state["arms"][0] = row
        self.record["state_result"] = copy.deepcopy(self.state)
        self.write(str(folder.relative_to(self.raw) / "arm-result.json"), row)
        self.write(str(folder.relative_to(self.raw) / "whole-arm.observer.json"), row["observer"])
        self.write(str(folder.relative_to(self.raw) / "whole-arm.json"), row["observer"]["measurement"])
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_missing_arm_receipts_do_not_erase_failed_or_incomplete_retention(self):
        for arm in ("baseline", "cartograph"):
            for name in publication.ARM_COMPLETION_FILES:
                (self.raw / "runs/restored_rebuilt" / arm / name).unlink()
        for code, status in ((9, "failed"), (125, "incomplete")):
            with self.subTest(status=status):
                self.record.update(status=status, exit_code=code)
                self.rewrite()
                row = publication.completion_receipt(self.raw, dict(exit_code=code))
                self.assertEqual(row["outcome"], "retained-" + status)
                self.assertNotIn("bound_file_sha256", row)

    def test_completed_failure_is_retained_without_success_certification(self):
        self.record.update(status="failed", exit_code=9)
        self.rewrite()
        row = publication.completion_receipt(self.raw, dict(exit_code=9))
        self.assertEqual(row["outcome"], "retained-failed")
        self.assertNotIn("bound_file_sha256", row)


class CalibrationCompletionTests(unittest.TestCase):
    write = CompletionBindingTests.write
    rewrite = CompletionBindingTests.rewrite
    arm = CompletionBindingTests.arm

    def setUp(self):
        CompletionBindingTests.setUp(self)
        shutil.rmtree(self.raw / "runs/restored_rebuilt")
        shutil.rmtree(self.raw / "private-readers")
        self.plan["calibration"] = state_inputs.calibration_plan()
        self.sdk = dict(content_sha256="d" * 64, accepted=False, final_protocol_ready=False)
        self.sdk_cost = dict(phases={"before-compilation": 1.0, "after-generation": 1.0})
        self.plan.update(calibration_sdk=copy.deepcopy(self.sdk), prior_costs=dict(calibration_sdk=copy.deepcopy(self.sdk_cost)))
        self.write("setup/calibration-oracle.json", dict(synthetic=True))
        self.plan["inputs"] = dict(oracle=state_inputs.reference(self.raw / "setup/calibration-oracle.json"))
        self.write("setup/plan.json", self.plan)
        self.write("setup/calibration-plan.json", self.plan["calibration"])
        self.full_rows = []
        self.evaluation = dict(status="passed", scored=True)
        for item in self.plan["calibration"]["invocations"]:
            folder = self.raw / "runs/calibration" / item["folder"]
            row = self.arm(item["engine"], folder)
            row["worker"].update(graph={}, observation={})
            self.write(str(folder.relative_to(self.raw) / "worker-result.json"), row["worker"])
            self.write(str(folder.relative_to(self.raw) / "source-catalog.json"), [])
            self.write(str(folder.relative_to(self.raw) / "normalized-graph.json"), row["worker"]["graph"])
            self.write(str(folder.relative_to(self.raw) / "observation.json"), row["worker"]["observation"])
            for suffix in ("stdout", "stderr", "observer.stdout", "observer.stderr"):
                (folder / ("whole-arm." + suffix)).write_bytes(b"")
            observer = row["observer"]
            measured = observer["measurement"]
            measured.update(schema_version=2, wall_seconds=1.0, measurement_mode=item["observer"],
                            primary_timing_eligible=item["observer"] == "timing")
            command_path = folder / "whole-arm.command.json"
            request = json.loads(command_path.read_text())
            if item["observer"] == "direct":
                request = dict(command=request["command"], cwd=request["cwd"], timeout_seconds=240, mode="direct")
                observer = dict(
                    mode="direct", command=request["command"], status="passed", exit_code=0, workload_returncode=0,
                    engine_runtime=observer["engine_runtime"], engine_wall_seconds=1.0, final_evidence=False,
                    cleanup_signals=[], cleanup_errors=[], wait_method="blocking_Popen_wait_with_one_POSIX_ITIMER_REAL_deadline",
                    measurement=dict(measurement_mode="direct", wall_seconds=1.0, root_returncode=0,
                                     status="ok", failure=None, timed_out=False, primary_timing_eligible=False),
                )
                row["observer"] = observer
                shutil.rmtree(folder / "observer-runtime")
                shutil.rmtree(self.raw / "private-readers" / item["folder"] / "observer")
                for name in ("whole-arm.json", "whole-arm.observer.json", "whole-arm.observer.stdout", "whole-arm.observer.stderr"):
                    (folder / name).unlink()
            else:
                request["measurement_mode"] = item["observer"]
                observer.update(mode=item["observer"], periodic_sampling=item["observer"] == "memory")
                if item["observer"] == "memory":
                    measured["rss"] = dict(sample_chunks=[])
            command_path.write_text(json.dumps(request))
            if item["observer"] != "direct":
                for name in ("command", "stdout", "stderr"):
                    path = folder / ("whole-arm." + ("command.json" if name == "command" else name))
                    measured["artifacts"][name] = dict(name=path.name, sha256=state_inputs.reference(path)["sha256"])
            row.update(invocation=item, evaluation=copy.deepcopy(self.evaluation))
            self.full_rows.append(row)
            self.write("setup/calibration-started/" + item["folder"] + ".json", item)
        self.state = dict(
            schema_version=1, role="actual-engine-observer-calibration", status="passed", exit_code=0,
            final_evidence=False, plan=self.plan["calibration"], invocations=[], groups=[], skipped_invocations=[],
            superiority_claim=None, wall_seconds_before_receipt=1.0,
            initial_guard=dict(status="passed", generation=self.plan["accepted"]),
            terminal_guard=dict(status="passed", generation=self.plan["accepted"]),
        )
        self.sync_calibration()
        plan_ref = state_inputs.reference(self.raw / "setup/plan.json")
        runtime_ref = state_inputs.reference(self.raw / "setup/runtime.json")
        arguments = ["--plan", plan_ref["path"], "--plan-sha256", plan_ref["sha256"], "--runtime", runtime_ref["path"],
                     "--runtime-sha256", runtime_ref["sha256"], "--output", str(self.raw)]
        measure = publication.controller.isolated_measure
        self.phase["command"] = measure.bootstrap_command(
            self.raw / "setup/runtime.json", runtime_ref["sha256"], publication.ROOT / "state_worker.py",
            self.raw / "setup/state-runtime/runtime-result.json", arguments,
        )
        self.receipt["arguments_sha256"] = hashlib.sha256(json.dumps(arguments, separators=(",", ":")).encode()).hexdigest()
        environment = measure.STARTUP.existing_environment(self.raw / "private-state", str(self.raw))
        launch = measure.STARTUP.launch_row(self.runtime, runtime_ref["sha256"], publication.ROOT / "state_worker.py",
                                          arguments, environment)
        self.write("setup/state-runtime/environment-request.json", launch)
        self.receipt["environment_request_sha256"] = state_inputs.reference(self.raw / "setup/state-runtime/environment-request.json")["sha256"]
        self.record.update(whole_state_process=copy.deepcopy(self.phase), state_runtime=copy.deepcopy(self.receipt))
        self.sync_calibration()

    def sync_calibration(self, groups=True):
        self.state["invocations"] = []
        for row in self.full_rows:
            item = row["invocation"]
            relative = "runs/calibration/" + item["folder"]
            arm = {key: value for key, value in row.items() if key not in ("invocation", "evaluation")}
            self.write(relative + "/arm-result.json", arm)
            direct = item["observer"] == "direct"
            self.write(relative + ("/whole-arm.direct.json" if direct else "/whole-arm.observer.json"), row["observer"])
            if not direct:
                self.write(relative + "/whole-arm.json", row["observer"]["measurement"])
            self.write(relative + "/calibration-result.json", dict(
                invocation=item, evaluation=row["evaluation"],
                arm_result=state_inputs.reference(self.raw / relative / "arm-result.json"),
            ))
            self.state["invocations"].append(dict(
                invocation=item, result=state_inputs.reference(self.raw / relative / "calibration-result.json"),
                status=row["status"], exit_code=row["exit_code"],
            ))
        if groups:
            self.state["groups"] = state_inputs.calibration_groups(self.full_rows)
        self.record["state_result"] = copy.deepcopy(self.state)
        self.rewrite()

    def sdk_rebind(self, plan, scratch):
        self.assertEqual(scratch, self.raw.parent)
        plan["calibration_sdk"] = copy.deepcopy(self.sdk)
        plan["prior_costs"]["calibration_sdk"] = copy.deepcopy(self.sdk_cost)

    def result(self, **attempt):
        with mock.patch.object(publication.state_inputs, "bind_calibration_sdk", side_effect=self.sdk_rebind), \
                mock.patch.object(publication.controller.contract_prerequisites, "verify", return_value={}), \
                mock.patch.object(publication, "completed_launch", return_value={}), \
                mock.patch.object(publication.state_worker, "evaluate", return_value=self.evaluation), \
                mock.patch.object(publication.controller.isolated_measure, "verify_memory"):
            return publication.completion_receipt(
                self.raw, {"exit_code": 0, "calibration_mode": "native-observer-v1", **attempt}
            )

    def test_all32_original_files_bind_with_independent_timing_groups(self):
        result = self.result()
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["outcome"], "passed")
        self.assertEqual(len([key for key in result["bound_file_sha256"] if key.endswith("/arm-result.json")]), 32)
        self.assertEqual(len([key for key in result["bound_file_sha256"] if key.endswith("/calibration-result.json")]), 32)
        self.assertEqual([row["timing_eligible"] for row in self.state["groups"]], [True, None, True, None])

    def test_missing_extra_or_reordered_invocations_cannot_complete(self):
        for relative in ("runs/calibration", "private-readers"):
            path = self.raw / relative / "invocation-32"
            backup = self.raw / "held-invocation"
            path.rename(backup)
            self.assertEqual(self.result()["status"], "unavailable")
            backup.rename(path)
            extra = self.raw / relative / "invocation-33"
            extra.mkdir()
            self.assertEqual(self.result()["status"], "unavailable")
            extra.rmdir()
        self.state["invocations"].reverse()
        self.record["state_result"] = copy.deepcopy(self.state)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_calibration_original_arm_reference_cannot_be_forged(self):
        path = self.raw / "runs/calibration/invocation-01/arm-result.json"
        value = json.loads(path.read_text())
        value["exit_code"] = False
        path.write_text(json.dumps(value))
        self.assertEqual(self.result()["status"], "unavailable")

    def test_calibration_typed_modes_exits_and_measurement_hashes_are_required(self):
        for index, key, value in ((0, "exit_code", False), (1, "mode", "memory"), (1, "observed_helper_returncode", False)):
            original = copy.deepcopy(self.full_rows[index])
            self.full_rows[index]["observer"][key] = value
            self.sync_calibration(groups=False)
            self.assertEqual(self.result()["status"], "unavailable")
            self.full_rows[index] = original
        self.sync_calibration()
        path = self.raw / "runs/calibration/invocation-02/whole-arm.command.json"
        request = json.loads(path.read_text())
        request["timeout_seconds"] = 241
        path.write_text(json.dumps(request))
        self.assertEqual(self.result()["status"], "unavailable")

    def test_calibration_recomputes_all_oracle_evaluations(self):
        self.evaluation = dict(status="failed", scored=True)
        self.assertEqual(self.result()["status"], "unavailable")

    def test_calibration_recomputes_each_engine_timing_eligibility(self):
        for engine in ("baseline", "cartograph"):
            for row in self.full_rows:
                item = row["invocation"]
                if item["engine"] == engine and item["observer"] == "timing":
                    row["observer"]["measurement"].update(wall_seconds=1.2, root_exit_observed_seconds=1.2, supervision_total_seconds=1.2)
            self.sync_calibration()
            self.assertEqual(self.result()["status"], "unavailable")
            for row in self.full_rows:
                row["observer"]["measurement"].update(wall_seconds=1.0, root_exit_observed_seconds=1.0, supervision_total_seconds=1.0)
        self.sync_calibration()
        self.state["groups"][0]["median_ratio"] = 0.8
        self.record["state_result"] = copy.deepcopy(self.state)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_calibration_plan_or_started_invocation_tampering_is_refused(self):
        for relative in ("setup/calibration-plan.json", "setup/calibration-started/invocation-01.json"):
            path = self.raw / relative
            original = path.read_bytes()
            value = json.loads(original)
            value["unbound"] = True
            path.write_text(json.dumps(value))
            self.assertEqual(self.result()["status"], "unavailable")
            path.write_bytes(original)

    def test_calibration_compact_copy_reference_must_match_original(self):
        self.state["invocations"][0]["result"]["sha256"] = "0" * 64
        self.record["state_result"] = copy.deepcopy(self.state)
        self.rewrite()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_failed_and_incomplete_calibration_histories_remain_nonpassing(self):
        shutil.rmtree(self.raw / "runs/calibration")
        for status, code in (("failed", 1), ("incomplete", 125)):
            self.record.update(status=status, exit_code=code)
            self.rewrite()
            result = publication.completion_receipt(self.raw, dict(exit_code=code, calibration_mode="native-observer-v1"))
            self.assertEqual(result["status"], "verified")
            self.assertEqual(result["outcome"], "retained-" + status)
            self.assertNotIn("bound_file_sha256", result)

    def test_calibration_forged_pass_with_direct_cleanup_error_refuses(self):
        observer = self.full_rows[0]["observer"]
        for value in (None, {}, [dict(stage="poll", error_type="OSError")]):
            observer["cleanup_errors"] = value
            self.sync_calibration()
            self.assertEqual(self.result()["status"], "unavailable")

    def test_calibration_rehashed_direct_overbudget_interval_cannot_pass(self):
        row = self.full_rows[0]
        self.assertEqual(row["invocation"]["observer"], "direct")
        row["observer"]["engine_wall_seconds"] = 241.0
        row["observer"]["measurement"]["wall_seconds"] = 241.0
        self.sync_calibration()
        self.assertEqual(self.result()["status"], "unavailable")

    def test_calibration_graph_and_observation_originals_bind_exact_typed_values(self):
        for name in ("normalized-graph.json", "observation.json"):
            path = self.raw / "runs/calibration/invocation-01" / name
            original = path.read_bytes()
            for data in (None, b'{"unexpected": true}'):
                if data is None:
                    path.unlink()
                else:
                    path.write_bytes(data)
                self.assertEqual(self.result()["status"], "unavailable")
                path.write_bytes(original)

    def test_calibration_sdk_success_must_recompute_same_original_relation_and_costs(self):
        original = copy.deepcopy(self.sdk)
        self.sdk["content_sha256"] = "e" * 64
        self.assertEqual(self.result()["status"], "unavailable")
        self.sdk = original
        self.sdk_cost["phases"]["before-compilation"] = 0.0
        self.assertEqual(self.result()["status"], "unavailable")
        with mock.patch.object(self, "sdk_rebind", side_effect=ValueError("missing SDK original")):
            self.assertEqual(self.result()["status"], "unavailable")

    def test_calibration_manifest_requires_all_bound_original_hashes(self):
        completion = self.result()
        self.assertEqual(completion["status"], "verified")
        manifest = dict(files=[dict(path="setup/controller-result.json", original_raw_sha256=completion["sha256"])])
        with self.assertRaises(ValueError):
            publication.verify_completion_manifest(completion, manifest)


class ActualArmCompletionTests(unittest.TestCase):
    def test_real_two_arm_process_receipts_pass_and_missing_original_refuses(self):
        import test_bound_arm_process as fixtures
        import state_worker

        fixture = fixtures.BoundArmProcessTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.plan["engine_config"]["state_id"] = "restored_rebuilt"
        fixture.configure(
            'Path(c["output"],"worker-result.json").write_text(json.dumps('
            '{"status":"ok","arm":c["arm"],"state_id":c["state_id"]}))'
        )
        runtime = json.loads(fixture.runtime.read_text())
        startup = publication.controller.startup_profile
        environment = state_worker.identity.private_environment(fixture.root / "profile-private")
        for name in ("startup_profile.py", "startup_binding.py", "interpreter_relation.py"):
            source = publication.ROOT / "runtime" / name
            runtime["code_files"][str(source)] = state_worker.identity.file_identity(source)["sha256"]
        controller = publication.controller
        sources = controller.source_hashes(controller.source_policy.EARLY_SOURCES)
        sources.update(runtime["code_files"])
        collection_path = fixture.root / "profile-collection"
        collection = controller.profile_collection.collect(
            environment, Path(sys.executable), Path(sys.executable), controller.ROOT / "correctness_controller.py",
            [Path(path) for path in sources], collection_path, controller.command_runner.command,
        )
        self.assertEqual(collection["status"], "passed", collection)
        collection_ref = state_inputs.reference(collection_path / "results.json")
        relation = controller.selected_launch.interpreter_relation.from_collection(
            collection_path / "results.json", collection_ref["sha256"], environment, Path(sys.executable),
            controller.ROOT / "correctness_controller.py", sources,
        )
        runtime.update(schema_version=3, startup_profile=collection["accepted_profile"], interpreter_relation=relation)
        (fixture.raw / "setup").mkdir()
        fixture.runtime = fixture.raw / "setup/runtime.json"
        fixture.runtime.write_text(json.dumps(runtime))
        (fixture.raw / "setup/plan.json").write_text(json.dumps(fixture.plan))
        runtime_ref = state_inputs.reference(fixture.runtime)
        guards = dict(status="passed", generation=fixture.plan["accepted"])
        with mock.patch.object(state_worker, "ROOT", fixture.scripts), mock.patch.object(
            state_worker, "guard", return_value=guards
        ), mock.patch.object(publication, "ROOT", fixture.scripts):
            for arm in ("baseline", "cartograph"):
                row = state_worker.run_arm(
                    fixture.plan, arm, fixture.raw / "runs/restored_rebuilt" / arm,
                    fixture.runtime, runtime_ref["sha256"],
                )
                self.assertEqual(row["status"], "passed", row)
                refs = publication.completed_arm(fixture.raw, arm, row, fixture.plan, runtime, runtime_ref)
                self.assertEqual(len(refs), len(publication.ARM_COMPLETION_FILES))
                report = fixture.raw / "runs/restored_rebuilt" / arm / "observer-runtime/runtime-result.json"
                original = report.read_bytes()
                report.unlink()
                with self.assertRaises((OSError, ValueError)):
                    publication.completed_arm(fixture.raw, arm, row, fixture.plan, runtime, runtime_ref)
                report.write_bytes(original)
                for role, embedded_key in (("engine", "engine_runtime"), ("observer", "runtime")):
                    with self.subTest(arm=arm, role=role):
                        folder = fixture.raw / "runs/restored_rebuilt" / arm
                        altered = copy.deepcopy(row)
                        altered["observer"][embedded_key]["interpreter_before"]["selected_path"] = "/unobserved-python"
                        replacements = {
                            folder / "arm-result.json": altered,
                            folder / "whole-arm.observer.json": altered["observer"],
                            folder / (role + "-runtime/runtime-result.json"): altered["observer"][embedded_key],
                        }
                        originals = {path: path.read_bytes() for path in replacements}
                        try:
                            for path, value in replacements.items():
                                path.write_text(json.dumps(value))
                            with self.assertRaises(ValueError):
                                publication.completed_arm(fixture.raw, arm, altered, fixture.plan, runtime, runtime_ref)
                        finally:
                            for path, value in originals.items():
                                path.write_bytes(value)
            (fixture.raw / "results.json").write_text(json.dumps(dict(status="actual-process-publication-control")))
            with mock.patch.object(publication.runtime_publication, "ROOT", fixture.scripts):
                manifest = publication.runtime_publication.package(
                    publication.NORMALIZER,
                    argparse.Namespace(input=fixture.raw, output=fixture.root / "public", prefix=[
                        "FIXTURE=" + str(fixture.root), "SOURCES=" + str(controller.ROOT),
                        "USR=/usr", "OPT=/opt", "PRIVATE=/private", "TEMP=/var", "TMP=/tmp",
                    ]),
                )
            bindings = manifest["runtime_module_projection"]["original_receipts"]
            self.assertEqual(len(bindings), 4)
            self.assertEqual({row["artifact"] for row in bindings}, {
                "runs/restored_rebuilt/" + arm + "/" + role + "-runtime/runtime-result.json"
                for arm in ("baseline", "cartograph") for role in ("engine", "observer")
            })
            projected = json.loads((fixture.root / "public/setup/runtime.json").read_text())
            self.assertEqual(projected["schema_version"], 3)
            self.assertIn("source_inputs", projected["interpreter_relation"])
            self.assertIn("reported_interpreter", projected["interpreter_relation"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
