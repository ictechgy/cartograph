#!/usr/bin/env python3
"""Collect C-P1-2 public/candidate compiler evidence; --diagnose never claims a fix."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys

MAX_OUTPUT = 16 * 1024 * 1024
LIVE = ("TopLevelPublisher.swift", "NestedPublisher.swift")


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def alias_lines(source):
    return {number for number, line in enumerate(source.splitlines(), 1)
            if line.strip().startswith("typealias ")}


def completed_exit(receipt, expected):
    code = receipt.get("returncode")
    if (receipt.get("timed_out") or receipt.get("output_limit_exceeded") or receipt.get("cleanup_errors")
            or receipt.get("ownership_lost") or receipt.get("exception_type")
            or receipt.get("owned_root_reaped") is not True or not isinstance(code, int) or code < 0):
        raise ValueError("Incomplete subprocess evidence is not a compiler result")
    if expected is not None and code not in expected:
        raise ValueError(f"Unexpected command exit {code}")
    return code


def classify(document, sources):
    diagnostics = document.get("diagnostics")
    if not isinstance(diagnostics, list) or document.get("suppressedCount") != 0:
        raise ValueError("Expected unsuppressed dead report")
    limitations = document.get("limitations", [])
    if not isinstance(limitations, list) or any(not isinstance(value, str) for value in limitations):
        raise ValueError("Expected explicit limitation strings")
    if any(str(value).startswith("empty-index:") for value in limitations):
        raise ValueError("Empty index cannot establish witness behavior")
    unused = {(Path(item["location"]["path"]).name, item["location"]["line"])
              for item in diagnostics if item["ruleIdentifier"] == "unused-symbol" and item.get("location")}
    required = {(name, line) for name in LIVE for line in alias_lines(sources[name])}
    unrelated = {("Unrelated.swift", line) for line in alias_lines(sources["Unrelated.swift"])}
    dead_line = next(number for number, line in enumerate(sources["DeadPublisher.swift"].splitlines(), 1)
                     if line.startswith("struct DeadForwarder"))
    return {"requiredAliasFalsePositives": [list(value) for value in sorted(required & unused)],
            "unrelatedAliasesStillReported": unrelated <= unused,
            "deadOwnerStillReported": ("DeadPublisher.swift", dead_line) in unused,
            "unusedLocations": [list(value) for value in sorted(unused)], "limitations": limitations}


def behavior_satisfied(public, candidate):
    """This complete controlled fixture cannot certify behavior from incomplete observations."""
    return (len(public["requiredAliasFalsePositives"]) == 4
            and not public["limitations"] and not candidate["limitations"]
            and not candidate["requiredAliasFalsePositives"]
            and candidate["unrelatedAliasesStillReported"] and candidate["deadOwnerStillReported"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True, help="Verified official 0.28.0 executable")
    parser.add_argument("--output", type=Path, required=True, help="New directory; no previous evidence overwritten")
    parser.add_argument("--diagnose", action="store_true", help="Collect unresolved candidate evidence without a pass claim")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native macOS/Combine compiler required")
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("witness_measurement", repo / "Scripts/benchmark-indexstore-cli.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    result = {"id": "C-P1-2", "status": "incomplete", "cases": {}, "mutations": [],
              "scope": "generalized native Combine fixture; not the reported company workspace",
              "limitations": ["Raw occurrence diagnostics must be reviewed before choosing a witness inference."]}

    def run(command, cwd, label, expected=(0,)):
        stem = output / "logs" / label
        try:
            native.run(list(map(str, command)), cwd, stem, 180, stream_limit=MAX_OUTPUT)
        except RuntimeError:
            # Intentional compiler mutation failures are accepted only with a completed receipt.
            if not Path(str(stem) + ".json").is_file():
                raise
        receipt = json.loads(Path(str(stem) + ".json").read_text())
        code = completed_exit(receipt, expected)
        return Path(receipt["stdout"]).read_text(encoding="utf-8"), code

    try:
        result["candidateCommit"] = run(["git", "rev-parse", "HEAD"], repo, "candidate-head")[0].strip()
        result["toolchain"] = run(["swift", "--version"], repo, "toolchain")[0].strip()
        fixture = output / "fixture"
        shutil.copytree(repo / "Fixtures/FalsePositiveCorpus/AssociatedWitness", fixture)
        source_root = fixture / "Sources/WitnessApp"
        sources = {path.name: path.read_text(encoding="utf-8") for path in source_root.glob("*.swift")}
        run(["swift", "build", "--jobs", "3"], fixture, "build-before")
        candidates = [fixture / ".build/debug/index/store", *sorted((fixture / ".build").glob("*/debug/index/store"))]
        stores = sorted({path.resolve() for path in candidates if (path / "v5/units").is_dir()})
        if len(stores) != 1:
            raise ValueError(f"Expected one compiler index: {stores}")
        captured = native.fingerprint(stores[0])
        result["compilerIndex"] = captured
        result["sourceSHA256"] = {name: hashlib.sha256(text.encode()).hexdigest() for name, text in sources.items()}
        for label, binary in [("public028", args.baseline.resolve()), ("candidate", args.cartograph.resolve())]:
            version = run([binary, "--version"], fixture, label + "-version")[0].strip()
            if label == "public028" and "0.28.0" not in version:
                raise ValueError("Public baseline must be official version 0.28.0")
            report = json.loads(run([binary, "dead", "--report-format", "json", "--project", fixture,
                                     "--index-store", stores[0]], fixture, label + "-dead")[0])
            result["cases"][label] = {"version": version, "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                                      **classify(report, sources)}
        if native.fingerprint(stores[0]) != captured:
            raise ValueError("Compiler index changed during paired analysis")
        for name in LIVE:
            for alias in ["Output", "Failure"]:
                path = source_root / name
                old = sources[name]
                changed = "\n".join(line for line in old.splitlines()
                                    if not line.strip().startswith(f"typealias {alias} =")) + "\n"
                if changed == old:
                    raise ValueError("Mutation did not remove the target declaration")
                path.write_text(changed, encoding="utf-8")
                try:
                    _, code = run(["swift", "build", "--jobs", "3"], fixture,
                                  name + "-remove-" + alias, expected=None)
                    result["mutations"].append({"file": name, "removedAlias": alias, "buildExit": code})
                    if code == 0:
                        raise ValueError(f"Required alias deletion unexpectedly compiled: {name}/{alias}")
                    failure = (output / "logs" / (name + "-remove-" + alias + ".stderr")).read_text(encoding="utf-8")
                    # SwiftPM routes compiler diagnostics to stdout on some toolchains.
                    failure += (output / "logs" / (name + "-remove-" + alias + ".stdout")).read_text(encoding="utf-8")
                    if "does not conform to protocol" not in failure or "Publisher" not in failure:
                        raise ValueError("Mutation failed without the expected Publisher conformance diagnostic")
                finally:
                    path.write_text(old, encoding="utf-8")
        control = source_root / "Unrelated.swift"
        control.write_text("\n".join(line for line in sources[control.name].splitlines()
                                    if not line.strip().startswith("typealias ")) + "\n", encoding="utf-8")
        try:
            run(["swift", "build", "--jobs", "3"], fixture, "remove-unrelated-aliases")
            result["mutations"].append({"file": control.name, "removedAlias": "both unrelated aliases", "buildExit": 0})
        finally:
            control.write_text(sources[control.name], encoding="utf-8")
        run(["swift", "build", "--jobs", "3"], fixture, "restored-build")
        current = result["cases"]["candidate"]
        reproduced = len(result["cases"]["public028"]["requiredAliasFalsePositives"]) == 4
        result["publicReproduced"] = reproduced
        passed = behavior_satisfied(result["cases"]["public028"], current)
        result["status"] = "diagnostic-only" if args.diagnose else ("passed" if passed else "failed")
        result["candidateBehaviorSatisfied"] = passed
        return 0 if args.diagnose or passed else 1
    finally:
        save(output / "results.json", result)
        print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    sys.exit(main())
