#!/usr/bin/env python3
"""실제 Swift 없이 준비 세션의 IPC·신선도·새로고침 측정 계약을 검사한다."""

from __future__ import annotations

import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("benchmark-prepared-indexstore-sessions.py")
SPEC = importlib.util.spec_from_file_location("prepared_sessions", SCRIPT)
assert SPEC and SPEC.loader
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)


class PreparedSessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        oracle, _ = BENCH.PROJECT.frozen_inputs()
        ids = {node["id"]: node["source_id"] for node in oracle["nodes"]}
        self.graph = {"bindings": {value: value for value in ids.values()},
                      "symbols": {value: value for value in ids.values()},
                      "edges": [[ids[edge["caller"]], ids[edge["callee"]]] for edge in oracle["edges"]]}
        self.config = {"oracle": oracle, "requests": BENCH.PROJECT.query_requests(oracle),
                       "project": str(self.root / "project"), "store": str(self.root / "index"),
                       "cg_config": str(self.root / "config.yml"), "out": str(self.root / "baseline"),
                       "manifest": {"files": [{"path": "Sources/Test.swift"}]}, "timeout": 1,
                       "cartograph": "unused"}
        (self.root / "project" / "Sources").mkdir(parents=True)
        (self.root / "project" / "Sources" / "Test.swift").write_text("func run() {}\n")
        (self.root / "index").mkdir()
        (self.root / "index" / "unit").write_bytes(b"index")
        (self.root / "config.yml").write_text("exclude: []\n")

    def tearDown(self):
        self.temporary.cleanup()

    def test_metadata_refuses_same_size_restored_mtime_edit_and_new_inputs(self):
        for path in [self.root / "project" / "Sources" / "Test.swift", self.root / "index" / "unit",
                     self.root / "config.yml"]:
            before, previous = BENCH.metadata(self.config), path.stat()
            path.write_bytes(b"X" * previous.st_size)
            os.utime(path, ns=(previous.st_atime_ns, previous.st_mtime_ns))
            self.assertNotEqual(before, BENCH.metadata(self.config))
        before = BENCH.metadata(self.config)
        extra = self.root / "project" / "Sources" / "Added.swift"
        extra.write_text("func extra() {}")
        self.assertNotEqual(before, BENCH.metadata(self.config))
        before = BENCH.metadata(self.config)
        extra.unlink()
        self.assertNotEqual(before, BENCH.metadata(self.config))
        extra.symlink_to(self.root / "config.yml")
        with self.assertRaisesRegex(ValueError, "Symlink"):
            BENCH.metadata(self.config)

    def worker(self, requests: list[tuple[str | None, dict]], fingerprints=None, graphs=None):
        raw = b"".join(BENCH.MCP.request(number, "tools/call" if name else "server/discover",
                            BENCH.MCP.modern_params(name=name, arguments=arguments))
                       for number, (name, arguments) in enumerate(requests))
        output = io.StringIO()
        with mock.patch.object(BENCH.sys, "stdin", io.TextIOWrapper(io.BytesIO(raw))), \
                mock.patch.object(BENCH.sys, "stdout", output), mock.patch.object(BENCH.signal, "signal"), \
                mock.patch.object(BENCH, "verify_bytes",
                                  side_effect=AssertionError("Byte grading inside IPC")) as admission, \
                mock.patch.object(BENCH.PROJECT, "graph_grade",
                                  side_effect=AssertionError("Oracle grading inside IPC")), \
                mock.patch.object(BENCH.PROJECT, "baseline_discovery", return_value=self.graph,
                                  side_effect=graphs) as discover:
            if fingerprints:
                with mock.patch.object(BENCH, "metadata", side_effect=fingerprints):
                    BENCH.baseline_worker(self.config)
            else:
                BENCH.baseline_worker(self.config)
        return [json.loads(line)["result"] for line in output.getvalue().splitlines()], discover, admission

    def test_ready_and_refresh_really_discover_but_warm_queries_reuse(self):
        request = max(self.config["requests"], key=lambda item: item["max_depth"])
        query = ("cartograph_query", {"symbols": [request["seed"]], "depth": request["max_depth"], "limit": 1000})
        with mock.patch.object(BENCH.BASE, "reverse_adjacency", wraps=BENCH.BASE.reverse_adjacency) as adjacency:
            replies, discover, admission = self.worker([(None, {}), ("cartograph_status", {}), query, query,
                                                       ("cartograph_status", {"refresh": True}), query])
        self.assertEqual(discover.call_count, 2)
        self.assertEqual(adjacency.call_count, 2)
        admission.assert_not_called()
        payloads = [reply["structuredContent"] for reply in replies[1:]]
        self.assertEqual([payload.get("generation", payload.get("session", {}).get("generation"))
                          for payload in payloads], [1, 1, 1, 2, 2])
        for index in (2, 3, 5):
            grade = BENCH.PROJECT.grade(replies[index]["structuredContent"]["answers"], self.config["oracle"])
            self.assertTrue(grade["passed"])
        self.assertEqual([call.args[0]["out"] for call in discover.call_args_list],
                         [str(self.root / "baseline" / f"generation-{number}") for number in (1, 2)])

    def test_refresh_replaces_adjacency_and_controller_still_rejects_bad_graph(self):
        request = max(self.config["requests"], key=lambda item: item["max_depth"])
        query = ("cartograph_query", {"symbols": [request["seed"]], "depth": request["max_depth"], "limit": 1000})
        changed = copy.deepcopy(self.graph)
        changed["edges"] = []
        replies, _, _ = self.worker([("cartograph_status", {}), query,
                                     ("cartograph_status", {"refresh": True}), query],
                                    graphs=[self.graph, changed])
        self.assertNotEqual(replies[1]["structuredContent"]["answers"], replies[3]["structuredContent"]["answers"])
        first = BENCH.verify_baseline_generation(self.config, 1)
        self.assertEqual(first["generation"], 1)
        self.assertTrue(first["grade"]["exact_match"])
        self.assertEqual(first["graph_sha256"],
                         BENCH.BASE.sha256(Path(self.config["out"]) / "generation-1" / "graph.json"))
        with self.assertRaisesRegex(ValueError, "Baseline graph failed oracle"):
            BENCH.verify_baseline_generation(self.config, 2)

    def test_prepared_traversal_preserves_minimum_depth_cycles_and_seed_exclusion(self):
        edges = [["a", "seed"], ["b", "a"], ["c", "b"], ["c", "a"], ["a", "a"], ["seed", "b"], ["outside", "c"]]
        reverse = BENCH.BASE.reverse_adjacency(edges)
        for maximum, expected in ((0, {}), (1, {"a": 1}), (3, {"a": 1, "b": 2, "c": 2, "outside": 3})):
            with self.subTest(maximum=maximum):
                self.assertEqual(BENCH.PROJECT.depths_from_reverse(reverse, "seed", maximum), expected)
                self.assertEqual(BENCH.PROJECT.reverse_depths(edges, "seed", maximum), expected)

    def test_worker_rejects_drift_before_any_repair(self):
        with self.assertRaisesRegex(ValueError, "refuses input metadata drift"):
            self.worker([("cartograph_status", {}), ("cartograph_status", {"refresh": True})], ["a", "a", "b"])
        with self.assertRaisesRegex(ValueError, "during baseline discovery"):
            self.worker([("cartograph_status", {})], ["a", "b"])

    def client(self, code: str, timeout=1):
        return BENCH.Client([sys.executable, "-u", "-c", code], self.root, self.root / "client", timeout)

    def test_ipc_raw_evidence_normal_exit_and_matching_timer_boundaries(self):
        code = ('import sys,json\nfor line in sys.stdin:\n r=json.loads(line); '
                'print(json.dumps({"jsonrpc":"2.0","id":r["id"],"result":{"resultType":"complete",'
                '"isError":False,"structuredContent":{"evidence":{"retained":True}}}}),flush=True)')
        client = self.client(code)
        try:
            events = []
            original_receive = client.receive
            def receive(deadline):
                events.append("receive")
                return original_receive(deadline)
            with mock.patch.object(client, "receive", side_effect=receive), \
                    mock.patch.object(BENCH.time, "perf_counter", side_effect=lambda: events.append("timer") or 1.0):
                payload, measured = client.call("cartograph_status")
            self.assertEqual(events, ["timer", "receive", "timer"])
            self.assertEqual(payload, {"evidence": {"retained": True}})
            self.assertIn('"retained": true', Path(measured["stdout"]).read_text())
            self.assertEqual(json.loads(Path(measured["request"]).read_text())["params"]["arguments"], {})
        finally:
            record = client.close()
        self.assertEqual(record["returncode"], 0)
        self.assertFalse(record["forced_cleanup"])

    def test_rejects_malformed_oversize_mismatched_and_incomplete_replies(self):
        cases = [('print("broken",flush=True)', "JSONDecodeError"),
                 ('print("x"*200,flush=True)', "Oversized"),
                 ('print(\'{"jsonrpc":"2.0","id":999,"result":{"resultType":"complete"}}\',flush=True)', "Mismatched"),
                 ('print(\'{"jsonrpc":"2.0","id":1,"result":{"resultType":"partial"}}\',flush=True)', "Incomplete")]
        for code, message in cases:
            client = self.client("import sys\nsys.stdin.readline()\n" + code)
            try:
                with mock.patch.object(BENCH, "MAX_REPLY", 100 if message == "Oversized" else BENCH.MAX_REPLY):
                    with self.assertRaises((ValueError, json.JSONDecodeError)) as error:
                        client.call("cartograph_status")
                    self.assertIn(message, type(error.exception).__name__ + str(error.exception))
                self.assertTrue((self.root / "client" / "01-cartograph_status.stdout").read_bytes())
            finally:
                client.close()

    def test_request_deadline_is_bounded(self):
        client = self.client("import sys,time\nsys.stdin.readline()\ntime.sleep(0.2)", timeout=0.01)
        try:
            with self.assertRaisesRegex(TimeoutError, "deadline"):
                client.call("cartograph_status")
        finally:
            client.close()

    def test_sequence_refresh_and_total_accounting(self):
        class FakeClient:
            def __init__(self, *_):
                self.started, self.completed, self.generation = 1.0, 3.0, 1
            def call(self, name, arguments=None):
                self.generation += bool((arguments or {}).get("refresh"))
                return {"generation": self.generation}, {"ipc_seconds": 7.0}
            def close(self):
                return {"returncode": 0, "forced_cleanup": False}
        report = {"admission_seconds": 5.0}
        def graph_check(config, generation):
            self.assertEqual(report["preparation"]["baseline"]["spawn_to_graph_ready_seconds"], 2.0)
            return {"generation": generation, "seconds": 4.0}
        with mock.patch.object(BENCH, "Client", FakeClient), \
                mock.patch.object(BENCH, "verify_bytes", return_value={"seconds": 3.0}), \
                mock.patch.object(BENCH, "verify_baseline_generation", side_effect=graph_check) as graph_check, \
                mock.patch.object(BENCH, "query", side_effect=lambda c, arm, cfg, g, generation:
                                  {"ipc_seconds": 11.0, "generation": generation}) as query:
            BENCH.run(self.config, self.graph, self.root / "run", report)
        self.assertEqual([pair["order"] for pair in report["warm_pairs"]],
                         [["baseline", "cartograph"], ["cartograph", "baseline"]] * 2)
        self.assertEqual(report["refresh"]["baseline"]["first_answer"]["generation"], 2)
        self.assertEqual(query.call_count, 12)
        self.assertEqual(report["totals"], {arm: 75.0 for arm in BENCH.ARMS})
        self.assertEqual(graph_check.call_args_list, [mock.call(self.config, 1), mock.call(self.config, 2)])
        self.assertEqual(report["common_byte_verification_seconds"], 42.0)
        self.assertEqual(report["common_graph_verification_seconds"], 8.0)
        self.assertEqual(report["totals_including_common_verification_seconds"], {arm: 130.0 for arm in BENCH.ARMS})
        self.assertEqual(report["status"], "passed")
        with mock.patch.object(BENCH, "Client", FakeClient), \
                mock.patch.object(BENCH, "verify_bytes", return_value={"seconds": 0}), \
                mock.patch.object(BENCH, "verify_baseline_generation", return_value={"seconds": 0}), \
                mock.patch.object(BENCH, "query", return_value={"ipc_seconds": 0}):
            with self.assertRaisesRegex(ValueError, "Shared driver deadline"):
                BENCH.run(self.config, self.graph, self.root / "expired", {"admission_seconds": 0}, deadline=0)

    def test_controller_oracle_failure_stops_before_queries_and_cleans_up(self):
        client = mock.Mock(started=1.0, completed=3.0)
        client.call.return_value = ({"generation": 1}, {"ipc_seconds": 1})
        client.close.return_value = {"returncode": 0, "forced_cleanup": False}
        with mock.patch.object(BENCH, "Client", return_value=client), \
                mock.patch.object(BENCH, "verify_bytes", return_value={"seconds": 0}), \
                mock.patch.object(BENCH, "verify_baseline_generation",
                                  side_effect=ValueError("Baseline graph failed oracle")), \
                mock.patch.object(BENCH, "query") as query:
            with self.assertRaisesRegex(ValueError, "Baseline graph failed oracle"):
                BENCH.run(self.config, self.graph, self.root / "failed", {"admission_seconds": 0})
        query.assert_not_called()
        client.close.assert_called_once()

    def test_shared_deadline_prevents_another_request_and_sigterm_enters_cleanup(self):
        client = self.client("import sys\nfor line in sys.stdin: pass")
        client.deadline = 0
        try:
            with self.assertRaisesRegex(ValueError, "Shared driver deadline"):
                client.call("cartograph_status")
        finally:
            self.assertEqual(client.close()["returncode"], 0)
        with mock.patch.object(BENCH.signal, "signal") as signal_handler:
            with self.assertRaisesRegex(KeyboardInterrupt, "cleaning up"):
                BENCH.terminate_driver(None, None)
            signal_handler.assert_called_once_with(BENCH.signal.SIGTERM, BENCH.signal.SIG_IGN)

    def test_stdin_close_failure_still_reaps_its_process(self):
        client = self.client("import sys\nfor line in sys.stdin: pass")
        original = client.process.stdin
        def fail_after_close():
            original.close()
            raise OSError("injected stdin close error")
        client.process.stdin = mock.Mock()
        client.process.stdin.close.side_effect = fail_after_close
        with self.assertRaisesRegex(OSError, "injected stdin close error"):
            client.close()
        self.assertEqual(client.process.poll(), 0)
        record = json.loads((client.out / "process.json").read_text())
        self.assertEqual(record["returncode"], 0)
        self.assertIn("injected stdin close error", record["close_error"])

    def test_cleanup_failure_does_not_skip_other_process(self):
        clients = [mock.Mock(started=0, completed=0), mock.Mock(started=0, completed=0)]
        for client in clients:
            client.call.return_value = ({"generation": 1}, {"ipc_seconds": 1})
        clients[0].close.side_effect = OSError("close failed")
        clients[1].close.return_value = {"returncode": 0, "forced_cleanup": False}
        report = {"admission_seconds": 0}
        with mock.patch.object(BENCH, "Client", side_effect=clients), \
                mock.patch.object(BENCH, "verify_bytes", return_value={"seconds": 0}), \
                mock.patch.object(BENCH, "verify_baseline_generation", return_value={"seconds": 0}), \
                mock.patch.object(BENCH, "query", side_effect=RuntimeError("query failed")):
            with self.assertRaisesRegex(RuntimeError, "query failed"):
                BENCH.run(self.config, self.graph, self.root / "run", report)
        clients[1].close.assert_called_once()
        self.assertEqual(report["status"], "failed")

    def test_native_parser_keeps_oracle_and_truncation_contracts(self):
        request = max(self.config["requests"], key=lambda item: item["max_depth"])
        answer = BENCH.PROJECT.reverse_depths(self.graph["edges"], request["seed"], request["max_depth"])
        result = {"requested": request["seed"], "status": "found", "level": "symbol", "limitations": [],
                  "result": {"subject": {"usr": request["seed"]},
                             "truncated": {key: False for key in ("usedBy", "dependsOn", "members")},
                             "usedBy": [{"usr": usr, "depth": depth, "edges": ["call"]}
                                        for usr, depth in answer.items()]}}
        client = mock.Mock()
        payload = {"session": {"generation": 1},
                   "result": {"format": "symbol-query-batch", "version": 1, "results": [result]}}
        client.call.return_value = payload, {"ipc_seconds": 1}
        self.assertTrue(BENCH.query(client, "cartograph", self.config, self.graph, 1)["grade"]["passed"])
        result["result"]["truncated"]["dependsOn"] = True
        with self.assertRaisesRegex(ValueError, "truncation"):
            BENCH.query(client, "cartograph", self.config, self.graph, 1)

    def test_byte_and_admission_guards_fail_closed(self):
        self.config["index_fingerprint"] = BENCH.BASE.fingerprint(Path(self.config["store"]))
        path = Path(self.config["cg_config"])
        self.config["hashes"] = {str(path): BENCH.BASE.sha256(path)}
        with mock.patch.object(BENCH.PROJECT, "verify_sources"):
            self.assertTrue(BENCH.verify_bytes(self.config)["source_index_and_config_bytes_unchanged"])
            path.write_text("exclude: [**]\n")
            with self.assertRaisesRegex(ValueError, "Admitted file changed"):
                BENCH.verify_bytes(self.config)
            (Path(self.config["store"]) / "added").write_bytes(b"new")
            with self.assertRaisesRegex(ValueError, "Index bytes changed"):
                BENCH.verify_bytes(self.config)
        report = self.root / "results.json"
        BENCH.BASE.save(report, {"status": "baseline_only", "validation_passed": True})
        with self.assertRaisesRegex(ValueError, "successful full"):
            BENCH.admit(report, self.root / "out", 1)

    def test_oracle_and_generation_mismatches_fail(self):
        for payload, message in [({"session": {"generation": 2}, "answers": {}}, "generation"),
                                 ({"session": {"generation": 1}, "answers": {}}, "oracle")]:
            client = mock.Mock()
            client.call.return_value = (payload, {"ipc_seconds": 1})
            with self.assertRaisesRegex(ValueError, message):
                BENCH.query(client, "baseline", self.config, self.graph, 1)


if __name__ == "__main__":
    unittest.main()
