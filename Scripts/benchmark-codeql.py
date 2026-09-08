#!/usr/bin/env python3
"""Run the CodeQL Swift value-flow benchmark with separate timing evidence.

The CodeQL CLI and its Swift extractor are downloaded and maintained outside this
repository. This script records the exact executable, pack resolution, Swift
runtime oracle, database extraction, query compilation, and repeated query runs.
It does not upload source or query results.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import signal
import shlex
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


LABEL_LINE = re.compile(r"^(?P<label>[A-Za-z0-9_-]+)=(?P<value>.*)$")
ORIGIN_VALUES = {"origin-A", "origin-B"}


def run_command(
    command: list[str],
    cwd: Path,
    stdout_path: Path,
    stderr_path: Path,
    timeout_s: int,
) -> dict[str, Any]:
    """Run one local command, terminating its process group on timeout."""
    started = time.perf_counter()
    timed_out = False
    cleanup: dict[str, Any] = {"sigterm_sent": False, "sigkill_sent": False, "process_exited": False}
    process: subprocess.Popen[str] | None = None
    stdout = ""
    stderr = ""
    try:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        stdout, stderr = process.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired as error:
        timed_out = True
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                cleanup["sigterm_sent"] = True
            except ProcessLookupError:
                pass
            try:
                stdout, trailing_stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                    cleanup["sigkill_sent"] = True
                except ProcessLookupError:
                    pass
                stdout, trailing_stderr = process.communicate()
            stderr = stderr or trailing_stderr
            cleanup["process_exited"] = process.poll() is not None
    elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
    stdout_text = stdout if isinstance(stdout, str) else stdout.decode(errors="replace")
    stderr_text = stderr if isinstance(stderr, str) else stderr.decode(errors="replace")
    stdout_path.write_text(stdout_text)
    stderr_path.write_text(stderr_text)
    return {
        "command": command,
        "returncode": 124 if timed_out else (process.returncode if process is not None else 1),
        "wall_ms": elapsed_ms,
        "timed_out": timed_out,
        "timeout_cleanup": cleanup,
    }


def load_expected(path: Path) -> dict[str, list[dict[str, Any]]]:
    """Load runtime and flow oracles from the reviewed corpus manifest."""
    document = json.loads(path.read_text())
    runtime = document.get("runtime")
    flow_oracle = document.get("flow_oracle")
    if not isinstance(runtime, list) or not runtime:
        raise ValueError("expected.json must contain a non-empty runtime array")
    if not isinstance(flow_oracle, list) or not flow_oracle:
        raise ValueError("expected.json must contain a non-empty flow_oracle array")
    return {"runtime": runtime, "flow_oracle": flow_oracle}


def parse_runtime(path: Path) -> dict[str, str]:
    """Parse probe output and reject any non-probe output as bad evidence."""
    observations: dict[str, str] = {}
    malformed: list[str] = []
    for line in path.read_text().splitlines():
        match = LABEL_LINE.match(line)
        if not match:
            malformed.append(line)
            continue
        label = match.group("label")
        if label in observations:
            raise ValueError(f"duplicate probe label: {label}")
        observations[label] = match.group("value")
    if malformed:
        raise ValueError(f"runtime emitted non-probe lines: {malformed}")
    return observations


def find_binary(build_root: Path) -> Path:
    """Locate SwiftPM's executable in its Xcode-style scratch output."""
    candidates = list(build_root.glob("out/Products/*/ValueFlowBenchmark"))
    if len(candidates) != 1:
        raise FileNotFoundError(f"expected one built executable, found {candidates}")
    return candidates[0]


def command_for_build(method: str, corpus: Path, output: Path) -> tuple[list[str], Path]:
    """Return a CodeQL build command and the expected direct-build executable."""
    if method == "swiftpm":
        scratch = output / "codeql-swiftpm-build"
        return ["swift", "build", "--scratch-path", str(scratch)], scratch / "out/Products/Debug/ValueFlowBenchmark"
    direct_binary = output / "codeql-direct-swiftc" / "ValueFlowBenchmark"
    sources = sorted(corpus.glob("Sources/ValueFlowBenchmark/*.swift"))
    return [
        "swiftc",
        "-parse-as-library",
        "-module-name",
        "ValueFlowBenchmark",
        *[str(path.relative_to(corpus)) for path in sources],
        "-o",
        str(direct_binary),
    ], direct_binary


def parse_bqrs_csv(path: Path) -> dict[str, Any]:
    """Read query rows and recover the final label/origin columns."""
    rows = list(csv.reader(path.read_text().splitlines()))
    if not rows:
        return {"columns": [], "rows": [], "pairs": []}
    columns = rows[0]
    data = rows[1:]
    pairs: set[tuple[str, str]] = set()
    for row in data:
        if len(row) < 2:
            continue
        # The benchmark queries place the stable label/origin columns last;
        # source and sink descriptions may contain arbitrary identifier text.
        label = row[-2].strip('"')
        origin = row[-1].strip('"')
        if re.fullmatch(r"[A-Za-z0-9_-]+", label) and origin in ORIGIN_VALUES:
            pairs.add((label, origin))
    return {"columns": columns, "rows": data, "pairs": [list(pair) for pair in sorted(pairs)]}


def pair_score(expected: set[tuple[str, str]], observed: list[list[str]], labels: set[str]) -> dict[str, Any]:
    """Compare one CodeQL relation with the explicit origin-to-sink oracle."""
    observed_set = {tuple(pair) for pair in observed if pair[0] in labels}
    true_positive = sorted(observed_set & expected)
    false_positive = sorted(observed_set - expected)
    false_negative = sorted(expected - observed_set)
    return {
        "oracle_pairs": [list(pair) for pair in sorted(expected)],
        "observed_pairs": [list(pair) for pair in sorted(observed_set)],
        "tp": len(true_positive),
        "fp": len(false_positive),
        "fn": len(false_negative),
        "true_positive_pairs": [list(pair) for pair in true_positive],
        "false_positive_pairs": [list(pair) for pair in false_positive],
        "false_negative_pairs": [list(pair) for pair in false_negative],
    }


def compare(
    expected: dict[str, list[dict[str, Any]]],
    observations: dict[str, str],
    query_results: dict[str, Any],
    score_allowed: bool,
) -> dict[str, Any]:
    """Score value flow and taint flow independently after runtime validation."""
    runtime_cases = expected["runtime"]
    flow_cases = expected["flow_oracle"]
    expected_runtime = {case["label"]: case["value"] for case in runtime_cases}
    runtime_mismatches = [
        {"label": label, "expected": value, "actual": observations.get(label)}
        for label, value in sorted(expected_runtime.items())
        if observations.get(label) != value
    ]
    labels = {case["label"] for case in flow_cases if case.get("evaluation") == "score"}
    oracle = {
        (case["label"], origin)
        for case in flow_cases
        if case.get("evaluation") == "score"
        for origin in case.get("expected_origins", [])
    }
    scores = (
        {
            name: pair_score(oracle, query_results.get(name, {}).get("pairs", []), labels)
            for name in ("value_flow", "taint_flow")
        }
        if score_allowed
        else None
    )
    return {
        "runtime": {
            "missing_labels": sorted(set(expected_runtime) - set(observations)),
            "unexpected_labels": sorted(set(observations) - set(expected_runtime)),
            "mismatches": runtime_mismatches,
        },
        "flow_oracle": {"score_labels": sorted(labels), "expected_pairs": [list(pair) for pair in sorted(oracle)]},
        "score_status": "scored" if score_allowed else "unscored",
        "score": scores,
        "constants": query_results.get("constants", {}).get("rows", []),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    default_corpus = Path(__file__).resolve().parents[1] / "Fixtures/ValueFlowBenchmark"
    parser.add_argument("--corpus", type=Path, default=default_corpus)
    parser.add_argument("--codeql", type=Path, default=Path("/tmp/cartograph-codeql-path"))
    parser.add_argument("--build-method", choices=("swiftpm", "directswiftc"), default="swiftpm")
    parser.add_argument("--runs", type=int, default=3, help="query repetitions (minimum: 3)")
    parser.add_argument("--timeout", type=int, default=300, help="per-command timeout in seconds")
    parser.add_argument("--output-dir", type=Path, help="evidence directory; defaults below the corpus")
    args = parser.parse_args()
    if args.runs < 3:
        parser.error("--runs must be at least 3")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    corpus = args.corpus.resolve()
    pointer = args.codeql.resolve()
    codeql_root = Path(pointer.read_text().strip()) if pointer.is_file() else pointer
    codeql = codeql_root / "codeql/codeql"
    output = args.output_dir.resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix="cartograph-codeql-", dir=corpus / ".benchmark-results"))
    output.mkdir(parents=True, exist_ok=True)
    expected = load_expected(corpus / "expected.json")
    query_dir = corpus / "codeql"
    database = output / "database"
    query_names = {
        "value_flow": query_dir / "origin-to-probe.ql",
        "taint_flow": query_dir / "origin-to-probe-taint.ql",
        "constants": query_dir / "origin-constants.ql",
    }

    pack_install = run_command(
        [str(codeql), "pack", "install", "--search-path", str(Path.home() / ".codeql/packages")],
        query_dir,
        output / "pack-install.stdout.log",
        output / "pack-install.stderr.log",
        args.timeout,
    )
    if pack_install["returncode"] != 0:
        result = {"status": "setup-failed", "pack_install": pack_install, "evidence": str(output)}
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return 1

    swift_build_root = output / "runtime-swift-build"
    runtime_build = run_command(
        ["swift", "build", "--scratch-path", str(swift_build_root)],
        corpus,
        output / "runtime-build.stdout.log",
        output / "runtime-build.stderr.log",
        args.timeout,
    )
    if runtime_build["returncode"] != 0:
        result = {"status": "runtime-build-failed", "pack_install": pack_install, "runtime_build": runtime_build, "evidence": str(output)}
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return 1
    runtime_binary = find_binary(swift_build_root)
    runtime = run_command(
        [str(runtime_binary)], corpus, output / "runtime.stdout.log", output / "runtime.stderr.log", args.timeout
    )
    try:
        observations = parse_runtime(output / "runtime.stdout.log")
        runtime_parse_error = None
    except ValueError as error:
        observations = {}
        runtime_parse_error = str(error)

    build_command, direct_binary = command_for_build(args.build_method, corpus, output)
    database_create = run_command(
        [str(codeql), "database", "create", "--language", "swift", "--source-root", str(corpus), "--command", shlex.join(build_command), str(database)],
        corpus,
        output / "database-create.stdout.log",
        output / "database-create.stderr.log",
        args.timeout,
    )
    build_evidence = {"method": args.build_method, "command": build_command, "expected_binary": str(direct_binary), "create": database_create}
    query_compiles: dict[str, Any] = {}
    query_results: dict[str, Any] = {}
    if database_create["returncode"] == 0:
        for name, query in query_names.items():
            query_compiles[name] = run_command(
                [str(codeql), "query", "compile", str(query)],
                query_dir,
                output / f"query-compile-{name}.stdout.log",
                output / f"query-compile-{name}.stderr.log",
                args.timeout,
            )
        if all(item["returncode"] == 0 for item in query_compiles.values()):
            for name, query in query_names.items():
                runs: list[dict[str, Any]] = []
                for index in range(1, args.runs + 1):
                    bqrs = output / f"{name}-{index}.bqrs"
                    csv_path = output / f"{name}-{index}.csv"
                    query_run = run_command(
                        [str(codeql), "query", "run", "--database", str(database), "--output", str(bqrs), str(query)],
                        query_dir,
                        output / f"{name}-{index}.stdout.log",
                        output / f"{name}-{index}.stderr.log",
                        args.timeout,
                    )
                    decode = None
                    parsed = {"columns": [], "rows": [], "pairs": []}
                    if query_run["returncode"] == 0:
                        decode = run_command(
                            [str(codeql), "bqrs", "decode", "--format", "csv", "--output", str(csv_path), str(bqrs)],
                            query_dir,
                            output / f"{name}-{index}-decode.stdout.log",
                            output / f"{name}-{index}-decode.stderr.log",
                            args.timeout,
                        )
                        if decode["returncode"] == 0:
                            parsed = parse_bqrs_csv(csv_path)
                    runs.append({"run": query_run, "decode": decode, "parsed": parsed})
                query_results[name] = {
                    "runs": runs,
                    "pairs": runs[0]["parsed"]["pairs"] if runs and runs[0]["run"]["returncode"] == 0 else [],
                    "rows": runs[0]["parsed"]["rows"] if runs and runs[0]["run"]["returncode"] == 0 else [],
                    "parse_errors": [
                        f"run {index + 1}: query or decode failed"
                        for index, item in enumerate(runs)
                        if item["run"]["returncode"] != 0
                        or item["decode"] is None
                        or item["decode"]["returncode"] != 0
                    ],
                    "stable": all(item["parsed"]["pairs"] == runs[0]["parsed"]["pairs"] for item in runs[1:]) if runs else False,
                }

    runtime_ok = runtime["returncode"] == 0 and runtime_parse_error is None and not compare(
        expected, observations, {}, score_allowed=False
    ).get("runtime", {}).get("mismatches")
    extraction_ok = database_create["returncode"] == 0
    compile_ok = bool(query_compiles) and all(item["returncode"] == 0 for item in query_compiles.values())
    queries_ok = compile_ok and all(result.get("stable") and all(item["run"]["returncode"] == 0 and item["decode"]["returncode"] == 0 for item in result.get("runs", [])) for result in query_results.values())
    comparison = compare(expected, observations, query_results, score_allowed=runtime_ok and extraction_ok and queries_ok)
    if runtime_ok and extraction_ok and queries_ok:
        status = "ok"
    elif not runtime_ok:
        status = "runtime-failed"
    elif database_create["timed_out"]:
        status = "extraction-timeout"
    elif not extraction_ok:
        status = "extraction-failed"
    else:
        status = "query-failed"
    result = {
        "status": status,
        "codeql": str(codeql),
        "codeql_version": run_command([str(codeql), "version"], corpus, output / "codeql-version.stdout.log", output / "codeql-version.stderr.log", args.timeout),
        "swift_version": run_command(["swift", "--version"], corpus, output / "swift-version.stdout.log", output / "swift-version.stderr.log", args.timeout),
        "pack_install": pack_install,
        "pack_lock": str(query_dir / "codeql-pack.lock.yml"),
        "corpus": str(corpus),
        "build": build_evidence,
        "runtime_build": runtime_build,
        "runtime": runtime,
        "runtime_parse_error": runtime_parse_error,
        "database": database_create,
        "query_compiles": query_compiles,
        "query_results": query_results,
        "comparison": comparison,
        "checks": {"runtime_ok": runtime_ok, "extraction_ok": extraction_ok, "compile_ok": compile_ok, "queries_ok": queries_ok},
        "limitations": [
            "CodeQL CLI 2.26.4 is a separately distributed CLI; the Swift query library is the public codeql/swift-queries pack.",
            "The installed codeql/swift-all 6.8.2 changelog documents Swift 6.3.3 support; this host reports Swift 6.4.0. This is a compatibility boundary to investigate, not proof that the timeout was caused by the compiler version.",
        ],
        "evidence": str(output),
    }
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if status == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
