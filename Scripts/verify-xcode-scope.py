#!/usr/bin/env python3
"""Portable preflight regressions. These do not claim native Xcode execution."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("xcode_scope", REPO / "Scripts/cartograph-xcode-scope.py")
SCOPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCOPE)


class XcodeScopePreflightTests(unittest.TestCase):
    def setUp(self):
        self.project = json.loads((REPO / "Tests/Fixtures/xcode-scope-project.json").read_text())

    def test_explicit_targets_and_distinct_product_module_identity(self):
        targets = SCOPE.membership(self.project)
        self.assertEqual(len(targets), 4)
        path, configuration, ids = SCOPE.scheme_membership(REPO / "Fixtures/XcodeAffectedScope", "Scope.xcodeproj", "Scope", None)
        self.assertEqual(configuration, "Debug")
        self.assertEqual({targets[x]["name"] for x in ids}, {"ChecksBlueprint", "OtherBlueprint"})
        self.assertEqual(SCOPE.scheme_membership(REPO / "Fixtures/XcodeAffectedScope", "Scope.xcodeproj", "PlannedScope", "Scope.xctestplan")[2], ids)

    def test_preflight_rejects_scripts_plugins_external_and_conditional_inputs(self):
        for kind in ("script", "plugin", "xcconfig", "package", "platform", "filter", "conditional", "shared", "implicit"):
            with self.subTest(kind=kind):
                project = copy.deepcopy(self.project)
                objects = project["objects"]
                target_ids = objects[project["rootObject"]]["targets"]
                if kind == "script": objects["bad"] = {"isa": "PBXShellScriptBuildPhase", "shellScript": "must never execute"}
                elif kind == "plugin": next(x for x in objects.values() if x["isa"] == "XCBuildConfiguration")["buildSettings"]["OTHER_SWIFT_FLAGS"] = "-load-plugin-executable /outside/plugin#Module"
                elif kind == "xcconfig": next(x for x in objects.values() if x["isa"] == "XCBuildConfiguration")["baseConfigurationReference"] = "outside"
                elif kind == "package": objects[project["rootObject"]]["packageReferences"] = ["outside"]
                elif kind == "platform": next(x for x in objects.values() if x["isa"] == "PBXBuildFile")["platformFilter"] = "ios"
                elif kind in ("filter", "conditional"):
                    key = "EXCLUDED_SOURCE_FILE_NAMES" if kind == "filter" else "PRODUCT_NAME[sdk=macosx*]"
                    next(x for x in objects.values() if x["isa"] == "XCBuildConfiguration")["buildSettings"][key] = "*"
                elif kind == "shared":
                    objects[target_ids[1]]["buildPhases"] = objects[target_ids[0]]["buildPhases"]
                else: objects[target_ids[1]]["dependencies"] = []
                with self.assertRaises(SCOPE.CaptureError): SCOPE.membership(project)

    def test_system_framework_paths_and_bounded_bytes(self):
        def with_framework(path):
            project = copy.deepcopy(self.project)
            objects = project["objects"]
            phase = next(x for x in objects.values() if x["isa"] == "PBXFrameworksBuildPhase")
            objects["sdk-ref"] = {"isa": "PBXFileReference", "sourceTree": "SDKROOT", "path": path}
            objects["sdk-file"] = {"isa": "PBXBuildFile", "fileRef": "sdk-ref"}
            phase.setdefault("files", []).append("sdk-file")
            return project
        normal = "System/Library/Frameworks/Foundation.framework"
        self.assertEqual(len(SCOPE.membership(with_framework(normal))), 4)
        for path in ("/tmp/Unbound.framework", "../../../../tmp/Unbound.framework", "$(OUTSIDE)/Unbound.framework",
                     "System/Library/Frameworks/../Unbound.framework"):
            with self.subTest(path=path), self.assertRaises(SCOPE.CaptureError):
                SCOPE.membership(with_framework(path))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            framework = root / normal
            framework.mkdir(parents=True)
            (framework / "Foundation.tbd").write_text("stub")
            files, links = SCOPE.framework_inventory(framework, root)
            self.assertEqual(len(files), 1)
            self.assertEqual(links, {})
            if os.name == "posix":
                outside = root.parent / (root.name + "-outside")
                outside.mkdir()
                try:
                    link = framework / "Escaping"
                    link.symlink_to(outside, target_is_directory=True)
                    with self.assertRaises(SCOPE.CaptureError): SCOPE.framework_inventory(framework, root)
                    link.unlink()
                    external = root / "Redirect.framework"
                    external.symlink_to(outside, target_is_directory=True)
                    with self.assertRaises(SCOPE.CaptureError): SCOPE.framework_inventory(external, root)
                    external.unlink()
                finally:
                    outside.rmdir()

    def test_preflight_rejects_external_products_hosts_and_runpaths(self):
        for key, value in (("CONFIGURATION_BUILD_DIR", "/tmp/outside"), ("TEST_HOST", "/tmp/host"),
                           ("BUNDLE_LOADER", "$(TEST_HOST)"), ("LD_RUNPATH_SEARCH_PATHS", "/tmp/frameworks"),
                           ("INFOPLIST_FILE", "/tmp/Info.plist")):
            with self.subTest(key=key):
                project = copy.deepcopy(self.project)
                next(x for x in project["objects"].values() if x["isa"] == "XCBuildConfiguration")["buildSettings"][key] = value
                with self.assertRaises(SCOPE.CaptureError): SCOPE.membership(project)
        self.assertTrue(SCOPE.valid_runpaths("$(inherited) @loader_path/../../../ @loader_path/../Frameworks"))
        self.assertFalse(SCOPE.valid_runpaths("@loader_path/../../../../outside"))

    def test_inventory_includes_untracked_sources_and_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Ignored.swift").write_text("struct Ignored {}")
            (root / ".gitignore").write_text("Ignored.swift\n")
            (root / "x.xctestplan").write_text("{}")
            before = SCOPE.inventory(root)
            self.assertIn("Ignored.swift", before)
            self.assertIn("x.xctestplan", before)
            (root / "Ignored.swift").write_text("struct Changed {}")
            self.assertNotEqual(SCOPE.inventory(root), before)
            (root / "Oversized.swift").write_bytes(b"a" * (4 * 1024 * 1024 + 1))
            with self.assertRaises(SCOPE.CaptureError): SCOPE.inventory(root)

    def test_bad_scope_paths_are_not_guessed(self):
        for value in ("", "../a", "/absolute", "a//b", "a\\b", "$(ROOT)/a", "C:/a", "a\nb"):
            self.assertFalse(SCOPE.relative(value), value)


if __name__ == "__main__":
    unittest.main()
