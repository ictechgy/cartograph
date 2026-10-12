#!/usr/bin/env python3
"""고정된 전체 세션 쌍으로 무작위 순서와 사전 선언 통계 판정을 만든다."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import random
import statistics
from typing import Any

PAIR_COUNT = 20
QUERY_COUNT = 10
REQUIRED_GATES = (
    "source_oracle", "negative_controls", "refresh", "rename_delete", "restoration", "stale_input",
    "common_index_before_after", "private_reader_state", "ten_query_batches", "equivalent_session_state",
)
ENDPOINTS = ("primary_composed", "secondary_existing_built")
PRIMARY_ARM_COMPONENTS = (
    "initial_discovery_setup_seconds", "initial_cache_validation_seconds", "initial_batch_seconds",
    "post_edit_refresh_seconds", "post_edit_cache_validation_seconds", "post_edit_batch_seconds",
)
SECONDARY_ARM_COMPONENTS = ("discovery_setup_seconds", "cache_validation_seconds", "batch_seconds")


def canonical_sha256(value: Any) -> str:
    """원본과 순서를 포함한 정규 JSON을 해시해 계획 교체를 드러낸다."""
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def make_plan(seed: int, bootstrap_seed: int, bootstrap_resamples: int = 50000,
              *, memory_seed: int) -> dict:
    """결과를 보기 전 고정해야 하는 20쌍의 각 상태별 균형 순서를 제공한다."""
    if type(seed) is not int or type(bootstrap_seed) is not int or type(memory_seed) is not int:
        raise ValueError("Timing, memory and bootstrap seeds must be explicit integers")
    if memory_seed == seed:
        raise ValueError("Memory arm order requires its own independently seeded randomization")
    if type(bootstrap_resamples) is not int or bootstrap_resamples < 10000:
        raise ValueError("At least 10000 preregistered bootstrap resamples are required")
    rng = random.Random(seed)
    orders = {}
    memory_orders = {}
    memory_rng = random.Random(memory_seed)
    for state in ("initial", "post_edit", "existing_built"):
        values = ["AB"] * 10 + ["BA"] * 10
        rng.shuffle(values)
        orders[state] = values
        memory_values = ["AB"] * 10 + ["BA"] * 10
        memory_rng.shuffle(memory_values)
        memory_orders[state] = memory_values
    plan = {
        "schema_version": 1,
        "pair_count_per_endpoint": PAIR_COUNT,
        "query_count_per_indexed_state": QUERY_COUNT,
        "arms": {"A": "baseline", "B": "cartograph"},
        "python_version": platform.python_version(),
        "random_generator": "Python random.Random MT19937; implementation version is pinned above",
        "analysis_helper_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "randomization_seed": seed,
        "memory_randomization_seed": memory_seed,
        "timing_mode": "timing_without_rss_or_periodic_tree_sampling",
        "memory_policy": "Separate matched workload sessions with independent arm order; never use their timings",
        "bootstrap_seed": bootstrap_seed,
        "bootstrap_resamples": bootstrap_resamples,
        "bootstrap_method": "percentile_95_type7_interpolation_resample_whole_pairs",
        "statistic": "median_of_within_pair_cartograph_over_baseline_total_cost_ratios",
        "primary_arm_cost_components": list(PRIMARY_ARM_COMPONENTS),
        "secondary_arm_cost_components": list(SECONDARY_ARM_COMPONENTS),
        "zero_cost_policy": "Every zero component must be explicitly listed in observed_zero_components",
        "maximum_success_ratio": 0.8,
        "confidence_upper_bound_strictly_below": 1.0,
        "overall_success_endpoint": "primary_composed",
        "reseed_policy": "No reseeding or replacing failed pairs after outcomes are observed",
        "pairs": [{"pair_id": f"pair-{i + 1:02d}",
                   "orders": {state: values[i] for state, values in orders.items()}}
                  for i in range(PAIR_COUNT)],
        "memory_pairs": [{"pair_id": f"pair-{i + 1:02d}",
                          "orders": {state: values[i] for state, values in memory_orders.items()}}
                         for i in range(PAIR_COUNT)],
    }
    return {**plan, "plan_sha256": canonical_sha256(plan)}


def validate_plan(plan: dict) -> None:
    """순서, 임계값, 표본 수 변경을 해시와 재생성 비교로 모두 거부한다."""
    expected = make_plan(plan["randomization_seed"], plan["bootstrap_seed"], plan["bootstrap_resamples"],
                         memory_seed=plan["memory_randomization_seed"])
    if plan != expected:
        raise ValueError("Plan differs from its fixed seeds or preregistered 20-pair specification")


def percentile(values: list[float], probability: float) -> float:
    """명시적인 type-7 선형 보간으로 작은 수열도 재현 가능하게 만든다."""
    if not values or not 0 <= probability <= 1 or not all(math.isfinite(v) for v in values):
        raise ValueError("Percentile needs nonempty finite values and probability in [0, 1]")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lo, hi = math.floor(position), math.ceil(position)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (position - lo)


def paired_bootstrap(cost_pairs: list[tuple[float, float]], seed: int, resamples: int) -> dict:
    """공유 빌드가 들어 있는 전체 쌍을 뽑아 쌍 안의 상관을 보존한다.

    각 튜플은 (baseline, cartograph)이며 질의나 빌드 조각을 따로 재표집하지 않는다.
    """
    if not cost_pairs or type(seed) is not int or type(resamples) is not int or resamples < 1:
        raise ValueError("Provide finite positive whole-session costs, an integer seed and resample count")
    for pair in cost_pairs:
        if len(pair) != 2 or any(not math.isfinite(value) or value <= 0 for value in pair):
            raise ValueError("Each pair must contain two finite positive whole-session costs")
    rng = random.Random(seed)
    observed = [cartograph / baseline for baseline, cartograph in cost_pairs]
    if any(not math.isfinite(ratio) or ratio <= 0 for ratio in observed):
        raise ValueError("Pair ratio overflow or underflow; report numerical failure, not a win")
    boot = []
    for _ in range(resamples):
        selected = [cost_pairs[rng.randrange(len(cost_pairs))] for _ in range(len(cost_pairs))]
        boot.append(statistics.median(cartograph / baseline for baseline, cartograph in selected))
    ratio = statistics.median(observed)
    interval = [percentile(boot, 0.025), percentile(boot, 0.975)]
    return {
        "paired_median_ratio": ratio,
        "paired_median_improvement_fraction": 1 - ratio,
        "ratio_95_percentile_ci": interval,
        "paired_ratios": observed,
        "resampling_unit": "whole_independent_session_pair_including_its_shared_build_costs",
        "bootstrap_seed": seed,
        "bootstrap_resamples": resamples,
        "twenty_percent_gate": ratio <= 0.8,
        "confidence_gate": interval[1] < 1.0,
    }


def _seconds(value: Any) -> float:
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError("Every timing must be finite, numeric and nonnegative")
    return float(value)


def _arm_components(record: dict, names: tuple[str, ...]) -> dict[str, float]:
    components = {name: _seconds(record[name]) for name in names}
    zero_observations = record.get("observed_zero_components", [])
    if not isinstance(zero_observations, list) or any(name not in names for name in zero_observations):
        raise ValueError("Observed zero-component names must belong to this endpoint")
    for name, seconds in components.items():
        if seconds == 0 and name not in zero_observations:
            raise ValueError(f"Zero cost was not explicitly observed: {name}")
        if seconds != 0 and name in zero_observations:
            raise ValueError(f"A positive cost was inconsistently declared zero: {name}")
    return components


def cost_decomposition(record: dict, endpoint: str) -> dict:
    """준비·검증·갱신 시간을 질의 시간과 분리하여 누락과 이중 청구를 감사한다."""
    names = PRIMARY_ARM_COMPONENTS if endpoint == "primary_composed" else SECONDARY_ARM_COMPONENTS
    result = {arm: _arm_components(record[arm], names) for arm in ("baseline", "cartograph")}
    if endpoint == "primary_composed":
        result["shared_charged_in_full_to_each_arm"] = {
            name: _seconds(record[name])
            for name in ("shared_initial_build_seconds", "shared_edit_rebuild_seconds")
        }
    return result


def composed_cost(record: dict) -> tuple[float, float]:
    """공유 빌드를 동일하게 전액 청구하고 준비·캐시 검증·갱신 비용을 빠짐없이 더한다."""
    parts = cost_decomposition(record, "primary_composed")
    shared = sum(parts["shared_charged_in_full_to_each_arm"].values())
    return tuple(shared + sum(parts[arm].values()) for arm in ("baseline", "cartograph"))


def existing_built_cost(record: dict) -> tuple[float, float]:
    """이미 빌드된 인덱스도 새 리더 준비·캐시 검증·전체 배치 비용을 모두 청구한다."""
    parts = cost_decomposition(record, "secondary_existing_built")
    return tuple(sum(parts[arm].values()) for arm in ("baseline", "cartograph"))


def _artifact_errors(record: dict) -> list[str]:
    artifacts = record.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        return ["missing_raw_evidence_hashes"]
    for artifact in artifacts:
        if not isinstance(artifact, dict) or not artifact.get("name") or not isinstance(artifact.get("sha256"), str):
            return ["invalid_raw_evidence_hashes"]
        digest = artifact["sha256"]
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            return ["invalid_raw_evidence_hashes"]
    return []


def analyze(plan: dict, observations: dict) -> dict:
    """실패한 쌍을 삭제하지 않고 두 지표를 항상 보고하되 주 지표만 종합 판정한다."""
    validate_plan(plan)
    if observations.get("plan_sha256") != plan["plan_sha256"]:
        raise ValueError("Observed plan hash does not match the frozen plan")
    records = observations.get("pairs")
    if not isinstance(records, list):
        raise ValueError("Observations must preserve a list of paired-session records")
    ids = [record.get("pair_id") for record in records]
    expected_ids = [pair["pair_id"] for pair in plan["pairs"]]
    if len(ids) != len(set(ids)) or any(pair_id not in expected_ids for pair_id in ids):
        raise ValueError("Duplicate or unknown pair IDs; do not replace or duplicate failed pairs")
    by_id = {record["pair_id"]: record for record in records}
    endpoints = {}
    for endpoint in ENDPOINTS:
        failures, costs = [], []
        for planned in plan["pairs"]:
            pair_id = planned["pair_id"]
            pair = by_id.get(pair_id)
            reasons = []
            record = pair.get(endpoint) if pair else None
            if not isinstance(record, dict):
                failures.append({"pair_id": pair_id, "reasons": ["missing_endpoint_record"]})
                continue
            if record.get("status") != "ok":
                reasons.append("failed_or_incomplete_session")
            if record.get("measurement_mode") != "timing" or record.get("rss_sampling_enabled") is not False:
                reasons.append("sampled_or_undeclared_timing_mode")
            states = ("initial", "post_edit") if endpoint == "primary_composed" else ("existing_built",)
            expected_orders = {state: planned["orders"][state] for state in states}
            if record.get("orders") != expected_orders:
                reasons.append("arm_order_differs_from_plan")
            gates = REQUIRED_GATES if endpoint == "primary_composed" else (
                "source_oracle", "negative_controls", "stale_input", "common_index_before_after",
                "private_reader_state", "ten_query_batches", "equivalent_session_state",
            )
            reasons.extend(f"gate:{name}" for name in gates if record.get("gates", {}).get(name) is not True)
            reasons.extend(_artifact_errors(record))
            try:
                totals = composed_cost(record) if endpoint == "primary_composed" else existing_built_cost(record)
                if min(totals) <= 0 or any(not math.isfinite(value) for value in totals):
                    raise ValueError("Total session cost must be finite and positive")
                ratio = totals[1] / totals[0]
                if not math.isfinite(ratio) or ratio <= 0:
                    raise ValueError("Numerically invalid pair ratio")
                costs.append({"pair_id": pair_id, "baseline_seconds": totals[0], "cartograph_seconds": totals[1],
                              "cost_decomposition": cost_decomposition(record, endpoint)})
            except (KeyError, TypeError, ValueError):
                reasons.append("missing_or_invalid_timing")
            if reasons:
                failures.append({"pair_id": pair_id, "reasons": reasons})
        endpoint_result = {"endpoint": endpoint, "required_independent_pair_count": PAIR_COUNT,
                           "reported_pair_count": len(costs), "failures": failures, "whole_pair_costs": costs,
                           "performance": None, "passed": False}
        if not failures and len(costs) == PAIR_COUNT:
            statistics_result = paired_bootstrap(
                [(row["baseline_seconds"], row["cartograph_seconds"]) for row in costs],
                plan["bootstrap_seed"], plan["bootstrap_resamples"],
            )
            endpoint_result["performance"] = statistics_result
            endpoint_result["passed"] = statistics_result["twenty_percent_gate"] and statistics_result["confidence_gate"]
        endpoints[endpoint] = endpoint_result
    return {
        "schema_version": 1,
        "plan_sha256": plan["plan_sha256"],
        "observations_sha256": canonical_sha256(observations),
        "analysis_helper_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "overall_success_endpoint": "primary_composed",
        "overall_passed": endpoints["primary_composed"]["passed"],
        "endpoints": endpoints,
        "raw_observations": observations,
        "limitations": [
            "Hashes and declared gates are preserved, not independently proven by this arithmetic helper.",
            "Adapters must verify oracle answers, index bytes, query counts, private caches and actual run order.",
            "Independence, prior freeze and no-reseeding require a committed plan and append-only execution records.",
            "Memory/startup regressions greater than 10% remain explicit tradeoffs; no dominance claim is inferred.",
        ],
    }


def main() -> None:
    """최초 계획 파일도 결과 파일도 덮어쓰지 않아 모든 시도를 남긴다."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--seed", required=True, type=int)
    plan_parser.add_argument("--bootstrap-seed", required=True, type=int)
    plan_parser.add_argument("--memory-seed", required=True, type=int)
    plan_parser.add_argument("--bootstrap-resamples", default=50000, type=int)
    plan_parser.add_argument("--output", required=True, type=Path)
    analyze_parser = subparsers.add_parser("analyze")
    analyze_parser.add_argument("--plan", required=True, type=Path)
    analyze_parser.add_argument("--observations", required=True, type=Path)
    analyze_parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    value = (make_plan(args.seed, args.bootstrap_seed, args.bootstrap_resamples, memory_seed=args.memory_seed)
             if args.action == "plan"
             else analyze(json.loads(args.plan.read_text()), json.loads(args.observations.read_text())))
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
    summary = {"output": args.output.name, "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest()}
    if args.action == "analyze":
        summary["overall_passed"] = value["overall_passed"]
    print(json.dumps(summary))
    if args.action == "analyze" and not value["overall_passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
