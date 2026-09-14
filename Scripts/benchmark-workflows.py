#!/usr/bin/env python3
"""Measure repeated CLI queries versus one cached MCP session and combined checks."""

from __future__ import annotations

import argparse
import json
import os
import platform
import select
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path
from typing import Any


VERSION = "2026-07-28"


def run(command: list[str], timeout: int = 300) -> tuple[int, str, str, float]:
    started = time.perf_counter()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise RuntimeError(f"command timed out: {command}")
    return process.returncode, stdout, stderr, time.perf_counter() - started


def mcp_request(request_id: int, method: str, **extra: Any) -> bytes:
    params = {
        "_meta": {
            "io.modelcontextprotocol/protocolVersion": VERSION,
            "io.modelcontextprotocol/clientCapabilities": {},
        }
    }
    params.update(extra)
    return (json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}, separators=(",", ":")) + "\n").encode()


class MCPClient:
    def __init__(self, binary: Path, project: Path, stderr_path: Path, timeout: int):
        self.process = subprocess.Popen(
            [str(binary), "serve", "--project", str(project)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr_path.open("wb"), start_new_session=True,
        )
        assert self.process.stdout is not None
        self.fd = self.process.stdout.fileno()
        self.buffer = bytearray()
        self.timeout = timeout

    def call(self, request_id: int, method: str, **extra: Any) -> dict[str, Any]:
        assert self.process.stdin is not None
        self.process.stdin.write(mcp_request(request_id, method, **extra))
        self.process.stdin.flush()
        deadline = time.monotonic() + self.timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("timed out waiting for MCP response")
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                raise RuntimeError("timed out waiting for MCP response")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise RuntimeError("MCP server closed stdout")
            self.buffer.extend(chunk)
        line, _, remainder = self.buffer.partition(b"\n")
        self.buffer = bytearray(remainder)
        return json.loads(line)

    def close(self) -> None:
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            self.process.wait(timeout=5)


def diagnostic_key(value: dict[str, Any]) -> tuple[Any, ...]:
    location = value.get("location") or {}
    return (
        value.get("ruleIdentifier"), value.get("severity"), value.get("message"), value.get("subject"),
        location.get("path"), location.get("line"), location.get("column"), tuple(value.get("details", [])),
    )


def parse_json(command: list[str], timeout: int = 300) -> tuple[dict[str, Any], float, int]:
    returncode, stdout, stderr, elapsed = run(command, timeout)
    if returncode not in (0, 1):
        raise RuntimeError(f"command failed ({returncode}): {' '.join(command)}\n{stderr[-1000:]}")
    try:
        parse_started = time.perf_counter()
        document = json.loads(stdout)
        return document, elapsed + time.perf_counter() - parse_started, returncode
    except json.JSONDecodeError as error:
        raise RuntimeError(f"command returned non-JSON output: {' '.join(command)}: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", required=True, type=Path)
    parser.add_argument("--project", type=Path, default=Path.cwd())
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--requests", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--min-query-speedup", type=float, default=2.0)
    parser.add_argument("--min-check-speedup", type=float, default=1.2)
    parser.add_argument("--max-warm-ms", type=float, default=250.0)
    args = parser.parse_args()
    if args.samples < 3 or args.requests < 1:
        parser.error("--samples must be at least 3 and --requests must be positive")
    if args.min_query_speedup < 2.0 or args.min_check_speedup < 1.2:
        parser.error("acceptance thresholds cannot be lowered")
    if args.max_warm_ms > 250.0:
        parser.error("--max-warm-ms cannot be relaxed above 250 ms")
    binary = args.cartograph.resolve()
    project = args.project.resolve()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-workflow-"))).resolve()
    if output == project or project in output.parents:
        parser.error("--output-dir must be outside the measured project")
    output.mkdir(parents=True, exist_ok=True)
    evidence: dict[str, Any] = {
        "binary": str(binary), "project": str(project), "samples": args.samples,
        "requests": args.requests, "output": str(output),
        "environment": {"platform": platform.platform()},
    }
    mcp: MCPClient | None = None
    try:
        version_code, version_out, _, _ = run([str(binary), "--version"], timeout=args.timeout)
        if version_code != 0:
            raise RuntimeError("could not read Cartograph version")
        evidence["version"] = version_out.strip()
        _, swift_version, _, _ = run(["swift", "--version"], timeout=args.timeout)
        evidence["environment"]["swift"] = swift_version.strip()
        graph, _, _ = parse_json([str(binary), "graph", "--level", "symbol", "--format", "json", "--project", str(project)], args.timeout)
        nodes = [node for node in graph.get("nodes", []) if node.get("usr")]
        if not nodes:
            raise RuntimeError("symbol graph contained no USRs")
        symbols = [node["usr"] for node in nodes[: args.requests]]
        evidence["graph"] = {"nodeCount": graph.get("nodeCount"), "edgeCount": graph.get("edgeCount"), "fileCount": len({(node.get("location") or {}).get("path") for node in graph.get("nodes", []) if (node.get("location") or {}).get("path")})}
        evidence["symbols"] = symbols

        startup_started = time.perf_counter()
        mcp = MCPClient(binary, project, output / "mcp.stderr.log", args.timeout)
        startup_seconds = time.perf_counter() - startup_started
        prep_started = time.perf_counter()
        discovered = mcp.call(1, "server/discover")
        listed = mcp.call(2, "tools/list")
        status_response = mcp.call(3, "tools/call", name="cartograph_status", arguments={})
        status_payload = status_response.get("result", {}).get("structuredContent", {})
        warm_mcp = mcp.call(4, "tools/call", name="cartograph_query", arguments={"symbols": [symbols[0]]})
        prep_seconds = time.perf_counter() - prep_started
        assert_true = lambda condition, message: (_ for _ in ()).throw(RuntimeError(message)) if not condition else None
        assert_true(discovered.get("result", {}).get("resultType") == "complete", "MCP discover failed")
        assert_true(len(listed.get("result", {}).get("tools", [])) >= 4, "MCP tools/list is incomplete")
        assert_true(not warm_mcp.get("result", {}).get("isError"), "MCP warm query failed")
        initial_session = status_payload
        evidence["mcpPreparation"] = {
            "startupSeconds": startup_seconds, "preparationSeconds": prep_seconds,
            "initialSession": initial_session,
        }

        # CLI warm-up is separate from the timed samples and has no artifact writes.
        parse_json([str(binary), "query", symbols[0], "--project", str(project)], args.timeout)
        cli_samples: list[float] = []
        cli_docs_samples: list[list[dict[str, Any]]] = []
        for sample in range(args.samples):
            started = time.perf_counter()
            docs = []
            for symbol in symbols:
                document, _, _ = parse_json([str(binary), "query", symbol, "--project", str(project)], args.timeout)
                docs.append(document)
            cli_samples.append(time.perf_counter() - started)
            cli_docs_samples.append(docs)

        mcp_samples: list[float] = []
        mcp_docs_samples: list[list[dict[str, Any]]] = []
        mcp_query_ms: list[float] = []
        session_stable = True
        for sample in range(args.samples):
            started = time.perf_counter()
            docs: list[dict[str, Any]] = []
            for index, symbol in enumerate(symbols):
                query_started = time.perf_counter()
                response = mcp.call(10_000 + sample * args.requests + index, "tools/call", name="cartograph_query", arguments={"symbols": [symbol]})
                mcp_query_ms.append((time.perf_counter() - query_started) * 1000)
                result = response.get("result", {})
                if result.get("isError"):
                    raise RuntimeError("MCP query returned isError")
                payload = result.get("structuredContent", {})
                batch = payload.get("result", {})
                if batch.get("format") != "symbol-query-batch":
                    raise RuntimeError("MCP query did not preserve query v1 document")
                document = batch["results"][0]
                docs.append(document)
            mcp_samples.append(time.perf_counter() - started)
            after = mcp.call(20_000 + sample, "tools/call", name="cartograph_status", arguments={})
            current_session = after.get("result", {}).get("structuredContent", {})
            session_stable = session_stable and current_session.get("generation") == initial_session.get("generation") and current_session.get("fingerprint") == initial_session.get("fingerprint")
            mcp_docs_samples.append(docs)

        for sample, docs in enumerate(cli_docs_samples):
            assert_true(docs == cli_docs_samples[0], f"CLI query result changed in sample {sample}")
        for sample, docs in enumerate(mcp_docs_samples):
            assert_true(docs == cli_docs_samples[0], f"MCP query result differs in sample {sample}")
        assert_true(session_stable, "MCP session generation or fingerprint changed during measurement")

        cli_median = statistics.median(cli_samples)
        mcp_median = statistics.median(mcp_samples)
        query_speedup = cli_median / mcp_median if mcp_median else float("inf")
        warm_median = statistics.median(mcp_query_ms)
        evidence["query"] = {"cliSeconds": cli_samples, "mcpSeconds": mcp_samples, "mcpQueryMs": mcp_query_ms, "cliMedian": cli_median, "mcpMedian": mcp_median, "mcpQueryMedianMs": warm_median, "speedup": query_speedup, "resultsEqual": True, "sessionStable": session_stable}

        individual_commands = [
            ("dead", ["dead", "--report-format", "json"]),
            ("cycles-module", ["cycles", "--level", "module", "--report-format", "json"]),
            ("cycles-type", ["cycles", "--level", "type", "--report-format", "json"]),
            ("rules", ["rules", "--report-format", "json"]),
        ]
        # 두 경로 모두 첫 실행의 파일·구문 캐시 준비를 측정에서 분리한다.
        for _, arguments in individual_commands:
            parse_json([str(binary)] + arguments + ["--project", str(project)], args.timeout)
        parse_json([str(binary), "check", "--report-format", "json", "--project", str(project)], args.timeout)
        individual_samples: list[float] = []
        individual_diagnostics_samples: list[Counter[tuple[Any, ...]]] = []
        for sample in range(args.samples):
            started = time.perf_counter()
            diagnostics: list[dict[str, Any]] = []
            for _, arguments in individual_commands:
                document, _, _ = parse_json([str(binary)] + arguments + ["--project", str(project)], args.timeout)
                diagnostics.extend(document.get("diagnostics", []))
            individual_samples.append(time.perf_counter() - started)
            individual_diagnostics_samples.append(Counter(diagnostic_key(item) for item in diagnostics))
        combined_samples: list[float] = []
        check_equal = True
        for sample in range(args.samples):
            document, elapsed, _ = parse_json([str(binary), "check", "--report-format", "json", "--project", str(project)], args.timeout)
            combined_samples.append(elapsed)
            check_equal = check_equal and Counter(diagnostic_key(item) for item in document.get("diagnostics", [])) == individual_diagnostics_samples[sample]
        check_speedup = statistics.median(individual_samples) / statistics.median(combined_samples)
        evidence["check"] = {"individualSeconds": individual_samples, "combinedSeconds": combined_samples, "speedup": check_speedup, "diagnosticsEqual": check_equal}
        final_status = mcp.call(30_000, "tools/call", name="cartograph_status", arguments={})
        final_session = final_status.get("result", {}).get("structuredContent", {})
        session_stable = session_stable and all(
            final_session.get(key) == initial_session.get(key) for key in ("generation", "fingerprint")
        )
        gates = {
            "querySpeedup": query_speedup >= args.min_query_speedup,
            "mcpWarmLatency": warm_median <= args.max_warm_ms,
            "sessionStable": session_stable,
            "queryResultsEqual": True,
            "checkSpeedup": check_speedup >= args.min_check_speedup,
            "checkDiagnosticsEqual": check_equal,
        }
        evidence["gates"] = gates
        if not all(gates.values()):
            raise RuntimeError("one or more benchmark acceptance gates failed: " + ", ".join(name for name, passed in gates.items() if not passed))
        evidence["status"] = "passed"
        (output / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps(evidence, indent=2))
        return 0
    except Exception as error:
        evidence["status"] = "failed"
        evidence["error"] = str(error)
        (output / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps(evidence, indent=2), file=sys.stderr)
        return 1
    finally:
        if mcp is not None:
            try:
                mcp.close()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
