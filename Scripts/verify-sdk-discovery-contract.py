#!/usr/bin/env python3
"""네이티브 SDK 검색 경계 제안이 승인된 세대와 공개 경계를 지키는지 검사한다."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("sdk_discovery", ROOT / "Scripts/validate-native-sdk-discovery.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class NativeDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.lifecycle = self.root / "mixed/validation"
        self.lifecycle.mkdir(parents=True)
        self.project = self.lifecycle / "Project"
        self.project.mkdir()
        self.generation = self.lifecycle / "Generations/restored_rebuilt"
        self.store = self.generation / "IndexStore"
        self.build = self.generation / "Build"
        self.store.mkdir(parents=True)
        (self.build / "modules").mkdir(parents=True)
        (self.store / "record").write_bytes(b"compiler-index")
        (self.build / "modules/FeatureAlpha.swiftmodule").write_bytes(b"module")
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.toolchain = self.developer / "Toolchains/XcodeDefault.xctoolchain"
        self.sdk = self.developer / "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        self.sdk.mkdir(parents=True)
        self.tools = {
            name: self.toolchain / suffix
            for name, suffix in {
                "swiftc": "usr/bin/swiftc",
                "clang": "usr/bin/clang",
                "library": "usr/lib/libIndexStore.dylib",
            }.items()
        }
        for name, path in self.tools.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        self.frontend = self.tools["swiftc"].with_name("swift-frontend")
        self.frontend.write_bytes(b"frontend")
        compiler_pins = mock.patch.object(
            M.SELECTOR, "REVIEWED_COMPILER_SHA256",
            {"swift": M.digest(self.tools["swiftc"]), "clang": M.digest(self.tools["clang"])},
        )
        compiler_pins.start()
        self.addCleanup(compiler_pins.stop)
        self.xcrun = self.root / "usr/bin/xcrun"
        self.xcrun.parent.mkdir(parents=True)
        self.xcrun.write_bytes(b"xcrun")
        import shutil

        shutil.copytree(
            ROOT / "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/fixture", self.project, dirs_exist_ok=True
        )
        self.setup = {
            **{k: str(v) for k, v in self.tools.items()},
            "sdk_path": str(self.sdk),
            "sdk_version": "26.5",
            "sdk_build": "23F81a",
            "target_triple": "arm64-apple-ios16.0-simulator",
            "requested_sdk": "iphonesimulator",
            "platform_path": str(self.sdk.parents[2]),
            "compiler_index_policy": "fresh-shared-v2",
            "compiler_toolchain_files": {str(p): M.digest(p) for p in [*self.tools.values(), self.frontend]},
        }
        self.commands = M.COMMON.command_plan(
            self.project,
            self.store,
            self.build,
            str(self.sdk),
            self.setup["target_triple"],
            str(self.tools["swiftc"]),
            str(self.tools["clang"]),
            self.setup["platform_path"],
            False,
        )
        self.accepted = dict(
            status="accepted",
            id="restored_rebuilt",
            store=str(self.store),
            build=str(self.build),
            source_files=M.COMMON.source_manifest(self.project),
            toolchain_files=self.setup["compiler_toolchain_files"],
            index_files=M.COMMON.manifest(self.store),
            build_files=M.COMMON.manifest(self.build),
            commands_sha256=M.GENERATIONS.content_digest(self.commands),
            sdk_content_identity={"contents_sha256": None},
        )
        self.state = dict(
            status="passed",
            name="restored_rebuilt",
            project=str(self.project),
            accepted_generation=self.accepted,
            compiler_index_policy="fresh-shared-v2",
        )
        self.results = dict(
            status="passed",
            ios_execution="compiler-only",
            compiler_index_policy="fresh-shared-v2",
            setup=self.setup,
            observation_failures=[],
        )
        self.state_dir = self.lifecycle / "runs/restored_rebuilt"
        self.state_dir.mkdir(parents=True)
        self.write_inputs()
        self.calls = []

    def write_inputs(self):
        for path, value in [
            (self.lifecycle / "results.json", self.results),
            (self.state_dir / "state.json", self.state),
            (self.state_dir / "commands.json", self.commands),
        ]:
            path.write_text(json.dumps(value))

    def fake_command(self, argv, cwd, stem, environment, timeout):
        self.calls.append(argv)
        request = json.loads(Path(argv[argv.index("--request") + 1]).read_text())
        output = Path(argv[argv.index("--output") + 1])
        output.mkdir(parents=True)
        proposal = dict(
            status="awaiting-root-review",
            accepted=False,
            final_protocol_ready=False,
            exit_code=0,
            proposal=dict(
                sdk_version=self.setup["sdk_version"],
                sdk_build=self.setup["sdk_build"],
                roots={"SDK": str(self.sdk), "TOOLCHAIN": str(self.toolchain)},
                clang_search_paths=[],
                unsealed_absence_dependencies=[],
            ),
            request=request,
            compile_phase=M.SELECTOR.compile_phase_binding(request),
        )
        (output / "results.json").write_text(json.dumps(proposal))
        for suffix in ["stdout", "stderr"]:
            Path(str(stem) + "." + suffix).write_text("")
        row = dict(
            completed=True,
            passed=True,
            returncode=0,
            observed_returncode=0,
            failure=None,
            wall_seconds=0.0,
            stdout=str(stem) + ".stdout",
            stderr=str(stem) + ".stderr",
            descendant_cleanup_verified=False,
        )
        Path(str(stem) + ".json").write_text(json.dumps(row))
        return row

    def execute(self, command=None, output=None):
        return M.execute(
            self.lifecycle / "results.json",
            output or self.root / "output",
            command=command or self.fake_command,
            xcrun=self.xcrun,
        )

    def test_request_preserves_actual_search_paths_cpp17_and_arc(self):
        r = self.execute()
        self.assertEqual(r["status"], "awaiting-root-review")
        self.assertFalse(r["accepted"])
        self.assertFalse(r["final_protocol_ready"])
        self.assertEqual(len(self.calls), 1)
        q = json.loads((self.root / "output/setup/selector-request.json").read_text())
        self.assertEqual(q["search_flags"]["clang"], ["-I", str(self.project / "Sources/BridgeKit/include")])
        self.assertEqual(
            q["search_flags"]["swift"],
            ["-I", str(self.project / "Sources/BridgeKit/include"), "-I", str(self.build / "modules")],
        )
        self.assertEqual(q["context_options"]["objective-c++"], ["-std=c++17"])
        self.assertEqual(
            q["extra_contexts"], [{"id": "objective-c-arc", "language": "objective-c", "options": ["-fobjc-arc"]}]
        )
        self.assertEqual(r["generation_guard_before"]["status"], "passed")
        self.assertEqual(r["generation_guard_after"]["status"], "passed")
        self.assertEqual(q["compile_phase"]["commands"], self.commands)
        self.assertEqual(r["compile_phase"]["commands_sha256"], self.accepted["commands_sha256"])
        self.assertFalse(r["compile_phase"]["runtime_closure_proven"])
        self.assertEqual(
            r["charged_wall_seconds_by_arm"]["cartograph"], r["charged_wall_seconds_by_arm"]["index_dump_assembly"]
        )

    def test_unknown_extra_compile_flag_refuses_before_selector(self):
        self.commands[0]["args"] += ["-I", "/unreviewed"]
        self.accepted["commands_sha256"] = M.GENERATIONS.content_digest(self.commands)
        self.write_inputs()
        self.assertEqual(self.execute()["failure"], "compiler-context-mismatch")
        self.assertEqual(self.calls, [])

    def test_generator_change_cannot_authorize_link_jit_or_execution(self):
        original_plan = M.COMMON.command_plan
        for extra in ["-emit-executable", "-interpret", "simctl"]:
            with self.subTest(extra=extra):
                commands = original_plan(
                    self.project, self.store, self.build, str(self.sdk), self.setup["target_triple"],
                    str(self.tools["swiftc"]), str(self.tools["clang"]), self.setup["platform_path"], False,
                )
                commands[-1]["args"].append(extra)
                self.commands = commands
                self.accepted["commands_sha256"] = M.GENERATIONS.content_digest(commands)
                self.write_inputs()
                with mock.patch.object(M.COMMON, "command_plan", return_value=commands):
                    result = self.execute(output=self.root / extra.lstrip("-"))
                self.assertEqual(result["failure"], "unreviewed-compile-phase")

    def test_missing_or_changed_selector_phase_binding_refuses(self):
        for mutation in ["missing", "commands_sha256", "runtime_closure_proven"]:
            with self.subTest(mutation=mutation):
                output = self.root / mutation

                def command(*args):
                    row = self.fake_command(*args)
                    path = output / "setup/discovery/results.json"
                    value = json.loads(path.read_text())
                    if mutation == "missing":
                        value.pop("compile_phase")
                    else:
                        value["compile_phase"][mutation] = True if mutation == "runtime_closure_proven" else "0" * 64
                    path.write_text(json.dumps(value))
                    return row

                self.assertEqual(
                    self.execute(command, output)["failure"], "invalid-compile-phase-binding"
                )

    def test_edited_source_refuses_before_selector(self):
        (self.project / "Sources/BridgeKit/include/CGCore.h").write_text("edited")
        self.assertEqual(self.execute()["failure"], "generation-inputs-changed")
        self.assertEqual(self.calls, [])

    def test_index_bytes_changed_refuses_before_selector(self):
        (self.store / "record").write_bytes(b"changed")
        self.assertEqual(self.execute()["failure"], "generation-inputs-changed")
        self.assertEqual(self.calls, [])

    def test_external_store_path_rejected_before_walk(self):
        self.accepted["store"] = str(self.root)
        self.write_inputs()
        with mock.patch.object(M.GENERATIONS, "guard", side_effect=AssertionError("must not walk")):
            self.assertEqual(self.execute()["failure"], "generation-path-boundary")
            self.assertEqual(self.calls, [])

    def test_failed_lifecycle_does_not_run_selector(self):
        self.results["status"] = "failed"
        self.write_inputs()
        self.assertEqual(self.execute()["failure"], "unaccepted-lifecycle")
        self.assertEqual(self.calls, [])

    def test_post_probe_index_mutation_rejects_without_acceptance(self):
        def command(*args):
            row = self.fake_command(*args)
            (self.store / "record").write_bytes(b"changed")
            return row

        r = self.execute(command)
        self.assertEqual(r["failure"], "generation-inputs-changed")
        self.assertFalse(r["accepted"])
        self.assertEqual(r["generation_guard_after"]["status"], "failed")

    def test_nested125_preserves_exit_and_does_not_post_guard(self):
        def command(*args):
            row = self.fake_command(*args)
            row.update(
                completed=False, passed=False, returncode=125, observed_returncode=125, failure="nested-incomplete"
            )
            return row

        r = self.execute(command)
        self.assertEqual(r["exit_code"], 125)
        self.assertEqual(r["phase"]["observed_returncode"], 125)
        self.assertEqual(r["generation_guard_after"]["status"], "unavailable")

    def test_nonzero_and_post_guard_failure_both_retained(self):
        def command(*args):
            row = self.fake_command(*args)
            (self.store / "record").write_bytes(b"changed")
            row.update(passed=False, returncode=1, observed_returncode=1)
            return row

        r = self.execute(command)
        self.assertEqual(r["failure"], "selector-failed")
        self.assertEqual(r["phase"]["observed_returncode"], 1)
        self.assertEqual(r["generation_guard_after"]["status"], "failed")

    def test_proposal_cannot_claim_accepted(self):
        def command(*args):
            row = self.fake_command(*args)
            path = self.root / "output/setup/discovery/results.json"
            value = json.loads(path.read_text())
            value["accepted"] = True
            path.write_text(json.dumps(value))
            return row

        self.assertEqual(self.execute(command)["failure"], "invalid-proposal-status")

    def test_different_sdk_build_refuses_proposal(self):
        def command(*args):
            row = self.fake_command(*args)
            path = self.root / "output/setup/discovery/results.json"
            value = json.loads(path.read_text())
            value["proposal"]["sdk_build"] = "different"
            path.write_text(json.dumps(value))
            return row

        self.assertEqual(self.execute(command)["failure"], "sdk-version-changed")

    def test_output_cannot_be_inside_lifecycle_or_toolchain(self):
        for output in [self.lifecycle / "bad-output", self.toolchain / "bad-output"]:
            with self.subTest(output=output), self.assertRaises(M.SELECTOR.DiscoveryError):
                self.execute(output=output)
            self.assertFalse(output.exists())

    def test_existing_output_not_replaced(self):
        self.execute()
        with self.assertRaises(FileExistsError):
            self.execute()

    def normalize(self):
        return subprocess.run(
            [
                sys.executable,
                str(ROOT / "Scripts/normalize-indexstore-evidence.py"),
                "--input",
                str(self.root / "output"),
                "--output",
                str(self.root / "public"),
                "--prefix",
                "WORK=" + str(self.root),
                "--prefix",
                "WORKSPACE=" + str(ROOT),
                "--prefix",
                "OPT=/opt",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_complete_mock_evidence_normalizes_without_binary_inputs(self):
        self.execute()
        row = self.normalize()
        self.assertEqual(row.returncode, 0, row.stderr)
        manifest = json.loads((self.root / "public/manifest.json").read_text())
        paths = {entry["path"] for entry in manifest["files"]}
        self.assertIn("setup/accepted-generation.json", paths)
        self.assertIn("setup/discovery/results.json", paths)
        self.assertFalse(any(name.endswith(".swiftmodule") or name.endswith("/record") for name in paths))
        for entry in manifest["files"]:
            data = (self.root / "public" / entry["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry["normalized_sha256"])
            self.assertNotIn(str(self.root).encode(), data)

    def test_incomplete_exit_and_unavailable_guard_survive_normalization(self):
        def command(*args):
            row = self.fake_command(*args)
            row.update(completed=False, passed=False, returncode=125, observed_returncode=-15, failure="signal")
            return row

        self.execute(command)
        row = self.normalize()
        self.assertEqual(row.returncode, 0, row.stderr)
        result = json.loads((self.root / "public/results.json").read_text())
        self.assertEqual(result["exit_code"], 125)
        self.assertEqual(result["phase"]["observed_returncode"], -15)
        self.assertEqual(result["generation_guard_after"]["status"], "unavailable")

    def test_private_metadata_blocks_publication_without_raw_fallback(self):
        self.results["unrelated"] = {"AWS_SESSION_TOKEN": "synthetic-secret-only"}
        self.write_inputs()
        self.execute()
        row = self.normalize()
        self.assertNotEqual(row.returncode, 0)
        self.assertFalse((self.root / "public/manifest.json").exists())

    def test_actual_prerecord_cli_failure_has_safe_durable_attempt(self):
        malformed = self.root / "malformed/results.json"
        malformed.parent.mkdir()
        malformed.write_text("{bad")
        attempt = self.root / "attempt"
        output = self.root / "discovery-output"
        row = subprocess.run(
            [
                sys.executable,
                str(ROOT / "Scripts/validate-native-sdk-discovery.py"),
                "--lifecycle-results",
                str(malformed),
                "--output",
                str(output),
                "--attempt-output",
                str(attempt),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(row.returncode, 1, row.stderr)
        self.assertFalse(output.exists())
        receipt = json.loads((attempt / "results.json").read_text())
        self.assertEqual(receipt["exit_code"], 1)
        self.assertEqual(receipt["observed_returncode"], 1)
        self.assertTrue(receipt["completed"])
        self.assertEqual(receipt["failure_category"], "invalid-json")
        self.assertGreater(receipt["total_wall_seconds"], 0)
        self.assertNotIn(str(self.root), json.dumps(receipt))
        self.assertTrue(receipt["stderr"]["sha256"])

    def test_attempt_receipt_stays_outside_rejected_sdk_output(self):
        output = self.toolchain / "not-authorized"
        attempt = self.root / "attempt"
        row = subprocess.run(
            [
                sys.executable,
                str(ROOT / "Scripts/validate-native-sdk-discovery.py"),
                "--lifecycle-results",
                str(self.lifecycle / "results.json"),
                "--output",
                str(output),
                "--attempt-output",
                str(attempt),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(row.returncode, 1, row.stderr)
        self.assertFalse(output.exists())
        receipt = json.loads((attempt / "results.json").read_text())
        self.assertEqual(receipt["failure_category"], "evidence-input-overlap")

    def test_attempt_directory_cannot_overlap_input_roots(self):
        with self.assertRaises(M.SELECTOR.DiscoveryError):
            M.supervise(self.lifecycle / "results.json", self.root / "output", self.toolchain / "attempt")
        self.assertFalse((self.toolchain / "attempt").exists())

    def publication_module(self):
        spec = importlib.util.spec_from_file_location(
            "sdk_publish", ROOT / "Scripts/normalize-sdk-discovery-evidence.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def publish(self, raw, attempt, public, prefixes):
        return self.publication_module().publish(raw, attempt, public, prefixes, self.lifecycle / "results.json")

    def synthetic_attempt(self, raw, code=0):
        attempt = self.root / "attempt"
        attempt.mkdir()
        stdout = attempt / "process.stdout"
        stderr = attempt / "process.stderr"
        stdout.write_text("")
        stderr.write_text("")
        argv = [
            sys.executable,
            str(ROOT / "Scripts/validate-native-sdk-discovery.py"),
            "--lifecycle-results",
            str(self.lifecycle / "results.json"),
            "--output",
            str(raw),
        ]
        phase = dict(
            command=argv,
            completed=code != 125,
            passed=code == 0,
            returncode=code,
            observed_returncode=code,
            failure="nested-incomplete" if code == 125 else None,
            wall_seconds=0.1,
            stdout=str(stdout),
            stderr=str(stderr),
        )
        (attempt / "process.json").write_text(json.dumps(phase))
        receipt = dict(
            schema_version=1,
            role="sdk-discovery-attempt-envelope",
            wrapper_sha256=M.digest(Path(M.__file__)),
            runner_sha256=M.SELECTOR.RUNNER_SHA256,
            argv_sha256=hashlib.sha256(json.dumps(argv, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest(),
            exit_code=code,
            observed_returncode=code,
            completed=code != 125,
            child_failure=phase["failure"],
            failure_category="child-incomplete" if code == 125 else "none" if code == 0 else "child-nonzero",
            child_wall_seconds=0.1,
            total_wall_seconds=0.2,
            source_inputs_unchanged=True,
            descendant_cleanup_verified=False,
            stdout={"status": "available", "bytes": 0, "sha256": M.digest(stdout)},
            stderr={"status": "available", "bytes": 0, "sha256": M.digest(stderr)},
            stderr_diagnostic_status="invalid-json" if code not in (0, 125) else "not-needed",
            raw_output_exists=raw.is_dir(),
            phase_receipt_sha256=M.digest(attempt / "process.json"),
            cleanup_signals=[],
            cleanup_root_unfinished=False,
        )
        (attempt / "results.json").write_text(json.dumps(receipt))
        return attempt

    def test_missing_raw_output_publishes_only_valid_attempt_envelope_and_stays_red(self):
        raw = self.root / "missing-raw"
        attempt = self.synthetic_attempt(raw, 1)
        public = self.root / "public"
        status, code = self.publish(raw, attempt, public, [])
        self.assertEqual(code, 1)
        self.assertEqual(status["discovery_bundle_status"], "missing")
        self.assertFalse(status["raw_fallback"])
        self.assertEqual({p.name for p in public.iterdir()}, {"attempt.json", "publication-status.json"})

    def test_blocked_subtree_never_appears_in_public_directory(self):
        self.results["unrelated"] = {"AWS_SESSION_TOKEN": "synthetic-secret-only"}
        self.write_inputs()
        self.execute()
        raw = self.root / "output"
        attempt = self.synthetic_attempt(raw)
        public = self.root / "public"
        status, code = self.publish(
            raw, attempt, public, ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT), "OPT=/opt"]
        )
        self.assertEqual(code, 1)
        self.assertEqual(status["discovery_bundle_status"], "blocked")
        self.assertFalse((public / "discovery").exists())
        self.assertTrue((public / "attempt.json").exists())
        self.assertNotIn("synthetic-secret", json.dumps(status))

    def test_valid_subtree_is_moved_only_with_complete_manifest(self):
        self.execute()
        raw = self.root / "output"
        attempt = self.synthetic_attempt(raw)
        public = self.root / "public"
        status, code = self.publish(
            raw, attempt, public, ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT), "OPT=/opt"]
        )
        self.assertEqual(code, 0)
        self.assertEqual(status["manifests"], ["discovery/manifest.json"])
        self.assertTrue((public / "discovery/manifest.json").is_file())

    def test_incomplete125_publication_remains_incomplete(self):
        raw = self.root / "missing-raw"
        attempt = self.synthetic_attempt(raw, 125)
        public = self.root / "public"
        status, code = self.publish(raw, attempt, public, [])
        self.assertEqual(code, 125)
        self.assertEqual(status["exit_code"], 125)

    def test_attempt_extra_fields_or_changed_console_block_receipt(self):
        raw = self.root / "missing-raw"
        attempt = self.synthetic_attempt(raw, 1)
        public = self.root / "public"
        (attempt / "process.stderr").write_text("changed")
        status, code = self.publish(raw, attempt, public, [])
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "blocked")
        self.assertFalse((public / "attempt.json").exists())

    def test_attempt_schema_hash_and_success_contradictions_refuse(self):
        raw = self.root / "missing-raw"
        attempt = self.synthetic_attempt(raw, 0)
        original = json.loads((attempt / "results.json").read_text())
        module = self.publication_module()
        mutations = [
            {"extra": "synthetic-private"},
            {"wrapper_sha256": "0" * 64},
            {"argv_sha256": "0" * 64},
            {"phase_receipt_sha256": "0" * 64},
            {"schema_version": True},
            {"source_inputs_unchanged": False},
            {"cleanup_root_unfinished": True},
            {"total_wall_seconds": float("nan")},
        ]
        for index, change in enumerate(mutations):
            with self.subTest(change=change):
                value = {**original, **change}
                (attempt / "results.json").write_text(json.dumps(value))
                public = self.root / f"public-{index}"
                status, code = module.publish(raw, attempt, public, [], self.lifecycle / "results.json")
                self.assertEqual(code, 1)
                self.assertEqual(status["attempt_status"], "blocked")
                self.assertFalse((public / "attempt.json").exists())

    def test_missing_attempt_still_retains_bounded_unavailable_status(self):
        public = self.root / "public"
        status, code = self.publish(self.root / "missing-raw", self.root / "missing-attempt", public, [])
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "missing")
        self.assertIsNone(status["exit_code"])
        self.assertEqual({p.name for p in public.iterdir()}, {"publication-status.json"})

    def test_publication_cli_ready_flag_survives_red_missing_raw(self):
        raw = self.root / "missing-raw"
        attempt = self.synthetic_attempt(raw, 1)
        public = self.root / "public"
        ready = self.root / "github-output"
        row = subprocess.run(
            [
                sys.executable,
                str(ROOT / "Scripts/normalize-sdk-discovery-evidence.py"),
                "--lifecycle-results",
                str(self.lifecycle / "results.json"),
                "--input",
                str(raw),
                "--attempt",
                str(attempt),
                "--output",
                str(public),
                "--ready-output",
                str(ready),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(row.returncode, 1, row.stderr)
        self.assertEqual(ready.read_text(), "ready=true\n")
        self.assertTrue((public / "publication-status.json").exists())
        self.assertFalse((public / "discovery").exists())

    def test_actual_malformed_cli_attempt_publishes_fixed_category(self):
        malformed = self.root / "bad/results.json"
        malformed.parent.mkdir()
        malformed.write_text("{bad")
        raw = self.root / "sdk-discovery-raw"
        attempt = self.root / "sdk-discovery-attempt"
        row = subprocess.run(
            [
                sys.executable,
                str(ROOT / "Scripts/validate-native-sdk-discovery.py"),
                "--lifecycle-results",
                str(malformed),
                "--output",
                str(raw),
                "--attempt-output",
                str(attempt),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(row.returncode, 1, row.stderr)
        public = self.root / "sdk-discovery-public"
        status, code = self.publication_module().publish(raw, attempt, public, [], malformed, self.root)
        self.assertEqual(code, 1)
        receipt = json.loads((public / "attempt.json").read_text())
        self.assertEqual(receipt["failure_category"], "invalid-json")
        self.assertEqual(receipt["observed_returncode"], 1)
        self.assertFalse((public / "discovery").exists())

    def test_publication_rejects_known_input_roots_and_aliases_before_staging(self):
        raw = self.root / "missing-raw"
        attempt = self.synthetic_attempt(raw, 1)
        alias = self.root / "sdk-alias"
        alias.symlink_to(self.sdk, target_is_directory=True)
        for parent in (self.sdk, self.toolchain, self.lifecycle, alias):
            output = parent / "PUBLIC-EVIDENCE"
            with self.subTest(parent=parent), self.assertRaises((ValueError, RuntimeError)):
                self.publish(raw, attempt, output, [])
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name + ".pending").exists())

    def test_supervisor_retains_large_and_nontext_log_outcomes(self):
        cases = [
            (b"x" * (M.SELECTOR.MAX_TEXT_BYTES + 1), b"", "invalid-json"),
            (b"", b"\xff", "unreadable-input"),
            (b"", b"x" * (M.SELECTOR.MAX_TEXT_BYTES + 1), "input-byte-limit"),
        ]
        for index, (out, err, diagnostic_status) in enumerate(cases):

            def command(argv, cwd, stem, environment, timeout):
                for kind, data in (("stdout", out), ("stderr", err)):
                    Path(str(stem) + "." + kind).write_bytes(data)
                phase = dict(
                    command=argv,
                    completed=True,
                    passed=False,
                    returncode=7,
                    observed_returncode=7,
                    failure=None,
                    wall_seconds=0.0,
                    stdout=str(stem) + ".stdout",
                    stderr=str(stem) + ".stderr",
                )
                Path(str(stem) + ".json").write_text(json.dumps(phase))
                return phase

            with self.subTest(index=index):
                attempt = self.root / f"attempt-{index}"
                receipt = M.supervise(self.lifecycle / "results.json", self.root / "raw", attempt, command=command)
                self.assertEqual(receipt["exit_code"], 7)
                self.assertEqual(receipt["observed_returncode"], 7)
                self.assertEqual(receipt["child_wall_seconds"], 0.0)
                for kind, data in (("stdout", out), ("stderr", err)):
                    self.assertEqual(receipt[kind]["bytes"], len(data))
                    self.assertEqual(receipt[kind]["sha256"], hashlib.sha256(data).hexdigest())
                self.assertTrue((attempt / "results.json").is_file())
                self.assertEqual(receipt["stderr_diagnostic_status"], diagnostic_status)
                public = self.root / f"public-{index}"
                status, code = self.publish(self.root / "raw", attempt, public, [])
                self.assertEqual(code, 1)
                self.assertEqual(status["attempt_status"], "verified")
                self.assertEqual(json.loads((public / "attempt.json").read_text())["exit_code"], 7)

    def test_malformed_boundary_requires_explicit_fixed_scratch_layout(self):
        (self.lifecycle / "results.json").write_text("{bad")
        for output in (self.root / "arbitrary", self.sdk / "PUBLIC", self.root / "sdk-discovery-public"):
            with self.subTest(output=output), self.assertRaises((ValueError, RuntimeError)):
                self.publication_module().publish(
                    self.root / "raw", self.root / "attempt", output, [], self.lifecycle / "results.json"
                )
            self.assertFalse(output.exists())
            self.assertFalse(output.with_name(output.name + ".pending").exists())

    def test_publication_explicit_lifecycle_must_match_attempt_argv(self):
        raw = self.root / "raw"
        attempt = self.synthetic_attempt(raw, 1)
        other = self.root / "other/results.json"
        other.parent.mkdir()
        other.write_text(json.dumps(self.results))
        with self.assertRaises(ValueError):
            self.publication_module().publish(raw, attempt, self.root / "public", [], other)
        self.assertFalse((self.root / "public").exists())
        self.assertFalse((self.root / "public.pending").exists())

    def test_log_hash_failure_preserves_phase_and_explicit_unavailable_status(self):
        def command(argv, cwd, stem, environment, timeout):
            Path(str(stem) + ".stdout").write_bytes(b"12345")
            Path(str(stem) + ".stderr").write_bytes(b"12345")
            row = dict(
                command=argv,
                completed=True,
                passed=False,
                returncode=9,
                observed_returncode=9,
                failure=None,
                wall_seconds=0.0,
                stdout=str(stem) + ".stdout",
                stderr=str(stem) + ".stderr",
            )
            Path(str(stem) + ".json").write_text(json.dumps(row))
            return row

        with mock.patch.object(M, "LOG_IDENTITY_LIMIT", 4):
            receipt = M.supervise(
                self.lifecycle / "results.json", self.root / "raw", self.root / "attempt", command=command
            )
        self.assertEqual(receipt["observed_returncode"], 9)
        self.assertEqual(receipt["child_wall_seconds"], 0.0)
        self.assertEqual(receipt["stdout"], {"status": "unavailable", "reason": "input-byte-limit"})
        self.assertEqual(receipt["stderr_diagnostic_status"], "hash-unavailable")
        publisher = self.publication_module()
        with mock.patch.object(publisher.DISCOVERY, "LOG_IDENTITY_LIMIT", 4):
            status, code = publisher.publish(
                self.root / "raw", self.root / "attempt", self.root / "public", [], self.lifecycle / "results.json"
            )
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "verified")
        self.assertEqual(status["publication_failure"], "log-identities-unavailable")
        self.assertEqual(json.loads((self.root / "public/attempt.json").read_text())["observed_returncode"], 9)
        path = self.root / "unstable"
        path.write_bytes(b"raw")
        with mock.patch.object(
            M.SELECTOR, "file_identity", side_effect=M.SELECTOR.DiscoveryError("input-changed-during-read")
        ):
            self.assertEqual(M.log_identity(path), {"status": "unavailable", "reason": "input-changed-during-read"})

    def test_nonstring_diagnostic_reason_remains_bounded(self):
        path = self.root / "stderr"
        path.write_text(json.dumps({"status": "refused-before-record", "reason": {"private": "synthetic"}}))
        category, status = M.diagnostic_category(path, M.log_identity(path), "child-nonzero")
        self.assertEqual((category, status), ("unrecognized-prerecord-failure", "parsed"))

    def test_transient_capture_hash_failure_keeps_original_exit_and_cost(self):
        raw = self.root / "raw"
        attempt = self.synthetic_attempt(raw, 9)
        path = attempt / "results.json"
        receipt = json.loads(path.read_text())
        receipt["stdout"] = {"status": "unavailable", "reason": "input-changed-during-read"}
        path.write_text(json.dumps(receipt))
        public = self.root / "public"
        status, code = self.publish(raw, attempt, public, [])
        self.assertEqual(code, 1)
        self.assertEqual(status["attempt_status"], "verified")
        self.assertEqual(status["publication_failure"], "log-identities-unavailable")
        published = json.loads((public / "attempt.json").read_text())
        self.assertEqual(published["exit_code"], 9)
        self.assertEqual(published["child_wall_seconds"], 0.1)
        self.assertEqual(published["stdout"], receipt["stdout"])
        self.assertEqual(published["publication_log_identities"]["stdout"], M.log_identity(attempt / "process.stdout"))
        self.assertEqual(published["publication_log_identities"]["stdout"]["status"], "available")

    def verify_synthetic_archive(
        self, extra_kind="sdk-input-discovery", attempt_name="attempt.json", role="sdk-discovery-attempt-envelope"
    ):
        import zipfile

        module = M.load_module("pilot_archive", ROOT / "Scripts/verify-indexstore-pilot-evidence.py")
        directory = self.root / "archive"
        directory.mkdir()
        archive = directory / "test-normalized.zip"
        files = {
            "discovery/manifest.json": json.dumps({"files": []}).encode(),
            attempt_name: json.dumps({"schema_version": 1, "role": role}).encode(),
            "publication-status.json": json.dumps(
                {
                    "schema_version": 1,
                    "role": "sdk-discovery-publication-envelope",
                    "raw_fallback": False,
                    "complete_run_evidence": False,
                }
            ).encode(),
        }
        with zipfile.ZipFile(archive, "w") as z:
            for name, data in files.items():
                z.writestr(name, data)
        bundle = {
            "archive": archive.name,
            "artifact_kind": extra_kind,
            "sha256": M.digest(archive),
            "compressed_bytes": archive.stat().st_size,
            "uncompressed_bytes": sum(map(len, files.values())),
            "archive_entries": 3,
            "manifests": ["discovery/manifest.json"],
            "verified_normalized_files": 0,
            "auxiliary_files": [
                {"path": name, "bytes": len(files[name]), "sha256": hashlib.sha256(files[name]).hexdigest()}
                for name in [attempt_name, "publication-status.json"]
            ],
        }
        (directory / "bundles.json").write_text(
            json.dumps(
                {
                    "bundles": [bundle],
                    "total_compressed_bytes": bundle["compressed_bytes"],
                    "total_uncompressed_bytes": bundle["uncompressed_bytes"],
                }
            )
        )
        return module.verify(directory)

    def cpp_alias_fixture(self, extra=""):
        self.execute()
        raw = self.root / "output"
        stem = raw / "setup/discovery/probes/clang-cxx.stderr"
        stem.parent.mkdir(parents=True, exist_ok=True)
        alias = self.tools["clang"].parent / "../include/c++/v1"
        stem.write_text(f'ignoring nonexistent directory "{alias}"' + extra + "\n")
        attempt = self.synthetic_attempt(raw, code=1)
        return raw, attempt, alias

    def cpp_parser_result_fixture(self):
        raw, attempt, path, spellings = self.complete_cpp_fixture()
        headers = self.sdk / "usr/include/c++/v1"
        headers.mkdir(parents=True, exist_ok=True)
        result_path = raw / "setup/discovery/results.json"
        result = json.loads(result_path.read_text())
        result["compiler_path_aliases"] = dict(
            aliases={str(spellings[0]): str(spellings[1])}, directory_identity_sha256="a" * 64
        )
        coverage = M.SELECTOR.covered_path(str(headers), {"SDK": self.sdk})
        result["proposal"]["clang_search_paths"] = [
            dict(
                context_id="cxx",
                language="c++",
                context_options=["-std=c++17"],
                effective=[dict(path=str(headers), framework=False, coverage=coverage)],
                ignored=[],
            )
        ]
        result_path.write_text(json.dumps(result))
        return raw, attempt, result_path, result, coverage

    def test_complete_parser_result_relative_cpp_path_is_lossless_and_publishable(self):
        raw, attempt, result_path, result, coverage = self.cpp_parser_result_fixture()
        original = result_path.read_bytes()
        status, code = self.publish(
            raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
        )
        self.assertEqual(code, 1)
        self.assertEqual(status["discovery_bundle_status"], "normalized")
        self.assertNotIn("relative_path", coverage)
        self.assertEqual(coverage["relative_path_components"], ["usr", "include", "c++", "v1"])
        self.assertEqual(str(self.sdk.joinpath(*coverage["relative_path_components"])), coverage["canonical_path"])
        self.assertEqual(result_path.read_bytes(), original)
        public = json.loads((self.root / "public/discovery/setup/discovery/results.json").read_text())
        saved = public["proposal"]["clang_search_paths"][0]["effective"][0]["coverage"]
        self.assertEqual(saved["relative_path_components"], coverage["relative_path_components"])
        self.assertEqual(saved["canonical_path"], "$SDK_CXX_HEADERS")

    def test_complete_parser_result_retains_private_path_and_credential_blocks(self):
        for extra in [
            dict(note="/unmapped-private/person"),
            dict(GITHUB_TOKEN="synthetic-only"),
            dict(AWS_SECRET_ACCESS_KEY="synthetic-only"),
        ]:
            with self.subTest(extra=extra):
                raw, attempt, result_path, result, coverage = self.cpp_parser_result_fixture()
                coverage.update(extra)
                result_path.write_text(json.dumps(result))
                status, code = self.publish(
                    raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
                )
                self.assertEqual(code, 1)
                self.assertEqual(status["discovery_bundle_status"], "blocked")
                self.assertTrue((self.root / "public/attempt.json").exists())
                self.assertFalse((self.root / "public/discovery").exists())
                self.tearDown_fixture_for_subtest()

    def test_verified_clang_cpp_parent_alias_normalizes_without_scanner_change(self):
        raw, attempt, alias = self.cpp_alias_fixture()
        public = self.root / "public"
        result, code = self.publish(raw, attempt, public, ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)])
        self.assertEqual(code, 1)
        self.assertEqual(result["discovery_bundle_status"], "normalized")
        self.assertEqual(result["normalization_aliases"]["status"], "verified")
        text = (public / "discovery/setup/discovery/probes/clang-cxx.stderr").read_text()
        self.assertEqual(text, 'ignoring nonexistent directory "$CLANG_CXX_HEADERS"\n')
        manifest = json.loads((public / "discovery/manifest.json").read_text())
        row = next(r for r in manifest["files"] if r["path"].endswith("clang-cxx.stderr"))
        self.assertEqual(row["original_raw_sha256"], M.digest(raw / row["path"]))
        self.assertFalse(result["complete_run_evidence"])

    def complete_cpp_fixture(self):
        raw, attempt, alias = self.cpp_alias_fixture()
        sdk_headers = self.sdk / "usr/include/c++/v1"
        spellings = [alias, alias.resolve(), sdk_headers, sdk_headers.resolve()]
        # 원격 원문을 추측하지 않고 공식 Darwin 드라이버의 두 후보 계열을 함께 검사한다.
        lines = [f'ignoring nonexistent directory "{value}"' for value in spellings]
        lines += [' "clang" ' + " ".join(f'-internal-isystem "{value}"' for value in spellings)]
        lines += ['#include "..." search starts here:', "#include <...> search starts here:"]
        lines += [" " + str(value) for value in spellings]
        lines += ["End of search list."]
        path = raw / "setup/discovery/probes/clang-cxx.stderr"
        path.write_text("\n".join(lines) + "\n")
        return raw, attempt, path, spellings

    def test_complete_cpp_alias_families_preserve_order_and_raw_hash(self):
        raw, attempt, path, spellings = self.complete_cpp_fixture()
        before = path.read_text()
        result, code = self.publish(
            raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
        )
        self.assertEqual(code, 1)
        self.assertEqual(result["discovery_bundle_status"], "normalized")
        expected = before
        for spelling, token in zip(spellings, ["$CLANG_CXX_HEADERS"] * 2 + ["$SDK_CXX_HEADERS"] * 2):
            expected = expected.replace(str(spelling), token)
        published = self.root / "public/discovery/setup/discovery/probes/clang-cxx.stderr"
        self.assertEqual(published.read_text(), expected)
        self.assertEqual(path.read_text(), before)
        manifest = json.loads((self.root / "public/discovery/manifest.json").read_text())
        row = next(r for r in manifest["files"] if r["path"].endswith("clang-cxx.stderr"))
        self.assertEqual(row["original_raw_sha256"], M.digest(path))
        self.assertEqual(result["normalization_aliases"]["sdk_request_binding"], "exact-selected-sdk")

    def test_complete_cpp_alias_family_rejects_all_adjacent_blockers(self):
        for suffix in [
            ' note "/unmapped-private/person"',
            ' {"GITHUB_TOKEN":"synthetic-only"}',
            ' {"AWS_SECRET_ACCESS_KEY":"synthetic-only"}',
            ' {"\\u0047ITHUB_TOKEN":"synthetic-only"}',
            "/../../private-owner",
            "-unreviewed",
        ]:
            with self.subTest(suffix=suffix):
                raw, attempt, path, spellings = self.complete_cpp_fixture()
                path.write_text(path.read_text() + f' "{spellings[-1]}{suffix}"\n')
                result, code = self.publish(
                    raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
                )
                self.assertEqual(code, 1)
                self.assertEqual(result["discovery_bundle_status"], "blocked")
                self.assertTrue((self.root / "public/attempt.json").exists())
                self.assertFalse((self.root / "public/discovery").exists())
                self.tearDown_fixture_for_subtest()

    def test_sdk_cpp_alias_requires_exact_request_binding(self):
        raw, attempt, path, spellings = self.complete_cpp_fixture()
        request_path = raw / "setup/selector-request.json"
        request = json.loads(request_path.read_text())
        request["sdk"] = str(self.root / "another.sdk")
        request_path.write_text(json.dumps(request))
        result, code = self.publish(
            raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
        )
        self.assertEqual(code, 1)
        self.assertEqual(result["discovery_bundle_status"], "blocked")

    def test_sdk_cpp_alias_normalizes_selected_sdk_symlink_spellings(self):
        physical = self.sdk.with_name("iPhoneSimulator26.5.sdk")
        self.sdk.rename(physical)
        self.sdk.symlink_to(physical, target_is_directory=True)
        self.test_complete_cpp_alias_families_preserve_order_and_raw_hash()

    def test_sdk_cpp_alias_refuses_existing_include_symlink_escape(self):
        raw, attempt, path, spellings = self.complete_cpp_fixture()
        outside = self.root / "external-sdk-headers"
        outside.mkdir()
        (self.sdk / "usr").mkdir()
        (self.sdk / "usr/include").symlink_to(outside, target_is_directory=True)
        result, code = self.publish(
            raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
        )
        self.assertEqual(code, 1)
        self.assertEqual(result["discovery_bundle_status"], "blocked")

    def test_sdk_cpp_alias_changed_during_staging_never_promotes_candidate(self):
        raw, attempt, path, spellings = self.complete_cpp_fixture()
        module = self.publication_module()
        package = module.BUNDLES.EVIDENCE.package

        def mutate(args):
            result = package(args)
            self.sdk.rename(self.sdk.with_name("old.sdk"))
            self.sdk.mkdir()
            return result

        with mock.patch.object(module.BUNDLES.EVIDENCE, "package", side_effect=mutate):
            result, code = module.publish(
                raw,
                attempt,
                self.root / "public",
                ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)],
                self.lifecycle / "results.json",
            )
        self.assertEqual(code, 1)
        self.assertEqual(result["discovery_bundle_status"], "blocked")
        self.assertTrue((self.root / "public/attempt.json").exists())
        self.assertFalse((self.root / "public/discovery").exists())

    def test_cpp_alias_does_not_allow_neighbor_private_path_or_credential(self):
        for name, extra in [
            ("path", ' note "/unmapped-private/person"'),
            ("credential", ' {"GITHUB_TOKEN":"synthetic-token-only"}'),
        ]:
            with self.subTest(name=name):
                raw, attempt, alias = self.cpp_alias_fixture(extra)
                result, code = self.publish(
                    raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
                )
                self.assertEqual(code, 1)
                self.assertEqual(result["discovery_bundle_status"], "blocked")
                self.assertTrue((self.root / "public/attempt.json").exists())
                self.assertFalse((self.root / "public/discovery").exists())
                self.tearDown_fixture_for_subtest()

    def tearDown_fixture_for_subtest(self):
        import shutil

        for name in ["output", "attempt", "public", "public.pending"]:
            shutil.rmtree(self.root / name, ignore_errors=True)

    def test_cpp_alias_cannot_hide_parent_escape_suffix(self):
        raw, attempt, alias = self.cpp_alias_fixture()
        path = raw / "setup/discovery/probes/clang-cxx.stderr"
        path.write_text(f'ignoring nonexistent directory "{alias}/../../private-owner"\n')
        result, code = self.publish(
            raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
        )
        self.assertEqual(code, 1)
        self.assertEqual(result["discovery_bundle_status"], "blocked")

    def test_cpp_alias_refuses_changed_compiler_or_lifecycle_binding(self):
        for changed in ["compiler", "lifecycle"]:
            with self.subTest(changed=changed):
                raw, attempt, alias = self.cpp_alias_fixture()
                path = self.tools["clang"] if changed == "compiler" else self.lifecycle / "results.json"
                original = path.read_bytes()
                path.write_bytes(original + (b"changed" if changed == "compiler" else b" "))
                result, code = self.publish(
                    raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
                )
                self.assertEqual(code, 1)
                self.assertEqual(result["discovery_bundle_status"], "blocked")
                self.assertTrue((self.root / "public/attempt.json").exists())
                path.write_bytes(original)
                self.tearDown_fixture_for_subtest()

    def test_cpp_alias_changed_during_staging_never_promotes_candidate(self):
        raw, attempt, alias = self.cpp_alias_fixture()
        module = self.publication_module()
        package = module.BUNDLES.EVIDENCE.package

        def mutate(args):
            result = package(args)
            self.tools["clang"].write_bytes(b"changed after normalization")
            return result

        with mock.patch.object(module.BUNDLES.EVIDENCE, "package", side_effect=mutate):
            result, code = module.publish(
                raw,
                attempt,
                self.root / "public",
                ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)],
                self.lifecycle / "results.json",
            )
        self.assertEqual(code, 1)
        self.assertEqual(result["discovery_bundle_status"], "blocked")
        self.assertFalse((self.root / "public/discovery").exists())
        self.assertTrue((self.root / "public/attempt.json").exists())

    def test_cpp_alias_refuses_existing_include_symlink_escape(self):
        raw, attempt, alias = self.cpp_alias_fixture()
        outside = self.root / "external-headers"
        outside.mkdir()
        include = self.toolchain / "usr/include"
        include.symlink_to(outside, target_is_directory=True)
        result, code = self.publish(
            raw, attempt, self.root / "public", ["WORK=" + str(self.root), "WORKSPACE=" + str(ROOT)]
        )
        self.assertEqual(code, 1)
        self.assertEqual(result["discovery_bundle_status"], "blocked")

    def test_archive_retains_exact_sdk_attempt_and_publication_envelopes(self):
        result = self.verify_synthetic_archive()
        self.assertEqual(result["archives"], 1)
        self.assertEqual(result["auxiliary_files"], 2)

    def test_archive_does_not_broaden_other_artifact_auxiliary_paths(self):
        with self.assertRaises(ValueError):
            self.verify_synthetic_archive(extra_kind="other")

    def test_archive_rejects_unexpected_auxiliary_name(self):
        with self.assertRaises(ValueError):
            self.verify_synthetic_archive(attempt_name="private-console.json")

    def test_archive_rejects_wrong_envelope_role(self):
        with self.assertRaises(ValueError):
            self.verify_synthetic_archive(role="unrecognized")

    def test_workflow_upload_requires_normalized_success_and_keeps_budget(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("steps.sdk_normalize.outputs.ready == 'true'", workflow)
        self.assertIn("path: ${{ runner.temp }}/sdk-discovery-public/", workflow)
        self.assertNotIn("path: ${{ runner.temp }}/sdk-discovery-raw/", workflow)
        self.assertIn("timeout-minutes: 35", workflow)
        self.assertLess(
            workflow.index("name: Validate native measurement helpers"),
            workflow.index("name: Discover native SDK input roots"),
        )
        self.assertIn("steps.mixed.outcome == 'success'", workflow)

    def test_source_and_input_byte_hashes_are_retained(self):
        r = self.execute()
        self.assertEqual(r["input_files"]["results.json"]["sha256"], M.digest(self.lifecycle / "results.json"))
        self.assertTrue(r["helper_hashes"])
        self.assertIn("setup/accepted-generation.json", r["retained_inputs"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
