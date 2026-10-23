#!/usr/bin/env python3
"""Separate compiler-required contracts from runtime owner use; keep build-removal controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time


PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WrapperBuilderFeedback", targets: [
    .target(name: "Features"), .executableTarget(name: "App", dependencies: ["Features"])
])
'''
FEATURES = '''@propertyWrapper public struct LiveBox {
    public var wrappedValue: Int
    public var projectedValue: Int { wrappedValue }
    public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
    public func spareWrapperHelper() -> Int { 100 }
}
@propertyWrapper public struct DormantBox {
    public var wrappedValue: Int
    public var projectedValue: Int { wrappedValue }
    public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
}
public struct LiveWrappedOwner {
    @LiveBox var value = 7
    public init() {}
    public func read() -> Int { $value }
}
public struct NeverMadeWrappedOwner {
    @DormantBox var value = 9
    public func read() -> Int { $value }
}
@resultBuilder public enum LiveBuilder {
    public static func buildBlock(_ values: Int...) -> Int { values.reduce(0, +) }
    public static func spareBuilderHelper() -> Int { 100 }
}
@resultBuilder public enum DormantBuilder {
    public static func buildBlock(_ values: Int...) -> Int { values.reduce(0, +) }
}
public struct LiveBuilderOwner {
    public init() {}
    @LiveBuilder public func value() -> Int { 1; 2 }
}
public struct NeverMadeBuilderOwner {
    @DormantBuilder public func value() -> Int { 4; 5 }
}
public struct OrdinaryNames {
    public var wrappedValue: Int { 23 }
    public static func buildBlock(_ value: Int) -> Int { value }
}
// @LiveBox and @LiveBuilder in comments do not make this owner live.
public struct CommentOnlyOwner {}
'''
CONTRACTS = ["LiveBox", "DormantBox", "LiveBuilder", "DormantBuilder"]
LIVE = ["LiveWrappedOwner", "LiveBuilderOwner"]
DEAD = ["NeverMadeWrappedOwner", "NeverMadeBuilderOwner",
        "OrdinaryNames", "CommentOnlyOwner", "LiveBox.spareWrapperHelper", "LiveBuilder.spareBuilderHelper"]
REQUIRED = ["LiveBox.wrappedValue", "LiveBox.projectedValue", "LiveBuilder.buildBlock",
            "DormantBox.wrappedValue", "DormantBox.projectedValue", "DormantBuilder.buildBlock"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def run(command, root, logs, label, expected=(0,), env=None):
    started = time.monotonic()
    args = list(map(str, command))
    result = subprocess.run(args, cwd=root, capture_output=True, text=True, timeout=300, env=env)
    write(logs / (label + ".stdout"), result.stdout)
    write(logs / (label + ".stderr"), result.stderr)
    write(logs / (label + ".json"), json.dumps({"command": args, "exit": result.returncode,
          "seconds": time.monotonic() - started}, indent=2, sort_keys=True))
    if expected is not None and result.returncode not in expected:
        raise AssertionError(f"{label}: exit {result.returncode}; {result.stderr[-5000:]}")
    return result


def index_store(root):
    candidates = [root / ".build/out", root / ".build/debug/index/store"]
    candidates.extend(sorted((root / ".build").glob("*/debug/index/store")))
    stores = [p for p in candidates if (p / "v5/units").is_dir() or (p / "units").is_dir()]
    # 기존 scratch의 낡은 unit이 선택되지 않도록 package 자체를 새 경로에 만든다.
    if not stores:
        raise AssertionError("Fresh SwiftPM build did not produce an observable index store")
    return stores[0]


def observe(binary, root, logs, label, requests):
    temporary = logs / (label + "-tmp")
    temporary.mkdir()
    environment = dict(os.environ, TMPDIR=str(temporary) + os.sep)
    request_path = logs / (label + "-requests.json")
    write(request_path, json.dumps(requests))
    document = json.loads(run([binary, "query", "--project", root, "--index-store", index_store(root),
                               "--batch", request_path], root, logs, label + "-query", env=environment).stdout)
    assert document["format"] == "symbol-query-batch"
    assert [row["requested"] for row in document["results"]] == requests
    states = {}
    compiler_references = {}
    for row in document["results"]:
        assert row["status"] == "found", row
        states[row["requested"]] = row["result"]["reachability"]
        if row["requested"] in CONTRACTS:
            usr = row["result"]["subject"]["usr"]
            compiler_references[row["requested"]] = [item
                for caller in row["result"]["usedBy"]
                for item in caller.get("referenceEvidence", {}).get("items", [])
                if item.get("origin") == "compiler" and item.get("targetUSR") == usr]
    return states, compiler_references


def check(states, compiler_references, exercised):
    reachable = {"reachable", "retained", "retainedByMember"}
    # 런타임에 만들지 않는 owner라도 annotation을 소스에 남겨 두면 규약 선언이
    # 컴파일에 필요하다. required declaration과 runtime owner를 같은 dead oracle로 보지 않는다.
    for name in CONTRACTS + REQUIRED + (LIVE if exercised else []):
        assert states[name]["state"] in reachable, (name, states[name])
    for name in CONTRACTS:
        assert compiler_references[name], (name, "missing observed compiler annotation reference")
    for name in DEAD + ([] if exercised else LIVE):
        assert states[name]["state"] == "unreachable", (name, states[name])


def declaration(source, marker, following):
    """고정 fixture 선언만 고른다. 임의 Swift 소스를 재작성하는 기능은 아니다."""
    assert source.count(marker) == 1 and source.count(following) == 1
    start = source.index(marker)
    end = source.index(following, start)
    return source[start:end]


def compiler_controls():
    wrapper = declaration(FEATURES, "@propertyWrapper public struct DormantBox", "public struct LiveWrappedOwner")
    builder = declaration(FEATURES, "@resultBuilder public enum DormantBuilder", "public struct LiveBuilderOwner")
    wrapper_owner = declaration(FEATURES, "public struct NeverMadeWrappedOwner", "@resultBuilder public enum LiveBuilder")
    builder_owner = declaration(FEATURES, "public struct NeverMadeBuilderOwner", "public struct OrdinaryNames")
    # wrappedValue만의 규약을 검사하려고 부수적인 getter/initializer의 참조도 함께 지운다.
    missing_value = ("@propertyWrapper public struct DormantBox {\n"
                     "    public var projectedValue: Int { 0 }\n"
                     "    public init(wrappedValue: Int) {}\n}\n")
    missing_block = "@resultBuilder public enum DormantBuilder {}\n"
    return [
        ("remove-wrapper-declaration", FEATURES.replace(wrapper, ""), False, ["DormantBox"]),
        ("remove-builder-declaration", FEATURES.replace(builder, ""), False, ["DormantBuilder"]),
        ("remove-wrapped-value", FEATURES.replace(wrapper, missing_value), False, ["wrappedValue"]),
        ("remove-build-block", FEATURES.replace(builder, missing_block), False, ["buildBlock"]),
        ("remove-dead-owners-and-contracts", FEATURES.replace(wrapper, "").replace(builder, "")
            .replace(wrapper_owner, "").replace(builder_owner, ""), True, []),
    ]


def verify_compiler_controls(output, result):
    for label, features, expected_success, diagnostic_tokens in compiler_controls():
        root = output / label
        write(root / "Package.swift", PACKAGE)
        write(root / "Sources/Features/Features.swift", features)
        write(root / "Sources/App/main.swift",
              "import Features\nprint(LiveWrappedOwner().read(), LiveBuilderOwner().value())\n")
        case = {"label": label, "expectedSuccess": expected_success,
                "sourceSHA256": {str(p.relative_to(root)): digest(p)
                    for p in [root / "Package.swift", *sorted((root / "Sources").rglob("*.swift"))]}}
        result["compilerControls"].append(case)
        built = run(["swift", "build", "--jobs", "3"], root, output, label + "-build",
                    expected=None)
        case["exit"] = built.returncode
        assert (built.returncode == 0) == expected_success, (label, built.returncode)
        diagnostics = built.stdout + built.stderr
        if not expected_success:
            assert built.returncode > 0 and "error:" in diagnostics, (label, diagnostics[-5000:])
        assert all(token in diagnostics for token in diagnostic_tokens), (label, diagnostics[-5000:])
        case["assertionsPassed"] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, help="Optional existing comparison binary; observations only")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    # 다른 실행의 증거를 덮거나 지우지 않는다. 실패한 실행도 그대로 남긴다.
    output.mkdir(parents=True, exist_ok=False)
    binary = args.cartograph.resolve(strict=True)
    result = {"id": "C-P0-3", "complete": False, "candidateSHA256": digest(binary),
              "scope": "Synthetic compiler-contract and runtime-owner controls, not SwiftUI projection or a private app",
              "existingSwiftUICoverage": "FalsePositiveCorpus/PropertyWrappers.swift separately covers real @State projection",
              "oracle": "Compiler annotation references keep contracts necessary while source remains. Runtime-dead owners and ordinary helpers remain unreachable. Fresh declaration/member removal builds test this distinction; unreachable is not a deletion recommendation.",
              "cases": [], "compilerControls": []}
    if args.baseline:
        result["baselineSHA256"] = digest(args.baseline.resolve(strict=True))
    try:
        repository = Path(__file__).resolve().parents[1]
        result["sourceCommit"] = run(["git", "rev-parse", "HEAD"], repository, output, "checkout-head").stdout.strip()
        result["sourceTree"] = run(["git", "rev-parse", "HEAD^{tree}"], repository, output, "checkout-tree").stdout.strip()
        result["checkoutDirty"] = bool(run(["git", "status", "--porcelain", "--untracked-files=no"],
                                            repository, output, "checkout-status").stdout.strip())
        result["toolchain"] = run(["swift", "--version"], repository, output, "toolchain").stdout.strip()
        result["host"] = {"system": platform.system(), "release": platform.release(), "machine": platform.machine()}
        for exercised in [True, False]:
            label = "called" if exercised else "uncalled"
            root = output / label
            write(root / "Package.swift", PACKAGE)
            write(root / "Sources/Features/Features.swift", FEATURES)
            write(root / "Sources/App/main.swift", "import Features\n" + (
                "print(LiveWrappedOwner().read(), LiveBuilderOwner().value())\n" if exercised else "print(0)\n"))
            run(["swift", "build", "--jobs", "3"], root, output, label + "-build")
            case = {"label": label, "sourceSHA256": {str(p.relative_to(root)): digest(p)
                    for p in [root / "Package.swift", *sorted((root / "Sources").rglob("*.swift"))]}}
            result["cases"].append(case)
            for name, executable in [("candidate", binary), ("baseline", args.baseline)]:
                if executable is None:
                    continue
                case[name], case[name + "CompilerReferences"] = observe(
                    executable.resolve(), root, output, label + "-" + name, CONTRACTS + LIVE + DEAD + REQUIRED)
            check(case["candidate"], case["candidateCompilerReferences"], exercised)
            case["candidateAssertionsPassed"] = True
        verify_compiler_controls(output, result)
        result["complete"] = True
    finally:
        write(output / "results.json", json.dumps(result, indent=2, sort_keys=True))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
