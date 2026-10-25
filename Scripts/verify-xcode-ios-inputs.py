#!/usr/bin/env python3
"""Pure iOS preflight regressions. Never compiles, invokes Xcode or operates a device."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    path = ROOT / "Scripts" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SCOPE, IOS = load("cartograph-xcode-scope"), load("xcode-ios-scope")
WORKSPACE = load("xcode-workspace-inputs")
PROOF = load("xcode-local-package-evidence")


class Inputs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cartograph-ios-inputs-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.plist = json.loads((ROOT / "Tests/Fixtures/xcode-scope-project.json").read_bytes())
        self.objects = self.plist["objects"]
        for obj in self.objects.values():
            if "buildSettings" in obj:
                obj["buildSettings"]["SDKROOT"] = "iphoneos"

    def member(self):
        return SCOPE.membership(self.plist, ios_simulator=True, root=self.root)

    def workspace_member(self):
        merged = WORKSPACE.merge({"Fixture.xcodeproj": self.plist})
        return SCOPE.membership(merged, ios_simulator=True, root=self.root)

    def auxiliary(self, suffix, phase):
        main = self.objects[self.plist["rootObject"]]
        group = self.objects[main["mainGroup"]]
        target = self.objects[main["targets"][0]]
        ref, build, phase_id = "ios-aux-ref-" + suffix, "ios-aux-build-" + suffix, "ios-aux-phase-" + suffix
        self.objects[ref] = {"isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": "Aux." + suffix}
        self.objects[build] = {"isa": "PBXBuildFile", "fileRef": ref}
        self.objects[phase_id] = {"isa": phase, "files": [build]}
        group["children"].append(ref)
        target["buildPhases"].append(phase_id)
        path = self.root / ("Aux." + suffix)
        path.write_text("plain auxiliary input")
        return path

    def configuration(self, text):
        main = self.objects[self.plist["rootObject"]]
        self.objects[main["mainGroup"]]["children"].append("ios-config-ref")
        self.objects["ios-config-ref"] = {"isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": "Build.xcconfig"}
        config = next(x for x in self.objects.values() if x.get("isa") == "XCBuildConfiguration")
        config["baseConfigurationReference"] = "ios-config-ref"
        (self.root / "Build.xcconfig").write_text(text)

    def test_ios_requires_explicit_profile(self):
        self.assertTrue(self.member())
        with self.assertRaises((ValueError, SCOPE.CaptureError)):
            SCOPE.membership(self.plist)

    def test_plain_resource_and_header_have_explicit_membership(self):
        resource = self.auxiliary("txt", "PBXResourcesBuildPhase")
        header = self.auxiliary("h", "PBXHeadersBuildPhase")
        values = self.member().values()
        self.assertEqual([resource.name], [x for row in values for x in row.get("resources", [])])
        self.assertEqual([header.name], [x for row in values for x in row.get("headers", [])])

    def test_resource_parent_alias_is_rejected(self):
        path = self.auxiliary("txt", "PBXResourcesBuildPhase")
        other = self.root / "other.txt"
        path.rename(other)
        path.symlink_to(other)
        with self.assertRaises((ValueError, SCOPE.CaptureError)):
            self.member()

    def test_literal_configuration_include_is_accepted(self):
        self.configuration('#include "Definitions.xcconfig"\nSWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) IOS_SCOPE\n')
        (self.root / "Definitions.xcconfig").write_text("GCC_PREPROCESSOR_DEFINITIONS = $(inherited) PROBE=1\n")
        self.assertTrue(self.member())

    def test_workspace_literal_configuration_include_is_accepted(self):
        self.configuration('#include "Definitions.xcconfig"\nSWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) IOS_SCOPE\n')
        (self.root / "Definitions.xcconfig").write_text("GCC_PREPROCESSOR_DEFINITIONS = $(inherited) PROBE=1\n")
        self.assertTrue(self.workspace_member())

    def test_workspace_configuration_rejects_execution_escape_and_cycle(self):
        for text, reason in (("SWIFT_EXEC = /tmp/not-executed\n", "Only literal compilation definitions"),
                             ('#include "../outside.xcconfig"\n', "Unsupported xcconfig include path"),
                             ("SWIFT_ACTIVE_COMPILATION_CONDITIONS = ${COMPUTED}\n", "Only literal compilation definitions"),
                             ('#include "Build.xcconfig"\n', "Unsupported xcconfig include path")):
            with self.subTest(text=text):
                objects = copy.deepcopy(self.objects)
                self.configuration(text)
                try:
                    with self.assertRaisesRegex(ValueError, reason):
                        self.workspace_member()
                finally:
                    self.objects.clear()
                    self.objects.update(objects)

    def test_configuration_never_executes_program_or_expands_escape(self):
        for text in ("SWIFT_EXEC = /tmp/not-executed\n", '#include "../outside.xcconfig"\n',
                     "SWIFT_ACTIVE_COMPILATION_CONDITIONS = ${COMPUTED}\n", '#include "Build.xcconfig"\n'):
            with self.subTest(text=text):
                objects = copy.deepcopy(self.objects)
                self.configuration(text)
                with self.assertRaises((ValueError, SCOPE.CaptureError)):
                    self.member()
                self.objects.clear()
                self.objects.update(objects)

    def test_observed_debug_code_image_is_separate_from_host_stub(self):
        targets = {"app": {"name": "App", "productType": "com.apple.product-type.application", "dependencies": []},
                   "test": {"name": "Checks", "productType": "com.apple.product-type.bundle.unit-test", "dependencies": ["app"]}}
        settings = [{"target": "App", "buildSettings": {"TARGET_BUILD_DIR": "/capture/Products", "EXECUTABLE_PATH": "App.app/App", "ENABLE_DEBUG_DYLIB": "YES"}},
                    {"target": "Checks", "buildSettings": {"TARGET_BUILD_DIR": "/capture/Products/App.app/PlugIns", "EXECUTABLE_PATH": "Checks.xctest/Checks"}}]
        self.assertEqual({"app": "/capture/Products/App.app/App.debug.dylib", "test": "/capture/Products/App.app/PlugIns/Checks.xctest/Checks"},
                         IOS.native_outputs(targets, settings, ["test"]))

    def test_host_stub_link_matches_verified_temporary_path_alias_once(self):
        executable = self.root / "App"
        code = self.root / "App.debug.dylib"
        executable.touch()
        code.touch()
        alias = str(self.root)
        if alias.startswith(("/private/tmp/", "/private/var/folders/")):
            alias = alias[len("/private"):]
        argv = ["/tool/clang", "-map", str(self.root / "App.map"), alias + "/App.debug.dylib", "-o", alias + "/App"]
        self.assertEqual(IOS.host_stub_link([argv], str(executable), str(code), PROOF), argv)
        for commands in ([argv, argv], [argv[:-2] + [str(code)] + argv[-2:]],
                         [[x.replace("App.debug.dylib", "Other.debug.dylib") for x in argv]]):
            with self.subTest(commands=commands):
                with self.assertRaises(ValueError):
                    IOS.host_stub_link(commands, str(executable), str(code), PROOF)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", help="Run these same pure checks against a pinned Git scope reader")
    args = parser.parse_args()
    if args.baseline_ref:
        source = subprocess.run(["git", "-c", "core.fsmonitor=false", "show", args.baseline_ref + ":Scripts/cartograph-xcode-scope.py"],
                                cwd=ROOT, capture_output=True, check=True).stdout
        baseline = types.ModuleType("baseline_scope")
        baseline.__file__ = str(ROOT / "Scripts/cartograph-xcode-scope.py")
        exec(compile(source, baseline.__file__, "exec"), baseline.__dict__)
        SCOPE = baseline
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Inputs))
    raise SystemExit(0 if result.wasSuccessful() else 1)
