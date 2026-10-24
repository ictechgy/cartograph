#!/usr/bin/env python3
"""Portable workspace preflight/identity controls; native execution is a separate gate."""
import copy
import importlib.util
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


class WorkspaceTests(unittest.TestCase):
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
