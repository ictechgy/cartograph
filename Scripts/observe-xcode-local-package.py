#!/usr/bin/env python3
"""Diagnostic-only native observations for the reviewed finite local-package fixture.

No target-scope receipt, usable selector, or production package-support claim is issued.
Builds only the checked-in synthetic fixture, never a user-supplied project.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import platform
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import time

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "Fixtures/XcodeLocalPackageScope"
SPEC = importlib.util.spec_from_file_location("xcode_scope", ROOT / "Scripts/cartograph-xcode-scope.py")
SCOPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCOPE)


def process_supervisor():
    # POSIX-only dependency stays lazy so parsing checks can run on Windows.
    spec = importlib.util.spec_from_file_location("native_process", ROOT / "Scripts/benchmark-indexstore-cli.py")
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    return supervisor


def run(argv, root: Path, output: Path, name: str, timeout: int, maximum=8 * 1024 * 1024) -> bytes:
    """Bound both live streams with the existing owned-process-group supervisor.

    The combined budget is divided equally: a 32 MiB call permits at most 16 MiB
    on each stream. A quiet stderr does not transfer its allowance to stdout.
    """
    SCOPE.require(type(maximum) is int and maximum >= 2 and maximum % 2 == 0,
                  "Combined process output budget must be a positive even byte count")
    SCOPE.require(name == Path(name).name and name not in ("", ".", ".."), "Invalid process receipt name")
    stem = output / name
    SCOPE.require(not any(Path(str(stem) + suffix).exists() for suffix in (".json", ".stdout", ".stderr")),
                  "Process observation already exists")
    per_stream = maximum // 2
    receipt = process_supervisor().run(argv, root, stem, timeout, stream_limit=per_stream)
    SCOPE.require(receipt.get("returncode") == 0 and receipt.get("timed_out") is False
                  and receipt.get("owned_root_reaped") is True and receipt.get("ownership_lost") is False
                  and receipt.get("cleanup_errors") == [] and not receipt.get("output_limit_exceeded")
                  and not receipt.get("exception_type"), "Process observation did not finish with verified cleanup")
    SCOPE.require(receipt.get("stream_limit_bytes") == per_stream, "Process stream budget was not applied")
    counts = receipt.get("retained_stream_bytes", {})
    data = {}
    for stream in ("stdout", "stderr"):
        path = Path(str(stem) + "." + stream)
        SCOPE.require(receipt.get(stream) == str(path), "Unexpected process output path")
        data[stream] = SCOPE.bounded(path, per_stream)
        SCOPE.require(type(counts.get(stream)) is int and counts[stream] == len(data[stream]),
                      "Retained stream byte count differs from process receipt")
    return data["stdout"]


def checked(path: str | Path, roots: list[Path]) -> Path:
    path = Path(path)
    SCOPE.require(path.is_absolute(), "Observed path is not absolute")
    resolved = path.resolve()
    SCOPE.require(any(resolved.is_relative_to(root.resolve()) for root in roots), "Observed path escapes diagnostic roots")
    return resolved


def operand(argv: list[str], option: str) -> str | None:
    if argv.count(option) != 1:
        return None
    tail = argv[argv.index(option) + 1:]
    while tail and tail[0] == "-Xlinker":
        tail = tail[1:]
    return tail[0] if tail and not tail[0].startswith("-") else None


def commands(log: str) -> list[list[str]]:
    result = []
    for line in log.splitlines():
        if not any(marker in line for marker in (" -output-file-map ", " -filelist ", " -map ")):
            continue
        try:
            argv = shlex.split(line.strip())
        except ValueError as error:
            raise SCOPE.CaptureError("Unparseable observed compiler/link command") from error
        SCOPE.require(len(argv) <= 4_096 and len(line.encode()) <= 256 * 1_024, "Compiler command budget exceeded")
        SCOPE.require(argv and (argv[0].startswith("/") or argv[0].startswith("builtin-")),
                      "Unknown build-log command prefix")
        result.append(argv)
        SCOPE.require(len(result) <= 256, "Observed command count exceeded")
    return result


def link_map(text: str) -> dict:
    objects, live, dead, section = {}, {}, {}, ""
    for line in text.splitlines():
        if line.startswith("# "):
            section = line
            continue
        if section == "# Object files:":
            match = re.match(r"\[\s*(\d+)\]\s+(.+)", line)
            if match:
                SCOPE.require(match[1] not in objects, "Ambiguous link-map object owner")
                objects[match[1]] = match[2]
        elif section in ("# Symbols:", "# Dead Stripped Symbols:"):
            match = re.search(r"\[\s*(\d+)\]\s+(.+)$", line)
            if match:
                counts = live if section == "# Symbols:" else dead
                counts[match[1]] = counts.get(match[1], 0) + 1
    SCOPE.require(len(objects) <= 256 and len(live) <= 256 and len(dead) <= 256, "Link-map owner budget exceeded")
    return {"objectFiles": objects, "liveSymbolCountByOwner": live, "deadSymbolCountByOwner": dead,
            "unresolvedOwnerIndices": sorted((set(live) | set(dead)) - set(objects)),
            "limitation": "Object-list presence alone is not contribution. Owner counts need actual compiler-object/link-step joins; no runtime or complete-membership proof."}


class ObservedFiles:
    def __init__(self, project: Path, build: Path):
        self.project, self.build = project, build
        self.items, self.document_bytes, self.object_bytes = {}, 0, 0

    def read(self, path: str | Path, *, binary: bool = False) -> bytes:
        resolved = checked(path, [self.build] if binary else [self.project, self.build])
        maximum = 64 * 1024 * 1024 if binary else 8 * 1024 * 1024
        data = SCOPE.bounded(resolved, maximum)
        digest = hashlib.sha256(data).hexdigest()
        if str(resolved) not in self.items:
            self.items[str(resolved)] = {"sha256": digest, "bytes": len(data), "kind": "object-or-product" if binary else "document-or-source"}
            if binary:
                self.object_bytes += len(data)
            else:
                self.document_bytes += len(data)
        else:
            SCOPE.require(self.items[str(resolved)]["sha256"] == digest, "Observed bytes changed during diagnostic read")
        SCOPE.require(len(self.items) <= 256 and self.document_bytes <= 32 * 1024 * 1024
                      and self.object_bytes <= 256 * 1024 * 1024, "Aggregate observation budget exceeded")
        return data


def inspect(log: str, project: Path, build: Path) -> dict:
    files = ObservedFiles(project, build)
    observations, unknown = [], []
    for argv in commands(log):
        row = {"argv": argv, "module": operand(argv, "-module-name"), "output": operand(argv, "-o")}
        output_map = operand(argv, "-output-file-map")
        if output_map:
            value = json.loads(files.read(output_map))
            SCOPE.require(isinstance(value, dict) and len(value) <= 256, "Invalid compiler output map")
            entries = []
            for source, outputs in value.items():
                if not source:
                    continue
                SCOPE.require(isinstance(outputs, dict), "Invalid compiler source output row")
                source_path = checked(source, [project])
                files.read(source_path)
                object_path = outputs.get("object")
                if object_path:
                    files.read(object_path, binary=True)
                entries.append({"source": str(source_path), "outputs": outputs})
            row["outputMap"] = {"path": output_map, "entries": entries}
        lists = [value for value in [operand(argv, "-filelist")] if value]
        lists += [arg[1:] for arg in argv if arg.startswith("@") and arg.endswith(".SwiftFileList")]
        row["fileLists"] = []
        for path in dict.fromkeys(lists):
            content = files.read(path).decode("utf-8")
            paths = []
            for line in content.splitlines():
                values = shlex.split(line)
                SCOPE.require(len(values) == 1, "Unknown file-list line")
                item = checked(values[0], [project, build])
                files.read(item, binary=item.suffix in (".o", ".a"))
                paths.append(str(item))
            row["fileLists"].append({"path": path, "paths": paths})
        map_path = operand(argv, "-map")
        if map_path:
            row["linkMap"] = {"path": map_path, **link_map(files.read(map_path).decode("utf-8"))}
        if row["output"]:
            path = checked(row["output"], [build])
            if path.is_file():
                files.read(path, binary=True)
            else:
                unknown.append({"path": str(path), "reason": "observed-output-not-a-regular-file"})
        observations.append(row)
    SCOPE.require(observations, "No bounded compiler/link commands were observed")
    return {"commands": observations, "files": files.items, "unknown": unknown,
            "contributionStatus": "not-certified: raw observations require compiler-output/unit/link-owner joins",
            "noProductionReceipt": True}


def prepare_variant(project: Path, logs: Path, negative: bool) -> None:
    if not negative:
        return
    pbx = project / "Scope.xcodeproj/project.pbxproj"
    value = json.loads(run(["plutil", "-convert", "json", "-o", "-", str(pbx)], project, logs, "variant-project", 30))
    objects = value["objects"]
    core = next(x for x in objects.values() if x.get("name") == "CoreBlueprint")
    other = next(x for x in objects.values() if x.get("name") == "OtherBlueprint")
    other["packageProductDependencies"] = core.pop("packageProductDependencies")
    phase = lambda target: next(objects[p] for p in target["buildPhases"] if objects[p]["isa"] == "PBXFrameworksBuildPhase")
    phase(core)["files"].remove("000000000000000000000102")
    phase(other)["files"].append("000000000000000000000102")
    pbx.write_bytes(plistlib.dumps(value))
    (project / "Core/Core.swift").write_text("public func changedValue() -> Int { 42 }\npublic func otherValue() -> Int { 7 }\n")
    (project / "Other/OtherTests.swift").write_text("import XCTest\nimport CoreKit\nimport ArithmeticCore\nfinal class OtherTests: XCTestCase {\n    func testOther() { XCTAssertEqual(otherValue(), 7); XCTAssertEqual(packageValue(), 42) }\n}\n")


def verified_fixture(output: Path) -> None:
    tracked = run(["git", "ls-tree", "-r", "--name-only", "HEAD", "--", "Fixtures/XcodeLocalPackageScope"],
                        ROOT, output, "fixture-files", 30).decode().splitlines()
    SCOPE.require(0 < len(tracked) <= 32, "Unexpected fixture inventory size")
    actual, entries = [], 0
    for path in FIXTURE.rglob("*"):
        entries += 1
        SCOPE.require(entries <= 256, "Fixture entry budget exceeded")
        SCOPE.require(not path.is_symlink(), "Fixture symlinks are unsupported")
        if path.is_file():
            actual.append(path.relative_to(ROOT).as_posix())
        SCOPE.require(len(actual) <= 32, "Unexpected fixture files")
    SCOPE.require(sorted(actual) == sorted(tracked), "Fixture has missing or untracked/ignored inputs")
    for number, name in enumerate(tracked):
        committed = run(["git", "show", "HEAD:" + name], ROOT, output, f"fixture-blob-{number}", 30, 8 * 1024 * 1024)
        SCOPE.require(committed == SCOPE.bounded(ROOT / name, 8 * 1024 * 1024), "Fixture differs from reviewed commit")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output).resolve()
    SCOPE.require(platform.system() == "Darwin" and not output.exists() and not output.is_relative_to(ROOT),
                  "Use a new diagnostic directory outside the checkout on macOS")
    output.mkdir(parents=True)
    # The only executable project input is the reviewed fixture at this checkout's exact HEAD.
    dirty = run(["git", "status", "--porcelain", "--untracked-files=all", "--", str(FIXTURE)], ROOT, output, "fixture-status", 30)
    SCOPE.require(not dirty.strip(), "Commit the reviewed synthetic fixture before native observation")
    verified_fixture(output)
    source_sha = run(["git", "rev-parse", "HEAD"], ROOT, output, "source-sha", 30).decode().strip()
    source_tree = run(["git", "rev-parse", "HEAD^{tree}"], ROOT, output, "source-tree", 30).decode().strip()
    developer = Path(run(["xcode-select", "--print-path"], ROOT, output, "developer", 30).decode().strip()).resolve()
    compiler = Path(run(["xcrun", "--find", "swiftc"], ROOT, output, "swiftc", 30).decode().strip()).resolve()
    swift = run(["xcrun", "--find", "swift"], ROOT, output, "swift", 30).decode().strip()
    library = checked(compiler.parent.parent / "lib/libIndexStore.dylib", [developer])
    SCOPE.require(library.is_file(), "Selected toolchain has no observable libIndexStore")
    run(["xcodebuild", "-version"], ROOT, output, "xcode-version", 30)
    run([str(compiler), "--version"], ROOT, output, "swift-version", 30)
    run([swift, "build", "--build-tests", "--jobs", "3"], ROOT, output, "probe-build", 600, 32 * 1024 * 1024)
    started, results = time.monotonic(), {}
    for name in ("core-consumes-package", "compiled-for-other-only"):
        logs = output / name
        logs.mkdir()
        project = logs / "project"
        shutil.copytree(FIXTURE, project)
        prepare_variant(project, logs, negative=name == "compiled-for-other-only")
        before = SCOPE.inventory(project)
        build = logs / "DerivedData"
        destination = "platform=macOS,arch=" + platform.machine()
        command = ["xcodebuild", "-project", str(project / "Scope.xcodeproj"), "-scheme", "Scope",
                   "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(build),
                   "build-for-testing", "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=YES",
                   "LD_GENERATE_MAP_FILE=YES", "ARCHS=" + platform.machine()]
        run(command + ["-showBuildSettings", "-json"], project, logs, "build-settings", 600, 8 * 1024 * 1024)
        log = run(command, project, logs, "build", 600, 32 * 1024 * 1024).decode("utf-8")
        SCOPE.require(before == SCOPE.inventory(project), "Fixture source/metadata changed during build")
        observations = inspect(log, project, build)
        SCOPE.save(logs / "compiler-link-observations.json", observations)
        stores = [x for x in (build / "Index.noindex/DataStore", build / "Index/DataStore") if x.is_dir()]
        SCOPE.require(len(stores) == 1, "Expected one Xcode index store")
        request = logs / "probe-request.json"
        SCOPE.save(request, {"projectRoot": str(project), "buildRoot": str(build), "store": str(stores[0]),
                            "library": str(library), "developerRoot": str(developer),
                            "output": str(logs / "unit-observations.json")})
        run(["/usr/bin/env", "CARTOGRAPH_LOCAL_PACKAGE_PROBE=" + str(request), swift, "test", "--skip-build",
                   "--filter", "LocalPackageUnitObservationTests"], ROOT, logs, "unit-probe", 240, 8 * 1024 * 1024)
        units = json.loads(SCOPE.bounded(logs / "unit-observations.json", 8 * 1024 * 1024))
        SCOPE.require(before == SCOPE.inventory(project), "Fixture changed while raw units were read")
        for path, identity in observations["files"].items():
            maximum = (64 if identity["kind"] == "object-or-product" else 8) * 1024 * 1024
            SCOPE.require(hashlib.sha256(SCOPE.bounded(Path(path), maximum)).hexdigest() == identity["sha256"],
                          "Observed compiler/link input changed while raw units were read")
        results[name] = {"sourceInventory": before, "observedUnits": len(units["units"]),
                         "compilerCommands": len(observations["commands"]), "contributionStatus": observations["contributionStatus"]}
    SCOPE.save(output / "diagnostic-results.json", {"status": "observations-collected", "sourceCommit": source_sha,
        "sourceTree": source_tree, "secondsIncludingXcodePreparation": time.monotonic() - started, "variants": results,
        "limitation": "Diagnostic evidence only. Package support, usable selectors, complete membership and runtime behavior are not certified."})


if __name__ == "__main__":
    main()
