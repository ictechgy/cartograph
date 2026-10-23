#!/usr/bin/env python3
"""Compile C-P1-4 once and compare public/candidate architectural ownership.

This does not build Cartograph. An optional pre-fix main binary can extend the
comparison; omitting it explicitly leaves native current-main evidence unknown.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import sys

CAP = 64 * 1024 * 1024
MODULE_PAIRS = {("App", "Presentation"), ("App", "CycleControl"),
                ("Presentation", "Domain"), ("Presentation", "Data")}
FILE_PAIRS = {
    ("Sources/App/main.swift", "Sources/Presentation/DomainType+Presentation.swift"),
    ("Sources/App/main.swift", "Sources/CycleControl/Left.swift"),
    ("Sources/App/main.swift", "Sources/CycleControl/Right.swift"),
    ("Sources/Presentation/DomainType+Presentation.swift", "Sources/Domain/DomainType.swift"),
    ("Sources/Presentation/DomainType+Presentation.swift", "Sources/Data/DataType.swift"),
    ("Sources/CycleControl/Left.swift", "Sources/CycleControl/Right.swift"),
    ("Sources/CycleControl/Right.swift", "Sources/CycleControl/Left.swift"),
}


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load(path):
    with path.open("rb") as stream:
        data = stream.read(CAP + 1)
    if len(data) > CAP:
        raise ValueError("JSON exceeds the 64 MiB evidence budget")
    return json.loads(data)


def pairs(document):
    if document.get("nodeCount") != len(document["nodes"]) or document.get("edgeCount") != len(document["edges"]):
        raise ValueError("Incomplete graph document")
    return {(edge["source"], edge["target"]) for edge in document["edges"]}


def file_pairs(document, project):
    return {(Path(source).resolve().relative_to(project.resolve()).as_posix(),
             Path(target).resolve().relative_to(project.resolve()).as_posix())
            for source, target in pairs(document)}


def type_pairs(document):
    names = {node["id"]: node["module"] + "." + node["name"] for node in document["nodes"]}
    return {(names[source], names[target]) for source, target in pairs(document)}


def validate_candidate(documents, project):
    if pairs(documents["module"]) != MODULE_PAIRS:
        raise ValueError("Candidate module graph differs from the full expected dependency pairs")
    if file_pairs(documents["file"], project) != FILE_PAIRS:
        raise ValueError("Candidate file graph differs from the full expected dependency pairs")
    expected_types = {("Domain.DomainType", "Presentation.AppProtocol"),
                      ("Presentation.AppProtocol", "Domain.DomainType"),
                      ("CycleControl.Left", "CycleControl.Right"), ("CycleControl.Right", "CycleControl.Left")}
    if not expected_types.issubset(type_pairs(documents["type"])):
        raise ValueError("Semantic type ownership or real mutual type references were lost")
    for level in ["file", "module"]:
        document = documents[level + "-evidence"]
        if document["edges"] != documents[level]["edges"]:
            raise ValueError("Evidence export and ordinary graph disagree")
        signatures = {(e["source"], e["target"], e["kind"]) for e in document["edges"]}
        evidence = {(e["source"], e["target"], e["kind"]) for e in document["evidence"]}
        if evidence != signatures or document["evidenceCount"] != len(document["evidence"]):
            raise ValueError("An architectural edge lost or misattributed its source evidence")
    rules = documents["rules"]
    violations = [d for d in rules["diagnostics"] if d["ruleIdentifier"] == "layer-violation"]
    if rules.get("suppressedCount") != 0 or not violations or any(
            "Presentation" not in d["message"] or "Data" not in d["message"] for d in violations):
        raise ValueError("Actual Presentation-to-Data violation disappeared or changed scope")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--public-binary", type=Path, required=True, help="Verified public 0.28.0 binary")
    parser.add_argument("--baseline", type=Path, help="Optional pre-C-P1-4 main binary")
    parser.add_argument("--output", type=Path, required=True, help="New directory; never overwritten")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This gate requires native macOS Swift; source review is not execution")
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("extension_native_base", repo / "Scripts/benchmark-indexstore-cli.py")
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    results = {"id": "C-P1-4", "status": "incomplete", "scope": "generalized synthetic native corpus, not company-app accuracy",
               "mainBaseline": "provided binary; source commit requires its independent CI receipt" if args.baseline
                               else "unverified: pre-fix main binary was not retained",
               "measurements": [], "binaries": {}, "reports": {}}

    def run(command, cwd, label, timeout=600):
        meta = base.run(list(map(str, command)), cwd, output / "logs" / label, timeout, stream_limit=CAP)
        results["measurements"].append({"label": label, "wallSeconds": meta["wall_seconds"],
            "processMaxRSSBytes": meta["wait4_maxrss_bytes"], "metadata": "logs/" + label + ".json"})
        return Path(meta["stdout"])

    try:
        results["candidateCheckoutCommit"] = run(["git", "rev-parse", "HEAD"], repo, "checkout-head").read_text().strip()
        results["toolchain"] = run(["swift", "--version"], repo, "toolchain").read_text().strip()
        fixture = output / "corpus"
        shutil.copytree(repo / "Fixtures/FalsePositiveCorpus/ExtensionArchitecture", fixture,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm"))
        results["fixtureSHA256"] = {str(p.relative_to(fixture)): base.sha256(p)
                                   for p in sorted(fixture.rglob("*")) if p.is_file()}
        run(["swift", "build", "--jobs", "3"], fixture, "build")
        bindir = run(["swift", "build", "--show-bin-path"], fixture, "bin-path").read_text().strip()
        run([Path(bindir) / "App"], fixture, "execute")
        candidates = [fixture / ".build/out", fixture / ".build/debug/index/store",
                      *sorted((fixture / ".build").glob("*/debug/index/store"))]
        indexes = {p.resolve() for p in candidates if (p / "v5/units").is_dir() or (p / "units").is_dir()}
        if len(indexes) != 1:
            raise ValueError("Expected exactly one fresh compiler index")
        index = indexes.pop()
        captured = base.fingerprint(index)
        binaries = {"public-0.28.0": args.public_binary.resolve(), "candidate": args.candidate.resolve()}
        if args.baseline:
            binaries["pre-fix-main"] = args.baseline.resolve()
        for label, binary in binaries.items():
            results["binaries"][label] = {"sha256": base.sha256(binary),
                "version": run([binary, "--version"], fixture, label + "-version").read_text().strip()}
            if label == "public-0.28.0" and "0.28.0" not in results["binaries"][label]["version"]:
                raise ValueError("Public baseline binary does not report version 0.28.0")
            documents = {}
            for level in ["module", "file", "type"]:
                documents[level] = load(run([binary, "graph", "--level", level, "--format", "json",
                    "--project", fixture, "--index-store", index, "--config", fixture / "rules.yml"],
                    fixture, label + "-" + level))
                if label == "candidate" and level != "type":
                    documents[level + "-evidence"] = load(run([binary, "graph", "--level", level,
                        "--format", "json", "--evidence", "--project", fixture, "--index-store", index,
                        "--config", fixture / "rules.yml"], fixture, label + "-" + level + "-evidence"))
            if label == "candidate":
                documents["rules"] = load(run([binary, "rules", "--level", "module", "--report-format", "json",
                    "--project", fixture, "--index-store", index, "--config", fixture / "rules.yml"],
                    fixture, label + "-rules"))
                validate_candidate(documents, fixture)
            observed = pairs(documents["module"])
            results["reports"][label] = {"modulePairs": sorted(observed),
                "falseDomainReverse": any(source == "Domain" and target in {"Presentation", "Data"}
                                          for source, target in observed),
                "filePairs": sorted(file_pairs(documents["file"], fixture)),
                "typePairs": sorted(type_pairs(documents["type"]))}
        if base.fingerprint(index) != captured:
            raise ValueError("Compiler index changed between analyses")
        if not results["reports"]["public-0.28.0"]["falseDomainReverse"]:
            raise ValueError("Public baseline did not reproduce the reported reverse architectural edge")
        if args.baseline and not results["reports"]["pre-fix-main"]["falseDomainReverse"]:
            raise ValueError("Provided pre-fix baseline did not reproduce the reverse edge")
        results.update(status="passed", sameIndex=captured,
                       limitations="Ambiguous/missing file module evidence retains the legacy semantic source. "
                                   "Type and symbol graphs intentionally preserve semantic owners; no whole-app claim.")
        return 0
    except Exception as error:
        results["error"] = str(error)
        raise
    finally:
        save(output / "results.json", results)
        print(json.dumps({"status": results["status"], "mainBaseline": results["mainBaseline"]}))


if __name__ == "__main__":
    sys.exit(main())
