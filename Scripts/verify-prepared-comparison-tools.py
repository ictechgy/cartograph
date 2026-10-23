#!/usr/bin/env python3
"""Portable refusal controls for prepared tools; no native execution claim."""
import copy
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("prepared", Path(__file__).with_name("prepared-comparison-tools.py"))
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)


class PreparedToolsTests(unittest.TestCase):
    def test_compiler_input_overrides_are_refused_before_executing_tools(self):
        for key in (*P.COMPILER_OVERRIDES, "DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH"):
            with self.subTest(key=key), patch.object(P.platform, "system", return_value="Darwin"), \
                 patch.dict(os.environ, {key: "private-alternate-value"}, clear=True), patch.object(P, "capture") as capture, \
                 self.assertRaisesRegex(ValueError, "Compiler/runtime environment override") as error:
                P.toolchain_identity()
            capture.assert_not_called()
            self.assertNotIn("private-alternate", str(error.exception))

    @unittest.skipUnless(os.name == "posix", "Actual tracked POSIX symlinks require native CI")
    def test_tracked_header_and_directory_links_keep_identity_and_referent_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "Sources/CLMDB/include").mkdir(parents=True)
            (root / "Sources/CLMDB/lmdb.h").write_bytes(b"int db(void);\n")
            (root / "Common").mkdir()
            (root / "Common/a.swift").write_bytes(b"func a() {}\n")
            (root / "Plugin").mkdir()
            (root / ".gitignore").write_bytes(b"Common/ignored.swift\n")
            (root / "Sources/CLMDB/include/lmdb.h").symlink_to("../lmdb.h")
            (root / "Plugin/Common").symlink_to("../Common", target_is_directory=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "-qm", "linked fixture"], cwd=root, check=True)
            revision = P.git(root, "rev-parse", "HEAD")
            value = P.source_identity(root, revision)
            self.assertEqual(value["symlinks"]["Plugin/Common"]["referent_inputs"], ["Common/a.swift"])
            self.assertNotIn("Sources/CLMDB/include/lmdb.h", value["input_sha256"])
            self.assertEqual(value["input_sha256"]["Sources/CLMDB/lmdb.h"], P.digest(root / "Sources/CLMDB/lmdb.h"))
            P.verify_source_links(root, value)
            (root / "Common/ignored.swift").write_bytes(b"untracked build input")
            with self.assertRaisesRegex(ValueError, "Untracked or ignored"):
                P.source_identity(root, revision)
            (root / "Common/ignored.swift").unlink()
            alias = root / "Sources/CLMDB/include/lmdb.h"
            alias.unlink()
            alias.symlink_to("../../../Common/a.swift")
            with self.assertRaisesRegex(ValueError, "link identity changed"):
                P.verify_source_links(root, value)
            with self.assertRaises(ValueError):
                P.source_identity(root, revision)

    @unittest.skipUnless(os.name == "posix", "Actual tracked POSIX symlinks require native CI")
    def test_source_links_refuse_escape_dangling_cycles_untracked_hops_and_artifact_links(self):
        for kind in ("escape", "dangling", "cycle", "directory-cycle", "untracked-hop"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as folder:
                root = Path(folder).resolve()
                (root / "real").write_bytes(b"real")
                tracked = {"real": ("100644", "")}
                links = {}
                if kind == "directory-cycle":
                    (root / "A").mkdir(); (root / "B").mkdir()
                    pairs = {"A/link": "../B", "B/link": "../A"}
                else:
                    pairs = {"link": {"escape": "../outside", "dangling": "missing", "cycle": "other",
                                      "untracked-hop": ".ignored"}[kind]}
                    if kind == "cycle":
                        pairs["other"] = "link"
                    if kind == "untracked-hop":
                        (root / ".ignored").symlink_to("real")
                for name, target in pairs.items():
                    (root / name).symlink_to(target)
                    tracked[name] = ("120000", "")
                    links[name] = target
                with self.assertRaises(ValueError):
                    P.source_links(root, tracked, links)
                artifact = root / "artifact"
                (artifact / "bin").mkdir(parents=True)
                (artifact / "manifest.json").write_bytes(b"{}")
                (artifact / "bin/tool").symlink_to(root / "real")
                with self.assertRaisesRegex(ValueError, "symlink"):
                    P.verify_files(artifact, {"files": {"bin/tool": {"sha256": P.digest(root / "real"),
                        "bytes": 4, "executable": True}}})

    def admission_fixture(self, root):
        action = {"checkout_commit": "a" * 40, "checkout_tree": "b" * 40,
                  "run": "7", "attempt": "2", "pr_head": "c" * 40, "pr_base": "d" * 40}
        tools = {"identity": {"architecture": "arm64", "os_build": "OS123"}}
        artifacts = root / "artifacts"
        expected = {}
        for role in P.ROLES:
            folder = artifacts / role
            (folder / "bin").mkdir(parents=True)
            binary = folder / "bin/tool"
            binary.write_bytes((role + " executable").encode())
            revision = action["checkout_commit"] if role == "candidate" else P.COMPARATOR if role == "comparator" else P.BASELINE
            source = {"revision": revision, "tree": "e" * 40, "working_tree_status": "", "input_sha256": {}}
            build = {"returncode": 0, "timed_out": False, "wall_seconds": 10.2,
                     "command": ["/producer/swift", "build", "-c", "release", "--product",
                                 "index-dump" if role == "comparator" else "cartograph", "--force-resolved-versions", "-j", "3"]}
            evidence = ({"commands": [build], "revision": P.COMPARATOR} if role == "comparator" else
                        {"setup": {"mode": "fresh-release-package-build", "build_cost_measured": True, "build": build}})
            evidence["binary_sha256"] = P.digest(binary)
            manifest = {"version": 1, "status": "prepared-only", "role": role, "binding": action,
                        "toolchain": tools, "runtime_closure": {"nodes": {}}, "source": source,
                        "dependencies": {}, "producer": {"runner": "producer"}, "build_evidence": evidence,
                        "source_verified_before_after": True, "dependencies_verified_before_after": True,
                        "limits": {"jobs": 3, "setup_timeout_seconds": 600 if role == "baseline" else 1500},
                        "files": {"bin/tool": {"sha256": P.digest(binary), "bytes": binary.stat().st_size, "executable": True}}}
            P.save(folder / "manifest.json", manifest)
            expected[role] = {"manifest_sha256": P.digest(folder / "manifest.json"), "artifact_id": str(len(expected) + 1)}
        P.save(root / "expected.json", expected)
        args = argparse.Namespace(checkout=root / "checkout", artifacts=artifacts, output=root / "admission",
                                  expected=root / "expected.json")
        lock = args.checkout / "Fixtures/IndexStoreCLIBenchmark/indexstore-Package.resolved"
        lock.parent.mkdir(parents=True)
        lock.write_bytes(b"fixture lock")
        return args, action, tools

    @contextlib.contextmanager
    def admission_boundaries(self, args, action, tools):
        def source(root, revision, **kwargs):
            role = next(role for role in P.ROLES if P.read_json(args.artifacts / role / "manifest.json")["source"]["revision"] == revision)
            return P.read_json(args.artifacts / role / "manifest.json")["source"]
        def acquire(repository, revision, destination, evidence):
            destination.mkdir(parents=True)
        with patch.object(P, "binding", return_value=action), patch.object(P, "toolchain_identity", return_value=tools), \
             patch.object(P, "phase_progress"), patch.object(P, "base_module", return_value=types.SimpleNamespace(UPSTREAM="fixture")), \
             patch.object(P, "runtime_closure", return_value=({"nodes": {}}, {})), \
             patch.object(P, "source_identity", side_effect=source), patch.object(P, "acquire", side_effect=acquire), \
             patch.object(P, "verify_dependency_pins"), patch.object(P, "admit_comparator_dependencies"):
            yield

    def test_admission_rejects_replacement_manifest_even_when_internal_hashes_match(self):
        with tempfile.TemporaryDirectory() as folder:
            args, action, tools = self.admission_fixture(Path(folder))
            manifest_path = args.artifacts / "candidate/manifest.json"
            manifest = P.read_json(manifest_path)
            binary = manifest_path.parent / "bin/tool"
            binary.write_bytes(b"replaced executable")
            manifest["files"]["bin/tool"].update(sha256=P.digest(binary), bytes=binary.stat().st_size)
            manifest["build_evidence"]["binary_sha256"] = P.digest(binary)
            manifest_path.write_text(json.dumps(manifest))
            with self.admission_boundaries(args, action, tools), self.assertRaisesRegex(ValueError, "Producer manifest digest differs"):
                P.admit(args)
            self.assertFalse((args.output / "admission.json").exists())

    def test_admission_matches_role_run_toolchain_and_actual_bytes_before_permission(self):
        mutations = [lambda row: row.update(role="baseline"), lambda row: row["binding"].update(attempt="1"),
                     lambda row: row["binding"].update(checkout_commit="f" * 40),
                     lambda row: row["toolchain"]["identity"].update(os_build="other"),
                     lambda row: row["build_evidence"].update(binary_sha256="0" * 64)]
        for mutate in mutations:
            with self.subTest(mutation=mutate), tempfile.TemporaryDirectory() as folder:
                args, action, tools = self.admission_fixture(Path(folder))
                path = args.artifacts / "candidate/manifest.json"
                manifest = P.read_json(path)
                mutate(manifest)
                path.write_text(json.dumps(manifest))
                expected = P.read_json(args.expected)
                expected["candidate"]["manifest_sha256"] = P.digest(path)
                args.expected.write_text(json.dumps(expected))
                with self.admission_boundaries(args, action, tools), patch.object(Path, "chmod") as chmod, self.assertRaises(ValueError):
                    P.admit(args)
                chmod.assert_not_called()

    def test_successful_preparation_is_never_a_passed_comparison_and_keeps_producer_argv(self):
        with tempfile.TemporaryDirectory() as folder:
            args, action, tools = self.admission_fixture(Path(folder))
            with self.admission_boundaries(args, action, tools):
                P.admit(args)
            value = P.read_json(args.output / "admission.json")
            self.assertEqual(value["status"], "admitted-preparation-only")
            product = P.prepared_product(value, "candidate")
            self.assertEqual(product["setup"]["mode"], "verified-prepared-artifact")
            self.assertEqual(product["setup"]["producer_evidence"]["setup"]["build"]["command"][0], "/producer/swift")
            self.assertEqual(product["setup"]["consumer_source"], str(args.checkout.resolve()))
            self.assertEqual(value["tools"]["candidate"]["artifact_id"], "1")

    def test_inventory_detects_tamper_extra_missing_and_escape(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "bin").mkdir()
            tool = root / "bin/tool"
            tool.write_bytes(b"actual binary bytes")
            manifest = {"files": {"bin/tool": {"sha256": P.digest(tool), "bytes": tool.stat().st_size, "executable": True}}}
            (root / "manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(P.verify_files(root, manifest), tool)
            tool.write_bytes(b"modified binary now")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                P.verify_files(root, manifest)
            tool.write_bytes(b"actual binary bytes")
            (root / "unexpected").write_bytes(b"extra")
            with self.assertRaisesRegex(ValueError, "extra files"):
                P.verify_files(root, manifest)
            (root / "unexpected").unlink()
            (root / "extra-dir").mkdir()
            with self.assertRaisesRegex(ValueError, "extra directory"):
                P.verify_files(root, manifest)
            for bad in ("../outside", "/absolute", "bin/../tool", "bin\\tool", "C:/tool", "bin//tool", "./bin/tool"):
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    P.checked_relative(bad)

    def test_receipt_requires_real_success_and_preserves_original_measurement(self):
        build = {"returncode": 0, "timed_out": False, "wall_seconds": 15.4,
                 "command": ["/producer/swift", "build", "--package-path", "/producer/source",
                             "-c", "release", "--product", "cartograph", "--force-resolved-versions", "-j", "3"]}
        value = {"role": "candidate", "source_verified_before_after": True, "dependencies_verified_before_after": True,
                 "limits": {"jobs": 3, "setup_timeout_seconds": 1500}, "dependencies": {},
                 "build_evidence": {"setup": {"mode": "fresh-release-package-build", "build_cost_measured": True,
                                                "build": build}}}
        original = copy.deepcopy(value)
        P.verify_preparation(value)
        self.assertEqual(value, original)
        changes = [("returncode", 1), ("returncode", False), ("timed_out", True),
                   ("wall_seconds", None), ("wall_seconds", float("nan"))]
        for key, item in changes:
            bad = copy.deepcopy(value)
            bad["build_evidence"]["setup"]["build"][key] = item
            with self.subTest(key=key, item=item), self.assertRaises(ValueError):
                P.verify_preparation(bad)
        for key in ("source_verified_before_after", "dependencies_verified_before_after"):
            bad = copy.deepcopy(value)
            bad[key] = False
            with self.assertRaises(ValueError):
                P.verify_preparation(bad)
        bad = copy.deepcopy(value)
        bad["build_evidence"]["setup"]["mode"] = "supplied-binary"
        with self.assertRaisesRegex(ValueError, "Actual producer"):
            P.verify_preparation(bad)

    def test_dylib_install_identity_is_not_a_recursive_dependency(self):
        outputs = ["libIndexStore.dylib:\n\t@rpath/libIndexStore.dylib (compatibility version 0.0.0, current version 0.0.0)\n"
                   "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)",
                   "Load command 1\n          cmd LC_ID_DYLIB\n      cmdsize 56\n         name @rpath/libIndexStore.dylib (offset 24)\n"
                   "Load command 2\n          cmd LC_RPATH\n      cmdsize 32\n         path @loader_path (offset 12)"]
        with patch.object(P, "capture", side_effect=outputs):
            deps, paths = P.macho_loads(Path("libIndexStore.dylib"), {"paths": {"otool": "/tool/otool"}})
        self.assertEqual(deps, ["/usr/lib/libSystem.B.dylib"])
        self.assertEqual(paths, ["@loader_path"])

    def test_runtime_closure_keeps_os_build_separate_and_rejects_unknown_libraries(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary, developer = root / "bin/tool", root / "Xcode"
            binary.parent.mkdir()
            developer.mkdir()
            binary.write_bytes(b"executable")
            library = developer / "libIndexStore.dylib"
            library.write_bytes(b"explicit dlopen bytes")
            tools = {"identity": {"architecture": "arm64", "os_build": "OS123"}, "developer": str(developer),
                     "paths": {"lipo": "lipo", "libIndexStore": str(library)}}
            with patch.object(P, "capture", return_value="arm64"), \
                 patch.object(P, "macho_loads", return_value=(["/usr/lib/libSystem.B.dylib"], [])):
                closure, files = P.runtime_closure(binary, tools)
            self.assertEqual(set(files), {"bin/tool"})
            self.assertEqual(closure["os_build"], "OS123")
            self.assertIn("developer:libIndexStore.dylib", closure["nodes"])
            self.assertEqual(closure["nodes"]["developer:libIndexStore.dylib"]["sha256"], P.digest(library))
            with patch.object(P, "capture", return_value="arm64"), \
                 patch.object(P, "macho_loads", return_value=(["@rpath/missing.dylib"], [])), \
                 self.assertRaisesRegex(ValueError, "Missing or ambiguous"):
                P.runtime_closure(binary, tools)

    def test_source_identity_checks_actual_git_objects_not_only_revision_label(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "config", "core.autocrlf", "false"], cwd=root, check=True)
            (root / "Sources").mkdir()
            (root / "Sources/a.swift").write_text("func a() {}\n")
            (root / "Package.resolved").write_text('{"pins":[]}\n')
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
                           cwd=root, check=True)
            revision = P.git(root, "rev-parse", "HEAD")
            original = P.source_identity(root, revision)
            self.assertEqual(original["input_sha256"]["Sources/a.swift"], P.digest(root / "Sources/a.swift"))
            stamp = (root / "Sources/a.swift").stat()
            (root / "Sources/a.swift").write_text("func b() {}\n")
            os.utime(root / "Sources/a.swift", ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            with self.assertRaises(ValueError):
                P.source_identity(root, revision)

    def test_shallow_merge_binding_uses_raw_commit_parents_and_current_run(self):
        commit, tree, head, base = "a" * 40, "b" * 40, "c" * 40, "d" * 40
        env = {"GITHUB_SHA": commit, "GITHUB_RUN_ID": "7", "GITHUB_RUN_ATTEMPT": "2",
               "CARTOGRAPH_CI_PR_HEAD": head, "CARTOGRAPH_CI_PR_BASE": base}
        responses = [commit, tree, f"tree {tree}\nparent {base}\nparent {head}\n\nmerge"]
        with patch.dict(os.environ, env), patch.object(P, "git", side_effect=responses) as query:
            value = P.binding(Path("checkout"))
        self.assertEqual(value["pr_head"], head)
        self.assertEqual(query.call_args.args[1:], ("cat-file", "-p", "HEAD"))
        with patch.dict(os.environ, env), patch.object(P, "git", side_effect=[commit, tree, f"parent {base}"]), \
             self.assertRaisesRegex(ValueError, "expected PR merge"):
            P.binding(Path("checkout"))

    def test_retained_run_attestation_still_checks_actual_checkout_and_merge_parents(self):
        commit, tree, head, base = "a" * 40, "b" * 40, "c" * 40, "d" * 40
        value = {"run": "7", "attempt": "2", "checkout_commit": commit, "checkout_tree": tree,
                 "pr_head": head, "pr_base": base}
        with patch.dict(os.environ, {}, clear=True), patch.object(P, "git", side_effect=[commit, tree, f"parent {base}\nparent {head}\n\nmerge"]):
            P.verify_checkout_binding(Path("checkout"), value)
        for observed in (["f" * 40], [commit, "f" * 40], [commit, tree, f"parent {base}"]):
            with self.subTest(observed=observed), patch.dict(os.environ, {}, clear=True), \
                 patch.object(P, "git", side_effect=observed), self.assertRaises(ValueError):
                P.verify_checkout_binding(Path("checkout"), value)


if __name__ == "__main__":
    unittest.main()
