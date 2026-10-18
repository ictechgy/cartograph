#!/usr/bin/env python3
"""실제 고정 index-dump와 Cartograph를 같은 컴파일 인덱스로 비교한다.

도구의 API를 CLI인 것처럼 대체하지 않고, 외부 조립 비용과 질의 비용을 구분한다.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import platform
import random
import re
import resource
import shutil
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

UPSTREAM = "https://github.com/swiftlang/indexstore-db.git"
REVISION = "64aa0b26913249c4e7c21d351a215fba02702003"
BRANCH = "release/6.4.1"
SCHEMA_VERSION = 1
CLI_DESCRIPTION = (
    "Compare real pinned index-dump plus explicit assembly with native Cartograph queries. "
    "Only explicit --baseline-only runs may omit Cartograph; they never report passed."
)


def save(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], cwd: Path, stem: Path, timeout: float = 300) -> dict[str, Any]:
    """명령과 원문 출력을 남기고 명령별 wait4 자원 사용량을 기록한다.

    RSS는 운영체제가 반환한 프로세스 최대치이며 동시 프로세스 트리 합계가 아니다.
    1 ms 종료 확인 주기는 일반적인 스케줄러 지연과 함께 실행 시간에 포함된다.
    """
    stem.parent.mkdir(parents=True, exist_ok=True)
    stdout, stderr = Path(str(stem) + ".stdout"), Path(str(stem) + ".stderr")
    started = time.perf_counter()
    timed_out, terminated_at, usage, returncode = False, None, None, None
    with stdout.open("wb") as out, stderr.open("wb") as err:
        process = subprocess.Popen(command, cwd=cwd, stdout=out, stderr=err, start_new_session=True)
        try:
            while True:
                pid, status, observed = os.wait4(process.pid, os.WNOHANG)
                if pid:
                    usage = observed
                    returncode = os.waitstatus_to_exitcode(status)
                    process.returncode = returncode
                    break
                elapsed = time.perf_counter() - started
                if elapsed > timeout and terminated_at is None:
                    timed_out, terminated_at = True, time.perf_counter()
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                elif terminated_at is not None and time.perf_counter() - terminated_at > 5:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                time.sleep(0.001)
        finally:
            if returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                _, status, usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
    result = {
        "command": command,
        "cwd": str(cwd),
        "returncode": 124 if timed_out else returncode,
        "timed_out": timed_out,
        "wall_seconds": time.perf_counter() - started,
        "wait4_maxrss_bytes": int(usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)),
        "user_seconds": usage.ru_utime,
        "system_seconds": usage.ru_stime,
        "stdout": str(stdout),
        "stderr": str(stderr),
    }
    save(Path(str(stem) + ".json"), result)
    if result["returncode"]:
        raise RuntimeError(f"Command failed ({result['returncode']}): {command}; see {stderr}")
    return result


def capture(command: list[str], cwd: Path, stem: Path, timeout: float = 300) -> tuple[str, dict]:
    measurement = run(command, cwd, stem, timeout)
    return Path(measurement["stdout"]).read_text(encoding="utf-8"), measurement


def fingerprint(root: Path) -> dict[str, Any]:
    """디렉터리 시각 대신 인덱스 바이트를 검증하되 질의 측정에서는 제외한다."""
    entries = [(str(path.relative_to(root)), sha256(path)) for path in sorted(root.rglob("*")) if path.is_file()]
    digest = hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()
    return {"sha256": digest, "file_count": len(entries)}


def selectors(project: Path) -> dict[str, dict[str, Any]]:
    result = {}
    for path in sorted((project / "Sources").glob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            marker = re.search(r"// oracle: ([a-z0-9_]+)\s*$", line)
            if not marker:
                continue
            declaration = re.search(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
            if not declaration or marker[1] in result:
                raise ValueError(f"Invalid/duplicate oracle marker in {path}:{number}")
            result[marker[1]] = {
                "path": str(path.resolve()),
                "line": number,
                "column": len(line[: declaration.start(1)].encode("utf-8")) + 1,
                "name": declaration[1],
            }
    if not result:
        raise ValueError("Fixture contains no source selectors")
    return result


def bind_symbols(found: dict[str, set[str]], expected: dict[str, dict]) -> dict[str, str]:
    missing = {key: sorted(found.get(key, set())) for key in expected if len(found.get(key, set())) != 1}
    if missing:
        raise ValueError(f"Source selectors must each resolve to exactly one symbol: {missing}")
    bound = {key: next(iter(found[key])) for key in expected}
    if len(set(bound.values())) != len(bound):
        raise ValueError("Distinct source declarations resolved to the same USR")
    return bound


def location_label(path: Path, line: int, column: int, name: str, expected: dict[str, dict]) -> str | None:
    for label, selector in expected.items():
        if (str(path.resolve()), line, column, name.split("(", 1)[0]) == (
            selector["path"],
            selector["line"],
            selector["column"],
            selector["name"],
        ):
            return label
    return None


def reverse_adjacency(edges: set[tuple[str, str]]) -> dict[str, set[str]]:
    reverse: dict[str, set[str]] = {}
    for caller, callee in edges:
        reverse.setdefault(callee, set()).add(caller)
    return reverse


def callers_from_reverse(reverse: dict[str, set[str]], target: str) -> dict[str, list[str]]:
    direct = reverse.get(target, set())
    visited, pending = set(), list(direct)
    while pending:
        current = pending.pop()
        if current in visited:
            continue
        visited.add(current)
        pending.extend(reverse.get(current, set()) - visited)
    visited.discard(target)
    return {"direct": sorted(direct - {target}), "transitive": sorted(visited)}


def reverse_callers(edges: set[tuple[str, str]], target: str) -> dict[str, list[str]]:
    return callers_from_reverse(reverse_adjacency(edges), target)


def components(edges: set[tuple[str, str]]) -> list[list[str]]:
    """작은 픽스처의 상호 도달성으로 두 제품과 독립적인 SCC 기대값을 검증한다."""
    nodes = {item for edge in edges for item in edge}
    remaining, groups = set(nodes), []
    reverse = reverse_adjacency(edges)
    reach = {node: set(callers_from_reverse(reverse, node)["transitive"]) | {node} for node in nodes}
    while remaining:
        seed = min(remaining)
        group = {node for node in remaining if seed in reach[node] and node in reach[seed]}
        remaining -= group
        if len(group) > 1 or (seed, seed) in edges:
            groups.append(sorted(group))
    return sorted(groups)


def caller_answers(edges: set[tuple[str, str]], targets: list[str]) -> dict[str, Any]:
    """측정 구간에서는 두 실행 도구가 요청받은 호출자 배치만 계산한다."""
    # 한 인덱스 세대의 배치에서 역방향 인접 목록은 한 번만 만든다.
    reverse = reverse_adjacency(edges)
    return {"callers": {target: callers_from_reverse(reverse, target) for target in targets}}


def graph_answers(edges: set[tuple[str, str]], targets: list[str]) -> dict[str, Any]:
    return {
        "edges": sorted([list(edge) for edge in edges]),
        "cycles": components(edges),
        **caller_answers(edges, targets),
    }


def baseline_graph(
    cli: Path,
    library: Path,
    project: Path,
    store: Path,
    targets: list[str],
    out: Path,
    task: str = "discovery",
    symbol_ids: dict[str, str] | None = None,
) -> dict:
    if task not in ("discovery", "callers"):
        raise ValueError(f"Unknown baseline task: {task}")
    if task == "callers" and (not symbol_ids or not all(target in symbol_ids for target in targets)):
        raise ValueError("Caller-only baseline requires previously resolved source selectors")
    expected = selectors(project) if task == "discovery" else {}
    invocations, records = [], {}
    discovery_started = time.perf_counter()
    unit_names = sorted(path.name for path in (store / "v5" / "units").iterdir() if path.is_file())
    if not unit_names:
        raise ValueError("Index store contains no units")

    def dump(name: str, kind: str) -> str:
        text, measurement = capture(
            [str(cli), name, "--index-store", str(store), "--lib-index-store", str(library)],
            project,
            out / f"{kind}-{name}",
            60,
        )
        invocations.append(measurement)
        return text

    for unit in unit_names:
        for line in dump(unit, "unit").splitlines():
            if not line.startswith("Record | user | "):
                continue
            fields = line.split(" | ")
            path = Path(fields[-2]).resolve()
            if path.is_relative_to((project / "Sources").resolve()) and path.is_file():
                name = fields[-1]
                if name in records and records[name] != path:
                    raise ValueError("One record unexpectedly has multiple project source paths")
                records[name] = path
    discovery_seconds = time.perf_counter() - discovery_started
    texts = {name: dump(name, "record") for name in sorted(records)}
    if not texts:
        raise ValueError("No current project records found")
    assembly_started = time.perf_counter()
    owned, raw_edges, found = set(), set(), {}
    for record, content in texts.items():
        section, callee = None, None
        for line in content.splitlines():
            if line in ("Symbols:", "Occurrences:"):
                section = line
                continue
            if not line:
                continue
            parts = line.split(" | ")
            if section == "Symbols:":
                if len(parts) != 4:
                    raise ValueError(f"Unsupported pinned symbol output: {line}")
                roles = set(parts[3].split(", "))
                if roles & {"definition", "declaration"}:
                    owned.add(parts[2])
            elif section == "Occurrences:":
                if line.startswith("  "):
                    if len(parts) != 2 or callee is None:
                        raise ValueError(f"Unsupported pinned relation output: {line}")
                    if "calledBy" in parts[0].strip().split(", "):
                        raw_edges.add((parts[1], callee))
                else:
                    if len(parts) != 5 or not re.fullmatch(r"\d+:\d+", parts[0]):
                        raise ValueError(f"Unsupported pinned occurrence output: {line}")
                    row, column = map(int, parts[0].split(":"))
                    callee = parts[3]
                    if task == "discovery":
                        label = location_label(records[record], row, column, parts[1], expected)
                        if label:
                            found.setdefault(label, set()).add(callee)
    if task == "discovery":
        symbol_ids = bind_symbols(found, expected)
    assert symbol_ids is not None
    labels = {usr: label for label, usr in symbol_ids.items()}
    edges = {
        (labels.get(a, f"unmapped:{a}"), labels.get(b, f"unmapped:{b}"))
        for a, b in raw_edges
        if a in owned and b in owned
    }
    assembly_seconds = time.perf_counter() - assembly_started
    query_started = time.perf_counter()
    answers = graph_answers(edges, targets) if task == "discovery" else caller_answers(edges, targets)
    return {
        "arm": "actual-index-dump-plus-external-assembly",
        "task": task,
        "symbol_ids": symbol_ids,
        "answers": answers,
        "units": len(unit_names),
        "records": len(records),
        "discovery_seconds": discovery_seconds,
        "assembly_seconds": assembly_seconds,
        "query_only_seconds": time.perf_counter() - query_started,
        "invocations": invocations,
        "native_freshness_warning": "unsupported; no native warning score assigned",
        "output_role_note": "Printed occurrence roles are symbol-wide; caller edges use calledBy relations.",
    }


def parse_cartograph_graph(document: dict, project: Path, targets: list[str]) -> dict:
    if document.get("level") != "symbol" or not isinstance(document.get("nodes"), list):
        raise ValueError("Expected native Cartograph symbol graph JSON")
    expected, found, ids = selectors(project), {}, {}
    for node in document["nodes"]:
        if not isinstance(node.get("id"), str):
            raise ValueError("Invalid graph node identity")
        ids[node["id"]] = node.get("usr") or node["id"]
        location = node.get("location")
        if location:
            path = Path(location["path"])
            if not path.is_absolute():
                path = project / path
            label = location_label(path, location["line"], location["column"], node["name"], expected)
            if label:
                found.setdefault(label, set()).add(ids[node["id"]])
    bound = bind_symbols(found, expected)
    names = {usr: label for label, usr in bound.items()}
    edges = set()
    for edge in document["edges"]:
        if edge["kind"] != "call":
            continue
        if edge["source"] not in ids or edge["target"] not in ids:
            raise ValueError("Dangling graph edge")
        a, b = ids[edge["source"]], ids[edge["target"]]
        edges.add((names.get(a, f"unmapped:{a}"), names.get(b, f"unmapped:{b}")))
    return {"arm": "native-cartograph-graph", "symbol_ids": bound, "answers": graph_answers(edges, targets)}


def parse_cartograph_batch(document: dict, targets: list[str], symbol_ids: dict[str, str]) -> dict:
    if document.get("format") != "symbol-query-batch" or document.get("version") != 1:
        raise ValueError("Expected symbol-query-batch v1")
    results = document.get("results")
    if not isinstance(results, list) or len(results) != len(targets):
        raise ValueError("Batch result count differs from request count")
    labels = {usr: label for label, usr in symbol_ids.items()}
    callers, limitations = {}, {}
    for target, result in zip(targets, results):
        if result.get("requested") != symbol_ids[target] or result.get("status") != "found":
            raise ValueError(f"Missing/ambiguous/wrong native query answer for {target}: {result}")
        if result.get("level") != "symbol":
            raise ValueError("Native batch answer is not symbol-level")
        answer = result.get("result", {})
        if not isinstance(answer.get("usedBy"), list):
            raise ValueError("Native query omitted usedBy")
        truncation = answer.get("truncated")
        if not isinstance(truncation, dict) or any(
            type(truncation.get(key)) is not bool for key in ("usedBy", "dependsOn", "members")
        ):
            raise ValueError("Native query omitted explicit truncation metadata")
        if not isinstance(result.get("limitations"), list) or not all(
            isinstance(item, str) for item in result["limitations"]
        ):
            raise ValueError("Native query omitted valid limitations metadata")
        if answer.get("subject", {}).get("usr") != symbol_ids[target]:
            raise ValueError("Native query returned the wrong subject")
        if any(answer.get("truncated", {}).values()):
            raise ValueError("Native query answer was truncated")
        direct, transitive = set(), set()
        for neighbor in answer.get("usedBy", []):
            if not isinstance(neighbor.get("depth"), int) or neighbor["depth"] < 1:
                raise ValueError("Native query neighbor has no valid depth")
            if "call" not in neighbor.get("edges", []):
                raise ValueError("Call-only native query returned a non-call neighbor")
            label = labels.get(neighbor.get("usr"), f"unmapped:{neighbor.get('usr')}")
            transitive.add(label)
            if neighbor["depth"] == 1:
                direct.add(label)
        callers[target] = {"direct": sorted(direct), "transitive": sorted(transitive)}
        limitations[target] = result.get("limitations", [])
    return {"callers": callers, "limitations": limitations}


def score(actual: list[Any], expected: list[Any]) -> dict:
    encode = lambda item: json.dumps(item, sort_keys=True, separators=(",", ":"))
    observed, gold = {encode(item) for item in actual}, {encode(item) for item in expected}
    tp, fp, fn = observed & gold, observed - gold, gold - observed
    return {
        "exact_match": not fp and not fn,
        "tp": len(tp),
        "fp": len(fp),
        "fn": len(fn),
        "precision": len(tp) / len(observed) if observed else None,
        "recall": len(tp) / len(gold) if gold else None,
        "false_positives": [json.loads(item) for item in sorted(fp)],
        "false_negatives": [json.loads(item) for item in sorted(fn)],
    }


def grade(answers: dict, oracle: dict, include_graph: bool = True) -> dict:
    checks = {}
    if include_graph:
        checks["edges"] = score(answers["edges"], oracle["edges"])
        checks["cycles"] = score(answers["cycles"], sorted(sorted(group) for group in oracle["cycles"]))
    for target in oracle["targets"]:
        for direction in ("direct", "transitive"):
            checks[f"{target}:{direction}"] = score(
                answers["callers"][target][direction], oracle["expected_callers"][target][direction]
            )
    return {"passed": all(item["exact_match"] for item in checks.values()), "checks": checks}


def distribution(values: list[float | int]) -> dict:
    return {
        "n": len(values),
        "minimum": min(values),
        "median": statistics.median(values),
        "p95_nearest_rank": sorted(values)[math.ceil(len(values) * 0.95) - 1],
        "maximum": max(values),
    }


def performance_summary(samples: list[dict[str, Any]], arms: list[str]) -> dict:
    """양쪽 모두 응답 정규화까지 끝난 같은 작업 경계로 비율을 계산한다."""
    result = {
        arm: {
            key: distribution([sample[arm]["measurement"][key] for sample in samples])
            for key in ("workflow_seconds", "wall_seconds", "wait4_maxrss_bytes")
        }
        for arm in arms
    }
    result["ratio_clock"] = "workflow_seconds"
    if "cartograph" in arms:
        baseline_median = result["baseline"]["workflow_seconds"]["median"]
        cg_median = result["cartograph"]["workflow_seconds"]["median"]
        result["observed_baseline_to_cartograph_median_ratio"] = baseline_median / cg_median
        result["interpretation"] = (
            "Descriptive synthetic end-to-answer workflow result, including each arm's answer normalization; "
            "subprocess wall is secondary. Not a universal or statistically established advantage."
        )
    return result


def toolchain(swiftc_option: str | None, library_option: str | None, root: Path) -> tuple[Path, Path, dict]:
    if swiftc_option:
        swiftc = Path(swiftc_option).absolute()
    elif sys.platform == "darwin":
        text, _ = capture(["xcrun", "--find", "swiftc"], root, root / "setup" / "find-swiftc")
        swiftc = Path(text.strip())
    else:
        found = shutil.which("swiftc")
        if not found:
            raise RuntimeError("swiftc is unavailable; select a Swift 6.4 toolchain")
        swiftc = Path(found)
    if not swiftc.is_file():
        raise ValueError(f"Invalid swiftc: {swiftc}")
    library = (
        Path(library_option).resolve()
        if library_option
        else (
            swiftc.resolve().parent.parent
            / "lib"
            / ("libIndexStore.dylib" if sys.platform == "darwin" else "libIndexStore.so")
        )
    )
    if not library.is_file():
        raise ValueError(f"No libIndexStore at {library}; pass --lib-index-store from the same toolchain")
    version, measurement = capture([str(swiftc), "--version"], root, root / "setup" / "swift-version")
    return (
        swiftc,
        library,
        {
            "swiftc": str(swiftc),
            "version": version.strip(),
            "library": str(library),
            "library_sha256": sha256(library),
            "measurement": measurement,
        },
    )


def verify_untracked_build_inputs(checkout: Path, root: Path) -> dict:
    """추적 차이 검사로 보이지 않는 입력도 거부해 실제 빌드 소스의 고정을 보장한다."""
    paths, measurement = capture(
        ["git", "ls-files", "--others", "-z", "--", ":(top,glob)Package*.swift", "Sources", "Tests", "Plugins"],
        checkout,
        root / "setup" / "upstream-untracked-build-inputs",
        60,
    )
    untracked = sorted(path for path in paths.split("\0") if path)
    if untracked:
        raise ValueError(f"Comparator has untracked or ignored build inputs: {untracked}")
    return {
        "passed": True,
        "measurement": measurement,
        "scope": "Package*.swift, Sources/, Tests/, Plugins/; ignored files are included",
    }


def prepare_cli(args: argparse.Namespace, swiftc: Path, root: Path) -> tuple[Path, dict]:
    checkout = args.indexstore_checkout.resolve() if args.indexstore_checkout else root / "upstream-indexstore-db"
    setup = {"repository": UPSTREAM, "revision": REVISION, "checkout": str(checkout), "commands": []}
    if args.indexstore_checkout:
        setup["clone"] = {"status": "reused existing checkout; clone cost not measured"}
    else:
        setup["commands"].append(
            run(
                ["git", "clone", "--branch", BRANCH, "--single-branch", UPSTREAM, str(checkout)],
                root,
                root / "setup" / "clone",
                args.setup_timeout,
            )
        )
        setup["commands"].append(
            run(["git", "checkout", "--detach", REVISION], checkout, root / "setup" / "checkout-pin", 60)
        )
    head, _ = capture(["git", "rev-parse", "HEAD"], checkout, root / "setup" / "upstream-head")
    if head.strip() != REVISION:
        raise ValueError(f"Comparator checkout must be exactly {REVISION}; got {head.strip()}")
    setup["commands"].append(
        run(["git", "diff", "--exit-code", "HEAD", "--"], checkout, root / "setup" / "upstream-clean", 60)
    )
    setup["untracked_build_inputs"] = verify_untracked_build_inputs(checkout, root)
    setup["commands"].append(setup["untracked_build_inputs"]["measurement"])
    swift = swiftc.parent / "swift"
    if not swift.is_file():
        raise ValueError(f"Swift package driver absent beside {swiftc}")
    lock_source = args.fixtures / "indexstore-Package.resolved"
    if not lock_source.is_file():
        raise ValueError(f"Pinned comparator dependency lock missing: {lock_source}")
    lock = json.loads(lock_source.read_text())
    required_pins = {
        "swift-argument-parser": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
        "swift-lmdb": "a4bc87807721c1fd114bf35464457e2db0d0e6c0",
    }
    if {pin["identity"]: pin["state"]["revision"] for pin in lock["pins"]} != required_pins:
        raise ValueError("Comparator dependency lock does not match reviewed pins")
    resolved_path = checkout / "Package.resolved"
    if resolved_path.exists() and json.loads(resolved_path.read_text()) != lock:
        raise ValueError("Existing comparator dependency lock differs; use a fresh comparator checkout")
    if not resolved_path.exists():
        shutil.copy2(lock_source, resolved_path)
    setup["dependency_lock_sha256"] = sha256(lock_source)
    setup["commands"].append(
        run(
            [
                str(swift),
                "build",
                "-c",
                "release",
                "--product",
                "index-dump",
                "--force-resolved-versions",
                "-j",
                str(args.jobs),
            ],
            checkout,
            root / "setup" / "upstream-build",
            args.setup_timeout,
        )
    )
    path, _ = capture(
        [str(swift), "build", "-c", "release", "--show-bin-path"], checkout, root / "setup" / "upstream-bin-path", 120
    )
    cli = Path(path.strip()) / "index-dump"
    if not cli.is_file():
        raise ValueError(f"Built comparator binary missing at {cli}")
    setup["binary"] = str(cli)
    setup["binary_sha256"] = sha256(cli)
    resolved = checkout / "Package.resolved"
    if resolved.exists():
        shutil.copy2(resolved, root / "setup" / "indexstore-Package.resolved")
        setup["resolved_dependencies"] = json.loads(resolved.read_text())
    help_text, measurement = capture([str(cli), "--help"], root, root / "setup" / "index-dump-help")
    if "<unit-or-record-name>" not in help_text or "--index-store" not in help_text:
        raise ValueError("Pinned comparator CLI contract was not observed")
    setup["help"] = measurement
    setup["total_measured_setup_seconds"] = sum(item["wall_seconds"] for item in setup["commands"])
    return cli, setup


def verify_cartograph_library(library: Path, root: Path) -> dict:
    """현재 제품의 XcodeEnvironment와 IndexStoreLocator가 선택할 라이브러리를 맞춘다."""
    if sys.platform != "darwin":
        raise RuntimeError("The full Cartograph comparison requires macOS; --baseline-only is diagnostic only")
    developer = os.environ.get("DEVELOPER_DIR", "")
    if not developer:
        developer, _ = capture(["xcode-select", "-p"], root, root / "setup" / "developer-directory")
        developer = developer.strip()
    candidates = [
        Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
        Path("/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib"),
        Path(
            "/Applications/Xcode.app/Contents/Developer/Toolchains/"
            "XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
        ),
    ]
    selected = next((candidate for candidate in candidates if candidate.is_file()), None)
    if selected is None or sha256(selected) != sha256(library):
        raise ValueError(
            "Cartograph's DEVELOPER_DIR/xcode-select library differs from the selected compiler/comparator library; "
            "select one matching Xcode toolchain"
        )
    return {
        "developer_directory": developer,
        "cartograph_library_candidate": str(selected),
        "same_library_bytes_verified": True,
        "sha256": sha256(selected),
    }


def prepare_cartograph(args: argparse.Namespace, swiftc: Path, root: Path) -> dict:
    if args.cartograph_package:
        package = args.cartograph_package.resolve()
        if not (package / "Package.swift").is_file() or not (package / "Package.resolved").is_file():
            raise ValueError("--cartograph-package requires Package.swift and a committed dependency lock")
        head, head_measure = capture(["git", "rev-parse", "HEAD"], package, root / "setup" / "cartograph-head")
        status, status_measure = capture(
            ["git", "status", "--porcelain"], package, root / "setup" / "cartograph-source-status"
        )
        inputs = [
            package / "Package.swift",
            package / "Package.resolved",
            *sorted((package / "Sources").rglob("*.swift")),
        ]
        source_hashes = {str(path.relative_to(package)): sha256(path) for path in inputs}
        save(root / "setup" / "cartograph-source-hashes.json", source_hashes)
        source_state = {
            "revision": head.strip(),
            "working_tree_status": status,
            "input_sha256": source_hashes,
            "git_measurements": [head_measure, status_measure],
        }
        scratch = root / "cartograph-release-build"
        swift = swiftc.parent / "swift"
        build_args = [
            str(swift),
            "build",
            "--package-path",
            str(package),
            "--scratch-path",
            str(scratch),
            "-c",
            "release",
            "--product",
            "cartograph",
            "--force-resolved-versions",
            "-j",
            str(args.jobs),
        ]
        measurement = run(build_args, package, root / "setup" / "cartograph-build", args.setup_timeout)
        binary_dir, path_measure = capture(
            [
                str(swift),
                "build",
                "--package-path",
                str(package),
                "--scratch-path",
                str(scratch),
                "-c",
                "release",
                "--show-bin-path",
            ],
            package,
            root / "setup" / "cartograph-bin-path",
            120,
        )
        args.cartograph = Path(binary_dir.strip()) / "cartograph"
        if not args.cartograph.is_file():
            raise ValueError(f"Built Cartograph binary missing: {args.cartograph}")
        setup = {
            "mode": "fresh-release-package-build",
            "source": source_state,
            "source_acquisition": (
                "Repository supplied by caller/CI checkout; acquisition cost outside this measurement."
            ),
            "scratch": str(scratch),
            "build": measurement,
            "binary_discovery": path_measure,
            "build_cost_measured": True,
            "cache": "Fresh product scratch; compiler SDK/global SwiftPM caches are not flushed.",
        }
    else:
        setup = {
            "mode": "supplied-binary",
            "build_cost_measured": False,
            "build": None,
            "configuration": "unknown; caller must identify release/debug",
            "limitation": "This mode cannot support a full setup-cost comparison.",
        }
    version, measurement = capture([str(args.cartograph), "--version"], root, root / "setup" / "cartograph-version")
    return {
        "binary": str(args.cartograph),
        "binary_sha256": sha256(args.cartograph),
        "version": version.strip(),
        "measurement": measurement,
        "setup": setup,
    }


def baseline_sample(
    args: argparse.Namespace,
    cli: Path,
    library: Path,
    project: Path,
    store: Path,
    oracle: dict,
    out: Path,
    task: str = "discovery",
    symbol_ids: dict[str, str] | None = None,
) -> tuple[dict, dict]:
    started = time.perf_counter()
    config = {
        "cli": str(cli),
        "library": str(library),
        "project": str(project),
        "store": str(store),
        "targets": oracle["targets"],
        "out": str(out / "raw"),
        "task": task,
        "symbol_ids": symbol_ids,
    }
    save(out / "request.json", config)
    measurement = run(
        [sys.executable, str(Path(__file__).resolve()), "--baseline-worker", str(out / "request.json")],
        project,
        out / "process",
        args.query_timeout,
    )
    result = json.loads(Path(measurement["stdout"]).read_text())
    save(out / "result.json", result)
    measurement["workflow_seconds"] = time.perf_counter() - started
    return result, measurement


def cg_options(project: Path, store: Path) -> list[str]:
    return [
        "--project",
        str(project),
        "--config",
        str(project / ".cartograph.yml"),
        "--index-store",
        str(store),
        "--include",
        "Sources/**",
        "--edge-kind",
        "call",
    ]


def cg_graph(args: argparse.Namespace, project: Path, store: Path, oracle: dict, out: Path) -> tuple[dict, dict]:
    started = time.perf_counter()
    text, measurement = capture(
        [str(args.cartograph), "graph", "--format", "json", "--level", "symbol", *cg_options(project, store)],
        project,
        out / "cartograph-graph",
        args.query_timeout,
    )
    result = parse_cartograph_graph(json.loads(text), project, oracle["targets"])
    save(out / "cartograph-graph-normalized.json", result)
    measurement["workflow_seconds"] = time.perf_counter() - started
    return result, measurement


def cg_sample(
    args: argparse.Namespace, project: Path, store: Path, oracle: dict, symbols: dict, out: Path
) -> tuple[dict, dict]:
    started = time.perf_counter()
    save(out / "requests.json", [symbols[target] for target in oracle["targets"]])
    text, measurement = capture(
        [
            str(args.cartograph),
            "query",
            "--batch",
            str(out / "requests.json"),
            "--depth",
            "64",
            "--limit",
            "1000",
            *cg_options(project, store),
        ],
        project,
        out / "cartograph-batch",
        args.query_timeout,
    )
    result = parse_cartograph_batch(json.loads(text), oracle["targets"], symbols)
    save(out / "cartograph-batch-normalized.json", result)
    measurement["workflow_seconds"] = time.perf_counter() - started
    return result, measurement


def fixture_sdk(project: Path, out: Path) -> dict | None:
    """직접 호출한 Xcode swiftc에도 같은 선택 환경의 SDK를 명시하고 탐색 비용을 보존한다."""
    if sys.platform != "darwin":
        return None
    path, path_measurement = capture(["xcrun", "--sdk", "macosx", "--show-sdk-path"], project, out / "sdk-path", 30)
    sdk = Path(path.strip())
    if not sdk.is_absolute() or not sdk.is_dir():
        raise ValueError(f"Selected macOS SDK directory is missing or invalid: {path.strip()}")
    version, version_measurement = capture(
        ["xcrun", "--sdk", "macosx", "--show-sdk-version"], project, out / "sdk-version", 30
    )
    return {
        "path": str(sdk),
        "version": version.strip(),
        "path_discovery": path_measurement,
        "version_discovery": version_measurement,
    }


def compile_fixture(swiftc: Path, project: Path, store: Path, oracle: dict, out: Path, timeout: float) -> dict:
    build = project / ".build"
    build.mkdir(exist_ok=True)
    mapping = {
        str(source): {"object": str(build / (source.stem + ".o"))}
        for source in sorted((project / "Sources").glob("*.swift"))
    }
    save(build / "output-file-map.json", mapping)
    sdk = fixture_sdk(project, out)
    command = [
        str(swiftc),
        *(["-sdk", sdk["path"]] if sdk else []),
        "-g",
        "-Onone",
        "-parse-as-library",
        "-module-name",
        oracle["module"],
        "-index-store-path",
        str(store),
        "-output-file-map",
        str(build / "output-file-map.json"),
        *mapping,
        "-o",
        str(build / "fixture"),
    ]
    measurement = run(command, project, out / "compile", timeout)
    text, runtime = capture([str(build / "fixture")], project, out / "runtime", 30)
    if text != oracle["runtime_stdout"]:
        raise ValueError(f"Fixture runtime oracle failed: expected {oracle['runtime_stdout']!r}, got {text!r}")
    return {"sdk": sdk, "compile": measurement, "runtime": runtime, "runtime_oracle_passed": True}


def fixture_run(args: argparse.Namespace, source: Path, cli: Path, library: Path, swiftc: Path, root: Path) -> dict:
    oracle = json.loads((source / "oracle.json").read_text())
    project = root / "fixtures" / source.name
    (project / "Sources").mkdir(parents=True)
    for path in source.glob("*.swift"):
        shutil.copy2(path, project / "Sources" / path.name)
    save(project / "oracle.json", oracle)
    (project / ".cartograph.yml").write_text(
        'include: ["Sources/**"]\nexclude: []\nretention:\n  retain_public: false\n'
    )
    original_sources = {
        str(path.relative_to(project)): sha256(path) for path in sorted((project / "Sources").glob("*.swift"))
    }
    store, out = project / ".build" / "index-store", root / "runs" / source.name
    report: dict[str, Any] = {
        "name": source.name,
        "purpose": oracle["purpose"],
        "source_sha256": original_sources,
        "oracle_sha256": sha256(source / "oracle.json"),
        "project": str(project),
        "index_store": str(store),
    }
    report["fixture_build"] = compile_fixture(swiftc, project, store, oracle, out / "initial-build", args.query_timeout)
    original_index = fingerprint(store)
    baseline, base_setup = baseline_sample(
        args, cli, library, project, store, oracle, out / "selector-discovery" / "baseline"
    )
    report["selector_discovery"] = {
        "baseline": {"measurement": base_setup, "grade": grade(baseline["answers"], oracle)}
    }
    symbol_ids = baseline["symbol_ids"]
    if args.cartograph:
        cartograph_graph, graph_measure = cg_graph(
            args, project, store, oracle, out / "selector-discovery" / "cartograph"
        )
        report["selector_discovery"]["cartograph"] = {
            "measurement": graph_measure,
            "grade": grade(cartograph_graph["answers"], oracle),
        }
        if symbol_ids != cartograph_graph["symbol_ids"]:
            raise ValueError("Arms resolved different USRs for the same source selectors")
    first_base, first_base_measure = baseline_sample(
        args,
        cli,
        library,
        project,
        store,
        oracle,
        out / "first-observed" / "baseline",
        task="callers",
        symbol_ids=symbol_ids,
    )
    report["first_observed_baseline_batch"] = {
        "measurement": first_base_measure,
        "grade": grade(first_base["answers"], oracle, False),
    }
    report["discovery_plus_first_query_workflow_seconds"] = {
        "baseline": base_setup["workflow_seconds"] + first_base_measure["workflow_seconds"]
    }
    if args.cartograph:
        first, first_measure = cg_sample(args, project, store, oracle, symbol_ids, out / "first-observed")
        report["first_observed_cartograph_batch"] = {"measurement": first_measure, "grade": grade(first, oracle, False)}
        report["discovery_plus_first_query_workflow_seconds"]["cartograph"] = (
            graph_measure["workflow_seconds"] + first_measure["workflow_seconds"]
        )
    samples = []
    rng = random.Random(args.seed)
    for number in range(args.repetitions):
        order = ["baseline", "cartograph"] if args.cartograph else ["baseline"]
        rng.shuffle(order)
        pair: dict[str, Any] = {"number": number, "order": order}
        for arm in order:
            destination = out / f"repeat-{number:02}" / arm
            if arm == "baseline":
                answers, measurement = baseline_sample(
                    args, cli, library, project, store, oracle, destination, task="callers", symbol_ids=symbol_ids
                )
                checked = grade(answers["answers"], oracle, False)
            else:
                answers, measurement = cg_sample(args, project, store, oracle, symbol_ids, destination)
                checked = grade(answers, oracle, False)
            pair[arm] = {"measurement": measurement, "grade": checked}
        if fingerprint(store) != original_index:
            raise RuntimeError("Shared input index changed during paired queries")
        samples.append(pair)
    report["repeated_samples"] = samples
    report["unchanged_shared_index"] = original_index
    report["performance"] = performance_summary(
        samples, ["baseline", "cartograph"] if args.cartograph else ["baseline"]
    )

    edited_oracle = copy.deepcopy(oracle)
    edited_oracle["edges"] = [edge for edge in oracle["edges"] if edge not in oracle["edit"]["remove_edges"]]
    edited_oracle["expected_callers"] = oracle["edit"]["expected_callers"]
    source_path = project / "Sources" / oracle["edit"]["file"]
    original_text = source_path.read_text()
    if original_text.count(oracle["edit"]["before"]) != 1:
        raise ValueError("Mutation must replace exactly one source expression")
    # 소스만 편집한 시각이 인덱스 기록 시각과 같은 정밀도 구간에 놓이지 않게 한다.
    newest_unit = max(path.stat().st_mtime for path in (store / "v5" / "units").iterdir())
    delay = max(0.0, newest_unit + 1.1 - time.time())
    if delay:
        time.sleep(delay)
    freshness: dict[str, Any] = {}
    try:
        source_path.write_text(original_text.replace(oracle["edit"]["before"], oracle["edit"]["after"]))
        before_index = fingerprint(store)
        stale_base, stale_base_measure = baseline_sample(
            args,
            cli,
            library,
            project,
            store,
            oracle,
            out / "source-edit" / "baseline",
            task="callers",
            symbol_ids=symbol_ids,
        )
        freshness["source_edit_without_build"] = {
            "baseline": {
                "measurement": stale_base_measure,
                "compiled_oracle": grade(stale_base["answers"], oracle, False),
                "current_source_oracle": grade(stale_base["answers"], edited_oracle, False),
                "native_warning": "unsupported; not assigned artificial zero recall",
            }
        }
        if args.cartograph:
            stale_cg, stale_cg_measure = cg_sample(
                args, project, store, oracle, symbol_ids, out / "source-edit" / "cartograph"
            )
            warning = all(
                any(item.startswith("index-staleness:") for item in limits)
                for limits in stale_cg["limitations"].values()
            )
            freshness["source_edit_without_build"]["cartograph"] = {
                "measurement": stale_cg_measure,
                "compiled_oracle": grade(stale_cg, oracle, False),
                "current_source_oracle": grade(stale_cg, edited_oracle, False),
                "stale_source_warning_present": warning,
            }
        if before_index != original_index or fingerprint(store) != original_index:
            raise RuntimeError("Source-only edit unexpectedly changed shared index bytes")
        freshness["incremental_build"] = compile_fixture(
            swiftc, project, store, edited_oracle, out / "incremental-build", args.query_timeout
        )
        rebuilt_index = fingerprint(store)
        fresh_base, fresh_base_measure = baseline_sample(
            args,
            cli,
            library,
            project,
            store,
            edited_oracle,
            out / "rebuilt" / "baseline",
            task="callers",
            symbol_ids=symbol_ids,
        )
        base_graph, base_graph_measure = baseline_sample(
            args, cli, library, project, store, edited_oracle, out / "rebuilt" / "baseline-discovery"
        )
        freshness["after_rebuild"] = {
            "index": rebuilt_index,
            "index_changed": rebuilt_index != original_index,
            "baseline": {
                "measurement": fresh_base_measure,
                "grade": grade(fresh_base["answers"], edited_oracle, False),
                "graph_measurement": base_graph_measure,
                "graph_grade": grade(base_graph["answers"], edited_oracle),
            },
        }
        if args.cartograph:
            fresh_cg, fresh_cg_measure = cg_sample(
                args, project, store, edited_oracle, symbol_ids, out / "rebuilt" / "cartograph"
            )
            graph, graph_measure = cg_graph(args, project, store, edited_oracle, out / "rebuilt")
            freshness["after_rebuild"]["cartograph"] = {
                "measurement": fresh_cg_measure,
                "grade": grade(fresh_cg, edited_oracle, False),
                "graph_measurement": graph_measure,
                "graph_grade": grade(graph["answers"], edited_oracle),
                "stale_source_warning_cleared": not any(
                    item.startswith("index-staleness:")
                    for limits in fresh_cg["limitations"].values()
                    for item in limits
                ),
            }
        if fingerprint(store) != rebuilt_index:
            raise RuntimeError("Shared rebuilt index changed between arms")
    finally:
        source_path.write_text(original_text)
        freshness["restore_build"] = compile_fixture(
            swiftc, project, store, oracle, out / "restore-build", args.query_timeout
        )
        restored_base, restored_measure = baseline_sample(
            args,
            cli,
            library,
            project,
            store,
            oracle,
            out / "restored" / "baseline",
            task="callers",
            symbol_ids=symbol_ids,
        )
        freshness["restored"] = {
            "baseline": {"measurement": restored_measure, "grade": grade(restored_base["answers"], oracle, False)}
        }
        if args.cartograph:
            restored_cg, restored_cg_measure = cg_sample(
                args, project, store, oracle, symbol_ids, out / "restored" / "cartograph"
            )
            freshness["restored"]["cartograph"] = {
                "measurement": restored_cg_measure,
                "grade": grade(restored_cg, oracle, False),
            }
        report["freshness"] = freshness
        save(out / "fixture-result.json", report)

    checks = [
        report["selector_discovery"]["baseline"]["grade"]["passed"],
        report["first_observed_baseline_batch"]["grade"]["passed"],
    ]
    checks.extend(sample[arm]["grade"]["passed"] for sample in samples for arm in sample["order"])
    checks.extend(
        [
            freshness["source_edit_without_build"]["baseline"]["compiled_oracle"]["passed"],
            not freshness["source_edit_without_build"]["baseline"]["current_source_oracle"]["passed"],
            freshness["after_rebuild"]["index_changed"],
            freshness["after_rebuild"]["baseline"]["grade"]["passed"],
            freshness["after_rebuild"]["baseline"]["graph_grade"]["passed"],
            freshness["restored"]["baseline"]["grade"]["passed"],
        ]
    )
    if args.cartograph:
        checks.extend(
            [
                report["selector_discovery"]["cartograph"]["grade"]["passed"],
                report["first_observed_cartograph_batch"]["grade"]["passed"],
                freshness["source_edit_without_build"]["cartograph"]["compiled_oracle"]["passed"],
                freshness["source_edit_without_build"]["cartograph"]["stale_source_warning_present"],
                freshness["after_rebuild"]["cartograph"]["grade"]["passed"],
                freshness["after_rebuild"]["cartograph"]["graph_grade"]["passed"],
                freshness["after_rebuild"]["cartograph"]["stale_source_warning_cleared"],
                freshness["restored"]["cartograph"]["grade"]["passed"],
            ]
        )
    report["passed"] = all(checks)
    save(out / "fixture-result.json", report)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=CLI_DESCRIPTION)
    parser.add_argument("--cartograph", type=Path, help="Existing executable; build configuration/cost unknown")
    parser.add_argument(
        "--cartograph-package",
        type=Path,
        help="Build Cartograph release in fresh scratch and measure full resolve/build",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--fixtures", type=Path, default=Path(__file__).resolve().parents[1] / "Fixtures" / "IndexStoreCLIBenchmark"
    )
    parser.add_argument(
        "--indexstore-checkout", type=Path, help="Reuse only an unchanged checkout already at the exact pin"
    )
    parser.add_argument("--swiftc")
    parser.add_argument("--lib-index-store")
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20261012)
    parser.add_argument("--setup-timeout", type=float, default=1200)
    parser.add_argument("--query-timeout", type=float, default=120)
    parser.add_argument(
        "--baseline-only", action="store_true", help="Diagnostic mode; never reports a passed Cartograph comparison"
    )
    parser.add_argument("--baseline-worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.baseline_worker:
        config = json.loads(args.baseline_worker.read_text())
        result = baseline_graph(
            Path(config["cli"]),
            Path(config["library"]),
            Path(config["project"]),
            Path(config["store"]),
            config["targets"],
            Path(config["out"]),
            task=config["task"],
            symbol_ids=config.get("symbol_ids"),
        )
        print(json.dumps(result, sort_keys=True))
        return 0
    if not args.output or not 1 <= args.repetitions <= 50 or args.jobs < 1:
        parser.error("--output, repetitions between 1 and 50, and positive --jobs are required")
    if sum([args.baseline_only, bool(args.cartograph), bool(args.cartograph_package)]) != 1:
        parser.error("Supply exactly one of --cartograph, --cartograph-package, or diagnostic --baseline-only")
    if args.cartograph:
        args.cartograph = args.cartograph.resolve()
        if not args.cartograph.is_file() or not os.access(args.cartograph, os.X_OK):
            parser.error("--cartograph must name an executable file")
    root = args.output.resolve()
    if root.exists() and any(root.iterdir()):
        parser.error("--output must be absent or empty; existing evidence is never overwritten")
    root.mkdir(parents=True, exist_ok=True)
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "status": "running",
        "revision": REVISION,
        "machine": {
            "platform": platform.platform(),
            "architecture": platform.machine(),
            "python": sys.version,
            "cpu_count": os.cpu_count(),
        },
        "measurement_contract": {
            "cache": (
                "New processes for every query; repeated OS caches uncontrolled/likely warm; no persistent MCP session."
            ),
            "cold": (
                "First-observed process launches only. Filesystem caches were not flushed; "
                "both first batches follow separately measured selector discovery."
            ),
            "rss": "wait4 ru_maxrss normalized to bytes; not simultaneous aggregate process-tree RSS.",
            "baseline": (
                "Actual upstream index-dump subprocesses plus explicitly measured Python assembly; no API proxy."
            ),
            "scope": (
                "Two fixed synthetic source-verified fixtures; "
                "no universal superiority or statistically blinded holdout claim."
            ),
            "query_tasks": (
                "Only the same direct/transitive caller batch is timed in each arm. "
                "Baseline SCC/graph validation and selector resolution occur separately."
            ),
            "cycle_tasks": "SCCs derived separately from each arm's call edges; native cycle command not benchmarked.",
            "setup": (
                "Comparator acquisition/build and selector-discovery costs reported separately. "
                "Fresh Cartograph release build measured with --cartograph-package; "
                "supplied-binary cost is unknown. Compiler/global dependency caches are not flushed."
            ),
        },
        "fixtures": [],
    }
    save(root / "results.json", result)
    try:
        swiftc, library, compiler = toolchain(args.swiftc, args.lib_index_store, root)
        result["toolchain"] = compiler
        if args.cartograph or args.cartograph_package:
            result["toolchain"]["cartograph_library_check"] = verify_cartograph_library(library, root)
            result["cartograph"] = prepare_cartograph(args, swiftc, root)
            save(root / "results.json", result)
        cli, setup = prepare_cli(args, swiftc, root)
        result["comparator_setup"] = setup
        cases = [args.fixtures / "basic", args.fixtures / "holdout"]
        for case in cases:
            if not (case / "oracle.json").is_file():
                raise ValueError(f"Required source oracle missing: {case}")
            result["fixtures"].append(fixture_run(args, case, cli, library, swiftc, root))
            save(root / "results.json", result)
        passed = all(case["passed"] for case in result["fixtures"])
        result["status"] = ("baseline_only" if args.baseline_only else "passed") if passed else "failed"
        result["correctness_and_freshness_passed"] = passed
        result["superiority_claim"] = None
        save(root / "results.json", result)
        print(json.dumps({"status": result["status"], "results": str(root / "results.json")}, sort_keys=True))
        return 0 if passed else 1
    except (Exception, KeyboardInterrupt) as error:
        result["status"] = "blocked" if not result.get("comparator_setup") else "failed"
        result["error"] = f"{type(error).__name__}: {error}"
        result["superiority_claim"] = None
        save(root / "results.json", result)
        print(
            json.dumps({"status": result["status"], "error": result["error"], "results": str(root / "results.json")}),
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
