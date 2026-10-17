#!/usr/bin/env python3
"""Verify change-impact against separate real compiler-index snapshots."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(command: list[str], *, cwd: Path, output: Path, name: str, expected: int = 0, timeout: int = 300) -> str:
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"{name}: timed out after {timeout}s") from error
    (output / f"{name}.stdout.log").write_text(result.stdout)
    (output / f"{name}.stderr.log").write_text(result.stderr)
    if result.returncode != expected:
        raise RuntimeError(f"{name}: expected exit {expected}, got {result.returncode}; see {output}")
    return result.stdout


def build_index(project: Path, scratch: Path, output: Path, label: str) -> tuple[Path, Path]:
    command = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch)]
    run(command + ["--build-tests"], cwd=project, output=output, name=f"{label}-build")
    bin_path = Path(run(command + ["--show-bin-path"], cwd=project, output=output, name=f"{label}-bin-path").strip())
    stores = [scratch / "out", scratch / "index/store", bin_path / "index/store"]
    store = next((path for path in stores if path.is_dir()), None)
    if store is None:
        raise RuntimeError(f"{label}: no compiler index produced in {scratch}")
    return bin_path, store


def json_document(binary: Path, project: Path, store: Path, output: Path, command: list[str], name: str, expected: int = 0) -> dict:
    text = run(
        [str(binary)] + command + ["--project", str(project), "--index-store", str(store)],
        cwd=project,
        output=output,
        name=name,
        expected=expected,
    )
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{name}: command did not return JSON") from error


ENUM_RELATIVE_PATH = "Sources/ImpactData/EnumDecisions.swift"
ENUM_BEFORE_SOURCE = """public enum ReleaseStatus: Equatable { case a, b }
public func releaseAllows(_ status: ReleaseStatus) -> Bool {
    [ReleaseStatus.a, .b].contains(status)
}
public func releaseDenies(_ status: ReleaseStatus) -> Bool {
    ![ReleaseStatus.a, .b].contains(status)
}
public func releaseFallback(_ status: ReleaseStatus) -> Bool {
    switch status {
    case .a: return true
    case .b: return true
    default: return false
    }
}
"""


def patch_before_sources(project: Path) -> None:
    (project / ENUM_RELATIVE_PATH).write_text(ENUM_BEFORE_SOURCE)
    live = project / "Sources/ImpactData/LiveStore.swift"
    live.write_text(live.read_text() + '\nextension LiveStore { public func legacy() -> String { "live" } }\n')
    render = project / "Sources/ImpactFeatures/Render.swift"
    render.write_text(render.read_text() + '\npublic func renderLegacy() -> String { LiveStore().legacy() }\n')


def patch_after_sources(project: Path) -> None:
    enum_source = project / ENUM_RELATIVE_PATH
    if enum_source.read_text() != ENUM_BEFORE_SOURCE:
        raise RuntimeError("enum before source changed before the paired compiler build")
    enum_source.write_text(ENUM_BEFORE_SOURCE.replace("case a, b", "case a, b, c", 1))
    live = project / "Sources/ImpactData/LiveStore.swift"
    text = live.read_text().replace('\nextension LiveStore { public func legacy() -> String { "live" } }\n', "\n")
    live.write_text(text)
    render = project / "Sources/ImpactFeatures/Render.swift"
    text = render.read_text().replace('public func renderLegacy() -> String { LiveStore().legacy() }', 'public func renderLegacy() -> String { "live" }')
    text = text.replace("extensionOnly()", "renamedExtensionOnly()")
    render.write_text(text)
    live.write_text(live.read_text().replace("public func extensionOnly()", "public func renamedExtensionOnly()"))


def verify_selection_safety(binary: Path, project: Path, store: Path, output: Path) -> None:
    affected = json_document(binary, project, store, output,
        ["affected", "lifecycleValue", "--format", "json"], "lifecycle-affected")
    expected = {"LifecycleSetupTests", "testDirect()"}
    if {row["symbol"]["name"] for row in affected["tests"]} != expected:
        raise RuntimeError("XCTest setup dependency was omitted or an ordinary helper was promoted")
    setup = next(row for row in affected["tests"] if row["symbol"]["name"] == "LifecycleSetupTests")
    if setup["relationship"] != "automaticRuntime" or setup["edges"] or not setup.get("runtimeEvidence"):
        raise RuntimeError("XCTest lifecycle provenance was lost or presented as a compiler edge")
    impact = json_document(binary, project, store, output,
        ["impact", "lifecycleValue", "--format", "json"], "lifecycle-impact")
    if {row["name"] for row in impact["tests"]} != expected:
        raise RuntimeError("impact and affected disagree on XCTest lifecycle execution")
    args = [str(binary), "affected", "--since", "HEAD", "--format", "xcodebuild",
            "--project", str(project), "--index-store", str(store)]
    run(["git", "init", "-q"], cwd=project, output=output, name="selection-git-init")
    run(["git", "add", "."], cwd=project, output=output, name="selection-git-add")
    run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
         "commit", "-qm", "fixture baseline"], cwd=project, output=output, name="selection-git-commit")
    fixture = project / "expected.json"
    fixture.write_text('{"value": 42}\n')
    if run(args, cwd=project, output=output, name="unmodeled-only-selectors"):
        raise RuntimeError("unmodeled-only changes must keep the empty all-tests fallback")
    # 작업 트리와 인덱스를 바꾸지 않고 HEAD 쪽 내용만 바꾼다. 신선도 거부가 회귀를 가리지 않는다.
    source = "Sources/ImpactData/LifecycleValue.swift"
    old = run(["git", "hash-object", "-w", "/dev/null"], cwd=project, output=output, name="selection-empty-blob").strip()
    run(["git", "update-index", "--cacheinfo", f"100644,{old},{source}"],
        cwd=project, output=output, name="selection-git-index")
    run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
         "commit", "-qm", "pre-change source"], cwd=project, output=output, name="selection-git-before")
    mixed = run(args, cwd=project, output=output, name="mixed-unmodeled-selectors", expected=2)
    if mixed or "outside the dependency model" not in (output / "mixed-unmodeled-selectors.stderr.log").read_text():
        raise RuntimeError("mixed modeled/unmodeled changes silently narrowed the test run")
    fixture.unlink()
    selectors = run(args, cwd=project, output=output, name="modeled-only-selectors")
    expected_selectors = ("-only-testing:ImpactChecks/LifecycleDirectTests/testDirect\n"
                          "-only-testing:ImpactChecks/LifecycleSetupTests\n")
    if selectors != expected_selectors:
        raise RuntimeError(f"modeled-only lifecycle selectors differ: {selectors!r}")


def enum_review(document: dict, *, label: str) -> dict:
    review = document.get("enumChangeReview")
    if document.get("status") != "found" or document.get("unresolvedInputs") or not isinstance(review, dict):
        raise RuntimeError(f"{label}: public comparison omitted the selected enum or its review")
    for count, rows in [
        ("issueCount", "issues"),
        ("unresolvedDecisionCount", "unresolvedDecisions"),
    ]:
        if review.get(count) != 0 or review.get(rows) != []:
            raise RuntimeError(f"{label}: unresolved enum evidence: {review}")
    if review.get("unattributedDecisionCount") != 0 or review.get("truncated") is not False:
        raise RuntimeError(f"{label}: incomplete or truncated enum evidence: {review}")
    return review


def verify_enum_no_addition(binary: Path, project: Path, store: Path, output: Path, before: Path) -> None:
    document = json_document(binary, project, store, output,
        ["impact", "ReleaseStatus", "--before", str(before), "--format", "json"], "enum-no-addition")
    review = enum_review(document, label="enum-no-addition")
    if (review.get("status") != "noCandidates" or review.get("changes") != []
            or review.get("changeCount") != 0 or review.get("candidates") != []
            or review.get("candidateCount") != 0):
        raise RuntimeError(f"identical capable enum snapshots produced a change candidate: {review}")


def verify_enum_expansion(binary: Path, project: Path, store: Path, output: Path, before: Path,
                          before_document: dict) -> dict:
    document = json_document(binary, project, store, output,
        ["impact", "ReleaseStatus", "--before", str(before), "--format", "json"], "enum-expansion-json")
    review = enum_review(document, label="enum-expansion")
    if review.get("status") != "review" or review.get("changeCount") != 1 or len(review.get("changes", [])) != 1:
        raise RuntimeError(f"paired compiler snapshots did not identify exactly one enum expansion: {review}")
    change = review["changes"][0]
    added = change.get("addedCases", [])
    if (change.get("name") != "ReleaseStatus" or change.get("beforeCaseCount") != 2
            or change.get("currentCaseCount") != 3 or change.get("addedCaseCount") != 1
            or len(added) != 1 or added[0].get("name") != "c"):
        raise RuntimeError(f"enum case inventory did not retain a,b -> a,b,c: {change}")
    enum_usr = change["enumUSR"]
    added_usr = added[0]["usr"]
    source_path = str((project / ENUM_RELATIVE_PATH).resolve())
    before_files = before_document.get("snapshot", {}).get("enumImpactFiles", [])
    before_rows = [row for row in before_files if row.get("path") == source_path]
    inventories = [row for file in before_rows for row in file.get("inventories", [])
                   if row.get("enumUSR") == enum_usr]
    if (len(before_rows) != 1 or before_rows[0].get("status") != "fresh"
            or len(inventories) != 1 or inventories[0].get("complete") is not True):
        raise RuntimeError("saved baseline omitted the complete compiler-bound enum inventory")
    old_cases = set(inventories[0]["caseUSRs"])
    if len(old_cases) != 2 or added_usr in old_cases:
        raise RuntimeError("added enum case identity was already in the saved baseline")
    if added[0]["location"]["path"] != source_path or added[0]["location"]["line"] != 1:
        raise RuntimeError("added case lost its current declaration location")

    expected_lines = {"literalMembership": 3, "negatedLiteralMembership": 6, "switchDefault": 9}
    candidates = review.get("candidates", [])
    if (review.get("candidateCount") != 3 or len(candidates) != 3
            or {row["kind"] for row in candidates} != set(expected_lines)):
        raise RuntimeError(f"packaged CLI omitted a distinct enum decision kind: {candidates}")
    contains_usr = "s:STsSQ7ElementRpzrlE8containsySbABF"
    negation_usr = "s:Sb1nopyS2bFZ"
    for row in candidates:
        kind = row["kind"]
        location = row["location"]
        if (row.get("enumUSR") != enum_usr or not row.get("ownerUSR")
                or row.get("addedCaseUSRs") != [added_usr] or row.get("addedCaseCount") != 1
                or set(row.get("explicitCaseUSRs", [])) != old_cases or row.get("explicitCaseCount") != 2
                or row.get("guardedCaseUSRs") != [] or row.get("guardedCaseCount") != 0):
            raise RuntimeError(f"{kind}: candidate identity or explicit case evidence differs: {row}")
        if location != {"path": source_path, "line": expected_lines[kind], "column": 5}:
            raise RuntimeError(f"{kind}: decision has the wrong current source location: {location}")
        evidence = row.get("evidenceLocations", [])
        if (not evidence or row.get("evidenceCount") != len(evidence)
                or any(point["path"] != source_path or point["line"] <= 0 or point["column"] <= 0
                       for point in evidence)):
            raise RuntimeError(f"{kind}: missing or misplaced compiler/syntax evidence: {evidence}")
        targets = [] if kind == "switchDefault" else [contains_usr]
        if kind == "negatedLiteralMembership":
            targets.append(negation_usr)
        if set(row.get("operationTargetUSRs", [])) != set(targets) or row.get("operationTargetCount") != len(targets):
            raise RuntimeError(f"{kind}: standard-library target attribution was not preserved: {row}")
        reason = ("added-case-not-unconditionally-handled-before-fallback" if kind == "switchDefault"
                  else "added-case-outside-explicit-literal-set")
        if row.get("reason") != reason:
            raise RuntimeError(f"{kind}: candidate reason overstates or omits the source evidence")
        if kind == "switchDefault" and {"path": source_path, "line": 12, "column": 5} not in evidence:
            raise RuntimeError("default candidate omitted its fallback token location")

    text = run([str(binary), "impact", "ReleaseStatus", "--before", str(before), "--format", "text",
                "--project", str(project), "--index-store", str(store)],
               cwd=project, output=output, name="enum-expansion-text")
    if ("enum change review: review, 1 expanded enums, 3 candidates" not in text
            or any(kind not in text for kind in expected_lines)):
        raise RuntimeError("public text output omitted the enum review or a decision kind")
    return {"enumUSR": enum_usr, "addedCaseUSR": added_usr, "candidateKinds": sorted(expected_lines),
            "candidateCount": 3, "noAdditionControl": "passed", "sourcePath": source_path}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    if binary.is_file() and binary.suffix == ".txt":
        binary = Path(binary.read_text().splitlines()[0].strip()).expanduser().resolve()
    if binary.is_dir():
        binary = binary / "cartograph"
    if not binary.is_file():
        parser.error(f"Cartograph binary not found: {binary}")
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/ChangeImpactCorpus"
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-impact-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix="cartograph-impact-workspace-")) / "ChangeImpactCorpus"
    shutil.copytree(corpus, workspace)
    before_scratch = output / "before-build"
    after_scratch = output / "after-build"
    try:
        patch_before_sources(workspace)
        _, before_store = build_index(workspace, before_scratch, output, "before")
        # 과거 비교를 추가해도 수정 전 질의의 프로토콜·익스텐션·범위 검증을 유지한다.
        witness = json_document(binary, workspace, before_store, output,
            ["impact", "LiveStore.read", "--format", "json"], "witness")
        witness_names = {row["symbol"]["name"] for row in witness["affected"]}
        if not {"render(_:)", "renderLive()", "rendersLiveStore()"}.issubset(witness_names):
            raise RuntimeError(f"protocol dispatch lost real consumers: {witness_names}")
        if {"SpareStore", "unrelatedUtility()"} & witness_names:
            raise RuntimeError("witness change leaked into an unrelated implementation")
        if any(row["symbol"]["name"] == "read()" and row["relationship"] == "dependent"
               for row in witness["affected"]):
            raise RuntimeError("sibling witness became a dependent")
        if not witness["tests"] or not witness["entryPoints"]:
            raise RuntimeError("impact omitted its real tests or executable entry point")
        if not any(row.get("dispatchContract") for row in witness["affected"]):
            raise RuntimeError("dispatch callers lack their protocol witness evidence")
        container = json_document(binary, workspace, before_store, output,
            ["impact", "LiveStore", "--format", "json"], "container")
        scope_names = {row["name"] for row in container["changeScope"]}
        if container["status"] != "found" or "extensionOnly()" not in scope_names:
            raise RuntimeError("type selection lost its extension member")
        if not {"renderExtension()", "rendersExtension()"}.issubset(
            {row["symbol"]["name"] for row in container["affected"]}
        ):
            raise RuntimeError("type selection lost extension consumers outside the selected file")
        file_impact = json_document(binary, workspace, before_store, output,
            ["impact", "--file", "Sources/ImpactData/LiveStore.swift", "--format", "json"], "file")
        if "renderExtension()" not in {row["symbol"]["name"] for row in file_impact["affected"]}:
            raise RuntimeError("file selection clipped consumers in another file")
        bounded = json_document(binary, workspace, before_store, output,
            ["impact", "LiveStore.read", "--depth", "1", "--limit", "1", "--format", "json"], "bounded")
        if not bounded["truncated"]["depth"]:
            raise RuntimeError("depth truncation was hidden")
        limited = json_document(binary, workspace, before_store, output,
            ["impact", "LiveStore", "--limit", "1", "--format", "json"], "limited")
        if not limited["truncated"]["output"] or len(limited["affected"]) != 1:
            raise RuntimeError("output truncation was hidden")
        runtime_impact = json_document(binary, workspace, before_store, output,
            ["impact", "RuntimeController", "--format", "json"], "runtime-impact")
        runtime_affected = json_document(binary, workspace, before_store, output,
            ["affected", "RuntimeController", "--format", "json"], "runtime-affected")
        expected_runtime_tests = {"resolvesRuntimeController()"}
        runtime_test_names = {row["symbol"]["name"] for row in runtime_affected["tests"]}
        if runtime_test_names != expected_runtime_tests:
            raise RuntimeError(f"runtime test selection omitted a test or included unrelated tests: {runtime_test_names}")
        if {row["name"] for row in runtime_impact["tests"]} != runtime_test_names:
            raise RuntimeError("affected and impact disagree about automatically discovered runtime consumers")
        if not any(row["symbol"]["name"] == "resolveRuntimeController()"
                   and row["relationship"] == "automaticRuntime" for row in runtime_impact["affected"]):
            raise RuntimeError("fixture no longer exercises the missing compiler-edge boundary")
        resource_affected = json_document(binary, workspace, before_store, output,
            ["affected", "--file", "Sources/ImpactData/Resources/RuntimeScreen.xib", "--format", "json"],
            "resource-affected")
        if resource_affected["status"] != "found" or {
            row["symbol"]["name"] for row in resource_affected["tests"]
        } != expected_runtime_tests:
            raise RuntimeError("resource change lost its bound Swift declaration or runtime test consumers")
        runtime_selectors = run(
            [str(binary), "affected", "RuntimeController", "--format", "xcodebuild", "--project", str(workspace),
             "--index-store", str(before_store)], cwd=workspace, output=output, name="runtime-selectors")
        if runtime_selectors != "-only-testing:ImpactChecks\n":
            raise RuntimeError(f"runtime test module selector was not preserved: {runtime_selectors!r}")
        verify_selection_safety(binary, workspace, before_store, output)
        before_snapshot = output / "before.json"
        run(
            [str(binary), "snapshot", "--revision", "before-change", "--project", str(workspace), "--index-store", str(before_store), "--output", str(before_snapshot)],
            cwd=workspace, output=output, name="snapshot-before",
        )
        before_doc = json.loads(before_snapshot.read_text())
        if before_doc.get("format") != "analysis-snapshot" or before_doc.get("revision") != "before-change":
            raise RuntimeError("before snapshot has the wrong format or revision label")
        verify_enum_no_addition(binary, workspace, before_store, output, before_snapshot)

        patch_after_sources(workspace)
        after_bin, after_store = build_index(workspace, after_scratch, output, "after")
        enum_expansion = verify_enum_expansion(binary, workspace, after_store, output, before_snapshot, before_doc)
        deleted = json_document(
            binary, workspace, after_store, output,
            ["impact", "LiveStore.legacy", "--before", str(before_snapshot), "--format", "json"],
            "comparison-deleted",
        )
        before_names = {row["symbol"]["name"] for row in deleted["before"]["affected"]}
        if "renderLegacy()" not in before_names:
            raise RuntimeError(f"deleted symbol lost its before caller: {before_names}")
        if deleted["status"] != "found" or deleted["unresolvedInputs"]:
            raise RuntimeError("deleted symbol was not reconciled from the historical snapshot")
        if "renderLegacy()" in {row["symbol"]["name"] for row in deleted["current"]["affected"]}:
            raise RuntimeError("current graph inherited a historical caller")

        renamed = json_document(
            binary, workspace, after_store, output,
            ["impact", "LiveStore.extensionOnly", "--before", str(before_snapshot), "--format", "json"],
            "comparison-renamed",
        )
        renamed_before = {row["symbol"]["name"] for row in renamed["before"]["affected"]}
        if "renderExtension()" not in renamed_before:
            raise RuntimeError("renamed symbol lost its historical caller")
        if renamed["status"] != "found" or renamed["unresolvedInputs"]:
            raise RuntimeError("renamed symbol was not reconciled from the historical snapshot")

        missing = json_document(
            binary, workspace, after_store, output,
            ["impact", "MissingSymbol", "--before", str(before_snapshot), "--format", "json"],
            "comparison-missing", expected=64,
        )
        if missing["status"] != "incomplete" or not missing["unresolvedInputs"]:
            raise RuntimeError("missing input did not remain incomplete")
        execution = run([str(after_bin / "ImpactApp")], cwd=workspace, output=output, name="runtime")
        if execution.strip().splitlines() != ["live", "extension"]:
            raise RuntimeError("executable output no longer matches the exercised scenarios")
        run(["swift", "test", "--package-path", str(workspace), "--scratch-path", str(after_scratch), "--skip-build"], cwd=workspace, output=output, name="tests")
        summary = {
            "status": "passed",
            "enumChangeReview": enum_expansion,
            "witnessDependents": len(witness["affected"]),
            "containerDependents": len(container["affected"]),
            "runtimeAffectedTests": sorted(runtime_test_names),
            "resourceAffectedTests": sorted(row["symbol"]["name"] for row in resource_affected["tests"]),
            "runtimeSelector": runtime_selectors.strip(),
            "beforeSnapshot": str(before_snapshot),
            "deletedBeforeAffected": sorted(before_names),
            "renamedBeforeAffected": sorted(renamed_before),
            "afterStore": str(after_store),
        }
        (output / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
        print(f"Evidence: {output}")
        return 0
    except Exception as error:
        (output / "result.json").write_text(json.dumps({"status": "failed", "error": str(error)}, indent=2) + "\n")
        print(f"FAILED: {error}; evidence: {output}")
        return 1
    finally:
        shutil.rmtree(workspace.parent, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
