#!/usr/bin/env python3
"""성공한 동일 도구 설치를 재사용해 실제 iOS 혼합 언어 상태를 검증한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation"
sys.path.insert(0, str(FIXTURE))
from compiler_generations import POLICIES, INCOMPLETE_PROCESS_EXIT, incomplete_exit

REVISION = "64aa0b26913249c4e7c21d351a215fba02702003"
SPEC = importlib.util.spec_from_file_location("mixed_base", ROOT / "Scripts/benchmark-indexstore-cli.py")
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)


def build_hook(setup_path: Path) -> list[str]:
    setup = json.loads(setup_path.read_text())
    if setup.get("status") != "passed" or setup.get("revision") != REVISION:
        raise ValueError("Mixed native validation requires a passed same-tool setup run")
    comparator, native, compiler = setup["comparator_setup"], setup["cartograph"], setup["toolchain"]
    for record, field in [(comparator, "binary"), (native, "binary"), (compiler, "library")]:
        path = Path(record[field])
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != record[field + "_sha256"]:
            raise ValueError(f"Reused {field} bytes differ from recorded setup")
    return [
        sys.executable,
        str(FIXTURE / "adapter/observe_mixed.py"),
        "--fixture-root",
        str(FIXTURE),
        "--index-dump",
        comparator["binary"],
        "--indexstore-checkout",
        comparator["checkout"],
        "--cli-build-evidence",
        str(setup_path),
        "--library",
        compiler["library"],
        "--cartograph",
        native["binary"],
        "--cartograph-graph-mode",
        "include-self-loops",
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--setup-results", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler-index-policy", choices=POLICIES, default=POLICIES[0])
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be absent or empty; existing evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    (output / "setup").mkdir()
    lifecycle_started, command = None, None
    try:
        hook = build_hook(args.setup_results.resolve())
        hook_path = output / "setup/observer-argv.json"
        hook_path.write_text(json.dumps(hook, indent=2) + "\n")
        command = [
            sys.executable,
            str(FIXTURE / "run_ios_validation.py"),
            "--output",
            str(output / "validation"),
            "--hook-json",
            str(hook_path),
            "--continue-observation-failures",
            "--compiler-index-policy",
            args.compiler_index_policy,
        ]
        lifecycle_started = time.perf_counter()
        measurement = BASE.run(command, ROOT, output / "setup/lifecycle", timeout=1200)
        child = json.loads((output / "validation/results.json").read_text())
        if child.get("status") != "passed" or child.get("ios_execution") != "compiler-only":
            raise ValueError("Native lifecycle did not record a complete compiler validation pass")
        BASE.save(
            output / "results.json",
            {
                "status": "passed",
                "role": "mixed-ios-validation-only",
                "compiler_index_policy": args.compiler_index_policy,
                "superiority_claim": None,
                "lifecycle": measurement,
                "validation_results": str(output / "validation/results.json"),
            },
        )
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, KeyboardInterrupt) as error:
        failure = dict(status="failed", error=f"{type(error).__name__}: {error}", superiority_claim=None,
                       compiler_index_policy=args.compiler_index_policy)
        incomplete = isinstance(error, KeyboardInterrupt)
        if lifecycle_started is not None:
            path = output / "setup/lifecycle.json"
            try:
                measurement = json.loads(path.read_text()) if path.is_file() else dict(
                    command=command, returncode="interrupted" if incomplete else "launch-error",
                    wall_seconds=time.perf_counter() - lifecycle_started,
                )
                failure["lifecycle"] = measurement
                incomplete = incomplete or bool(measurement.get("timed_out")) or incomplete_exit(measurement["returncode"])
            except (OSError, ValueError, KeyError) as retention_error:
                incomplete = True
                failure["retention_error"] = f"{type(retention_error).__name__}: {retention_error}"
        if incomplete:
            failure["process_lifecycle"] = dict(completed=False, descendant_cleanup_verified=False)
        BASE.save(output / "results.json", failure)
        print(f"Mixed validation setup failed: {error}", file=sys.stderr)
        return INCOMPLETE_PROCESS_EXIT if incomplete else 2


if __name__ == "__main__":
    raise SystemExit(main())
