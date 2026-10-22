#!/usr/bin/env python3
"""Check Git capture selection locally and the real Swift compiler flow on macOS."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("git_impact", Path(__file__).with_name("cartograph-git-impact.py"))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.STDOUT).decode().strip()


class GitCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cartograph-git-test-")
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        git(self.root, "init", "-q")
        git(self.root, "config", "user.name", "Fixture")
        git(self.root, "config", "user.email", "fixture@example.invalid")
        (self.root / "Old.swift").write_text("func old() {}\n")
        (self.root / ".gitignore").write_text(".build/\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "base")
        self.base = capture.revision(self.root, "HEAD")

    def tearDown(self):
        self.temporary.cleanup()

    def test_deleted_and_renamed_paths_survive_exact_commit_selection(self):
        git(self.root, "mv", "Old.swift", "New.swift")
        git(self.root, "commit", "-qm", "rename")
        head = capture.revision(self.root, "HEAD")
        self.assertEqual(capture.changed_paths(self.root, self.base, head, False), ["New.swift", "Old.swift"])
        self.assertEqual(capture.changed_paths(self.root, head, head, False), [])

    def test_working_tree_preserves_staged_unstaged_deleted_and_untracked(self):
        (self.root / "Old.swift").unlink()
        (self.root / "Staged.swift").write_text("func staged() {}\n")
        git(self.root, "add", ".")
        (self.root / "Staged.swift").write_text("func staged() { print(1) }\n")
        (self.root / "Untracked.swift").write_text("func new() {}\n")
        destination = Path(self.temporary.name) / "copy"
        capture.checkout(self.root, destination, self.base)
        capture.copy_working_tree(self.root, destination)
        self.assertEqual(capture.source_fingerprint(self.root), capture.source_fingerprint(destination))
        self.assertFalse((destination / "Old.swift").exists())
        self.assertEqual(capture.changed_paths(self.root, self.base, self.base, True),
                         ["Old.swift", "Staged.swift", "Untracked.swift"])

    def test_body_edit_with_restored_mtime_changes_content_identity(self):
        source = self.root / "Old.swift"
        stamp = source.stat()
        before = capture.source_fingerprint(self.root)
        source.write_text("func old() { print(2) }\n")
        os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        self.assertNotEqual(capture.source_fingerprint(self.root), before)

    def test_working_tree_restored_to_base_is_not_a_changed_seed(self):
        source = self.root / "Old.swift"
        original = source.read_bytes()
        source.write_text("func old() { print(3) }\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "head edit")
        head = capture.revision(self.root, "HEAD")
        source.write_bytes(original)
        index = self.root / ".git/index"
        index_before = index.read_bytes()
        self.assertEqual(capture.changed_paths(self.root, self.base, head, True), [])
        self.assertEqual(index.read_bytes(), index_before)
        git(self.root, "add", ".")
        self.assertEqual(capture.changed_paths(self.root, self.base, head, True), [])

    def test_head_addition_deleted_from_working_tree_is_not_a_changed_seed(self):
        source = self.root / "New.swift"
        source.write_text("func added() {}\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "head addition")
        head = capture.revision(self.root, "HEAD")
        source.unlink()
        self.assertEqual(capture.changed_paths(self.root, self.base, head, True), [])
        git(self.root, "add", ".")
        self.assertEqual(capture.changed_paths(self.root, self.base, head, True), [])


def compiler_flow(binary: Path):
    output = Path(tempfile.mkdtemp(prefix="cartograph-git-compiler-"))
    root = output / "fixture"
    root.mkdir()
    (root / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ChangeFixture", products: [.library(name: "ChangeFixture", targets: ["ChangeFixture"])],
    targets: [.target(name: "ChangeFixture"), .testTarget(name: "ChangeFixtureTests", dependencies: ["ChangeFixture"])])
''')
    (root / "Sources/ChangeFixture").mkdir(parents=True)
    (root / "Tests/ChangeFixtureTests").mkdir(parents=True)
    old = root / "Sources/ChangeFixture/Old.swift"
    old.write_text("public func removed() -> Int { 1 }\npublic func caller() -> Int { removed() }\n")
    (root / "Tests/ChangeFixtureTests/Tests.swift").write_text(
        "import Testing\n@testable import ChangeFixture\n@Test func usesCaller() { #expect(caller() == 1) }\n")
    git(root, "init", "-q")
    git(root, "config", "user.name", "Fixture")
    git(root, "config", "user.email", "fixture@example.invalid")
    git(root, "add", ".")
    git(root, "commit", "-qm", "before")
    base = capture.revision(root, "HEAD")
    old.unlink()
    (root / "Sources/ChangeFixture/New.swift").write_text("public func caller() -> Int { 1 }\n")
    before_status = git(root, "status", "--porcelain")
    invocation = subprocess.run([sys.executable, str(Path(__file__).with_name("cartograph-git-impact.py")),
        "--project", str(root), "--cartograph", str(binary), "--base", base, "--working-tree",
        "--output", str(output / "evidence")], capture_output=True, text=True, timeout=600)
    assert invocation.returncode in (0, 2), invocation.stderr
    result = output / "evidence/impact.json"
    assert result.is_file(), invocation.stderr
    document = json.loads(result.read_text())
    expected_exit = 2 if document["status"] == "incomplete" or document["changeInput"]["analysisExitCode"] != 0 else 0
    assert invocation.returncode == expected_exit
    print(json.dumps({"evidence": str(result), "status": document["status"],
        "beforeSelected": document["before"]["selected"], "currentSelected": document["current"]["selected"],
        "unresolvedInputs": document["unresolvedInputs"], "beforeTests": document["before"]["tests"]}, indent=2))
    assert document["before"]["input"]["mode"] == "historical-snapshot"
    assert document["before"]["input"]["fingerprint"]
    assert document["changeInput"]["before"]["sourceStableDuringBuild"]
    assert document["changeInput"]["current"]["freshIndex"]
    assert any(s["name"] == "removed()" for s in document["before"]["selected"])
    assert all(s["name"] != "removed()" for s in document["current"]["selected"])
    assert any(s["name"] == "usesCaller()" for s in document["before"]["tests"])
    assert git(root, "status", "--porcelain") == before_status
    print(json.dumps({"status": "passed", "evidence": str(result), "changeInput": document["changeInput"]}, indent=2))
    # HEAD의 편집을 작업 트리에서 base로 복원한 경우에는 CLI까지 빈 선택을 보존한다.
    (root / "Sources/ChangeFixture/New.swift").unlink()
    original = "public func removed() -> Int { 1 }\npublic func caller() -> Int { removed() }\n"
    old.write_text(original.replace("{ 1 }", "{ 2 }"))
    git(root, "add", ".")
    git(root, "commit", "-qm", "head body edit")
    old.write_text(original)
    empty_result = capture.analyze(argparse.Namespace(project=str(root), cartograph=str(binary), base=base, head=None,
        working_tree=True, output=str(output / "empty-evidence"), timeout=600, depth=None, limit=200))
    empty = json.loads(empty_result.read_text())
    assert empty["changeInput"]["changedFiles"] == []
    assert empty["before"]["selected"] == [] and empty["current"]["selected"] == []
    assert empty["unresolvedInputs"] == []
    assert empty["status"] == "noChanges"
    print(json.dumps({"status": "passed", "emptyPatchEvidence": str(empty_result)}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cartograph", type=Path)
    args = parser.parse_args()
    success = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(GitCaptureTests)).wasSuccessful()
    if not success:
        raise SystemExit(1)
    if args.cartograph:
        compiler_flow(args.cartograph.resolve())
