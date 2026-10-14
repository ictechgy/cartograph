#!/usr/bin/env python3
"""복구된 한 상태에서 격리한 A·B 실행과 독립 정답 검증을 한 번만 수행한다."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "runtime"))
sys.path.insert(0, str(ROOT / "primitive"))
sys.path.insert(0, str(ROOT / "primitive/vendor/mixed"))
import runtime_bootstrap as bootstrap
import runtime_identity as identity
import isolated_measure
import score_calls
import state_inputs


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write("\n")


guard = state_inputs.guard


def run_arm(plan, arm, output, runtime_path, runtime_sha256, *, observer_mode="timing", private_key=None):
    """측정 감독기와 실제 엔진 양쪽 모두 검증한 격리 진입점으로만 실행한다."""
    started = time.perf_counter()
    config = dict(plan["engine_config"], arm=arm, output=str(output))
    state_inputs.disjoint(output, plan["input_roots"])
    output.mkdir(parents=True)
    row = dict(
        arm=arm,
        status="failed",
        exit_code=1,
        may_continue=False,
        final_evidence=False,
        guard_before=guard(plan),
        guard_after=dict(status="not-run", reason="prelaunch-guard-not-passed"),
    )
    try:
        if row["guard_before"]["status"] != "passed":
            if row["guard_before"]["status"] == "incomplete":
                row.update(status="incomplete", exit_code=125)
        else:
            runtime_data = bootstrap.read_regular(Path(runtime_path))
            state_inputs.require(hashlib.sha256(runtime_data).hexdigest() == runtime_sha256,
                                 "Runtime configuration changed before arm launch")
            runtime = bootstrap.strict_json(runtime_data)
            save(output / "input.json", config)
            config_ref = state_inputs.reference(output / "input.json")
            developer = Path(config["developer_directory"])
            private = Path(plan["raw_output"]) / "private-readers" / (private_key or arm)
            environment = identity.private_environment(private / "engine", developer)
            command = isolated_measure.bootstrap_command(
                runtime_path,
                runtime_sha256,
                ROOT / "engine_worker.py",
                output / "engine-runtime/runtime-result.json",
                ["--input", config_ref["path"], "--sha256", config_ref["sha256"]],
                runtime=runtime,
            )
            if observer_mode == "direct":
                measurement = isolated_measure.run_direct(
                    command, Path(config["project"]), output / "whole-arm", runtime_path,
                    runtime_sha256, environment, timeout=240,
                )
            else:
                state_inputs.require(observer_mode in ("timing", "memory"), "Unknown observer mode")
                observer_environment = identity.private_environment(private / "observer", developer)
                options = {} if observer_mode == "timing" else {"mode": "memory"}
                measurement = isolated_measure.run(
                    command, Path(config["project"]), output / "whole-arm", runtime_path,
                    runtime_sha256, environment, observer_environment, timeout=240, **options,
                )
            row["observer"] = measurement
            incomplete = measurement["status"] == "incomplete" or measurement["exit_code"] == 125
            if incomplete:
                row.update(
                    status="incomplete",
                    exit_code=125,
                    guard_after=dict(status="unavailable", reason="incomplete-process-cleanup-unverified"),
                )
            else:
                row["guard_after"] = guard(plan)
                worker_path = output / "worker-result.json"
                row["worker"] = (
                    state_inputs.document(state_inputs.reference(worker_path))
                    if worker_path.is_file()
                    else dict(status="missing", failure="Engine result unavailable after completed process")
                )
                row["may_continue"] = row["guard_after"]["status"] == "passed"
                if row["guard_after"]["status"] == "incomplete":
                    row.update(status="incomplete", exit_code=125)
                elif measurement["status"] == "passed" and row["worker"]["status"] == "ok" and row["may_continue"]:
                    row.update(status="passed", exit_code=0)
                else:
                    row["exit_code"] = measurement["exit_code"] or 1
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, KeyboardInterrupt) as error:
        row.update(
            status="incomplete",
            exit_code=125,
            may_continue=False,
            failure=type(error).__name__,
        )
        if row["guard_after"]["status"] == "not-run":
            row["guard_after"] = dict(status="unavailable", reason="orchestration-incomplete")
    row["wall_seconds_before_receipt"] = time.perf_counter() - started
    row["cost_scope"] = "Arm writes and normal teardown are included by the enclosing state interval/outer process"
    save(output / "arm-result.json", row)
    return row


def evaluate(row, oracle):
    """컴파일러 관측을 바꾸지 않고 정의·간선·열 질의를 원래 소스 정답과 비교한다."""
    if row["status"] != "passed" or row["guard_after"]["status"] != "passed":
        return dict(status="failed", scored=False, reason="Arm did not complete with accepted terminal inputs")
    worker = row["worker"]
    graph, observation = worker["graph"], worker["observation"]
    source = oracle["variants"]["initial"]
    identifiers = {node["key"]: node["id"] for node in source["nodes"]}
    expected_edges = {(identifiers[e["caller"]], identifiers[e["callee"]]) for e in source["edges"]}
    expected_definitions = set(identifiers.values())
    actual_definitions = set(graph["symbols"].values())
    actual_edges = {tuple(edge) for edge in graph["edges"]}
    definitions = score_calls.exact(actual_definitions, expected_definitions)
    edges = score_calls.exact(actual_edges, expected_edges)
    # baseline primitive는 API 능력과 최신성 메타데이터를 주장하지 않는다.
    # 이 두 필드는 실제 완료된 배치와 양쪽 시점의 승인 세대 검사 뒤에만 부여한다.
    comparable = dict(observation, capability="supported", fresh=True)
    queries = score_calls.grade(comparable, oracle, "initial")
    seeds = [q["seed"] for q in comparable["queries"]]
    valid = (
        definitions["exact"]
        and edges["exact"]
        and not graph["unresolved"]
        and queries["status"] == "passed"
        and len(seeds) == len(set(seeds)) == 10
    )
    return dict(
        status="passed" if valid else "failed",
        scored=True,
        definitions=definitions,
        edges=edges,
        queries=queries,
        unresolved=graph["unresolved"],
        distinct_seed_count=len(set(seeds)),
        freshness_basis="Required prelaunch and completed terminal accepted-generation guards",
    )


def execute(plan, runtime_path, runtime_sha256, output):
    if "calibration" in plan:
        return execute_calibration(plan, runtime_path, runtime_sha256, output)
    started = time.perf_counter_ns()
    result = dict(
        schema_version=1,
        role="single-restored-state-correctness-validation",
        status="failed",
        exit_code=1,
        final_evidence=False,
        order="AB",
        arms=[],
        phases=[],
        evaluation=dict(status="not-run"),
        sdk_content_identity=plan["accepted"]["sdk_content_identity"],
        performance_ratio=None,
        superiority_claim=None,
    )
    previous = started

    def phase(name):
        nonlocal previous
        now = time.perf_counter_ns()
        result["phases"].append(dict(name=name, start_ns=previous, end_ns=now, seconds=(now - previous) / 1e9))
        previous = now

    try:
        initial = guard(plan)
        result["initial_guard"] = initial
        phase("state-setup")
        if initial["status"] != "passed":
            result["exit_code"] = 125 if initial["status"] == "incomplete" else 1
        else:
            for arm in ("baseline", "cartograph"):
                row = run_arm(plan, arm, output / "runs/restored_rebuilt" / arm, runtime_path, runtime_sha256)
                result["arms"].append(row)
                phase(arm)
                if not row["may_continue"] or row["exit_code"] == 125:
                    result.update(
                        status="incomplete" if row["exit_code"] == 125 else "failed", exit_code=row["exit_code"]
                    )
                    break
            else:
                # 정답은 두 팔 실행이 모두 정상적으로 끝나고 각 종료 검사까지 통과한 뒤에만 해석한다.
                oracle = state_inputs.document(plan["inputs"]["oracle"])
                scores = {row["arm"]: evaluate(row, oracle) for row in result["arms"]}
                result["evaluation"] = dict(
                    status="passed" if all(v["status"] == "passed" for v in scores.values()) else "failed", arms=scores
                )
                phase("independent-evaluation")
                if result["evaluation"]["status"] == "passed":
                    result.update(status="passed", exit_code=0)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, KeyboardInterrupt) as error:
        result.update(status="incomplete", exit_code=125, failure=type(error).__name__)
    result["skipped_arms"] = [
        arm for arm in ("baseline", "cartograph") if arm not in {r["arm"] for r in result["arms"]}
    ]
    result["cost_accounting"] = dict(
        measured_nonoverlapping_intervals=True,
        final_serialization_and_normal_teardown="Closed by outer whole-worker child wall, not an assumed zero",
        nested_observer_engine_cli="Explanatory only; never added again to enclosing physical intervals",
        prior_costs=plan["prior_costs"],
    )
    phase("state-finalization-or-failed-work")
    save(output / "results.json", result)
    return result



def execute_calibration(plan, runtime_path, runtime_sha256, output):
    """승인된 고정 32개 실제 엔진 호출을 한 번만 관찰하고 최초 실패에서 멈춘다."""
    started = time.perf_counter()
    deadline = started + 900
    result = dict(
        schema_version=1, role="actual-engine-observer-calibration", status="failed", exit_code=1,
        final_evidence=False, plan=state_inputs.calibration_plan(), invocations=[], groups=[],
        superiority_claim=None, phases=[],
        limitations=[
            "Four-pair timing screen is empirical validation, not population confidence.",
            "Memory sampling can miss short-lived/reparented macOS descendants; continuous peak is unproved.",
            "OS caches, host scheduling and dynamic-loader closure remain uncontrolled.",
        ],
    )
    previous = started
    completed_rows, output_references = [], {}

    def phase(name):
        nonlocal previous
        now = time.perf_counter()
        result["phases"].append(dict(name=name, start=previous, end=now, seconds=now - previous))
        previous = now

    try:
        state_inputs.require(plan["calibration"] == result["plan"], "Calibration plan changed")
        save(output / "setup/calibration-plan.json", result["plan"])
        result["initial_guard"] = guard(plan)
        state_inputs.require(result["initial_guard"]["status"] == "passed", "Calibration initial guard failed")
        oracle = state_inputs.document(plan["inputs"]["oracle"])
        phase("calibration-admission")
        for item in result["plan"]["invocations"]:
            state_inputs.require(deadline - time.perf_counter() >= 240, "Calibration full child budget unavailable")
            folder = output / "runs/calibration" / item["folder"]
            save(output / "setup/calibration-started" / (item["folder"] + ".json"), item)
            row = run_arm(
                plan, item["engine"], folder, runtime_path, runtime_sha256,
                observer_mode=item["observer"], private_key=item["folder"],
            )
            row["invocation"] = item
            row["evaluation"] = evaluate(row, oracle)
            completed_rows.append(row)
            save(folder / "calibration-result.json", dict(
                invocation=item, evaluation=row["evaluation"],
                arm_result=state_inputs.reference(folder / "arm-result.json"),
            ))
            result["invocations"].append(dict(
                invocation=item, result=state_inputs.reference(folder / "calibration-result.json"),
                status=row["status"], exit_code=row["exit_code"],
            ))
            phase(item["folder"])
            if row["status"] != "passed" or row["evaluation"]["status"] != "passed":
                result.update(status=row["status"] if row["status"] != "passed" else "failed",
                              exit_code=row["exit_code"] or 1, first_failure=item["number"])
                break
            observed = json.dumps({key: row["worker"][key] for key in ("graph", "observation")},
                                  sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode()
            reference = output_references.setdefault(item["engine"], observed)
            if observed != reference:
                result["first_failure"] = item["number"]
                raise ValueError("Same-engine calibration output differs")
            state_inputs.require(time.perf_counter() < deadline, "Calibration shared deadline expired")
        else:
            result["groups"] = state_inputs.calibration_groups(completed_rows)
            result["terminal_guard"] = guard(plan)
            state_inputs.require(result["terminal_guard"]["status"] == "passed", "Calibration terminal guard failed")
            state_inputs.require(time.perf_counter() < deadline, "Calibration shared deadline expired")
            passed = all(group["timing_eligible"] is not False for group in result["groups"])
            result.update(status="passed" if passed else "ineligible", exit_code=0 if passed else 1)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, KeyboardInterrupt) as error:
        result.update(status="incomplete" if isinstance(error, KeyboardInterrupt) else "failed",
                      exit_code=125 if isinstance(error, KeyboardInterrupt) else 1, failure=type(error).__name__)
        result["failure_reason"] = str(error)
    phase("calibration-finalization-or-failed-work")
    result["skipped_invocations"] = [item["number"] for item in result["plan"]["invocations"]
                                     if item["number"] > len(result["invocations"])]
    result["wall_seconds_before_receipt"] = time.perf_counter() - started
    if result["wall_seconds_before_receipt"] >= 900 and result["exit_code"] == 0:
        result.update(status="incomplete", exit_code=125, failure="SharedDeadlineExpired")
    result["cost_accounting"] = dict(
        prior_costs=plan["prior_costs"],
        nested_timings="explanatory; never added twice or subtracted from composed costs",
        enclosing_process="Includes final serialization and interpreter teardown outside this inner clock",
    )
    save(output / "results.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--plan-sha256", required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--runtime-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    plan = state_inputs.document(dict(path=str(args.plan), sha256=args.plan_sha256))
    raise SystemExit(execute(plan, args.runtime, args.runtime_sha256, args.output)["exit_code"])


if __name__ == "__main__":
    main()
