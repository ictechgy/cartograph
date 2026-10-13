#!/usr/bin/env python3
"""검증 전용: 실제 CLI를 호출하고 상태당 역방향 색인을 한 번만 조립한다."""

from __future__ import annotations

import argparse
from collections import defaultdict, deque
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import traceback

sys.path.insert(0, str(Path(__file__).parent / "vendor"))
sys.path.insert(0, str(Path(__file__).parent / "vendor/mixed/adapter"))
import mixed_adapter as adapter
import process_tree_measure as measure
import command_runner
import generation_inputs as generation

REQUIRED_GATES = (
    "source_oracle",
    "negative_controls",
    "refresh",
    "rename_delete",
    "restoration",
    "stale_input",
    "common_index_before_after",
    "private_reader_state",
    "ten_query_batches",
    "equivalent_session_state",
)
PHASES = ("cache_validation", "discovery_setup", "batch")


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write("\n")


def fingerprint(root):
    root = Path(root)
    entries = [[str(p.relative_to(root)), digest(p)] for p in sorted(root.rglob("*")) if p.is_file()]
    return dict(
        sha256=hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest(), file_count=len(entries)
    )


def source_snapshot(project):
    root = Path(project)
    paths = sorted((root / "Sources").rglob("*"))
    config = root / ".cartograph.yml"
    if config.exists():
        paths.append(config)
    return {
        str(p.relative_to(root)): dict(sha256=digest(p), mtime_ns=p.stat().st_mtime_ns) for p in paths if p.is_file()
    }


class CommandFailure(RuntimeError):
    pass


class IncompleteCommand(CommandFailure):
    pass


class UnsupportedNative(RuntimeError):
    pass


class CommandRecorder:
    """각 하위 명령의 원문과 실패를 남긴다. 외부 감독기가 전체 트리를 제한한다."""

    def __init__(self, root, environment=None, timeout=120.0):
        self.root = Path(root)
        self.environment = environment
        self.timeout = timeout
        self.invocations = []

    def capture(self, command, cwd, name):
        stem = self.root / name
        stem.parent.mkdir(parents=True, exist_ok=True)
        paths = {
            kind: Path(str(stem) + "." + suffix)
            for kind, suffix in [("stdout", "stdout"), ("stderr", "stderr"), ("command", "command.json")]
        }
        if any(path.exists() for path in paths.values()):
            raise FileExistsError(f"Preserve original command evidence: {stem}")
        item = command_runner.command(command, Path(cwd), stem, self.environment or dict(os.environ), self.timeout)
        save(paths["command"], item)
        self.invocations.append(item)
        if not item["completed"] or item["returncode"] == 125:
            raise IncompleteCommand(f"Incomplete command; retained {stem}")
        if not item["passed"]:
            raise CommandFailure(f"Command exited {item['returncode']}; retained {stem}")
        return paths["stdout"].read_text()


class Ledger:
    """중첩 없는 단조 시각 구간을 보존하여 합산에서 관측한 비용을 빠뜨리지 않는다."""

    def __init__(self):
        self.phases = []
        self.active = False

    @contextmanager
    def phase(self, name):
        if self.active or name not in PHASES or any(x["name"] == name for x in self.phases):
            raise ValueError("Duplicate, nested or unknown phase")
        started = time.perf_counter_ns()
        self.active = True
        status = "failed"
        try:
            yield
            status = "ok"
        finally:
            ended = time.perf_counter_ns()
            self.phases.append(
                dict(name=name, start_ns=started, end_ns=ended, seconds=(ended - started) / 1e9, status=status)
            )
            self.active = False


def reverse_index(edges):
    reverse = defaultdict(set)
    for caller, callee in edges:
        reverse[callee].add(caller)
    return reverse


def caller_depths(reverse, seed, maximum):
    depths, pending = {seed: 0}, deque([seed])
    while pending:
        current = pending.popleft()
        if depths[current] >= maximum:
            continue
        for caller in sorted(reverse.get(current, ())):
            if caller not in depths:
                depths[caller] = depths[current] + 1
                pending.append(caller)
    del depths[seed]
    return dict(sorted(depths.items()))


def validate_requests(requests):
    if len(requests) != 10 or len({r["id"] for r in requests}) != 10:
        raise ValueError("Exactly ten uniquely identified requests required; duplicate seeds are allowed")
    if len({r["max_depth"] for r in requests}) != 1:
        raise ValueError("This native single-batch regime requires one common predetermined depth")
    if any(type(r["max_depth"]) is not int or not 1 <= r["max_depth"] <= 128 for r in requests):
        raise ValueError("Invalid depth")


class LoadedBaseline:
    """하나의 불변 상태에서 조립과 역방향 인접 목록을 열 번 재사용한다."""

    def __init__(self, graph):
        self.graph = graph
        self.reverse = reverse_index(graph["edges"])

    def batch(self, requests):
        validate_requests(requests)
        missing = [r["seed"] for r in requests if r["seed"] not in self.graph["bindings"]]
        unresolved = list(self.graph["unresolved"]) + [f"Missing source seed: {s}" for s in missing]
        return dict(
            arm="actual-index-dump-plus-session-assembly",
            operation="compiler-callers",
            complete=not unresolved,
            unresolved=unresolved,
            queries=[adapter.query_item(r, caller_depths(self.reverse, r["seed"], r["max_depth"])) for r in requests],
        )


def resolve_requests(catalog, specs):
    requests = []
    for spec in specs:
        found = [
            node["id"]
            for node in catalog
            if node["definition"] and node["context"] == spec["context"] and node["signature"] == spec["signature"]
        ]
        if len(found) != 1:
            raise ValueError(f"A source query is unresolved or ambiguous: {spec}: {found}")
        requests.append(dict(id=spec["id"], seed=found[0], max_depth=spec["max_depth"]))
    validate_requests(requests)
    return requests


def classify_unused_implicit(graph, metadata, raw_edges):
    """명시적으로 implicit인 미사용 선언만 진단으로 옮긴다. 간선은 절대 제거하지 않는다."""
    endpoints = {usr for edge in raw_edges for usr in edge}
    diagnostics, removable = [], set()
    for usr, details in metadata.items():
        if details.get("implicit") is True and usr not in graph["symbols"] and usr not in endpoints:
            diagnostics.append(dict(usr=usr, **details, reason="explicitly-implicit-unbound-no-call-endpoint"))
            removable.add(usr)

    def retained(message):
        for usr in removable:
            if message == f"Unbound in-universe callable compiler identity: {usr}":
                return False
            if message.startswith("Unrecognized callable source anchor: ") and message.endswith(f" ({usr})"):
                return False
        return True

    return dict(
        graph,
        unresolved=[message for message in graph["unresolved"] if retained(message)],
        unbound_unused_implicit=diagnostics,
    )


def baseline_implicit_metadata(texts):
    metadata, raw_edges = {}, set()
    for name, text in texts.items():
        parsed = adapter.parse_record(text)
        raw_edges.update(adapter.record_edges(parsed))
        for symbol in parsed["symbols"]:
            usr = symbol["usr"]
            item = metadata.setdefault(usr, dict(implicit=True, kind=symbol["kind"], provenance=[]))
            item["implicit"] &= "implicit" in symbol["roles"]
            item["provenance"].extend(
                dict(record=name, line=o["line"], column=o["column"], roles=o["printed_symbol_roles"])
                for o in parsed["occurrences"]
                if o["usr"] == usr
            )
    return metadata, raw_edges


def normalize_native_graph(raw, project, catalog):
    graph = adapter.cartograph_graph(raw, project, catalog)
    ids = {node["id"]: node.get("usr") or node["id"] for node in raw["nodes"]}
    metadata = {
        ids[node["id"]]: dict(
            implicit="implicit" in node.get("attributes", []),
            kind=node["kind"],
            provenance=[dict(location=node.get("location"), node_id=node["id"])],
        )
        for node in raw["nodes"]
    }
    edges = {(ids[e["source"]], ids[e["target"]]) for e in raw["edges"] if e["kind"] == "call"}
    return classify_unused_implicit(graph, metadata, edges)


def baseline_discovery(config, catalog, recorder):
    project, store = Path(config["project"]), Path(config["store"])
    units = {}
    for path in sorted((store / "v5/units").iterdir()):
        if path.is_file():
            text = recorder.capture(
                [config["index_dump"], path.name, "--index-store", str(store), "--lib-index-store", config["library"]],
                project,
                "units/" + path.name,
            )
            units[path.name] = adapter.parse_unit(path.name, text)
    selected = adapter.select_units(units, config["expected_outputs"])
    records = []
    allowed = set(config["contexts"])
    for record in selected["records"]:
        relative = adapter.relative_path(project, record["absolute_path"])
        if relative and relative.startswith("Sources/"):
            if relative not in allowed or not Path(record["absolute_path"]).is_file():
                raise ValueError(f"Active unit includes unknown/deleted project source: {relative}")
            records.append(record)
    for dependency in selected["files"]:
        relative = adapter.relative_path(project, dependency["absolute_path"])
        if relative and relative.startswith("Sources/") and relative not in allowed:
            raise ValueError(f"Active unit includes deleted/undeclared source dependency: {relative}")
    covered = {adapter.relative_path(project, record["absolute_path"]) for record in records}
    if covered != allowed:
        raise ValueError(f"Active record/source manifest mismatch: missing={sorted(allowed-covered)}")
    for expected in config["expected_outputs"]:
        roots = [
            name
            for name in selected["roots"]
            if adapter.absolute(units[name]["metadata"]["Output File"], units[name]["metadata"]["Working Directory"])
            == str(Path(expected["output"]).resolve())
        ]
        if len(roots) != 1 or not any(
            record["absolute_path"] == str(Path(expected["source"]).resolve()) and roots[0] in record["root_units"]
            for record in records
        ):
            raise ValueError("Active compiler output lacks its main source record")
        reachable = {
            entry["absolute_path"]
            for entry in selected["records"] + selected["files"]
            if roots[0] in entry["root_units"]
        }
        if set(expected.get("project_headers", [])) - reachable:
            raise ValueError("Active compiler output lacks declared header dependencies")
    texts = {
        name: recorder.capture(
            [config["index_dump"], name, "--index-store", str(store), "--lib-index-store", config["library"]],
            project,
            "records/" + name,
        )
        for name in sorted({r["name"] for r in records})
    }
    graph = adapter.baseline_graph(project, catalog, records, texts)
    metadata, raw_edges = baseline_implicit_metadata(texts)
    graph = classify_unused_implicit(graph, metadata, raw_edges)
    save(recorder.root / "provenance.json", dict(**selected, active_records=records))
    return graph


def native_options(config):
    return [
        "--project",
        config["project"],
        "--config",
        str(Path(config["project"]) / ".cartograph.yml"),
        "--index-store",
        config["store"],
        "--include",
        "Sources/**",
        "--edge-kind",
        "call",
    ]


def native_discovery_command(config):
    return [
        config["native_binary"],
        "graph",
        "--format",
        "json",
        "--level",
        "symbol",
        "--include-self-loops",
        *native_options(config),
    ]


def native_batch_command(config, graph, requests, out):
    validate_requests(requests)
    path = Path(out) / "native-requests.json"
    save(path, [graph["bindings"][request["seed"]] for request in requests])
    return [
        config["native_binary"],
        "query",
        "--batch",
        str(path),
        "--depth",
        str(requests[0]["max_depth"]),
        "--limit",
        str(config.get("limit", 10000)),
        *native_options(config),
    ]


def native_library(library, developer_directory):
    if sys.platform != "darwin":
        raise UnsupportedNative("Native Cartograph needs macOS; no native result can be inferred on Linux")
    candidates = [
        Path(developer_directory) / "Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
        Path("/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib"),
        Path(
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
        ),
    ]
    selected = next((p for p in candidates if p.is_file()), None)
    if selected is None or digest(selected) != digest(library):
        raise ValueError("Native resolver library differs from baseline/compiler library bytes")
    return dict(path=str(selected), sha256=digest(selected))


def execute_worker(config):
    out = Path(config["output"])
    ledger, recorder = Ledger(), CommandRecorder(out)
    result = dict(
        arm=config["arm"],
        state_id=config["state_id"],
        regime="fresh-reader-source-selector-cli-batch",
        status="failed",
        phases=[],
        invocations=[],
        graph=None,
        observation=None,
        default_projection_diagnostic_executed=False,
    )
    try:
        with ledger.phase("cache_validation"):
            derived = generation.verify(config)
            config = dict(config, **{k: derived[k] for k in ("expected_outputs", "contexts")})
            result["accepted_inputs"] = derived
            if source_snapshot(config["project"]) != config["accepted_sources"]:
                raise ValueError("Sources/config changed since accepted compiler build; stale input rejected")
            if digest(config["library"]) != config["library_sha256"]:
                raise ValueError("Library bytes changed")
            if config["arm"] == "cartograph":
                result["native_library"] = native_library(config["library"], config["developer_directory"])
            # 각 상태의 새 리더 디렉터리는 비어 있어야 하며 다른 팔과 공유하지 않는다.
            cache = Path(os.environ["TMPDIR"])
            if list(cache.iterdir()):
                raise ValueError("Reader cache is not fresh/private")
            result["reader_cache"] = str(cache.resolve())
            result["reader_cache_initial_entries"] = []
            result["validated_sources"] = config["accepted_sources"]
            result["validated_library_sha256"] = config["library_sha256"]
        with ledger.phase("discovery_setup"):
            catalog = adapter.source_catalog(Path(config["project"]), config["contexts"])
            requests = resolve_requests(catalog, config["queries"])
            save(out / "source-catalog.json", catalog)
            save(out / "source-requests.json", requests)
            if config["arm"] == "baseline":
                graph = baseline_discovery(config, catalog, recorder)
                session = LoadedBaseline(graph)
                result["reverse_adjacency_build_count"] = 1
            else:
                raw = json.loads(
                    recorder.capture(native_discovery_command(config), config["project"], "complete-graph")
                )
                graph = normalize_native_graph(raw, Path(config["project"]), catalog)
            result["graph"] = graph
            save(out / "normalized-graph.json", graph)
        with ledger.phase("batch"):
            if config["arm"] == "baseline":
                observation = session.batch(requests)
            else:
                command = native_batch_command(config, graph, requests, out)
                raw = json.loads(recorder.capture(command, config["project"], "native-batch"))
                observation = adapter.cartograph_batch(raw, requests, graph)
                # 원래 질의 계약은 출발 정점을 포함하지 않는다. 파서 성공만으로 이를 가정하지 않는다.
                if any(q["seed"] in {item["id"] for item in q["transitive"]} for q in observation["queries"]):
                    raise ValueError("Native query included its seed")
            result["observation"] = observation
            save(out / "observation.json", observation)
        result["status"] = "ok" if observation["complete"] else "unresolved"
    except BaseException as exc:
        result["status"] = (
            "incomplete"
            if isinstance(exc, (IncompleteCommand, KeyboardInterrupt))
            else "blocked" if isinstance(exc, UnsupportedNative) else "failed"
        )
        result["error"] = dict(type=type(exc).__name__, message=str(exc), traceback=traceback.format_exc())
    finally:
        result["phases"], result["invocations"] = ledger.phases, recorder.invocations
        save(out / "worker-result.json", result)
    return result


def reconcile(result, measurement, external_validation_seconds=0.0):
    if measurement.get("measurement_mode") != "timing" or measurement.get("sampling_during_timing") is not False:
        raise ValueError("Only unsampled timing runs can be composed")
    phases = {row["name"]: row["seconds"] for row in result["phases"]}
    if len(phases) != len(result["phases"]) or set(phases) != set(PHASES):
        raise ValueError("Phase evidence is missing, duplicated, or unexpected")
    if any(type(value) not in (int, float) or not math.isfinite(value) or value < 0 for value in phases.values()):
        raise ValueError("Invalid phase duration")
    total = measurement["wall_seconds"]
    overhead = total - sum(phases.values())
    if not math.isfinite(total) or overhead < 0:
        raise ValueError("Phases exceed externally measured whole-worker cost")
    if not math.isfinite(external_validation_seconds) or external_validation_seconds < 0:
        raise ValueError("Invalid external validation cost")
    charged = dict(phases)
    charged["external_validation"] = external_validation_seconds
    charged["discovery_setup"] += overhead
    return dict(
        measured_worker_seconds=total,
        worker_overhead_seconds=overhead,
        overhead_policy="All interpreter/import/result-serialization/teardown overhead charged to setup",
        charged_components=charged,
        raw_phases=result["phases"],
    )


def guard_receipt(config):
    started = time.perf_counter()
    record = dict(status="failed")
    try:
        record["inputs"] = generation.verify(config)
        record["status"] = "passed"
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        record["failure"] = dict(type=type(error).__name__, message=str(error))
    except KeyboardInterrupt:
        record.update(status="incomplete", failure=dict(type="KeyboardInterrupt"))
    record["wall_seconds"] = time.perf_counter() - started
    return record


def incomplete_measurement(value):
    code = value.get("root_returncode", value.get("returncode"))
    return (
        type(code) is not int
        or code < 0
        or code == 125
        or value.get("failure") not in (None, "nonzero_exit")
        or (value.get("cleanup") or {}).get("remaining_observed_pids", [])
    )


def output_boundary(config, out):
    destination = Path(out).resolve()
    candidates = [Path(config[k]).resolve() for k in ("project", "store") if k in config]
    lifecycle = config.get("generation_receipts", {}).get("lifecycle", {}).get("path")
    if lifecycle:
        candidates.append(Path(lifecycle).resolve().parent)
    for source in candidates:
        if destination.is_relative_to(source) or source.is_relative_to(destination):
            raise ValueError("Arm evidence overlaps compiler inputs")


def run_arm(config, out, mode="timing"):
    started = time.perf_counter()
    out = Path(out).resolve()
    output_boundary(config, out)
    out.mkdir(parents=True, exist_ok=False)
    record = dict(
        arm=config["arm"],
        state_id=config["state_id"],
        status="failed",
        exit_code=1,
        final_evidence=False,
        result={"status": "not-run"},
        measurement=None,
    )
    try:
        before = guard_receipt(config)
        record["guard_before"] = before
        record["guard_after"] = dict(status="not-run", reason="prelaunch-inputs-not-accepted")
        if before["status"] != "passed":
            record["exit_code"] = 125 if before["status"] == "incomplete" else 1
            record["status"] = "incomplete" if record["exit_code"] == 125 else "failed"
        else:
            cache = out / "private-reader-cache"
            cache.mkdir()
            config = dict(config, output=str(out), accepted_sources=source_snapshot(config["project"]))
            save(out / "input.json", config)
            index_before = fingerprint(config["store"])
            env = dict(os.environ, TMPDIR=str(cache))
            if config.get("developer_directory"):
                env["DEVELOPER_DIR"] = config["developer_directory"]
            measure_started = time.perf_counter()
            measured = measure.run(
                [sys.executable, str(Path(__file__).resolve()), "--worker", str(out / "input.json")],
                Path(config["project"]),
                out / "whole-arm",
                mode=mode,
                timeout=config.get("timeout", 300),
                environment=env,
            )
            measure_finished = time.perf_counter()
            record["measurement"] = measured
            path = out / "worker-result.json"
            result = (
                json.loads(path.read_text())
                if path.exists()
                else dict(status="failed", error="Worker produced no result")
            )
            record.update(result=result, index_path=str(Path(config["store"]).resolve()), index_before=index_before)
            if incomplete_measurement(measured) or result["status"] == "incomplete":
                record.update(
                    status="incomplete",
                    exit_code=125,
                    guard_after=dict(status="unavailable", reason="incomplete-process-cleanup-unverified"),
                )
            else:
                record["guard_after"] = guard_receipt(config)
                record["index_after"] = fingerprint(config["store"])
                if record["guard_after"]["status"] == "incomplete":
                    record.update(status="incomplete", exit_code=125)
                elif (
                    result["status"] == "ok"
                    and measured["status"] == "ok"
                    and record["guard_after"]["status"] == "passed"
                    and record["index_before"] == record["index_after"]
                ):
                    record.update(status="ok", exit_code=0)
            observation_finished = time.perf_counter()
            pre = measure_started - started
            call = measure_finished - measure_started
            post = observation_finished - measure_finished
            if call < measured["wall_seconds"]:
                raise ValueError("Whole measurement exceeds observed measurement-call interval")
            external = pre + post
            record["external_intervals"] = [
                dict(name="prelaunch", start=started, end=measure_started, seconds=pre),
                dict(name="measurement_call", start=measure_started, end=measure_finished, seconds=call),
                dict(name="post_terminal", start=measure_finished, end=observation_finished, seconds=post),
            ]
            record["external_validation_seconds"] = external
            record["instrumentation_residual_seconds"] = call - measured["wall_seconds"]
            record["external_cost_scope"] = (
                "Measured prelaunch setup and post-terminal read/validation intervals; separate measurement supervisor residual is reported but not a tool cost. Final arm-record serialization awaits outer-controller charging."
            )
            if record["status"] == "ok" and mode == "timing":
                record.update(reconcile(result, measured, external))
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, KeyboardInterrupt) as error:
        record.update(
            status="incomplete",
            exit_code=125,
            orchestration_failure=dict(type=type(error).__name__, message=str(error)),
            guard_after=dict(status="unavailable", reason="incomplete-observation-or-cleanup"),
        )
    record["observed_total_seconds_before_receipt_write"] = time.perf_counter() - started
    save(out / "arm-record.json", record)
    return record


def run_state(config, out, order="AB", mode="timing", baseline_only=False):
    if order not in ("AB", "BA"):
        raise ValueError("Order must be AB or BA from a precommitted plan")
    root = Path(out)
    output_boundary(config, root)
    root.mkdir(parents=True, exist_ok=False)
    observed = {}
    for key in order:
        arm_name = {"A": "baseline", "B": "cartograph"}[key]
        if baseline_only and arm_name == "cartograph":
            observed[arm_name] = dict(status="not-run", reason="Explicit baseline-only validation")
        else:
            previous = list(observed.values())
            abort = any(
                v.get("status") == "incomplete"
                or v.get("guard_before", {}).get("status") in ("failed", "incomplete")
                or v.get("guard_after", {}).get("status") in ("failed", "incomplete", "unavailable")
                for v in previous
            )
            if abort:
                observed[arm_name] = dict(status="not-run", reason="Prior arm incomplete or accepted inputs changed")
            else:
                observed[arm_name] = run_arm(dict(config, arm=arm_name), root / arm_name, mode=mode)
    code = (
        125
        if any(v.get("exit_code") == 125 for v in observed.values())
        else 0 if all(v.get("status") == "ok" for v in observed.values()) else 1
    )
    result = dict(
        state_id=config["state_id"],
        order=order,
        measurement_mode=mode,
        final_evidence=False,
        exit_code=code,
        **observed,
    )
    save(root / "state-result.json", result)
    return result


def _build_cost(records):
    if not records:
        raise ValueError("Missing full shared compiler preparation")
    total = 0.0
    for record in records:
        wall = record.get("wall_seconds")
        compiler = record.get("compiler_subprocess_wall_seconds")
        if (
            record.get("status") != "measured"
            or record.get("scope")
            != "full shared compiler/index preparation, command logs, output maps and acceptance seals"
            or type(wall) not in (int, float)
            or not math.isfinite(wall)
            or wall < 0
            or type(compiler) not in (int, float)
            or not math.isfinite(compiler)
            or not 0 <= compiler <= wall
            or record.get("charged_wall_seconds_by_arm") != {"cartograph": wall, "index_dump_assembly": wall}
        ):
            raise ValueError("Only accepted full shared preparation costs can be composed")
        total += wall
    return total


def composed_costs(initial, post_edit, initial_builds, edit_builds):
    for state in (initial, post_edit):
        for name in ("baseline", "cartograph"):
            record = state[name]
            if record.get("status") != "ok" or record.get("exit_code") != 0:
                raise ValueError("A failed arm cannot produce successful composed cost")
    shared = _build_cost(initial_builds) + _build_cost(edit_builds)
    result = {}
    for name in ("baseline", "cartograph"):
        initial_parts, edit_parts = initial[name]["charged_components"], post_edit[name]["charged_components"]
        result[name] = dict(
            shared_build_seconds=shared,
            initial=initial_parts,
            post_edit=edit_parts,
            total_seconds=shared + sum(initial_parts.values()) + sum(edit_parts.values()),
        )
    return result


def exact_gate(observed, expected):
    if observed is None or expected is None:
        return dict(passed=False, reason="Missing observed or independently authored expected evidence")
    encode = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"))
    actual, gold = set(map(encode, observed)), set(map(encode, expected))
    tp, fp, fn = actual & gold, actual - gold, gold - actual
    return dict(
        passed=not fp and not fn,
        tp=len(tp),
        fp=len(fp),
        fn=len(fn),
        precision=len(tp) / len(actual) if actual else None,
        recall=len(tp) / len(gold) if gold else None,
        false_positives=[json.loads(value) for value in sorted(fp)],
        false_negatives=[json.loads(value) for value in sorted(fn)],
    )


def load_evidence(reference):
    """부모 수집기는 경로뿐 아니라 실측 직후 봉인한 해시를 요구한다."""
    if not isinstance(reference, dict) or set(reference) != {"path", "sha256"}:
        raise ValueError("Evidence requires an exact path and SHA-256 reference")
    path = Path(reference["path"])
    if digest(path) != reference["sha256"]:
        raise ValueError(f"Changed evidence artifact: {path}")
    return json.loads(path.read_text())


def derive_required_gates(evidence):
    """실행 산출물 스키마에서 기본 게이트를 계산한다. 미실행 수명주기는 실패로 남긴다.

    네이티브 stale 경고, rename/delete/restoration 전용 수집기는 아직 연결되지 않았다.
    따라서 이 검증 프로토타입은 최종 통계 헬퍼를 통과시키는 레코드를 내보내지 않는다.
    """
    if set(evidence) - {"states"}:
        raise ValueError("Only sealed state bundles are accepted; handwritten gate flags are forbidden")
    checks = {name: [] for name in REQUIRED_GATES}
    states = {}
    for bundle in evidence.get("states", []):
        if set(bundle) != {"state", "oracle", "config"}:
            raise ValueError("Expected sealed state, oracle and configuration artifacts")
        state, oracle, config = (load_evidence(bundle[key]) for key in ("state", "oracle", "config"))
        if state["state_id"] != config["state_id"] or state["state_id"] in states:
            raise ValueError("Repeated or inconsistent state identity")
        states[state["state_id"]] = state
        arms = [state.get(name, {}) for name in ("baseline", "cartograph")]
        ready = all(
            a.get("status") == "ok"
            and a.get("exit_code") == 0
            and a.get("guard_before", {}).get("status") == "passed"
            and a.get("guard_after", {}).get("status") == "passed"
            and a.get("result", {}).get("status") == "ok"
            and a.get("measurement", {}).get("status") == "ok"
            for a in arms
        )
        if not ready:
            for name in checks:
                checks[name].append(dict(passed=False, reason="A required real arm failed or did not execute"))
            continue
        caches = [a["result"].get("reader_cache") for a in arms]
        checks["private_reader_state"].append(
            dict(
                passed=all(caches)
                and len(set(caches)) == 2
                and all(a["result"].get("reader_cache_initial_entries") == [] for a in arms)
            )
        )
        checks["common_index_before_after"].append(
            dict(
                passed=arms[0]["index_path"] == arms[1]["index_path"]
                and arms[0]["index_before"]["file_count"] > 0
                and all(a["index_before"] == a["index_after"] == arms[0]["index_before"] for a in arms)
                and all(a["result"].get("validated_library_sha256") == config["library_sha256"] for a in arms)
            )
        )
        for name, a in zip(("baseline", "cartograph"), arms):
            result = a["result"]
            queries = result["observation"]["queries"]
            checks["source_oracle"].append(exact_gate(result["graph"]["edges"], oracle.get("edges")))
            checks["source_oracle"].append(exact_gate(queries, oracle.get("queries")))
            checks["ten_query_batches"].append(
                dict(
                    passed=len(queries) == 10
                    and [q["id"] for q in queries] == [q["id"] for q in config["queries"]]
                    and len({q["id"] for q in queries}) == 10
                )
            )
            negative = oracle.get("negative_controls")
            if not isinstance(negative, dict) or not negative:
                checks["negative_controls"].append(dict(passed=False, reason="Missing explicit negative controls"))
            else:
                by_id = {q["id"]: q for q in queries}
                violations = [
                    {"query": key, "id": item["id"]}
                    for key, excluded in negative.items()
                    for item in by_id[key]["transitive"]
                    if item["id"] in excluded
                ]
                checks["negative_controls"].append(dict(passed=not violations, violations=violations))
            commands = [i["command"] for i in result["invocations"]]
            valid_regime = result["regime"] == "fresh-reader-source-selector-cli-batch"
            if name == "baseline":
                valid_regime &= result.get("reverse_adjacency_build_count") == 1
            else:
                valid_regime &= len(commands) == 2 and "graph" in commands[0] and "--include-self-loops" in commands[0]
                valid_regime &= "query" in commands[1] and "--batch" in commands[1]
            checks["equivalent_session_state"].append(
                dict(passed=valid_regime and result.get("default_projection_diagnostic_executed") is False)
            )
    if {"initial", "post_edit"} <= set(states):
        initial, post = states["initial"], states["post_edit"]
        ready = all(
            s.get(a, {}).get("result", {}).get("status") == "ok"
            for s in (initial, post)
            for a in ("baseline", "cartograph")
        )
        changed = ready and initial["baseline"]["index_before"] != post["baseline"]["index_before"]
        changed = (
            changed
            and initial["baseline"]["result"]["validated_sources"] != post["baseline"]["result"]["validated_sources"]
        )
        checks["refresh"].append(dict(passed=bool(changed) and all(c["passed"] for c in checks["source_oracle"])))
    gates = {
        name: dict(
            passed=bool(items) and all(item["passed"] for item in items),
            checks=items,
            reason=None if items else "Required dedicated lifecycle verifier not executed",
        )
        for name, items in checks.items()
    }
    return dict(
        gates=gates,
        all_passed=all(g["passed"] for g in gates.values()),
        final_export_enabled=False,
        required_unimplemented_collectors=["native_stale_input", "rename_delete", "restoration"],
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--order", choices=["AB", "BA"], default="AB")
    parser.add_argument("--mode", choices=["timing", "memory"], default="timing")
    parser.add_argument("--baseline-only", action="store_true")
    args = parser.parse_args()
    if args.worker:
        result = execute_worker(json.loads(args.worker.read_text()))
        raise SystemExit(0 if result["status"] == "ok" else 125 if result["status"] == "incomplete" else 1)
    if not args.config or not args.output:
        parser.error("--config and --output are required")
    result = run_state(json.loads(args.config.read_text()), args.output, args.order, args.mode, args.baseline_only)
    print(json.dumps(dict(state_id=result["state_id"], final_evidence=False), sort_keys=True))
    raise SystemExit(result["exit_code"])


if __name__ == "__main__":
    main()
