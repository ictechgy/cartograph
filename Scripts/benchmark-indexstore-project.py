#!/usr/bin/env python3
"""고정 공개 프로젝트의 소스 오라클로 실제 CLI 두 도구를 검증한다.

최종 홀드아웃이나 우월성 판정을 대신하지 않으며 기대값을 도구 출력에서 만들지 않는다.
"""

from __future__ import annotations

import argparse
from collections import deque
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import re
import shutil
import sys
import time
from typing import Any

BASE_PATH = Path(__file__).with_name("benchmark-indexstore-cli.py")
SPEC = importlib.util.spec_from_file_location("indexstore_cli_adapter", BASE_PATH)
assert SPEC and SPEC.loader
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)
FIXTURE = BASE_PATH.parents[1] / "Fixtures" / "IndexStoreCLIBenchmark" / "argument-parser-validation"
PROJECT_REVISION = "6a52f3251125d74daf04fcbd5e6f08a75d074382"
FROZEN_HASHES = {
    "DESIGN.md": "310ccab8f3ee79dba1a24f4dae1c29c6388c0624826c28297c6d73f6d21210ed",
    "oracle.json": "f7c68d46d669c522da944c64f750a78a421c45128b3c357bd14d19681f6ba7a8",
    "source-manifest.json": "e133e7e5f45b6fbf5fce6cb0206042834eee363a28fd206196489cfda34e2340",
    "source-mention-audit.txt": "5eac8a47adcb751be7c8f36bccf9195c050e928118d5bb6811f2ec90d763a858",
    "verify_oracle.py": "f67e2e61ef3d69f10e88cd5027692925cf0104587ab905bcd7a7de253f4e4d13",
}
CALLABLE_KINDS = {"function", "instanceMethod", "classMethod", "staticMethod", "constructor", "destructor"}
CG_CALLABLE_KINDS = {"function", "method", "init", "deinit", "subscript"}


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def frozen_inputs(fixture: Path = FIXTURE) -> tuple[dict, dict]:
    """소스 감사 때 고정한 바이트와 현재 검증 계약을 실행 전에 확인한다."""
    for name, digest in FROZEN_HASHES.items():
        if BASE.sha256(fixture / name) != digest:
            raise ValueError(f"Frozen source evidence changed: {name}; human review required")
    declared = {
        name: digest for digest, name in (line.split() for line in (fixture / "SHA256SUMS").read_text().splitlines())
    }
    if declared != FROZEN_HASHES:
        raise ValueError("Frozen SHA256SUMS does not match the preregistered source evidence")
    oracle, manifest = read_json(fixture / "oracle.json"), read_json(fixture / "source-manifest.json")
    if oracle["project"]["revision"] != PROJECT_REVISION or manifest["revision"] != PROJECT_REVISION:
        raise ValueError("Unexpected public project revision")
    if [query["max_depth"] for query in oracle["queries"]] != [1, 3, 5]:
        raise ValueError("The frozen depth-boundary tasks changed")
    return oracle, manifest


def source_files(manifest: dict) -> set[str]:
    return {
        entry["path"]
        for entry in manifest["files"]
        if entry["path"].endswith(".swift") and entry["path"] != "Package.swift"
    }


def verify_sources(project: Path, manifest: dict, oracle: dict) -> dict:
    """예상 간선을 도구와 무관하게 검증하고 빌드 입력의 추가·변경을 거부한다."""
    contents = {}
    for entry in manifest["files"]:
        path = project / entry["path"]
        if path.is_symlink() or BASE.sha256(path) != entry["sha256"]:
            raise ValueError(f"Frozen source hash mismatch: {entry['path']}")
        contents[entry["path"]] = path.read_text().splitlines()
    actual = {
        str(path.relative_to(project))
        for target in oracle["scope"]["included_targets"]
        for path in (project / "Sources" / target).rglob("*.swift")
    }
    if actual != source_files(manifest):
        raise ValueError("The built source-file universe differs from the frozen manifest")
    nodes = {node["id"]: node for node in oracle["nodes"]}
    if len(nodes) != len(oracle["nodes"]):
        raise ValueError("Duplicate authored node identity")
    for node in nodes.values():
        lines = contents[node["path"]]
        line = lines[node["declaration_line"] - 1]
        if line.strip() != node["declaration_text"] or not line[node["declaration_name_column"] - 1 :].startswith(
            node["name"] + "("
        ):
            raise ValueError(f"Frozen declaration anchor changed: {node['id']}")
        if lines[node["definition_end_line"] - 1].strip() != "}":
            raise ValueError(f"Frozen definition range changed: {node['id']}")
    for edge in oracle["edges"]:
        caller = nodes[edge["caller"]]
        if edge["path"] != caller["path"] or len(edge["call_lines"]) != len(edge["call_text"]):
            raise ValueError("Invalid authored call-site evidence")
        for line, text in zip(edge["call_lines"], edge["call_text"]):
            if (
                not caller["declaration_line"] <= line <= caller["definition_end_line"]
                or contents[edge["path"]][line - 1].strip() != text
            ):
                raise ValueError(f"Frozen call-site anchor changed: {edge['caller']}:{line}")
    authored = {"edges": [[edge["caller"], edge["callee"]] for edge in oracle["edges"]]}
    for query in oracle["queries"]:
        answer = reverse_depths(authored["edges"], query["seed"], query["max_depth"])
        if (
            answer != {item["id"]: item["minimum_depth"] for item in query["expected"]}
            or len(answer) != query["expected_count"]
        ):
            raise ValueError(f"Authored graph/depth inconsistency: {query['id']}")
    return {
        "verified_files": len(manifest["files"]),
        "source_call_edges": len(oracle["edges"]),
        "source_call_sites": sum(len(edge["call_lines"]) for edge in oracle["edges"]),
    }


def source_identity(project: Path, path: str, line: int, column: int, allowed: set[str]) -> str | None:
    absolute = Path(path)
    if not absolute.is_absolute():
        absolute = project / absolute
    try:
        relative = str(absolute.resolve().relative_to(project.resolve()))
    except ValueError:
        return None
    if relative not in allowed:
        return None
    if type(line) is not int or type(column) is not int or line < 1 or column < 1:
        raise ValueError("Invalid source declaration location")
    return f"{relative}:{line}:{column}"


def declaration_anchor(project: Path, source_id: str, name: str) -> bool:
    """집계된 occurrence 역할 대신 실제 소스의 선언 이름 위치를 확인한다."""
    path, row, column = source_id.rsplit(":", 2)
    lines = (project / path).read_text().splitlines()
    if int(row) > len(lines):
        raise ValueError(f"Declaration location beyond source: {source_id}")
    line = lines[int(row) - 1]
    prefix = line.encode("utf-8")[: int(column) - 1].decode("utf-8")
    suffix = line.encode("utf-8")[int(column) - 1 :].decode("utf-8")
    base_name = name.split("(", 1)[0]
    if base_name in {"init", "deinit", "subscript"}:
        return bool(
            re.fullmatch(
                r"\s*(?:(?:public|private|fileprivate|internal|package|required|convenience|override|nonisolated)\s+)*",
                prefix,
            )
        ) and bool(re.match(rf"{base_name}\b", suffix))
    return bool(re.search(r"\bfunc\s+`?$", prefix)) and suffix.lstrip("`").startswith(base_name)


def unique_bindings(candidates: dict[str, set[str]], oracle: dict) -> dict[str, str]:
    expected = {node["source_id"]: {} for node in oracle["nodes"]}
    return BASE.bind_symbols(candidates, expected)


def reverse_depths(edges: list[list[str]], seed: str, maximum: int) -> dict[str, int]:
    return depths_from_reverse(BASE.reverse_adjacency(edges), seed, maximum)


def depths_from_reverse(reverse: dict[str, set[str]], seed: str, maximum: int) -> dict[str, int]:
    """준비된 세대의 역방향 인접 목록을 재사용하되 최소 깊이 계약은 유지한다."""
    distances, pending = {seed: 0}, deque([seed])
    while pending:
        current = pending.popleft()
        if distances[current] >= maximum:
            continue
        for caller in sorted(reverse.get(current, set())):
            if caller not in distances:
                distances[caller] = distances[current] + 1
                pending.append(caller)
    del distances[seed]
    return dict(sorted(distances.items()))


def normalized_graph(
    candidates: dict[str, set[str]], raw_edges: set[tuple[str, str]], owned: set[str], oracle: dict
) -> dict:
    """오라클에 없는 소스 호출자도 유지하여 새 간선을 정답에서 지우지 않는다."""
    bindings = unique_bindings(candidates, oracle)
    symbols: dict[str, str] = {}
    for source_id, usrs in candidates.items():
        if len(usrs) != 1:
            raise ValueError(f"Ambiguous compiler identity at {source_id}: {sorted(usrs)}")
        usr = next(iter(usrs))
        if usr in symbols and symbols[usr] != source_id:
            raise ValueError(f"One compiler identity has multiple declarations: {usr}")
        symbols[usr] = source_id
    edges = sorted(
        {
            (symbols.get(caller, f"unmapped:{caller}"), symbols.get(callee, f"unmapped:{callee}"))
            for caller, callee in raw_edges
            if caller in owned and callee in owned
        }
    )
    return {"bindings": bindings, "symbols": symbols, "edges": [list(edge) for edge in edges]}


def parse_records(texts: dict[str, str], project: Path, allowed: set[str], oracle: dict) -> dict:
    candidates: dict[str, set[str]] = {}
    raw_edges, owned = set(), set()
    for path, text in texts.items():
        section, callee = None, None
        for line in text.splitlines():
            if line in {"Symbols:", "Occurrences:"}:
                section, callee = line, None
                continue
            if not line:
                continue
            fields = line.split(" | ")
            if section == "Symbols:":
                if len(fields) != 4:
                    raise ValueError(f"Unsupported pinned symbol output: {line}")
                if {"definition", "declaration"} & set(fields[3].split(", ")):
                    owned.add(fields[2])
            elif section == "Occurrences:":
                if line.startswith("  "):
                    if len(fields) != 2 or callee is None:
                        raise ValueError(f"Unsupported pinned relation output: {line}")
                    if "calledBy" in fields[0].strip().split(", "):
                        raw_edges.add((fields[1], callee))
                else:
                    if len(fields) != 5 or not re.fullmatch(r"\d+:\d+", fields[0]):
                        raise ValueError(f"Unsupported pinned occurrence output: {line}")
                    row, column = map(int, fields[0].split(":"))
                    callee = fields[3]
                    identity = source_identity(project, path, row, column, allowed)
                    if (
                        identity
                        and fields[2].split(".", 1)[0] in CALLABLE_KINDS
                        and declaration_anchor(project, identity, fields[1])
                    ):
                        candidates.setdefault(identity, set()).add(callee)
            else:
                raise ValueError(f"Unexpected pinned record preamble: {line}")
    return normalized_graph(candidates, raw_edges, owned, oracle)


def baseline_discovery(config: dict) -> dict:
    project, store, out = (Path(config[key]).resolve() for key in ("project", "store", "out"))
    allowed, records, measurements = set(config["allowed"]), {}, []
    started = time.perf_counter()

    def dump(name: str, kind: str) -> str:
        text, measurement = BASE.capture(
            [config["cli"], name, "--index-store", str(store), "--lib-index-store", config["library"]],
            project,
            out / f"{kind}-{name}",
            config["timeout"],
        )
        measurements.append(measurement)
        return text

    units = sorted(path.name for path in (store / "v5" / "units").iterdir() if path.is_file())
    if not units:
        raise ValueError("The fresh project store contains no units")
    for unit in units:
        for line in dump(unit, "unit").splitlines():
            if not line.startswith("Record | user | "):
                continue
            fields = line.split(" | ")
            if len(fields) < 4:
                raise ValueError(f"Unsupported pinned unit record: {line}")
            path, record = Path(fields[-2]).resolve(), fields[-1]
            try:
                relative = str(path.relative_to(project))
            except ValueError:
                continue
            if relative not in allowed:
                continue
            if record in records and records[record] != relative:
                raise ValueError("One record maps to multiple source paths")
            records[record] = relative
    if set(records.values()) != allowed:
        raise ValueError(f"Index source coverage mismatch: missing={sorted(allowed - set(records.values()))}")
    if len(set(records.values())) != len(records):
        raise ValueError("Multiple compiler records for one source file; target context needs human review")
    discovery_seconds = time.perf_counter() - started
    texts = {records[name]: dump(name, "record") for name in sorted(records)}
    assembly = time.perf_counter()
    graph = parse_records(texts, project, allowed, config["oracle"])
    return {
        **graph,
        "unit_count": len(units),
        "record_count": len(records),
        "record_manifest": records,
        "unit_discovery_seconds": discovery_seconds,
        "assembly_seconds": time.perf_counter() - assembly,
        "invocations": measurements,
        "printed_roles": (
            "Symbol-wide aggregates; declaration identity verified from source anchors; "
            "calls from calledBy relations."
        ),
    }


def parse_cg_graph(document: dict, project: Path, allowed: set[str], oracle: dict) -> dict:
    if (
        document.get("level") != "symbol"
        or not isinstance(document.get("nodes"), list)
        or not isinstance(document.get("edges"), list)
    ):
        raise ValueError("Expected native symbol-level Cartograph graph")
    candidates: dict[str, set[str]] = {}
    ids, owned, raw_edges = {}, set(), set()
    for node in document["nodes"]:
        identifier, usr = node.get("id"), node.get("usr") or node.get("id")
        if not isinstance(identifier, str) or not isinstance(usr, str) or identifier in ids:
            raise ValueError("Invalid or duplicate graph identity")
        ids[identifier] = usr
        location = node.get("location")
        if not location:
            continue
        identity = source_identity(project, location["path"], location["line"], location["column"], allowed)
        if identity:
            owned.add(usr)
            if node.get("kind") in CG_CALLABLE_KINDS and declaration_anchor(project, identity, node["name"]):
                candidates.setdefault(identity, set()).add(usr)
    for edge in document["edges"]:
        if edge.get("kind") != "call":
            continue
        if edge["source"] not in ids or edge["target"] not in ids:
            raise ValueError("Dangling native call edge")
        raw_edges.add((ids[edge["source"]], ids[edge["target"]]))
    return normalized_graph(candidates, raw_edges, owned, oracle)


def query_requests(oracle: dict) -> list[dict]:
    nodes = {node["id"]: node["source_id"] for node in oracle["nodes"]}
    return [
        {"id": query["id"], "seed": nodes[query["seed"]], "max_depth": query["max_depth"]}
        for query in oracle["queries"]
    ]


def baseline_queries(graph: dict, requests: list[dict]) -> dict:
    return {
        request["id"]: reverse_depths(graph["edges"], request["seed"], request["max_depth"]) for request in requests
    }


def combined_answers(answer: dict[str, int], requests: list[dict]) -> dict:
    """한 최대 깊이 응답의 최소 거리로 같은 사용자 작업의 경계 답을 만든다."""
    if len({request["seed"] for request in requests}) != 1:
        raise ValueError("Combined workload requires one common source seed")
    return {
        request["id"]: {key: depth for key, depth in answer.items() if depth <= request["max_depth"]}
        for request in requests
    }


def parse_cg_query(document: dict, request: dict, graph: dict) -> dict:
    seed = request["seed"]
    usr = graph["bindings"][seed]
    if (
        document.get("format") != "symbol-query-batch"
        or document.get("version") != 1
        or len(document.get("results", [])) != 1
    ):
        raise ValueError("Expected one native batch request result")
    result = document["results"][0]
    if result.get("requested") != usr or result.get("status") != "found" or result.get("level") != "symbol":
        raise ValueError("Native seed was missing, ambiguous, or incorrect")
    answer = result.get("result", {})
    truncated = answer.get("truncated", {})
    if answer.get("subject", {}).get("usr") != usr or any(
        type(truncated.get(key)) is not bool or truncated[key] for key in ("usedBy", "dependsOn", "members")
    ):
        raise ValueError("Native answer subject/truncation contract failed")
    if not isinstance(result.get("limitations"), list) or not all(
        isinstance(item, str) for item in result["limitations"]
    ):
        raise ValueError("Native answer omitted limitations")
    if any(item.startswith("index-staleness:") for item in result["limitations"]):
        raise ValueError("Native answer reports stale index on the frozen fresh project")
    if not isinstance(answer.get("usedBy"), list):
        raise ValueError("Native answer omitted usedBy")
    observed = {}
    for neighbor in answer["usedBy"]:
        depth, identity = neighbor.get("depth"), neighbor.get("usr")
        if type(depth) is not int or not 1 <= depth <= request["max_depth"] or "call" not in neighbor.get("edges", []):
            raise ValueError("Native answer has invalid call depth/relation")
        source_id = graph["symbols"].get(identity, f"unmapped:{identity}")
        if source_id in observed:
            raise ValueError("Native answer repeats a source identity")
        observed[source_id] = depth
    return {"answer": dict(sorted(observed.items())), "limitations": result["limitations"]}


def grade(answers: dict, oracle: dict) -> dict:
    nodes = {node["id"]: node["source_id"] for node in oracle["nodes"]}
    checks = {}
    for query in oracle["queries"]:
        actual = answers.get(query["id"], {})
        expected = {nodes[item["id"]]: item["minimum_depth"] for item in query["expected"]}
        pairs = lambda values: [{"source_id": key, "minimum_depth": value} for key, value in values.items()]
        checks[query["id"]] = BASE.score(pairs(actual), pairs(expected))
        negatives = [
            item["qualified_signature"]
            for item in oracle["explicit_negative_controls"]
            if any(key.startswith(f"{item['path']}:{item['declaration_line']}:") for key in actual)
        ]
        checks[query["id"]]["negative_control_violations"] = negatives
        checks[query["id"]]["exact_match"] &= not negatives
    return {
        "passed": set(answers) == {query["id"] for query in oracle["queries"]}
        and all(check["exact_match"] for check in checks.values()),
        "checks": checks,
    }


def graph_grade(graph: dict, oracle: dict) -> dict:
    """오라클이 완전히 감사한 깊이 5 전선 안쪽 유입 간선만 통째로 비교한다."""
    nodes = {node["id"]: node for node in oracle["nodes"]}
    audited_callees = {node["source_id"] for node in nodes.values() if node["minimum_caller_depth"] < 5}
    actual = [edge for edge in graph["edges"] if edge[1] in audited_callees]
    expected = [[nodes[edge["caller"]]["source_id"], nodes[edge["callee"]]["source_id"]] for edge in oracle["edges"]]
    return BASE.score(actual, expected)


def cg_options(project: Path, store: Path, config: Path) -> list[str]:
    return [
        "--project",
        str(project),
        "--config",
        str(config),
        "--index-store",
        str(store),
        "--include",
        "Sources/ArgumentParser/**",
        "Sources/ArgumentParserToolInfo/**",
        "--edge-kind",
        "call",
    ]


def subprocess_worker(config: dict, out: Path, timeout: float) -> tuple[dict, dict]:
    started = time.perf_counter()
    BASE.save(out / "request.json", config)
    measurement = BASE.run(
        [sys.executable, config.get("runner", str(Path(__file__).resolve())), "--worker", str(out / "request.json")],
        Path(config["project"]),
        out / "process",
        timeout,
    )
    result = read_json(Path(measurement["stdout"]))
    BASE.save(out / "normalized.json", result)
    measurement["workflow_seconds"] = time.perf_counter() - started
    return result, measurement


def execute_worker(config: dict) -> dict:
    if config["task"] == "discovery":
        return baseline_discovery(config)
    graph = read_json(Path(config["graph"]))
    if BASE.sha256(Path(config["graph"])) != config["graph_sha256"]:
        raise ValueError("Frozen graph cache changed")
    if config["task"] == "baseline-query":
        return {
            "answers": combined_answers(
                reverse_depths(
                    graph["edges"],
                    config["requests"][0]["seed"],
                    max(request["max_depth"] for request in config["requests"]),
                ),
                config["requests"],
            ),
            "native_invocations": 0,
            "cache": "Persisted actual index-dump graph; cache read/JSON/BFS/serialization included.",
        }
    if config["task"] != "cartograph-query":
        raise ValueError("Unknown worker task")
    answers, measurements, limitations = {}, [], {}
    out, project = Path(config["out"]), Path(config["project"])
    requests = (
        config["requests"]
        if config.get("all_depth_commands")
        else [max(config["requests"], key=lambda request: request["max_depth"])]
    )
    for request in requests:
        request_file = out / f"{request['id']}-request.json"
        BASE.save(request_file, [graph["bindings"][request["seed"]]])
        text, measurement = BASE.capture(
            [
                config["cartograph"],
                "query",
                "--batch",
                str(request_file),
                "--depth",
                str(request["max_depth"]),
                "--limit",
                "100000",
                *cg_options(project, Path(config["store"]), Path(config["cg_config"])),
            ],
            project,
            out / request["id"],
            config["timeout"],
        )
        parsed = parse_cg_query(json.loads(text), request, graph)
        answers[request["id"]], limitations[request["id"]] = parsed["answer"], parsed["limitations"]
        measurements.append(measurement)
    if not config.get("all_depth_commands"):
        answers = combined_answers(answers[requests[0]["id"]], config["requests"])
    return {
        "answers": answers,
        "limitations": limitations,
        "invocations": measurements,
        "native_invocations": len(measurements),
    }


def reuse_tools(setup_path: Path, baseline_only: bool, root: Path) -> dict:
    setup = read_json(setup_path)
    (root / "setup").mkdir(parents=True, exist_ok=True)
    shutil.copy2(setup_path, root / "setup" / "reused-setup-results.json")
    if setup.get("status") not in {"passed", "baseline_only"} or setup.get("revision") != BASE.REVISION:
        raise ValueError("--setup-results must be a completed successful base-harness run")
    comparator, compiler = setup["comparator_setup"], setup["toolchain"]
    if comparator["revision"] != BASE.REVISION:
        raise ValueError("Comparator revision differs from the frozen real-CLI pin")
    files = {
        "cli": (comparator["binary"], comparator["binary_sha256"]),
        "library": (compiler["library"], compiler["library_sha256"]),
    }
    if not baseline_only:
        cartograph = setup.get("cartograph", {})
        files["cartograph"] = (cartograph.get("binary", ""), cartograph.get("binary_sha256", ""))
    for label, (path, digest) in files.items():
        if not Path(path).is_file() or BASE.sha256(Path(path)) != digest:
            raise ValueError(f"Reused {label} missing or changed since setup")
    swiftc, library, current = BASE.toolchain(compiler["swiftc"], compiler["library"], root)
    if os.environ.get("SWIFT_EXEC") and Path(os.environ["SWIFT_EXEC"]).resolve() != swiftc.resolve():
        raise ValueError("SWIFT_EXEC overrides the selected shared compiler")
    if current["version"] != compiler["version"] or current["library_sha256"] != compiler["library_sha256"]:
        raise ValueError("Selected toolchain differs from recorded setup")
    target, target_measurement = BASE.capture(
        [str(swiftc), "-print-target-info"], root, root / "setup" / "swift-target"
    )
    result = {label: path for label, (path, _) in files.items()}
    result.update(
        swiftc=str(swiftc),
        swiftc_sha256=BASE.sha256(swiftc),
        setup_results=str(setup_path),
        setup_results_sha256=BASE.sha256(setup_path),
        compiler=current,
        target=json.loads(target),
        target_measurement=target_measurement,
        setup_cost="Reused previously measured tools; see immutable source setup results, not a new tool build.",
    )
    if not baseline_only:
        result["cartograph_library_check"] = BASE.verify_cartograph_library(library, root)
    return result


def prepare_project(
    args: argparse.Namespace, root: Path, tools: dict, oracle: dict, manifest: dict
) -> tuple[Path, Path, dict]:
    project, scratch = root / "project", root / "project-build"
    source = str(args.project_source.resolve()) if args.project_source else oracle["project"]["repository"]
    acquisition = BASE.run(
        ["git", "clone", "--no-hardlinks", "--no-checkout", source, str(project)],
        root,
        root / "setup" / "project-clone",
        args.setup_timeout,
    )
    BASE.run(["git", "checkout", "--detach", PROJECT_REVISION], project, root / "setup" / "project-checkout", 60)
    head, _ = BASE.capture(["git", "rev-parse", "HEAD"], project, root / "setup" / "project-head")
    source_tree, _ = BASE.capture(["git", "rev-parse", "HEAD:Sources"], project, root / "setup" / "project-tree")
    status, _ = BASE.capture(
        ["git", "status", "--porcelain", "--untracked-files=all"], project, root / "setup" / "project-clean"
    )
    if head.strip() != PROJECT_REVISION or source_tree.strip() != oracle["project"]["source_tree"] or status:
        raise ValueError("Public project clone is not the clean frozen source state")
    proof = verify_sources(project, manifest, oracle)
    swift = Path(tools["swiftc"]).parent / "swift"
    command = [
        str(swift),
        "build",
        "--package-path",
        str(project),
        "--scratch-path",
        str(scratch),
        "--target",
        "ArgumentParser",
        "--enable-index-store",
        "-j",
        str(args.jobs),
    ]
    build = BASE.run(command, project, root / "runs" / "build" / "project", args.setup_timeout)
    stores = [
        path.parent for path in scratch.rglob("v5") if (path / "units").is_dir() and any((path / "units").iterdir())
    ]
    if len(stores) != 1:
        raise ValueError(f"Expected one fresh compiler index store, found {stores}")
    store = stores[0].resolve()
    verify_sources(project, manifest, oracle)
    entries = [
        {"path": str(path.relative_to(store)), "sha256": BASE.sha256(path), "bytes": path.stat().st_size}
        for path in sorted(store.rglob("*"))
        if path.is_file()
    ]
    BASE.save(root / "runs" / "build" / "index-file-manifest.json", entries)
    return (
        project,
        store,
        {
            "acquisition": acquisition,
            "build": build,
            "source_validation": proof,
            "source_tree": source_tree.strip(),
            "revision": head.strip(),
            "index_store": str(store),
            "index_fingerprint": BASE.fingerprint(store),
            "index_file_manifest_sha256": BASE.sha256(root / "runs" / "build" / "index-file-manifest.json"),
            "shared_compilation_cost_excluded_from_queries": True,
        },
    )


def discover_native_graph(
    binary: str,
    project: Path,
    store: Path,
    config: Path,
    out: Path,
    timeout: float,
    allowed: set[str],
    oracle: dict,
    mode: str,
) -> tuple[dict, dict, dict | None]:
    if mode not in {"default", "include-self-loops"}:
        raise ValueError(f"Unknown graph projection: {mode}")

    def observe(projection: str, directory: Path) -> tuple[dict, dict]:
        started = time.perf_counter()
        flags = ["--include-self-loops"] if projection == "include-self-loops" else []
        text, measurement = BASE.capture(
            [binary, "graph", "--format", "json", "--level", "symbol", *flags, *cg_options(project, store, config)],
            project,
            directory / "graph",
            timeout,
        )
        graph = parse_cg_graph(json.loads(text), project, allowed, oracle)
        BASE.save(directory / "normalized.json", graph)
        measurement["workflow_seconds"] = time.perf_counter() - started
        return graph, measurement

    graph, measurement = observe(mode, out)
    diagnostic = None
    if mode == "include-self-loops":
        default_graph, default_measurement = observe("default", out / "default-projection")
        diagnostic = {
            "projection": "default",
            "measurement": default_measurement,
            "graph_grade": graph_grade(default_graph, oracle),
            "query_grade": grade(baseline_queries(default_graph, query_requests(oracle)), oracle),
            "timing_role": "Separate default-projection diagnostic, outside complete-projection discovery/query clocks.",
            "correctness_role": "Retained against the unchanged full-call oracle; default filtering is not a complete-call contract.",
        }
    return graph, measurement, diagnostic


def run_validation(args: argparse.Namespace, root: Path, report: dict, oracle: dict, manifest: dict) -> None:
    tools = reuse_tools(args.setup_results.resolve(), args.baseline_only, root)
    report["reused_tools"] = tools
    BASE.save(root / "results.json", report)
    project, store, report["project"] = prepare_project(args, root, tools, oracle, manifest)
    config = root / "setup" / "cartograph.yml"
    config.write_text(
        'include: ["Sources/ArgumentParser/**", "Sources/ArgumentParserToolInfo/**"]\n'
        "exclude: []\nretention:\n  retain_public: false\n"
    )
    report["config_sha256"] = BASE.sha256(config)
    common = {
        "project": str(project),
        "store": str(store),
        "timeout": args.query_timeout,
        "allowed": sorted(source_files(manifest)),
        "oracle": oracle,
        "runner": str(root / "frozen-adapters" / Path(__file__).name),
    }
    discovery, discovery_measure = subprocess_worker(
        {
            **common,
            "task": "discovery",
            "cli": tools["cli"],
            "library": tools["library"],
            "out": str(root / "runs" / "discovery" / "baseline" / "raw"),
        },
        root / "runs" / "discovery" / "baseline",
        args.setup_timeout,
    )
    graphs = {"baseline": discovery}
    report["discovery"] = {
        "baseline": {
            "measurement": discovery_measure,
            "graph_grade": graph_grade(discovery, oracle),
            "query_grade": grade(baseline_queries(discovery, query_requests(oracle)), oracle),
        }
    }
    BASE.save(root / "results.json", report)
    if not args.baseline_only:
        graph, measurement, diagnostic = discover_native_graph(
            tools["cartograph"],
            project,
            store,
            config,
            root / "runs" / "discovery" / "cartograph",
            args.query_timeout,
            source_files(manifest),
            oracle,
            args.cartograph_graph_mode,
        )
        graphs["cartograph"] = graph
        if diagnostic is not None:
            report["default_projection_diagnostic"] = diagnostic
        report["discovery"]["cartograph"] = {
            "projection": args.cartograph_graph_mode,
            "measurement": measurement,
            "graph_grade": graph_grade(graph, oracle),
            "query_grade": grade(baseline_queries(graph, query_requests(oracle)), oracle),
        }
    for arm, graph in graphs.items():
        BASE.save(
            root / "runs" / "discovery" / arm / "graph-cache.json",
            {key: graph[key] for key in ("bindings", "symbols", "edges")},
        )
    if not args.baseline_only:
        graph_path = root / "runs" / "discovery" / "cartograph" / "graph-cache.json"
        contract_out = root / "runs" / "native-depth-contract"
        contract, contract_measurement = subprocess_worker(
            {
                **common,
                "task": "cartograph-query",
                "graph": str(graph_path),
                "graph_sha256": BASE.sha256(graph_path),
                "requests": query_requests(oracle),
                "all_depth_commands": True,
                "out": str(contract_out / "raw"),
                "cg_config": str(config),
                "cartograph": tools["cartograph"],
            },
            contract_out,
            args.query_timeout * 3 + 10,
        )
        report["native_depth_contract"] = {
            "measurement": contract_measurement,
            "grade": grade(contract["answers"], oracle),
            "timing_role": (
                "Separate depth 1/3/5 CLI contract check, excluded from " "the combined depth-5 user-task query clocks."
            ),
        }
    if BASE.fingerprint(store) != report["project"]["index_fingerprint"]:
        raise ValueError("Shared immutable index changed during discovery")
    orders = [["baseline"]] if args.baseline_only else [["baseline", "cartograph"], ["cartograph", "baseline"]]
    rng = random.Random(args.seed)
    paired = orders * (args.repetitions // len(orders))
    rng.shuffle(paired)
    report["query_samples"] = []
    first_order = rng.choice(orders)
    for number, order in enumerate([first_order, *paired]):
        sample = {
            "phase": "first_observed_after_discovery" if number == 0 else "repeated_process",
            "number": number,
            "order": order,
        }
        for arm in order:
            out = root / "runs" / "queries" / f"{number:03d}" / arm
            graph_path = root / "runs" / "discovery" / arm / "graph-cache.json"
            worker = {
                **common,
                "task": f"{arm}-query",
                "graph": str(graph_path),
                "graph_sha256": BASE.sha256(graph_path),
                "requests": query_requests(oracle),
                "out": str(out / "raw"),
                "cg_config": str(config),
                "cartograph": tools.get("cartograph"),
            }
            output, measurement = subprocess_worker(worker, out, args.query_timeout * 3 + 10)
            sample[arm] = {
                "measurement": measurement,
                "grade": grade(output["answers"], oracle),
                "normalized_result": str(out / "normalized.json"),
            }
        report["query_samples"].append(sample)
        if BASE.fingerprint(store) != report["project"]["index_fingerprint"]:
            raise ValueError("Shared immutable index changed between query arms")
        verify_sources(project, manifest, oracle)
        BASE.save(root / "results.json", report)
    report["repeated_process_distributions"] = {
        arm: {
            metric: BASE.distribution([sample[arm]["measurement"][metric] for sample in report["query_samples"][1:]])
            for metric in ("workflow_seconds", "wall_seconds", "wait4_maxrss_bytes")
        }
        for arm in graphs
    }
    report["first_discovery_plus_first_query_seconds"] = {
        arm: report["discovery"][arm]["measurement"]["workflow_seconds"]
        + report["query_samples"][0][arm]["measurement"]["workflow_seconds"]
        for arm in graphs
    }
    passed = all(
        item["graph_grade"]["exact_match"] and item["query_grade"]["passed"] for item in report["discovery"].values()
    ) and all(sample[arm]["grade"]["passed"] for sample in report["query_samples"] for arm in sample["order"])
    if not args.baseline_only:
        passed = passed and report["native_depth_contract"]["grade"]["passed"]
    report["validation_passed"] = passed
    report["status"] = ("baseline_only" if args.baseline_only else "passed") if passed else "failed"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Validate a frozen real public Swift project against actual pinned index-dump and native Cartograph; "
            "not a final holdout or superiority test."
        )
    )
    parser.add_argument(
        "--setup-results",
        type=Path,
        help="Successful raw results.json from benchmark-indexstore-cli.py; binaries are hash-verified and reused",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--project-source",
        type=Path,
        help="Optional local Git mirror cloned into a fresh standalone checkout at the public pin",
    )
    parser.add_argument(
        "--baseline-only", action="store_true", help="Diagnostic Linux baseline; never reports a passed comparison"
    )
    parser.add_argument(
        "--repetitions",
        type=int,
        default=4,
        help="Even number of repeated AB/BA workload pairs, plus one separately labelled first workload",
    )
    parser.add_argument(
        "--cartograph-graph-mode",
        choices=["default", "include-self-loops"],
        default="default",
        help="Explicit symbol graph projection; complete mode also retains default graph diagnostics without fallback",
    )
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20261012)
    parser.add_argument("--setup-timeout", type=float, default=1200)
    parser.add_argument("--query-timeout", type=float, default=120)
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.worker:
        print(json.dumps(execute_worker(read_json(args.worker)), sort_keys=True))
        return 0
    if (
        not args.setup_results
        or not args.output
        or args.repetitions < 2
        or args.repetitions > 50
        or args.repetitions % 2
        or args.jobs < 1
        or args.setup_timeout <= 0
        or args.query_timeout <= 0
    ):
        parser.error("Provide --setup-results, empty --output, even repetitions 2..50, and positive jobs/timeouts")
    root = args.output.resolve()
    if root.exists() and any(root.iterdir()):
        parser.error("--output must be absent or empty; evidence is never overwritten")
    root.mkdir(parents=True, exist_ok=True)
    report = {
        "schema_version": 1,
        "status": "running",
        "role": "real-project validation only; not the final holdout",
        "superiority_claim": None,
        "machine": {"platform": platform.platform(), "python": sys.version},
        "environment": {
            key: os.environ[key]
            for key in (
                "HOME",
                "XDG_CACHE_HOME",
                "CLANG_MODULE_CACHE_PATH",
                "SWIFT_MODULECACHE_PATH",
                "SWIFTPM_MODULECACHE_OVERRIDE",
                "DEVELOPER_DIR",
                "SDKROOT",
                "SWIFT_EXEC",
            )
            if key in os.environ
        },
        "parameters": {
            "repetitions": args.repetitions,
            "seed": args.seed,
            "jobs": args.jobs,
            "baseline_only": args.baseline_only,
            "cartograph_graph_mode": args.cartograph_graph_mode,
        },
    }
    BASE.save(root / "results.json", report)
    try:
        oracle, manifest = frozen_inputs()
        protocol = read_json(FIXTURE / "runner-protocol.json")
        frozen = {
            "source_evidence_sha256": FROZEN_HASHES,
            "protocol": protocol,
            "protocol_sha256": BASE.sha256(FIXTURE / "runner-protocol.json"),
            "runner_sha256": BASE.sha256(Path(__file__)),
            "base_adapter_sha256": BASE.sha256(BASE_PATH),
            "parameters": report["parameters"],
        }
        BASE.save(root / "setup" / "preregistration.json", frozen)
        (root / "frozen-adapters").mkdir()
        for path in (Path(__file__), BASE_PATH):
            shutil.copy2(path, root / "frozen-adapters" / path.name)
        shutil.copytree(FIXTURE, root / "setup" / "frozen-source-evidence")
        report["preregistration_sha256"] = BASE.sha256(root / "setup" / "preregistration.json")
        report["measurement_contract"] = protocol
        run_validation(args, root, report, oracle, manifest)
    except (Exception, KeyboardInterrupt) as error:
        report["status"] = "failed" if report.get("project") else "blocked"
        report["error"] = f"{type(error).__name__}: {error}"
        report["human_review_required"] = (
            "Do not change frozen expected answers from observed tool output. "
            "Review source and compiler representation separately."
        )
    BASE.save(root / "results.json", report)
    print(
        json.dumps(
            {"status": report["status"], "results": str(root / "results.json"), "error": report.get("error")},
            sort_keys=True,
        )
    )
    return 0 if report["status"] in {"passed", "baseline_only"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
