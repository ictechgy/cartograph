#!/usr/bin/env python3
"""Build a trusted, bounded single-project Swift Xcode test universe and capture its inputs.

This runs build-for-testing (not tests). Review the project before invoking it.
Unsupported scripts, packages, plugins, external/conditional membership and resources
are rejected before xcodebuild. A receipt is an auditable producer claim, not a signature,
test-coverage proof, or permission to skip tests. Use the exact captured test context.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import stat
import time
import xml.etree.ElementTree as ET

# Shared bounded command runner; the published scripts must be installed together.
_spec = importlib.util.spec_from_file_location("swiftpm_scope", Path(__file__).with_name("cartograph-swiftpm-scope.py"))
_shared = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_shared)
CaptureError, run, save = _shared.CaptureError, _shared.run, _shared.save

INPUT_SUFFIXES = {".swift", ".m", ".mm", ".h", ".xib", ".storyboard", ".pbxproj", ".xcscheme",
                  ".xctestplan", ".xcconfig", ".plist", ".entitlements", ".resolved"}
UNBOUND_SETTINGS = {"EXCLUDED_SOURCE_FILE_NAMES", "INCLUDED_SOURCE_FILE_NAMES", "SWIFT_OBJC_BRIDGING_HEADER",
                    "GCC_PREFIX_HEADER", "SWIFT_EXEC", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC", "CC", "CXX", "LD",
                    "OTHER_SWIFT_FLAGS", "OTHER_LDFLAGS", "SWIFT_INCLUDE_PATHS", "HEADER_SEARCH_PATHS",
                    "FRAMEWORK_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "DEVELOPER_DIR",
                    "CONFIGURATION_BUILD_DIR", "CONFIGURATION_TEMP_DIR", "BUILD_DIR", "BUILD_ROOT", "BUILT_PRODUCTS_DIR", "OBJROOT", "SYMROOT", "DSTROOT", "TARGET_BUILD_DIR", "TARGET_TEMP_DIR", "TEMP_DIR", "DERIVED_FILE_DIR", "SHARED_PRECOMPS_DIR", "INDEX_DATA_STORE_DIR", "TEST_HOST", "BUNDLE_LOADER", "TEST_TARGET_NAME", "LD_DYLIB_INSTALL_NAME", "DYLIB_INSTALL_NAME_BASE", "INFOPLIST_FILE", "INFOPLIST_PREFIX_HEADER", "CODE_SIGN_ENTITLEMENTS", "MODULEMAP_FILE", "MODULEMAP_PRIVATE_FILE"}


def require(condition, message):
    if not condition:
        raise CaptureError(message)


def relative(value):
    return isinstance(value, str) and 0 < len(value.encode()) <= 4096 and not any(
        x in value for x in ("\\", "$(", "${", ":")) and all(ord(c) >= 32 for c in value) and all(
        x not in ("", ".", "..") for x in value.split("/"))


def bounded(path, maximum):
    require(path.is_file() and not path.is_symlink(), f"Nonregular/symlink input: {path}")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, f"Input exceeds byte budget: {path}")
    return data


def inventory(root):
    result, pending, entries, total = {}, [root], 0, 0
    while pending:
        for path in sorted(pending.pop().iterdir()):
            entries += 1
            require(entries <= 50000 and not path.is_symlink(), "Inventory budget or symlink boundary exceeded")
            if path.is_dir():
                if path.name not in (".git", ".build"):
                    pending.append(path)
                continue
            if path.suffix not in INPUT_SUFFIXES:
                continue
            data = bounded(path, 4 * 1024 * 1024)
            total += len(data)
            require(len(result) < 10000 and total <= 64 * 1024 * 1024, "Project input byte budget exceeded")
            result[path.relative_to(root).as_posix()] = hashlib.sha256(data).hexdigest()
    return result


def valid_runpaths(value):
    values = value.split() if isinstance(value, str) else value if isinstance(value, list) else None
    allowed = {"$(inherited)", "@loader_path/Frameworks", "@loader_path/../Frameworks", "@loader_path/../../../",
               "@executable_path/Frameworks", "@executable_path/../Frameworks"}
    return values is not None and all(isinstance(x, str) and x in allowed for x in values)


def membership(plist):
    """Pure preflight: no Xcode, compiler or project code is executed here."""
    objects = plist.get("objects", {})
    project = objects.get(plist.get("rootObject"), {})
    ids = project.get("targets", [])
    require(len(objects) <= 50000 and project.get("isa") == "PBXProject" and 0 < len(ids) <= 1000
            and len(set(ids)) == len(ids) and not project.get("packageReferences")
            and not project.get("projectReferences") and not project.get("projectDirPath")
            and not project.get("projectRoot"), "Only explicit local single-project targets are supported")
    for obj in objects.values():
        require(obj.get("isa") not in {"PBXShellScriptBuildPhase", "PBXBuildRule", "PBXAggregateTarget",
                "PBXFileSystemSynchronizedRootGroup", "XCSwiftPackageProductDependency"}
                and "platformFilter" not in obj and "platformFilters" not in obj,
                "Scripts, plugins, packages, synchronized groups or platform-filtered membership are unsupported")
        require("baseConfigurationReference" not in obj, "External xcconfig is unsupported")
        require(not any("[" in key or (key == "SDKROOT" and value != "macosx")
                        or (key == "LD_RUNPATH_SEARCH_PATHS" and not valid_runpaths(value))
                        or (key in UNBOUND_SETTINGS and value not in ("", "$(inherited)"))
                        for key, value in obj.get("buildSettings", {}).items()),
                "Conditional, custom compiler/linker or external input settings are unsupported")
    paths, seen, pending = {}, set(), [(project.get("mainGroup"), "", 0)]
    while pending:
        ident, parent, depth = pending.pop()
        require(ident not in seen and ident in objects and depth <= 128, "Missing/shared/cyclic project group")
        seen.add(ident)
        obj = objects[ident]
        tree, path = obj.get("sourceTree", "<group>"), obj.get("path", "")
        if tree not in ("<group>", "SOURCE_ROOT"):
            continue
        require(not path or relative(path), "External project path")
        combined = "/".join(x for x in ("" if tree == "SOURCE_ROOT" else parent, path) if x)
        if obj.get("isa") == "PBXGroup":
            pending += [(child, combined, depth + 1) for child in obj.get("children", [])]
        elif obj.get("isa") == "PBXFileReference" and combined:
            paths[ident] = combined
    targets, owners, linked = {}, set(), {}
    product_owners = {}
    for ident in ids:
        ref = objects[ident].get("productReference")
        require(ref not in product_owners, "Shared/missing product reference")
        product_owners[ref] = ident
    for ident in ids:
        obj = objects[ident]
        require(obj.get("isa") == "PBXNativeTarget" and obj.get("productType") in {
            "com.apple.product-type.framework", "com.apple.product-type.library.static",
            "com.apple.product-type.application", "com.apple.product-type.bundle.unit-test"}
            and not obj.get("buildRules") and not obj.get("packageProductDependencies"), "Unsupported target")
        sources = []
        for phase_id in obj.get("buildPhases", []):
            phase = objects[phase_id]
            kind, files = phase.get("isa"), phase.get("files", [])
            require(kind in {"PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase",
                             "PBXHeadersBuildPhase"}, "Unsupported build phase")
            require(kind not in {"PBXResourcesBuildPhase", "PBXHeadersBuildPhase"} or not files,
                    "Nonempty resource/header phases are unsupported")
            for file_id in files:
                file = objects[file_id]
                ref = file.get("fileRef")
                require(ref in objects and "settings" not in file, "Conditional/generated build file")
                if kind == "PBXSourcesBuildPhase":
                    source = paths.get(ref, "")
                    require(source.endswith(".swift") and source not in owners, "Non-Swift, missing or shared source")
                    owners.add(source)
                    sources.append(source)
                elif kind == "PBXFrameworksBuildPhase":
                    require(objects[ref].get("sourceTree") in {"SDKROOT", "DEVELOPER_DIR", "BUILT_PRODUCTS_DIR"},
                            "Unbound binary framework")
                    tree, path = objects[ref]["sourceTree"], objects[ref].get("path", "")
                    require(relative(path), "Absolute, escaping or macro framework path")
                    if tree != "BUILT_PRODUCTS_DIR":
                        require(system_framework_path(tree, path), "Unsupported system framework path")
                    if tree == "BUILT_PRODUCTS_DIR":
                        require(ref in product_owners, "Built framework has no local producer")
                        linked.setdefault(ident, set()).add(product_owners[ref])
        deps = [objects[x].get("target") for x in obj.get("dependencies", [])]
        require(sources and all(x in ids for x in deps), "Empty target or external dependency")
        targets[ident] = {"id": ident, "name": obj["name"], "productType": obj["productType"],
                          "sources": sorted(sources), "dependencies": sorted(deps)}
    for ident, links in linked.items():
        closure, pending = set(), list(targets[ident]["dependencies"])
        while pending:
            item = pending.pop()
            if item not in closure:
                closure.add(item)
                pending += targets[item]["dependencies"]
        require(links <= closure, "Implicit target dependencies must be explicit")
    return targets


def system_framework_path(tree, path):
    prefix = "System/Library/Frameworks/" if tree == "SDKROOT" else "Platforms/MacOSX.platform/Developer/Library/Frameworks/"
    return relative(path) and path.startswith(prefix) and "/" not in path[len(prefix):] and path.endswith(".framework")


def framework_references(plist):
    objects = plist["objects"]
    refs = set()
    for phase in objects.values():
        if phase.get("isa") != "PBXFrameworksBuildPhase":
            continue
        for ident in phase.get("files", []):
            ref = objects[objects[ident]["fileRef"]]
            if ref["sourceTree"] in ("SDKROOT", "DEVELOPER_DIR"):
                refs.add((ref["sourceTree"], ref["path"]))
    require(len(refs) <= 64, "System framework count budget exceeded")
    return sorted(refs)


def framework_inventory(path, allowed_root, budget=None):
    require(path.is_dir() and path.resolve().is_relative_to(allowed_root), "System framework resolves outside its toolchain root")
    result, links, pending = {}, {}, [path.resolve()]
    budget = [0, 0] if budget is None else budget
    while pending:
        for item in sorted(pending.pop().iterdir()):
            budget[0] += 1
            require(budget[0] <= 10000, "System framework entry budget exceeded")
            if item.is_symlink():
                require(item.resolve().is_relative_to(path.resolve()), "System framework symlink escapes its captured bundle")
                links[str(item)] = str(item.resolve())
            elif item.is_dir():
                pending.append(item)
            else:
                data = bounded(item, 16 * 1024 * 1024)
                budget[1] += len(data)
                require(budget[1] <= 128 * 1024 * 1024, "System framework byte budget exceeded")
                result[str(item)] = hashlib.sha256(data).hexdigest()
    require(result, "System framework has no captured regular inputs")
    return result, links


def capture_frameworks(plist, root, output, timeout):
    refs = framework_references(plist)
    if not refs:
        return []
    developer = Path(os.environ.get("DEVELOPER_DIR") or run(["xcode-select", "-p"], root, output, "developer-root", timeout).decode().strip()).resolve()
    sdk = Path(run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], root, output, "sdk-root", timeout).decode().strip()).resolve()
    require(sdk.is_relative_to(developer / "Platforms/MacOSX.platform/Developer/SDKs") and sdk.name.endswith(".sdk"),
            "SDK does not belong to the selected Xcode developer root")
    result, budget = [], [0, 0]
    for tree, path in refs:
        allowed = sdk if tree == "SDKROOT" else developer
        resolved = (allowed / path).resolve()
        files, links = framework_inventory(allowed / path, allowed, budget)
        result.append({"sourceTree": tree, "path": path, "root": str(allowed), "developerRoot": str(developer),
                       "resolvedPath": str(resolved), "files": files, "links": links})
    return result


def scheme_membership(root, project, scheme, test_plan):
    path = project + "/xcshareddata/xcschemes/" + scheme + ".xcscheme"
    data = bounded(root / path, 1024 * 1024)
    require(b"<!DOCTYPE" not in data and b"<!ENTITY" not in data, "Scheme XML entities are unsupported")
    xml = ET.fromstring(data)
    require(not any(list(xml.iter(name)) for name in (
        "ExecutionAction", "SkippedTests", "SelectedTests", "EnvironmentVariable", "CommandLineArgument")),
        "Scheme actions, runtime options or partial selections are unsupported")
    require(all(x.get("ReferencedContainer") == "container:" + project for x in xml.iter("BuildableReference")),
            "External scheme build targets are unsupported")
    actions = list(xml.iter("TestAction"))
    require(len(actions) == 1, "Expected one scheme TestAction")
    config = actions[0].get("buildConfiguration")
    require(config and relative(config), "Missing test configuration")
    plans = [x.get("reference", "").removeprefix("container:") for x in xml.iter("TestPlanReference")]
    ids = []
    if plans:
        require(test_plan in plans and relative(test_plan), "Select an explicit shared test plan path")
        plan = json.loads(bounded(root / test_plan, 1024 * 1024))
        configs = plan.get("configurations", [])
        require(len(configs) == 1 and not configs[0].get("options") and not plan.get("defaultOptions"),
                "Only one test-plan configuration without runtime options is supported")
        for item in plan.get("testTargets", []):
            target = item.get("target", {})
            require(item.get("enabled") is not False and "selectedTests" not in item and "skippedTests" not in item
                    and target.get("containerPath") == "container:" + project, "Partial/external plan target")
            ids.append(target.get("identifier"))
    else:
        require(test_plan is None, "Unexpected test plan")
        for item in xml.iter("TestableReference"):
            require(item.get("skipped") == "NO", "Skipped test targets are unsupported")
            refs = list(item.iter("BuildableReference"))
            require(len(refs) == 1 and refs[0].get("ReferencedContainer") == "container:" + project,
                    "External/missing scheme target")
            ids.append(refs[0].get("BlueprintIdentifier"))
    require(ids and len(ids) <= 1000 and len(set(ids)) == len(ids), "Empty/duplicate test universe")
    return path, config, sorted(ids)


def product_inventory(root):
    result, links, pending, total, entries = {}, {}, [root], 0, 0
    while pending:
        for path in sorted(pending.pop().iterdir()):
            entries += 1
            require(entries <= 10000, "Product entry budget exceeded")
            if path.is_symlink():
                require(path.resolve().is_relative_to(root), "Product symlink escapes capture")
                links[str(path)] = str(path.resolve())
            elif path.is_dir():
                pending.append(path)
            else:
                data = bounded(path, 128 * 1024 * 1024)
                total += len(data)
                require(len(result) < 10000 and total <= 512 * 1024 * 1024, "Product byte budget exceeded")
                result[str(path)] = hashlib.sha256(data).hexdigest()
    return result, links


def capture(args):
    root, output, binary = Path(args.project).resolve(), Path(args.output).resolve(), Path(args.cartograph).resolve()
    require(relative(args.xcode_project) and "/" not in args.xcode_project and args.xcode_project.endswith(".xcodeproj") and relative(args.scheme),
            "Use a relative .xcodeproj path and shared scheme name")
    require(not output.is_relative_to(root) and not output.exists(), "Use a new output directory outside the project")
    require(1 <= args.timeout <= 3600 and platform.system() == "Darwin", "Capture requires macOS and timeout 1...3600")
    output.mkdir(parents=True)
    started = time.monotonic()
    before = inventory(root)
    # plutil reads metadata only. No project command is invoked until both preflights succeed.
    project_bytes = run(["plutil", "-convert", "json", "-o", "-", str(root / args.xcode_project / "project.pbxproj")],
                        root, output, "project-plist", args.timeout)
    project_plist = json.loads(project_bytes)
    targets = membership(project_plist)
    scheme_path, configuration, selected = scheme_membership(root, args.xcode_project, args.scheme, args.test_plan)
    require(all(x in targets and targets[x]["productType"] == "com.apple.product-type.bundle.unit-test" for x in selected),
            "Selected scheme entries must be local unit-test targets")
    frameworks = capture_frameworks(project_plist, root, output, args.timeout)
    arch = platform.machine()
    require(arch in ("arm64", "x86_64"), "Unsupported native architecture")
    destination = "platform=macOS,arch=" + arch
    derived = output / "DerivedData"
    common = ["xcodebuild", "-project", str(root / args.xcode_project), "-configuration", configuration,
              "-destination", destination, "-derivedDataPath", str(derived), "-scheme", args.scheme]
    if args.test_plan:
        common += ["-testPlan", Path(args.test_plan).stem]
    overrides = ["CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=YES", "ARCHS=" + arch]
    settings_bytes = run(common + ["-showBuildSettings", "-json"] + overrides, root, output, "build-settings", args.timeout)
    settings = json.loads(settings_bytes)
    # Xcode may omit unbuilt targets from scheme settings. Query each only after safe preflight.
    for target in targets.values():
        rows = [x for x in settings if x.get("target") == target["name"]]
        if not rows:
            extra = run(["xcodebuild", "-project", str(root / args.xcode_project), "-target", target["name"],
                         "-configuration", configuration, "-showBuildSettings", "-json"] + overrides,
                        root, output, "settings-" + target["id"], args.timeout)
            rows = [x for x in json.loads(extra) if x.get("target") == target["name"]]
            settings += rows
        require(len(rows) == 1 and rows[0]["buildSettings"].get("PRODUCT_MODULE_NAME"), "Ambiguous compiler module")
        target["module"] = rows[0]["buildSettings"]["PRODUCT_MODULE_NAME"]
    require(len({x["module"] for x in targets.values()}) == len(targets),
            "Compiler module names must be unique across every project target")
    run(common + ["build-for-testing"] + overrides, root, output, "build-for-testing", args.timeout, 32 * 1024 * 1024)
    products_root = derived / "Build/Products"
    test_runs = list(products_root.glob("*.xctestrun"))
    require(len(test_runs) == 1, "Expected one freshly built xctestrun")
    stores = [p for p in (derived / "Index.noindex/DataStore", derived / "Index/DataStore") if p.is_dir()]
    require(len(stores) == 1, "Expected one fresh Xcode index store")
    command = [str(binary), "snapshot", "--project", str(root), "--index-store", str(stores[0])]
    if args.config:
        command += ["--config", str(Path(args.config).resolve())]
    snapshot = json.loads(run(command, root, output, "snapshot", args.timeout, 128 * 1024 * 1024))
    after = inventory(root)
    require(before == after, "Inputs changed during capture; inspect generated files and recapture")
    products, links = product_inventory(products_root)
    run_plist = plistlib.loads(bounded(test_runs[0], 8 * 1024 * 1024))
    rows = run_plist["TestConfigurations"][0]["TestTargets"] if "TestConfigurations" in run_plist else [v for k, v in run_plist.items() if not k.startswith("__")]
    test_hosts = {}
    developer = Path(settings[0]["buildSettings"]["DEVELOPER_DIR"]).resolve()
    for row in rows:
        require(not row.get("IsAppHostedTestBundle"), "App-hosted test bundles are unsupported")
        if "TestHostPath" in row:
            declared = row["TestHostPath"].replace("__PLATFORMS__", str(developer / "Platforms"))
            expected = developer / "Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"
            require(Path(declared) == expected and Path(declared).resolve() == expected,
                    "Only the selected Xcode's standard non-app XCTest host is supported")
            test_hosts[str(expected)] = hashlib.sha256(bounded(expected, 16 * 1024 * 1024)).hexdigest()
    receipt = {"format": "cartograph-xcode-target-scope", "version": 1, "projectRoot": str(root),
               "project": args.xcode_project, "scheme": args.scheme, "schemePath": scheme_path,
               "testPlan": args.test_plan, "configuration": configuration, "destination": destination, "architecture": arch,
               "inputFingerprint": snapshot.get("inputFingerprint"), "before": before, "after": after,
               "buildSettingsJSON": json.dumps(settings, sort_keys=True), "testRunPath": str(test_runs[0]),
               "testRunSHA256": products[str(test_runs[0])], "products": products, "productLinks": links,
               "targets": sorted(targets.values(), key=lambda x: x["id"]), "selectedTargetIDs": selected,
               "frameworks": frameworks, "testHosts": test_hosts, "buildExitCode": 0}
    require(isinstance(receipt["inputFingerprint"], str) and len(receipt["inputFingerprint"]) == 64,
            "Snapshot has no bound input fingerprint")
    encoded = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()
    require(len(encoded) <= 8 * 1024 * 1024, "Receipt exceeds 8 MiB")
    (output / "target-scope.json").write_bytes(encoded)
    save(output / "capture.json", {"receipt": str(output / "target-scope.json"), "indexStore": str(stores[0]),
         "secondsIncludingPreparation": time.monotonic() - started,
         "context": common + ["test-without-building"],
         "limitation": "Captured review candidates only. Not signed, not executed tests, and not permission to skip tests."})
    return output / "target-scope.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("project", "xcode-project", "scheme", "cartograph", "output"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--test-plan", help="Relative shared .xctestplan path; exactly one empty-options configuration")
    parser.add_argument("--config")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    try:
        print(capture(args))
    except (CaptureError, OSError, ValueError, KeyError, ET.ParseError) as error:
        parser.exit(2, str(error) + "\n")


if __name__ == "__main__":
    main()
