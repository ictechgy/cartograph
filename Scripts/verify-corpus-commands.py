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


def main():
    binary, fixture = (Path(argument).resolve() for argument in sys.argv[1:])
    report = run(binary, fixture, "dead", "--report-format", "json")
    compare(fixture, "expected-redundant-public.json", [
        item for item in report["diagnostics"] if item["ruleIdentifier"] == "redundant-public"
    ])
    before = source_hashes(fixture)
    compare(fixture, "expected-fix.json", run(binary, fixture, "fix", "--format", "json"))
    assert source_hashes(fixture) == before, "fix dry run changed source bytes"
    compare(fixture, "expected-affected.json",
            run(binary, fixture, "affected", "onlyTestsCallThis", "--format", "json"))
    compare(fixture, "expected-affected-changed.json",
            run(binary, fixture, "affected", "exercisesTestOnlyCode", "--format", "json"))
    compare(fixture, "expected-affected-empty.json",
            run(binary, fixture, "affected", "calledOnlyFromGetter", "--format", "json"))
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
