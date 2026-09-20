#!/usr/bin/env python3
"""Compare compiler-backed public/fix/affected results in both directions."""

import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def run(binary, fixture, *arguments):
    result = subprocess.run(
        [str(binary), *arguments, "--project", str(fixture)], capture_output=True, text=True
    )
    if result.returncode:
        raise AssertionError(f"{arguments}: exit {result.returncode}\n{result.stderr}")
    return json.loads(result.stdout)


def normalize(value, fixture):
    if isinstance(value, str):
        return value.replace(str(fixture), "<project>")
    if isinstance(value, list):
        return [normalize(item, fixture) for item in value]
    if isinstance(value, dict):
        return {key: normalize(item, fixture) for key, item in value.items()}
    return value


def compare(fixture, name, actual):
    expected = (fixture / name).read_text()
    actual = json.dumps(normalize(actual, fixture), indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if actual != expected:
        difference = "".join(difflib.unified_diff(
            expected.splitlines(True), actual.splitlines(True), fromfile=name, tofile="actual"
        ))
        raise AssertionError(difference)
    print(f"  ok  {name}")


def source_hashes(fixture):
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for base in ("Sources", "Tests") for path in (fixture / base).rglob("*.swift")}


def affected(binary, fixture, selector, nodes):
    document = run(binary, fixture, "affected", selector, "--format", "json")
    impact = run(binary, fixture, "impact", selector, "--format", "json")
    assert not impact["truncated"]["output"] and not impact["truncated"]["depth"], impact
    assert document["summary"]["affectedSymbols"] == len(impact["affected"]), (document, impact)
    # Swift 6.3/6.4의 @Test 매크로는 서로 다른 수의 암시적 보조 선언을 만든다.
    # 개수를 버리지 않고 impact의 실제 목록과 먼저 대조한 뒤, 컴파일러가
    # 정확한 매크로 위치에 implicit으로 남긴 정점만 골든 집계에서 분리한다.
    generated = []
    for visit in impact["affected"]:
        node = nodes[visit["symbol"]["usr"]]
        location = node.get("location", {})
        if ("implicit" in node["attributes"] and node["module"] == "CorpusTests"
                and location.get("path") == str(fixture / "Tests/CorpusTests/CorpusTests.swift")
                and location.get("line") == 4 and location.get("column") == 1):
            generated.append(node["name"])
    document["summary"]["affectedSymbols"] -= len(generated)
    print(f"  info  {selector}: {len(impact['affected'])} raw consumers; "
          f"{len(generated)} compiler-implicit @Test helpers: {generated}")
    return document


def main():
    binary, fixture = (Path(argument).resolve() for argument in sys.argv[1:])
    report = run(binary, fixture, "dead", "--report-format", "json")
    compare(fixture, "expected-redundant-public.json", [
        item for item in report["diagnostics"] if item["ruleIdentifier"] == "redundant-public"
    ])
    before = source_hashes(fixture)
    compare(fixture, "expected-fix.json", run(binary, fixture, "fix", "--format", "json"))
    assert source_hashes(fixture) == before, "fix dry run changed source bytes"
    graph = run(binary, fixture, "graph", "--level", "symbol", "--format", "json")
    nodes = {node["usr"]: node for node in graph["nodes"] if node.get("usr")}
    compare(fixture, "expected-affected.json",
            affected(binary, fixture, "onlyTestsCallThis", nodes))
    compare(fixture, "expected-affected-changed.json",
            affected(binary, fixture, "exercisesTestOnlyCode", nodes))
    compare(fixture, "expected-affected-empty.json",
            affected(binary, fixture, "calledOnlyFromGetter", nodes))
    # 테스트 경로를 뺀 답과 원래 테스트가 없는 답을 혼동하지 않게 한다.
    with tempfile.TemporaryDirectory(prefix="cartograph-affected-filter-") as directory:
        config = Path(directory) / "excluded-tests.yml"
        config.write_text('exclude: ["Tests/**"]\n')
        excluded = run(binary, fixture, "affected", "onlyTestsCallThis", "--format", "json",
                       "--config", str(config))
        assert excluded["tests"] == [], excluded
        assert any(item.startswith("configured-path-filter:") for item in excluded["limitations"]), excluded
    print("  ok  fix dry run preserves sources; excluded tests carry a limitation")


if __name__ == "__main__":
    main()
