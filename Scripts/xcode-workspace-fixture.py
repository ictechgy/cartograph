#!/usr/bin/env python3
"""Turn the public native project fixture into a real two-project dependency workspace."""
import copy
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def plists(original=None):
    if original is None:
        original = json.loads((ROOT / "Tests/Fixtures/xcode-scope-project.json").read_text())
    app, core = copy.deepcopy(original), copy.deepcopy(original)
    objects = app["objects"]
    root = app["rootObject"]
    core_id = next(k for k, v in objects.items() if v.get("isa") == "PBXNativeTarget" and v.get("name") == "CoreBlueprint")
    product = objects[core_id]["productReference"]
    objects[root]["targets"].remove(core_id)
    core["objects"][root]["targets"] = [core_id]
    # The first package is consumed by Core, which now belongs only to Core.xcodeproj.
    package_objects = {k for k, v in objects.items() if "SwiftPackage" in v.get("isa", "")}
    package_files = {k for k, v in objects.items() if v.get("productRef") in package_objects}
    if package_objects:
        objects[root]["packageReferences"] = []
        for obj in objects.values():
            if "packageProductDependencies" in obj:
                obj["packageProductDependencies"] = []
            if "files" in obj:
                obj["files"] = [f for f in obj["files"] if f not in package_files]
        for key in package_objects | package_files:
            del objects[key]
    for key in [k for k, v in core["objects"].items() if v.get("isa") == "PBXContainerItemProxy"]:
        del core["objects"][key]
    # PBX IDs are deliberately identical in both files, as happens when projects originate from templates.
    objects["workspace-project-ref"] = {"isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": "Core.xcodeproj", "lastKnownFileType": "wrapper.pb-project"}
    objects["workspace-product-group"] = {"isa": "PBXGroup", "sourceTree": "<group>", "children": ["workspace-product-proxy"], "name": "Products"}
    objects["workspace-target-proxy"] = {"isa": "PBXContainerItemProxy", "containerPortal": "workspace-project-ref", "proxyType": "1", "remoteGlobalIDString": core_id, "remoteInfo": "CoreBlueprint"}
    objects["workspace-product-proxy-container"] = {"isa": "PBXContainerItemProxy", "containerPortal": "workspace-project-ref", "proxyType": "2", "remoteGlobalIDString": product, "remoteInfo": "CoreKit"}
    objects["workspace-product-proxy"] = {"isa": "PBXReferenceProxy", "remoteRef": "workspace-product-proxy-container", "sourceTree": "BUILT_PRODUCTS_DIR", "path": objects[product]["path"], "fileType": "wrapper.framework"}
    objects[objects[root]["mainGroup"]]["children"].append("workspace-project-ref")
    objects[root]["projectReferences"] = [{"ProjectRef": "workspace-project-ref", "ProductGroup": "workspace-product-group"}]
    for key, obj in list(objects.items()):
        if obj.get("isa") == "PBXContainerItemProxy" and key not in ("workspace-target-proxy", "workspace-product-proxy-container"):
            del objects[key]
        elif obj.get("isa") == "PBXTargetDependency" and obj.get("target") == core_id:
            obj.pop("target", None)
            obj["targetProxy"] = "workspace-target-proxy"
        elif obj.get("isa") == "PBXBuildFile" and obj.get("fileRef") == product:
            obj["fileRef"] = "workspace-product-proxy"
    return {"App.xcodeproj": app, "Core.xcodeproj": core}


def make(root, packages=0):
    source = ROOT / "Fixtures" / ("XcodeLocalPackageScope" if packages else "XcodeAffectedScope")
    shutil.copytree(source, root)
    original = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(source / "Scope.xcodeproj/project.pbxproj")])) if packages else None
    shutil.rmtree(root / "Scope.xcodeproj")
    values = plists(original)
    if packages == 2:
        objects = values["App.xcodeproj"]["objects"]
        main = objects[values["App.xcodeproj"]["rootObject"]]
        main["packageReferences"] = ["second-package"]
        objects["second-package"] = {"isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/OtherMath"}
        objects["second-product"] = {"isa": "XCSwiftPackageProductDependency", "package": "second-package", "productName": "OtherArithmeticProduct"}
        objects["second-link"] = {"isa": "PBXBuildFile", "productRef": "second-product"}
        other = next(v for v in objects.values() if v.get("isa") == "PBXNativeTarget" and v.get("name") == "OtherBlueprint")
        other["packageProductDependencies"] = ["second-product"]
        phase = next(objects[k] for k in other["buildPhases"] if objects[k]["isa"] == "PBXFrameworksBuildPhase")
        phase.setdefault("files", []).append("second-link")
        package = root / "Packages/OtherMath"
        (package / "Sources/OtherArithmeticCore").mkdir(parents=True)
        (package / "Package.swift").write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "OtherMath", products: [.library(name: "OtherArithmeticProduct", targets: ["OtherArithmeticCore"])], targets: [.target(name: "OtherArithmeticCore")])\n')
        (package / "Sources/OtherArithmeticCore/Other.swift").write_text('public func otherPackageValue() -> Int { 42 }\n')
        other_source = root / "Other/OtherTests.swift"
        text = other_source.read_text().replace('import XCTest', 'import XCTest\nimport OtherArithmeticCore')
        text = text.replace('XCTAssertEqual(otherValue(), 7)', 'XCTAssertEqual(otherValue(), 7); XCTAssertEqual(otherPackageValue(), 42)')
        other_source.write_text(text)
    for path, value in values.items():
        (root / path).mkdir()
        value["archiveVersion"] = str(value.get("archiveVersion", "1"))
        value["objectVersion"] = str(value.get("objectVersion", "56"))
        (root / path / "project.pbxproj").write_bytes(plistlib.dumps(value))
    workspace = root / "Scope.xcworkspace"
    (workspace / "xcshareddata/xcschemes").mkdir(parents=True)
    (workspace / "contents.xcworkspacedata").write_text('<Workspace version="1.0"><FileRef location="group:App.xcodeproj"/><FileRef location="group:Core.xcodeproj"/></Workspace>\n')
    for name in ("Scope", "PlannedScope"):
        scheme_source = source / "Scope.xcodeproj/xcshareddata/xcschemes" / (name + ".xcscheme")
        xml = ET.fromstring(scheme_source.read_bytes())
        for ref in xml.iter("BuildableReference"):
            ref.set("ReferencedContainer", "container:" + ("Core.xcodeproj" if ref.get("BlueprintName") == "CoreBlueprint" else "App.xcodeproj"))
        (workspace / "xcshareddata/xcschemes" / (name + ".xcscheme")).write_bytes(ET.tostring(xml))
    plan = json.loads((root / "Scope.xctestplan").read_text())
    for row in plan["testTargets"]:
        row["target"]["containerPath"] = "container:App.xcodeproj"
    (root / "Scope.xctestplan").write_text(json.dumps(plan, sort_keys=True))
    return root
