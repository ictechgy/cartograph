#!/usr/bin/env python3
"""Portable non-executing package preflight regressions; no Swift/Xcode claims."""
import importlib.util
import contextlib
import copy
import json
import shutil
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("package_inputs", ROOT / "Scripts/xcode-local-package-inputs.py")
INPUTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INPUTS)
MANIFEST = (ROOT / "Fixtures/XcodeLocalPackageScope/Packages/LocalMath/Package.swift").read_bytes()


class PackageInputTests(unittest.TestCase):
    def test_installed_helpers_load_without_a_repository_or_diagnostic_scripts(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder).resolve()
            for name in ("cartograph-xcode-scope.py", "cartograph-swiftpm-scope.py",
                         "xcode-local-package-inputs.py", "xcode-local-package-evidence.py"):
                shutil.copyfile(ROOT / "Scripts" / name, target / name)
            check = importlib.util.spec_from_file_location("installed_capture_check", ROOT / "Scripts/verify-xcode-scope-install.py")
            verifier = importlib.util.module_from_spec(check)
            check.loader.exec_module(verifier)
            verifier.verify(target)
            (target / "xcode-local-package-evidence.py").unlink()
            with self.assertRaises(FileNotFoundError):
                verifier.verify(target)

    def test_package_project_references_must_agree_and_preserve_native_preflight(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            package = root / "Packages/LocalMath"
            (package / "Sources/ArithmeticCore").mkdir(parents=True)
            (package / "Package.swift").write_bytes(MANIFEST)
            (package / "Sources/ArithmeticCore/Math.swift").write_bytes(b"public func value() {}")
            plist = json.loads((ROOT / "Tests/Fixtures/xcode-scope-project.json").read_text())
            objects = plist["objects"]
            project = objects[plist["rootObject"]]
            core_id = next(k for k, v in objects.items() if v.get("name") == "CoreBlueprint")
            core = objects[core_id]
            framework = next(objects[p] for p in core["buildPhases"] if objects[p]["isa"] == "PBXFrameworksBuildPhase")
            project["packageReferences"] = ["LOCAL"]
            objects["LOCAL"] = {"isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/LocalMath"}
            objects["PRODUCT"] = {"isa": "XCSwiftPackageProductDependency", "package": "LOCAL", "productName": "ArithmeticProduct"}
            objects["LINK"] = {"isa": "PBXBuildFile", "productRef": "PRODUCT"}
            core["packageProductDependencies"] = ["PRODUCT"]
            framework["files"].append("LINK")
            original = copy.deepcopy(plist)
            spec, sanitized = INPUTS.project(root, plist)
            self.assertEqual(spec["consumers"], [core_id])
            self.assertEqual(plist, original)
            native_spec = importlib.util.spec_from_file_location("scope", ROOT / "Scripts/cartograph-xcode-scope.py")
            scope = importlib.util.module_from_spec(native_spec)
            native_spec.loader.exec_module(scope)
            self.assertEqual(len(scope.membership(sanitized)), 4)
            # The native target need not be built to make shared package ownership
            # unsupported. Reject it before any xcodebuild command is invoked.
            shared = copy.deepcopy(original)
            source = next(v for v in shared["objects"].values() if v.get("path") == "Unbuilt/Tool.swift")
            source["path"] = "Packages/LocalMath/Sources/ArithmeticCore/Math.swift"
            with tempfile.TemporaryDirectory() as captures:
                args = SimpleNamespace(project=str(root), output=str(Path(captures) / "capture"),
                                       cartograph=str(root / "cartograph"), xcode_project="Scope.xcodeproj",
                                       scheme="ChecksOnly", test_plan=None, timeout=30, local_package=True)
                with mock.patch.object(scope.platform, "system", return_value="Darwin"), \
                     mock.patch.object(scope, "inventory", return_value={}), \
                     mock.patch.object(scope, "run", return_value=json.dumps(shared).encode()) as commands:
                    with self.assertRaisesRegex(scope.CaptureError, "Package sources cannot also belong"):
                        scope.capture(args)
                    self.assertEqual(commands.call_count, 1)
                    self.assertEqual(commands.call_args.args[0][0], "plutil")
            for change in (lambda o: o["LOCAL"].update(relativePath="../escape"),
                           lambda o: o["LOCAL"].update(unbound="ignored"),
                           lambda o: o["PRODUCT"].update(productName="Wrong"),
                           lambda o: o["LINK"].update(platformFilter="macos"),
                           lambda o: o["LINK"].update(isa="PBXShellScriptBuildPhase", shellScript="echo unsupported"),
                           lambda o: o[core_id].update(packageProductDependencies=[])):
                altered = copy.deepcopy(original)
                change(altered["objects"])
                with self.assertRaises(INPUTS.UnsupportedPackage):
                    INPUTS.project(root, altered)

    def test_directory_enumeration_stops_before_sorting_unbounded_entries(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            count = 0
            def entries():
                nonlocal count
                for i in range(10000):
                    count += 1
                    yield type("Entry", (), {"path": str(root / str(i))})()
            with mock.patch.object(INPUTS.os, "scandir", return_value=contextlib.nullcontext(entries())), self.assertRaises(INPUTS.UnsupportedPackage):
                INPUTS.inventory(root, "ArithmeticCore")
            self.assertEqual(count, 4097)

    def test_manifest_reader_bounds_bytes_before_parsing(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder).resolve() / "Package.swift"
            path.write_bytes(MANIFEST)
            self.assertEqual(INPUTS.read_manifest(path)["module"], "ArithmeticCore")
            path.write_bytes(MANIFEST + b" " * (64 * 1024))
            with self.assertRaises(INPUTS.UnsupportedPackage):
                INPUTS.read_manifest(path)

    def test_literal_fixture_and_nested_comments(self):
        expected = {"name": "LocalMath", "product": "ArithmeticProduct", "module": "ArithmeticCore"}
        self.assertEqual(INPUTS.manifest(MANIFEST), expected)
        self.assertEqual(INPUTS.manifest(MANIFEST.replace(b"\n", b"\r\n")), expected)
        with self.assertRaises(INPUTS.UnsupportedPackage):
            INPUTS.manifest(MANIFEST.replace(b"\n", "\u2028\n".encode(), 1))
        altered = MANIFEST.replace(b"let package", b"/* outer /* nested */ safe */ let package") + b"\n// not executable\n"
        self.assertEqual(INPUTS.manifest(altered), expected)

    def test_unsupported_or_unconsumed_executable_syntax(self):
        variants = [MANIFEST + b"\nprint(1)", MANIFEST.replace(b"let package", b"let ignored = run(); let package"),
                    MANIFEST.replace(b'"LocalMath"', b'compute()'), MANIFEST.replace(b'"LocalMath"', b'"Local\\(run())"'),
                    MANIFEST.replace(b'"LocalMath"', b'"Local\\u{004d}ath"'), MANIFEST.replace(b'"LocalMath"', b'#"LocalMath"#'),
                    MANIFEST.replace(b'"LocalMath"', b'"""LocalMath"""'), MANIFEST + b"\n/* unterminated",
                    MANIFEST.replace(b"import PackageDescription", b"import Foundation\nimport PackageDescription"),
                    MANIFEST.replace(b'.target(name: "ArithmeticCore")', b'.macro(name: "ArithmeticCore")'),
                    MANIFEST.replace(b'.target(name: "ArithmeticCore")', b'.target(name: "ArithmeticCore", dependencies: [])'),
                    MANIFEST.replace(b'.target(name: "ArithmeticCore")', b'.target(name: "Other")'),
                    MANIFEST.replace(b"products:", b"dependencies: [.package(path: \"Elsewhere\")], products:"),
                    MANIFEST.replace(b"name: \"LocalMath\"", b"name: \"LocalMath\", platforms: [.macOS(.v13)]")]
        for value in variants:
            with self.subTest(value=value[-100:]), self.assertRaises(INPUTS.UnsupportedPackage):
                INPUTS.manifest(value)

    def test_full_subtree_sees_unknown_extensions_and_empty_directories(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            (root / "Sources/ArithmeticCore").mkdir(parents=True)
            (root / "Package.swift").write_bytes(MANIFEST)
            (root / "Sources/ArithmeticCore/Math.swift").write_text("public func value() -> Int { 1 }\n")
            original = INPUTS.inventory(root, "ArithmeticCore")
            for name in ("Sources/ArithmeticCore/Hidden.c", "Sources/ArithmeticCore/Hidden.cpp", "data.bin", ".config"):
                path = root / name
                path.write_bytes(b"new")
                with self.subTest(name=name), self.assertRaises(INPUTS.UnsupportedPackage):
                    INPUTS.inventory(root, "ArithmeticCore")
                path.unlink()
            (root / "Resources").mkdir()
            with self.assertRaises(INPUTS.UnsupportedPackage):
                INPUTS.inventory(root, "ArithmeticCore")
            (root / "Resources").rmdir()
            self.assertEqual(original, INPUTS.inventory(root, "ArithmeticCore"))

    def test_source_content_addition_and_deletion_change_inventory(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            (root / "Sources/ArithmeticCore").mkdir(parents=True)
            (root / "Package.swift").write_bytes(MANIFEST)
            source = root / "Sources/ArithmeticCore/Math.swift"
            source.write_bytes(b"func value() {}")
            original = INPUTS.inventory(root, "ArithmeticCore")
            source.write_bytes(b"func other() {}")
            self.assertNotEqual(original, INPUTS.inventory(root, "ArithmeticCore"))
            source.unlink()
            with self.assertRaises(INPUTS.UnsupportedPackage):
                INPUTS.inventory(root, "ArithmeticCore")


if __name__ == "__main__":
    unittest.main()
