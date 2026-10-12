#!/usr/bin/env python3
"""원래 누락된 헤더 선언·간선을 독립 소스 위치로 실제 CLI에서 검증한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile

spec = importlib.util.spec_from_file_location("shared", Path(__file__).with_name("verify-recursive-calls.py"))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
require, compare, run = shared.require, shared.compare, shared.run


def verify_source(oracle: dict, project: Path) -> None:
    for site in oracle["symbols"].values():
        line = (project / site["path"]).read_bytes().splitlines()[site["line"] - 1]
        require(line[site["column"] - 1 :].startswith(site["name"].encode()), f"Authored source anchor changed: {site}")


def verify_graph(graph: dict, oracle: dict, project: Path) -> dict[str, str]:
    ids = {}
    for key, site in oracle["symbols"].items():
        matches = [
            node
            for node in graph["nodes"]
            if node["name"] == site["name"]
            and node["kind"] == "function"
            and node.get("location")
            and shared.location_key(node["location"], project) == (site["path"], site["line"], site["column"])
        ]
        require(len(matches) == 1, f"Expected one compiled source definition for {key}, got {matches}")
        require(matches[0]["id"] == matches[0]["usr"], "Native identity is not the compiler USR")
        ids[key] = matches[0]["usr"]
    compare(len(graph["nodes"]), len(ids), "all authored node count")
    compare(set(node["id"] for node in graph["nodes"]), set(ids.values()), "all authored nodes")
    actual = {(edge["source"], edge["target"]) for edge in graph["edges"] if edge["kind"] == "call"}
    compare(actual, {(ids[a], ids[b]) for a, b in oracle["calls"]}, "all authored call edges")
    return ids


def verify(binary: Path, output: Path) -> dict:
    project = output / "Project"
    fixture = Path(__file__).resolve().parents[1] / "Fixtures/HeaderRecordCorpus"
    shutil.copytree(fixture, project)
    oracle = json.loads((project / "oracle.json").read_text())
    verify_source(oracle, project)
    store, build = output / "IndexStore", output / "Build"
    store.mkdir()
    build.mkdir()
    clang = run(["xcrun", "--find", "clang"], project, output, "clang-path").strip()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], project, output, "sdk-path").strip()
    for name in ["Core.m", "CppBridge.mm"]:
        run(
            [
                clang,
                "-c",
                "-isysroot",
                sdk,
                f"Sources/BridgeKit/{name}",
                "-I",
                "Sources/BridgeKit/include",
                "-o",
                str(build / (name + ".o")),
                "-index-store-path",
                str(store),
            ],
            project,
            output,
            name,
        )
    native = shared.Harness(binary, project, store, output)
    graph = native.document(
        "complete-graph", ["graph", "--level", "symbol", "--include-self-loops", "--format", "json"]
    )
    ids = verify_graph(graph, oracle, project)
    for depth, expected in [
        (1, {"headerC": 1, "headerCpp": 1}),
        (4, {"headerC": 1, "headerCpp": 1, "bridge": 2, "cppHelper": 2, "cppBridge": 3}),
    ]:
        query = native.document(f"query-{depth}", ["query", ids["base"], "--depth", str(depth), "--edge-kind", "call"])
        compare(query["status"], "found", "base query status")
        rows = query["result"]["usedBy"]
        compare({row["usr"]: row["depth"] for row in rows}, {ids[k]: v for k, v in expected.items()}, "header callers")
        compare(len(rows), len(expected), "no duplicate caller contexts")
        require(
            not any(x.startswith("header-projection:") for x in query["limitations"]),
            "Admitted header still incomplete",
        )
    snapshot = native.document("snapshot", ["snapshot"])["snapshot"]
    header = str(project / "Sources/BridgeKit/include/CGCore.h")
    compare(snapshot["admittedHeaderPaths"], [header], "header admission roundtrip")
    require(header in snapshot["oldestIndexedFileDates"], "Header admission lost independent freshness")
    return {
        "status": "passed",
        "symbols": len(ids),
        "call_edges": len(oracle["calls"]),
        "original_missing_header_definitions": 2,
        "original_missing_header_edges": 4,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    require(binary.is_file() and os.access(binary, os.X_OK), "Exact Cartograph executable is required")
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-header-records-"))).resolve()
    require(not output.exists() or not any(output.iterdir()), "Output must be absent or empty")
    output.mkdir(parents=True, exist_ok=True)
    before = hashlib.sha256(binary.read_bytes()).hexdigest()
    try:
        result = verify(binary, output)
        require(hashlib.sha256(binary.read_bytes()).hexdigest() == before, "Executable changed")
    except Exception as error:
        result = {"status": "failed", "error": f"{type(error).__name__}: {error}"}
    result["cartograph_sha256"] = before
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
