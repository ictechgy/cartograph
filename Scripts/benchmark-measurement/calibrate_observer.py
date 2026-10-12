#!/usr/bin/env python3
"""한 프로세스와 반복 CLI 모양에서 관찰자 편향을 합성 교차 순서로 측정한다."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
import time

import paired_sessions as paired
import process_tree_measure as measurement

HERE = Path(__file__).resolve().parent
WORKLOAD = HERE / "synthetic_workload.py"
WORKLOADS = {
    "one_sustained_process": [sys.executable, str(WORKLOAD), "cpu", "1800000"],
    "twelve_cli_subprocesses": [sys.executable, str(WORKLOAD), "repeated_cpu", "12", "150000"],
}


def calibration_plan(pairs: int, seed: int, bootstrap_seed: int, interval: float) -> dict:
    """결과 확인 전에 비교별 AB/BA 수와 모든 순서를 고정한다."""
    if pairs < 2 or pairs % 2:
        raise ValueError("An even positive pair count is required for balanced order")
    rng = random.Random(seed)
    jobs = []
    for workload in WORKLOADS:
        for mode in ("timing", "memory"):
            orders = ["AB"] * (pairs // 2) + ["BA"] * (pairs // 2)
            rng.shuffle(orders)
            jobs.extend({"workload": workload, "mode": mode, "pair": index + 1, "order": order}
                        for index, order in enumerate(orders))
    rng.shuffle(jobs)
    return {
        "scope": "synthetic observer calibration only; never product superiority evidence",
        "pairs_per_workload_mode": pairs,
        "arm_A": "direct blocking wait with no observer",
        "arm_B": "declared helper mode",
        "randomization_seed": seed,
        "bootstrap_seed": bootstrap_seed,
        "bootstrap_resamples": 10000,
        "rss_interval_seconds": interval,
        "workloads": WORKLOADS,
        "jobs": jobs,
        "python_version": platform.python_version(),
        "platform": sys.platform,
        "hashes": {path.name: measurement.file_sha256(path) for path in
                   (Path(__file__), WORKLOAD, HERE / "process_tree_measure.py", HERE / "paired_sessions.py")},
        "load_policy": "Sequential calibration runs; other cloud workload activity and OS caches uncontrolled",
        "no_reseed_or_outlier_removal": True,
    }


def direct_run(command: list[str], stem: Path) -> dict:
    """고정 유한 반복 합성 작업을 샘플러 없이 같은 파일 출력과 blocking wait로 실행한다."""
    stdout = Path(str(stem) + ".stdout")
    stderr = Path(str(stem) + ".stderr")
    with stdout.open("xb") as out, stderr.open("xb") as err:
        started = time.perf_counter()
        process = subprocess.Popen(command, cwd=HERE, stdout=out, stderr=err, start_new_session=True)
        returncode = process.wait()
        elapsed = time.perf_counter() - started
    result = {"mode": "no_observer", "status": "ok" if returncode == 0 else "failed",
              "returncode": returncode, "wall_seconds": elapsed, "command": command,
              "artifacts": {kind: {"name": path.name, "sha256": measurement.file_sha256(path)}
                            for kind, path in (("stdout", stdout), ("stderr", stderr))}}
    measurement.write_json(Path(str(stem) + ".json"), result)
    return result


def run_calibration(plan: dict, output: Path) -> dict:
    """모든 비교와 원본 실패를 남기고 관찰자 비용을 제품 성능으로 해석하지 않는다."""
    output.mkdir(exist_ok=False)
    measurement.write_json(output / "plan.json", plan)
    records = []
    for job in plan["jobs"]:
        directory = output / job["workload"] / job["mode"] / f"pair-{job['pair']:02d}"
        directory.mkdir(parents=True)
        results = {}
        for arm in job["order"]:
            command = plan["workloads"][job["workload"]]
            if arm == "A":
                results[arm] = direct_run(command, directory / "no-observer")
            else:
                results[arm] = measurement.run(command, HERE, directory / job["mode"], timeout=30,
                                               interval=plan["rss_interval_seconds"], mode=job["mode"])
        record = {**job, "no_observer": results["A"], "observed": results["B"],
                  "output_agrees": results["A"]["artifacts"]["stdout"]["sha256"] ==
                                   results["B"]["artifacts"]["stdout"]["sha256"]}
        records.append(record)
        measurement.write_json(directory / "pair.json", record)
    groups = []
    for workload in plan["workloads"]:
        for mode in ("timing", "memory"):
            selected = [record for record in records if record["workload"] == workload and record["mode"] == mode]
            failures = [record["pair"] for record in selected if not record["output_agrees"] or
                        record["no_observer"]["status"] != "ok" or record["observed"]["status"] != "ok"]
            rows = [(row["no_observer"]["wall_seconds"], row["observed"]["wall_seconds"]) for row in selected]
            result = paired.paired_bootstrap(rows, plan["bootstrap_seed"], plan["bootstrap_resamples"])
            sample_bytes = [row["observed"]["rss"]["sample_total_bytes"] for row in selected] if mode == "memory" else []
            groups.append({"workload": workload, "mode": mode, "pair_count": len(selected),
                           "AB_count": sum(row["order"] == "AB" for row in selected),
                           "BA_count": sum(row["order"] == "BA" for row in selected),
                           "failed_pairs": failures,
                           "no_observer_median_seconds": statistics.median(a for a, b in rows),
                           "observed_median_seconds": statistics.median(b for a, b in rows),
                           "median_observer_over_no_observer_ratio": result["paired_median_ratio"],
                           "ratio_95_ci": result["ratio_95_percentile_ci"],
                           "raw_ratios": result["paired_ratios"],
                           "rss_bytes_per_run": sample_bytes,
                           "rss_bytes_total": sum(sample_bytes),
                           "maximum_run_evidence_bytes": max(sum(path.stat().st_size for path in
                                (output / workload / mode / f"pair-{row['pair']:02d}").iterdir()) for row in selected)})
    summary = {"scope": plan["scope"], "plan_sha256": measurement.file_sha256(output / "plan.json"),
               "all_outputs_agree": all(record["output_agrees"] for record in records),
               "groups": groups,
               "interpretation": [
                   "A ratio greater than 1 means instrumentation made the same synthetic work slower.",
                   "Ratios below 1 can reflect noise, caches or scheduling; never treat them as tool speedups.",
                   "No observer correction is subtracted from product timing; primary uses timing-only runs.",
                   "Repeat calibration on the pinned native macOS regime before freezing final execution.",
                   "This uncontrolled-load cloud calibration supplies no Cartograph or baseline superiority evidence.",
               ]}
    measurement.write_json(output / "summary.json", summary)
    return summary


def main() -> None:
    """실행 계획과 출력 경로를 명시적으로 받아 재측정 선택 편향을 드러낸다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=10)
    parser.add_argument("--seed", required=True, type=int)
    parser.add_argument("--bootstrap-seed", required=True, type=int)
    parser.add_argument("--interval", type=float, default=0.01)
    args = parser.parse_args()
    plan = calibration_plan(args.pairs, args.seed, args.bootstrap_seed, args.interval)
    print(json.dumps(run_calibration(plan, args.output_dir), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
