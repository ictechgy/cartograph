#!/usr/bin/env python3
"""Compile generalized feedback fixtures; preserve release/candidate evidence, never company sources."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import time
import urllib.request

RELEASE = "https://github.com/ictechgy/cartograph/releases/download/0.28.0/cartograph-0.28.0-macos-universal.tar.gz"
DIGEST = "df5a9a8fea14769e7904e0c315421c527c29907969d4fce00e0e28c013cc3b17"


def write(root, path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def run(command, root, output, label, expected=(0,), timeout=600):
    started = time.monotonic()
    result = subprocess.run(list(map(str, command)), cwd=root, capture_output=True, text=True, timeout=timeout)
    write(output, label + ".stdout", result.stdout)
    write(output, label + ".stderr", result.stderr)
    write(output, label + ".json", json.dumps({"command": list(map(str, command)), "exit": result.returncode,
          "seconds": time.monotonic() - started}, indent=2))
    if expected is not None and result.returncode not in expected:
        raise AssertionError(f"{label}: exit {result.returncode}; {result.stderr[-5000:]}")
    return result


def index(root):
    candidates = [root / ".build/out", root / ".build/debug/index/store"]
    candidates += sorted((root / ".build").glob("*/debug/index/store"))
    return next(path for path in candidates if (path / "v5/units").is_dir() or (path / "units").is_dir())


def analyze(binary, root, output, label, command):
    return run([binary, *command, "--project", root, "--index-store", index(root)], root, output, label)


def import_case(binary, root, output, label, visibility, strict, scope="complete"):
    root.mkdir(parents=True)
    write(root, "Package.swift", '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Feedback", products: [.executable(name: "App", targets: ["App"])], targets: [
    .target(name: "Lib"), .target(name: "Unused"),
    .target(name: "Mid", dependencies: ["Lib", "Unused"]),
    .executableTarget(name: "App", dependencies: ["Mid"])
])
''')
    write(root, "Sources/Lib/Lib.swift", "public extension Int { static let magic = 42 }\n")
    write(root, "Sources/Unused/Unused.swift", "public struct Unused {}\n")
    write(root, "Sources/Mid/Mid.swift", "import Lib\nimport Unused\npublic func midValue() -> Int { .magic }\n")
    write(root, "Sources/Mid/Qualified.swift", "import Lib\npublic func qualifiedValue() -> Int { Int.magic }\n")
    write(root, "Sources/App/main.swift", "import Mid\nprint(midValue(), qualifiedValue())\n")
    if scope == "git-ignored":
        run(["git", "-c", "core.hooksPath=/dev/null", "init", "-q"], root, output, label + "-git")
        write(root, ".gitignore", "Sources/Lib/Lib.swift\n.build/\n")
    elif scope == "explicit-filter":
        write(root, "scope.yml", 'exclude:\n  - "Sources/Lib/**"\n')
    build = ["swift", "build"] + (["-Xswiftc", "-enable-upcoming-feature", "-Xswiftc", "MemberImportVisibility"] if visibility else [])
    run(build, root, output, label + "-before")
    project = root / "Sources/Mid" if scope == "outside-capture" else root
    def scoped(command, suffix):
        config = ["--config", root / "scope.yml"] if scope == "explicit-filter" else []
        return run([binary, *command, "--project", project, "--index-store", index(root), *config],
                   root, output, label + suffix)
    dead = json.loads(scoped(["dead", "--report-format", "json"], "-dead").stdout)
    imports = [d for d in dead["diagnostics"] if d["ruleIdentifier"] == "unused-import"]
    fixes = json.loads(scoped(["fix", "--apply", "--format", "json"], "-fix").stdout)
    after = run(build, root, output, label + "-after", expected=None)
    lib_present = all("import Lib" in (root / ("Sources/Mid/" + name)).read_text()
                      for name in ["Mid.swift", "Qualified.swift"])
    unused_removed = "import Unused" not in (root / "Sources/Mid/Mid.swift").read_text()
    if strict:
        assert lib_present and after.returncode == 0, (imports, fixes, after.stderr)
        if scope == "complete":
            assert unused_removed, (imports, fixes)
        else:
            assert not unused_removed, "Unknown external extension ownership must suppress removal in this file"
    return {"id": "C-P0-2", "label": label, "visibility": visibility, "libImportPreserved": lib_present,
            "unusedControlRemoved": unused_removed, "scope": scope,
            "postFixBuildExit": after.returncode,
            "reproduced": not lib_present and after.returncode != 0}


def macro_case(binary, root, output, label, syntax, strict):
    root.mkdir(parents=True, exist_ok=True)
    write(root, "Package.swift", '''// swift-tools-version: 6.0
import PackageDescription
import CompilerPluginSupport
let package = Package(name: "MacroFeedback", platforms: [.macOS(.v14)], dependencies: [
    .package(path: %s)
], targets: [
    .macro(name: "Impl", dependencies: [.product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax")]),
    .target(name: "Macros", dependencies: ["Impl"]),
    .executableTarget(name: "App", dependencies: ["Macros"])
])
''' % json.dumps(str(syntax)))
    write(root, "Sources/Impl/Impl.swift", '''import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros
public struct HelloMacro: MemberMacro {
    public static func expansion(of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        ["func hello() -> Int { 42 }"]
    }
}
@main struct Plugin: CompilerPlugin { let providingMacros: [Macro.Type] = [HelloMacro.self] }
''')
    write(root, "Sources/Macros/Macros.swift", '''@attached(member, names: named(hello))
public macro AddHello() = #externalMacro(module: "Impl", type: "HelloMacro")
@attached(member, names: named(hello))
public macro MainHello() = #externalMacro(module: "Impl", type: "HelloMacro")
@attached(member, names: named(hello))
public macro DeadHello() = #externalMacro(module: "Impl", type: "HelloMacro")
@attached(member, names: named(hello))
public macro CommentOnly() = #externalMacro(module: "Impl", type: "HelloMacro")
''')
    write(root, "Sources/App/Greeter.swift", '''import Macros
@AddHello struct Greeter {}
@DeadHello struct NeverMade {}
// @CommentOnly struct CommentView {}
''')
    write(root, "Sources/App/main.swift", '''import Macros
@MainHello struct MainGreeter {}
print(Greeter().hello(), MainGreeter().hello())
''')
    run(["swift", "build", "--jobs", "3"], root, output, label + "-build", timeout=1200)
    states = {}
    for name in ["AddHello", "MainHello", "DeadHello", "CommentOnly", "NeverMade", "Greeter"]:
        doc = json.loads(analyze(binary, root, output, label + "-" + name, ["query", name]).stdout)
        states[name] = doc.get("symbol", doc.get("result", doc)).get("reachability", {})
        # Query's public response is retained intact alongside this compact summary.
        if not states[name]:
            def find(value):
                if isinstance(value, dict):
                    if "state" in value and value["state"] in ["retained", "reachable", "unreachable", "retainedByMember"]:
                        return value
                    for child in value.values():
                        found = find(child)
                        if found: return found
                return None
            states[name] = find(doc) or {}
    if strict:
        assert all(states[n].get("state") != "unreachable" and states[n] for n in ["AddHello", "MainHello", "DeadHello", "Greeter"]), states
        assert all(states[n].get("state") == "unreachable" for n in ["CommentOnly", "NeverMade"]), states
    return {"id": "C-P0-3", "label": label, "states": states}


def module_coverage_case(binary, baseline, root, output):
    """Use the actual SwiftPM description and remove only owned fixture Lib units, then restore them."""
    selected = index(root).resolve()
    description_path = selected.parent.parent / "description.json"
    with description_path.open("rb") as stream:
        data = stream.read(8 * 1024 * 1024 + 1)
    assert len(data) <= 8 * 1024 * 1024
    description = json.loads(data)
    commands = [c for c in description["swiftCommands"].values() if c["moduleName"] == "Lib"]
    assert commands and all(str(selected) in c["otherArguments"] for c in commands), commands
    stems = {Path(p).name for c in commands for p in c["objects"] + [c["moduleOutputPath"]]}
    units = selected / "v5/units"
    assert units.is_dir()
    removed = [p for p in units.iterdir() if p.is_file() and any(p.name.startswith(stem + "-") for stem in stems)]
    assert removed, (sorted(stems), sorted(p.name for p in units.iterdir()))
    complete = json.loads(analyze(binary, root, output, "module-coverage-complete", ["dead", "--report-format", "json"]).stdout)
    assert not any('"Lib": missing-observed-source-units' in x for x in complete.get("limitations", []))
    backup = root / "unit-backup"
    backup.mkdir()
    try:
        for p in removed:
            p.rename(backup / p.name)
        public = json.loads(analyze(baseline, root, output, "module-coverage-public", ["dead", "--report-format", "json"]).stdout)
        candidate = json.loads(analyze(binary, root, output, "module-coverage-missing", ["dead", "--report-format", "json"]).stdout)
        notes = [x for x in candidate.get("limitations", []) if x.startswith("build-module-coverage:")]
        assert any('"Lib": missing-observed-source-units' in x and "freshness are unverified" in x for x in notes), candidate
        assert not any(x.startswith("build-module-coverage:") for x in public.get("limitations", []))
        return {"id": "C-P0-1", "label": "swiftpm-missing-local-module", "candidateControls": "passed",
                "removedFixtureUnits": sorted(p.name for p in removed), "descriptionSHA256": hashlib.sha256(data).hexdigest(),
                "candidateLimitations": notes, "publicLimitations": public.get("limitations", []),
                "scope": "actual synthetic SwiftPM build metadata and omitted Lib units; no Xcode/private-workspace claim"}
    finally:
        for p in removed:
            retained = backup / p.name
            if retained.exists():
                retained.rename(p)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "release-0.28.0.tar.gz"
    with urllib.request.urlopen(RELEASE, timeout=60) as response:
        data = response.read(100 * 1024 * 1024 + 1)
    assert hashlib.sha256(data).hexdigest() == DIGEST
    archive.write_bytes(data)
    baseline = output / "release-0.28.0/cartograph"
    with tarfile.open(archive) as tar:
        members = [m for m in tar.getmembers() if m.isfile() and Path(m.name).name == "cartograph"]
        assert len(members) == 1
        baseline.parent.mkdir()
        baseline.write_bytes(tar.extractfile(members[0]).read())
        baseline.chmod(0o755)
    result = {"scope": "generalized synthetic compiler fixtures; not the reported company workspace",
              "release": {"version": "0.28.0", "archiveSHA256": DIGEST}, "cases": []}
    try:
        for name, binary, strict in [("release028", baseline, False), ("candidate", args.cartograph.resolve(), True)]:
            for visibility in [False, True]:
                label = name + ("-visibility" if visibility else "-ordinary")
                result["cases"].append(import_case(binary, output / label, output / "logs", label, visibility, strict))
                for scope in ["outside-capture", "git-ignored", "explicit-filter"]:
                    external = label + "-" + scope
                    result["cases"].append(import_case(binary, output / external, output / "logs", external,
                                                       visibility, strict, scope=scope))
            syntax = Path(__file__).resolve().parents[1] / ".build/checkouts/swift-syntax"
            result["cases"].append(macro_case(binary, output / "macro", output / "logs", name + "-macro", syntax, strict))
        result["cases"].append(module_coverage_case(args.cartograph.resolve(), baseline,
                                                   output / "candidate-ordinary", output / "logs"))
    finally:
        write(output, "results.json", json.dumps(result, indent=2, sort_keys=True))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
