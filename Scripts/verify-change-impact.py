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


def patch_before_sources(project: Path) -> None:
    live = project / "Sources/ImpactData/LiveStore.swift"
    live.write_text(live.read_text() + '\nextension LiveStore { public func legacy() -> String { "live" } }\n')
    render = project / "Sources/ImpactFeatures/Render.swift"
    render.write_text(render.read_text() + '\npublic func renderLegacy() -> String { LiveStore().legacy() }\n')


def patch_after_sources(project: Path) -> None:
    live = project / "Sources/ImpactData/LiveStore.swift"
    text = live.read_text().replace('\nextension LiveStore { public func legacy() -> String { "live" } }\n', "\n")
    live.write_text(text)
    render = project / "Sources/ImpactFeatures/Render.swift"
    text = render.read_text().replace('public func renderLegacy() -> String { LiveStore().legacy() }', 'public func renderLegacy() -> String { "live" }')
    text = text.replace("extensionOnly()", "renamedExtensionOnly()")
    render.write_text(text)
    live.write_text(live.read_text().replace("public func extensionOnly()", "public func renamedExtensionOnly()"))


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
        before_snapshot = output / "before.json"
        run(
            [str(binary), "snapshot", "--revision", "before-change", "--project", str(workspace), "--index-store", str(before_store), "--output", str(before_snapshot)],
            cwd=workspace, output=output, name="snapshot-before",
        )
        before_doc = json.loads(before_snapshot.read_text())
        if before_doc.get("format") != "analysis-snapshot" or before_doc.get("revision") != "before-change":
            raise RuntimeError("before snapshot has the wrong format or revision label")

        patch_after_sources(workspace)
        after_bin, after_store = build_index(workspace, after_scratch, output, "after")
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
            "witnessDependents": len(witness["affected"]),
            "containerDependents": len(container["affected"]),
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
