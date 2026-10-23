#!/usr/bin/env python3
"""Compile public synthetic controls and verify additive CLI finding review on one capture."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
import time
from pathlib import Path


def verify_documents(plain: dict, summary: dict, generated: dict) -> None:
    """Compare all original fields; an absent finding or limitation is a regression."""
    for changed in (summary, generated):
        original = {key: value for key, value in changed.items() if key != "findingReview"}
        assert original == plain, "optional review changed original JSON fields"
        review = changed["findingReview"]
        assert "diagnostics" not in review, "original diagnostics must not be duplicated"
        assert review["findingCount"] == len(plain["diagnostics"])
        assert review["totalFileCount"] == 3 and review["omittedFileCount"] == 0
        assert sum(file["findingCount"] for file in review["files"]) == len(plain["diagnostics"])
    assert summary["findingReview"]["markerReviewRequested"] is False
    assert summary["findingReview"]["markerBytesRead"] == 0
    assert all("generatedMarker" not in file for file in summary["findingReview"]["files"])
    observed = generated["findingReview"]
    assert observed["markerReviewRequested"] is True
    statuses = {Path(file["path"]).name: file["generatedMarker"]["status"] for file in observed["files"]}
    assert statuses == {"Generated.swift": "markerObserved", "DesignTokens.swift": "noMarkerInHeader",
                        "NeedleGenerated.swift": "noMarkerInHeader"}, statuses
    for file in observed["files"]:
        if file["generatedMarker"]["status"] == "markerObserved":
            assert file["generatedMarker"]["evidence"] == {"line": 1, "text": "// @generated"}
            assert file["generatedMarker"]["fileStableDuringRead"] is True
            assert "retention.retained_files" in file["generatedMarker"]["suggestion"]
        else:
            assert "suggestion" not in file["generatedMarker"]


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def run(binary: Path, output: Path, baseline: Path | None = None) -> None:
    repository = Path(__file__).resolve().parents[1]
    fixture = repository / "Fixtures" / "FollowupGeneratedReview"
    names = ["Generated.swift", "DesignTokens.swift", "NeedleGenerated.swift", "Main.swift"]
    receipt: dict = {"id": "C-P1-7", "status": "running", "commands": [],
                     "scope": "synthetic actual Swift compiler fixture; no private app verification",
                     "baseline_commit": "fae3c24b1776af8d75151663821f8ff221d928f8",
                     "baseline_native_execution": False,
                     "baseline_validation_passed": False,
                     "cartograph_build_cost_included": False,
                     "baseline_build_cost_included": False}
    started = time.perf_counter()

    def invoke(args: list[str], cwd: Path, expected: int = 0) -> str:
        start = time.perf_counter()
        result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=180, check=False)
        receipt["commands"].append({"arguments": args, "returncode": result.returncode,
                                    "seconds": time.perf_counter() - start,
                                    "stdout_sha256": hashlib.sha256(result.stdout.encode()).hexdigest()})
        assert result.returncode == expected, (args, result.returncode, result.stdout[-6000:], result.stderr[-6000:])
        return result.stdout

    try:
        receipt["candidate_source_commit"] = invoke(["git", "rev-parse", "HEAD"], repository).strip()
        receipt["candidate_binary_sha256"] = file_digest(binary)
        receipt["tool_version"] = invoke([str(binary), "--version"], repository).strip()
        if baseline:
            receipt["baseline_binary_sha256"] = file_digest(baseline)
            receipt["baseline_tool_version"] = invoke([str(baseline), "--version"], repository).strip()
        receipt["swift_version"] = invoke(["xcrun", "swiftc", "--version"], repository).strip()
        receipt["fixture_sha256"] = {name: hashlib.sha256((fixture / name).read_bytes()).hexdigest() for name in names}
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="followup-generated-", dir=output.parent) as temporary:
            root = Path(temporary).resolve()
            preparation = time.perf_counter()
            for name in names:
                (root / name).write_bytes((fixture / name).read_bytes())
            store = root / "IndexStore"
            invoke(["xcrun", "swiftc", "-module-name", "GeneratedReview", "-parse-as-library", "-emit-library",
                    *names, "-o", "libGeneratedReview.dylib", "-index-store-path", str(store)], root)
            receipt["fixture_preparation_seconds"] = time.perf_counter() - preparation
            common = ["--project", str(root), "--index-store", str(store)]
            graph_args = [str(binary), "graph", *common, "--level", "symbol", "--format", "json"]
            before_graph = json.loads(invoke(graph_args, root))
            dead = [str(binary), "dead", *common, "--report-format", "json", "--strict"]
            plain = json.loads(invoke(dead, root, 1))
            if baseline:
                baseline_started = time.perf_counter()
                baseline_plain = json.loads(invoke([str(baseline), *dead[1:]], root, 1))
                receipt["baseline_native_execution"] = True
                assert baseline_plain == plain, "candidate default JSON differs from frozen baseline on same capture"
                for flag in ("--file-summary", "--generated-suggestions"):
                    invoke([str(baseline), *dead[1:], flag], root, 64)
                receipt["baseline_execution_seconds"] = time.perf_counter() - baseline_started
                receipt["baseline_validation_passed"] = True
            summary = json.loads(invoke([*dead, "--file-summary"], root, 1))
            generated = json.loads(invoke([*dead, "--generated-suggestions"], root, 1))
            verify_documents(plain, summary, generated)
            unused = [d for d in plain["diagnostics"] if d["ruleIdentifier"] == "unused-symbol"]
            expected = {"GeneratedReview.filenameUnused()", "GeneratedReview.generatedUnused()",
                        "GeneratedReview.manualToken()"}
            assert {d["message"].split("'")[1] for d in unused} == expected
            assert json.loads(invoke(graph_args, root)) == before_graph, "review changed graph output"
            invoke([str(binary), "dead", "--file-summary", "--report-format", "text",
                    "--index-store", str(root / "absent")], root, 64)
            invoke([str(binary), "dead", "--generated-suggestions", "--explain", "x"], root, 64)
            receipt["diagnostic_count"] = len(plain["diagnostics"])
            receipt["unused_names"] = sorted(expected)
            receipt["finding_review"] = generated["findingReview"]
            receipt["default_graph_sha256"] = hashlib.sha256(
                json.dumps(before_graph, sort_keys=True).encode()).hexdigest()
            receipt["status"] = "passed"
    except BaseException as error:
        receipt["status"] = "failed"
        receipt["error"] = str(error)
        raise
    finally:
        receipt["total_seconds_including_fixture_preparation"] = time.perf_counter() - started
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, help="Built frozen fae3c24 binary for same-capture regression")
    options = parser.parse_args()
    run(options.binary.resolve(), options.output.resolve(), options.baseline.resolve() if options.baseline else None)
