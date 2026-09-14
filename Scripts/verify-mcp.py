#!/usr/bin/env python3
"""Exercise the Cartograph MCP stdio server with a real temporary Swift package."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


MAX_LINE = 1_048_576
VERSION = "2026-07-28"


def request(request_id: int | str | None, method: str, params: dict[str, Any] | None = None) -> bytes:
    value: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
    if request_id is not None:
        value["id"] = request_id
    if params is not None:
        value["params"] = params
    return (json.dumps(value, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def modern_params(**extra: Any) -> dict[str, Any]:
    value: dict[str, Any] = {
        "_meta": {
            "io.modelcontextprotocol/protocolVersion": VERSION,
            "io.modelcontextprotocol/clientCapabilities": {},
        }
    }
    value.update(extra)
    return value


class MCPProcess:
    def __init__(self, binary: Path, project: Path, stderr_path: Path, extra_arguments: list[str] | None = None):
        self.process = subprocess.Popen(
            [str(binary), "serve", "--project", str(project)] + (extra_arguments or []),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr_path.open("wb"),
            start_new_session=True,
        )
        self.selector = selectors.DefaultSelector()
        assert self.process.stdout is not None
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()

    def send(self, payload: bytes) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(payload)
        self.process.stdin.flush()

    def receive(self, timeout: float = 10.0) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError("timed out waiting for MCP response")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("MCP server closed stdout before responding")
            self.buffer.extend(chunk)
        line, _, rest = self.buffer.partition(b"\n")
        self.buffer = bytearray(rest)
        return json.loads(line)

    def request(self, request_id: int | str, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self.send(request(request_id, method, params))
        response = self.receive()
        assert response is not None
        return response

    def close(self) -> int:
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            return self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            return self.process.wait(timeout=5)


def run(command: list[str], timeout: int = 120) -> tuple[int, str, str, float]:
    started = time.perf_counter()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise RuntimeError(f"command timed out: {command}")
    return process.returncode, stdout, stderr, time.perf_counter() - started


def write_package(root: Path) -> Path:
    source = root / "Sources" / "Tiny"
    source.mkdir(parents=True)
    (root / "Package.swift").write_text(
        "// swift-tools-version: 6.0\n"
        "import PackageDescription\n"
        "let package = Package(name: \"Tiny\", targets: [.executableTarget(name: \"Tiny\")])\n"
    )
    path = source / "main.swift"
    path.write_text("struct Root { func run() { print(\"ready\") } }\nRoot().run()\n")
    return path


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def legacy_payload(response: dict[str, Any]) -> dict[str, Any]:
    result = response["result"]
    assert_true("structuredContent" not in result, "legacy result duplicated its JSON payload")
    assert_true(len(result["content"]) == 1 and result["content"][0]["type"] == "text", "legacy result lacks JSON text")
    return json.loads(result["content"][0]["text"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--timeout", type=float, default=15)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-mcp-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    stderr_path = output / "serve.stderr.log"
    package = Path(tempfile.mkdtemp(prefix="cartograph-mcp-package-"))
    source_path = write_package(package)
    processes: list[MCPProcess] = []
    evidence: dict[str, Any] = {"output": str(output), "package": str(package), "steps": []}

    def build(name: str) -> None:
        status, stdout, stderr, elapsed = run(["swift", "build", "--package-path", str(package)], timeout=180)
        (output / (name + ".stdout.log")).write_text(stdout)
        (output / (name + ".stderr.log")).write_text(stderr)
        assert_true(status == 0, f"{name} failed; see build logs")
        evidence["steps"].append({name + "Ms": round(elapsed * 1000, 2)})

    try:
        legacy = MCPProcess(binary, package, output / "legacy.stderr.log")
        processes.append(legacy)
        started = time.perf_counter()
        initialize = legacy.request(1, "initialize", {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "verify-mcp", "version": "1"},
        })
        evidence["steps"].append({"legacyInitializeMs": round((time.perf_counter() - started) * 1000, 2)})
        assert_true(initialize["result"]["protocolVersion"] == "2025-11-25", "legacy negotiation failed")
        legacy.send(request(None, "notifications/initialized"))
        listed = legacy.request(2, "tools/list")
        assert_true(len(listed["result"]["tools"]) == 5, "legacy tools/list did not expose five tools")
        legacy.send(request(3, "tools/call", {"name": "cartograph_query", "arguments": {"symbols": ["Root"]}}))
        failed = legacy.receive(timeout=args.timeout)
        assert_true(failed is not None and failed["result"]["isError"], "missing-index query did not return tool error")
        assert_true(legacy.process.poll() is None, "server exited after missing-index tool error")
        build("initial-build")
        success = legacy.request(4, "tools/call", {"name": "cartograph_query", "arguments": {"symbols": ["Root"]}})
        assert_true(not success["result"]["isError"], "query did not recover after build")
        payload = legacy_payload(success)
        assert_true(payload["result"]["results"][0]["status"] == "found", "query did not find Root")
        generation = payload["session"]["generation"]
        repeated = legacy.request(5, "tools/call", {"name": "cartograph_query", "arguments": {"symbols": ["Root"]}})
        assert_true(legacy_payload(repeated)["session"]["generation"] == generation, "session was not reused")
        source_path.write_text(source_path.read_text() + "struct Added {}\n")
        stale = legacy.request(6, "tools/call", {"name": "cartograph_query", "arguments": {"symbols": ["Root"]}})
        stale_session = legacy_payload(stale)["session"]
        assert_true(stale_session["generation"] > generation, "source edit did not refresh session")
        assert_true(any("index-staleness" in item for item in stale_session["limitations"]), "staleness was not reported")
        build("refresh-build")
        fresh = legacy.request(7, "tools/call", {"name": "cartograph_query", "arguments": {"symbols": ["Root"]}})
        fresh_limits = legacy_payload(fresh)["session"]["limitations"]
        assert_true(not any("index-staleness" in item for item in fresh_limits), "rebuild did not clear staleness")
        legacy.send(request(None, "notifications/unknown", {}))
        assert_true(legacy.request(8, "ping", {})["result"] == {}, "notification disturbed next request")
        legacy.send(b"{broken\n")
        assert_true(legacy.receive()["error"]["code"] == -32700, "malformed JSON was not rejected")
        oversized = b"x" * (MAX_LINE + 1) + b"\n" + request(9, "ping", {})
        legacy.send(oversized)
        oversize_error = legacy.receive(timeout=args.timeout)
        ping = legacy.receive(timeout=args.timeout)
        assert_true(oversize_error["error"]["code"] == -32600 and ping["id"] == 9, "oversize recovery failed")
        evidence["legacy"] = {"generation": generation, "staleGeneration": stale_session["generation"]}
        assert_true(legacy.close() == 0, "legacy server did not exit cleanly at EOF")
        processes.remove(legacy)

        modern = MCPProcess(binary, package, stderr_path)
        processes.append(modern)
        discovered = modern.request(1, "server/discover", modern_params())
        assert_true(discovered["result"]["resultType"] == "complete", "modern discover is incomplete")
        assert_true("io.modelcontextprotocol/serverInfo" in discovered["result"]["_meta"], "discover metadata key is wrong")
        assert_true("instructions" in discovered["result"], "discover instructions are missing")
        missing_meta = modern.request(2, "ping", {})
        assert_true(missing_meta["error"]["code"] == -32602, "modern metadata omission was accepted")
        modern_query = modern.request(3, "tools/call", modern_params(
            name="cartograph_query", arguments={"symbols": ["Root"]}
        ))
        assert_true("structuredContent" in modern_query["result"], "modern tool response lacks structured content")
        assert_true(modern_query["result"]["structuredContent"]["result"]["format"] == "symbol-query-batch", "query v1 was not nested intact")
        runtime_discovery = modern.request(4, "tools/call", modern_params(
            name="cartograph_runtime_discover", arguments={"limit": 1}
        ))
        runtime_payload = runtime_discovery["result"]["structuredContent"]
        assert_true(
            runtime_payload["result"]["format"] == "runtime-discovery",
            "runtime discovery was not nested intact",
        )
        query_generation = modern_query["result"]["structuredContent"]["session"]["generation"]
        assert_true(
            runtime_payload["session"]["generation"] == query_generation,
            "runtime discovery did not reuse the query generation",
        )
        assert_true(not runtime_discovery["result"]["isError"], "analyzed runtime discovery was marked as a tool error")
        modern.send(request(None, "ping", modern_params()))
        assert_true(modern.close() == 0, "modern server did not exit cleanly at EOF")
        processes.remove(modern)
        evidence["status"] = "passed"
        (output / "result.json").write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps(evidence, indent=2, ensure_ascii=False))
        return 0
    except Exception as error:
        evidence["status"] = "failed"
        evidence["error"] = str(error)
        (output / "result.json").write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps(evidence, indent=2, ensure_ascii=False), file=sys.stderr)
        return 1
    finally:
        for process in processes:
            try:
                process.close()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
