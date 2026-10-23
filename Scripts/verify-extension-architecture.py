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
import time

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
VARIANT_TYPE_PAIRS = {
    ("Domain.InferredToken", "Presentation.InferredContract"),
    ("Domain.Box", "Presentation.ConditionalContract"),
    ("Domain.DefaultToken", "Presentation.DefaultContract"),
    ("Domain.AliasToken", "Presentation.AliasContract"),
    ("CycleControl.Left", "CycleControl.Right"),
    ("CycleControl.Right", "CycleControl.Left"),
}
VARIANT_FILE_CONTROLS = {
    ("Sources/CycleControl/Left.swift", "Sources/CycleControl/Right.swift"),
    ("Sources/CycleControl/Right.swift", "Sources/CycleControl/Left.swift"),
    ("Sources/Presentation/NestedMembers.swift", "Sources/Data/DataType.swift"),
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
    validate_evidence_and_rules(documents)


def validate_variants_candidate(documents, project):
    """Check added native shapes without guessing every compiler-emitted file edge."""
    if pairs(documents["module"]) != MODULE_PAIRS:
        raise ValueError("Variant module graph differs from the full expected dependency pairs")
    observed_files = file_pairs(documents["file"], project)
    if any(source.startswith("Sources/Domain/") and
           target.startswith(("Sources/Presentation/", "Sources/Data/")) for source, target in observed_files):
        raise ValueError("Variant extension reference was attributed to the original domain file")
    if not VARIANT_FILE_CONTROLS.issubset(observed_files):
        raise ValueError("Variant nested-member dependency or genuine file cycle disappeared")
    if not VARIANT_TYPE_PAIRS.issubset(type_pairs(documents["type"])):
        raise ValueError("Variant semantic conformance or genuine type cycle disappeared")
    validate_evidence_and_rules(documents)


def validate_evidence_and_rules(documents):
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
    parser.add_argument("--corpus", choices=["original", "variants"], default="original",
                        help="The default original run also verifies additional variants independently")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This gate requires native macOS Swift; source review is not execution")
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    spec = importlib.util.spec_from_file_location("extension_native_base", repo / "Scripts/benchmark-indexstore-cli.py")
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    deadline = time.monotonic() + 600 if args.corpus == "variants" else None
    results = verify_corpus(args, repo, base, args.corpus, output, deadline=deadline)
    if args.corpus == "original":
        verify_additional_corpus(args, repo, base, output, results)
    return 0


def require_remaining(deadline):
    """진단 전체 예산은 다음 native 호출 전에 검사하고 남은 시간을 직접 감독자에 준다."""
    remaining = None if deadline is None else deadline - time.monotonic()
    if remaining is not None and remaining <= 0:
        raise TimeoutError("Extension corpus exhausted its 600-second native-command budget")
    return remaining


def corpus_runner(base, output, results, deadline=None):
    """중간 Python process 없이 동일 감독자가 각 native command와 종료 receipt를 소유한다."""
    def run(command, cwd, label, timeout=600):
        remaining = require_remaining(deadline)
        command_timeout = timeout if remaining is None else min(timeout, remaining)
        meta = base.run(list(map(str, command)), cwd, output / "logs" / label,
                        command_timeout, stream_limit=CAP)
        results["measurements"].append({"label": label, "wallSeconds": meta["wall_seconds"],
            "processMaxRSSBytes": meta["wait4_maxrss_bytes"], "metadata": "logs/" + label + ".json"})
        return Path(meta["stdout"])
    return run


def verify_additional_corpus(args, repo, base, output, results):
    """추가 corpus도 같은 interpreter에서 실행하고 실패 receipt를 기존 artifact 범위에 보존한다."""
    results["status"] = "incomplete"
    save(output / "results.json", results)
    try:
        variants = verify_corpus(args, repo, base, "variants", output / "variants",
                                 deadline=time.monotonic() + 600)
        if variants.get("status") != "candidate-controls-passed":
            raise ValueError("Additional native extension variants did not complete")
        results["additionalCorpus"] = {"results": "logs/extension-variants-evidence/results.json",
            "status": variants["status"], "reproduction": variants["reproduction"],
            "fixtureSHA256": variants["fixtureSHA256"]}
        results["status"] = "candidate-controls-passed"
    except BaseException as error:
        results["error"] = str(error)
        raise
    finally:
        # ci.yml 고정 관찰과 build 산출물을 바꾸지 않고 성공/실패의 raw receipt만 복사한다.
        try:
            receipts = output / "logs" / "extension-variants-evidence"
            receipts.mkdir(parents=True, exist_ok=False)
            if (output / "variants/results.json").is_file():
                shutil.copy2(output / "variants/results.json", receipts / "results.json")
            if (output / "variants/logs").is_dir():
                shutil.copytree(output / "variants/logs", receipts / "logs")
        except BaseException as error:
            results["status"] = "incomplete"
            results["evidenceError"] = str(error)
            raise
        finally:
            save(output / "results.json", results)


def verify_corpus(args, repo, base, corpus, output, deadline=None):
    """독립 결과와 입력을 남기며 같은 감독자가 합성 corpus의 native 명령을 순차 실행한다."""
    output.mkdir(parents=True, exist_ok=False)
    results = {"id": "C-P1-4", "corpus": corpus, "status": "incomplete",
               "scope": "generalized synthetic native corpus, not company-app accuracy",
               "mainBaseline": "provided binary; source commit requires its independent CI receipt" if args.baseline
                               else "unverified: pre-fix main binary was not retained",
               "measurements": [], "binaries": {}, "reports": {}}

    run = corpus_runner(base, output, results, deadline)

    try:
        results["candidateCheckoutCommit"] = run(["git", "rev-parse", "HEAD"], repo, "checkout-head").read_text().strip()
        results["toolchain"] = run(["swift", "--version"], repo, "toolchain").read_text().strip()
        fixture = output / "corpus"
        corpus_name = "ExtensionArchitecture" if corpus == "original" else "ExtensionVariants"
        shutil.copytree(repo / "Fixtures/FalsePositiveCorpus" / corpus_name, fixture,
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
                if corpus == "variants":
                    validate_variants_candidate(documents, fixture)
                else:
                    validate_candidate(documents, fixture)
                    query = load(run([binary, "query", "DomainType", "--project", fixture,
                        "--index-store", index, "--config", fixture / "rules.yml"],
                        fixture, label + "-query-type"))
                    if query.get("status") != "found" or query["result"]["subject"]["kind"] != "struct":
                        raise ValueError("Compiler-proven type and extension name did not resolve to the nominal type")
                    usr = query["result"]["subject"]["usr"]
                    exact = load(run([binary, "query", usr, "--project", fixture,
                        "--index-store", index, "--config", fixture / "rules.yml"],
                        fixture, label + "-query-usr"))
                    if exact.get("status") != "found" or exact["result"]["subject"] != query["result"]["subject"]:
                        raise ValueError("Name canonicalization and exact compiler USR disagree")
                    results["queryIdentity"] = {"status": "passed", "subject": query["result"]["subject"],
                        "scope": "one actual compiler extension; three-extension and ambiguity controls are unit fixtures"}
            observed = pairs(documents["module"])
            results["reports"][label] = {"modulePairs": sorted(observed),
                "falseDomainReverse": any(source == "Domain" and target in {"Presentation", "Data"}
                                          for source, target in observed),
                "filePairs": sorted(file_pairs(documents["file"], fixture)),
                "typePairs": sorted(type_pairs(documents["type"]))}
        if base.fingerprint(index) != captured:
            raise ValueError("Compiler index changed between analyses")
        reproduction = {label: "reproduced" if report["falseDomainReverse"] else "not-reproduced"
                        for label, report in results["reports"].items() if label != "candidate"}
        # A successful candidate control is not evidence that an older binary was wrong.
        # Keep the public result separate; this compiler corpus may not emit the
        # semantic-owner/source-location combination from the reported workspace.
        results.update(status="candidate-controls-passed", reproduction=reproduction, sameIndex=captured,
                       limitations="Ambiguous/missing file module evidence retains the legacy semantic source. "
                                   "Type and symbol graphs intentionally preserve semantic owners. A not-reproduced "
                                   "public result does not establish remediation of the reported workspace; no whole-app claim.")
        require_remaining(deadline)
        return results
    except BaseException as error:
        results["status"] = "incomplete"
        results["error"] = str(error)
        raise
    finally:
        save(output / "results.json", results)
        print(json.dumps({"corpus": corpus, "status": results["status"], "mainBaseline": results["mainBaseline"],
                          "reproduction": results.get("reproduction", {})}))


if __name__ == "__main__":
    sys.exit(main())
