"""계약 실행은 정확한 수·모듈·종료를 요구하며 건너뜀을 통과로 바꾸지 않는다."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import types
from unittest import mock
import contract_suite as suite
import contract_prerequisites as contracts


class ContractPrerequisiteTests(unittest.TestCase):
    def run_case(self, body, count=1, duplicate=False):
        class Synthetic(unittest.TestCase):
            def test_control(self):
                body(self)

        case = Synthetic("test_control")
        batch = unittest.TestSuite([case, case] if duplicate else [case])
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stderr(io.StringIO()):
            return suite.execute_suite(batch, count, Path(folder) / "result.json", "synthetic")

    def test_exact_complete_suite_passes(self):
        row = self.run_case(lambda test: test.assertTrue(True))
        self.assertEqual(row["exit_code"], 0)
        self.assertEqual(row["tests_run"], 1)

    def test_skip_is_not_success(self):
        row = self.run_case(lambda test: test.skipTest("synthetic skip"))
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(len(row["skipped"]), 1)

    def test_missing_count_is_not_success(self):
        self.assertEqual(self.run_case(lambda test: None, count=2)["exit_code"], 1)

    def test_duplicate_test_identity_is_not_success(self):
        self.assertEqual(self.run_case(lambda test: None, count=2, duplicate=True)["exit_code"], 1)

    def test_missing_import_is_recorded_as_error(self):
        def missing(test):
            raise ModuleNotFoundError("synthetic missing dependency")

        row = self.run_case(missing)
        self.assertEqual(row["exit_code"], 1)
        self.assertEqual(len(row["errors"]), 1)

    def test_bool_count_is_rejected(self):
        self.assertEqual(self.run_case(lambda test: None, count=True)["exit_code"], 1)

    def valid_summary(self):
        modules, count = suite.SUITES["runtime"]
        ids = [modules[i % len(modules)] + ".Case.test_" + str(i) for i in range(count)]
        return dict(
            schema_version=1,
            role="bound-contract-suite",
            suite="runtime",
            status="passed",
            exit_code=0,
            expected_tests=count,
            discovered_tests=count,
            tests_run=count,
            test_ids=ids,
            failures=[],
            errors=[],
            skipped=[],
            expected_failures=[],
            unexpected_successes=[],
            final_evidence=False,
        )

    def test_complete_summary_is_validated(self):
        contracts.validate_suite(self.valid_summary(), "runtime")

    def test_boolean_exit_or_missing_module_cannot_pass(self):
        row = self.valid_summary()
        row["exit_code"] = False
        with self.assertRaises(ValueError):
            contracts.validate_suite(row, "runtime")
        row = self.valid_summary()
        row["test_ids"] = ["unaccepted.Case.test_" + str(i) for i in range(row["tests_run"])]
        with self.assertRaises(ValueError):
            contracts.validate_suite(row, "runtime")

    def test_changed_skip_cannot_pass(self):
        row = self.valid_summary()
        row["skipped"] = [row["test_ids"][0]]
        with self.assertRaises(ValueError):
            contracts.validate_suite(row, "runtime")

    def test_explicit_sources_include_every_suite_but_not_gold(self):
        paths = contracts.source_paths(["state_worker.py"])
        self.assertIn("test_state_worker.py", paths)
        self.assertIn("runtime/test_runtime_bootstrap.py", paths)
        self.assertNotIn("test-fixtures/oracle.json", paths)
        self.assertEqual(len(paths), len(set(paths)))

    def run_prerequisites(self, root, mode="passed"):
        import correctness_controller as controller

        sources = controller.SOURCE_FILES
        calls = []

        def command(argv, cwd, stem, env, timeout):
            calls.append(argv)
            label = argv[argv.index("--suite") + 1]
            phase = dict(
                command=argv,
                completed=mode != "incomplete",
                passed=mode == "passed",
                returncode=125 if mode == "incomplete" else 9 if mode == "failed" else 0,
                observed_returncode=125 if mode == "incomplete" else 9 if mode == "failed" else 0,
                failure="nested-incomplete" if mode == "incomplete" else None,
                cleanup_root_unfinished=False,
                cleanup_signals=[],
                wall_seconds=0.01,
            )
            controller.save(Path(str(stem) + ".json"), phase)
            if mode != "incomplete":
                modules, count = suite.SUITES[label]
                summary = self.valid_summary()
                summary.update(
                    suite=label,
                    expected_tests=count,
                    discovered_tests=count,
                    tests_run=count,
                    test_ids=[modules[i % len(modules)] + ".Case.test_" + str(i) for i in range(count)],
                )
                if mode == "failed":
                    summary.update(status="failed", exit_code=1, failures=[summary["test_ids"][0]])
                controller.save(Path(argv[-1]), summary)
                controller.save(stem.parent / "runtime-result.json", {"status": "passed"})
            return phase

        (root / "setup").mkdir()
        runner = types.SimpleNamespace(command=command)
        result = contracts.run(dict(package={}, python={}), root, sources, runner, controller.save)
        return result, calls

    def test_completed_failed_suite_stops_second_suite_and_retains_return(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(
            contracts.isolated_measure, "verify_runtime_receipt", return_value={"status": "failed"}
        ):
            result, calls = self.run_prerequisites(Path(d), "failed")
        self.assertEqual(result["exit_code"], 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["suites"][0]["process"]["returncode"], 9)

    def test_incomplete125_stops_before_runtime_verification_or_second_suite(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(
            contracts.isolated_measure, "verify_runtime_receipt"
        ) as verify:
            result, calls = self.run_prerequisites(Path(d), "incomplete")
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(len(calls), 1)
        verify.assert_not_called()

    def test_missing_runtime_receipt_preserves_phase_and_blocks_next_suite(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(
            contracts.isolated_measure, "verify_runtime_receipt", side_effect=ValueError("missing runtime")
        ):
            result, calls = self.run_prerequisites(Path(d))
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["suites"][0]["process"]["returncode"], 0)
        self.assertEqual(len(calls), 1)

    def test_success_requires_both_actual_phase_summary_runtime_files(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(
            contracts.isolated_measure, "verify_runtime_receipt", return_value={"status": "passed"}
        ):
            root = Path(d)
            result, calls = self.run_prerequisites(root)
            refs = contracts.verify(root / "setup/contracts", result)
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(refs), 8)
        for argv in calls:
            self.assertEqual(argv[1:4], ["-I", "-S", "-B"])

    def test_changed_actual_phase_cannot_reuse_embedded_success(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(
            contracts.isolated_measure, "verify_runtime_receipt", return_value={"status": "passed"}
        ):
            root = Path(d)
            result, _ = self.run_prerequisites(root)
            path = root / "setup/contracts/runtime/process.json"
            phase = json.loads(path.read_text())
            phase["returncode"] = False
            path.write_text(json.dumps(phase))
            with self.assertRaises(ValueError):
                contracts.verify(root / "setup/contracts", result)

    def test_missing_second_summary_cannot_reuse_embedded_success(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(
            contracts.isolated_measure, "verify_runtime_receipt", return_value={"status": "passed"}
        ):
            root = Path(d)
            result, _ = self.run_prerequisites(root)
            (root / "setup/contracts/runtime/summary.json").unlink()
            with self.assertRaises(OSError):
                contracts.verify(root / "setup/contracts", result)

    def test_contract_runtime_must_match_actual_engine_installation(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(
            contracts.isolated_measure, "verify_runtime_receipt", return_value={"status": "passed"}
        ):
            root = Path(d)
            result, _ = self.run_prerequisites(root)
            runtime = json.loads((root / "setup/contracts/runtime.json").read_text())
            contracts.verify(root / "setup/contracts", result, runtime)
            runtime["package"] = {"target": "different-private-package"}
            with self.assertRaises(ValueError):
                contracts.verify(root / "setup/contracts", result, runtime)


if __name__ == "__main__":
    unittest.main(verbosity=2)
