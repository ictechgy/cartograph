#!/usr/bin/env python3
"""Exercise background MCP preparation against a compiled, synthetic Swift package.

Native cancellation timing is observational; deterministic late-result/deadline races
are tested by MCPPreparationTests. This fixture makes no private-app speedup claim.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time


CAP = 1_048_576


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


class Peer:
    def __init__(self, binary: Path, package: Path, output: Path, mode: str, extra_arguments=None):
        self.output = output
        self.process = subprocess.Popen(
            [str(binary), "serve", "--project", str(package), "--session-freshness-interval", "0",
             "--limitations", mode] + list(extra_arguments or []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # 전체 실행은 외부 supervisor의 소유 프로세스 그룹 안에 머문다.
        self.selector = selectors.DefaultSelector()
        for name in ("stdout", "stderr"):
            pipe = getattr(self.process, name)
            os.set_blocking(pipe.fileno(), False)
            self.selector.register(pipe, selectors.EVENT_READ, name)
        self.buffers = {"stdout": bytearray(), "stderr": bytearray()}
        self.counts = {"stdout": 0, "stderr": 0}
        self.steps = []
        self.sequence = 0
        self.closed = False

    def request(self, method: str, params: dict, timeout: float = 5) -> dict:
        self.sequence += 1
        message = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        payload = (json.dumps(message) + "\n").encode()
        require(len(payload) < 4096, "request exceeds bounded write size")
        started = time.monotonic()
        self.process.stdin.write(payload)
        self.process.stdin.flush()
        deadline = started + timeout
        while b"\n" not in self.buffers["stdout"]:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "MCP response deadline exceeded")
            events = self.selector.select(remaining)
            require(bool(events), "MCP response deadline exceeded")
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), min(65536, CAP - self.counts[key.data] + 1))
                if not chunk:
                    self.selector.unregister(key.fileobj)
                    require(key.data != "stdout", "MCP stdout closed before response")
                    continue
                self.counts[key.data] += len(chunk)
                require(self.counts[key.data] <= CAP, "MCP stream budget exceeded")
                self.buffers[key.data].extend(chunk)
        line, _, rest = self.buffers["stdout"].partition(b"\n")
        self.buffers["stdout"] = bytearray(rest)
        response = json.loads(line)
        require(response.get("id") == self.sequence, "response identity mismatch")
        self.steps.append({"method": method, "params": params, "response": response,
                           "wallSeconds": time.monotonic() - started})
        save(self.output / "steps.json", self.steps)
        return response

    def call(self, name: str, arguments: dict) -> tuple[dict, bool]:
        response = self.request("tools/call", {"name": name, "arguments": arguments})
        require("result" in response, "MCP protocol error")
        result = response["result"]
        content = result.get("structuredContent")
        if content is None:
            content = json.loads(result["content"][0]["text"])
        return content, bool(result.get("isError"))

    def prepare(self, **arguments) -> tuple[dict, bool]:
        return self.call("cartograph_prepare", arguments)

    def settled(self, timeout: float = 60) -> tuple[dict, bool]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status, failed = self.prepare(action="status")
            require("percent" not in status and "progressPercent" not in status, "fabricated percentage")
            require(status["inputFreshness"] == "not-rechecked-by-status", "cached status claims input recheck")
            if not status["workerActive"]:
                return status, failed
            time.sleep(0.05)
        raise RuntimeError("preparation did not settle within fixture deadline")

    def close(self) -> None:
        self.process.stdin.close()
        try:
            code = self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            # 이 Popen의 직접 자식만 중단한다. 외부 supervisor가 전체 소유 그룹을 관리한다.
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            raise RuntimeError("MCP server required termination after EOF")
        finally:
            (self.output / "serve.stderr").write_bytes(self.buffers["stderr"])
            self.selector.close()
            self.process.stdout.close()
            self.process.stderr.close()
        require(code == 0, "MCP server failed during EOF shutdown")
        self.closed = True


def worker(args) -> int:
    output = args.output_dir.resolve()
    peer = Peer(args.cartograph.resolve(), output.parent / "package", output, args.mode)
    result = {"status": "failed", "mode": args.mode, "scope": "synthetic compiled Swift package",
              "nativeCancellation": "race observation only; deterministic cancellation uses Swift unit tests"}
    try:
        peer.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                    "clientInfo": {"name": "followup-mcp", "version": "1"}})
        peer.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        peer.process.stdin.flush()
        listed = peer.request("tools/list", {})
        require("cartograph_prepare" in {item["name"] for item in listed["result"]["tools"]},
                "MCP readiness tool missing")
        idle, failed = peer.prepare(action="status")
        require(idle["state"] == "idle" and not failed and idle["preparationGeneration"] == 0,
                "cold status unexpectedly prepared a session")
        first, failed = peer.prepare(action="start", timeoutSeconds=60)
        require(first["state"] == "queued" and not failed and first["workerActive"], "start did not return queued")
        cancelled, _ = peer.prepare(action="cancel", generation=first["preparationGeneration"])
        require(cancelled["state"] in {"cancelled", "ready"}, "unexpected native cancellation race")
        result["nativeCancellationObserved"] = cancelled["state"]
        settled, failed = peer.settled()
        require(settled["state"] in {"cancelled", "ready"} and not failed, "initial preparation failed")
        preparation_started = time.monotonic()
        restarted, failed = peer.prepare(action="start", timeoutSeconds=60)
        require(restarted["preparationGeneration"] == first["preparationGeneration"] + 1 and not failed,
                "settled generation was not replaced")
        ready, failed = peer.settled()
        result["backgroundPreparationObservedWallSeconds"] = time.monotonic() - preparation_started
        result["backgroundPreparationTimingScope"] = "start round-trip through observed readiness; includes polling delay"
        require(ready["state"] == "ready" and not failed and ready["session"]["nodeCount"] > 0,
                "compiled package was not prepared")
        query, failed = peer.call("cartograph_query", {"symbols": ["Root"]})
        require(not failed and query["result"]["results"][0]["status"] == "found", "prepared query failed")
        require(query["session"]["generation"] == ready["session"]["generation"], "unchanged query reloaded")
        status, failed = peer.call("cartograph_status", {})
        require(not failed and status["generation"] == ready["session"]["generation"], "legacy status changed")
        require(bool(ready["limitations"]), "readiness omitted safety limitation")
        require(("limitationSummary" in ready) == (args.mode == "summary"), "presentation mode mismatch")
        result["ready"] = ready
        result["query"] = query
        result["status"] = "passed"
    finally:
        try:
            peer.close()
        finally:
            result["ownedServerClosed"] = peer.closed
            if not peer.closed:
                result["status"] = "failed"
            save(output / "result.json", result)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--mode", choices=("full", "summary"), default="full")
    args = parser.parse_args()
    if args.worker:
        return worker(args)
    require(sys.platform == "darwin", "native fixture requires macOS and Swift")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    package = output / "package"
    source = package / "Sources" / "Tiny"
    source.mkdir(parents=True)
    (package / "Package.swift").write_text('// swift-tools-version: 6.0\nimport PackageDescription\n'
        'let package = Package(name: "Tiny", targets: [.executableTarget(name: "Tiny")])\n', encoding="utf-8")
    (source / "main.swift").write_text('struct Root { func run() { print("ready") } }\nRoot().run()\n', encoding="utf-8")
    base = load("mcp_preparation_supervisor", Path(__file__).with_name("benchmark-indexstore-cli.py"))
    with args.cartograph.open("rb") as binary:
        binary_sha = hashlib.file_digest(binary, "sha256").hexdigest()
    evidence = {"status": "failed", "scope": "synthetic compiled Swift package",
                "binarySHA256": binary_sha,
                "preparationCostIncludesBuild": True, "commands": []}
    try:
        evidence["commands"].append(base.run(["swift", "build", "--package-path", str(package)],
            package, output / "build", 180, stream_limit=CAP))
        for mode in ("full", "summary"):
            directory = output / mode
            directory.mkdir()
            evidence["commands"].append(base.run([sys.executable, str(Path(__file__).resolve()),
                "--cartograph", str(args.cartograph.resolve()), "--output-dir", str(directory),
                "--worker", "--mode", mode], output, output / (mode + "-worker"), 150, stream_limit=CAP))
        evidence["status"] = "passed"
    finally:
        save(output / "followup-mcp-preparation.json", evidence)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
