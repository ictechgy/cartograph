"""순서·미완료 중단·독립 정의/간선/질의 판정과 바깥 비용 경계를 검증한다."""

import copy
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import state_worker as worker

ORACLE_PATH = Path(__file__).with_name("test-fixtures") / "oracle.json"


class StateWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.oracle = json.loads(ORACLE_PATH.read_text())
        self.plan = dict(
            inputs=dict(oracle=worker.state_inputs.reference(ORACLE_PATH)),
            accepted=dict(sdk_content_identity=None),
            prior_costs={},
        )

    def complete_row(self, arm="baseline"):
        source = self.oracle["variants"]["initial"]
        ids = {node["key"]: node["id"] for node in source["nodes"]}
        graph = dict(
            symbols={v: v for v in ids.values()},
            edges=[[ids[e["caller"]], ids[e["callee"]]] for e in source["edges"]],
            unresolved=[],
        )
        observation = dict(
            arm=arm,
            operation="compiler-callers",
            complete=True,
            unresolved=[],
            queries=copy.deepcopy(source["queries"]),
        )
        return dict(
            arm=arm,
            status="passed",
            exit_code=0,
            may_continue=True,
            guard_after=dict(status="passed"),
            worker=dict(graph=graph, observation=observation),
        )

    def execute(self, run_arm):
        with mock.patch.object(worker, "guard", return_value=dict(status="passed")), mock.patch.object(
            worker, "run_arm", side_effect=run_arm
        ):
            return worker.execute(self.plan, self.root / "runtime.json", "a" * 64, self.root)

    def test_source_authored_control_scores_all_definitions_edges_and_queries(self):
        score = worker.evaluate(self.complete_row(), self.oracle)
        self.assertEqual(score["status"], "passed")
        self.assertTrue(score["definitions"]["exact"])
        self.assertTrue(score["edges"]["exact"])
        self.assertEqual(score["distinct_seed_count"], 10)

    def test_missing_header_edge_definition_or_extra_caller_never_disappears(self):
        for change in ["edge", "definition", "caller"]:
            row = self.complete_row()
            if change == "edge":
                row["worker"]["graph"]["edges"].pop()
            if change == "definition":
                row["worker"]["graph"]["symbols"].pop(next(iter(row["worker"]["graph"]["symbols"])))
            if change == "caller":
                row["worker"]["observation"]["queries"][0]["transitive"].append(
                    dict(id="Unrelated::source:1:1", minimum_depth=1)
                )
            self.assertEqual(worker.evaluate(row, self.oracle)["status"], "failed")

    def test_unresolved_or_failed_guard_is_not_fresh_accuracy(self):
        row = self.complete_row()
        row["guard_after"]["status"] = "failed"
        self.assertFalse(worker.evaluate(row, self.oracle)["scored"])
        row = self.complete_row()
        row["worker"]["graph"]["unresolved"] = ["ambiguous context"]
        self.assertEqual(worker.evaluate(row, self.oracle)["status"], "failed")

    def test_one_fixed_AB_pair_no_ratio_and_contiguous_phases(self):
        calls = []

        def arm(plan, name, *args):
            calls.append(name)
            return self.complete_row(name)

        result = self.execute(arm)
        self.assertEqual(calls, ["baseline", "cartograph"])
        self.assertEqual(result["status"], "passed")
        self.assertIsNone(result["performance_ratio"])
        self.assertIsNone(result["superiority_claim"])
        self.assertEqual(result["skipped_arms"], [])
        for previous, next_ in zip(result["phases"], result["phases"][1:]):
            self.assertEqual(previous["end_ns"], next_["start_ns"])

    def test_incomplete125_stops_second_arm_and_evaluation(self):
        calls = []

        def arm(plan, name, *args):
            calls.append(name)
            return dict(arm=name, status="incomplete", exit_code=125, may_continue=False)

        result = self.execute(arm)
        self.assertEqual(calls, ["baseline"])
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["skipped_arms"], ["cartograph"])
        self.assertEqual(result["evaluation"]["status"], "not-run")

    def test_failed_terminal_guard_stops_even_completed_nonzero(self):
        calls = []

        def arm(plan, name, *args):
            calls.append(name)
            return dict(arm=name, status="failed", exit_code=9, may_continue=False)

        result = self.execute(arm)
        self.assertEqual(calls, ["baseline"])
        self.assertEqual(result["exit_code"], 9)
        self.assertEqual(result["evaluation"]["status"], "not-run")

    def test_ordinary_failed_arm_with_completed_guards_can_retain_other_arm(self):
        def arm(plan, name, *args):
            row = self.complete_row(name)
            if name == "baseline":
                row.update(status="failed", exit_code=9)
            return row

        result = self.execute(arm)
        self.assertEqual(len(result["arms"]), 2)
        self.assertEqual(result["status"], "failed")
        self.assertFalse(result["evaluation"]["arms"]["baseline"]["scored"])
        self.assertEqual(result["evaluation"]["arms"]["cartograph"]["status"], "passed")

    def test_delayed_arm_receipt_cost_is_inside_state_phase(self):
        def arm(plan, name, *args):
            time.sleep(0.03)
            return self.complete_row(name)

        result = self.execute(arm)
        phases = {p["name"]: p for p in result["phases"]}
        for name in ["baseline", "cartograph"]:
            self.assertGreaterEqual(phases[name]["seconds"], 0.03)
        self.assertIn("outer whole-worker", result["cost_accounting"]["final_serialization_and_normal_teardown"])


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.plan = dict(
            calibration=worker.state_inputs.calibration_plan(), prior_costs={},
            inputs=dict(oracle=worker.state_inputs.reference(ORACLE_PATH)),
        )

    def row(self, item, ratio=1.0):
        return dict(
            invocation=item, arm=item["engine"], status="passed", exit_code=0, may_continue=True,
            guard_after=dict(status="passed"), evaluation=dict(status="passed"),
            worker=dict(arm=item["engine"], graph=dict(symbols=["first", "second"], edges=[["first", "second"]]),
                        observation=dict(queries=["first", "first", "second"], limitations=[], count=1)),
            observer=dict(mode=item["observer"], measurement=dict(
                measurement_mode=item["observer"], wall_seconds=ratio if item["side"] == "B" else 1.0)),
        )

    def rows(self, ratio=1.0):
        return [self.row(item, ratio) for item in self.plan["calibration"]["invocations"]]

    def execute(self, operation=None, clock=None):
        def arm(plan, engine, folder, *args, observer_mode, private_key):
            item = self.plan["calibration"]["invocations"][int(private_key[-2:]) - 1]
            self.assertEqual((engine, observer_mode, folder.name),
                             (item["engine"], item["observer"], item["folder"]))
            folder.mkdir(parents=True)
            result = operation(item) if operation else self.row(item)
            worker.save(folder / "arm-result.json", {key: value for key, value in result.items()
                                                     if key not in ("invocation", "evaluation")})
            return result

        with mock.patch.object(worker, "guard", return_value=dict(status="passed")), mock.patch.object(
            worker, "run_arm", side_effect=arm
        ) as launch, mock.patch.object(worker, "evaluate", return_value=dict(status="passed")), mock.patch.object(
            worker.time, "perf_counter", side_effect=clock or (lambda: 10.0)
        ):
            result = worker.execute(self.plan, self.root / "runtime.json", "a" * 64, self.root)
        return result, launch

    def test_exact_schedule_has_32_fresh_invocations_and_balanced_orders(self):
        items = self.plan["calibration"]["invocations"]
        self.assertEqual([item["number"] for item in items], list(range(1, 33)))
        self.assertEqual(len({item["folder"] for item in items}), 32)
        for engine in ("baseline", "cartograph"):
            for mode in ("timing", "memory"):
                pairs = [item for item in items if item["engine"] == engine and
                         item["mode"] == mode and item["side"] == "A"]
                self.assertEqual(sorted(item["order"] for item in pairs), ["AB", "AB", "BA", "BA"])

    def test_timing_screen_checks_median_and_every_ratio_with_exact_boundary(self):
        rows = self.rows(1.05)
        groups = worker.state_inputs.calibration_groups(rows)
        self.assertTrue(all(row["timing_eligible"] for row in groups if row["mode"] == "timing"))
        changed = next(row for row in rows if row["invocation"]["mode"] == "timing" and
                       row["invocation"]["side"] == "B")
        changed["observer"]["measurement"]["wall_seconds"] = 1.100001
        self.assertFalse(worker.state_inputs.calibration_groups(rows)[0]["timing_eligible"])
        self.assertFalse(worker.state_inputs.calibration_groups(self.rows(1.050001))[0]["timing_eligible"])

    def test_memory_is_descriptive_and_cannot_become_primary_timing(self):
        rows = self.rows()
        for row in rows:
            if row["invocation"]["mode"] == "memory" and row["invocation"]["side"] == "B":
                row["observer"]["measurement"]["wall_seconds"] = 3.0
        groups = worker.state_inputs.calibration_groups(rows)
        self.assertTrue(all(row["timing_eligible"] for row in groups if row["mode"] == "timing"))
        self.assertTrue(all(row["timing_eligible"] is None and row["median_ratio"] == 3
                            for row in groups if row["mode"] == "memory"))

    def test_same_engine_output_order_multiplicity_and_limitations_remain_exact(self):
        for mutation in ("graph", "order", "duplicate", "limitations", "typed-bool", "typed-float"):
            rows = self.rows()
            value = rows[1]["worker"]
            if mutation == "graph": value["graph"]["edges"] = []
            elif mutation == "order": value["observation"]["queries"].reverse()
            elif mutation == "duplicate": value["observation"]["queries"].pop()
            elif mutation == "limitations": value["observation"]["limitations"].append("new limit")
            else: value["observation"]["count"] = True if mutation == "typed-bool" else 1.0
            with self.assertRaisesRegex(ValueError, "Same-engine", msg=mutation):
                worker.state_inputs.calibration_groups(rows)
        rows = self.rows()
        for row in rows:
            if row["invocation"]["engine"] == "baseline" and row["invocation"]["mode"] == "memory":
                row["worker"]["observation"]["limitations"].append("mode-dependent fact")
        with self.assertRaisesRegex(ValueError, "Same-engine"):
            worker.state_inputs.calibration_groups(rows)

    def test_missing_duplicate_reordered_or_untyped_walls_refuse(self):
        for mutation in ("missing", "duplicate", "reordered", "bool", "nan", "zero"):
            rows = self.rows()
            if mutation == "missing": rows.pop()
            elif mutation == "duplicate": rows[-1] = rows[0]
            elif mutation == "reordered": rows[0], rows[1] = rows[1], rows[0]
            else: rows[0]["observer"]["measurement"]["wall_seconds"] = {
                "bool": True, "nan": float("nan"), "zero": 0,
            }[mutation]
            with self.assertRaises(ValueError, msg=mutation):
                worker.state_inputs.calibration_groups(rows)

    def test_wrong_engine_or_observer_binding_and_overflow_ratio_refuse(self):
        for mutation in ("arm", "worker", "observer", "measurement", "overflow"):
            rows = self.rows()
            if mutation == "arm": rows[0]["arm"] = "cartograph"
            elif mutation == "worker": rows[0]["worker"]["arm"] = "cartograph"
            elif mutation == "observer": rows[0]["observer"]["mode"] = "timing"
            elif mutation == "measurement": rows[0]["observer"]["measurement"]["measurement_mode"] = "timing"
            else:
                rows[0]["observer"]["measurement"]["wall_seconds"] = 1e-300
                rows[1]["observer"]["measurement"]["wall_seconds"] = 1e300
            with self.assertRaises(ValueError, msg=mutation):
                worker.state_inputs.calibration_groups(rows)

    def test_full_schedule_uses_actual_arm_and_evaluator_for_all_32(self):
        result, calls = self.execute()
        self.assertEqual(result["status"], "passed")
        self.assertEqual(calls.call_count, 32)
        self.assertEqual(result["skipped_invocations"], [])
        self.assertFalse(result["final_evidence"])
        self.assertTrue((self.root / "setup/calibration-plan.json").is_file())

    def test_first_nonzero_stops_schedule_and_keeps_failed_invocation(self):
        def failed(item):
            row = self.row(item)
            row.update(status="failed", exit_code=9)
            return row
        result, calls = self.execute(failed)
        self.assertEqual((result["exit_code"], calls.call_count, result["first_failure"]), (9, 1, 1))
        self.assertEqual(result["skipped_invocations"], list(range(2, 33)))

    def test_first_full_document_difference_stops_even_when_oracle_passes(self):
        def changed(item):
            row = self.row(item)
            if item["number"] == 2:
                row["worker"]["observation"]["limitations"].append("new limit")
            return row
        result, calls = self.execute(changed)
        self.assertEqual((result["exit_code"], calls.call_count, result["first_failure"]), (1, 2, 2))
        self.assertEqual(result["skipped_invocations"], list(range(3, 33)))

    def test_changed_plan_and_insufficient_full_child_budget_prevent_launch(self):
        self.plan["calibration"]["engine_invocation_count"] = 31
        result, calls = self.execute()
        self.assertEqual(calls.call_count, 0)
        self.assertNotEqual(result["exit_code"], 0)
        first_path = self.root / "results.json"
        first_bytes = first_path.read_bytes()
        self.root = self.root / "insufficient-budget"
        self.root.mkdir()
        self.plan["calibration"] = worker.state_inputs.calibration_plan()
        values = iter([0.0, 0.0, 661.0])
        result, calls = self.execute(clock=lambda: next(values, 661.0))
        self.assertEqual(first_path.read_bytes(), first_bytes)
        self.assertEqual(calls.call_count, 0)
        self.assertNotEqual(result["exit_code"], 0)

    def test_deadline_after_final_guard_never_publishes_pass(self):
        current = [0.0]
        original = worker.state_inputs.calibration_groups
        def final_groups(rows):
            value = original(rows)
            current[0] = 901.0
            return value
        with mock.patch.object(worker.state_inputs, "calibration_groups", side_effect=final_groups):
            result, calls = self.execute(clock=lambda: current[0])
        self.assertEqual(calls.call_count, 32)
        self.assertNotEqual(result["exit_code"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
