#!/usr/bin/env python3
"""Verify positive, broken, missing and stale contracts with the real Foundation runtime."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-runtime-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "project"
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/RuntimeContractCorpus"
    shutil.copytree(corpus, project, ignore=shutil.ignore_patterns(".build"))
    scratch = output / "build"
    contracts = project / "runtime-contracts.json"

    def run(command, name, expected=0):
        process = subprocess.run(command, cwd=project, capture_output=True, text=True, timeout=180)
        (output / (name + ".stdout.log")).write_text(process.stdout)
        (output / (name + ".stderr.log")).write_text(process.stderr)
        if process.returncode != expected:
            raise RuntimeError(f"{name}: expected exit {expected}, got {process.returncode}; see {output}")
        return process.stdout

    build_args = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch)]
    run(build_args, "build-positive")
    bin_path = Path(run(build_args + ["--show-bin-path"], "bin-path").strip())
    candidates = [scratch / "out", scratch / "index/store", bin_path / "index/store"]
    store = next((path for path in candidates if path.is_dir()), None)
    if store is None:
        raise RuntimeError(f"No compiler index in {scratch}")
    executable = bin_path / "RuntimeProbe"
    common = [
        "--project", str(project), "--index-store", str(store),
        "--contracts", str(contracts), "--executable", str(executable),
    ]

    def plan(name, expected=0):
        return json.loads(run([str(binary), "runtime", "plan", "--strict"] + common, name, expected))

    def check(observations, name, expected=0):
        path = output / (name + ".observations.json")
        path.write_text(json.dumps(observations))
        return json.loads(run([str(binary), "runtime", "check", "--strict", "--observations", str(path)]
                              + common, name, expected))

    positive_plan = plan("positive-plan")
    observed = json.loads(run([str(executable), positive_plan["fingerprint"]], "positive-execution"))
    assert observed["executableFingerprint"] == positive_plan["executableFingerprint"], observed
    positive = check(observed, "positive-check")
    assert positive["status"] == "verified" and positive["verifiedCount"] == 2, positive
    empty = dict(observed, observations=[])
    incomplete = check(empty, "empty-check", expected=1)
    assert incomplete["status"] == "incomplete" and incomplete["unverifiedCount"] == 2

    source = project / "Sources/RuntimeProbe/main.swift"
    source.write_text(source.read_text().replace('NSSelectorFromString("open")', 'NSSelectorFromString("missingOpen")'))
    run(build_args, "build-broken-selector")
    stale = check(observed, "stale-check", expected=2)
    assert stale["status"] == "stale" and stale["verifiedCount"] == 0
    broken_plan = plan("broken-plan")
    spoofed = dict(observed, planFingerprint=broken_plan["fingerprint"])
    stale_executable = check(spoofed, "stale-executable", expected=2)
    assert stale_executable["status"] == "stale", stale_executable
    broken_observed = json.loads(run([str(executable), broken_plan["fingerprint"]], "broken-execution"))
    broken = check(broken_observed, "broken-check", expected=1)
    statuses = {row["contractID"]: row["status"] for row in broken["bindings"]}
    assert statuses == {"selector-route": "failed", "screen-registration": "observed"}, statuses

    source.write_text(source.read_text().replace('    @objc func open() -> NSString { "opened" }\n', ""))
    run(build_args, "build-removed-target")
    missing = plan("removed-target-plan", expected=1)
    assert any(row["contractID"] == "selector-route" and row["status"] == "missingTarget"
               for row in missing["bindings"]), missing
    result = {"status": "passed", "verified": 2, "broken_selector_exit": 1,
              "empty_observations_exit": 1, "stale_observations_exit": 2,
              "stale_executable_exit": 2, "removed_target_exit": 1}
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    print(f"Evidence: {output}")


if __name__ == "__main__":
    main()
