#!/usr/bin/env python3
"""새 컴파일러 인덱스로 재귀 호출의 명시적 내보내기와 기존 분석 계약을 검증한다."""

from __future__ import annotations

import argparse
from collections import Counter, deque
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def compare(actual, expected, label: str) -> None:
    require(actual == expected, f"{label}: expected {expected!r}, got {actual!r}")


def run(command: list[str], cwd: Path, output: Path, name: str, expected: int = 0, timeout: int = 60) -> str:
    (output / f"{name}.command.json").write_text(json.dumps(command, indent=2) + "\n")
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        for label, content in (("stdout", error.stdout), ("stderr", error.stderr)):
            if isinstance(content, bytes):
                content = content.decode(errors="replace")
            (output / f"{name}.{label}.log").write_text(content or "")
        raise RuntimeError(f"{name}: timed out after {timeout}s; see {output}") from error
    (output / f"{name}.stdout.log").write_text(result.stdout)
    (output / f"{name}.stderr.log").write_text(result.stderr)
    require(result.returncode == expected, f"{name}: expected exit {expected}, got {result.returncode}; see {output}")
    return result.stdout


def build_index(project: Path, scratch: Path, output: Path, flags: list[str]) -> tuple[Path, Path]:
    command = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch), *flags]
    run(command, project, output, "build", timeout=300)
    binary_path = Path(run([*command, "--show-bin-path"], project, output, "bin-path").strip()).resolve()
    # 백엔드별 실제 산출물을 찾는다. 인덱스 경로를 지정하는 컴파일러 플래그에 의존하지 않는다.
    candidates = [scratch / "out", scratch / "index/store", binary_path / "index/store"]
    stores = set()
    for candidate in candidates:
        units = candidate / "v5/units"
        if units.is_dir() and any(path.is_file() for path in units.iterdir()):
            stores.add(candidate.resolve())
    require(len(stores) == 1, f"Expected one populated fresh compiler index in {scratch}, found {sorted(stores)}")
    return binary_path, next(iter(stores))


class Harness:
    def __init__(self, binary: Path, project: Path, store: Path, output: Path):
        self.binary, self.project, self.output = binary, project, output
        self.common = [
            "--project",
            str(project),
            "--index-store",
            str(store),
            "--config",
            str(project / ".cartograph.yml"),
        ]

    def text(self, name: str, arguments: list[str], expected: int = 0) -> str:
        return run([str(self.binary), *arguments, *self.common], self.project, self.output, name, expected=expected)

    def document(self, name: str, arguments: list[str]) -> dict:
        text = self.text(name, arguments)
        try:
            document = json.loads(text)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"{name}: command did not return JSON") from error
        require(isinstance(document, dict), f"{name}: expected a JSON object")
        return document


def location_key(location: dict, project: Path) -> tuple[str, int, int]:
    path = Path(location["path"])
    if path.is_absolute():
        path = path.resolve().relative_to(project.resolve())
    return path.as_posix(), location["line"], location["column"]


def verify_source(oracle: dict, project: Path) -> None:
    lines = (project / oracle["source"]).read_bytes().splitlines()
    # 출력에서 기대값을 유도하지 않고 사람이 작성한 위치가 원본 토큰을 가리키는지 먼저 확인한다.
    for site in [*oracle["symbols"].values(), *oracle["calls"]]:
        line, column = site["line"], site["column"]
        require(1 <= line <= len(lines), f"Oracle line is outside source: {line}")
        require(
            lines[line - 1][column - 1 :].startswith(site["spelling"].encode()),
            f"Oracle spelling changed at {oracle['source']}:{line}:{column}",
        )


def resolve_symbols(graph: dict, oracle: dict, project: Path) -> dict[str, str]:
    ids = {}
    for key, expected in oracle["symbols"].items():
        matches = [
            node
            for node in graph["nodes"]
            if node["name"] == expected["name"]
            and node["kind"] == expected["kind"]
            and node.get("location")
            and location_key(node["location"], project) == (oracle["source"], expected["line"], expected["column"])
        ]
        require(len(matches) == 1, f"Expected exactly one indexed declaration for {key}, found {matches}")
        compare(matches[0]["id"], matches[0].get("usr"), f"{key} symbol identity")
        ids[key] = matches[0]["id"]
    return ids


def edge_signature(graph: dict) -> list[tuple]:
    return sorted((edge["source"], edge["target"], edge["kind"], edge["weight"]) for edge in graph["edges"])


def expected_edges(oracle: dict, ids: dict, include_self: bool) -> list[tuple]:
    calls = Counter(
        (ids[site["source"]], ids[site["target"]])
        for site in oracle["calls"]
        if include_self or site["source"] != site["target"]
    )
    return sorted((source, target, "call", weight) for (source, target), weight in calls.items())


def verify_graph(graph: dict, oracle: dict, ids: dict, include_self: bool) -> None:
    compare(graph["level"], "symbol", "graph level")
    compare(graph["nodeCount"], len(graph["nodes"]), "node count")
    compare(graph["edgeCount"], len(graph["edges"]), "edge count")
    actual_calls = [edge for edge in edge_signature(graph) if edge[2] == "call"]
    compare(actual_calls, expected_edges(oracle, ids, include_self), "complete authored call-edge inventory")
    loops = [edge for edge in edge_signature(graph) if edge[0] == edge[1]]
    expected_loops = [edge for edge in expected_edges(oracle, ids, include_self) if edge[0] == edge[1]]
    compare(loops, expected_loops, "complete self-loop inventory")


def verify_evidence(document: dict, oracle: dict, ids: dict, include_self: bool, project: Path) -> None:
    actual = []
    compare(document["evidenceCount"], len(document["evidence"]), "evidence count")
    for row in document["evidence"]:
        if row["kind"] != "call":
            continue
        require(row.get("location") is not None, "Authored call has no occurrence location")
        compare(row["sourceUSR"], row["source"], "call evidence source USR")
        compare(row["targetUSR"], row["target"], "call evidence target USR")
        compare(row["origin"], "compiler", "call evidence origin")
        compare(row["position"], "body", "call evidence position")
        actual.append((row["source"], row["target"], *location_key(row["location"], project)))
    expected = [
        (ids[site["source"]], ids[site["target"]], oracle["source"], site["line"], site["column"])
        for site in oracle["calls"]
        if include_self or site["source"] != site["target"]
    ]
    compare(sorted(actual), sorted(expected), "complete authored call-occurrence inventory")
    actual_loops = [
        (row["source"], row["target"], row["kind"]) for row in document["evidence"] if row["source"] == row["target"]
    ]
    expected_loops = [(source, target, "call") for source, target, *_ in expected if source == target]
    compare(sorted(actual_loops), sorted(expected_loops), "complete self-loop evidence inventory")


def expected_neighbors(oracle: dict, seed: str, incoming: bool, depth: int) -> dict[str, int]:
    # 독립 소스 오라클만 순회한다. 제품의 간선이나 이웃 목록을 정답으로 재사용하지 않는다.
    adjacent = {}
    for site in oracle["calls"]:
        source, target = site["source"], site["target"]
        if incoming:
            source, target = target, source
        adjacent.setdefault(source, set()).add(target)
    found, queue = {seed: 0}, deque([seed])
    while queue:
        current = queue.popleft()
        if found[current] >= depth:
            continue
        for other in adjacent.get(current, set()):
            if other not in found:
                found[other] = found[current] + 1
                queue.append(other)
    del found[seed]
    return found


def verify_queries(harness: Harness, oracle: dict, ids: dict) -> None:
    keys = {usr: key for key, usr in ids.items()}
    for seed in oracle["recursiveSymbols"]:
        # 호출 전용 필터는 포함 간선도 제거하므로 도달성은 기본 그래프로 별도 확인한다.
        full = harness.document(f"query-{seed}-reachability", ["query", ids[seed]])
        compare(full["status"], "found", f"query {seed} default status")
        compare(
            full["result"]["reachability"]["state"],
            "unreachable" if seed == "unused" else "reachable",
            f"query {seed} reachability",
        )
        for depth in (1, 128):
            document = harness.document(
                f"query-{seed}-{depth}",
                ["query", ids[seed], "--depth", str(depth), "--limit", "100", "--edge-kind", "call"],
            )
            compare(document["status"], "found", f"query {seed} status")
            result = document["result"]
            compare(result["subject"]["usr"], ids[seed], f"query {seed} subject")
            for direction, incoming in (("usedBy", True), ("dependsOn", False)):
                rows = result[direction]
                require(all(row.get("usr") != ids[seed] for row in rows), f"query {seed} returned its own seed")
                usrs = [row.get("usr") for row in rows]
                compare(len(usrs), len(set(usrs)), f"query {seed} duplicate {direction}")
                require(all(usr in keys for usr in usrs), f"query {seed} returned unexpected {direction}: {usrs}")
                actual = {keys[row["usr"]]: row["depth"] for row in rows}
                compare(actual, expected_neighbors(oracle, seed, incoming, depth), f"query {seed} {direction}")
            require(not any(result["truncated"].values()), f"query {seed} unexpectedly truncated")


def verify_analysis(harness: Harness, oracle: dict, ids: dict) -> None:
    for level in ("module", "type", "symbol"):
        document = harness.document(
            f"cycles-{level}", ["cycles", "--level", level, "--report-format", "json", "--strict"]
        )
        compare(document["diagnostics"], [], f"default {level} cycles")
    dead = harness.document("dead", ["dead", "--report-format", "json"])
    actual = sorted(
        location_key(row["location"], harness.project)
        for row in dead["diagnostics"]
        if row["ruleIdentifier"] == "unused-symbol"
    )
    expected = sorted(
        (oracle["source"], oracle["symbols"][key]["line"], oracle["symbols"][key]["column"])
        for key in oracle["unusedSymbols"]
    )
    compare(actual, expected, "complete unused-symbol inventory")
    keys = {usr: key for key, usr in ids.items()}
    for seed in oracle["recursiveSymbols"]:
        document = harness.document(f"impact-{seed}", ["impact", ids[seed], "--format", "json", "--edge-kind", "call"])
        compare(document["status"], "found", f"impact {seed} status")
        compare([row["usr"] for row in document["selected"]], [ids[seed]], f"impact {seed} selection")
        rows = document["affected"]
        require(all(row["symbol"].get("usr") != ids[seed] for row in rows), f"impact {seed} returned its own seed")
        usrs = [row["symbol"].get("usr") for row in rows]
        require(all(usr in keys for usr in usrs), f"impact {seed} returned unexpected consumers: {usrs}")
        actual = {keys[row["symbol"]["usr"]]: row["depth"] for row in rows}
        compare(actual, expected_neighbors(oracle, seed, True, 128), f"impact {seed} consumers")
        compare(len(rows), len({row["symbol"]["usr"] for row in rows}), f"impact {seed} duplicate consumers")
        compare(document["truncated"], {"depth": False, "output": False, "sections": []}, f"impact {seed} truncation")
        if seed == "unused":
            compare(rows, [], "unused recursion consumers")


def verify_defaults(harness: Harness, default: dict) -> None:
    for level in ("module", "file", "type"):
        graph = harness.document(f"rollup-{level}", ["graph", "--level", level, "--format", "json"])
        require(not any(row["source"] == row["target"] for row in graph["edges"]), f"{level} rollup leaked a loop")
    for label, arguments in (
        ("implicit", []),
        ("module", ["--level", "module"]),
        ("file", ["--level", "file"]),
        ("type", ["--level", "type"]),
    ):
        harness.text(f"invalid-level-{label}", ["graph", "--include-self-loops", "--format", "json", *arguments], 64)
        require(
            "--include-self-loops requires explicit --level symbol"
            in (harness.output / f"invalid-level-{label}.stderr.log").read_text(),
            f"{label}: missing actionable self-loop option validation",
        )
    for format_ in ("dot", "mermaid"):
        diagram = harness.text(f"diagram-{format_}", ["graph", "--level", "symbol", "--format", format_])
        pattern = r'^\s*"([^"\n]+)" -> "([^"\n]+)"' if format_ == "dot" else r"^\s*(n\d+)\s+[^\s]+\s+(n\d+)\s*$"
        edges = re.findall(pattern, diagram, flags=re.MULTILINE)
        require(edges, f"{format_}: no diagram edges were inspected")
        require(all(source != target for source, target in edges), f"Default {format_} diagram leaked a self-loop")
    repeated = harness.document("graph-default-repeat", ["graph", "--level", "symbol", "--format", "json"])
    compare(repeated, default, "default graph after opt-in commands")


def verify(harness: Harness, oracle: dict) -> dict:
    arguments = ["graph", "--level", "symbol", "--format", "json"]
    default = harness.document("graph-default", arguments)
    complete = harness.document("graph-self-loops", [*arguments, "--include-self-loops"])
    ids = resolve_symbols(default, oracle, harness.project)
    compare(complete["nodes"], default["nodes"], "opt-in node inventory")
    for label, graph, include_self in (("default", default, False), ("self-loops", complete, True)):
        verify_graph(graph, oracle, ids, include_self)
        evidence_arguments = [*arguments, "--evidence"] + (["--include-self-loops"] if include_self else [])
        document = harness.document(f"evidence-{label}", evidence_arguments)
        compare(document["nodes"], graph["nodes"], f"{label} evidence nodes")
        compare(edge_signature(document), edge_signature(graph), f"{label} evidence topology")
        verify_evidence(document, oracle, ids, include_self, harness.project)
    compare(
        [edge for edge in edge_signature(complete) if edge[0] != edge[1]],
        edge_signature(default),
        "unchanged non-self topology",
    )
    verify_defaults(harness, default)
    verify_queries(harness, oracle, ids)
    verify_analysis(harness, oracle, ids)
    return {
        "status": "passed",
        "authoredCallOccurrences": len(oracle["calls"]),
        "authoredCallEdges": len(expected_edges(oracle, ids, True)),
        "selfCallEdges": len(oracle["recursiveSymbols"]),
        "selfCallOccurrences": sum(site["source"] == site["target"] for site in oracle["calls"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify recursive calls against a fresh Swift compiler index.")
    parser.add_argument("--cartograph", type=Path, required=True, help="Exact Cartograph executable to test.")
    parser.add_argument("--output-dir", type=Path, help="Directory for logs, fresh workspace, index, and result.json.")
    parser.add_argument("--swiftpm-flags", default=os.environ.get("SWIFTPM_FLAGS", ""))
    args = parser.parse_args()
    binary = args.cartograph.expanduser().resolve()
    if binary.is_dir():
        binary /= "cartograph"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"Cartograph executable not found: {binary}")
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-recursive-"))).resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error(f"Output directory must be empty; choose a new path to preserve prior evidence: {output}")
    output.mkdir(parents=True, exist_ok=True)
    # 이전 실행의 실패 근거를 덮어쓰지 않고 인덱스와 빌드 캐시도 새 경로에 격리한다.
    workspace = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/RecursiveCallCorpus"
    project = workspace / corpus.name
    try:
        shutil.copytree(corpus, project, ignore=shutil.ignore_patterns(".build", ".swiftpm", "__pycache__"))
        oracle = json.loads((project / "expected-calls.json").read_text())
        verify_source(oracle, project)
        run(["swift", "--version"], project, output, "swift-version")
        binary_path, store = build_index(project, workspace / "build", output, shlex.split(args.swiftpm_flags))
        compare(
            run([str(binary_path / "RecursiveCalls")], project, output, "runtime"),
            oracle["runtimeOutput"],
            "fixture runtime output",
        )
        result = verify(Harness(binary, project, store, output), oracle)
        compare(hashlib.sha256(binary.read_bytes()).hexdigest(), binary_hash, "unchanged Cartograph executable")
        result.update(
            {
                "cartograph": str(binary),
                "cartographSHA256": binary_hash,
                "project": str(project),
                "indexStore": str(store),
            }
        )
    except Exception as error:
        result = {"status": "failed", "error": str(error), "cartograph": str(binary), "project": str(project)}
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    print(f"Evidence: {output}")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
