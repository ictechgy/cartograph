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


if __name__ == "__main__":
    unittest.main(verbosity=2)
