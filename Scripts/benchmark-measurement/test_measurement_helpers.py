#!/usr/bin/env python3
"""합성 자료와 실제 자식 트리만으로 통계 및 관찰 한계를 회귀 검증한다."""
import copy
import itertools
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

import psutil
import paired_sessions as stats
import process_tree_measure as memory
import machine_manifest as machine
from calibrate_observer import calibration_plan

HERE = Path(__file__).resolve().parent
SYNTHETIC = HERE / "synthetic_workload.py"


def manufactured(plan, shared=0, primary_ratio=0.7, secondary_ratio=0.7):
    """비교 실험 없이 모든 계수가 알려진 세션 레코드를 만든다."""
    records = []
    for row in plan["pairs"]:
        primary = {"status": "ok", "measurement_mode": "timing", "rss_sampling_enabled": False, "orders": {k: row["orders"][k] for k in ("initial", "post_edit")},
                   "shared_initial_build_seconds": shared, "shared_edit_rebuild_seconds": shared,
                   "baseline": {"initial_batch_seconds": 10, "post_edit_batch_seconds": 10},
                   "cartograph": {"initial_batch_seconds": 10 * primary_ratio,
                                  "post_edit_batch_seconds": 10 * primary_ratio},
                   "gates": {gate: True for gate in stats.REQUIRED_GATES},
                   "artifacts": [{"name": "synthetic-only.json", "sha256": "a" * 64}]}
        secondary = {"status": "ok", "measurement_mode": "timing", "rss_sampling_enabled": False, "orders": {"existing_built": row["orders"]["existing_built"]},
                     "baseline": {"batch_seconds": 10}, "cartograph": {"batch_seconds": 10 * secondary_ratio},
                     "gates": {gate: True for gate in stats.REQUIRED_GATES},
                     "artifacts": [{"name": "synthetic-only.json", "sha256": "b" * 64}]}
        for arm in ("baseline", "cartograph"):
            for record, names in ((primary, stats.PRIMARY_ARM_COMPONENTS),
                                  (secondary, stats.SECONDARY_ARM_COMPONENTS)):
                record[arm]["observed_zero_components"] = []
                for name in names:
                    if name not in record[arm]:
                        record[arm][name] = 0
                        record[arm]["observed_zero_components"].append(name)
        records.append({"pair_id": row["pair_id"], "primary_composed": primary,
                        "secondary_existing_built": secondary})
    return {"plan_sha256": plan["plan_sha256"], "pairs": records}


class StatisticsTests(unittest.TestCase):
    """합성 고정 사례로 estimand, 보간, gate, 실패 보존을 검증한다."""

    def setUp(self):
        self.plan = stats.make_plan(1729, 2718, 10000, memory_seed=31415)

    def test_balanced_reproducible_independent_state_orders(self):
        self.assertEqual(self.plan, stats.make_plan(1729, 2718, 10000, memory_seed=31415))
        for state in ("initial", "post_edit", "existing_built"):
            orders = [row["orders"][state] for row in self.plan["pairs"]]
            self.assertEqual(orders.count("AB"), 10)
            self.assertEqual(orders.count("BA"), 10)
        self.assertNotEqual([p["orders"]["initial"] for p in self.plan["pairs"]],
                            [p["orders"]["post_edit"] for p in self.plan["pairs"]])

    def test_memory_order_is_independent_and_balanced(self):
        for state in ("initial", "post_edit", "existing_built"):
            orders = [row["orders"][state] for row in self.plan["memory_pairs"]]
            self.assertEqual(orders.count("AB"), 10)
            self.assertEqual(orders.count("BA"), 10)
            self.assertNotEqual(orders, [row["orders"][state] for row in self.plan["pairs"]])
        with self.assertRaises(ValueError):
            stats.make_plan(1, 2, 10000, memory_seed=1)

    def test_sampled_memory_timing_never_enters_primary(self):
        for mode, sampled in (("memory", True), ("timing", True), (None, False)):
            observations = manufactured(self.plan)
            row = observations["pairs"][0]["primary_composed"]
            row["measurement_mode"] = mode
            row["rss_sampling_enabled"] = sampled
            result = stats.analyze(self.plan, observations)
            self.assertFalse(result["overall_passed"])
            self.assertIsNone(result["endpoints"]["primary_composed"]["performance"])

    def test_plan_mutation_rejected(self):
        for key, value in (("pair_count_per_endpoint", 19), ("maximum_success_ratio", 0.9),
                           ("bootstrap_seed", 1), ("overall_success_endpoint", "secondary_existing_built")):
            altered = copy.deepcopy(self.plan)
            altered[key] = value
            with self.assertRaises(ValueError):
                stats.validate_plan(altered)

    def test_type7_percentiles_fixed_values(self):
        self.assertEqual(stats.percentile([0, 10, 20, 30], 0.25), 7.5)
        self.assertEqual(stats.percentile([0, 10, 20, 30], 0.5), 15)
        self.assertEqual(stats.percentile([0, 10, 20, 30], 0.975), 29.25)
        self.assertEqual(stats.percentile([5], 0.025), 5)
        self.assertEqual(stats.percentile([30, 20, 10, 0], 0), 0)
        self.assertEqual(stats.percentile([30, 20, 10, 0], 1), 30)

    def test_bootstrap_constant_ratio_is_exact(self):
        pairs = [(i + 1, (i + 1) * 0.5) for i in range(20)]
        value = stats.paired_bootstrap(pairs, 101, 1000)
        self.assertEqual(value["paired_median_ratio"], 0.5)
        self.assertEqual(value["ratio_95_percentile_ci"], [0.5, 0.5])

    def test_bootstrap_fixed_nonconstant_case(self):
        result = stats.paired_bootstrap([(10, 2), (20, 12), (40, 40), (100, 160)], 1907, 10000)
        self.assertEqual(result["paired_median_ratio"], 0.8)
        self.assertEqual(result["ratio_95_percentile_ci"], [0.2, 1.6])
        self.assertFalse(result["confidence_gate"])
        exact = [statistics.median(sample) for sample in itertools.product([0.2, 0.6, 1, 1.6], repeat=4)]
        self.assertEqual([stats.percentile(exact, p) for p in (0.025, 0.975)], [0.2, 1.6])

    def test_statistic_is_median_of_paired_ratios(self):
        result = stats.paired_bootstrap([(1, 0.5), (10, 8), (100, 50)], 0, 100)
        self.assertEqual(result["paired_median_ratio"], 0.5)
        self.assertNotEqual(result["paired_median_ratio"], statistics.median([0.5, 8, 50]) / 10)

    def test_exact_twenty_percent_boundary_and_strict_ci(self):
        boundary = stats.paired_bootstrap([(10, 8)] * 20, 9, 100)
        self.assertTrue(boundary["twenty_percent_gate"])
        no_gain = stats.paired_bootstrap([(10, 10)] * 20, 9, 100)
        self.assertFalse(no_gain["confidence_gate"])
        self.assertEqual(no_gain["ratio_95_percentile_ci"], [1, 1])

    def test_shared_build_cost_kept_and_secondary_cannot_rescue(self):
        observations = manufactured(self.plan, shared=100, primary_ratio=0.5, secondary_ratio=0.5)
        value = stats.analyze(self.plan, observations)
        self.assertFalse(value["overall_passed"])
        self.assertFalse(value["endpoints"]["primary_composed"]["passed"])
        self.assertTrue(value["endpoints"]["secondary_existing_built"]["passed"])
        totals = value["endpoints"]["primary_composed"]["whole_pair_costs"][0]
        self.assertEqual((totals["baseline_seconds"], totals["cartograph_seconds"]), (220, 210))
        self.assertAlmostEqual(value["endpoints"]["primary_composed"]["performance"]["paired_median_ratio"], 210 / 220)

    def test_omitted_prep_or_unobserved_zero_fails(self):
        for endpoint, names in (("primary_composed", stats.PRIMARY_ARM_COMPONENTS),
                                ("secondary_existing_built", stats.SECONDARY_ARM_COMPONENTS)):
            for name in names:
                observations = manufactured(self.plan)
                del observations["pairs"][0][endpoint]["cartograph"][name]
                result = stats.analyze(self.plan, observations)
                self.assertFalse(result["endpoints"][endpoint]["passed"], (endpoint, name))
                self.assertIsNone(result["endpoints"][endpoint]["performance"])
            observations = manufactured(self.plan)
            observations["pairs"][0][endpoint]["cartograph"]["observed_zero_components"] = []
            self.assertFalse(stats.analyze(self.plan, observations)["endpoints"][endpoint]["passed"])

    def test_discovery_refresh_cost_overturns_batch_only_win(self):
        observations = manufactured(self.plan, primary_ratio=0.5)
        for pair in observations["pairs"]:
            cartograph = pair["primary_composed"]["cartograph"]
            for name, seconds in (("initial_discovery_setup_seconds", 15), ("post_edit_refresh_seconds", 20),
                                  ("post_edit_cache_validation_seconds", 5)):
                cartograph[name] = seconds
                cartograph["observed_zero_components"].remove(name)
        result = stats.analyze(self.plan, observations)
        self.assertFalse(result["overall_passed"])
        primary = result["endpoints"]["primary_composed"]
        self.assertEqual(primary["performance"]["paired_median_ratio"], 2.5)
        self.assertEqual(primary["whole_pair_costs"][0]["cartograph_seconds"], 50)
        self.assertEqual(primary["whole_pair_costs"][0]["cost_decomposition"]["cartograph"]
                         ["post_edit_refresh_seconds"], 20)
        self.assertTrue(result["endpoints"]["secondary_existing_built"]["passed"])

    def test_secondary_discovery_cache_cost_cannot_be_omitted(self):
        observations = manufactured(self.plan, secondary_ratio=0.5)
        for pair in observations["pairs"]:
            cartograph = pair["secondary_existing_built"]["cartograph"]
            cartograph["discovery_setup_seconds"] = 10
            cartograph["cache_validation_seconds"] = 2
            cartograph["observed_zero_components"] = []
        result = stats.analyze(self.plan, observations)
        self.assertTrue(result["overall_passed"])
        secondary = result["endpoints"]["secondary_existing_built"]
        self.assertFalse(secondary["passed"])
        self.assertEqual(secondary["performance"]["paired_median_ratio"], 1.7)

    def test_primary_pass_does_not_depend_on_secondary_performance(self):
        value = stats.analyze(self.plan, manufactured(self.plan, primary_ratio=0.7, secondary_ratio=1.2))
        self.assertTrue(value["overall_passed"])
        self.assertFalse(value["endpoints"]["secondary_existing_built"]["passed"])

    def test_failures_are_preserved_not_bootstrapped_away(self):
        observations = manufactured(self.plan)
        observations["pairs"][3]["primary_composed"]["status"] = "timeout"
        observations["pairs"][3]["primary_composed"]["root_returncode"] = -9
        result = stats.analyze(self.plan, observations)
        self.assertFalse(result["overall_passed"])
        self.assertIsNone(result["endpoints"]["primary_composed"]["performance"])
        self.assertEqual(result["raw_observations"], observations)
        self.assertEqual(result["endpoints"]["primary_composed"]["failures"][0]["pair_id"], "pair-04")

    def test_missing_pair_order_gate_and_hash_fail_closed(self):
        for change in ("missing", "order", "gate", "hash"):
            observations = manufactured(self.plan)
            record = observations["pairs"][0]["primary_composed"]
            if change == "missing":
                observations["pairs"].pop()
            elif change == "order":
                record["orders"]["initial"] = "invalid"
            elif change == "gate":
                record["gates"]["source_oracle"] = False
            else:
                record["artifacts"][0]["sha256"] = "not-a-hash"
            self.assertFalse(stats.analyze(self.plan, observations)["overall_passed"])

    def test_invalid_numeric_values_rejected(self):
        for bad in (0, -1, float("nan"), float("inf")):
            with self.assertRaises(ValueError):
                stats.paired_bootstrap([(10, bad)], 0, 100)
        for pair in ((1e-300, 1e300), (1e300, 1e-300)):
            with self.assertRaises(ValueError):
                stats.paired_bootstrap([pair], 0, 10)
        with self.assertRaises(ValueError):
            stats.percentile([], 0.5)


class ManifestAndCalibrationTests(unittest.TestCase):
    """허용 목록, 실패 공개와 합성 보정 순서만 집중 검증한다."""

    def test_sysctl_disallows_identity_and_bulk_queries(self):
        calls = []
        for key in ("kern.hostname", "kern.version", "hw.serialnumber", "-a", "anything_else"):
            with self.assertRaises(ValueError):
                machine.read_sysctl(key, lambda command: calls.append(command))
        self.assertEqual(calls, [])

    def test_macos_fields_use_only_whitelisted_keys(self):
        values = {"hw.machine": "arm64", "hw.physicalcpu": "8", "hw.logicalcpu": "8",
                  "hw.memsize": "17179869184", "machdep.cpu.brand_string": "Synthetic CPU model",
                  "kern.osrelease": "synthetic-kernel", "kern.osproductversion": "synthetic-os-version"}
        calls = []
        def runner(command):
            calls.append(command)
            return {"status": "ok", "stdout": values[command[-1]]}
        fields, failures = machine.macos_fields(runner)
        self.assertEqual(failures, [])
        self.assertEqual(fields["ram_bytes"], 17179869184)
        self.assertEqual(fields["physical_core_count"], 8)
        self.assertEqual({command[-1] for command in calls}, machine.SYSCTL_KEYS)
        self.assertTrue(all(command[:2] == ["/usr/sbin/sysctl", "-n"] for command in calls))

    def test_missing_native_fields_are_not_guessed(self):
        fields, failures = machine.macos_fields(lambda command: {"status": "failed", "stdout": ""})
        self.assertIsNone(fields["cpu_model"])
        self.assertEqual(len(failures), len(machine.SYSCTL_KEYS))

    def test_cpu_model_excludes_serial_and_unrelated_fields(self):
        with tempfile.TemporaryDirectory(prefix="cpuinfo-", dir=HERE) as directory:
            path = Path(directory) / "cpuinfo"
            path.write_text("Serial: PRIVATE_SERIAL\nmodel name: Synthetic CPU\nhostname: PRIVATE_HOST\n")
            self.assertEqual(machine.linux_cpu_model(path), "Synthetic CPU")

    def test_calibration_plan_is_balanced_and_reproducible(self):
        plan = calibration_plan(10, 48611, 87941, 0.01)
        self.assertEqual(plan, calibration_plan(10, 48611, 87941, 0.01))
        for workload in plan["workloads"]:
            for mode in ("timing", "memory"):
                orders = [job["order"] for job in plan["jobs"]
                          if job["workload"] == workload and job["mode"] == mode]
                self.assertEqual(orders.count("AB"), 5)
                self.assertEqual(orders.count("BA"), 5)
        with self.assertRaises(ValueError):
            calibration_plan(9, 48611, 87941, 0.01)


class ProcessTreeTests(unittest.TestCase):
    """실제 실행한 합성 트리만 관찰하고 종료하는지 검증한다."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="selftest-", dir=HERE)
        self.directory = Path(self.temp.name)
        # 뒤에 등록한 fixture identity 정리가 임시 디렉터리 삭제보다 먼저 실행돼야 한다.
        self.addCleanup(self.temp.cleanup)

    def measure(self, mode, *args, timeout=5):
        return memory.run([sys.executable, str(SYNTHETIC), mode, *map(str, args)], HERE,
                          self.directory / "observed", timeout=timeout, interval=0.005, grace=0.05, mode="memory")

    def assert_gone(self, pid):
        try:
            self.assertTrue(not psutil.Process(pid).is_running() or psutil.Process(pid).status() == psutil.STATUS_ZOMBIE)
        except psutil.NoSuchProcess:
            return

    def test_simultaneous_sum_and_resolution(self):
        result = self.measure("simultaneous")
        self.assertEqual(result["status"], "ok", result)
        self.assertGreaterEqual(result["rss"]["observed_peak_bytes"], 60 * 1024 * 1024)
        self.assertGreaterEqual(result["rss"]["observed_process_count"], 2)
        self.assertGreater(result["rss"]["actual_interval_max_seconds"], 0)
        samples = [json.loads(line) for line in (self.directory / "observed.samples.0001.jsonl").read_text().splitlines()]
        for row in samples:
            self.assertEqual(row["rss_bytes"], sum(member["rss_bytes"] for member in row["processes"]))
        self.assertEqual(result["rss"]["observed_peak_bytes"], max(row["rss_bytes"] for row in samples))
        for artifact in result["artifacts"].values():
            self.assertEqual(artifact["sha256"], memory.file_sha256(self.directory / artifact["name"]))

    def test_sequential_peaks_are_not_summed(self):
        result = self.measure("sequential")
        self.assertEqual(result["status"], "ok", result)
        peaks = {}
        for line in (self.directory / "observed.samples.0001.jsonl").read_text().splitlines():
            for member in json.loads(line)["processes"]:
                key = member["process_id"]
                peaks[key] = max(peaks.get(key, 0), member["rss_bytes"])
        self.assertGreater(sum(peaks.values()) - result["rss"]["observed_peak_bytes"], 30 * 1024 * 1024)

    def test_timeout_kills_independent_session_grandchild(self):
        pid_file = self.directory / "grandchild.pid"
        result = self.measure("orphan", pid_file, 10, 10, timeout=0.6)
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["returncode"], 124)
        self.assertEqual(result["cleanup"]["remaining_observed_pids"], [])
        self.assert_gone(int(pid_file.read_text()))

    def test_parent_exit_keeps_observed_grandchild_and_times_out(self):
        pid_file = self.directory / "grandchild.pid"
        identities = self.directory / "fixture-identities.jsonl"
        released = self.directory / "release-middle"
        samples_path = self.directory / "observed.samples.0001.jsonl"
        fixture = self.directory / "observed-orphan.py"
        # 생산자가 아직 내용을 쓰지 않은 유효한 시작 상태도 handshake가 기다려야 한다.
        pid_file.touch()
        fixture.write_text(textwrap.dedent('''\
            import json, os, subprocess, sys, time
            from pathlib import Path
            import psutil
            role, synthetic, pid_name, ids_name, release_name, samples_name = sys.argv[1:]
            pid_file, identities, released, samples = map(Path, (pid_name, ids_name, release_name, samples_name))
            empty_read = pid_file.with_suffix(".empty-observed")
            deadline = time.monotonic() + 5
            def remember(pid):
                with identities.open("a") as sink:
                    sink.write(json.dumps({"pid": pid, "create_time": psutil.Process(pid).create_time()}) + "\\n")
            def wait_for(predicate):
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    time.sleep(0.005)
                raise TimeoutError("fixture handshake deadline")
            remember(os.getpid())
            if role == "middle":
                # 빈 PID를 실제로 읽기 전에는 생산자가 덮어쓰지 않는 결정적 준비 대조군이다.
                wait_for(empty_read.exists)
                leaf = subprocess.Popen([sys.executable, synthetic, "stubborn", str(pid_file)], start_new_session=True)
                remember(leaf.pid)
                wait_for(released.exists)
            else:
                middle = subprocess.Popen([sys.executable, __file__, "middle", *sys.argv[2:]], start_new_session=True)
                remember(middle.pid)
                def observed():
                    if not pid_file.exists() or not samples.exists():
                        return False
                    try:
                        leaf_pid = int(pid_file.read_text())
                    except ValueError:
                        empty_read.touch()
                        return False
                    wanted = {(pid, psutil.Process(pid).create_time())
                              for pid in (os.getpid(), middle.pid, leaf_pid)}
                    for line in samples.read_text().splitlines():
                        try:
                            row = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if wanted <= {(member["pid"], member["create_time"]) for member in row["processes"]}:
                            return True
                    return False
                wait_for(observed)
                # 이전 0.5초 oracle이 거절했던 정상적인 늦은 루트 종료 대조군이다.
                time.sleep(0.55)
                released.touch()
            '''))

        # 첫 assertion이나 변이 대조군 실패 뒤에도 이번 fixture의 원래 identity만 정리한다.
        def cleanup_fixture():
            if not identities.exists():
                return
            errors = []
            for line in identities.read_text().splitlines():
                try:
                    identity = json.loads(line)
                    process = psutil.Process(identity["pid"])
                    if process.create_time() == identity["create_time"] and process.status() != psutil.STATUS_ZOMBIE:
                        process.kill()
                        process.wait(timeout=3)
                except psutil.NoSuchProcess:
                    continue
                except (ValueError, psutil.Error) as error:
                    errors.append(type(error).__name__)
            self.assertEqual(errors, [], "Owned fixture identity cleanup failed")

        self.addCleanup(cleanup_fixture)
        # 3초는 합성 handshake/timeout의 실행 한도이며 제품 성능 판정 기준이 아니다.
        result = memory.run([sys.executable, str(fixture), "root", str(SYNTHETIC), str(pid_file),
                             str(identities), str(released), str(samples_path)], HERE,
                            self.directory / "observed", timeout=3, interval=0.005, grace=0.05, mode="memory")
        self.assertEqual(result["root_returncode"], 0)
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["returncode"], 124)
        self.assertEqual(result["failure"], "timeout")
        self.assertEqual(result["rss"]["read_errors"], [])
        self.assertGreaterEqual(result["rss"]["observed_process_count"], 3)
        self.assertEqual(result["cleanup"]["remaining_observed_pids"], [])
        rows = [json.loads(line) for line in samples_path.read_text().splitlines()]
        # 루트가 자식 생성 전에 남긴 실제 identity로 sample→poll 관측 구간을 고정한다.
        root_identity = json.loads(identities.read_text().splitlines()[0])
        root_key = (root_identity["pid"], root_identity["create_time"])
        root_rows = [index for index, row in enumerate(rows) if any(
            (member["pid"], member["create_time"]) == root_key for member in row["processes"])]
        self.assertTrue(root_rows)
        last_root = root_rows[-1]
        self.assertEqual(root_rows, list(range(root_rows[0], last_root + 1)))
        exit_at = result["root_exit_observed_seconds"]
        self.assertGreater(len(rows), last_root + 2)
        self.assertLess(rows[last_root]["start_seconds"], exit_at)
        self.assertLess(exit_at, rows[last_root + 2]["start_seconds"])
        initial = next(row for row in rows if row["process_count"] == 3)
        members = {member["process_id"]: member for member in initial["processes"]}
        leaf = next(member for member in members.values() if member["pid"] == int(pid_file.read_text()))
        # 관측 구간 밖의 이른/늦은 시각은 위에서 거절하며, 그 뒤에도 같은 고아를 보존해야 한다.
        self.assertTrue(any(row["start_seconds"] > exit_at and
                            len(row["processes"]) == 1 and
                            row["processes"][0]["process_id"] == leaf["process_id"] and
                            row["processes"][0]["pid"] == leaf["pid"] and
                            row["processes"][0]["create_time"] == leaf["create_time"]
                            for row in rows))
        self.assert_gone(int(pid_file.read_text()))

    @unittest.skipUnless(sys.platform == "linux", "Linux-only orphan adoption; macOS gap is explicit")
    def test_fast_unobserved_ancestry_adopted_by_isolated_subreaper(self):
        pid_file = self.directory / "grandchild.pid"
        result = self.measure("orphan", pid_file, 0, 0, timeout=0.5)
        self.assertTrue(result["containment"]["linux_subreaper"])
        self.assertTrue(result["timed_out"])
        self.assert_gone(int(pid_file.read_text()))

    def test_portable_identity_tracking_retains_orphan_after_parent_exit(self):
        pid_file = self.directory / "portable-grandchild.pid"
        root = subprocess.Popen([sys.executable, str(SYNTHETIC), "orphan", str(pid_file), "0.2", "0.25"],
                                start_new_session=True)
        tracker = memory.TreeTracker(os.getpid(), root.pid, subreaper=False)
        try:
            deadline = time.perf_counter() + 2
            while root.poll() is None and time.perf_counter() < deadline:
                tracker.discover()
                time.sleep(0.005)
            tracker.discover()
            pid = int(pid_file.read_text())
            self.assertEqual(root.poll(), 0)
            self.assertIn(pid, [process.pid for process in tracker.live()])
            cleanup = memory._cleanup(tracker, root, grace=0.05)
            self.assertEqual(cleanup["remaining_observed_pids"], [])
            self.assert_gone(pid)
        finally:
            memory._cleanup(tracker, root, grace=0.05)

    def test_unrelated_process_untouched_and_not_recorded(self):
        sentinel = "UNRELATED_COMMAND_MUST_NEVER_BE_RECORDED"
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)", sentinel])
        try:
            result = self.measure("allocate", 1, 0.08)
            self.assertEqual(result["status"], "ok")
            self.assertIsNone(unrelated.poll())
            all_bytes = b"".join(path.read_bytes() for path in self.directory.iterdir())
            self.assertNotIn(sentinel.encode(), all_bytes)
            samples = (self.directory / "observed.samples.0001.jsonl").read_text()
            self.assertNotIn(f'"pid": {unrelated.pid},', samples)
        finally:
            unrelated.terminate()
            unrelated.wait()

    def test_nonzero_exit_keeps_outputs_hashes_and_timing(self):
        result = self.measure("nonzero")
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["root_returncode"], 7)
        self.assertGreater(result["wall_seconds"], 0)
        self.assertEqual((self.directory / "observed.stdout").read_text(), "synthetic stdout\n")
        self.assertEqual((self.directory / "observed.stderr").read_text(), "synthetic stderr\n")
        self.assertTrue((self.directory / "observed.json").exists())

    def test_cli_termination_forwards_cleanup_and_preserves_result(self):
        pid_file = self.directory / "cancelled-grandchild.pid"
        launcher = subprocess.Popen([sys.executable, str(HERE / "process_tree_measure.py"),
                                     "--stem", str(self.directory / "cancelled"), "--timeout", "10", "--",
                                     sys.executable, str(SYNTHETIC), "orphan", str(pid_file), "10", "10"],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.perf_counter() + 3
            while not pid_file.exists() and time.perf_counter() < deadline:
                time.sleep(0.01)
            self.assertTrue(pid_file.exists())
            launcher.terminate()
            out, err = launcher.communicate(timeout=5)
            self.assertEqual(launcher.returncode, 1, (out, err))
            result = json.loads((self.directory / "cancelled.json").read_text())
            self.assertEqual(result["failure"], "cancelled")
            self.assertEqual(result["returncode"], 143)
            self.assertEqual(result["cleanup"]["remaining_observed_pids"], [])
            self.assert_gone(int(pid_file.read_text()))
        finally:
            if launcher.poll() is None:
                launcher.terminate()
                launcher.wait(timeout=5)

    def test_timing_mode_creates_no_rss_samples(self):
        result = memory.run([sys.executable, str(SYNTHETIC), "allocate", "1", "0.08"], HERE,
                            self.directory / "timing", mode="timing")
        self.assertEqual(result["status"], "ok", result)
        self.assertTrue(result["primary_timing_eligible"])
        self.assertIsNone(result["rss"])
        self.assertFalse(result["periodic_tree_discovery_during_timing"])
        self.assertFalse(list(self.directory.glob("timing.samples.*")))
        self.assertGreaterEqual(result["supervision_total_seconds"], result["wall_seconds"])

    def test_timing_timeout_kills_independent_sessions(self):
        pid_file = self.directory / "timing-grandchild.pid"
        result = memory.run([sys.executable, str(SYNTHETIC), "orphan", str(pid_file), "10", "10"], HERE,
                            self.directory / "timing-timeout", timeout=0.5, grace=0.05, mode="timing")
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["cleanup"]["remaining_observed_pids"], [])
        self.assert_gone(int(pid_file.read_text()))

    @unittest.skipUnless(sys.platform == "linux", "macOS detached-orphan gap remains disclosed")
    def test_timing_early_root_exit_with_orphans_fails_and_cleans_up(self):
        pid_file = self.directory / "timing-orphan.pid"
        result = memory.run([sys.executable, str(SYNTHETIC), "orphan", str(pid_file), "0", "0.15"], HERE,
                            self.directory / "timing-orphan", timeout=2, grace=0.05, mode="timing")
        self.assertEqual(result["root_returncode"], 0)
        self.assertEqual(result["failure"], "unexpected_descendants_after_root_exit")
        self.assertFalse(result["primary_timing_eligible"])
        self.assert_gone(int(pid_file.read_text()))

    def test_sample_rotation_preserves_every_row_and_hash(self):
        rows = [{"sample_id": i, "rss_bytes": i * 1024, "processes": []} for i in range(20)]
        writer = memory.SampleWriter(self.directory / "rotated", limit_bytes=250)
        with writer:
            for row in rows:
                writer.write(row)
        restored = []
        self.assertGreater(len(writer.chunks), 1)
        for index, chunk in enumerate(writer.chunks, 1):
            self.assertEqual(chunk["name"], f"rotated.samples.{index:04d}.jsonl")
            path = self.directory / chunk["name"]
            self.assertLessEqual(path.stat().st_size, 250)
            self.assertEqual(path.stat().st_size, chunk["bytes"])
            self.assertEqual(memory.file_sha256(path), chunk["sha256"])
            lines = path.read_text().splitlines()
            self.assertEqual(len(lines), chunk["sample_count"])
            restored.extend(json.loads(line) for line in lines)
        self.assertEqual(restored, rows)

    def test_oversized_sample_fails_instead_of_splitting_or_dropping(self):
        with memory.SampleWriter(self.directory / "oversized", limit_bytes=10) as writer:
            with self.assertRaises(ValueError):
                writer.write({"sample": "too long"})
        self.assertEqual(writer.chunks, [])

    def test_existing_evidence_never_overwritten(self):
        self.measure("allocate", 1, 0.05)
        before = (self.directory / "observed.json").read_bytes()
        with self.assertRaises(FileExistsError):
            self.measure("allocate", 2, 0.05)
        self.assertEqual(before, (self.directory / "observed.json").read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
