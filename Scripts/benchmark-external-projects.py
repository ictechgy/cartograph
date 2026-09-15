#!/usr/bin/env python3
"""Collect reproducible external-project scan and semantic-query evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import select
import shutil
import subprocess
import time
from pathlib import Path


PROJECTS = {
    "alamofire": {"include": ["Source/**"], "excludeTargets": []},
    "kingfisher": {"include": ["Sources/**"], "excludeTargets": []},
    "argument-parser": {
        "include": ["Sources/ArgumentParser/**", "Sources/ArgumentParserToolInfo/**"],
        "excludeTargets": [
            "ArgumentParserTestHelpers", "roll", "math", "repeat", "color", "default-as-flag",
            "generate-docc-reference", "generate-manual", "count-lines", "changelog-authors",
        ],
    },
}


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def run(command, cwd, stem, timeout=300):
    started = time.perf_counter()
    try:
        process = subprocess.run(command, cwd=cwd, capture_output=True, timeout=timeout)
        result = {"command": command, "exit": process.returncode,
                  "seconds": time.perf_counter() - started}
        stdout, stderr = process.stdout, process.stderr
    except subprocess.TimeoutExpired as error:
        result = {"command": command, "exit": None, "timeout": timeout,
                  "seconds": time.perf_counter() - started}
        stdout, stderr = error.stdout or b"", error.stderr or b""
    stem.parent.mkdir(parents=True, exist_ok=True)
    stem.with_suffix(".stdout").write_bytes(stdout)
    stem.with_suffix(".stderr").write_bytes(stderr)
    result["stdoutBytes"] = len(stdout)
    result["stdoutSHA256"] = hashlib.sha256(stdout).hexdigest()
    save(stem.with_suffix(".json"), result)
    if result["exit"] != 0:
        raise RuntimeError(f"Command failed or timed out (exit {result['exit']}); inspect {stem}.json")
    return result, stdout


class LSPClient:
    """Use the installed language server and synchronize its normal background index."""

    def __init__(self, project, log, timeout=240, command=None):
        self.log = log.open("wb")
        self.process = subprocess.Popen(
            command or ["sourcekit-lsp"], cwd=project, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.log,
        )
        self.buffer = bytearray()
        self.sequence = 0
        self.timeout = timeout
        self.transcript = []

    def send(self, value):
        encoded = json.dumps(value).encode()
        self.process.stdin.write(f"Content-Length: {len(encoded)}\r\n\r\n".encode() + encoded)
        self.process.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def receive(self, deadline):
        while True:
            if b"\r\n\r\n" in self.buffer:
                header, body = self.buffer.split(b"\r\n\r\n", 1)
                length = next(int(line.split(b":", 1)[1]) for line in header.split(b"\r\n")
                              if line.lower().startswith(b"content-length:"))
                if len(body) >= length:
                    self.buffer = bytearray(body[length:])
                    return json.loads(body[:length])
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise TimeoutError("SourceKit-LSP response timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("SourceKit-LSP closed stdout")
            self.buffer.extend(chunk)

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        started = time.perf_counter()
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + self.timeout
        while True:
            response = self.receive(deadline)
            if "method" in response:
                if "id" in response:
                    answer = None
                    if response["method"] == "workspace/configuration":
                        answer = [None for _ in response.get("params", {}).get("items", [])]
                    self.send({"jsonrpc": "2.0", "id": response["id"], "result": answer})
                continue
            if response.get("id") == request_id:
                record = {"method": method, "params": params, "response": response,
                          "seconds": time.perf_counter() - started}
                self.transcript.append(record)
                if "error" in response:
                    raise RuntimeError(f"{method} returned JSON-RPC error {response['error'].get('code')}")
                if isinstance(response.get("result"), dict) and response["result"].get("isError"):
                    raise RuntimeError(f"{method} returned an MCP tool error; inspect the transcript")
                return record

    def initialize(self, project):
        response = self.request("initialize", {
            "processId": os.getpid(), "rootUri": project.as_uri(),
            "capabilities": {"workspace": {"configuration": True}},
            "workspaceFolders": [{"uri": project.as_uri(), "name": project.name}],
            "initializationOptions": {"backgroundIndexing": True},
        })
        if "error" in response["response"]:
            raise RuntimeError(f"LSP initialization failed: {response}")
        self.notify("initialized", {})
        return self.request("workspace/synchronize", {"index": True})

    def open_file(self, path):
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": path.as_uri(), "languageId": "swift", "version": 1, "text": path.read_text(),
        }})

    def close(self):
        try:
            if self.process.poll() is None:
                self.request("shutdown", None)
                self.notify("exit", {})
                self.process.stdin.close()
                self.process.wait(timeout=10)
        except (TimeoutError, subprocess.TimeoutExpired, BrokenPipeError, RuntimeError):
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        finally:
            self.log.close()


class MCPClient(LSPClient):
    """Reuse bounded process I/O with MCP's JSON-lines framing."""

    def __init__(self, project, config, log):
        super().__init__(project, log, command=["cartograph", "serve", *cartograph_args(project, config)])

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise TimeoutError("MCP response timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("MCP closed stdout")
            self.buffer.extend(chunk)
        line, _, remainder = self.buffer.partition(b"\n")
        self.buffer = bytearray(remainder)
        return json.loads(line)

    def request(self, method, params):
        return super().request(method, {"_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
        }, **params})

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        finally:
            self.log.close()


def cartograph_args(project, config):
    return ["--project", str(project), "--index-store", str(project / ".build/out"),
            "--include", *config["include"]]


def prepare(root, output, manifest):
    metadata = json.loads(manifest.read_text())
    root.mkdir(parents=True, exist_ok=True)
    for name, details in metadata["repos"].items():
        if name not in PROJECTS:
            raise ValueError(f"Unknown benchmark project: {name}")
        project = root / name
        if project.exists():
            raise FileExistsError(f"Use a fresh evaluation directory; project already exists: {name}")
        project.mkdir()
        commands = [
            ["git", "init", "--quiet"],
            ["git", "remote", "add", "origin", details["url"]],
            ["git", "fetch", "--depth", "1", "origin", details["revision"]],
            ["git", "checkout", "--detach", "FETCH_HEAD"],
            ["swift", "build", "-j", "4", *([] if name == "kingfisher" else ["--build-tests"])],
        ]
        for index, command in enumerate(commands):
            result, _ = run(command, project, output / f"{name}-prepare-{index}")
            if result["exit"] != 0:
                raise RuntimeError(f"Project preparation failed; inspect {name}-prepare-{index}")
    for filename in ["tasks.json", "oracle-frozen.json", "metadata.json"]:
        shutil.copyfile(manifest.parent / filename, root.parent / filename)


def validate_inputs(root):
    metadata = json.loads((root.parent / "metadata.json").read_text())
    commands = {"cartographVersion": ["cartograph", "--version"],
                "peripheryVersion": ["periphery", "version"], "swiftVersion": ["swift", "--version"],
                "rgVersion": ["rg", "--version"]}
    actual = {}
    for key, command in commands.items():
        actual[key] = subprocess.check_output(command, stderr=subprocess.PIPE, text=True).strip()
        if actual[key] != metadata[key]:
            raise ValueError(f"Tool version differs from the frozen manifest: {key}")
    binaries = {}
    for tool in ["cartograph", "periphery", "sourcekit-lsp", "rg"]:
        resolved = (subprocess.check_output(["xcrun", "--find", tool], text=True).strip()
                    if tool == "sourcekit-lsp" else shutil.which(tool))
        path = Path(resolved).resolve()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        expected = metadata.get("binarySHA256", {}).get(tool)
        if expected is not None and digest != expected:
            raise ValueError(f"Executable differs from the frozen manifest: {tool}")
        binaries[tool] = {"path": str(path), "sha256": digest}
    for name, details in metadata["repos"].items():
        project = root / name
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project, text=True).strip()
        if revision != details["revision"]:
            raise ValueError(f"Project revision differs from the frozen manifest: {name}")
        if subprocess.run(["git", "diff", "HEAD", "--quiet"], cwd=project).returncode != 0:
            raise ValueError(f"Tracked project content differs from the frozen commit: {name}")
    return {"versions": actual, "binaries": binaries, "revisionsAndTrackedSourcesVerified": True}


def scans(root, output, samples, selected_projects):
    for name, config in PROJECTS.items():
        if selected_projects and name not in selected_projects:
            continue
        project = root / name
        common = cartograph_args(project, config)
        periphery = [
            "periphery", "scan", "--project-root", str(project), "--index-store-path",
            str(project / ".build/out"), "--exclude-tests", "--retain-public",
            "--retain-objc-accessible", "--retain-swift-ui-previews", "--retain-codable-properties",
            "--retain-encodable-properties", "--disable-redundant-public-analysis",
            "--disable-unused-import-analysis", "--disable-update-check", "--quiet", "--format", "json",
        ]
        if config["excludeTargets"]:
            periphery += ["--exclude-targets", *config["excludeTargets"]]
            periphery += ["--index-exclude", "**/*?.build/**/*", "**/SourcePackages/checkouts/**",
                          str(project / "Tools/**"), str(project / "Examples/**"),
                          str(project / "Sources/ArgumentParserTestHelpers/**")]
        commands = {
            "cartograph": ["cartograph", "dead", *common, "--retain-public", "--report-format", "json"],
            "periphery": [*periphery, "--retain-assign-only-properties"],
        }
        for sample in range(samples):
            order = list(commands) if sample % 2 == 0 else list(reversed(commands))
            for tool in order:
                result, _ = run(commands[tool], project, output / f"{name}-{tool}-{sample}")
                print(json.dumps({"project": name, "tool": tool, "sample": sample, **result}), flush=True)
        run(periphery, project, output / f"{name}-periphery-assign-only")
        result, _ = run(["cartograph", "graph", *common, "--level", "symbol", "--format", "json"],
                        project, output / f"{name}-graph")
        print(json.dumps({"project": name, "tool": "graph", **result}), flush=True)


def queries(root, output, tasks, samples):
    for name, config in PROJECTS.items():
        project = root / name
        selected = [task for task in tasks if task["project"] == name]
        if not selected:
            continue
        client = LSPClient(project, output / f"{name}-lsp.stderr")
        try:
            ready = client.initialize(project)
            if "error" in ready["response"]:
                raise RuntimeError(f"LSP readiness failed: {ready}")
            for task in selected:
                path = project / task["target"]["path"]
                client.open_file(path)
                point = {"textDocument": {"uri": path.as_uri()}, "position": {
                    "line": task["target"]["line"] - 1, "character": task["target"]["column"] - 1,
                }}
                for sample in range(samples):
                    result = client.request("textDocument/references", {**point, "context": {"includeDeclaration": False}})
                    save(output / f"{task['id']}-lsp-references-{sample}.json", result)
                    hierarchy = client.request("textDocument/prepareCallHierarchy", point)
                    save(output / f"{task['id']}-lsp-prepare-{sample}.json", hierarchy)
                    if not hierarchy["response"].get("result"):
                        raise RuntimeError(f"LSP could not resolve the frozen target: {task['id']}")
                    incoming = [client.request("callHierarchy/incomingCalls", {"item": item})
                                for item in hierarchy["response"].get("result") or []]
                    save(output / f"{task['id']}-lsp-incoming-{sample}.json", incoming)
                client.notify("textDocument/didClose", {"textDocument": {"uri": path.as_uri()}})
        finally:
            save(output / f"{name}-lsp-transcript.json", client.transcript)
            client.close()
        for task in selected:
            for sample in range(samples):
                run(["cartograph", "impact", task["target"]["usr"], *cartograph_args(project, config),
                     "--depth", "1", "--limit", "1000", "--format", "json"],
                    project, output / f"{task['id']}-cartograph-{sample}")
                run(["rg", "--json", "-w", "-F", task["target"]["token"], "--glob", "*.swift",
                     *[pattern.removesuffix("/**") for pattern in config["include"]]],
                    project, output / f"{task['id']}-rg-{sample}")


def mcp_queries(root, output, tasks, samples):
    for name, config in PROJECTS.items():
        selected = [task for task in tasks if task["project"] == name]
        if not selected:
            continue
        client = MCPClient(root / name, config, output / f"{name}-mcp.stderr")
        try:
            client.request("server/discover", {})
            client.request("tools/list", {})
            client.request("tools/call", {"name": "cartograph_status", "arguments": {}})
            client.request("tools/call", {"name": "cartograph_impact", "arguments": {
                "symbols": [selected[0]["target"]["usr"]], "depth": 1, "limit": 1000,
            }})
            save(output / f"{name}-mcp-preparation.json", client.transcript)
            for task in selected:
                for sample in range(samples):
                    result = client.request("tools/call", {"name": "cartograph_impact", "arguments": {
                        "symbols": [task["target"]["usr"]], "depth": 1, "limit": 1000,
                    }})
                    save(output / f"{task['id']}-mcp-{sample}.json", result)
                    response = result["response"]
                    if "error" in response or response.get("result", {}).get("isError"):
                        raise RuntimeError(f"MCP impact failed: {response}")
        finally:
            save(output / f"{name}-mcp-transcript.json", client.transcript)
            client.close()


def symbol_queries(root, output, tasks, samples):
    summary = []
    for name, config in PROJECTS.items():
        selected = [task for task in tasks if task["project"] == name]
        if not selected:
            continue
        project = root / name
        client = MCPClient(project, config, output / f"{name}-mcp.stderr")
        try:
            client.request("server/discover", {})
            client.request("tools/call", {"name": "cartograph_query", "arguments": {
                "symbols": [selected[0]["target"]["usr"]], "depth": 1, "limit": 1000,
            }})
            for task in selected:
                records, documents = [], []
                for sample in range(samples):
                    metadata, data = run(["cartograph", "query", task["target"]["usr"],
                        *cartograph_args(project, config), "--depth", "1", "--limit", "1000"],
                        project, output / f"{task['id']}-query-cli-{sample}")
                    cli = json.loads(data)
                    response = client.request("tools/call", {"name": "cartograph_query", "arguments": {
                        "symbols": [task["target"]["usr"]], "depth": 1, "limit": 1000,
                    }})
                    save(output / f"{task['id']}-query-mcp-{sample}.json", response)
                    mcp = response["response"]["result"]["structuredContent"]["result"]["results"][0]
                    if cli != mcp or cli["status"] != "found":
                        raise RuntimeError(f"Symbol-query CLI/MCP results differ: {task['id']}")
                    documents.append(cli)
                    records.append({"cliMs": metadata["seconds"] * 1000,
                                    "mcpMs": response["seconds"] * 1000, "bytes": len(data)})
                if any(document != documents[0] for document in documents):
                    raise RuntimeError(f"Symbol-query result changed: {task['id']}")
                summary.append({"id": task["id"], "samples": records, "stableAndEqual": True,
                    "usedBy": [{"path": str(Path(value["location"]["path"]).relative_to(project)),
                                "line": value["location"]["line"]} for value in documents[0]["result"]["usedBy"]]})
        finally:
            save(output / f"{name}-mcp-transcript.json", client.transcript)
            client.close()
    save(output / "summary.json", summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "scans", "queries", "mcp", "symbol-queries"])
    parser.add_argument("--repos", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tasks", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--project", action="append", choices=list(PROJECTS))
    args = parser.parse_args()
    if args.samples < 3:
        parser.error("at least three samples are required")
    args.output.mkdir(parents=True, exist_ok=True)
    if args.mode != "prepare":
        save(args.output / "verified-inputs.json", validate_inputs(args.repos.resolve()))
    if args.mode == "prepare":
        if not args.manifest:
            parser.error("prepare requires --manifest")
        prepare(args.repos.resolve(), args.output.resolve(), args.manifest.resolve())
    elif args.mode == "scans":
        scans(args.repos.resolve(), args.output.resolve(), args.samples, args.project)
    else:
        if not args.tasks:
            parser.error("queries require --tasks")
        operation = {"queries": queries, "mcp": mcp_queries, "symbol-queries": symbol_queries}[args.mode]
        operation(args.repos.resolve(), args.output.resolve(), json.loads(args.tasks.read_text()), args.samples)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
