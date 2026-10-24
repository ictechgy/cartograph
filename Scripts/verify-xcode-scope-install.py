#!/usr/bin/env python3
"""Load the actual installed capture dependencies; does not build or claim Xcode support."""
import argparse
import importlib.util
from pathlib import Path


def verify(directory):
    spec = importlib.util.spec_from_file_location("installed_scope", directory / "cartograph-xcode-scope.py")
    scope = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scope)
    inputs = scope.package_helper("xcode-local-package-inputs")
    evidence = scope.package_helper("xcode-local-package-evidence")
    workspace = scope.package_helper("xcode-workspace-inputs")
    capture = scope.package_helper("xcode-workspace-capture")
    assert workspace.projects(b'<Workspace><FileRef location="group:Example.xcodeproj"/></Workspace>') == ["Example.xcodeproj"]
    assert callable(capture.capture)
    value = inputs.manifest(b'// swift-tools-version: 6.0\nimport PackageDescription\n'
        b'let package = Package(name: "Local", products: [.library(name: "Product", targets: ["Module"])], '
        b'targets: [.target(name: "Module")])\n')
    assert value == {"name": "Local", "product": "Product", "module": "Module"}
    assert evidence.operand(["/tool/linker", "-Xlinker", "-map", "-Xlinker", "/observed.map"], "-map") == "/observed.map"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scripts-dir", required=True, type=Path)
    verify(parser.parse_args().scripts_dir.resolve())
