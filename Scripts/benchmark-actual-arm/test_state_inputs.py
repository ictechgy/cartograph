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


if __name__ == "__main__":
    unittest.main(verbosity=2)
