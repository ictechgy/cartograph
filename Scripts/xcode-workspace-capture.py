#!/usr/bin/env python3
"""Capture explicit multi-project workspaces using the shared bounded Xcode proof machinery."""
import copy
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import time
import xml.etree.ElementTree as ET


def canonical_settings(rows):
    """Keep raw command output beside the receipt; project path operands use physical identities."""
    result = copy.deepcopy(rows)
    for row in result:
        settings = row.get("buildSettings", {})
        for key in ("PROJECT_FILE_PATH", "TARGET_BUILD_DIR", "DEVELOPER_DIR", "SDKROOT", "TEST_HOST", "BUNDLE_LOADER"):
            if isinstance(settings.get(key), str) and settings[key].startswith("/"):
                settings[key] = str(Path(settings[key]).resolve())
    return result


def aggregate_packages(project_specs, scope):
    """Deduplicate physical packages while retaining every project-specific declaration and consumer."""
    result = {}
    declarations = 0
    for project, spec in project_specs:
        core = {k: v for k, v in spec.items() if k not in ("referenceID", "productReferenceID", "consumers")}
        path = spec["path"]
        if path not in result:
            result[path] = {**core, "declarations": []}
        scope.require({k: v for k, v in result[path].items() if k != "declarations"} == core,
                      "Shared package declarations disagree on manifest, module or complete subtree")
        declaration = {"project": project, "referenceID": spec["referenceID"], "productReferenceID": spec["productReferenceID"],
                       "consumers": [project + "::" + x for x in spec["consumers"]]}
        scope.require(not any(x["project"] == project for x in result[path]["declarations"]), "Duplicate package path in one project")
        result[path]["declarations"].append(declaration)
        declarations += 1
    scope.require(len(result) <= 16 and declarations <= 256, "Workspace package/declaration budget exceeded")
    for key in ("name", "product", "module"):
        scope.require(len({spec[key] for spec in result.values()}) == len(result), "Distinct workspace packages have duplicate " + key + " identities")
    for spec in result.values():
        spec["declarations"].sort(key=lambda x: x["project"])
        first = spec["declarations"][0]
        spec.update({"referenceID": first["referenceID"], "productReferenceID": first["productReferenceID"],
                     "consumers": sorted({c for d in spec["declarations"] for c in d["consumers"]})})
    return [result[key] for key in sorted(result)]


def scheme(root, workspace, projects, name, test_plan, scope):
    path = workspace + "/xcshareddata/xcschemes/" + name + ".xcscheme"
    data = scope.bounded(root / path, 1024 * 1024)
    xml = scope.package_helper("xcode-workspace-inputs").xml(data)
    scope.require(not any(list(xml.iter(n)) for n in (
        "ExecutionAction", "SkippedTests", "SelectedTests", "EnvironmentVariable", "CommandLineArgument")),
        "Scheme actions, runtime options or partial selections are unsupported")
    def identity(ref):
        container = ref.get("ReferencedContainer", "")
        project = container.removeprefix("container:")
        scope.require(container.startswith("container:") and project in projects and ref.get("BlueprintIdentifier"),
                      "Scheme target belongs to an unlisted workspace project")
        return project + "::" + ref.get("BlueprintIdentifier")
    for ref in xml.iter("BuildableReference"):
        identity(ref)
    actions = list(xml.iter("TestAction"))
    scope.require(len(actions) == 1 and scope.relative(actions[0].get("buildConfiguration")), "Expected one explicit test configuration")
    plans = [x.get("reference", "").removeprefix("container:") for x in xml.iter("TestPlanReference")]
    selected = []
    if plans:
        scope.require(test_plan in plans and scope.relative(test_plan), "Select an explicit workspace test plan")
        plan = json.loads(scope.bounded(root / test_plan, 1024 * 1024))
        configs = plan.get("configurations", [])
        scope.require(len(configs) == 1 and not configs[0].get("options") and not plan.get("defaultOptions"),
                      "Only one test-plan configuration without runtime options is supported")
        for item in plan.get("testTargets", []):
            target = item.get("target", {})
            scope.require(item.get("enabled") is not False and "selectedTests" not in item and "skippedTests" not in item,
                          "Partial or disabled workspace test targets are unsupported")
            selected.append(identity({"ReferencedContainer": target.get("containerPath"), "BlueprintIdentifier": target.get("identifier")}))
    else:
        scope.require(test_plan is None, "Unexpected workspace test plan")
        for item in xml.iter("TestableReference"):
            refs = list(item.iter("BuildableReference"))
            scope.require(item.get("skipped") == "NO" and len(refs) == 1, "Skipped or missing workspace test target")
            selected.append(identity(refs[0]))
    scope.require(selected and len(selected) <= 1000 and len(set(selected)) == len(selected), "Empty or duplicate workspace test universe")
    return path, actions[0].get("buildConfiguration"), sorted(selected)


def capture(args, scope):
    root, output, binary = Path(args.project).resolve(), Path(args.output).resolve(), Path(args.cartograph).resolve()
    scope.require(scope.relative(args.workspace) and args.workspace.endswith(".xcworkspace") and scope.relative(args.scheme),
                  "Use an explicit local .xcworkspace path and shared scheme")
    scope.require(not output.is_relative_to(root) and not output.exists(), "Use a fresh output outside the project")
    scope.require(1 <= args.timeout <= 3600 and platform.system() == "Darwin", "Capture requires native macOS and timeout 1...3600")
    output.mkdir(parents=True)
    ios = getattr(args, "ios_simulator", False)
    auxiliary = set()
    def inventory():
        return scope.inventory(root, maximum_files=20000, maximum_bytes=128 * 1024 * 1024, additional_paths=auxiliary)
    started, before = time.monotonic(), inventory()
    helper = scope.package_helper("xcode-workspace-inputs")
    projects = helper.projects(scope.bounded(root / args.workspace / "contents.xcworkspacedata", 1024 * 1024))
    raw, sanitized, package_specs = {}, {}, []
    inputs = scope.package_helper("xcode-local-package-inputs")
    for index, path in enumerate(projects):
        scope.require((root / path).resolve() == root / path, "Workspace project path is symlinked or noncanonical")
        data = scope.run(["plutil", "-convert", "json", "-o", "-", str(root / path / "project.pbxproj")],
                         root, output, "project-" + str(index), args.timeout)
        raw[path] = json.loads(data)
        sanitized[path] = raw[path]
        main = raw[path].get("objects", {}).get(raw[path].get("rootObject"), {})
        if main.get("packageReferences") and args.local_package:
            specs, sanitized[path] = inputs.workspace_project(root, path, raw[path])
            package_specs += [(path, spec) for spec in specs]
    initial_packages = aggregate_packages(package_specs, scope)
    merged = helper.merge(sanitized)
    targets = scope.membership(merged, ios_simulator=ios, root=root)
    if ios:
        auxiliary = {p for target in targets.values() for p in target.get("resources", []) + target.get("headers", [])}
        before = inventory()
    # No duplicate target name can be represented unambiguously by Xcode's -only-testing syntax.
    scope.require(len({t["name"] for t in targets.values()}) == len(targets), "Workspace target selector names must be unique")
    scheme_path, configuration, selected = scheme(root, args.workspace, projects, args.scheme, args.test_plan, scope)
    scope.require(all(x in targets and targets[x]["productType"] == "com.apple.product-type.bundle.unit-test" for x in selected),
                  "Selected workspace entries must be explicit native unit-test targets")
    frameworks = scope.capture_frameworks(merged, root, output, args.timeout, ios_simulator=ios)
    arch = platform.machine()
    scope.require(arch in ("arm64", "x86_64"), "Unsupported native architecture")
    destination = "generic/platform=iOS Simulator" if ios else "platform=macOS,arch=" + arch
    derived = output / "DerivedData"
    common = ["xcodebuild", "-workspace", str(root / args.workspace), "-configuration", configuration,
              "-destination", destination, "-derivedDataPath", str(derived), "-scheme", args.scheme]
    if ios:
        common += ["-sdk", "iphonesimulator"]
    if args.test_plan:
        common += ["-testPlan", Path(args.test_plan).stem]
    overrides = ["CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=YES", "ARCHS=" + arch]
    if package_specs or ios:
        overrides += ["LD_GENERATE_MAP_FILE=YES"]
    if ios:
        # App stub/code image must not overwrite the same link-map output.
        overrides += ["LD_MAP_FILE_PATH=$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-$(MACH_O_TYPE)-$(CURRENT_ARCH)-LinkMap.txt"]
    settings = canonical_settings(json.loads(scope.run(common + ["build-for-testing", "-showBuildSettings", "-json"] + overrides,
                                    root, output, "build-settings", args.timeout)))
    for target in targets.values():
        project = target["id"].split("::", 1)[0]
        def matches(row):
            return row.get("target") == target["name"] and row.get("buildSettings", {}).get("PROJECT_FILE_PATH") == str(root / project)
        rows = [r for r in settings if matches(r)]
        if not rows:
            extra = canonical_settings(json.loads(scope.run(["xcodebuild", "-project", str(root / project), "-target", target["name"],
                "-configuration", configuration, "-showBuildSettings", "-json"] + (["-sdk", "iphonesimulator"] if ios else []) + overrides,
                root, output, "settings-" + str(len(settings)), args.timeout)))
            rows = [r for r in extra if matches(r)]
            settings += rows
        scope.require(len(rows) == 1 and rows[0]["buildSettings"].get("PRODUCT_MODULE_NAME"), "Ambiguous workspace compiler module")
        target["module"] = rows[0]["buildSettings"]["PRODUCT_MODULE_NAME"]
    module_names = [t["module"] for t in targets.values()] + [s["module"] for s in initial_packages]
    scope.require(len(set(module_names)) == len(module_names), "Workspace compiler module names must be unique")
    scope.require(len({s["name"] for s in initial_packages}) == len(initial_packages)
                  and len({s["product"] for s in initial_packages}) == len(initial_packages),
                  "Distinct workspace packages require unique package/product identities")
    build_log = scope.run(common + ["build-for-testing"] + overrides, root, output, "build-for-testing", args.timeout, 32 * 1024 * 1024)
    products_root = derived / "Build/Products"
    runs = list(products_root.glob("*.xctestrun"))
    stores = [p for p in (derived / "Index.noindex/DataStore", derived / "Index/DataStore") if p.is_dir()]
    scope.require(len(runs) == 1 and len(stores) == 1, "Expected one fresh workspace xctestrun and index store")
    command = [str(binary), "snapshot", "--project", str(root), "--index-store", str(stores[0])]
    if args.config:
        command += ["--config", str(Path(args.config).resolve())]
    snapshot = json.loads(scope.run(command, root, output, "snapshot", args.timeout, 128 * 1024 * 1024))
    proof = scope.package_helper("xcode-local-package-evidence")
    ios_helper = scope.package_helper("xcode-ios-scope") if ios else None
    native_outputs = ios_helper.native_outputs(targets, settings, selected) if ios else None
    def native_proof(current_snapshot):
        return ios_helper.assemble(root, derived, stores[0], build_log.decode("utf-8"), current_snapshot,
                                   targets, settings, selected, arch, proof) if ios else None
    native_evidence = native_proof(snapshot)
    def package_proofs(current_snapshot):
        result = []
        current_specs = []
        for path in sorted({path for path, _ in package_specs}):
            specs, _ = inputs.workspace_project(root, path, raw[path])
            for current in specs:
                original = next(s for p, s in package_specs if p == path and s["referenceID"] == current["referenceID"])
                current_specs.append((path, inputs.captured_spec(original, current)))
        for current in aggregate_packages(current_specs, scope):
            scope.require(not any(p.startswith(current["path"] + "/") for t in targets.values() for p in t["sources"]),
                          "Package sources cannot also belong to workspace native targets")
            item = proof.assemble(current, root, derived, stores[0], build_log.decode("utf-8"), current_snapshot,
                                  targets, settings, selected, arch, **({"native_outputs": native_outputs} if ios else {}))
            result.append(item)
        return result
    packages = package_proofs(snapshot)
    if packages or ios:
        snapshot = json.loads(scope.run(command, root, output, "package-fresh-snapshot", args.timeout, 128 * 1024 * 1024))
        scope.require(package_proofs(snapshot) == packages and native_proof(snapshot) == native_evidence,
                      "Workspace compiler/link/record proof changed across fresh graph analysis")
    after = inventory()
    scope.require(before == after, "Workspace inputs changed during capture")
    products, links = scope.product_inventory(products_root)
    run_plist = plistlib.loads(scope.bounded(runs[0], 8 * 1024 * 1024))
    rows = run_plist["TestConfigurations"][0]["TestTargets"] if "TestConfigurations" in run_plist else [v for k, v in run_plist.items() if not k.startswith("__")]
    hosts = {}
    developer = Path(settings[0]["buildSettings"]["DEVELOPER_DIR"]).resolve()
    for row in rows:
        scope.require(bool(row.get("IsAppHostedTestBundle")) == ios and not row.get("IsUITestBundle"), "Unexpected workspace XCTest host profile")
        if not ios and "TestHostPath" in row:
            expected = developer / "Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"
            declared = row["TestHostPath"].replace("__PLATFORMS__", str(developer / "Platforms"))
            scope.require(Path(declared) == expected and Path(declared).resolve() == expected, "Unknown workspace XCTest host")
            hosts[str(expected)] = hashlib.sha256(scope.bounded(expected, 16 * 1024 * 1024)).hexdigest()
    receipt = {"format": "cartograph-xcode-target-scope", "version": 3, "projectRoot": str(root), "project": projects[0],
        "workspace": args.workspace, "projects": projects, "scheme": args.scheme, "schemePath": scheme_path,
        "testPlan": args.test_plan, "configuration": configuration, "destination": destination, "architecture": arch,
        "inputFingerprint": snapshot.get("inputFingerprint"), "before": before, "after": after,
        "buildSettingsJSON": json.dumps(settings, sort_keys=True), "testRunPath": str(runs[0]), "testRunSHA256": products[str(runs[0])],
        "products": products, "productLinks": links, "targets": sorted(targets.values(), key=lambda x: x["id"]),
        "selectedTargetIDs": selected, "frameworks": frameworks, "testHosts": hosts, "buildExitCode": 0, "localPackages": packages}
    if ios:
        receipt.update(version=4, ios=native_evidence)
    scope.require(isinstance(receipt["inputFingerprint"], str) and len(receipt["inputFingerprint"]) == 64, "Snapshot has no bound input fingerprint")
    scope.require(package_proofs(snapshot) == packages and native_proof(snapshot) == native_evidence and before == inventory(), "Workspace inputs/proof changed before receipt publication")
    encoded = (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode()
    scope.require(len(encoded) <= 8 * 1024 * 1024, "Workspace receipt exceeds 8 MiB")
    (output / "target-scope.json").write_bytes(encoded)
    scope.save(output / "capture.json", {"receipt": str(output / "target-scope.json"), "indexStore": str(stores[0]),
        "secondsIncludingPreparation": time.monotonic() - started,
        "context": None if ios else common + ["test-without-building"], "buildContext": common + ["build-for-testing"],
        "runtimeAcceptance": "not-run; no device operation" if ios else "not-run-by-capture",
        "inputFileCount": len(after), "declaredSourceCountByModule": {t["module"]: len(t["sources"]) for t in targets.values()},
        "observedSourceRecordCountByModule": {t["module"]: len({r.get("path") for r in snapshot.get("snapshot", {}).get("sourceRecordAdmissions", []) if r.get("module") == t["module"]}) for t in targets.values()},
        "coverageCountLimitation": "Observed compiler source-record counts, not line coverage, dynamic coverage or proof that omitted sources are harmless.",
        "limitation": "Captured workspace review candidates. Not signed, executed tests or permission to skip tests."})
    return output / "target-scope.json"
