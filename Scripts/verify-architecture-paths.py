#!/usr/bin/env python3
"""Verify real compiler-backed path rules and genuine/filtered cycle controls."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def run(command, root, expected=0):
    result = subprocess.run(list(map(str, command)), cwd=root, capture_output=True, text=True, timeout=120)
    if result.returncode != expected:
        raise AssertionError(f"{command}: expected exit {expected}, got {result.returncode}\n"
                             f"{result.stdout}\n{result.stderr}")
    return result.stdout


def verify(binary, root):
    sources = {
        "Features/Screen.swift": "public struct Screen { public init() {}\n"
            " public func load() -> Store { Store() }\n}\n",
        "Data/Store.swift": "public struct Store { public init() {} }\n",
        "Cycle/Left.swift": "final class Left { var right: Right? }\n",
        "Cycle/Right.swift": "final class Right { var left: Left? }\n",
    }
    for name, content in sources.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    run(["swiftc", "-module-name", "RulePaths", "-emit-module", "-emit-library",
         "-module-cache-path", root / "module-cache", "-index-store-path", root / "index",
         "-o", root / "libRulePaths.dylib", *[root / name for name in sources]], root)
    template = """level: type
include: ["**/*.swift"]
exclude: []
layers:
  - name: Presentation
    match: ["{prefix}Features/**"]
  - name: Data
    match: ["{prefix}Data/**"]
  - name: CycleControl
    match: ["{prefix}Cycle/**"]
rules:
  - from: Presentation
    deny: [Data]
"""
    common = ["--project", root, "--index-store", root / "index"]
    reports = []
    for name, prefix in [("relative", ""), ("absolute", str(root) + "/"), ("globstar", "**/")]:
        config = root / (name + ".yml")
        config.write_text(template.format(prefix=prefix), encoding="utf-8")
        result = json.loads(run([binary, "rules", *common, "--config", config,
                                 "--report-format", "json", "--strict"], root, expected=1))
        assert result["suppressedCount"] == 0
        diagnostics = result["diagnostics"]
        violations = [d for d in diagnostics if d["ruleIdentifier"] == "layer-violation"]
        assert violations and len(violations) == len(diagnostics), result
        assert all("RulePaths.Screen (Presentation)" in d["message"] and
                   "RulePaths.Store (Data)" in d["message"] for d in violations), result
        reports.append(diagnostics)
    assert reports[0] == reports[1] == reports[2], "Path spellings changed the findings"
    config = root / "relative.yml"
    explained = run([binary, "rules", *common, "--config", config, "--explain", "Screen"], root)
    assert "matched: Features/Screen.swift against 'Features/**'" in explained, explained
    cycle_args = [binary, "cycles", *common, "--config", config, "--report-format", "json", "--strict"]
    for level in ["type", "file"]:
        report = json.loads(run([*cycle_args, "--level", level], root, expected=1))
        cycles = [d for d in report["diagnostics"] if d["ruleIdentifier"] == "cycle"]
        assert len(cycles) == 1 and "Left" in cycles[0]["message"] and "Right" in cycles[0]["message"], report
    for extra in [["--level", "module"], ["--level", "type", "--edge-kind", "call"]]:
        report = json.loads(run([*cycle_args, *extra], root))
        assert not any(d["ruleIdentifier"] == "cycle" for d in report["diagnostics"]), report
    print("  ok    relative/absolute rules, explanation, real file/type cycle and edge-kind controls")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    args = parser.parse_args()
    binary = args.cartograph.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="cartograph-architecture-paths-") as directory:
        verify(binary, Path(directory).resolve())


if __name__ == "__main__":
    main()
