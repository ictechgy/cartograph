#!/usr/bin/env python3
"""고정 공개 프로젝트의 준비된 두 세션을 같은 IPC 경계로 진단한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROJECT = load("prepared_project", "benchmark-indexstore-project.py")
MCP = load("prepared_mcp", "verify-mcp.py")
BASE = PROJECT.BASE
ARMS = ["baseline", "cartograph"]
ORDERS = [ARMS, list(reversed(ARMS)), ARMS, list(reversed(ARMS))]
MAX_REPLY = 8 * 1024 * 1024
DRIVER_SECONDS = 540


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def metadata(config: dict) -> str:
    """추가·삭제를 포함한 현재 소스·설정·인덱스 메타데이터를 요청마다 읽는다."""
    project, store = Path(config["project"]), Path(config["store"])
    paths = {project / entry["path"] for entry in config["manifest"]["files"]}
    paths.add(Path(config["cg_config"]))
    paths.update((project / "Sources").rglob("*"))
    paths.update(store.rglob("*"))
    entries = []
    for path in sorted(paths):
        require(not path.is_symlink(), f"Symlink input rejected: {path}")
        stat = path.stat()
        entries.append((str(path), stat.st_dev, stat.st_ino, stat.st_mode, stat.st_size,
                        stat.st_mtime_ns, stat.st_ctime_ns))
    return hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()


def verify_bytes(config: dict) -> dict:
    started = time.perf_counter()
    PROJECT.verify_sources(Path(config["project"]), config["manifest"], config["oracle"])
    require(BASE.fingerprint(Path(config["store"])) == config["index_fingerprint"], "Index bytes changed")
    for path, digest in config["hashes"].items():
        require(BASE.sha256(Path(path)) == digest, f"Admitted file changed: {path}")
    return {"seconds": time.perf_counter() - started, "source_index_and_config_bytes_unchanged": True}


def admit(path: Path, out: Path, timeout: float) -> tuple[dict, dict]:
    report = PROJECT.read_json(path)
    require(report.get("status") == "passed" and report.get("validation_passed") is True,
            "A successful full raw project validation is required")
    require(report["project"]["revision"] == PROJECT.PROJECT_REVISION, "Project revision changed")
    oracle, manifest = PROJECT.frozen_inputs()
    prior = report["reused_tools"]
    setup_path = Path(prior["setup_results"])
    require(BASE.sha256(setup_path) == prior["setup_results_sha256"], "Tool setup evidence changed")
    setup = PROJECT.read_json(setup_path)
    require(setup["status"] == "passed" and setup["comparator_setup"]["revision"] == BASE.REVISION,
            "Successful pinned comparator setup is required")
    root = path.parent
    registration = root / "setup" / "preregistration.json"
    require(BASE.sha256(registration) == report["preregistration_sha256"], "Project registration changed")
    frozen = PROJECT.read_json(registration)
    hashes = {
        str(Path(prior["cli"])): setup["comparator_setup"]["binary_sha256"],
        str(Path(prior["library"])): setup["toolchain"]["library_sha256"],
        str(Path(prior["cartograph"])): setup["cartograph"]["binary_sha256"],
        str(Path(prior["swiftc"])): prior["swiftc_sha256"],
        str(root / "setup" / "cartograph.yml"): report["config_sha256"],
        str(Path(PROJECT.__file__)): frozen["runner_sha256"],
        str(PROJECT.BASE_PATH): frozen["base_adapter_sha256"],
        str(Path(__file__).resolve()): BASE.sha256(Path(__file__)),
        str(Path(MCP.__file__)): BASE.sha256(Path(MCP.__file__)),
        str(root / "runs" / "build" / "index-file-manifest.json"):
            report["project"]["index_file_manifest_sha256"],
    }
    config = {"project": str(root / "project"), "store": report["project"]["index_store"],
              "cg_config": str(root / "setup" / "cartograph.yml"), "manifest": manifest, "oracle": oracle,
              "allowed": sorted(PROJECT.source_files(manifest)), "requests": PROJECT.query_requests(oracle),
              "index_fingerprint": report["project"]["index_fingerprint"], "hashes": hashes,
              "cli": prior["cli"], "library": prior["library"], "cartograph": prior["cartograph"],
              "out": str(out / "baseline"), "timeout": timeout}
    verify_bytes(config)
    measurement = report["discovery"]["cartograph"]["measurement"]
    require(measurement["returncode"] == 0 and not measurement["timed_out"], "Native discovery failed")
    graph_path = Path(measurement["stdout"])
    graph = PROJECT.parse_cg_graph(PROJECT.read_json(graph_path), Path(config["project"]),
                                  set(config["allowed"]), oracle)
    require(PROJECT.graph_grade(graph, oracle)["exact_match"], "Native graph no longer matches source oracle")
    BASE.save(out / "admission.json", {"project_results": str(path), "project_results_sha256": BASE.sha256(path),
              "native_graph": str(graph_path), "native_graph_sha256": BASE.sha256(graph_path), "hashes": hashes,
              "source_evidence_sha256": PROJECT.FROZEN_HASHES,
              "runner_sha256": BASE.sha256(Path(__file__)), "mcp_adapter_sha256": BASE.sha256(Path(MCP.__file__))})
    return config, graph


def baseline_worker(config: dict) -> None:
    def terminate(_signal, _frame):
        raise SystemExit(143)  # 실행 중인 실제 index-dump 도 BASE.run 의 finally 로 정리한다.
    signal.signal(signal.SIGTERM, terminate)
    graph, admitted, generation = None, None, 0
    for raw in sys.stdin.buffer:
        require(len(raw) <= MCP.MAX_LINE, "Oversized request")
        request = json.loads(raw)
        if request["method"] == "server/discover":
            result = {"resultType": "complete"}
        else:
            require(request["method"] == "tools/call", "Unsupported method")
            name, arguments = request["params"]["name"], request["params"]["arguments"]
            require(name in {"cartograph_status", "cartograph_query"}, "Unsupported tool")
            current = metadata(config)
            require(admitted is None or current == admitted, "Baseline refuses input metadata drift")
            if graph is None or arguments.get("refresh"):
                verify_bytes(config)
                directory = Path(config["out"]) / f"generation-{generation + 1}"
                graph = PROJECT.baseline_discovery({**config, "out": str(directory)})
                require(metadata(config) == current, "Input changed during baseline discovery")
                require(PROJECT.graph_grade(graph, config["oracle"])["exact_match"], "Baseline graph failed oracle")
                admitted, generation = current, generation + 1
                BASE.save(Path(config["out"]) / f"generation-{generation}" / "graph.json", graph)
            payload = {"generation": generation, "ready": True, "fingerprint": admitted}
            if name == "cartograph_query":
                deepest = max(config["requests"], key=lambda item: item["max_depth"])
                require(arguments == {"symbols": [deepest["seed"]], "depth": deepest["max_depth"], "limit": 1000},
                        "Unexpected baseline workload")
                payload = {"session": payload, "answers": PROJECT.combined_answers(
                    PROJECT.reverse_depths(graph["edges"], deepest["seed"], deepest["max_depth"]), config["requests"])}
            result = {"resultType": "complete", "isError": False, "structuredContent": payload}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}, sort_keys=True), flush=True)


class Client:
    """양쪽 모두 전송부터 완전한 구조 응답 파싱까지 같은 시계를 사용한다."""

    def __init__(self, command: list[str], cwd: Path, out: Path, timeout: float, deadline: float | None = None):
        out.mkdir(parents=True, exist_ok=True)
        self.out, self.timeout, self.sequence = out, timeout, 0
        self.deadline = time.monotonic() + DRIVER_SECONDS if deadline is None else deadline
        require(time.monotonic() < self.deadline, "Shared driver deadline exceeded")
        self.record = {"command": command, "cwd": str(cwd), "stderr": str(out / "process.stderr")}
        BASE.save(out / "process.json", self.record)
        self.stderr = (out / "process.stderr").open("wb")
        self.started = time.perf_counter()
        self.process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, start_new_session=True)
        self.record["pid"] = self.process.pid
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()

    def receive(self, deadline: float) -> tuple[dict, bytes]:
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError("Session response deadline exceeded")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Session closed before a complete response")
            self.buffer.extend(chunk)
            require(len(self.buffer) <= MAX_REPLY, "Oversized session response")
        raw, _, rest = self.buffer.partition(b"\n")
        self.buffer = bytearray(rest)
        self.last_reply = bytes(raw) + b"\n"
        return json.loads(raw), self.last_reply

    def call(self, name: str | None, arguments: dict | None = None) -> tuple[dict, dict]:
        self.sequence += 1
        params = MCP.modern_params(name=name, arguments=arguments or {}) if name else MCP.modern_params()
        raw = MCP.request(self.sequence, "tools/call" if name else "server/discover", params)
        self.last_reply = b""
        deadline = min(time.monotonic() + self.timeout, self.deadline)
        require(time.monotonic() < deadline, "Shared driver deadline exceeded")
        started = time.perf_counter()
        try:
            self.process.stdin.write(raw)
            self.process.stdin.flush()
            response, _ = self.receive(deadline)
            require(response.get("jsonrpc") == "2.0" and response.get("id") == self.sequence, "Mismatched response")
            result = response.get("result", {})
            require(result.get("resultType") == "complete" and not result.get("isError"), "Incomplete/error response")
            payload = result.get("structuredContent") if name else result
            require(isinstance(payload, dict), "Missing structured response")
        finally:
            self.completed = time.perf_counter()
            stem = self.out / f"{self.sequence:02d}-{name or 'discover'}"
            Path(str(stem) + ".request.json").write_bytes(raw)
            Path(str(stem) + ".stdout").write_bytes(self.last_reply or bytes(self.buffer))
            measurement = {"ipc_seconds": self.completed - started,
                           "request": str(stem) + ".request.json", "stdout": str(stem) + ".stdout"}
            BASE.save(Path(str(stem) + ".json"), measurement)
        return payload, measurement

    def close(self) -> dict:
        error, forced = None, False
        try:
            self.process.stdin.close()
        except BaseException as failure:
            error = failure
        try:
            for signum in (None, signal.SIGTERM, signal.SIGKILL):
                if signum is not None:
                    forced = True
                    try:
                        os.killpg(self.process.pid, signum)
                    except ProcessLookupError:
                        pass
                try:
                    self.process.wait(timeout=10 if signum != signal.SIGKILL else 5)
                    break
                except subprocess.TimeoutExpired:
                    continue
        except BaseException as failure:
            error = error or failure
        finally:
            for resource in (self.selector, self.process.stdout, self.stderr):
                try:
                    resource.close()
                except BaseException as failure:
                    error = error or failure
        self.record.update(returncode=self.process.returncode, forced_cleanup=forced)
        if error is not None:
            self.record["close_error"] = f"{type(error).__name__}: {error}"
        BASE.save(self.out / "process.json", self.record)
        if error is not None:
            raise error
        return self.record


def query(client: Client, arm: str, config: dict, graph: dict, generation: int) -> dict:
    request = max(config["requests"], key=lambda item: item["max_depth"])
    symbol = graph["bindings"][request["seed"]] if arm == "cartograph" else request["seed"]
    payload, measurement = client.call("cartograph_query",
                                       {"symbols": [symbol], "depth": request["max_depth"], "limit": 1000})
    require(type(payload["session"]["generation"]) is int and payload["session"]["generation"] == generation,
            "Prepared generation was not reused")
    if arm == "cartograph":
        parsed = PROJECT.parse_cg_query(payload["result"], request, graph)
        answers = PROJECT.combined_answers(parsed["answer"], config["requests"])
    else:
        answers = payload["answers"]
    grade = PROJECT.grade(answers, config["oracle"])
    require(grade["passed"], "Prepared answer failed the frozen source oracle")
    return {**measurement, "generation": generation, "grade": grade, "answers": answers}


def run(config: dict, graph: dict, out: Path, report: dict, deadline: float | None = None) -> None:
    clients, generations = {}, {}
    report.update(preparation={}, first={}, warm_pairs=[], refresh={}, processes={}, byte_checks=[])
    BASE.save(out / "baseline-config.json", config)
    try:
        report["byte_checks"].append({"phase": "before-preparation", **verify_bytes(config)})
        for arm in ARMS:
            command = ([sys.executable, str(Path(__file__).resolve()), "--worker", str(out / "baseline-config.json")]
                       if arm == "baseline" else [config["cartograph"], "serve", "--session-freshness-interval", "0",
                            *PROJECT.cg_options(Path(config["project"]), Path(config["store"]),
                                                Path(config["cg_config"]))])
            client = clients[arm] = Client(command, Path(config["project"]), out / arm, config["timeout"], deadline)
            _, discover = client.call(None)
            status, ready = client.call("cartograph_status")
            require(type(status.get("generation")) is int and status["generation"] > 0, "Session not ready")
            generations[arm] = status["generation"]
            report["preparation"][arm] = {"spawn_to_graph_ready_seconds": client.completed - client.started,
                                          "generation": status["generation"], "discover": discover, "status": ready}
        phases = [("first", ARMS), *[(f"warm-{number}", order) for number, order in enumerate(ORDERS)]]
        for phase, order in phases:
            report["byte_checks"].append({"phase": f"before-{phase}", **verify_bytes(config)})
            pair = {"order": order}
            for arm in order:
                pair[arm] = query(clients[arm], arm, config, graph, generations[arm])
            report["byte_checks"].append({"phase": f"after-{phase}", **verify_bytes(config)})
            if phase == "first":
                report["first"] = pair
            else:
                report["warm_pairs"].append(pair)
            BASE.save(out / "results.json", report)
        report["byte_checks"].append({"phase": "before-forced-refresh", **verify_bytes(config)})
        for arm in ARMS:
            status, measurement = clients[arm].call("cartograph_status", {"refresh": True})
            require(status["generation"] == generations[arm] + 1,
                    "Forced refresh did not advance exactly one generation")
            answer = query(clients[arm], arm, config, graph, status["generation"])
            report["refresh"][arm] = {"completed_refresh": measurement, "first_answer": answer,
                "refresh_plus_first_answer_seconds": measurement["ipc_seconds"] + answer["ipc_seconds"]}
        report["byte_checks"].append({"phase": "after-forced-refresh", **verify_bytes(config)})
        report["totals"] = {arm: report["preparation"][arm]["spawn_to_graph_ready_seconds"]
                            + report["first"][arm]["ipc_seconds"]
                            + sum(pair[arm]["ipc_seconds"] for pair in report["warm_pairs"])
                            + report["refresh"][arm]["refresh_plus_first_answer_seconds"] for arm in ARMS}
        report["common_byte_verification_seconds"] = sum(check["seconds"] for check in report["byte_checks"])
        common = report["admission_seconds"] + report["common_byte_verification_seconds"]
        report["totals_including_common_verification_seconds"] = {
            arm: total + common for arm, total in report["totals"].items()}
        require(deadline is None or time.monotonic() < deadline, "Shared driver deadline exceeded")
        report["status"] = "passed"
    finally:
        for arm, client in clients.items():
            try:
                report["processes"][arm] = client.close()
            except BaseException as error:
                report["processes"][arm] = {"returncode": None, "forced_cleanup": True,
                                            "cleanup_error": f"{type(error).__name__}: {error}"}
        if any(record["returncode"] != 0 or record["forced_cleanup"] for record in report["processes"].values()):
            report["status"] = "failed"


def terminate_driver(_signal, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise KeyboardInterrupt("Termination requested; cleaning up session processes")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-results", type=Path)
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.worker:
        baseline_worker(PROJECT.read_json(args.worker))
        return 0
    if not args.project_results or not 0 < args.timeout <= 300:
        parser.error("Provide successful --project-results and a timeout in (0, 300]")
    path = args.project_results.resolve()
    out = path.parent / "runs" / "prepared-sessions"
    require(not out.exists(), "Prepared-session evidence already exists; never overwrite a run")
    out.mkdir(parents=True)
    report = {"schema_version": 1, "status": "running", "superiority_claim": None,
              "role": "Separate prepared-session diagnostic; not a fresh-CLI or generic engine comparison",
              "query_clock": ("Client IPC send through complete response JSON/structured payload parsing; "
                              "oracle grading and raw log writes excluded"),
              "refresh_contract": ("One forced same-input invalidation and completed rediscovery/refresh, "
                                   "then first answer; no source edit or rebuild"),
              "total_contract": ("Per-arm spawn-to-ready + first + four warm queries + completed refresh "
                                 "+ first refreshed answer; shared checks separate"),
              "prior_setup": ("Reuses existing binaries/project compilation/native identity discovery; "
                              "their measured costs remain in project results"),
              "warm_orders": ORDERS, "refresh_order": ARMS,
              "freshness": ("Baseline stats all current sources/config/index each request and refuses drift; "
                            "native freshness interval 0"),
              "native_evidence": ("Complete native evidence/limitations response is retained and timed; "
                                  "the baseline returns only the common call answer")}

    started, deadline = time.perf_counter(), time.monotonic() + DRIVER_SECONDS
    report["shared_driver_deadline_seconds"] = DRIVER_SECONDS
    previous_handler = signal.signal(signal.SIGTERM, terminate_driver)
    try:
        config, graph = admit(path, out, args.timeout)
        report["admission_seconds"] = time.perf_counter() - started
        run(config, graph, out, report, deadline)
    except (Exception, KeyboardInterrupt) as error:
        report.update(status="failed", error=f"{type(error).__name__}: {error}")
    finally:
        signal.signal(signal.SIGTERM, previous_handler)
    report["diagnostic_elapsed_seconds"] = time.perf_counter() - started
    BASE.save(out / "results.json", report)
    print(json.dumps({"status": report["status"], "results": str(out / "results.json")}, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
