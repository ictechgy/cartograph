#!/usr/bin/env python3
"""정답 파일 없이 동결한 엔진 조립기를 한 번 실행하는 선택된 진입점."""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "runtime"))
sys.path.insert(0, str(ROOT / "primitive"))
import runtime_bootstrap as bootstrap
import arm_sessions as primitive
from selector_contract import selectors


adapter = primitive.adapter
baseline_implicit_metadata = primitive.baseline_implicit_metadata
classify_unused_implicit = primitive.classify_unused_implicit
save = primitive.save
ADAPTER_VERSION = "include-only-file-dependency-v1"
INCLUDE = re.compile(r'[ \t]*#[ \t]*(?:include|import)[ \t]+"([A-Za-z0-9_./-]+)"[ \t]*\r?')


def sealed_source(config, relative):
    """재사용한 승인 소스 바이트 없이는 빈 선언 목록을 신뢰하지 않는다."""
    project = Path(config["project"]).resolve()
    path = project / relative
    if path.is_symlink() or not path.is_file() or path.resolve() != path or not path.is_relative_to(project):
        raise ValueError("File-only header source is missing or aliased")
    data = path.read_bytes()
    expected = config.get("accepted_sources", {}).get(relative, {}).get("sha256")
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("File-only header source differs from accepted bytes")
    return path, data


def include_targets(config, relative, catalog):
    """지원 문법 밖의 매크로·조건문·선언은 의미를 추측하지 않고 거부한다."""
    if Path(relative).suffix != ".h" or any(row["path"] == relative for row in catalog):
        raise ValueError("File-only coverage requires a header without source declarations")
    path, data = sealed_source(config, relative)
    targets = []
    for line in data.decode("ascii").split("\n"):
        if not line.strip(" \t\r"):
            continue
        match = INCLUDE.fullmatch(line)
        if match is None:
            raise ValueError("File-only header is not exclusively quoted include/import directives")
        spelling = match.group(1)
        target = Path(spelling)
        if target.is_absolute() or ".." in target.parts or spelling != str(target):
            raise ValueError("File-only header include is absolute, escaping or ambiguous")
        absolute = path.parent / target
        if absolute.is_symlink() or absolute.resolve() != absolute:
            raise ValueError("File-only include target is missing or aliased")
        included = adapter.relative_path(Path(config["project"]), str(absolute))
        if included not in config["contexts"] or absolute.suffix != ".h":
            raise ValueError("File-only header includes an undeclared project header")
        sealed_source(config, included)
        if included in targets:
            raise ValueError("File-only header repeats an ambiguous include target")
        targets.append(included)
    if not targets:
        raise ValueError("File-only header has no independently witnessed includes")
    return targets, hashlib.sha256(data).hexdigest()


def dependency_context(config, dependency, units, selected, relative):
    """선택된 실제 컴파일 루트와 모듈 문맥이 일치하는 파일 증거만 허용한다."""
    metadata = units[dependency["unit"]]["metadata"]
    roots = dependency["root_units"]
    module = dependency["module"]
    if (
        dependency["kind"] != "File"
        or dependency["scope"] != "user"
        or not module
        or config["contexts"][relative] != [module]
        or metadata["Module"] != module
        or metadata["Provider Identifier"] != "clang"
        or metadata["Is System"] != "false"
        or metadata["Is Module"] != "true"
        or metadata["Has Main File"] != "false"
        or dependency["unit"] not in selected["reachable_units"]
        or not roots
        or len(roots) != len(set(roots))
        or not set(roots) <= set(selected["roots"])
    ):
        raise ValueError("File-only header lacks an active user Clang module witness")
    for root in roots:
        root_metadata = units[root]["metadata"]
        output = adapter.absolute(root_metadata["Output File"], root_metadata["Working Directory"])
        expected = [row for row in config["expected_outputs"] if str(Path(row["output"]).resolve()) == output]
        if (
            len(expected) != 1
            or adapter.target_key(metadata["Target"]) != adapter.target_key(expected[0]["target"])
            or not expected[0].get("sysroot")
            or adapter.absolute(metadata["Sysroot"], metadata["Working Directory"])
            != str(Path(expected[0]["sysroot"]).resolve())
        ):
            raise ValueError("File-only header target or SDK differs from an active compiler root")


def file_only_coverage(config, catalog, units, selected, covered):
    """File은 Record가 아니다. 선언 없는 포함 파일의 출처만 따로 보존한다."""
    project = Path(config["project"])
    evidence = []
    for relative in sorted(set(config["contexts"]) - covered):
        targets, sha256 = include_targets(config, relative, catalog)
        dependencies = [
            row for row in selected["files"]
            if adapter.relative_path(project, row["absolute_path"]) == relative
        ]
        if len(dependencies) != 1:
            raise ValueError("File-only header dependency is missing or ambiguous")
        dependency = dependencies[0]
        dependency_context(config, dependency, units, selected, relative)
        for included in targets:
            matches = [
                row for row in selected["records"]
                if adapter.relative_path(project, row["absolute_path"]) == included
                and row["unit"] == dependency["unit"]
            ]
            if (
                len(matches) != 1
                or matches[0]["kind"] != "Record"
                or matches[0]["scope"] != "user"
                or not matches[0]["name"]
                or matches[0]["module"] not in ("", dependency["module"])
                or config["contexts"][included] != [dependency["module"]]
                or not set(dependency["root_units"]) <= set(matches[0]["root_units"])
            ):
                raise ValueError("File-only include lacks one same-unit Record for every active root")
        evidence.append(dict(
            path=relative,
            sha256=sha256,
            includes=targets,
            unit=dependency["unit"],
            root_units=sorted(dependency["root_units"]),
            coverage="file-dependency-only-without-callable-declarations",
        ))
    return evidence


def discover(config, catalog, recorder):
    project, store = Path(config["project"]), Path(config["store"])
    units = {}
    for path in sorted((store / "v5/units").iterdir()):
        if path.is_file():
            text = recorder.capture(
                [config["index_dump"], path.name, "--index-store", str(store), "--lib-index-store", config["library"]],
                project,
                "units/" + path.name,
            )
            units[path.name] = adapter.parse_unit(path.name, text)
    selected = adapter.select_units(units, config["expected_outputs"])
    records = []
    allowed = set(config["contexts"])
    for record in selected["records"]:
        relative = adapter.relative_path(project, record["absolute_path"])
        if relative and relative.startswith("Sources/"):
            if relative not in allowed or not Path(record["absolute_path"]).is_file():
                raise ValueError(f"Active unit includes unknown/deleted project source: {relative}")
            records.append(record)
    for dependency in selected["files"]:
        relative = adapter.relative_path(project, dependency["absolute_path"])
        if relative and relative.startswith("Sources/") and relative not in allowed:
            raise ValueError(f"Active unit includes deleted/undeclared source dependency: {relative}")
    covered = {adapter.relative_path(project, record["absolute_path"]) for record in records}
    file_only = file_only_coverage(config, catalog, units, selected, covered)
    covered.update(row["path"] for row in file_only)
    if covered != allowed:
        raise ValueError(f"Active record/source manifest mismatch: missing={sorted(allowed-covered)}")
    for expected in config["expected_outputs"]:
        roots = [
            name
            for name in selected["roots"]
            if adapter.absolute(units[name]["metadata"]["Output File"], units[name]["metadata"]["Working Directory"])
            == str(Path(expected["output"]).resolve())
        ]
        if len(roots) != 1 or not any(
            record["absolute_path"] == str(Path(expected["source"]).resolve()) and roots[0] in record["root_units"]
            for record in records
        ):
            raise ValueError("Active compiler output lacks its main source record")
        reachable = {
            entry["absolute_path"]
            for entry in selected["records"] + selected["files"]
            if roots[0] in entry["root_units"]
        }
        if set(expected.get("project_headers", [])) - reachable:
            raise ValueError("Active compiler output lacks declared header dependencies")
    texts = {
        name: recorder.capture(
            [config["index_dump"], name, "--index-store", str(store), "--lib-index-store", config["library"]],
            project,
            "records/" + name,
        )
        for name in sorted({r["name"] for r in records})
    }
    graph = adapter.baseline_graph(project, catalog, records, texts)
    metadata, raw_edges = baseline_implicit_metadata(texts)
    graph = classify_unused_implicit(graph, metadata, raw_edges)
    save(
        recorder.root / "provenance.json",
        dict(**selected, active_records=records, file_only_headers=file_only, adapter_version=ADAPTER_VERSION),
    )
    return graph



def execute(path, expected):
    data = bootstrap.read_regular(path)
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Engine input changed")
    config = bootstrap.strict_json(data)
    selectors(config["queries"])
    # 승인 세대·도구·소스 검증과 골드 필드 거부는 동결된 원래 구현을 그대로 쓴다.
    primitive.generation.verify(config)
    # 격리된 단일 엔진 호출에서만 현재 기준선 선택기를 사용하며 원본 바이트는 보존한다.
    original = primitive.baseline_discovery
    try:
        if config.get("arm") == "baseline":
            primitive.baseline_discovery = discover
        result = primitive.execute_worker(config)
    finally:
        primitive.baseline_discovery = original
    return 0 if result["status"] == "ok" else 125 if result["status"] == "incomplete" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    raise SystemExit(execute(args.input, args.sha256))


if __name__ == "__main__":
    main()
