#!/usr/bin/env python3
"""Measure Cartograph's differentiators on tasks competing tools cannot answer directly.

Each task runs every applicable arm (cartograph CLI/MCP, SourceKit-LSP, source search)
with wall-clock timing, saves complete raw output under raw/, and grades the result
against a frozen oracle. The scratch copy `ap-edit` is prepared by `--prepare-ap-edit`:
it snapshots the pinned argument-parser index, removes one `valueCompletion` call site,
and rebuilds so `impact --since/--before` has a real change to report.

Usage:
    benchmark-harder-tasks.py --prepare-ap-edit   # build the edited scratch copy once
    benchmark-harder-tasks.py                     # run all arms and write harder-results.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path

DESKTOP = Path.home() / "Desktop"
WORKSPACE = DESKTOP / "cartograph-evaluation-20260916"
PINNED = DESKTOP / "cartograph-evaluation-20260915" / "repos"
CARTOGRAPH = DESKTOP / "cartograph-competitive" / ".build" / "release" / "cartograph"

REPOS = {
    "alamofire": {"root": PINNED / "alamofire", "include": ["Source/**"]},
    "kingfisher": {"root": PINNED / "kingfisher", "include": ["Sources/**"]},
    "argument-parser": {
        "root": PINNED / "argument-parser",
        "include": ["Sources/ArgumentParser/**", "Sources/ArgumentParserToolInfo/**"],
    },
    "pigeon-host": {"root": WORKSPACE / "repos" / "pigeon-host", "include": ["Sources/**"]},
    "ap-edit": {
        "root": WORKSPACE / "repos" / "ap-edit",
        "include": ["Sources/ArgumentParser/**", "Sources/ArgumentParserToolInfo/**"],
    },
}


def save(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def run(command: list[str], cwd: Path, stem: Path, timeout: int = 300) -> dict:
    """Run one arm, capture complete output, and record wall time."""
    started = time.perf_counter()
    result = subprocess.run(
        command, cwd=cwd, capture_output=True, text=True, timeout=timeout
    )
    record = {
        "command": command,
        "exit": result.returncode,
        "seconds": round(time.perf_counter() - started, 4),
        "stdout": result.stdout,
        "stderr": result.stderr,
    }
    save(stem.with_suffix(".json"), record)
    return record


def cg_args(project: Path, include: list[str]) -> list[str]:
    return [
        "--project", str(project),
        "--index-store", str(project / ".build" / "out"),
        "--include", *include,
    ]


# --- bounded process clients (same framing as benchmark-external-projects.py) ---

class LSPClient:
    def __init__(self, project: Path, log: Path, timeout: int = 240, command=None):
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
                return record

    def initialize(self, project: Path):
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

    def open_file(self, path: Path):
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": path.as_uri(), "languageId": "swift", "version": 1,
            "text": path.read_text(),
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
    def __init__(self, project: Path, include: list[str], log: Path):
        super().__init__(project, log,
                         command=[str(CARTOGRAPH), "serve", *cg_args(project, include)])

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


# --- oracles ---------------------------------------------------------------

H1_GOLD = {
    "dev.flutter.pigeon.host.CameraApi.takePhoto": {
        "PigeonHost.audit(_:)", "PigeonHost.takePhoto(completion:)",
    },
    "dev.flutter.pigeon.host.CameraApi.switchCamera": {
        "PigeonHost.switchCamera(completion:)",
    },
}

H2_GOLD_DIRECT = {
    ("Source/Core/DataRequest.swift", 119),
    ("Source/Core/DownloadRequest.swift", 205),
    ("Source/Core/DataStreamRequest.swift", 146),
    ("Source/Core/WebSocketRequest.swift", 171),
}
H2_GOLD_TRANSITIVE = {("Source/Core/UploadRequest.swift", 110)}
H2_USR = "s:9Alamofire7RequestC4task3for5usingSo16NSURLSessionTaskC10Foundation10URLRequestV_So0F0CtF"
H2_LSP_POINT = ("Source/Core/Request.swift", 700, 10)

H5_GOLD_LINES = {421, 425}

AP_EDIT_FILE = "Sources/ArgumentParser/Completions/BashCompletionsGenerator.swift"
# 호출 지점 두 곳을 빈 문자열로 바꿔 `valueCompletion`을 선언만 남은 고립 헬퍼로 만든다.
AP_EDIT_CALLSITES = [
    ("\\(valueCompletion(arg).indentingEachLine(by: 8))", "\\(\"\")"),
    ("        let completion = valueCompletion(arg)\n", "        let completion = \"\"\n"),
]
AP_EDIT_CONSUMER_FILE = "Sources/ArgumentParser/Completions/CompletionsGenerator.swift"
# bashCompletionScript를 소비하던 유일한 외부 호출을 제거해 시드 파일의 소비자 사슬이
# 실제로 달라지게 한다.
AP_EDIT_CONSUMER = (
    "      return ToolInfoV0(commandStack: [command]).bashCompletionScript\n",
    "      return \"\"\n",
)


# --- task arms -------------------------------------------------------------

def h1_bridge_handlers(output: Path) -> dict:
    project = REPOS["pigeon-host"]["root"]
    record: dict = {"project": "pigeon-host", "arms": {}}

    cartograph = run([str(CARTOGRAPH), "bridges", "--target", "flutter", "--messages",
                      *cg_args(project, REPOS["pigeon-host"]["include"])],
                     project, output / "h1-cartograph")
    facts = json.loads(cartograph["stdout"]) if cartograph["exit"] == 0 else {}
    found = {}
    dynamic_facts = 0
    for fact in facts.get("facts", []):
        deps = fact.get("dependencies") or []
        handler = {d.get("symbol", {}).get("qualifiedName")
                   for d in deps if d.get("scope") == "handler"}
        if fact.get("channel", "").startswith("dev.flutter"):
            found[fact["channel"]] = handler
        else:
            dynamic_facts += 1
    record["arms"]["cartograph"] = {
        "seconds": cartograph["seconds"],
        "goldMatch": found == {k: v for k, v in H1_GOLD.items()},
        "handlerDeps": {k: sorted(v) for k, v in found.items()},
        "dynamicFactsPreserved": dynamic_facts,
        "limitations": facts.get("limitations", []),
    }

    search = run(["grep", "-rn", "CameraApi.takePhoto", "Sources/"],
                 project, output / "h1-search")
    sites = [line for line in search["stdout"].splitlines() if line.strip()]
    record["arms"]["source-search"] = {
        "seconds": search["seconds"],
        "sitesFound": len(sites),
        "boundsHandlerScope": False,
        "note": "locates the literal and call sites; the per-message callee set still needs reading",
    }

    lsp = LSPClient(project, output / "h1-lsp.stderr")
    try:
        lsp.initialize(project)
        setup_path = project / "Sources/PigeonHost/CameraApiSetup.swift"
        lsp.open_file(setup_path)
        point = {"textDocument": {"uri": setup_path.as_uri()},
                 "position": {"line": 5, "character": 24}}
        hierarchy = lsp.request("textDocument/prepareCallHierarchy", point)
        incoming = [lsp.request("callHierarchy/incomingCalls", {"item": item})
                    for item in hierarchy["response"].get("result") or []]
        save(output / "h1-lsp-incoming.json", incoming)
        callers = []
        for reply in incoming:
            for call in reply["response"].get("result") or []:
                callers.append(call.get("from", {}).get("name"))
        record["arms"]["sourcekit-lsp"] = {
            "seconds": sum(r["seconds"] for r in [hierarchy, *incoming]),
            "incomingCallers": callers,
            "boundsHandlerScope": False,
            "note": "callHierarchy reaches the registration caller, not a bounded per-message callee list",
        }
    finally:
        save(output / "h1-lsp-transcript.json", lsp.transcript)
        lsp.close()
    return record


def h2_override_fanout(output: Path) -> dict:
    config = REPOS["alamofire"]
    project = config["root"]
    record: dict = {"project": "alamofire", "target": "Request.task(for:using:)", "arms": {}}

    cartograph = run([str(CARTOGRAPH), "query", H2_USR, "--depth", "3", "--limit", "200",
                      *cg_args(project, config["include"])],
                     project, output / "h2-cartograph")
    doc = json.loads(cartograph["stdout"]) if cartograph["exit"] == 0 else {}
    impl_direct, impl_transitive = set(), set()
    for neighbor in (doc.get("result") or {}).get("usedBy", []):
        if "overrides" not in neighbor.get("edges", []):
            continue
        loc = neighbor.get("location") or {}
        rel = str(Path(loc.get("path", "")).relative_to(project))
        (impl_direct if neighbor["depth"] == 1 else impl_transitive).add((rel, loc.get("line")))
    record["arms"]["cartograph"] = {
        "seconds": cartograph["seconds"],
        "direct": sorted(impl_direct), "transitive": sorted(impl_transitive),
        "directMatch": impl_direct == H2_GOLD_DIRECT,
        "transitiveMatch": impl_transitive == H2_GOLD_TRANSITIVE,
    }

    lsp = LSPClient(project, output / "h2-lsp.stderr")
    try:
        lsp.initialize(project)
        path = project / H2_LSP_POINT[0]
        lsp.open_file(path)
        impl = lsp.request("textDocument/implementation", {
            "textDocument": {"uri": path.as_uri()},
            "position": {"line": H2_LSP_POINT[1] - 1, "character": H2_LSP_POINT[2] - 1},
        })
        save(output / "h2-lsp-implementation.json", impl)
        locations = set()
        for loc in impl["response"].get("result") or []:
            uri = loc.get("uri") or loc.get("targetUri", "")
            rng = loc.get("range") or loc.get("targetRange") or {}
            line = rng.get("start", {}).get("line")
            p = Path(uri.removeprefix("file://"))
            try:
                locations.add((str(p.relative_to(project)), line + 1 if line is not None else None))
            except ValueError:
                locations.add((str(p), line))
        record["arms"]["sourcekit-lsp"] = {
            "seconds": impl["seconds"],
            "implementations": sorted(locations),
            "foundAll": H2_GOLD_DIRECT | H2_GOLD_TRANSITIVE <= locations,
            "distinguishesDirectFromTransitive": False,
            "note": "implementation returns one flat set; depth and edge kind need manual grouping",
        }
    finally:
        save(output / "h2-lsp-transcript.json", lsp.transcript)
        lsp.close()

    search = run(["grep", "-rn", "override func task(for request", "Source/"],
                 project, output / "h2-search")
    hits = [line for line in search["stdout"].splitlines() if line.strip()]
    found = set()
    for line in hits:
        m = re.match(r"(Source/[^:]+):(\d+):", line)
        if m:
            found.add((m.group(1), int(m.group(2))))
    record["arms"]["source-search"] = {
        "seconds": search["seconds"], "hits": sorted(found),
        "foundAll": H2_GOLD_DIRECT | H2_GOLD_TRANSITIVE <= found,
        "distinguishesDirectFromTransitive": False,
        "note": "finds override decls by text; the hierarchy level needs source reading",
    }
    return record


def prepare_ap_edit(output: Path) -> None:
    """Build the edited scratch copy: snapshot the pinned index, remove one call, rebuild."""
    source = REPOS["argument-parser"]["root"]
    scratch = REPOS["ap-edit"]["root"]
    if scratch.exists():
        raise FileExistsError(f"scratch copy already exists: {scratch}")
    # 인덱스 유닛은 절대 경로에 묶여 복사본에서 무효다. 빌드 산출물 없이 복사해
    # 스크래치 위치에서 새로 빌드한다.
    shutil.copytree(
        source, scratch, symlinks=True,
        ignore=shutil.ignore_patterns(".build*", ".git", ".swiftpm"),
    )
    shutil.copytree(source / ".git", scratch / ".git", symlinks=True)
    first = run(["swift", "build", "-j", "4"], scratch, output / "h4-first-build", timeout=900)
    if first["exit"] != 0:
        raise RuntimeError("scratch initial build failed; inspect h4-first-build.json")
    snapshot = run([str(CARTOGRAPH), "snapshot",
                    *cg_args(scratch, REPOS["ap-edit"]["include"])],
                   scratch, output / "h4-snapshot")
    if snapshot["exit"] != 0:
        raise RuntimeError("snapshot capture failed; inspect h4-snapshot.json")
    (scratch / "before.json").write_text(snapshot["stdout"])

    target = scratch / AP_EDIT_FILE
    text = target.read_text()
    for old, new in AP_EDIT_CALLSITES:
        if text.count(old) != 1:
            raise RuntimeError(f"expected exactly one call site {old!r} in the scratch copy")
        text = text.replace(old, new)
    target.write_text(text)

    consumer = scratch / AP_EDIT_CONSUMER_FILE
    consumer_text = consumer.read_text()
    old, new = AP_EDIT_CONSUMER
    if consumer_text.count(old) != 1:
        raise RuntimeError("expected exactly one bashCompletionScript consumer in the scratch copy")
    consumer.write_text(consumer_text.replace(old, new))

    build = run(["swift", "build", "-j", "4"], scratch, output / "h4-rebuild", timeout=600)
    if build["exit"] != 0:
        raise RuntimeError("scratch rebuild failed; inspect h4-rebuild.json")


def h3_h4_impact(output: Path) -> dict:
    config = REPOS["ap-edit"]
    project = config["root"]
    record: dict = {"project": "ap-edit", "arms": {}}

    search = run(["git", "diff", "--name-only", "HEAD"], project, output / "h3-search")
    record["arms"]["source-search"] = {
        "seconds": search["seconds"],
        "changedFiles": sorted(search["stdout"].split()),
        "note": "file-level only; no declaration-level consumer information",
    }

    since = run([str(CARTOGRAPH), "impact", "--since", "HEAD", "--format", "json",
                 *cg_args(project, config["include"])],
                project, output / "h3-cartograph")
    since_doc = json.loads(since["stdout"]) if since["exit"] == 0 else {}
    affected_files = sorted({((a.get("symbol") or {}).get("location") or {}).get("path", "")
                             for a in since_doc.get("affected", [])})
    record["arms"]["cartograph-since"] = {
        "seconds": since["seconds"],
        "status": since_doc.get("status"),
        "affectedCount": len(since_doc.get("affected", [])),
        "affectedFiles": [str(Path(f).relative_to(project)) for f in affected_files if f],
        "requestedFiles": since_doc.get("requestedFiles"),
        "summary": since_doc.get("summary"),
    }

    before = run([str(CARTOGRAPH), "impact", "--since", "HEAD",
                  "--before", str(project / "before.json"), "--format", "json",
                  *cg_args(project, config["include"])],
                 project, output / "h4-cartograph")
    before_doc = json.loads(before["stdout"]) if before["exit"] == 0 else {}
    cur = before_doc.get("current", {})
    prev = before_doc.get("before", {})

    def edge_key(a):
        symbol = a.get("symbol") or {}
        return (symbol.get("usr"), a.get("via"))

    cur_edges = {edge_key(a) for a in cur.get("affected", [])}
    prev_edges = {edge_key(a) for a in prev.get("affected", [])}
    lost = sorted(
        f"{(a.get('symbol') or {}).get('qualifiedName')} via {a.get('via')}"
        for a in prev.get("affected", []) if edge_key(a) not in cur_edges
    )
    record["arms"]["cartograph-before"] = {
        "seconds": before["seconds"],
        "status": before_doc.get("status"),
        "currentAffected": len(cur.get("affected", [])),
        "beforeAffected": len(prev.get("affected", [])),
        "lostConsumerEdges": lost,
        "gainedConsumerEdges": len(cur_edges - prev_edges),
        "limitations": before_doc.get("limitations", []),
    }

    # 고립된 헬퍼를 심볼로 지정: before 스냅샷에는 소비자가 있고 현재에는 없어야 한다.
    orphan = run([str(CARTOGRAPH), "impact", "valueCompletion(_:)",
                  "--before", str(project / "before.json"), "--format", "json",
                  *cg_args(project, config["include"])],
                 project, output / "h4-cartograph-symbol")
    orphan_doc = json.loads(orphan["stdout"]) if orphan["exit"] == 0 else {}
    o_cur = orphan_doc.get("current", {})
    o_prev = orphan_doc.get("before", {})
    record["arms"]["cartograph-orphan-symbol"] = {
        "seconds": orphan["seconds"],
        "currentStatus": o_cur.get("status"),
        "currentAffected": len(o_cur.get("affected", [])),
        "beforeAffected": len(o_prev.get("affected", [])),
        "orphanDetected": len(o_prev.get("affected", [])) > len(o_cur.get("affected", [])),
    }

    dead = run([str(CARTOGRAPH), "dead", *cg_args(project, config["include"])],
               project, output / "h3-cartograph-dead")
    flagged = [line.strip() for line in dead["stdout"].splitlines()
               if "never used" in line and ("valueCompletion" in line
                                            or "bashCompletionScript" in line)]
    record["arms"]["cartograph-dead-on-edit"] = {
        "seconds": dead["seconds"],
        "orphanedDeclsFlagged": flagged,
        "orphanDetected": any("valueCompletion" in line for line in flagged),
    }

    # 대조군: 미편집 고정 리비전에서는 같은 선언이 잡히지 않아야 한다.
    control = REPOS["argument-parser"]
    dead_control = run([str(CARTOGRAPH), "dead",
                        *cg_args(control["root"], control["include"])],
                       control["root"], output / "h3-cartograph-dead-control")
    control_flagged = [line.strip() for line in dead_control["stdout"].splitlines()
                       if "never used" in line and ("valueCompletion" in line
                                                    or "bashCompletionScript" in line)]
    record["arms"]["cartograph-dead-control"] = {
        "seconds": dead_control["seconds"],
        "orphanedDeclsFlagged": control_flagged,
        "clean": not control_flagged,
    }
    return record


def h5_local_function(output: Path) -> dict:
    config = REPOS["kingfisher"]
    project = config["root"]
    record: dict = {"project": "kingfisher", "target": "failCurrentSource", "arms": {}}

    cartograph = run([str(CARTOGRAPH), "query", "failCurrentSource", "--depth", "1",
                      *cg_args(project, config["include"])],
                     project, output / "h5-cartograph")
    doc = json.loads(cartograph["stdout"]) if cartograph["exit"] == 0 else {}
    subject = (doc.get("result") or {}).get("subject") or {}
    lines = set()
    for neighbor in (doc.get("result") or {}).get("usedBy", []):
        for item in (neighbor.get("referenceEvidence") or {}).get("items") or []:
            loc = item.get("location") or {}
            if loc.get("path", "").endswith("KingfisherManager.swift"):
                lines.add(loc.get("line"))
    record["arms"]["cartograph"] = {
        "seconds": cartograph["seconds"],
        "status": doc.get("status"),
        "localUSR": (subject.get("usr") or "").startswith("cartograph:local-function:"),
        "evidenceLines": sorted(lines),
        "exactLocalGranularity": lines == H5_GOLD_LINES,
    }

    lsp = LSPClient(project, output / "h5-lsp.stderr")
    try:
        lsp.initialize(project)
        path = project / "Sources/General/KingfisherManager.swift"
        lsp.open_file(path)
        refs = lsp.request("textDocument/references", {
            "textDocument": {"uri": path.as_uri()},
            "position": {"line": 362, "character": 23},
            "context": {"includeDeclaration": False},
        })
        save(output / "h5-lsp-references.json", refs)
        ref_lines = set()
        for loc in refs["response"].get("result") or []:
            if loc.get("uri", "").endswith("KingfisherManager.swift"):
                ref_lines.add(loc["range"]["start"]["line"] + 1)
        record["arms"]["sourcekit-lsp"] = {
            "seconds": refs["seconds"],
            "referenceLines": sorted(ref_lines),
            "exactLocalGranularity": H5_GOLD_LINES <= ref_lines,
        }
    finally:
        save(output / "h5-lsp-transcript.json", lsp.transcript)
        lsp.close()

    search = run(["grep", "-rn", "failCurrentSource", "Sources/"],
                 project, output / "h5-search")
    record["arms"]["source-search"] = {
        "seconds": search["seconds"],
        "hits": len(search["stdout"].splitlines()),
        "note": "decl and both call sites are textually visible; ownership needs reading",
    }
    return record


def h6_dead_regression(output: Path) -> dict:
    record: dict = {"arms": {}}
    for name in ["alamofire", "kingfisher", "argument-parser"]:
        config = REPOS[name]
        result = run([str(CARTOGRAPH), "dead", "--retain-public",
                      *cg_args(config["root"], config["include"])],
                     config["root"], output / f"h6-dead-{name}")
        warnings = [l for l in result["stdout"].splitlines() if "never used" in l]
        record["arms"][name] = {
            "seconds": result["seconds"], "exit": result["exit"],
            "neverUsedWarnings": len(warnings),
            "expectation": {"alamofire": 21, "kingfisher": 8, "argument-parser": 40}[name],
        }
    return record


def latency_query(output: Path, samples: int) -> dict:
    config = REPOS["alamofire"]
    project = config["root"]
    usr = "s:9Alamofire7InstantVACycfc"
    record: dict = {"project": "alamofire", "arms": {}}

    cold = [run([str(CARTOGRAPH), "query", usr, "--depth", "1",
                 *cg_args(project, config["include"])],
                project, output / f"lat-cli-{i}")["seconds"]
            for i in range(samples)]
    record["arms"]["cartograph-cli-cold"] = cold

    mcp = MCPClient(project, config["include"], output / "lat-mcp.stderr")
    try:
        mcp.request("server/discover", {})
        mcp.request("tools/call", {"name": "cartograph_status", "arguments": {}})
        warm = [mcp.request("tools/call", {"name": "cartograph_query", "arguments": {
            "symbols": [usr], "depth": 1}})["seconds"] for _ in range(samples)]
        record["arms"]["cartograph-mcp-warm"] = warm
    finally:
        save(output / "lat-mcp-transcript.json", mcp.transcript)
        mcp.close()

    lsp = LSPClient(project, output / "lat-lsp.stderr")
    try:
        lsp.initialize(project)
        path = project / "Source/Core/Instant.swift"
        lsp.open_file(path)
        point = {"textDocument": {"uri": path.as_uri()},
                 "position": {"line": 41, "character": 4}}
        hierarchy = lsp.request("textDocument/prepareCallHierarchy", point)
        items = hierarchy["response"].get("result") or []
        lsp_times = []
        for _ in range(samples):
            started = time.perf_counter()
            for item in items:
                lsp.request("callHierarchy/incomingCalls", {"item": item})
            lsp_times.append(round(time.perf_counter() - started, 4))
        record["arms"]["sourcekit-lsp-warm"] = lsp_times
    finally:
        save(output / "lat-lsp-transcript.json", lsp.transcript)
        lsp.close()

    grep_times = []
    for i in range(samples):
        r = run(["grep", "-rn", "Instant()", "Source/"],
                project, output / f"lat-search-{i}")
        grep_times.append(r["seconds"])
    record["arms"]["source-search"] = grep_times
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-ap-edit", action="store_true",
                        help="build the edited argument-parser scratch copy and exit")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--output", type=Path, default=WORKSPACE / "raw")
    args = parser.parse_args()
    output = args.output
    output.mkdir(parents=True, exist_ok=True)

    if args.prepare_ap_edit:
        prepare_ap_edit(output)
        print("prepared ap-edit scratch copy")
        return 0

    if not REPOS["ap-edit"]["root"].exists():
        print("run --prepare-ap-edit first", file=sys.stderr)
        return 2

    results = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "cartograph": str(CARTOGRAPH),
        "tasks": {
            "h1-bridge-handlers": h1_bridge_handlers(output),
            "h2-override-fanout": h2_override_fanout(output),
            "h3-h4-impact-diff": h3_h4_impact(output),
            "h5-local-function": h5_local_function(output),
            "h6-dead-regression": h6_dead_regression(output),
            "latency-query": latency_query(output, args.samples),
        },
    }
    save(output / "harder-results.json", results)
    print(json.dumps(results["tasks"], indent=2, sort_keys=True)[:6000])
    print(f"\nfull results: {output / 'harder-results.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
