#!/usr/bin/env python3
"""Swift 실행을 주장하지 않고 단계 파서·출력 동등성·유한 캡처를 검증한다."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import sys
import tempfile
import unittest
from unittest import mock


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


D = load("phase_diagnostic", "diagnose-query-phases.py")
NORMALIZE = load("phase_normalizer", "normalize-indexstore-evidence.py")


def line(value=b"0.010000000"):
    return D.PREFIX + b" ".join(name.encode() + b"=" + value for name in D.PHASES) + b"\n"


class PhaseContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def test_exact_single_finite_record_only_is_removed(self):
        clean = b"warning\r\nError: unchanged\n\x80"
        raw = b"warning\r\n" + line() + b"Error: unchanged\n\x80"
        self.assertEqual(D.split_stderr(raw, True), (clean, dict.fromkeys(D.PHASES, 0.01)))
        self.assertEqual(D.split_stderr(clean, False), (clean, None))
        self.assertEqual(D.split_stderr(line(b"not_run"), True)[1], dict.fromkeys(D.PHASES))
        for bad in (b"", line() * 2, line().rstrip(), line(b"nan"), line(b"-0.100000000"),
                    line(b"9" * 400 + b".000000000"), line().replace(b"answer=", b"unknown=")):
            with self.subTest(bad=bad[:40]), self.assertRaises(ValueError):
                D.split_stderr(bad, True)
        with self.assertRaises(ValueError):
            D.split_stderr(line(), False)

    def test_real_nonzero_process_keeps_exit_and_restores_environment_and_limits(self):
        code = ('import os,sys; print("answer"); sys.stderr.write("warning\\n"); sys.stderr.flush(); '
                f'sys.stderr.buffer.write({line()!r} if os.environ.get({D.FLAG!r})=="1" else b""); sys.exit(64)')
        limits = resource.getrlimit(resource.RLIMIT_FSIZE)
        with mock.patch.dict(os.environ, {D.FLAG: "original"}):
            off, left = D.capture([sys.executable, "-c", code], self.root, self.root / "off", False)
            on, right = D.capture([sys.executable, "-c", code], self.root, self.root / "on", True)
            self.assertEqual(os.environ[D.FLAG], "original")
        self.assertEqual(left, (64, b"answer\n", b"warning\n"))
        self.assertEqual(left, right)
        self.assertEqual(on["measurement"]["returncode"], 64)
        self.assertIsNone(off["phases"])
        self.assertEqual(resource.getrlimit(resource.RLIMIT_FSIZE), limits)

    def test_timeout_and_output_cap_refuse_with_original_measurements(self):
        with mock.patch.object(D, "COMMAND_SECONDS", 0.1), self.assertRaisesRegex(ValueError, "timed out"):
            D.capture([sys.executable, "-c", "import time; time.sleep(10)"], self.root, self.root / "timeout", False)
        self.assertTrue(D.PROJECT.read_json(self.root / "timeout.json")["timed_out"])
        with self.assertRaisesRegex(ValueError, "output cap"):
            D.capture([sys.executable, "-c", "import os; os.write(1,b'x'*(2*1024*1024))"],
                      self.root, self.root / "oversized", False)
        self.assertLessEqual((self.root / "oversized.stdout").stat().st_size, D.MAX_BYTES)

    def test_shared_alarm_reaps_actual_child_and_records_interruption(self):
        pidfile = self.root / "child.pid"
        code = (f'import os,signal,time,pathlib; pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid())); '
                'os.kill(os.getppid(),signal.SIGALRM); time.sleep(10)')
        prior = {sig: signal.getsignal(sig) for sig in (signal.SIGALRM, signal.SIGTERM)}
        try:
            signal.signal(signal.SIGALRM, D.PREP.terminate_driver)
            with self.assertRaises(KeyboardInterrupt):
                D.capture([sys.executable, "-c", code], self.root, self.root / "interrupted", False)
        finally:
            for sig, handler in prior.items():
                signal.signal(sig, handler)
        self.assertTrue(D.PROJECT.read_json(self.root / "interrupted.json")["interrupted"])
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)

    def fixture(self):
        oracle, _ = D.PROJECT.frozen_inputs()
        ids = {node["id"]: node["source_id"] for node in oracle["nodes"]}
        self.graph = {"bindings": {value: value for value in ids.values()},
                      "symbols": {value: value for value in ids.values()},
                      "edges": [[ids[edge["caller"]], ids[edge["callee"]]] for edge in oracle["edges"]]}
        self.config = {"oracle": oracle, "requests": D.PROJECT.query_requests(oracle), "hashes": {},
                       "cartograph": "unused", "project": str(self.root / "project"),
                       "store": str(self.root / "index"), "cg_config": str(self.root / "config.yml")}
        self.path = self.root / "raw" / "results.json"
        self.out = self.root / "raw" / "runs" / "query-phases"
        package, binary_dir = self.root / "package", self.root / "release"
        package.mkdir(exist_ok=True)
        binary_dir.mkdir(exist_ok=True)
        (package / "Package.swift").write_text("// controlled fixture\n")
        (package / "Package.resolved").write_text("{}\n")
        (binary_dir / "cartograph").write_bytes(b"fixture binary; never executed")
        args = argparse.Namespace(cartograph_package=package, setup_timeout=1, jobs=1)
        # 실제 생산자의 반환 구조를 쓴다. 컴파일러·git·실행 파일 호출만 모의한다.
        with mock.patch.object(D.BASE, "capture", side_effect=[
                ("fixture", {}), ("", {}), (str(binary_dir), {}), ("fixture version", {})]), \
                mock.patch.object(D.BASE, "run", return_value={}):
            cartograph = D.BASE.prepare_cartograph(args, self.root / "swiftc", self.root)
        D.BASE.save(self.root / "setup.json", {"cartograph": cartograph, "toolchain": {"version": "fixture"}})
        D.BASE.save(self.path, {"reused_tools": {"setup_results": str(self.root / "setup.json")}})
        return self.config, self.graph

    def fake_capture(self, command, project, stem, enabled):
        names = D.PROJECT.read_json(Path(command[command.index("--batch") + 1]))
        request = max(self.config["requests"], key=lambda row: row["max_depth"])
        seed = self.graph["bindings"][request["seed"]]
        depths = D.PROJECT.reverse_depths(self.graph["edges"], request["seed"], request["max_depth"])
        results = []
        for name in names:
            result = {"requested": name, "level": "symbol", "limitations": []}
            if name == seed:
                result.update(status="found", result={"subject": {"usr": name},
                    "truncated": {key: False for key in ("usedBy", "dependsOn", "members")},
                    "usedBy": [{"usr": self.graph["bindings"][node], "depth": depth, "edges": ["call"]}
                               for node, depth in depths.items()]})
            elif name == "fullMessage":
                result.update(status="ambiguous", candidates=[{"usr": self.graph["bindings"][node["source_id"]]}
                    for node in self.config["oracle"]["nodes"] if node["name"] == name])
            else:
                result.update(status="notFound")
            results.append(result)
        stdout = json.dumps({"format": "symbol-query-batch", "version": 1, "results": results}, sort_keys=True).encode()
        phases = dict.fromkeys(D.PHASES, 0.01)
        if seed not in names:
            phases["found_facts"] = None
        stderr = (D.PREFIX + b" ".join(key.encode() + b"=" + (b"not_run" if value is None else b"0.010000000")
                  for key, value in phases.items()) + b"\n") if enabled else b""
        stem.parent.mkdir(parents=True, exist_ok=True)
        Path(str(stem) + ".stdout").write_bytes(stdout)
        Path(str(stem) + ".stderr").write_bytes(stderr)
        code = 64 if any(row["status"] == "notFound" for row in results) else 0
        measured = {"command": command, "returncode": code, "timed_out": False,
                    "wall_seconds": 1.1 if enabled else 1.0, "stdout": str(stem) + ".stdout",
                    "stderr": str(stem) + ".stderr"}
        return {"measurement": measured, "enabled": enabled, "phases": phases if enabled else None}, (code, stdout, b"")

    def run_fixture(self, capture=None, deadline=None):
        admitted = self.fixture()
        report = {"status": "running"}
        with mock.patch.object(D.PREP, "admit", return_value=admitted), \
                mock.patch.object(D.PREP, "verify_bytes", return_value={"seconds": 0, "unchanged": True}) as checks, \
                mock.patch.object(D, "capture", side_effect=capture or self.fake_capture):
            D.run(self.path, self.out, report, deadline)
        return report, checks

    def test_fixed_fourteen_run_scope_and_balanced_schedule(self):
        report, checks = self.run_fixture()
        self.assertEqual(report["status"], "passed")
        self.assertEqual(len(report["runs"]), 14)
        self.assertEqual(checks.call_count, 15)
        self.assertEqual([row["enabled"] for row in report["runs"] if row["case"] == "found"],
                         [False, True, True, False] * 2)
        self.assertAlmostEqual(report["enabled_minus_disabled_median_seconds"], 0.1)
        for wall in (float("inf"), float("nan"), -1, True, 0.001):
            def invalid_wall(*args):
                measured, raw = self.fake_capture(*args)
                measured["measurement"]["wall_seconds"] = wall
                return measured, raw
            with self.subTest(wall=wall), self.assertRaisesRegex(ValueError, "wall"):
                self.run_fixture(invalid_wall)
        with self.assertRaisesRegex(ValueError, "deadline"):
            self.run_fixture(deadline=0)

    def test_actual_producer_setup_is_required_before_query_capture(self):
        report, _ = self.run_fixture()
        produced = D.PROJECT.read_json(self.root / "setup.json")["cartograph"]
        self.assertNotIn("mode", produced)
        self.assertNotIn("source", produced)
        self.assertEqual(report["source"], produced["setup"]["source"])
        self.assertEqual(report["source"]["revision"], "fixture")
        for missing_setup in (False, True):
            admitted = self.fixture()
            setup = D.PROJECT.read_json(self.root / "setup.json")
            # 바깥에 옛 모의 필드를 넣어도 실제 setup 계약을 대신할 수 없다.
            setup["cartograph"].update(mode="fresh-release-package-build", source={"revision": "spoof"})
            if missing_setup:
                del setup["cartograph"]["setup"]
            else:
                setup["cartograph"]["setup"]["mode"] = "supplied-binary"
            D.BASE.save(self.root / "setup.json", setup)
            with self.subTest(missing_setup=missing_setup), \
                    mock.patch.object(D.PREP, "admit", return_value=admitted), \
                    mock.patch.object(D, "capture") as capture, self.assertRaises((ValueError, KeyError)):
                D.run(self.path, self.out, {})
            capture.assert_not_called()

    def test_stdout_exit_stderr_mutations_prevent_timing_interpretation(self):
        for field in (0, 1, 2):
            def changed(*args):
                measured, raw = self.fake_capture(*args)
                if args[-1]:
                    raw = list(raw)
                    raw[field] = 1 if field == 0 else raw[field] + b"changed"
                return measured, tuple(raw)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.run_fixture(changed)
            partial = D.PROJECT.read_json(self.out / "results.json")
            self.assertNotIn("enabled_minus_disabled_median_seconds", partial)
            self.assertTrue(all("instrumented_phase_sum_seconds" not in row for row in partial["runs"]))
            shutil.rmtree(self.root / "raw")

    def test_oracle_and_actual_ambiguity_candidates_are_required(self):
        self.fixture()
        request = max(self.config["requests"], key=lambda row: row["max_depth"])
        for name in (self.graph["bindings"][request["seed"]], "fullMessage"):
            path = self.out / "requests.json"
            D.BASE.save(path, [name])
            _, raw = self.fake_capture(["query", "--batch", str(path)], self.root, self.out / "mutation", False)
            document = json.loads(raw[1]); result = document["results"][0]
            if result["status"] == "found":
                result["result"]["usedBy"].pop()
            else:
                result["candidates"].pop()
            with self.assertRaises(ValueError):
                D.check_answer((0, json.dumps(document).encode(), b""), [name], [result["status"]],
                               self.config, self.graph, request)

    def test_existing_normalization_preserves_correct_samples_and_rejects_sensitive_content(self):
        report, _ = self.run_fixture()
        D.BASE.save(self.out / "results.json", report)
        args = argparse.Namespace(input=self.root / "raw", output=self.root / "public", prefix=[f"TEMP={self.root}"])
        manifest = NORMALIZE.package(args)
        paths = {row["path"] for row in manifest["files"]}
        self.assertIn("runs/query-phases/results.json", paths)
        self.assertEqual((args.output / "runs/query-phases/found-6.stderr").read_bytes(), line())
        self.assertEqual((args.output / "runs/query-phases/found-7.stderr").read_bytes(), b"")
        (self.out / "unsafe.stderr").write_text("Bearer abcdefghijklmnopqrstuvwxyz\n")
        args.output = self.root / "blocked"
        with self.assertRaises(NORMALIZE.PublicationBlocked):
            NORMALIZE.package(args)
        self.assertFalse(args.output.exists())

    def run_paired_fixture(self, capture=None):
        admitted = self.fixture()
        baseline = {"cartograph": {"binary": "baseline",
                    "binary_sha256": "b" * 64, "setup": {"source": {"revision": "a" * 40}}}}
        report = {"status": "running"}
        setup = D.PROJECT.read_json(self.root / "setup.json")
        self.config["index_fingerprint"] = {"fixture": True}
        setup["cartograph"]["binary_sha256"] = "c" * 64
        D.BASE.save(self.root / "setup.json", setup)
        def measured(*args):
            row, raw = (capture or self.fake_capture)(*args)
            row["measurement"]["wait4_maxrss_bytes"] = 2048 if args[0][0] == "baseline" else 1024
            return row, raw
        with mock.patch.object(D.PREP, "admit", return_value=admitted), \
                mock.patch.object(D.PREP, "verify_bytes", return_value={"unchanged": True}), \
                mock.patch.object(D, "admit_baseline", return_value=baseline), \
                mock.patch.object(D, "capture", side_effect=measured):
            D.run(self.path, self.out, report, baseline_path=self.root / "baseline.json", baseline_revision="a" * 40)
        return report

    def test_optional_pairs_keep_all_cases_and_balanced_found_order(self):
        report = self.run_paired_fixture()
        self.assertEqual(len(report["runs"]), 28)
        self.assertTrue(report["output_parity_verified"])
        found = [row for row in report["runs"] if row["case"] == "found"]
        self.assertEqual([row["arm"] for row in found],
                         ["baseline", "candidate", "candidate", "baseline"] * 4)
        summary = report["paired_summary"]
        self.assertFalse(summary["final_evidence"])
        self.assertEqual(len(summary["cases"]), 8)
        for row in summary["cases"]:
            self.assertEqual(row["pairs"], 4 if row["case"] == "found" else 1)
            self.assertEqual(row["median_paired_baseline_over_candidate_wall"], 1)
            self.assertEqual(row["baseline"]["wait4_maxrss_bytes"], 2048)
            self.assertEqual(row["candidate"]["wait4_maxrss_bytes"], 1024)
            self.assertEqual("phases_seconds" in row["baseline"], row["enabled"])

    def test_optional_summary_rejects_mismatched_slots_and_invalid_rss(self):
        report = self.run_paired_fixture()
        report["runs"][0]["pair"] = 100
        with self.assertRaisesRegex(ValueError, "pairs"):
            D.paired_summary(report)
        report["runs"][0]["pair"] = 0
        for value in (0, -1, float("inf"), float("nan"), True):
            report["runs"][0]["measurement"]["wait4_maxrss_bytes"] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "RSS"):
                D.paired_summary(report)

    def test_optional_summary_uses_paired_ratios_not_ratio_of_medians(self):
        report = self.run_paired_fixture()
        for arm, values in (("baseline", [1, 100, 100, 100]), ("candidate", [1, 1, 100, 100])):
            records = [row for row in report["runs"] if row["case"] == "found"
                       and not row["enabled"] and row["arm"] == arm]
            for row, value in zip(records, values):
                row["measurement"]["wall_seconds"] = value
        summary = next(row for row in D.paired_summary(report)["cases"]
                       if row["case"] == "found" and not row["enabled"])
        self.assertEqual(summary["baseline"]["wall_seconds"], 100)
        self.assertEqual(summary["candidate"]["wall_seconds"], 50.5)
        self.assertEqual(summary["median_paired_baseline_over_candidate_wall"], 1)
        report["runs"].append(dict(report["runs"][0]))
        with self.assertRaisesRegex(ValueError, "pairs"):
            D.paired_summary(report)

    def test_optional_baseline_output_mutation_blocks_summary(self):
        for field in (0, 1, 2):
            def changed(*args):
                row, raw = self.fake_capture(*args)
                if args[0][0] == "baseline":
                    raw = list(raw)
                    raw[field] = 1 if field == 0 else raw[field] + b"changed"
                return row, tuple(raw)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.run_paired_fixture(changed)
            partial = D.PROJECT.read_json(self.out / "results.json")
            self.assertNotIn("paired_summary", partial)

    def test_optional_admission_pins_release_source_binary_and_toolchain(self):
        self.fixture()
        package = self.root / "package"
        baseline = D.PROJECT.read_json(self.root / "setup.json")
        product = baseline["cartograph"]
        product["setup"]["source"]["revision"] = "a" * 40
        product["setup"]["build"] = {"command": ["swift", "build", "--package-path", str(package)],
                                     "returncode": 0, "timed_out": False}
        baseline["status"] = "passed"
        path = self.root / "baseline.json"
        D.BASE.save(path, baseline)
        with mock.patch.object(D.PREP, "verify_bytes") as verify:
            self.assertEqual(D.admit_baseline(path, "a" * 40, baseline, self.config, self.out), baseline)
            verify.assert_called_once()
        self.assertEqual(self.config["hashes"][product["binary"]], product["binary_sha256"])
        self.assertEqual(self.config["hashes"][str(path)], D.BASE.sha256(path))
        for key in ("revision", "working_tree_status"):
            changed = json.loads(json.dumps(baseline))
            changed["cartograph"]["setup"]["source"][key] = "changed"
            D.BASE.save(path, changed)
            with self.subTest(key=key), self.assertRaises(ValueError):
                D.admit_baseline(path, "a" * 40, baseline, self.config, self.out)
        D.BASE.save(path, baseline)
        with self.assertRaises(ValueError):
            D.admit_baseline(path, "main", baseline, self.config, self.out)
        changed = {**baseline, "toolchain": {"version": "different"}}
        with self.assertRaises(ValueError):
            D.admit_baseline(path, "a" * 40, changed, self.config, self.out)
        def verify_hashes(config):
            for filename, digest in config["hashes"].items():
                D.require(D.BASE.sha256(Path(filename)) == digest, "Admitted file changed")
        Path(product["binary"]).write_bytes(b"mutated binary")
        with mock.patch.object(D.PREP, "verify_bytes", side_effect=verify_hashes), \
                self.assertRaisesRegex(ValueError, "Admitted file changed"):
            D.admit_baseline(path, "a" * 40, baseline, self.config, self.out)
        (package / "Sources").mkdir()
        (package / "Sources" / "added.swift").write_text("// 추가된 입력\n")
        with self.assertRaises(ValueError):
            D.admit_baseline(path, "a" * 40, baseline, self.config, self.out)


if __name__ == "__main__":
    unittest.main()
