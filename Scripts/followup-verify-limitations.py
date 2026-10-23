#!/usr/bin/env python3
"""Compare the frozen candidate's missing JSON summary option with native CLI output.

Uses an already built/indexed synthetic or repository input. Does not build, run user
code, or claim app-wide recall. Raw commands/stdout/stderr and timings are retained.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def without_presentation(value: object) -> object:
    if isinstance(value, dict):
        return {key: without_presentation(item) for key, item in value.items()
                if key not in {"limitations", "limitationSummary"}}
    if isinstance(value, list):
        return [without_presentation(item) for item in value]
    return value


def compare(full: dict, summary: dict) -> dict:
    if without_presentation(full) != without_presentation(summary):
        raise AssertionError("Summary changed analysis facts outside limitation presentation")
    notes = full.get("limitations")
    assert isinstance(notes, list) and notes and all(isinstance(note, str) for note in notes)
    detail = summary["limitationSummary"]
    assert detail["mode"] == "summary" and detail["noteCount"] == len(notes)
    assert sum(group["noteCount"] for group in detail["groups"]) == len(notes)
    assert summary["limitations"] and any("not a safety guarantee" in note for note in summary["limitations"])
    assert any(group["code"] == "configured-path-filter" for group in detail["groups"])
    return {"originalNoteCount": len(notes), "groupCount": detail["groupCount"],
            "detailsOmitted": detail["detailsOmitted"], "allOtherFactsIdentical": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    records: dict[str, dict] = {}

    def run(label: str, binary: Path, arguments: list[str]) -> tuple[int, bytes, bytes]:
        command = [str(binary.resolve()), *arguments]
        started = time.monotonic()
        with (args.output / (label + ".stdout")).open("wb") as stdout, \
                (args.output / (label + ".stderr")).open("wb") as stderr:
            completed = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=300, check=False)
        records[label] = {"command": command, "exitCode": completed.returncode,
                          "seconds": time.monotonic() - started}
        (args.output / "commands.json").write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
        return completed.returncode, (args.output / (label + ".stdout")).read_bytes(), \
            (args.output / (label + ".stderr")).read_bytes()

    query = ["query", "__cartograph_followup_summary_missing__", "--project", str(args.project.resolve()),
             "--include", "Sources/**"]
    default_code, default, _ = run("candidate-default", args.candidate, query)
    full_code, full, _ = run("candidate-full", args.candidate, query + ["--limitations", "full"])
    summary_code, summary, _ = run("candidate-summary", args.candidate, query + ["--limitations", "summary"])
    baseline_code, _, baseline_error = run("frozen-summary", args.baseline,
                                          query + ["--limitations", "summary"])
    assert default_code == full_code == summary_code == 64, "notFound remains usage error 64"
    assert default == full, "Default full must preserve exact bytes"
    assert baseline_code == 64 and b"--limitations" in baseline_error and b"Unknown option" in baseline_error
    checked = compare(json.loads(full), json.loads(summary))
    rejected_code, rejected, rejected_error = run("snapshot-rejected", args.candidate,
        ["snapshot", "--project", "/__cartograph_missing_project__", "--limitations", "summary"])
    assert rejected_code == 64 and not rejected and b"require --limitations full" in rejected_error
    result = {"status": "passed", "baselineSHA256": digest(args.baseline),
              "candidateSHA256": digest(args.candidate), "baselineSummary": "unsupported-option-reproduced",
              "defaultFullByteIdentical": True, "notFoundExitPreserved": True,
              "snapshotRejectedBeforeAnalysis": True, "summary": checked, "commands": records,
              "limitations": ["Presentation-only validation on the supplied indexed input; not application recall.",
                              "Command timings include native CLI preparation; prior build preparation is excluded."]}
    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "passed", "summary": checked}, sort_keys=True))


if __name__ == "__main__":
    main()
