#!/usr/bin/env python3
"""기존 macOS CI에서 고정 합성 측정 진단을 실행하고 모든 단계 결과를 남긴다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / "Scripts/benchmark-measurement"


def save(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def plan() -> dict:
    return dict(
        role="fixed synthetic native helper validation only",
        final_comparison=False,
        pairs_per_workload_mode=4,
        randomization_seed=20261012,
        bootstrap_seed=101226,
        sample_interval_seconds=0.01,
        runner_regime="moving macos-latest/newest-Xcode pilot",
        real_engine_calibration="not-run",
        sdk_content_identity="not-proved",
        containment="known cooperative/retained identities only; detached macOS ancestry gaps remain",
        cache_policy="OS filesystem caches and unrelated host load uncontrolled",
    )


def command(argv: list[str], cwd: Path, stem: Path, environment: dict, timeout: float) -> dict:
    """완료되지 않은 단계는 125로 남긴다. 다음 단계는 호출자가 시작하지 않는다."""
    stem.parent.mkdir(parents=True, exist_ok=True)
    stdout, stderr = Path(str(stem) + ".stdout"), Path(str(stem) + ".stderr")
    if any(Path(str(stem) + suffix).exists() for suffix in (".stdout", ".stderr", ".json")):
        raise ValueError("Existing command evidence must not be overwritten")
    started = time.perf_counter()
    cleanup_signals, cleanup_root_unfinished = [], False
    failure, process, completed, code = None, None, False, 125
    with stdout.open("xb") as out, stderr.open("xb") as err:
        try:
            process = subprocess.Popen(argv, cwd=cwd, env=environment, stdout=out, stderr=err, start_new_session=True)
            code = process.wait(timeout=timeout)
            completed = code >= 0 and code != 125
            if not completed:
                failure = "nested-incomplete" if code == 125 else "signal"
        except subprocess.TimeoutExpired:
            failure = "timeout"
        except KeyboardInterrupt:
            failure = "interrupt"
        except OSError:
            failure = "launch"
        finally:
            if process is not None and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    cleanup_signals.append("term-sent")
                except ProcessLookupError:
                    cleanup_signals.append("term-target-already-exited")
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                        cleanup_signals.append("kill-sent")
                    except ProcessLookupError:
                        cleanup_signals.append("kill-target-already-exited")
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        cleanup_root_unfinished = True
    row = dict(
        command=argv,
        cwd=str(cwd),
        returncode=code if completed else 125,
        observed_returncode=process.returncode if process is not None else None,
        completed=completed,
        passed=completed and code == 0,
        failure=failure,
        wall_seconds=time.perf_counter() - started,
        descendant_cleanup_verified=False,
        containment="POSIX process-group fallback only; no detached-descendant guarantee",
        stdout=str(stdout.resolve()),
        stderr=str(stderr.resolve()),
        cleanup_signals=cleanup_signals,
        cleanup_root_unfinished=cleanup_root_unfinished,
    )
    save(Path(str(stem) + ".json"), row)
    return row


def helper_hashes() -> dict:
    return {
        str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(
            [
                *HELPERS.iterdir(),
                Path(__file__).resolve(),
                ROOT / "Scripts/normalize-indexstore-evidence.py",
                ROOT / ".github/workflows/ci.yml",
            ]
        )
        if p.is_file()
    }


def calibration_passed(output: Path, config: dict) -> bool:
    """도우미의 종료 0만으로 실패한 합성 쌍이나 빠진 그룹을 통과시키지 않는다."""
    directory = output / "runs/calibration"
    try:
        summary = json.loads((directory / "summary.json").read_text())
        groups = summary["groups"]
        expected = {(w, m) for w in ["one_sustained_process", "twelve_cli_subprocesses"] for m in ["timing", "memory"]}
        return (
            summary["all_outputs_agree"] is True
            and len(groups) == 4
            and {(g["workload"], g["mode"]) for g in groups} == expected
            and summary["plan_sha256"] == hashlib.sha256((directory / "plan.json").read_bytes()).hexdigest()
            and all(
                g["failed_pairs"] == []
                and g["pair_count"] == config["pairs_per_workload_mode"]
                and g["AB_count"] == g["BA_count"] == config["pairs_per_workload_mode"] // 2
                for g in groups
            )
        )
    except (OSError, ValueError, KeyError, TypeError):
        return False


def validate(output: Path, dependencies: Path) -> dict:
    """진단 단계가 실패하면 증거를 남기되 이후 실행으로 오염을 전파하지 않는다."""
    if sys.platform != "darwin":
        raise ValueError("This diagnostic requires native macOS; no platform substitution")
    output, dependencies = output.resolve(), dependencies.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError("Evidence output must be absent or empty")
    if dependencies.exists():
        raise ValueError("Dependency directory must be new and task-owned")
    if dependencies.is_relative_to(output) or output.is_relative_to(dependencies):
        raise ValueError("Dependency bytes and publishable raw evidence must be separate")
    started = time.perf_counter()
    output.mkdir(parents=True, exist_ok=True)
    (output / "runs").mkdir()
    config, hashes = plan(), helper_hashes()
    save(output / "setup/plan.json", config)
    save(output / "setup/helper-hashes.json", hashes)
    # 사용자 pip 구성/추가 인덱스를 상속하지 않고 공식 PyPI만 사용한다. 값은 증거에 기록하지 않는다.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("PIP_")}
    environment["PIP_CONFIG_FILE"] = os.devnull
    environment["PYTHONPATH"] = str(dependencies)
    phases = [
        (
            "install",
            [
                sys.executable,
                "-m",
                "pip",
                "install",
                "--index-url",
                "https://pypi.org/simple",
                "--no-input",
                "--disable-pip-version-check",
                "--no-cache-dir",
                "--target",
                str(dependencies),
                "--report",
                str(output / "setup/install-report.json"),
                "-r",
                str(HELPERS / "requirements.txt"),
            ],
            180,
        ),
        ("tests", [sys.executable, "-m", "unittest", "discover", "-s", str(HELPERS), "-p", "test_*.py", "-v"], 180),
        (
            "machine",
            [
                sys.executable,
                str(HELPERS / "machine_manifest.py"),
                "--output-dir",
                str(output / "setup/machine"),
                "--concurrency-policy",
                "Sequential diagnostic; background host activity uncontrolled",
                "--cache-policy",
                config["cache_policy"],
                "--runner-regime",
                config["runner_regime"],
                "--collect-toolchain",
            ],
            120,
        ),
        (
            "calibration",
            [
                sys.executable,
                str(HELPERS / "calibrate_observer.py"),
                "--output-dir",
                str(output / "runs/calibration"),
                "--pairs",
                str(config["pairs_per_workload_mode"]),
                "--seed",
                str(config["randomization_seed"]),
                "--bootstrap-seed",
                str(config["bootstrap_seed"]),
                "--interval",
                str(config["sample_interval_seconds"]),
            ],
            180,
        ),
    ]
    result = dict(status="running", **config, phases={}, helper_hashes=hashes)
    save(output / "results.json", result)
    for name, argv, timeout in phases:
        if helper_hashes() != hashes:
            result.update(status="failed", failed_phase=name, failure="helper-input-changed-before-phase")
            break
        row = command(argv, ROOT, output / "setup" / name, environment, timeout)
        result["phases"][name] = row
        if not row["passed"] or helper_hashes() != hashes:
            result.update(
                status="failed",
                failed_phase=name,
                failure="phase-failed" if not row["passed"] else "helper-input-changed-after-phase",
            )
            break
    else:
        if calibration_passed(output, config):
            result["status"] = "completed-synthetic-native-validation"
        else:
            result.update(status="failed", failed_phase="calibration", failure="calibration-oracle-failed")
    result["diagnostic_wall_seconds"] = time.perf_counter() - started
    save(output / "results.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dependencies", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = validate(args.output, args.dependencies)
    except (ValueError, OSError) as error:
        print(f"Diagnostic setup refused: {type(error).__name__}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {"status": result["status"], "failed_phase": result.get("failed_phase"), "final_comparison": False},
            sort_keys=True,
        )
    )
    if result["status"] == "completed-synthetic-native-validation":
        return 0
    return 125 if any(not r["completed"] for r in result["phases"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
