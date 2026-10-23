#!/usr/bin/env python3
"""Portable refusal controls for prepared tools; no native execution claim."""
import copy
import argparse
import contextlib
import hashlib
import importlib.util
import io
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
    @staticmethod
    def source_link_fixture(target="../../../IndexStoreCAPI/include/IndexStoreCAPI/indexstore_functions.h"):
        name = "Sources/IndexStoreDB_CIndexStoreDB/include/IndexStoreDB_CIndexStoreDB/indexstore_functions.h"
        resolved = "Sources/IndexStoreCAPI/include/IndexStoreCAPI/indexstore_functions.h"
        row = {"target_encoding": "slash-components-v1", "target_components": target.split("/"),
               "target_sha256": hashlib.sha256(os.fsencode(target)).hexdigest(), "resolved": resolved,
               "referent_inputs": [resolved]}
        return {"revision": P.COMPARATOR, "input_sha256": {resolved: "a" * 64}, "symlinks": {name: row}}, name

    def test_source_link_components_round_trip_and_refuse_tamper_old_shape_and_absolute_targets(self):
        for target in ("../../../IndexStoreCAPI/include/IndexStoreCAPI/indexstore_functions.h", ".././a//b", "../caf\u00e9.h"):
            source, name = self.source_link_fixture(target)
            original = copy.deepcopy(source)
            P.verify_source_link_shape(source)
            self.assertEqual(os.fsencode("/".join(source["symlinks"][name]["target_components"])), os.fsencode(target))
            self.assertEqual(source, original)
        source, name = self.source_link_fixture()
        bad = copy.deepcopy(source); bad["symlinks"][name]["target_components"][-1] = "changed.h"
        with self.assertRaisesRegex(ValueError, "target bytes differ"):
            P.verify_source_link_shape(bad)
        bad = copy.deepcopy(source); bad["symlinks"][name]["target_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "target bytes differ"):
            P.verify_source_link_shape(bad)
        bad = copy.deepcopy(source); row = bad["symlinks"][name]
        row["target"] = "/".join(row.pop("target_components")); del row["target_encoding"]
        with self.assertRaisesRegex(ValueError, "Incompatible source link target encoding"):
            P.verify_source_link_shape(bad)
        for target in ("/absolute.h", "C:/outside.h", "../bad\\name.h"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                P.verify_source_link_shape(self.source_link_fixture(target)[0])
        for parts in (None, "../wrong.h", [], ["..", None], ["../hidden-component.h"], ["..", "bad\0name"]):
            bad = copy.deepcopy(source); bad["symlinks"][name]["target_components"] = parts
            with self.subTest(parts=parts), self.assertRaises(ValueError):
                P.verify_source_link_shape(bad)

    def test_chain_aware_link_resolution_preserves_safe_parent_traversal(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            (root / "a").mkdir(); (root / "b/c/d").mkdir(parents=True)
            (root / "target.h").write_bytes(b"target")
            (root / "b/c/d/payload.h").write_bytes(b"payload")
            links = {"a/s": "../b/c/d", "a/link": "s/../../../target.h"}
            tracked = {name: ("120000", "") for name in links}
            regular = ("target.h", "b/c/d/payload.h")
            tracked.update({name: ("100644", "") for name in regular})
            original_is_symlink = Path.is_symlink
            def is_link(path):
                return path in {root / name for name in links} or original_is_symlink(path)
            def read_link(path):
                return links[Path(path).relative_to(root).as_posix()]
            # Portable resolver replay uses real referent files and simulated link syscalls.
            # The separate POSIX controls exercise actual filesystem symlinks in native CI.
            with patch.object(Path, "is_symlink", is_link), patch.object(P.os, "readlink", side_effect=read_link):
                inventory = P.source_links(root, tracked, links)
                source = {"input_sha256": {name: P.digest(root / name) for name in regular}, "symlinks": inventory}
                self.assertEqual(inventory["a/link"]["resolved"], "target.h")
                P.verify_source_link_shape(source)
                P.verify_source_links(root, source)
                links["a/link"] = "s/../../../../outside.h"
                with self.assertRaisesRegex(ValueError, "escapes checkout"):
                    P.source_links(root, tracked, links)

    @unittest.skipUnless(os.name == "posix", "Actual chained source links require native CI")
    def test_actual_chained_source_link_preserves_safe_parent_traversal(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "a").mkdir(); (root / "b/c/d").mkdir(parents=True)
            (root / "target.h").write_bytes(b"target")
            (root / "b/c/d/payload.h").write_bytes(b"payload")
            (root / "a/s").symlink_to("../b/c/d", target_is_directory=True)
            (root / "a/link").symlink_to("s/../../../target.h")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "-qm", "chained link fixture"], cwd=root, check=True)
            source = P.source_identity(root, P.git(root, "rev-parse", "HEAD"))
            self.assertEqual(source["symlinks"]["a/link"]["resolved"], "target.h")
            P.verify_source_link_shape(source)
            P.verify_source_links(root, source)
            (root / "a/link").unlink()
            (root / "a/link").symlink_to("s/../../../../outside.h")
            with self.assertRaisesRegex(ValueError, "escapes checkout"):
                P.verify_source_links(root, source)

    def test_prepared_link_components_normalize_without_allowing_arbitrary_relative_targets(self):
        spec = importlib.util.spec_from_file_location("link_bundle_normalizer", Path(__file__).with_name("normalize-indexstore-bundles.py"))
        normalizer = importlib.util.module_from_spec(spec); spec.loader.exec_module(normalizer)
        source, name = self.source_link_fixture()
        old = copy.deepcopy(source); row = old["symlinks"][name]
        row["target"] = "/".join(row.pop("target_components")); del row["target_encoding"]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            for label, identity in (("old", old), ("new", source)):
                raw = root / label; raw.mkdir()
                document = {"mode": "verified-prepared-artifact", "source": identity}
                (raw / "results.json").write_text(json.dumps(document), encoding="utf-8")
                args = argparse.Namespace(input=raw, output=root / (label + "-public"), prefix=[])
                if label == "old":
                    with self.assertRaises(normalizer.EVIDENCE.PublicationBlocked) as error:
                        normalizer.EVIDENCE.package(args)
                    self.assertEqual(normalizer.diagnostic(error.exception)["reason"], "unmapped-absolute-path")
                else:
                    normalizer.EVIDENCE.package(args)
                    published = json.loads((args.output / "results.json").read_text(encoding="utf-8"))
                    self.assertEqual(published, document)
                    P.verify_source_link_shape(published["source"])
            (root / "new/results.json").write_text(json.dumps({"arbitrary_target": "../../private/file"}), encoding="utf-8")
            with self.assertRaises(normalizer.EVIDENCE.PublicationBlocked):
                normalizer.EVIDENCE.package(argparse.Namespace(input=root / "new", output=root / "still-refused", prefix=[]))

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
            link = value["symlinks"]["Sources/CLMDB/include/lmdb.h"]
            self.assertEqual(link["target_components"], ["..", "lmdb.h"])
            self.assertEqual(link["target_sha256"], hashlib.sha256(b"../lmdb.h").hexdigest())
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
                  "source": {"input_sha256": {}, "symlinks": {}},
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

    def dylib_block(self, command="LC_ID_DYLIB", number=0, version="1.0.0", use_options=None,
                    name="@rpath/libIndexStore.dylib"):
        marker = "   time stamp 1 Thu Jan  1 00:00:01 1970" if use_options is None else "      options " + use_options
        offset = 24 if use_options is None else 28
        return (f"Load command {number}\n          cmd {command}\n      cmdsize 56\n"
                f"         name {name} (offset {offset})\n" + marker +
                f"\n      current version {version}\ncompatibility version {version}")

    def test_dylib_install_identity_is_not_a_recursive_dependency(self):
        outputs = ["libIndexStore.dylib:\n\t@rpath/libIndexStore.dylib (compatibility version 0.0.0, current version 0.0.0)\n"
                   "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)",
                   "libIndexStore.dylib:\n" + self.dylib_block() + "\n" +
                   "Load command 1\n          cmd LC_RPATH\n      cmdsize 32\n         path @loader_path (offset 12)"]
        with patch.object(P, "capture", side_effect=outputs) as capture:
            deps, paths = P.macho_loads(Path("libIndexStore.dylib"),
                                      {"paths": {"otool": "/tool/otool"}, "identity": {"architecture": "arm64"}})
        self.assertEqual(deps, ["/usr/lib/libSystem.B.dylib"])
        self.assertEqual(paths, ["@loader_path"])
        self.assertEqual([call.args[0][1:4] for call in capture.call_args_list],
                         [["-arch", "arm64", "-L"], ["-arch", "arm64", "-l"]])

    def test_complete_official_dylib_variants_accept_only_their_positioned_version_field(self):
        # Apple ofile_print.c print_dylib_command와 LLVM PrintDylibCommand의 전체 필드를 쓴다.
        for command in sorted(P.MACHO_DYLIB_COMMANDS):
            for version in ("1.0.0", "n/a"):
                for options in (None, "", "weak re-export upward delay-init "):
                    text = "tool:\n" + self.dylib_block(command, version=version, use_options=options)
                    with self.subTest(command=command, version=version, options=options):
                        self.assertEqual(P.parse_macho_commands(text, Path("tool"), "arm64"),
                                         ([], "@rpath/libIndexStore.dylib" if command == "LC_ID_DYLIB" else None))
        full = "tool:\n" + self.dylib_block()
        bad = [full.rsplit("\n", 1)[0], full.replace("compatibility version", "unexpected version"),
               full.replace("compatibility version", " compatibility version"),
               full.replace("compatibility version 1.0.0", "compatibility version unknown"),
               full.replace("current version 1.0.0", "current version unknown"),
               full.replace("time stamp 1 Thu Jan  1 00:00:01 1970", "time stamp 1 garbage"),
               full + "\ncompatibility version 1.0.0", full + "\n arbitrary extra field",
               "tool:\n" + self.dylib_block().replace("LC_ID_DYLIB", "LC_UUID"),
               "tool:\n" + self.dylib_block(use_options="unknown ")]
        for text in bad:
            with self.subTest(text=text), self.assertRaises(P.MachOParseError):
                P.parse_macho_commands(text, Path("tool"), "arm64")

    def test_complete_official_note_accepts_only_its_positioned_bounded_owner(self):
        # Apple/LLVM LC_NOTE는 data_owner를 들여쓰기 없이 최대 16바이트로 출력한다.
        for owner in ("", "build metadata", "sixteen-byte-own", "\u00e9" * 8):
            text = ("tool:\nLoad command 0\n       cmd LC_NOTE\n   cmdsize 40\ndata_owner " + owner +
                    "\n    offset 256\n      size 48")
            with self.subTest(owner=owner):
                self.assertEqual(P.parse_macho_commands(text, Path("tool"), "arm64"), ([], None))
        text = "tool:\nLoad command 0\n       cmd LC_NOTE\n   cmdsize 40\ndata_owner build\n    offset 256\n      size 48"
        bad = [text.rsplit("\n", 1)[0], text.replace("data_owner build", "data_owner " + "x" * 17),
               text.replace("data_owner build", "data_owner " + "\u00e9" * 9),
               text.replace("data_owner build", "unknown_owner build"),
               text.replace("data_owner build", " data_owner build"),
               text.replace("LC_NOTE", "LC_UUID"), text.replace("offset 256", "offset 256 (past end of file)"),
               text.replace("size 48", "size nope"), text + "\ndata_owner other", text + "\n unknown extra"]
        for value in bad:
            with self.subTest(text=value), self.assertRaises(P.MachOParseError):
                P.parse_macho_commands(value, Path("tool"), "arm64")

    def test_full_dylib_note_and_rpath_blocks_keep_loaded_dependency_and_exclude_only_self(self):
        path = Path("libIndexStore.dylib")
        system = "/usr/lib/libSystem.B.dylib"
        listed = (f"{path}:\n\t@rpath/libIndexStore.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
                  f"\t{system} (compatibility version 1.0.0, current version 1.0.0)")
        commands = (f"{path}:\n" + self.dylib_block() + "\n" +
                    self.dylib_block("LC_LOAD_DYLIB", 1, name=system) +
                    "\nLoad command 2\n       cmd LC_NOTE\n   cmdsize 40\ndata_owner build metadata\n"
                    "    offset 256\n      size 48\nLoad command 3\n          cmd LC_RPATH\n      cmdsize 32\n"
                    "         path @loader_path (offset 12)")
        tools = {"paths": {"otool": "/tool/otool"}, "identity": {"architecture": "arm64"}}
        with patch.object(P, "capture", side_effect=[listed, commands]):
            self.assertEqual(P.macho_loads(path, tools), ([system], ["@loader_path"]))

    def test_explicit_slice_handles_official_thin_and_fat_headers_without_accepting_all_slices(self):
        # Apple main.c의 architecture header와 LLVM의 단일 -arch header를 각각 보존한다.
        path = Path("libIndexStore.dylib")
        dependency = "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)"
        commands = "Load command 0\n          cmd LC_RPATH\n      cmdsize 32\n         path @loader_path (offset 12)"
        tools = {"paths": {"otool": "/tool/otool"}, "identity": {"architecture": "arm64"}}
        fat = f"{path} (architecture x86_64):\n{dependency}\n{path} (architecture arm64):\n{dependency}"
        with self.assertRaisesRegex(P.MachOParseError, "selected Mach-O header"):
            P.parse_macho_dependencies(fat, path, "arm64")
        for selected_header in (f"{path}:", f"{path} (architecture arm64):"):
            def output(argv):
                if "-arch" not in argv:
                    return fat
                self.assertEqual(argv[1:3], ["-arch", "arm64"])
                return selected_header + "\n" + (dependency if "-L" in argv else commands)
            with self.subTest(header=selected_header), patch.object(P, "capture", side_effect=output):
                self.assertEqual(P.macho_loads(path, tools), (["/usr/lib/libSystem.B.dylib"], ["@loader_path"]))

    def test_dependency_parser_rejects_unknown_truncated_mismatched_and_repeated_headers(self):
        path = Path("tool")
        row = "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)"
        bad = ["", row, "other:\n" + row, "tool (architecture x86_64):\n" + row,
               "tool: is a truncated object file", "tool:\n" + row + "\ntool:\n" + row,
               "tool:\n\tunknown", "tool:\n" + row[:-1], "tool:\n" + row + "\n", "tool:\n\x1b[31m" + row]
        for text in bad:
            with self.subTest(text=text), self.assertRaises(P.MachOParseError):
                P.parse_macho_dependencies(text, path, "arm64")
        # 기존 정규식이 이미 허용한 LLVM suffix는 이번 실패 원인으로 간주하지 않는다.
        for suffix in ("weak", "reexport", "upward", "lazy"):
            self.assertEqual(P.parse_macho_dependencies("tool:\n" + row[:-1] + ", " + suffix + ")", path, "arm64"),
                             ["/usr/lib/libSystem.B.dylib"])

    def test_load_commands_require_selected_header_and_complete_rpath_identity(self):
        path = Path("tool")
        rpath = "Load command 0\n          cmd LC_RPATH\n      cmdsize 32\n         path @loader_path (offset 12)"
        bad = [rpath, "other:\n" + rpath, "tool (architecture x86_64):\n" + rpath,
               "tool:", "tool:\n" + rpath.rsplit("\n", 1)[0], "tool:\n" + rpath + "\nunknown",
               "tool:\n" + rpath + "\ntool (architecture x86_64):",
               "tool:\n" + rpath.replace("Load command 0", "Load command 1"),
               "tool:\nLoad command 0\n          cmd LC_ID_DYLIB\n      cmdsize 24"]
        for text in bad:
            with self.subTest(text=text), self.assertRaises(P.MachOParseError):
                P.parse_macho_commands(text, path, "arm64")
        identity = self.dylib_block()
        with self.assertRaisesRegex(P.MachOParseError, "Duplicate dylib identity"):
            P.parse_macho_commands("tool:\n" + identity + "\n" + identity.replace("Load command 0", "Load command 1"), path, "arm64")

    def test_macho_failure_diagnostic_is_bounded_control_safe_and_preserves_original_error(self):
        tools = {"paths": {"otool": "/tool/otool"}, "identity": {"architecture": "arm64", "tools_sha256": {"otool": "a" * 64}}}
        text = "tool:\n\tbad\x1b[31m\x00" + "\U0001f600" * 100000
        stream = io.StringIO()
        with patch.object(P, "otool_version", return_value={"stderr": P.observed_text("Apple version\x1b[31m")}), \
             contextlib.redirect_stdout(stream):
            P.emit_macho_observation(Path("tool\n::error::fake"), tools, "-L", text,
                                     P.MachOParseError("Unparsed Mach-O dependency", text.split("\n")[1]))
        body = stream.getvalue()
        self.assertLessEqual(len(body.encode("ascii")), P.MACHO_DIAGNOSTIC_LIMIT)
        self.assertEqual(len(body.splitlines()), 1)
        self.assertNotIn("\x1b", body); self.assertNotIn("\x00", body)
        value = json.loads(body.removeprefix("PREPARED_MACHO "))
        self.assertEqual(value["otool_sha256"], "a" * 64)
        self.assertTrue(value["first_unparsed_line"]["truncated"])
        self.assertIn("\\n", body)
        with patch.object(P, "capture", return_value="tool:\n\tbad"), \
             patch.object(P, "otool_version", side_effect=OSError("version failed")), \
             patch("builtins.print", side_effect=OSError("closed log pipe")), \
             self.assertRaisesRegex(P.MachOParseError, "Unparsed Mach-O dependency"):
            P.macho_loads(Path("tool"), tools)

    def test_otool_version_keeps_stderr_and_uses_its_own_bounded_supervisor(self):
        def run(argv, cwd, stem, timeout, cap):
            self.assertEqual(argv, ["/tool/otool", "--version"])
            self.assertEqual((timeout, cap), (10, 32768))
            stdout, stderr = stem.with_suffix(".stdout"), stem.with_suffix(".stderr")
            stdout.write_bytes(b""); stderr.write_bytes(b"otool(1): Apple Inc. version fixture\n")
            return {"returncode": 0, "owned_root_reaped": True, "stdout": str(stdout), "stderr": str(stderr)}
        with patch.object(P, "base_module", return_value=types.SimpleNamespace(_run_stream_capped=run)):
            result = P.otool_version({"paths": {"otool": "/tool/otool"}})
        self.assertIn("Apple Inc. version fixture", result["stderr"]["prefix"])
        self.assertEqual(result["stdout"]["bytes"], 0)

    def test_default_headers_are_diagnostic_only_and_selected_preflight_precedes_acquisition(self):
        tools = {"paths": {"otool": "/tool/otool", "libIndexStore": "libIndexStore.dylib"},
                 "identity": {"architecture": "arm64"}}
        dep = "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)"
        fat = "libIndexStore.dylib (architecture x86_64):\n" + dep + "\nlibIndexStore.dylib (architecture arm64):\n" + dep
        stream = io.StringIO()
        with patch.object(P, "capture", return_value=fat), patch.object(P, "macho_loads") as selected, \
             patch.object(P, "otool_version", return_value={}), contextlib.redirect_stdout(stream):
            P.preflight_macho(tools)
        selected.assert_called_once_with(Path("libIndexStore.dylib"), tools)
        row = json.loads(stream.getvalue().removeprefix("PREPARED_MACHO "))
        self.assertEqual(len(row["headers"]), 2)
        self.assertEqual(row["first_unparsed_line"]["prefix"], "libIndexStore.dylib (architecture arm64):")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = argparse.Namespace(checkout=root, output=root / "output", evidence=root / "evidence",
                                      role="baseline", setup_timeout=600, jobs=3)
            fake_base = types.SimpleNamespace(run=unittest.mock.Mock())
            with patch.object(P, "base_module", return_value=fake_base), patch.object(P, "phase_progress"), \
                 patch.object(P, "binding", return_value={"checkout_commit": "a" * 40}), \
                 patch.object(P, "toolchain_identity", return_value=tools), patch.object(P, "acquire") as acquire, \
                 patch.object(P, "preflight_macho", side_effect=P.MachOParseError("fixture preflight refusal")), \
                 self.assertRaisesRegex(P.MachOParseError, "fixture preflight refusal"):
                P.prepare(args)
            acquire.assert_not_called(); fake_base.run.assert_not_called()
            self.assertFalse((args.output / "manifest.json").exists())

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
