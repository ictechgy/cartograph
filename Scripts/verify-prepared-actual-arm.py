#!/usr/bin/env python3
"""Prepared tools must satisfy the unchanged actual-arm gates without inventing a local build."""
import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parent / "benchmark-actual-arm"
sys.path.insert(0, str(ROOT))
import state_inputs as inputs
import test_state_inputs as fixture_inputs


class PreparedActualArmTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture_inputs.InputTests(methodName="test_exact_state_yields_gold_free_engine_configuration")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        # Windows에서는 생성한 regular fixture 읽기만 모의한다. POSIX no-follow 검증을 대체하지 않는다.
        if os.name == "nt":
            def read(path):
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_size > inputs.bootstrap.LIMIT:
                    raise ValueError("Invalid test receipt")
                return path.read_bytes()
            replacement = patch.object(inputs.bootstrap, "read_regular", side_effect=read)
            replacement.start()
            self.addCleanup(replacement.stop)
        # Git autocrlf는 임시 fixture만 LF로 복원한다. 고정 hash/실제 CI 검사는 바꾸지 않는다.
        for name, expected in (("adapter/query-spec.json", inputs.QUERY_SHA256), ("oracle.json", inputs.ORACLE_SHA256)):
            path = self.fixture.repo / inputs.FIXTURE / name
            data = path.read_bytes().replace(b"\r\n", b"\n")
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected)
            path.write_bytes(data)
        self.original = copy.deepcopy(self.fixture.tool_data)
        self.admission_path = self.fixture.tools / "admission.json"
        self.scripts = self.fixture.repo / "Scripts"
        self.scripts.mkdir()
        (self.scripts / "prepared-comparison-tools.py").write_text("# retained helper source\n")
        (self.scripts / "benchmark-indexstore-cli.py").write_text("# retained benchmark source\n")
        self.binding = {"run": "123", "attempt": "1", "checkout_commit": "a" * 40, "checkout_tree": "b" * 40,
                        "pr_head": "c" * 40, "pr_base": "d" * 40}
        selected = self.fixture.data["setup"]
        self.paths = {"swiftc": selected["swiftc"], "clang": selected["clang"], "libIndexStore": selected["library"]}
        self.identity = {"swift_version": "fixture Swift", "tools_sha256": {
            key: hashlib.sha256(Path(path).read_bytes()).hexdigest() for key, path in self.paths.items()}}
        self.value = {"binding": self.binding, "tools": {}, "toolchain": {"identity": self.identity, "paths": self.paths},
                      "consumer": {"runner": "consumer-host", "admission_seconds": 3.5}}
        for role in ("candidate", "comparator", "baseline"):
            folder = self.fixture.tools / role
            folder.mkdir()
            manifest = folder / "manifest.json"
            manifest.write_text(json.dumps({"role": role, "producer": "separate host"}))
            source = folder / "source"
            source.mkdir()
            self.value["tools"][role] = {"manifest": str(manifest), "manifest_sha256": inputs.generation.digest(manifest),
                "consumer_source": str(source), "producer": {"runner": "producer-" + role, "preparation_seconds": 12.5}}
        self.admission_path.write_text(json.dumps(self.value))
        self.products = {}
        for role, original in (("candidate", self.original["cartograph"]), ("comparator", self.original["comparator_setup"])):
            item = self.value["tools"][role]
            self.products[role] = {"binary": str(self.fixture.binary), "binary_sha256": self.fixture.digest,
                "version": "fixture", "setup": {"mode": "verified-prepared-artifact",
                    "build_cost_measured": "producer-only", "source": {"revision": "a" * 40, "symlinks": {}},
                    "consumer_source": item["consumer_source"], "producer_evidence": copy.deepcopy(original),
                    "producer": item["producer"], "admission": item, "toolchain_identity": self.identity}}
        native = copy.deepcopy(self.products["candidate"])
        native["setup"]["admission_path"] = str(self.admission_path)
        cli_setup = self.products["comparator"]["setup"]
        comparator = dict(
            mode="verified-prepared-artifact", repository=self.original["comparator_setup"]["repository"],
            revision=self.original["comparator_setup"]["revision"],
            binary=str(self.fixture.binary), binary_sha256=self.fixture.digest,
            checkout=cli_setup["consumer_source"], source=cli_setup["source"],
            build_evidence=cli_setup["producer_evidence"], commands=cli_setup["producer_evidence"]["commands"],
            producer=cli_setup["producer"], admission=cli_setup["admission"],
            admission_path=str(self.admission_path), toolchain_identity=self.identity,
        )
        self.fixture.tool_data = dict(
            status="passed", correctness_and_freshness_passed=True, cartograph=native, comparator_setup=comparator,
            toolchain_identity=self.identity,
            toolchain=dict(version="fixture Swift", swiftc=selected["swiftc"], library=selected["library"],
                           library_sha256=self.identity["tools_sha256"]["libIndexStore"]),
        )
        self.helper = types.SimpleNamespace(
            read_admission=Mock(side_effect=lambda path, **kwargs: copy.deepcopy(self.value)),
            prepared_product=Mock(side_effect=lambda value, role: copy.deepcopy(self.products[role])))
        self.fixture.write()

    def prepare(self):
        with patch.object(inputs, "prepared_module", return_value=self.helper):
            return self.fixture.prepare()

    def guard(self, plan):
        with patch.object(inputs, "prepared_module", return_value=self.helper), patch.object(
                inputs.generation, "verify", return_value={"generation": "checked"}):
            return inputs.guard(plan)

    def test_nested_producer_receipts_pass_without_fabricated_local_build(self):
        self.assertNotIn("build", self.fixture.tool_data["cartograph"]["setup"])
        self.assertNotIn("help", self.fixture.tool_data["comparator_setup"])
        before = copy.deepcopy(self.fixture.tool_data)
        plan = self.prepare()
        self.assertEqual(self.fixture.tool_data, before)
        self.assertEqual(plan["state_id"], "restored_rebuilt")
        self.assertEqual(plan["prepared_tools"]["binding"], self.binding)
        self.helper.read_admission.assert_called_once_with(self.admission_path, retained_binding=self.binding)
        self.assertEqual(len([name for name in plan["inputs"] if name.startswith("prepared:")]), 6)
        self.assertIn("no local build", plan["prior_costs"]["prepared_tools"]["scope"])
        self.assertIn(self.value["tools"]["comparator"]["consumer_source"], plan["input_roots"])

    def test_legacy_setup_does_not_load_prepared_helpers(self):
        self.fixture.tool_data = self.original
        self.fixture.write()
        with patch.object(inputs, "prepared_module", side_effect=AssertionError("Unexpected prepared path")):
            plan = self.fixture.prepare()
        self.assertNotIn("prepared_tools", plan)
        self.assertEqual(len(plan["inputs"]), 7)

    def test_thirteen_states_and_real_comparison_still_required(self):
        original = copy.deepcopy(self.fixture.tool_data)
        for change in (lambda: self.fixture.tool_data.update(status="admitted-preparation-only"),
                       lambda: self.fixture.tool_data.update(correctness_and_freshness_passed=False),
                       lambda: self.fixture.data["states"].pop(0)):
            self.fixture.tool_data = copy.deepcopy(original)
            change()
            self.fixture.write()
            with self.assertRaises(ValueError):
                self.prepare()

    def test_mode_label_without_matching_manifest_receipts_is_rejected(self):
        self.fixture.tool_data["cartograph"]["setup"]["producer_evidence"]["setup"]["build"]["wall_seconds"] = 0
        self.fixture.write()
        with self.assertRaisesRegex(ValueError, "native result differs"):
            self.prepare()

    def test_failed_original_build_help_or_unknown_inputs_are_not_accepted(self):
        for field in ("commands", "help", "untracked_build_inputs"):
            original = copy.deepcopy(self.products["comparator"]["setup"]["producer_evidence"])
            failed = copy.deepcopy(original)
            if field == "commands":
                failed[field][0]["returncode"] = 1
            elif field == "help":
                failed[field]["timed_out"] = True
            else:
                failed[field]["passed"] = False
            self.products["comparator"]["setup"]["producer_evidence"] = failed
            self.fixture.tool_data["comparator_setup"]["build_evidence"] = failed
            self.fixture.tool_data["comparator_setup"]["commands"] = failed["commands"]
            self.fixture.write()
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Original producer"):
                self.prepare()
            self.products["comparator"]["setup"]["producer_evidence"] = original

    def test_different_consumer_source_or_compiler_is_rejected(self):
        self.fixture.tool_data["comparator_setup"]["checkout"] = str(self.fixture.repo)
        self.fixture.write()
        with self.assertRaisesRegex(ValueError, "comparator result differs"):
            self.prepare()
        self.fixture.tool_data["comparator_setup"]["checkout"] = self.products["comparator"]["setup"]["consumer_source"]
        self.fixture.tool_data["toolchain"]["version"] = "changed compiler"
        self.fixture.write()
        with self.assertRaisesRegex(ValueError, "toolchain differs"):
            self.prepare()

    def test_manifest_change_is_rejected_before_loading_helper(self):
        Path(self.value["tools"]["candidate"]["manifest"]).write_text("{}")
        with patch.object(inputs, "prepared_module") as loader, self.assertRaisesRegex(ValueError, "manifest changed"):
            self.fixture.prepare()
        loader.assert_not_called()

    def test_guard_revalidates_source_runtime_and_retained_binding(self):
        plan = self.prepare()
        self.helper.read_admission.reset_mock()
        self.assertEqual(self.guard(plan)["status"], "passed")
        self.helper.read_admission.assert_called_once_with(self.admission_path, retained_binding=self.binding)
        self.helper.read_admission.side_effect = ValueError("Runtime library or source link changed")
        self.assertEqual(self.guard(plan)["status"], "failed")

    def test_guard_detects_admission_manifest_and_helper_bytes(self):
        plan = self.prepare()
        for key in ("prepared:admission", "prepared:manifest:baseline", "prepared:helper", "prepared:benchmark"):
            path = Path(plan["inputs"][key]["path"])
            original = path.read_bytes()
            path.write_bytes(original + b" ")
            with self.subTest(key=key):
                self.assertEqual(self.guard(plan)["status"], "failed")
            path.write_bytes(original)

    def test_helper_changes_during_revalidation_fail_terminal_guard(self):
        plan = self.prepare()
        def mutate(*args, **kwargs):
            Path(plan["inputs"]["prepared:helper"]["path"]).write_text("# changed during verification\n")
            return copy.deepcopy(self.value)
        self.helper.read_admission.side_effect = mutate
        self.assertEqual(self.guard(plan)["status"], "failed")

    def test_sealed_helper_loader_executes_exact_source_and_binds_benchmark(self):
        helper = self.scripts / "prepared-comparison-tools.py"
        benchmark = self.scripts / "benchmark-indexstore-cli.py"
        helper.write_text("_BASE = None\nmarker = 'helper'\n")
        benchmark.write_text("marker = 'benchmark'\n")
        refs = {"prepared:helper": inputs.reference(helper), "prepared:benchmark": inputs.reference(benchmark)}
        module = inputs.prepared_module(refs)
        self.assertEqual((module.marker, module._BASE.marker), ("helper", "benchmark"))
        benchmark.write_text("raise AssertionError('changed source executed')\n")
        with self.assertRaisesRegex(ValueError, "Sealed input changed"):
            inputs.prepared_module(refs)


if __name__ == "__main__":
    unittest.main()
