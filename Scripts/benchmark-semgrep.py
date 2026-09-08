#!/usr/bin/env python3
"""값 전파 코퍼스를 빌드하고 Semgrep CE를 런타임 정답과 비교한다.

Swift 컴파일·프로그램 실행·Semgrep 추출을 별도 측정하며, 로그인하거나
소스를 로컬 밖으로 보내지 않는다.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


LABEL_LINE = re.compile(r"^(?P<label>[A-Za-z0-9_-]+)=(?P<value>.*)$")


def run_command(command: list[str], cwd: Path, stdout_path: Path, stderr_path: Path) -> dict[str, Any]:
    """로컬 명령 하나를 실행하고 출력과 벽시계 시간을 기록한다."""
    started = time.perf_counter()
    try:
        process = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False, timeout=300)
        stdout = process.stdout
        stderr = process.stderr
        returncode = process.returncode
        timed_out = False
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        returncode = 124
        timed_out = True
    elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
    stdout_path.write_text(stdout if isinstance(stdout, str) else stdout.decode(errors="replace"))
    stderr_path.write_text(stderr if isinstance(stderr, str) else stderr.decode(errors="replace"))
    return {"command": command, "returncode": returncode, "wall_ms": elapsed_ms, "timed_out": timed_out}


def load_expected(path: Path) -> dict[str, list[dict[str, Any]]]:
    """런타임 정답과 명시적 값 전파 정답을 분리해 읽는다."""
    document = json.loads(path.read_text())
    runtime = document.get("runtime")
    flow_oracle = document.get("flow_oracle")
    if not isinstance(runtime, list) or not runtime:
        raise ValueError("expected.json must contain a non-empty runtime array")
    if not isinstance(flow_oracle, list) or not flow_oracle:
        raise ValueError("expected.json must contain a non-empty flow_oracle array")
    return {"runtime": runtime, "flow_oracle": flow_oracle}


def parse_runtime(path: Path) -> dict[str, str]:
    """probe 출력을 파싱하고 probe가 아닌 줄은 잘못된 증거로 거부한다."""
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
    """Xcode 형식 scratch 출력에서 SwiftPM 실행 파일을 찾는다."""
    candidates = list(build_root.glob("out/Products/*/ValueFlowBenchmark"))
    if len(candidates) != 1:
        raise FileNotFoundError(f"expected one built executable, found {candidates}")
    return candidates[0]


def semgrep_pair(result: dict[str, Any]) -> tuple[str, str] | None:
    """Semgrep 결과 하나에서 origin-to-probe 쌍을 뽑는다."""
    rule_id = result.get("check_id", "")
    if "origin-a" in rule_id:
        origin = "origin-A"
    elif "origin-b" in rule_id:
        origin = "origin-B"
    else:
        return None
    metavars = result.get("extra", {}).get("metavars", {})
    label = metavars.get("$LABEL", {}).get("abstract_content")
    if not label:
        return None
    try:
        label = json.loads(label)
    except json.JSONDecodeError:
        return None
    if not isinstance(label, str):
        return None
    return label, origin


def parse_semgrep(path: Path) -> dict[str, Any]:
    """JSON 추출 하나를 읽고 taint·literal·union 쌍을 분리한다."""
    try:
        document = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        return {
            "parse_ok": False,
            "findings": [],
            "taint_pairs": [],
            "literal_pairs": [],
            "union_pairs": [],
            "errors": [f"invalid JSON: {error}"],
            "scanned": [],
            "skipped": [],
        }
    results = document.get("results", [])
    findings = []
    extraction_errors = []
    for result in results:
        pair = semgrep_pair(result)
        if pair is None:
            extraction_errors.append({"check_id": result.get("check_id"), "reason": "missing sink label"})
            continue
        rule_id = result.get("check_id", "")
        kind = "literal" if "literal" in rule_id else "taint"
        findings.append({"pair": list(pair), "kind": kind, "rule_id": rule_id})
    taint_pairs = sorted({tuple(item["pair"]) for item in findings if item["kind"] == "taint"})
    literal_pairs = sorted({tuple(item["pair"]) for item in findings if item["kind"] == "literal"})
    paths = document.get("paths", {})
    return {
        "parse_ok": not extraction_errors,
        "findings": findings,
        "taint_pairs": [list(pair) for pair in taint_pairs],
        "literal_pairs": [list(pair) for pair in literal_pairs],
        "union_pairs": [list(pair) for pair in sorted(set(taint_pairs) | set(literal_pairs))],
        "errors": document.get("errors", []) + extraction_errors,
        "scanned": paths.get("scanned", []),
        "skipped": paths.get("skipped", []),
        "finding_count": len(results),
        "version": document.get("version"),
        "engine": document.get("engine_requested"),
    }


def pair_score(
    expected: set[tuple[str, str]], observed: list[list[str]], labels: set[str]
) -> dict[str, Any]:
    """발견 집합 하나를 명시한 origin 쌍과 비교한다."""
    observed_set = {tuple(pair) for pair in observed if pair[0] in labels}
    true_positive = sorted(observed_set & expected)
    false_positive = sorted(observed_set - expected)
    false_negative = sorted(expected - observed_set)
    return {
        "evaluated_labels": sorted(labels),
        "oracle_pairs": [list(pair) for pair in sorted(expected)],
        "observed_pairs": [list(pair) for pair in sorted(observed_set)],
        "tp": len(true_positive),
        "fp": len(false_positive),
        "fn": len(false_negative),
        "true_positive_pairs": [list(pair) for pair in true_positive],
        "false_positive_pairs": [list(pair) for pair in false_positive],
        "false_negative_pairs": [list(pair) for pair in false_negative],
    }


def runtime_oracle_matches(runtime_cases: list[dict[str, Any]], observations: dict[str, str]) -> bool:
    """검토한 label과 값이 정확히 맞을 때만 전파 점수를 계산한다."""
    expected = {case["label"]: case["value"] for case in runtime_cases}
    return observations == expected


def compare(
    runtime_cases: list[dict[str, Any]],
    flow_cases: list[dict[str, Any]],
    observations: dict[str, str],
    semgrep: dict[str, Any],
    score_allowed: bool,
) -> dict[str, Any]:
    """런타임 label을 검증하고 Semgrep 결과 집합마다 별도로 점수를 낸다."""
    expected_labels = {case["label"] for case in runtime_cases}
    missing_labels = sorted(expected_labels - observations.keys())
    unexpected_labels = sorted(observations.keys() - expected_labels)
    runtime_mismatches = [
        {"label": case["label"], "expected": case["value"], "actual": observations.get(case["label"])}
        for case in runtime_cases
        if observations.get(case["label"]) != case["value"]
    ]
    score_cases = [case for case in flow_cases if case["evaluation"] == "score"]
    score_labels = {case["label"] for case in score_cases}
    oracle = {
        (case["label"], origin)
        for case in score_cases
        for origin in case["expected_origins"]
    }
    score_names = ("taint_only", "literal_only", "union")
    observed_sets = {
        "taint_only": semgrep.get("taint_pairs", []),
        "literal_only": semgrep.get("literal_pairs", []),
        "union": semgrep.get("union_pairs", []),
    }
    scores: dict[str, Any]
    if score_allowed:
        scores = {name: pair_score(oracle, observed, score_labels) for name, observed in observed_sets.items()}
    else:
        scores = {name: None for name in score_names}
    unsupported_labels = sorted(case["label"] for case in flow_cases if case["evaluation"] == "unsupported")
    unsupported_set = set(unsupported_labels)
    return {
        "runtime": {
            "missing_labels": missing_labels,
            "unexpected_labels": unexpected_labels,
            "mismatches": runtime_mismatches,
        },
        "flow_oracle": {
            "score_labels": sorted(score_labels),
            "expected_pairs": [list(pair) for pair in sorted(oracle)],
        },
        "score_status": "scored" if score_allowed else "unscored",
        "score": scores,
        "unsupported": {
            "labels": unsupported_labels,
            "observed_pairs_excluded_from_score": [
                pair for pair in semgrep.get("union_pairs", []) if pair[0] in unsupported_set
            ],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    default_corpus = Path(__file__).resolve().parents[1] / "Fixtures/ValueFlowBenchmark"
    parser.add_argument("--corpus", type=Path, default=default_corpus)
    parser.add_argument("--semgrep", type=Path, default=Path("/opt/homebrew/bin/semgrep"))
    parser.add_argument("--runs", type=int, default=3, help="Semgrep extraction repetitions (minimum: 3)")
    parser.add_argument("--output-dir", type=Path, help="Evidence directory; defaults to a temporary directory")
    args = parser.parse_args()
    if args.runs < 3:
        parser.error("--runs must be at least 3")

    corpus = args.corpus.resolve()
    semgrep = args.semgrep.resolve()
    if args.output_dir:
        output = args.output_dir.resolve()
    else:
        evidence_root = corpus / ".benchmark-results"
        evidence_root.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="cartograph-value-flow-", dir=evidence_root))
    output.mkdir(parents=True, exist_ok=True)
    build_root = output / "swift-build"
    expected = load_expected(corpus / "expected.json")

    build = run_command(
        ["swift", "build", "--scratch-path", str(build_root)],
        corpus,
        output / "swift-build.stdout.log",
        output / "swift-build.stderr.log",
    )
    if build["returncode"] != 0:
        result = {"status": "build-failed", "build": build, "evidence": str(output)}
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return 1

    binary = find_binary(build_root)
    runtime = run_command(
        [str(binary)], corpus, output / "runtime.stdout.log", output / "runtime.stderr.log"
    )
    runtime_parse_error = None
    try:
        observations = parse_runtime(output / "runtime.stdout.log")
    except ValueError as error:
        observations = {}
        runtime_parse_error = str(error)

    semgrep_runs: list[dict[str, Any]] = []
    for index in range(1, args.runs + 1):
        json_path = output / f"semgrep-{index}.json"
        command_result = run_command(
            [
                str(semgrep),
                "scan",
                "--config",
                str(corpus / "rules/origin-to-probe.yml"),
                "--metrics=off",
                "--disable-version-check",
                "--json",
                "--quiet",
                "Sources",
            ],
            corpus,
            json_path,
            output / f"semgrep-{index}.stderr.log",
        )
        parsed = parse_semgrep(json_path)
        parsed["command"] = command_result["command"]
        parsed["returncode"] = command_result["returncode"]
        parsed["wall_ms"] = command_result["wall_ms"]
        semgrep_runs.append(parsed)

    first = semgrep_runs[0]
    stable = all(run["union_pairs"] == first["union_pairs"] for run in semgrep_runs[1:])
    swift_files = sorted(str(path.relative_to(corpus)) for path in (corpus / "Sources").rglob("*.swift"))
    expected_scanned = swift_files
    scanned_sets_match = all(sorted(run.get("scanned", [])) == expected_scanned for run in semgrep_runs)
    coverage = {
        "swift_files": swift_files,
        "scanned_files": first.get("scanned", []),
        "skipped": first.get("skipped", []),
        "scanned_count": len(first.get("scanned", [])),
        "swift_file_count": len(swift_files),
        "percent": round(100 * len(first.get("scanned", [])) / len(swift_files), 2) if swift_files else 0,
        "errors": [run.get("errors", []) for run in semgrep_runs],
        "expected_set_match": scanned_sets_match,
    }
    errors: list[Any] = []
    if runtime_parse_error:
        errors.append(f"runtime parse error: {runtime_parse_error}")
    errors.extend(error for run in semgrep_runs for error in run.get("errors", []))
    for run in semgrep_runs:
        if run["returncode"] != 0:
            errors.append(f"Semgrep return code {run['returncode']}")
        if not run.get("parse_ok", False):
            errors.append("Semgrep result extraction failed")
    if not scanned_sets_match:
        errors.append("Semgrep scanned file set differs from corpus Swift files")
    if runtime["returncode"] != 0:
        errors.append(f"Swift runtime return code {runtime['returncode']}")
    runtime_ok = (
        runtime["returncode"] == 0
        and not runtime_parse_error
        and runtime_oracle_matches(expected["runtime"], observations)
    )
    analysis_ok = not errors and stable
    comparison = compare(
        expected["runtime"],
        expected["flow_oracle"],
        observations,
        first,
        score_allowed=runtime_ok and analysis_ok,
    )
    status = "ok" if runtime_ok and analysis_ok and not comparison["runtime"]["mismatches"] else "failed"
    result = {
        "status": status,
        "corpus": str(corpus),
        "semgrep": str(semgrep),
        "build": build,
        "runtime": runtime,
        "comparison": comparison,
        "semgrep_runs": semgrep_runs,
        "semgrep_stable_across_runs": stable,
        "parse_coverage": coverage,
        "checks": {
            "runtime_ok": runtime_ok,
            "runtime_parse_error": runtime_parse_error,
            "analysis_ok": analysis_ok,
            "errors": errors,
        },
        "evidence": str(output),
    }
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if status == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
