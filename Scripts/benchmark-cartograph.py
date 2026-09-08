#!/usr/bin/env python3
"""Benchmark Cartograph's value-flow command against the Swift runtime oracle.

SwiftPM compilation, runtime execution, and Cartograph extraction are measured separately.
The complete command output is kept in the evidence directory; the result summary contains
tool versions, timings, mappings, and score data without embedding source paths in mappings.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


LABEL_LINE = re.compile(r"^(?P<label>[A-Za-z0-9_-]+)=(?P<value>.*)$")
ORIGINS = {"origin-A", "origin-B"}


def run_command(
    command: list[str],
    cwd: Path,
    stdout_path: Path,
    stderr_path: Path,
    timeout_s: int = 300,
) -> dict[str, Any]:
    """Run a command in its own process group and save complete raw output."""
    started = time.perf_counter()
    process: subprocess.Popen[str] | None = None
    timed_out = False
    cleanup = {"sigterm_sent": False, "sigkill_sent": False, "process_exited": False}
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
    stdout_text = stdout if isinstance(stdout, str) else stdout.decode(errors="replace")
    stderr_text = stderr if isinstance(stderr, str) else stderr.decode(errors="replace")
    stdout_path.write_text(stdout_text)
    stderr_path.write_text(stderr_text)
    return {
        "returncode": 124 if timed_out else (process.returncode if process else 1),
        "wall_ms": round((time.perf_counter() - started) * 1000, 2),
        "timed_out": timed_out,
        "timeout_cleanup": cleanup,
    }


def load_expected(path: Path) -> dict[str, list[dict[str, Any]]]:
    """Load the runtime and origin-to-probe oracle."""
    document = json.loads(path.read_text())
    runtime = document.get("runtime")
    flow_oracle = document.get("flow_oracle")
    if not isinstance(runtime, list) or not runtime:
        raise ValueError("expected.json must contain a non-empty runtime array")
    if not isinstance(flow_oracle, list) or not flow_oracle:
        raise ValueError("expected.json must contain a non-empty flow_oracle array")
    return {"runtime": runtime, "flow_oracle": flow_oracle}


def parse_runtime(path: Path) -> dict[str, str]:
    """Parse probe output and reject non-probe lines or duplicate labels."""
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
    """Find the executable produced by the fresh SwiftPM build."""
    candidates = list(build_root.glob("out/Products/*/ValueFlowBenchmark"))
    if len(candidates) != 1:
        raise FileNotFoundError(f"expected one ValueFlowBenchmark executable, found {candidates}")
    return candidates[0]


def find_index_store(build_root: Path) -> tuple[Path, str]:
    """Prefer Swift 6.4's scratch `out` store, then legacy debug index paths."""
    out = build_root / "out"
    if out.is_dir():
        return out, "out"
    candidates = (
        (build_root / ".build/debug/index/store", "debug-index-store"),
        (build_root / ".build/index/store", "index-store"),
    )
    for path, kind in candidates:
        if path.is_dir():
            return path, kind
    raise FileNotFoundError(f"no Swift index store under {build_root}")


def runtime_matches(expected: list[dict[str, Any]], observations: dict[str, str]) -> dict[str, Any]:
    """Compare runtime output separately from static value-flow relations."""
    expected_values = {case["label"]: case["value"] for case in expected}
    mismatches = [
        {"label": label, "expected": value, "actual": observations.get(label)}
        for label, value in sorted(expected_values.items())
        if observations.get(label) != value
    ]
    return {
        "ok": not mismatches and set(observations) == set(expected_values),
        "missing_labels": sorted(set(expected_values) - set(observations)),
        "unexpected_labels": sorted(set(observations) - set(expected_values)),
        "mismatches": mismatches,
    }


def nested_strings(value: Any) -> set[str]:
    """Read strings through Swift Codable's associated-value `_0` wrappers."""
    if isinstance(value, str):
        return {value}
    if isinstance(value, dict):
        values: set[str] = set()
        for child in value.values():
            values.update(nested_strings(child))
        return values
    if isinstance(value, list):
        values: set[str] = set()
        for child in value:
            values.update(nested_strings(child))
        return values
    return set()


def value_strings(value: Any) -> tuple[set[str], list[str], set[str]]:
    """Extract typed string literals, unknown reasons, and origin evidence from a value object."""
    if not isinstance(value, dict):
        return set(), ["malformed-value"], set()
    literals: set[str] = set()
    atoms = value.get("atoms", [])
    if isinstance(atoms, list):
        for atom in atoms:
            literal = atom.get("literal") if isinstance(atom, dict) else None
            if isinstance(literal, dict):
                literals.update(nested_strings(literal.get("_0", literal)))
    unknown = value.get("unknownReasons", [])
    unknown_reasons = [str(reason) for reason in unknown] if isinstance(unknown, list) else ["malformed-unknown"]
    origin_evidence: set[str] = set()
    origins = value.get("origins", [])
    if isinstance(origins, list):
        for origin in origins:
            literal = origin.get("literal") if isinstance(origin, dict) else None
            if isinstance(literal, dict):
                origin_evidence.update(nested_strings(literal.get("_0", literal)))
    return literals, unknown_reasons, origin_evidence


def parse_dataflow(document: dict[str, Any]) -> dict[str, Any]:
    """Map probe contexts to labels and actual literal string values."""
    graph = document.get("graph")
    if not isinstance(graph, dict):
        raise ValueError("dataflow JSON has no graph object")
    contexts = graph.get("contexts")
    if not isinstance(contexts, list):
        raise ValueError("dataflow JSON graph has no contexts array")
    mapped: dict[str, set[str]] = {}
    known_values: dict[str, set[str]] = {}
    unknown: dict[str, list[dict[str, Any]]] = {}
    malformed_contexts: list[str] = []
    selected_context_count = 0
    selected = document.get("selectedContexts")
    selected_ids = set(selected) if isinstance(selected, list) else None
    for index, context in enumerate(contexts):
        if not isinstance(context, dict):
            malformed_contexts.append(f"context[{index}]")
            continue
        if selected_ids is not None and context.get("id") not in selected_ids:
            continue
        selected_context_count += 1
        arguments = context.get("arguments", context.get("args"))
        if not isinstance(arguments, list) or len(arguments) < 2:
            continue
        labels, label_unknown, _ = value_strings(arguments[0])
        values, value_unknown, origin_evidence = value_strings(arguments[1])
        if len(labels) != 1:
            if labels or label_unknown:
                malformed_contexts.append(f"context[{index}]-label")
            continue
        label = next(iter(labels))
        reasons = label_unknown + value_unknown
        if not values and not reasons and isinstance(arguments[1], dict):
            if arguments[1].get("atoms"):
                reasons.append("non-string-value")
            elif not arguments[1].get("unknownReasons"):
                reasons.append("no-known-value")
        known_values.setdefault(label, set()).update(values)
        actual = values & ORIGINS
        if actual and not reasons:
            mapped.setdefault(label, set()).update(actual)
        if reasons:
            unknown.setdefault(label, []).append({
                "context": context.get("id", f"context[{index}]"),
                "reasons": sorted(set(reasons)),
                "literalValues": sorted(values),
                "originEvidence": sorted(origin_evidence),
            })
    return {
        "status": document.get("status"),
        "truncated": bool(graph.get("truncated")),
        "limitations": graph.get("limitations", []),
        "mapped": {label: sorted(origins) for label, origins in sorted(mapped.items())},
        "known_values": {label: sorted(values) for label, values in sorted(known_values.items())},
        "reached_labels": sorted(set(known_values) | set(unknown)),
        "unknown": unknown,
        "malformed_contexts": malformed_contexts,
        "context_count": selected_context_count,
    }


def score_flow(expected: list[dict[str, Any]], mapped: dict[str, list[str]]) -> dict[str, Any]:
    """Score only literal values observed at the probe argument."""
    score_cases = [case for case in expected if case.get("evaluation") == "score"]
    labels = {case["label"] for case in score_cases}
    oracle = {(case["label"], origin) for case in score_cases for origin in case.get("expected_origins", [])}
    observed = {(label, origin) for label, origins in mapped.items() if label in labels for origin in origins}
    tp = sorted(observed & oracle)
    fp = sorted(observed - oracle)
    fn = sorted(oracle - observed)
    return {
        "oracle_pairs": [list(pair) for pair in sorted(oracle)],
        "observed_pairs": [list(pair) for pair in sorted(observed)],
        "tp": len(tp),
        "fp": len(fp),
        "fn": len(fn),
        "true_positive_pairs": [list(pair) for pair in tp],
        "false_positive_pairs": [list(pair) for pair in fp],
        "false_negative_pairs": [list(pair) for pair in fn],
    }


def compare_runtime_values(expected: list[dict[str, Any]], known_values: dict[str, list[str]],
                           unknown: dict[str, Any]) -> dict[str, Any]:
    """Compare statically known string values with the independent runtime oracle."""
    expected_values = {case["label"]: case["value"] for case in expected}
    compared: list[dict[str, Any]] = []
    for label, expected_value in sorted(expected_values.items()):
        values = known_values.get(label, [])
        compared.append({
            "label": label,
            "expected": expected_value,
            "known": values,
            "match": values == [expected_value],
            "comparable": len(values) == 1 and not unknown.get(label),
        })
    return {
        "compared": compared,
        "comparable_count": sum(item["comparable"] for item in compared),
        "match_count": sum(item["comparable"] and item["match"] for item in compared),
    }


def tool_metadata(cartograph: Path, cwd: Path, output: Path) -> dict[str, Any]:
    """Record versions and host architecture without exposing paths in the summary."""
    version = run_command(
        [str(cartograph), "--version"], cwd,
        output / "cartograph-version.stdout.log", output / "cartograph-version.stderr.log"
    )
    swift = run_command(
        ["swift", "--version"], cwd,
        output / "swift-version.stdout.log", output / "swift-version.stderr.log"
    )
    machine = run_command(["uname", "-m"], cwd, output / "uname.stdout.log", output / "uname.stderr.log")
    return {
        "cartograph_version": output_file_text(output / "cartograph-version.stdout.log"),
        "swift_version": output_file_text(output / "swift-version.stdout.log"),
        "architecture": output_file_text(output / "uname.stdout.log"),
        "checks": {"cartograph": version["returncode"], "swift": swift["returncode"], "uname": machine["returncode"]},
    }


def output_file_text(path: Path) -> str:
    """Read short tool metadata output and normalize it for JSON."""
    return path.read_text().strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    default_corpus = Path(__file__).resolve().parents[1] / "Fixtures/ValueFlowBenchmark"
    parser.add_argument("--cartograph", type=Path, default=Path("cartograph"))
    parser.add_argument("--corpus", type=Path, default=default_corpus)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    if args.runs < 3:
        parser.error("--runs must be at least 3")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    corpus = args.corpus.resolve()
    cartograph = args.cartograph.resolve() if args.cartograph.parent != Path(".") else args.cartograph
    if args.output_dir:
        output = args.output_dir.resolve()
    else:
        root = corpus / ".benchmark-results"
        root.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="cartograph-value-flow-", dir=root))
    output.mkdir(parents=True, exist_ok=True)
    expected = load_expected(corpus / "expected.json")
    build_root = output / "swift-build"
    build = run_command(
        ["swift", "build", "--scratch-path", str(build_root)],
        corpus,
        output / "swift-build.stdout.log",
        output / "swift-build.stderr.log",
        args.timeout,
    )
    result: dict[str, Any] = {
        "status": "build-failed",
        "tool": tool_metadata(cartograph, corpus, output),
        "build": build,
        "runtime": None,
        "queries": [],
        "score_status": "unscored-build-failure",
        "evidence": str(output),
    }
    if build["returncode"] != 0:
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return 1

    binary = find_binary(build_root)
    runtime = run_command(
        [str(binary)], corpus, output / "runtime.stdout.log", output / "runtime.stderr.log", args.timeout
    )
    try:
        observations = parse_runtime(output / "runtime.stdout.log")
        runtime_parse_error = None
    except ValueError as error:
        observations = {}
        runtime_parse_error = str(error)
    runtime_result = runtime_matches(expected["runtime"], observations)
    index_store, index_kind = find_index_store(build_root)
    query_runs: list[dict[str, Any]] = []
    for run_index in range(1, args.runs + 1):
        raw = output / f"dataflow-{run_index}.stdout.log"
        error_log = output / f"dataflow-{run_index}.stderr.log"
        query = run_command(
            [str(cartograph), "dataflow", "probe", "--project", str(corpus), "--index-store", str(index_store)],
            corpus,
            raw,
            error_log,
            args.timeout,
        )
        document: dict[str, Any] | None = None
        parsed: dict[str, Any] | None = None
        parse_error: str | None = None
        if query["returncode"] == 0:
            try:
                document = json.loads(raw.read_text())
                if not isinstance(document, dict):
                    raise ValueError("dataflow output is not a JSON object")
                parsed = parse_dataflow(document)
            except (json.JSONDecodeError, ValueError) as error:
                parse_error = str(error)
        query_runs.append({"run": query, "parsed": parsed, "parse_error": parse_error})

    parsed_runs = [item["parsed"] for item in query_runs if item["parsed"] is not None]
    stable = bool(parsed_runs) and all(item == parsed_runs[0] for item in parsed_runs[1:])
    expected_labels = {case["label"] for case in expected["flow_oracle"]}
    mapped = parsed_runs[0]["mapped"] if parsed_runs else {}
    reached_labels = parsed_runs[0]["reached_labels"] if parsed_runs else []
    missing_labels = sorted(expected_labels - set(reached_labels))
    extraction_failure = any(
        item["run"]["returncode"] != 0 or item["parse_error"] is not None for item in query_runs
    ) or len(parsed_runs) != args.runs or not stable or any(
        item.get("status") != "found" or item.get("malformed_contexts") for item in parsed_runs
    )
    truncated = any(item.get("truncated") for item in parsed_runs)
    score_status = "scored"
    if extraction_failure:
        score_status = "unscored-extraction-failure"
    elif truncated:
        score_status = "unscored-truncated"
    elif missing_labels:
        score_status = "unscored-missing-labels"
    elif not runtime_result["ok"]:
        score_status = "unscored-runtime-mismatch"
    score = score_flow(expected["flow_oracle"], mapped) if score_status == "scored" else None
    result.update({
        "status": "ok" if score_status == "scored" else score_status,
        "runtime": {"command": runtime, "oracle": runtime_result, "parse_error": runtime_parse_error},
        "index_store_kind": index_kind,
        "queries": query_runs,
        "query_stable": stable,
        "missing_labels": missing_labels,
        "unknown_contexts": parsed_runs[0]["unknown"] if parsed_runs else {},
        "malformed_contexts": parsed_runs[0]["malformed_contexts"] if parsed_runs else [],
        "reached_labels": reached_labels,
        "known_values": parsed_runs[0]["known_values"] if parsed_runs else {},
        "runtime_value_comparison": compare_runtime_values(
            expected["runtime"], parsed_runs[0]["known_values"] if parsed_runs else {},
            parsed_runs[0]["unknown"] if parsed_runs else {}
        ),
        "score_status": score_status,
        "score": score,
    })
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
