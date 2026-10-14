"""고정 상태·소스 질의·출력 경계를 실제 파일 경로로 검증한다."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import state_inputs as inputs


class InputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.lifecycle = self.root / "lifecycle"
        self.measurement = self.root / "measurement"
        self.tools = self.root / "tools"
        for path in [self.repo, self.lifecycle, self.measurement, self.tools]:
            path.mkdir()
        fixture = self.repo / inputs.FIXTURE
        (fixture / "adapter").mkdir(parents=True)
        for name, dest in [("oracle.json", "oracle.json"), ("query-spec.json", "adapter/query-spec.json")]:
            (fixture / dest).write_bytes((Path(__file__).with_name("test-fixtures") / name).read_bytes())
        self.binary = self.tools / "binary"
        self.binary.write_bytes(b"synthetic executable")
        self.digest = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        developer = self.root / "Developer"
        toolchain = developer / "Toolchains/T.xctoolchain"
        platform = developer / "Platforms/iPhoneSimulator.platform"
        sdk = platform / "Developer/SDKs/Simulator.sdk"
        sdk.mkdir(parents=True)
        setup = dict(developer_dir=str(developer), sdk_path=str(sdk), platform_path=str(platform))
        for key, relative in [
            ("clang", "usr/bin/clang"),
            ("swiftc", "usr/bin/swiftc"),
            ("library", "usr/lib/libIndexStore.dylib"),
        ]:
            path = toolchain / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic compiler bytes")
            setup[key] = str(path)
        self.state = dict(
            name="restored_rebuilt",
            status="passed",
            oracle_variant="initial",
            expected_fresh=True,
            shared_input_cost=dict(wall_seconds=1),
            shared_preflight_integrity_wall_seconds_by_arm=dict(cartograph=0.1, index_dump_assembly=0.1),
        )
        self.data = dict(
            status="passed",
            compiler_index_policy="fresh-shared-v2",
            observation_failures=[],
            setup=setup,
            states=[dict(name=name, status="passed") for name in inputs.STATES[:-1]] + [self.state],
        )
        self.tool_data = dict(
            correctness_and_freshness_passed=True,
            cartograph=dict(
                binary=str(self.binary),
                binary_sha256=self.digest,
                setup=dict(build_cost_measured=True, build=dict(returncode=0, timed_out=False, wall_seconds=1)),
            ),
            comparator_setup=dict(
                binary=str(self.binary),
                binary_sha256=self.digest,
                repository="https://github.com/swiftlang/indexstore-db.git",
                revision="64aa0b26913249c4e7c21d351a215fba02702003",
                checkout=str(self.tools / "checkout"),
                commands=[dict(returncode=0, timed_out=False, wall_seconds=1)],
                help=dict(returncode=0, timed_out=False, wall_seconds=0.1),
                untracked_build_inputs=dict(passed=True),
            ),
        )
        self.write()

    def write(self):
        for path, value in [
            (self.lifecycle / "results.json", self.data),
            (self.lifecycle / "runs/restored_rebuilt/state.json", self.state),
            (self.lifecycle / "runs/restored_rebuilt/commands.json", []),
            (self.tools / "results.json", self.tool_data),
            (self.measurement / "results.json", {}),
        ]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))

    def prepare(self):
        with mock.patch.object(inputs.generation, "verify", return_value=dict(sdk_content_identity=None)):
            return inputs.prepare(
                self.repo,
                self.lifecycle / "results.json",
                self.tools / "results.json",
                self.measurement / "results.json",
            )

    def test_exact_state_yields_gold_free_engine_configuration(self):
        plan = self.prepare()
        config = plan["engine_config"]
        self.assertEqual(config["state_id"], "restored_rebuilt")
        self.assertEqual(len(config["queries"]), 10)
        self.assertNotIn("oracle", config)
        self.assertNotIn("oracle", config["generation_receipts"])
        self.assertEqual(set(config["generation_receipts"]), {"lifecycle", "state", "commands"})
        self.assertEqual(plan["inputs"]["oracle"]["sha256"], inputs.ORACLE_SHA256)

    def test_native_unset_override_binds_explicit_runtime_and_output_root(self):
        self.data["setup"]["developer_dir"] = None
        self.write()
        plan = self.prepare()
        expected = str(self.root / "Developer")
        self.assertEqual(plan["engine_config"]["developer_directory"], expected)
        self.assertIsNone(plan["engine_config"]["developer_context"]["requested_override"])
        self.assertIn(expected, plan["input_roots"])

    def test_prearm_input_guard_hashes_oracle_without_parsing_answers(self):
        plan = self.prepare()
        original = inputs.bootstrap.strict_json
        oracle = (self.repo / inputs.FIXTURE / "oracle.json").read_bytes()

        def forbid_answers(data):
            if data == oracle:
                raise AssertionError("Oracle answers parsed before completed arm observations")
            return original(data)

        with mock.patch.object(inputs.bootstrap, "strict_json", side_effect=forbid_answers), mock.patch.object(
            inputs.generation, "verify", return_value={}
        ):
            self.assertEqual(inputs.guard(plan)["status"], "passed")

    def test_missing_duplicate_or_failed_lifecycle_state_refuses(self):
        original = self.data["states"][:]
        for states in [
            original[:-1],
            original + [original[-1]],
            [{**s, "status": "failed"} if i == 2 else s for i, s in enumerate(original)],
        ]:
            self.data["states"] = states
            self.write()
            with self.assertRaises(ValueError):
                self.prepare()

    def test_state_receipt_cannot_differ_from_lifecycle(self):
        self.data["states"][-1] = dict(self.state, expected_fresh=False)
        self.write()
        with self.assertRaises(ValueError):
            self.prepare()

    def test_changed_source_selector_or_oracle_is_refused(self):
        for relative in ["adapter/query-spec.json", "oracle.json"]:
            path = self.repo / inputs.FIXTURE / relative
            original = path.read_bytes()
            path.write_bytes(original + b" ")
            with self.assertRaises(ValueError):
                self.prepare()
            path.write_bytes(original)

    def test_changed_binary_or_pin_cannot_reuse_prior_build_cost(self):
        self.binary.write_bytes(b"replaced")
        with self.assertRaises(ValueError):
            self.prepare()
        self.binary.write_bytes(b"synthetic executable")
        self.tool_data["comparator_setup"]["revision"] = "0" * 40
        self.write()
        with self.assertRaises(ValueError):
            self.prepare()

    def test_prior_baseline_build_failure_or_untyped_native_exit_refuses(self):
        baseline = self.tool_data["comparator_setup"]
        baseline["commands"] = [dict(returncode=9, timed_out=False, wall_seconds=1)]
        self.write()
        with self.assertRaises(ValueError):
            self.prepare()
        baseline["commands"] = [dict(returncode=0, timed_out=False, wall_seconds=1)]
        self.tool_data["cartograph"]["setup"]["build"]["returncode"] = False
        self.write()
        with self.assertRaises(ValueError):
            self.prepare()

    def test_output_alias_inside_input_refuses_before_write(self):
        alias = self.root / "alias"
        alias.symlink_to(self.repo, target_is_directory=True)
        for path in [self.repo / "out", alias / "out", self.root]:
            with self.assertRaises(ValueError):
                inputs.disjoint(path, [self.repo])
        self.assertFalse((self.repo / "out").exists())

    def test_new_sibling_output_passes_without_creating_it(self):
        path = self.root / "new"
        inputs.disjoint(path, [self.repo, self.lifecycle])
        self.assertFalse(path.exists())

    def test_existing_output_and_parent_spelling_refuse(self):
        for path in [self.repo, self.root / "x/../new"]:
            with self.assertRaises(ValueError):
                inputs.disjoint(path, [self.lifecycle])

    def test_duplicate_and_symlink_receipts_refuse(self):
        path = self.lifecycle / "results.json"
        path.write_text('{"status":"passed","status":"failed"}')
        with self.assertRaises(ValueError):
            self.prepare()
        path.unlink()
        path.symlink_to(self.tools / "results.json")
        with self.assertRaises(ValueError):
            self.prepare()


class CalibrationSdkBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo, self.scratch = self.root / "repo", self.root / "scratch"
        self.repo.mkdir()
        self.scratch.mkdir()
        for relative in inputs.CALIBRATION_INPUT_HELPERS:
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic reviewed helper: " + relative)
        self.hashes = {name: inputs.reference(self.repo / name)["sha256"]
                       for name in inputs.CALIBRATION_INPUT_HELPERS}
        self.plan = dict(repository=str(self.repo), inputs={}, prior_costs={}, engine_config={})
        self.content = "a" * 64
        native = dict(platform="darwin", runner={"ImageOS": "macos26", "ImageVersion": "20260907.0351.1"},
                      machine={"architecture": "arm64"}, versions={"sdk_version": "26.5"},
                      selected={"sdk": "selected-sdk"}, layout={"roots": {"SDK": "physical-sdk"}})
        self.phases, self.calls = {}, {}
        for name, status in [("before-compilation", "captured-candidate"),
                             ("after-generation", "verified-candidate")]:
            observation = dict(status=status, boundary=name, accepted=False, final_protocol_ready=False,
                               native=json.loads(json.dumps(native)))
            if name == "before-compilation":
                observation.update(content_sha256=self.content,
                                   expectation_sha256=self.hashes[inputs.CALIBRATION_INPUT_HELPERS[2]])
            else:
                observation["verification"] = dict(matches=True, expected_sha256=self.content,
                                                   actual_sha256=self.content)
            self.phases[name] = dict(stage=name, status="passed", exit_code=0, accepted=False,
                                     final_protocol_ready=False, helper_sha256=dict(self.hashes),
                                     observation=observation)
            if name == "after-generation":
                self.phases[name]["discovery_binding"] = dict(status="bound-candidate",
                                                             precompilation_content_sha256=self.content)
            command = dict(command=[inputs.sys.executable, "-I", "-S", "-B",
                                    str(self.repo / inputs.CALIBRATION_INPUT_HELPERS[0]),
                                    "--stage", name, "--scratch-root", str(self.scratch), "--execute-stage"],
                           cwd=str(self.repo), completed=True, passed=True, returncode=0, observed_returncode=0,
                           failure=None, cleanup_signals=[], cleanup_root_unfinished=False, wall_seconds=4.0)
            self.calls[name] = dict(stage=name, status="passed", exit_code=0, accepted=False,
                                    final_protocol_ready=False, helper_sha256=dict(self.hashes),
                                    command=command, full_call_wall_seconds_before_receipt=4.5)
        self.write()

    def phase_path(self, name):
        return self.scratch / "native-calibration-sdk-raw/setup/phases" / (name + ".json")

    def call_path(self, name):
        return self.scratch / "native-calibration-sdk-calls" / name / "results.json"

    def write(self, *, refresh_original=True):
        for name in self.phases:
            phase, call = self.phase_path(name), self.call_path(name)
            phase.parent.mkdir(parents=True, exist_ok=True)
            call.parent.mkdir(parents=True, exist_ok=True)
            phase.write_text(json.dumps(self.phases[name], sort_keys=True))
            if refresh_original:
                self.calls[name]["original_phase"] = inputs.reference(phase)
            call.write_text(json.dumps(self.calls[name], sort_keys=True))

    def bind(self):
        return inputs.bind_calibration_sdk(self.plan, self.scratch)

    def test_sdk_binding_keeps_four_original_refs_and_full_cost_for_both_engines(self):
        result = self.bind()
        self.assertEqual(result["content_sha256"], self.content)
        self.assertFalse(result["accepted"])
        self.assertFalse(result["final_protocol_ready"])
        self.assertEqual(len(result["phases"]), 4)
        self.assertEqual(len(self.plan["inputs"]), 4 + len(inputs.CALIBRATION_INPUT_HELPERS))
        self.assertEqual(result["source_sha256"], self.hashes)
        for name in self.phases:
            self.assertEqual(result["phases"][name], inputs.reference(self.phase_path(name)))
            self.assertEqual(result["phases"][name + "-caller"], inputs.reference(self.call_path(name)))
            cost = self.plan["prior_costs"]["calibration_sdk"]["phases"][name]
            self.assertEqual(cost["child_process_wall_seconds"], 4.0)
            self.assertEqual(cost["supervisor_wall_seconds_before_receipt"], 4.5)
            self.assertEqual(cost["charged_child_wall_seconds_by_arm"], dict(baseline=4.0, cartograph=4.0))

    def test_sdk_binding_requires_exact_actual_argv_and_cwd(self):
        name = "after-generation"
        original = json.loads(json.dumps(self.calls[name]["command"]))
        mutations = [lambda row: row["command"].remove("-S"),
                     lambda row: row["command"].__setitem__(4, str(self.repo / "other.py")),
                     lambda row: row["command"].__setitem__(6, "before-compilation"),
                     lambda row: row["command"].__setitem__(8, str(self.root / "other-scratch")),
                     lambda row: row["command"].append("--extra"),
                     lambda row: row.update(cwd=str(self.root))]
        for mutate in mutations:
            row = json.loads(json.dumps(original))
            mutate(row)
            self.calls[name]["command"] = row
            self.write()
            with self.subTest(command=row), self.assertRaisesRegex(ValueError, "actual caller differs"):
                self.bind()
            self.assertEqual(self.plan["inputs"], {})

    def test_sdk_binding_rejects_original_phase_reference_mismatch(self):
        self.calls["after-generation"]["original_phase"]["sha256"] = "0" * 64
        self.write(refresh_original=False)
        with self.assertRaisesRegex(ValueError, "phase relation differs"):
            self.bind()

    def test_sdk_binding_rejects_same_hash_original_at_other_path(self):
        name = "before-compilation"
        other = self.root / "copied-phase.json"
        other.write_bytes(self.phase_path(name).read_bytes())
        self.calls[name]["original_phase"] = inputs.reference(other)
        self.write(refresh_original=False)
        with self.assertRaisesRegex(ValueError, "phase relation differs"):
            self.bind()

    def test_sdk_binding_requires_typed_zero_phase_and_caller_exits(self):
        for target in [self.phases, self.calls]:
            for bad in [False, "0", 1, 125]:
                target["before-compilation"]["exit_code"] = bad
                self.write()
                with self.subTest(target=target is self.phases, value=bad), self.assertRaisesRegex(
                        ValueError, "phase relation differs"):
                    self.bind()
            target["before-compilation"]["exit_code"] = 0

    def test_sdk_binding_requires_typed_actual_child_exits_and_clean_completion(self):
        row = self.calls["after-generation"]["command"]
        for key, bad in [("returncode", False), ("observed_returncode", "0"), ("completed", False),
                         ("passed", False), ("failure", "timeout"), ("cleanup_signals", ["term-sent"]),
                         ("cleanup_root_unfinished", True)]:
            original = row[key]
            row[key] = bad
            self.write()
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "actual caller differs"):
                self.bind()
            row[key] = original

    def test_sdk_binding_requires_complete_current_helper_set(self):
        original = dict(self.phases["before-compilation"]["helper_sha256"])
        for replacement in [{}, {**original, "extra-helper.py": "b" * 64},
                            {**original, inputs.CALIBRATION_INPUT_HELPERS[0]: "0" * 64}]:
            self.phases["before-compilation"]["helper_sha256"] = replacement
            self.write()
            with self.subTest(replacement=replacement), self.assertRaisesRegex(ValueError, "phase relation differs"):
                self.bind()

    def test_sdk_binding_changed_helper_bytes_cannot_reuse_recorded_hashes(self):
        path = self.repo / inputs.CALIBRATION_INPUT_HELPERS[0]
        path.write_text("changed helper")
        with self.assertRaisesRegex(ValueError, "phase relation differs"):
            self.bind()

    def test_sdk_binding_rejects_changed_native_stable_fields(self):
        native = self.phases["after-generation"]["observation"]["native"]
        for key in ["platform", "runner", "machine", "versions", "selected", "layout"]:
            original = native[key]
            native[key] = "changed"
            self.write()
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "content relation differs"):
                self.bind()
            native[key] = original

    def test_sdk_binding_rejects_content_and_expectation_mismatch(self):
        before = self.phases["before-compilation"]["observation"]
        after = self.phases["after-generation"]["observation"]
        binding = self.phases["after-generation"]["discovery_binding"]
        for target, key, bad in [(before, "content_sha256", "g" * 64),
                                 (before, "expectation_sha256", "0" * 64),
                                 (after["verification"], "matches", False),
                                 (after["verification"], "actual_sha256", "0" * 64),
                                 (after["verification"], "expected_sha256", "0" * 64),
                                 (binding, "status", "failed"),
                                 (binding, "precompilation_content_sha256", "0" * 64)]:
            original = target[key]
            target[key] = bad
            self.write()
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "content relation differs"):
                self.bind()
            target[key] = original

    def test_sdk_binding_rejects_bool_nan_negative_and_short_outer_cost(self):
        call = self.calls["after-generation"]
        for target, key, bad in [(call["command"], "wall_seconds", True),
                                 (call["command"], "wall_seconds", float("nan")),
                                 (call["command"], "wall_seconds", -1),
                                 (call, "full_call_wall_seconds_before_receipt", False),
                                 (call, "full_call_wall_seconds_before_receipt", float("nan")),
                                 (call, "full_call_wall_seconds_before_receipt", 3.9)]:
            original = target[key]
            target[key] = bad
            self.write()
            with self.subTest(key=key, value=bad), self.assertRaises(ValueError):
                self.bind()
            target[key] = original

    def test_sdk_binding_requires_candidate_flags_and_correct_boundaries(self):
        before = self.phases["before-compilation"]
        observation = before["observation"]
        for target, key, bad in [(before, "accepted", True), (before, "final_protocol_ready", True),
                                 (observation, "accepted", True), (observation, "final_protocol_ready", True),
                                 (observation, "status", "passed"), (observation, "boundary", "after-compilation")]:
            original = target[key]
            target[key] = bad
            self.write()
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "phase relation differs"):
                self.bind()
            target[key] = original

    def test_sdk_binding_final_guard_rejects_mutated_original_refs_and_source(self):
        self.bind()
        with mock.patch.object(inputs.generation, "verify", return_value={}):
            self.assertEqual(inputs.guard(self.plan)["status"], "passed")
            for path in [self.phase_path("before-compilation"), self.call_path("after-generation"),
                         self.repo / inputs.CALIBRATION_INPUT_HELPERS[-1]]:
                original = path.read_bytes()
                path.write_bytes(original + b" ")
                with self.subTest(path=path):
                    self.assertEqual(inputs.guard(self.plan)["status"], "failed")
                path.write_bytes(original)

    def test_sdk_binding_detects_phase_mutation_between_reference_and_read(self):
        original = inputs.document
        target = self.phase_path("after-generation")
        def change(ref):
            if ref["path"] == str(target):
                target.write_bytes(target.read_bytes() + b" ")
            return original(ref)
        with mock.patch.object(inputs, "document", side_effect=change):
            with self.assertRaisesRegex(ValueError, "Sealed input changed"):
                self.bind()


if __name__ == "__main__":
    unittest.main(verbosity=2)
