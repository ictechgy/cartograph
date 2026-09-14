#!/usr/bin/env python3
"""Verify compiler-backed immutable Swift.Dictionary registry relationships."""

import argparse
from collections import Counter
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()

    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-registry-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/RuntimeRegistryCorpus"
    project = output / "project"
    shutil.copytree(corpus, project, dirs_exist_ok=True)
    binary = args.cartograph.resolve()
    result = {"status": "failed", "output": str(output)}

    def run(command, label, expected=0, cwd=None):
        process = subprocess.run(
            [str(value) for value in command],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=240,
        )
        (output / f"{label}.stdout.log").write_text(process.stdout)
        (output / f"{label}.stderr.log").write_text(process.stderr)
        if process.returncode != expected:
            raise RuntimeError(f"{label}: expected exit {expected}, got {process.returncode}\n{process.stderr[-6000:]}")
        return process.stdout

    def build():
        scratch = output / "fixture-scratch"
        run(["swift", "build", "--package-path", project, "--scratch-path", scratch], "build")
        bin_path = Path(run([
            "swift", "build", "--package-path", project, "--scratch-path", scratch, "--show-bin-path"
        ], "bin").strip())
        executable = bin_path / "RuntimeRegistryProbe"
        stores = [scratch / "out", scratch / "index/store", bin_path / "index/store"]
        store = next((path for path in stores if (path / "v5/units").is_dir()), None)
        if store is None:
            raise RuntimeError("fixture compiler did not produce an index store")
        return store, executable

    def document(command, label, store):
        stdout = run(
            [binary, *command, "--project", project, "--index-store", store, "--allow-empty-index"],
            label,
        )
        return json.loads(stdout)

    try:
        store, executable = build()
        execution = run([executable], "probe")
        lines = set(execution.splitlines())
        expected_lines = {
            "registry=Alpha,Beta,Alpha",
            "unsupported=Alpha,Alpha,Alpha",
            "custom=nil,conditional=Alpha",
        }
        if not expected_lines.issubset(lines):
            raise RuntimeError("fixture factory selection output did not match the expected runtime behavior")

        snapshot = document(["snapshot"], "snapshot", store)
        raw = snapshot["snapshot"]
        references = raw["references"]
        dictionary_subscripts = sorted({
            reference["targetUSR"]
            for reference in references
            if reference["targetUSR"].startswith("s:SDyq_Sgxc")
        })
        expected_subscripts = ["s:SDyq_Sgxcig", "s:SDyq_Sgxcip"]
        if dictionary_subscripts != expected_subscripts:
            raise RuntimeError(
                f"compiler did not produce the exact standard Dictionary subscript proof: {dictionary_subscripts}"
            )

        report = document(["runtime", "discover", "--limit", "10000"], "discover", store)
        findings = report["findings"]
        registry_kinds = {"registryEntry", "registryLookup", "registryAlias"}
        actual = Counter()
        scored_kinds = {"registryEntry", "registryLookup"}
        for finding in findings:
            if finding["kind"] not in scored_kinds or finding["status"] not in {"resolved", "alreadyIndexed"}:
                continue
            source = (finding.get("source") or {}).get("name")
            for target in finding["targets"]:
                actual[(source, target["name"], finding["kind"])] += 1

        expected = Counter({
            ("factories", "makeAlpha()", "registryEntry"): 1,
            ("factories", "makeBeta()", "registryEntry"): 1,
            ("routes", "makeAlpha()", "registryEntry"): 1,
            ("lookupFactory()", "makeAlpha()", "registryLookup"): 1,
            ("lookupFactoryAlias()", "makeBeta()", "registryLookup"): 1,
            ("lookupRouter()", "makeAlpha()", "registryLookup"): 1,
            ("route()", "makeAlpha()", "registryLookup"): 1,
        })
        missing = expected - actual
        unexpected = actual - expected
        negative_sources = {
            "lookupMutableFactory()",
            "lookupDynamicFactory(_:)",
            "lookupClosureFactory()",
            "lookupCustomFactory()",
            "lookupConditionalFactory()",
            "buildDuplicateFactories()",
        }
        negative_resolved = sorted({
            (finding.get("source") or {}).get("name")
            for finding in findings
            if finding["kind"] in scored_kinds
            and finding["status"] in {"resolved", "alreadyIndexed"}
            and (finding.get("source") or {}).get("name") in negative_sources
        })
        if missing or unexpected or negative_resolved:
            raise RuntimeError(
                "registry discovery mismatch: "
                + json.dumps({
                    "missing": [list(value) for value in missing],
                    "unexpected": [list(value) for value in unexpected],
                    "negativeResolved": negative_resolved,
                }, sort_keys=True)
            )

        boundaries = [
            boundary
            for facts in snapshot["runtimeFiles"]
            for boundary in facts["boundaries"]
            if boundary["kind"] in registry_kinds
        ]
        if not any(boundary["kind"] == "registryAlias" for boundary in boundaries):
            raise RuntimeError("immutable alias did not leave a registryAlias boundary")
        if not any(boundary["kind"] == "registryLookup" and boundary.get("name") == "alpha"
                   for boundary in boundaries):
            raise RuntimeError("literal registry lookup was not preserved in the snapshot")

        result.update(
            status="passed",
            compilerProof=dictionary_subscripts,
            expectedRelationships=sum(expected.values()),
            truePositives=sum((expected & actual).values()),
            falsePositives=sum((actual - expected).values()),
            falseNegatives=sum((expected - actual).values()),
            registryBoundaryCount=len(boundaries),
            resolvedRelationships=sum(actual.values()),
            negativeResolved=negative_resolved,
        )
    except Exception as error:
        result["error"] = str(error)
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
