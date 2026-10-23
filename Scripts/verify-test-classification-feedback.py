#!/usr/bin/env python3
"""C-P1-6: compare public/candidate test identity on one real compiler index.

Synthetic fixture only. Seven sibling callers remain conservative candidates;
this does not measure whole-application accuracy or authorize test omission.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def symbol_names(rows):
    return {row.get("symbol", row).get("name", "").split("(", 1)[0] for row in rows}


def assess(leaf, dispatch):
    debug = {"test_debugOne", "test_debugTwo", "test_debugThree", "test_debugFour", "test_debugFive"}
    actual = {"testActual", "modernActual"}
    siblings = {"siblingOne", "siblingTwo", "siblingThree", "siblingFour", "siblingFive", "siblingSix", "siblingSeven"}
    tests = symbol_names(leaf["tests"])
    uncertain = symbol_names(leaf.get("uncertainTestCandidates") or [])
    projected = symbol_names(dispatch["tests"])
    return {"misclassifiedDebug": sorted(tests & debug), "uncertainDebug": sorted(uncertain & debug),
            "actualTestsPreserved": actual <= tests,
            "ordinaryControlExcluded": "ordinaryControl" not in tests,
            "siblingCandidates": sorted(projected & siblings),
            "changedReceiverPreserved": "changedReceiverControl" in projected,
            "directSiblingExcluded": "directSiblingControl" not in projected,
            "receiverUnknownPreserved": any(x.startswith("dispatch-receiver-uncertainty:") for x in dispatch["limitations"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path, help="Installed public 0.28.0 executable")
    parser.add_argument("--prior-candidate", type=Path, help="Optional installed pre-feedback candidate")
    parser.add_argument("--output", required=True, type=Path, help="New evidence directory")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("native_measure", repo / "Scripts/benchmark-indexstore-cli.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    fixture = output / "fixture"
    shutil.copytree(repo / "Fixtures/FalsePositiveCorpus/TestClassification", fixture)
    records = []

    def run(command, label, expected=(0,)):
        started = time.monotonic()
        meta = native.run(list(map(str, command)), fixture, output / "logs" / label, 600,
                          stream_limit=64 * 1024 * 1024)
        records.append({"label": label, "wallSeconds": time.monotonic() - started, "receipt": "logs/" + label + ".json"})
        # Native runner raises for unexpected failures, preserving its bounded logs and cleanup receipt.
        return Path(meta["stdout"]).read_text(encoding="utf-8")

    result = {"id": "C-P1-6", "scope": "synthetic SwiftPM compiler fixture; no company sources",
              "status": "pending", "runs": {}, "measurements": records}
    try:
        result["toolchain"] = run(["swift", "--version"], "toolchain")
        run(["swift", "build", "--build-tests", "--enable-index-store", "--jobs", "2"], "build")
        stores = [fixture / ".build/out", fixture / ".build/debug/index/store", *sorted((fixture / ".build").glob("*/debug/index/store"))]
        stores = sorted({p.resolve() for p in stores if (p / "v5/units").is_dir() or (p / "units").is_dir()})
        if len(stores) != 1:
            raise AssertionError("Expected one compiler index, observed " + str(stores))
        binaries = [("public028", args.baseline), ("candidate", args.candidate)]
        if args.prior_candidate:
            binaries.insert(1, ("priorCandidate", args.prior_candidate))
        for label, binary in binaries:
            binary = binary.resolve()
            version = run([binary, "--version"], label + "-version").strip()
            if label == "public028" and "0.28.0" not in version:
                raise AssertionError("Baseline must be actual public 0.28.0 executable")
            documents = {}
            for query, symbol in [("leaf", "impactLeaf()"), ("dispatch", "ChangedClient.send()")]:
                for command in ["affected", "impact"]:
                    doc = json.loads(run([binary, command, symbol, "--format", "json", "--limit", "10000",
                                          "--project", fixture, "--index-store", stores[0]], label + "-" + query + "-" + command))
                    if doc.get("selectionIssues") or not doc.get("selected"):
                        raise AssertionError("Unresolved fixture seed: " + str(doc.get("selectionIssues")))
                    documents[query + "-" + command] = doc
            outcome = assess(documents["leaf-affected"], documents["dispatch-affected"])
            result["runs"][label] = {"version": version, "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                                      "assessment": outcome}
            if label == "candidate":
                assert not outcome["misclassifiedDebug"], outcome
                assert outcome["actualTestsPreserved"] and outcome["ordinaryControlExcluded"], outcome
                assert len(outcome["siblingCandidates"]) == 7 and outcome["changedReceiverPreserved"], outcome
                assert outcome["directSiblingExcluded"] and outcome["receiverUnknownPreserved"], outcome
                assert symbol_names(documents["leaf-impact"]["tests"]) == symbol_names(documents["leaf-affected"]["tests"])
        result["status"] = "passed"
        result["publicReproduced"] = bool(result["runs"]["public028"]["assessment"]["misclassifiedDebug"])
        result["limitations"] = ["No receiver-sensitive specialization; seven sibling tests are retained review candidates.",
                                 "Framework identity/Swift Testing syntax markers do not prove selected scheme membership.",
                                 "Pre-feedback candidate not executed unless --prior-candidate is supplied."]
    finally:
        save(output / "results.json", result)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
