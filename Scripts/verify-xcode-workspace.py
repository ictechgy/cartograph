#!/usr/bin/env python3
"""Portable workspace preflight/identity controls; native execution is a separate gate."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WORKSPACE, FIXTURE, SCOPE = load("xcode-workspace-inputs"), load("xcode-workspace-fixture"), load("cartograph-xcode-scope")
CAPTURE = load("xcode-workspace-capture")
INPUTS = load("xcode-local-package-inputs")


class WorkspaceTests(unittest.TestCase):
    def shared(self, root):
        values = json.loads((ROOT / "Tests/Fixtures/xcode-workspace-shared-projects.json").read_text())
        for path, name, product, module in (("LocalMath", "LocalMath", "ArithmeticProduct", "ArithmeticCore"),
                                            ("OtherMath", "OtherMath", "OtherArithmeticProduct", "OtherArithmeticCore")):
            package = root / "Packages" / path
            (package / "Sources" / module).mkdir(parents=True)
            (package / "Package.swift").write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "' + name + '", products: [.library(name: "' + product + '", targets: ["' + module + '"])], targets: [.target(name: "' + module + '")])\n')
            (package / "Sources" / module / "Value.swift").write_text("public func value() -> Int { 42 }\n")
        return values

    def test_shared_workspace_package_and_multiple_products_in_one_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            values = self.shared(root)
            specs, sanitized = [], {}
            for path, value in values.items():
                current, sanitized[path] = INPUTS.workspace_project(root, path, value)
                specs += [(path, s) for s in current]
            packages = CAPTURE.aggregate_packages(specs, SCOPE)
            self.assertEqual(len(packages), 2)
            shared = next(p for p in packages if p["module"] == "ArithmeticCore")
            self.assertEqual(shared["path"], "Packages/LocalMath")
            self.assertEqual({d["project"] for d in shared["declarations"]}, set(values))
            self.assertEqual(len(shared["consumers"]), 2)
            self.assertEqual(len(SCOPE.membership(WORKSPACE.merge(sanitized))), 4)
            bad = copy.deepcopy(specs)
            next(s for _, s in bad if s["module"] == "OtherArithmeticCore")["module"] = "ArithmeticCore"
            with self.assertRaises(SCOPE.CaptureError): CAPTURE.aggregate_packages(bad, SCOPE)

    def test_shared_package_external_duplicate_unknown_and_unlinked_refuse(self):
        for kind in ("external", "absolute", "duplicate", "unlinked", "unknown"):
            with tempfile.TemporaryDirectory() as directory, self.subTest(kind=kind):
                root = Path(directory).resolve()
                values = self.shared(root)
                app = values["Apps/App.xcodeproj"]
                objects = app["objects"]
                if kind == "external": objects["shared-package"]["relativePath"] = "../../outside/LocalMath"
                elif kind == "absolute": objects["shared-package"]["relativePath"] = str(root / "Packages/LocalMath")
                elif kind == "duplicate":
                    objects["second-package"]["relativePath"] = "../Packages/LocalMath"
                    objects["second-product"]["productName"] = "ArithmeticProduct"
                elif kind == "unlinked":
                    phase = next(v for v in objects.values() if "shared-link" in v.get("files", []))
                    phase["files"].remove("shared-link")
                else:
                    target = next(v for v in objects.values() if v.get("isa") == "PBXNativeTarget" and v.get("name") == "OtherBlueprint")
                    target["packageProductDependencies"].append("unknown-product")
                with self.assertRaises(ValueError): INPUTS.workspace_project(root, "Apps/App.xcodeproj", app)

    def test_xml_encoding_and_dtd_policy_is_identical_for_workspace_and_scheme(self):
        text = '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE Workspace [<!ENTITY p "App.xcodeproj">]><Workspace><FileRef location="group:&p;"/></Workspace>'
        for encoding in ("utf-8", "utf-16", "utf-16-le", "utf-16-be", "utf-32"):
            with self.subTest(encoding=encoding), self.assertRaises(WORKSPACE.WorkspaceError):
                WORKSPACE.xml(text.encode(encoding))
        for encoding in ("UTF-16", "ISO-8859-1"):
            with self.assertRaises(WORKSPACE.WorkspaceError):
                WORKSPACE.xml(('<?xml version="1.0" encoding="' + encoding + '"?><Workspace/>').encode())
        self.assertEqual(WORKSPACE.xml(b'<?xml version="1.0" encoding="UTF-8"?><Workspace/>').tag, "Workspace")

    def test_cross_project_dependency_and_product_proxy_join(self):
        plists = FIXTURE.plists()
        targets = SCOPE.membership(WORKSPACE.merge(plists))
        self.assertEqual(len(targets), 4)
        core = next(t for t in targets.values() if t["name"] == "CoreBlueprint")
        checks = next(t for t in targets.values() if t["name"] == "ChecksBlueprint")
        self.assertTrue(core["id"].startswith("Core.xcodeproj::"))
        self.assertEqual(checks["dependencies"], [core["id"]])
        self.assertEqual(core["sources"], ["Core/Core.swift"])

    def test_workspace_groups_namespace_repeated_pbx_ids(self):
        data = b'<Workspace><Group location="group:Libraries"><FileRef location="group:Core.xcodeproj"/></Group><FileRef location="container:App.xcodeproj"/></Workspace>'
        self.assertEqual(WORKSPACE.projects(data), ["App.xcodeproj", "Libraries/Core.xcodeproj"])
        values = FIXTURE.plists()
        renamed = {"A/App.xcodeproj": values["App.xcodeproj"], "A/Core.xcodeproj": values["Core.xcodeproj"]}
        targets = SCOPE.membership(WORKSPACE.merge(renamed))
        self.assertTrue(all(s.startswith("A/") for t in targets.values() for s in t["sources"]))

    def test_bad_workspace_paths_entities_and_limits_refuse(self):
        for location in ("absolute:/tmp/App.xcodeproj", "group:../App.xcodeproj", "group:$(ROOT)/App.xcodeproj", "group:Remote.xcworkspace"):
            with self.subTest(location=location), self.assertRaises(WORKSPACE.WorkspaceError):
                WORKSPACE.projects(('<Workspace><FileRef location="' + location + '"/></Workspace>').encode())
        for data in (b'<!DOCTYPE x><Workspace/>', b'<Workspace><FileRef location="group:A.xcodeproj"/><FileRef location="group:A.xcodeproj"/></Workspace>',
                     ('<Workspace>' + ''.join('<FileRef location="group:P%d.xcodeproj"/>' % i for i in range(33)) + '</Workspace>').encode()):
            with self.assertRaises(WORKSPACE.WorkspaceError): WORKSPACE.projects(data)

    def test_missing_foreign_target_product_and_proxy_mismatch_refuse(self):
        for kind in ("foreign", "target", "product", "product-path", "direct-disagreement"):
            values = copy.deepcopy(FIXTURE.plists())
            objects = values["App.xcodeproj"]["objects"]
            if kind == "foreign": objects["workspace-project-ref"]["path"] = "NotListed.xcodeproj"
            elif kind == "target": objects["workspace-target-proxy"]["remoteGlobalIDString"] = "missing"
            elif kind == "product": objects["workspace-product-proxy-container"]["remoteGlobalIDString"] = "missing"
            elif kind == "product-path": objects["workspace-product-proxy"]["path"] = "Wrong.framework"
            else:
                obj = next(v for v in objects.values() if v.get("isa") == "PBXTargetDependency")
                obj["target"] = values["App.xcodeproj"]["objects"][values["App.xcodeproj"]["rootObject"]]["targets"][0]
            with self.subTest(kind=kind), self.assertRaises(WORKSPACE.WorkspaceError): WORKSPACE.merge(values)

    def test_workspace_scheme_and_plan_use_project_qualified_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = FIXTURE.make(Path(directory) / "project")
            paths = WORKSPACE.projects((root / "Scope.xcworkspace/contents.xcworkspacedata").read_bytes())
            basic = CAPTURE.scheme(root, "Scope.xcworkspace", paths, "Scope", None, SCOPE)
            planned = CAPTURE.scheme(root, "Scope.xcworkspace", paths, "PlannedScope", "Scope.xctestplan", SCOPE)
            self.assertEqual(basic[2], planned[2])
            self.assertEqual(len(basic[2]), 2)
            self.assertTrue(all(x.startswith("App.xcodeproj::") for x in basic[2]))


if __name__ == "__main__":
    unittest.main()
