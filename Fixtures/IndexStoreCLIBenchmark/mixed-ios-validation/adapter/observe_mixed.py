#!/usr/bin/env python3
"""실제 고정 index-dump와 native Cartograph를 별도로 관측하는 --state 훅."""

from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import time

import mixed_adapter as adapter

REVISION = "64aa0b26913249c4e7c21d351a215fba02702003"
PINS = {
    "swift-argument-parser": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
    "swift-lmdb": "a4bc87807721c1fd114bf35464457e2db0d0e6c0",
}


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(root: Path) -> dict:
    return {str(p.relative_to(root)): digest(p) for p in sorted(root.rglob("*")) if p.is_file()}


def source_manifest(root: Path) -> dict:
    result = {}
    for directory in ["Sources", "Tests"]:
        result.update({f"{directory}/{name}": value for name, value in manifest(root / directory).items()})
    if (root / ".cartograph.yml").is_file():
        result[".cartograph.yml"] = digest(root / ".cartograph.yml")
    return result


def run(command: list[str], cwd: Path, stem: Path, timeout: int = 120) -> dict:
    stem.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, timeout=timeout, check=False)
        code, stdout, stderr = result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as error:
        code, stdout, stderr = "timeout", error.stdout or b"", error.stderr or b""
    stdout_path, stderr_path = Path(str(stem) + ".stdout"), Path(str(stem) + ".stderr")
    stdout_path.write_bytes(stdout)
    stderr_path.write_bytes(stderr)
    record = dict(
        command=command,
        cwd=str(cwd),
        exit_code=code,
        stdout=str(stdout_path),
        stderr=str(stderr_path),
        wall_seconds=time.monotonic() - started,
    )
    save(Path(str(stem) + ".json"), record)
    return record


def capture(command: list[str], cwd: Path, stem: Path) -> str:
    result = run(command, cwd, stem)
    if result["exit_code"] != 0:
        raise ValueError(f"Command failed; retained evidence: {stem}")
    return Path(result["stdout"]).read_text()


def verify_cli(cli: Path, checkout: Path, evidence: Path, out: Path) -> dict:
    """기존 공식 빌드 증거와 현재 바이트를 결합하며 새 다운로드/빌드를 하지 않는다."""
    setup = json.loads(evidence.read_text())
    setup = setup.get("comparator_setup", setup)
    if (
        setup.get("revision") != REVISION
        or setup.get("binary_sha256") != digest(cli)
        or setup.get("repository") != "https://github.com/swiftlang/indexstore-db.git"
    ):
        raise ValueError("Pinned CLI build evidence/reused binary hash mismatch")
    builds = [
        c
        for c in setup.get("commands", [])
        if "build" in c.get("command", [])
        and "--product" in c.get("command", [])
        and "index-dump" in c.get("command", [])
    ]
    if not builds or any(c.get("returncode", c.get("exit_code")) != 0 for c in builds):
        raise ValueError("Successful pinned native CLI build evidence is required")
    head = capture(["git", "rev-parse", "HEAD"], checkout, out / "upstream-head").strip()
    if head != REVISION:
        raise ValueError("Upstream source revision mismatch")
    capture(["git", "diff", "--exit-code", "HEAD", "--"], checkout, out / "upstream-clean")
    untracked = capture(
        ["git", "ls-files", "--others", "-z", "--", ":(top,glob)Package*.swift", "Sources", "Tests", "Plugins"],
        checkout,
        out / "upstream-untracked",
    )
    if untracked:
        raise ValueError("Untracked/ignored upstream build inputs present")
    lock = json.loads((checkout / "Package.resolved").read_text())
    if {p["identity"]: p["state"]["revision"] for p in lock["pins"]} != PINS:
        raise ValueError("Dependency pins mismatch")
    for name, revision in PINS.items():
        dependency = checkout / ".build/checkouts" / name
        if capture(["git", "rev-parse", "HEAD"], dependency, out / f"{name}-head").strip() != revision:
            raise ValueError(f"Dependency checkout revision mismatch: {name}")
        capture(["git", "diff", "--exit-code", "HEAD", "--"], dependency, out / f"{name}-clean")
        extras = capture(
            ["git", "ls-files", "--others", "-z", "--", ":(top,glob)Package*.swift", "Sources", "Plugins"],
            dependency,
            out / f"{name}-untracked",
        )
        if extras:
            raise ValueError(f"Untracked/ignored dependency build inputs present: {name}")
    help_text = capture([str(cli), "--help"], out, out / "index-dump-help")
    if "<unit-or-record-name>" not in help_text or "--lib-index-store" not in help_text:
        raise ValueError("Actual pinned index-dump CLI contract missing")
    return dict(
        revision=head,
        binary=str(cli),
        binary_sha256=digest(cli),
        reused_build_evidence=str(evidence),
        evidence_sha256=digest(evidence),
        dependency_lock_sha256=digest(checkout / "Package.resolved"),
    )


def option(command: list[str], name: str) -> str | None:
    if name not in command:
        return None
    if command.count(name) != 1 or command.index(name) + 1 == len(command):
        raise ValueError(f"Ambiguous compiler option: {name}")
    return command[command.index(name) + 1]


def compile_manifest(commands: list[dict], state: dict, setup: dict) -> tuple[list[dict], dict]:
    expected, contexts = [], defaultdict(set)
    project = Path(state["project"])
    builds = state.get("builds", [])
    if len(builds) != len(commands) or any(
        build.get("exit_code") != 0 or build.get("command") != command["args"]
        for build, command in zip(builds, commands)
    ):
        raise ValueError("Accepted compiler command/exit evidence is incomplete")
    for command in commands:
        argv = command["args"]
        module = option(argv, "-module-name") or ""
        provider = "swift" if module else "clang"
        target = option(argv, "-target") or state["triple"]
        sysroot = option(argv, "-sdk") or option(argv, "-isysroot")
        if target != state["triple"] or (setup.get("sdk_path") and sysroot != setup["sdk_path"]):
            raise ValueError("Compile command target/SDK differs from selected setup")
        mapping = command.get("output_file_map")
        pairs = (
            [(path, details["object"]) for path, details in mapping.items()]
            if mapping
            else list(zip(command["source_paths"], command["outputs"]))
        )
        if len(pairs) != len(command["outputs"]) or {p[1] for p in pairs} != set(command["outputs"]):
            raise ValueError("Compiler source/output association is incomplete")
        for source, output in pairs:
            relative = adapter.relative_path(project, source)
            if not relative or relative not in state["current_sources"]:
                raise ValueError(f"Active compiler source absent from accepted source manifest: {source}")
            if not Path(output).is_file():
                raise ValueError(f"Active object output missing: {output}")
            headers = []
            dependency_path = option(argv, "-MF")
            if provider == "clang":
                if not dependency_path or not Path(dependency_path).is_file():
                    raise ValueError("Clang build lacks an explicit recorded dependency file")
                dependency_text = Path(dependency_path).read_text().replace("\\\n", " ")
                _, separator, values = dependency_text.partition(":")
                if not separator:
                    raise ValueError("Malformed compiler dependency file")
                headers = sorted(
                    {
                        str(Path(value).resolve())
                        for value in shlex.split(values)
                        if value.endswith(".h") and adapter.relative_path(project, value) in state["current_sources"]
                    }
                )
            expected.append(
                dict(
                    output=output,
                    source=source,
                    module=module,
                    provider=provider,
                    target=target,
                    sysroot=sysroot,
                    project_headers=headers,
                )
            )
            if relative.startswith("Sources/"):
                contexts[relative].add(module or "BridgeKit")
    if {e["output"] for e in expected} != set(state["active_object_outputs"]):
        raise ValueError("State active outputs differ from accepted compiler command manifest")
    # 헤더는 정답 노드 목록이 아니라, 독립 소스/빌드 입력 목록에서 가져온다.
    for relative in state["current_sources"]:
        if relative.startswith("Sources/") and relative.endswith(".h"):
            contexts[relative].add("BridgeKit")
    return expected, {path: sorted(values) for path, values in contexts.items()}


def catalog_evidence(catalog: list[dict]) -> list[dict]:
    """선언 이름은 자격 정보 필드와 구분하고 내부 바인딩 자료는 그대로 둔다."""
    result = []
    for entry in catalog:
        if "declaration_lexeme" in entry:
            raise ValueError("Source catalog diagnostic key collision")
        result.append({("declaration_lexeme" if key == "token" else key): value for key, value in entry.items()})
    return result


def source_requests(catalog: list[dict], specs: list[dict]) -> list[dict]:
    requests = []
    for spec in specs:
        found = [
            entry["id"]
            for entry in catalog
            if entry["definition"] and entry["context"] == spec["context"] and entry["signature"] == spec["signature"]
        ]
        if len(found) != 1:
            raise ValueError(f"Query source anchor is missing/ambiguous: {spec}: {found}")
        requests.append(dict(id=spec["id"], seed=found[0], max_depth=spec["max_depth"]))
    if len({r["id"] for r in requests}) != len(requests):
        raise ValueError("Duplicate query IDs")
    return requests


def discover(
    cli: Path, library: Path, project: Path, store: Path, expected: list, current_sources: dict, out: Path
) -> tuple[dict, dict]:
    units = {}
    directory = store / "v5/units"
    if not directory.is_dir():
        raise ValueError("Native index unit directory absent")
    for path in sorted(directory.iterdir()):
        if path.is_file():
            text = capture(
                [str(cli), path.name, "--index-store", str(store), "--lib-index-store", str(library)],
                project,
                out / "units" / path.name,
            )
            units[path.name] = adapter.parse_unit(path.name, text)
    selected = adapter.select_units(units, expected)
    selected["units"] = units
    selected["external_records"] = []
    selected["framework_records"] = []
    source_records, user_dependencies = [], []
    for entry in [*selected["records"], *selected["files"]]:
        relative = adapter.relative_path(project, entry["absolute_path"])
        if relative and relative.startswith(("Sources/", "Tests/")):
            if relative not in current_sources:
                raise ValueError(f"Current unit still depends on deleted/unknown project source: {relative}")
            if not Path(entry["absolute_path"]).is_file():
                raise ValueError(f"Current unit source dependency missing: {relative}")
            user_dependencies.append(relative)
            metadata = units[entry["unit"]]["metadata"]
            for root_name in entry["root_units"]:
                root_metadata = units[root_name]["metadata"]
                root_output = adapter.absolute(root_metadata["Output File"], root_metadata["Working Directory"])
                root_expected = next(value for value in expected if str(Path(value["output"]).resolve()) == root_output)
                if adapter.target_key(metadata["Target"]) != adapter.target_key(root_expected["target"]):
                    raise ValueError(f"Project dependency target differs from active compile root: {relative}")
                if root_expected.get("sysroot") and adapter.absolute(
                    metadata["Sysroot"], metadata["Working Directory"]
                ) != str(Path(root_expected["sysroot"]).resolve()):
                    raise ValueError(f"Project dependency SDK differs from active compile root: {relative}")
        if entry["kind"] == "Record":
            if relative and relative.startswith("Sources/"):
                source_records.append(entry)
            elif relative and relative.startswith("Tests/"):
                selected["framework_records"].append(entry)
            else:
                selected["external_records"].append(entry)
    # 각 실제 산출물에서 주 소스 레코드와 컴파일러 .d 헤더까지 추적되어야 한다.
    all_records = source_records + selected["framework_records"]
    for expected_output in expected:
        roots = [
            name
            for name in selected["roots"]
            if adapter.absolute(units[name]["metadata"]["Output File"], units[name]["metadata"]["Working Directory"])
            == str(Path(expected_output["output"]).resolve())
        ]
        root = roots[0]
        if not any(
            record["absolute_path"] == str(Path(expected_output["source"]).resolve()) and root in record["root_units"]
            for record in all_records
        ):
            raise ValueError(f"Active output lacks its main source record: {expected_output['output']}")
        observed_paths = {
            entry["absolute_path"]
            for entry in [*selected["records"], *selected["files"]]
            if root in entry["root_units"]
        }
        missing_headers = set(expected_output.get("project_headers", [])) - observed_paths
        if missing_headers:
            raise ValueError(f"Current unit lacks compiler header dependencies: {sorted(missing_headers)}")
    selected["records"] = source_records
    selected["user_dependencies"] = sorted(set(user_dependencies))
    texts = {}
    for name in sorted({record["name"] for record in source_records}):
        texts[name] = capture(
            [str(cli), name, "--index-store", str(store), "--lib-index-store", str(library)],
            project,
            out / "records" / name,
        )
    save(out / "provenance.json", selected)
    return selected, texts


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


def library_for_cartograph(library: Path, out: Path) -> dict:
    if platform.system() != "Darwin":
        raise ValueError("Native Cartograph comparison requires macOS; portable baseline is diagnostic only")
    developer = os.environ.get("DEVELOPER_DIR") or capture(["xcode-select", "-p"], out, out / "developer-dir").strip()
    candidates = [
        Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
        Path("/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib"),
        Path(
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
        ),
    ]
    selected = next((path for path in candidates if path.is_file()), None)
    if selected is None or digest(selected) != digest(library):
        raise ValueError("Native Cartograph and compiler/comparator library bytes differ")
    return dict(path=str(selected), sha256=digest(selected), same_library_bytes=True)


def native_observations(
    binary: Path,
    project: Path,
    store: Path,
    catalog: list,
    requests: list,
    out: Path,
    graph_mode: str = "default",
) -> dict:
    if graph_mode not in {"default", "include-self-loops"}:
        raise ValueError(f"Unknown explicit native graph mode: {graph_mode}")
    command = [str(binary), "graph", "--format", "json", "--level", "symbol"]
    save(
        out / "graph-mode.json",
        dict(
            selected_mode=graph_mode,
            fallback_allowed=False,
            default_graph_evidence="default-graph" if graph_mode == "include-self-loops" else "graph",
        ),
    )
    if graph_mode == "include-self-loops":
        # 기본 모드의 손실도 독립 증거로 남기고, 호환 모드 실패를 기본 실행으로 덮지 않는다.
        default_raw = json.loads(capture([*command, *cg_options(project, store)], project, out / "default-graph"))
        default_graph = adapter.cartograph_graph(default_raw, project, catalog)
        save(out / "normalized-default-graph.json", default_graph)
        save(
            out / "default-graph-observation.json",
            adapter.graph_observation(default_graph, requests, "native-cartograph-default-graph"),
        )
        command.append("--include-self-loops")
    raw_graph = json.loads(capture([*command, *cg_options(project, store)], project, out / "graph"))
    graph = adapter.cartograph_graph(raw_graph, project, catalog)
    save(out / "normalized-graph.json", graph)
    graph_observation = adapter.graph_observation(graph, requests, "native-cartograph-graph")
    save(out / "graph-observation.json", graph_observation)
    available = [request for request in requests if request["seed"] in graph["bindings"]]
    missing = [request for request in requests if request["seed"] not in graph["bindings"]]
    if len({request["max_depth"] for request in requests}) != 1:
        raise ValueError("Native batch adapter requires a common query depth")
    if available:
        request_path = out / "requests.json"
        save(request_path, [graph["bindings"][request["seed"]] for request in available])
        raw = json.loads(
            capture(
                [
                    str(binary),
                    "query",
                    "--batch",
                    str(request_path),
                    "--depth",
                    str(available[0]["max_depth"]),
                    "--limit",
                    "100000",
                    *cg_options(project, store),
                ],
                project,
                out / "batch",
            )
        )
        query = adapter.cartograph_batch(raw, available, graph)
    else:
        query = dict(
            arm="native-cartograph-query",
            operation="compiler-callers",
            capability="supported",
            fresh=True,
            complete=False,
            unresolved=[],
            queries=[],
            limitations={},
        )
    for request in missing:
        query["queries"].append(adapter.query_item(request, {}))
        query["unresolved"].append(f'Cannot issue native query for missing source seed: {request["seed"]}')
    query["queries"].sort(key=lambda item: item["id"])
    query["complete"] = not query["unresolved"]
    save(out / "query-observation.json", query)
    return dict(graph=graph_observation, query=query)


def grade_observation(observation: dict, oracle: Path, variant: str, fixture: Path) -> dict:
    # 정답 파일은 양쪽 관측이 완료된 뒤 이 함수에서만 연다.
    spec = importlib.util.spec_from_file_location("mixed_source_grader", fixture / "score_calls.py")
    module = importlib.util.module_from_spec(spec)
    import sys

    sys.path.insert(0, str(fixture))
    try:
        spec.loader.exec_module(module)
        return module.grade(observation, json.loads(oracle.read_text()), variant)
    except ValueError as error:
        return dict(status="failed", scored=False, error=str(error), unresolved=observation.get("unresolved"))
    finally:
        sys.path.pop(0)


def grade_graph(graph: dict, oracle: Path, variant: str) -> dict:
    source = json.loads(oracle.read_text())["variants"][variant]
    identities = {node["key"]: node["id"] for node in source["nodes"]}
    expected = {(identities[edge["caller"]], identities[edge["callee"]]) for edge in source["edges"]}
    actual = {tuple(edge) for edge in graph["edges"]}
    return dict(
        status="passed" if actual == expected and not graph["unresolved"] else "failed",
        false_positive=[list(edge) for edge in sorted(actual - expected)],
        false_negative=[list(edge) for edge in sorted(expected - actual)],
        unresolved=graph["unresolved"],
    )


def setup_path_for(root: Path) -> Path:
    # 구형 루트 배치와 새 setup/ 배치를 명시적으로 지원하며 충돌은 거부한다.
    found = [path for path in (root / "setup.json", root / "setup/setup.json") if path.is_file()]
    if len(found) > 1:
        raise ValueError(f"Ambiguous setup layouts under run root: {root}")
    if not found:
        raise ValueError(f"Missing setup.json or setup/setup.json under run root: {root}")
    return found[0]


def find_run_root(state_path: Path) -> Path:
    for parent in state_path.parents:
        if any(path.is_file() for path in (parent / "setup.json", parent / "setup/setup.json")):
            setup_path_for(parent)
            return parent
    raise ValueError("Cannot locate run setup.json or setup/setup.json; provide --run-root")


def input_guard(state: dict, library: Path, library_hash: str, cli: Path, cli_hash: str) -> None:
    if (
        manifest(Path(state["store"])) != state["index_files"]
        or source_manifest(Path(state["project"])) != state["current_sources"]
    ):
        raise ValueError("Shared compiler store or source bytes differ from recorded state")
    if digest(library) != library_hash or digest(cli) != cli_hash:
        raise ValueError("Compiler reader library/native CLI changed during observation")


def freshness_diagnostics(native: dict, project: Path, changed: list[str]) -> dict:
    """정상 종료한 질의의 한계 필드 안에서만 변경 경로의 경고 근거를 찾는다."""
    evidence = dict(reported_changed_paths=[], matched_diagnostics=[], warning_present=False)
    if type(native.get("exit_code")) is not int or native["exit_code"] != 0 or native.get("timed_out"):
        return {
            **evidence,
            "status": "failed",
            "reason": "Native query failed or timed out; partial output is not diagnostic proof",
        }

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate diagnostic JSON key")
            result[key] = value
        return result

    def invalid_number(value):
        raise ValueError(f"Nonfinite diagnostic JSON: {value}")

    try:
        document = json.loads(
            Path(native["stdout"]).read_text(), object_pairs_hook=unique_object, parse_constant=invalid_number
        )
        if (
            not isinstance(document, dict)
            or document.get("requested") != "CGBase"
            or document.get("level") != "symbol"
            or document.get("status") not in {"found", "notFound", "ambiguous"}
            or not isinstance(document.get("limitations"), list)
            or any(not isinstance(item, str) for item in document["limitations"])
        ):
            raise ValueError("Unrecognized single-symbol query diagnostic schema")
    except (OSError, UnicodeError, ValueError, RecursionError) as error:
        return {**evidence, "status": "failed", "reason": f"Invalid structured query diagnostic: {error}"}
    warnings = [
        item
        for item in document["limitations"]
        if item.startswith(("index-staleness:", "missing-sources:", "unindexed-sources:"))
    ]
    matched, reported = [], set()
    for diagnostic in warnings:
        relevant = []
        for path in changed:
            candidates = {path, str(project / path)}
            if any(
                re.search(r"(?<![\w./-])" + re.escape(candidate) + r"(?![\w./-])", diagnostic)
                for candidate in candidates
            ):
                relevant.append(path)
        if relevant:
            matched.append({"diagnostic": diagnostic, "changed_paths": relevant})
            reported.update(relevant)
    return dict(
        status="passed" if reported else "failed",
        reported_changed_paths=sorted(reported),
        matched_diagnostics=matched,
        warning_present=bool(warnings),
        reason="A recognized limitations entry itself must identify a changed dependency; graph locations and stderr do not qualify",
    )


def required_stale_paths(state: dict, accepted: dict, changed: list[str]) -> list[str]:
    """부수적인 import 편집 경고로 헤더·이동·삭제 경로의 검증을 대신하지 않는다."""
    name = state.get("name")
    before, after = accepted["current_sources"], state["current_sources"]
    if name == "header_edit_unbuilt":
        required = [path for path in changed if path.endswith(".h") and path in before and path in after]
    elif name in {"header_rename_unbuilt", "swift_rename_unbuilt"}:
        extension = ".h" if name.startswith("header_") else ".swift"
        required = [path for path in changed if path.endswith(extension) and ((path in before) != (path in after))]
    elif name in {"header_delete_unbuilt", "header_delete_build_failed", "swift_delete_unbuilt"}:
        extension = ".h" if name.startswith("header_") else ".swift"
        required = [path for path in changed if path.endswith(extension) and path in before and path not in after]
    else:
        raise ValueError("Unknown source-staleness state; a dependency family must be declared")
    if not required:
        raise ValueError("Declared stale state has no changed dependency in its required path family")
    return required


def stale_observation(args, state: dict, accepted: dict, out: Path) -> dict:
    changed = sorted(
        key
        for key in state["current_sources"].keys() | accepted["current_sources"].keys()
        if state["current_sources"].get(key) != accepted["current_sources"].get(key)
    )
    if changed != state["changed_since_success"] or not changed:
        raise ValueError("Source-only stale state lacks exact independent hash delta")
    if state["expected_build"] == "not-run" and state["index_files"] != accepted["index_files"]:
        raise ValueError("Unbuilt source-only state changed compiler index bytes")
    result = dict(
        status="stale-current-source-not-scored",
        external_source_integrity=dict(stale=True, changed_paths=changed),
        compiler_calls=dict(status="not-scored", reason="Compiled facts belong to last successful build"),
        index_dump_native_freshness=dict(capability="unsupported", precision=None, recall=None, scored=False),
        native_cartograph_freshness=dict(status="not-run"),
    )
    if args.cartograph:
        project, store = Path(state["project"]), Path(state["store"])
        native = run(
            [str(args.cartograph), "query", "CGBase", "--depth", "8", "--limit", "100000", *cg_options(project, store)],
            project,
            out / "cartograph-stale",
        )
        required = required_stale_paths(state, accepted, changed)
        result["native_cartograph_freshness"] = {
            **freshness_diagnostics(native, project, required),
            "required_changed_paths": required,
            "exact_changed_paths": changed,
            "diagnostic": native,
        }
    save(out / "freshness.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--run-root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--index-dump", type=Path, required=True)
    parser.add_argument("--indexstore-checkout", type=Path, required=True)
    parser.add_argument("--cli-build-evidence", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--cartograph", type=Path)
    parser.add_argument(
        "--cartograph-graph-mode",
        choices=["default", "include-self-loops"],
        default="default",
        help="Explicit native graph contract; compatible mode requires the symbol self-loop flag and never falls back",
    )
    parser.add_argument("--baseline-only", action="store_true")
    parser.add_argument("--query-spec", type=Path, default=Path(__file__).with_name("query-spec.json"))
    parser.add_argument("--oracle", type=Path)
    parser.add_argument(
        "--no-score", action="store_true", help="Diagnostic contracts only; never a full comparison pass"
    )
    args = parser.parse_args()
    for name in [
        "state",
        "fixture_root",
        "run_root",
        "output",
        "index_dump",
        "indexstore_checkout",
        "cli_build_evidence",
        "library",
        "cartograph",
        "query_spec",
        "oracle",
    ]:
        value = getattr(args, name)
        if value is not None:
            setattr(args, name, value.resolve())
    if not args.baseline_only and not args.cartograph:
        parser.error("--cartograph is required unless --baseline-only explicitly marks the diagnostic")
    state_path = args.state.resolve()
    out = (args.output or state_path.parent / "observation").resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Observation output must be new/empty; evidence is never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    result = dict(
        role="preparatory-validation",
        superiority="not-claimed",
        full_comparison=False,
        cartograph_graph_mode=args.cartograph_graph_mode,
        index_dump_native_callers=dict(capability="unsupported", scored=False, precision=None, recall=None),
        framework_selection=dict(
            status="separate-not-scored", index_dump_native="unsupported", precision=None, recall=None
        ),
    )
    try:
        state = json.loads(state_path.read_text())
        if state.get("execution") != "executed":
            raise ValueError("Plan-only compiler states cannot be observed as native evidence")
        root = args.run_root.resolve() if args.run_root else find_run_root(state_path)
        setup_path = setup_path_for(root)
        setup = json.loads(setup_path.read_text())
        result["setup_path"] = str(setup_path)
        result["setup_layout"] = str(setup_path.relative_to(root))
        library = args.library.resolve()
        library_hash = digest(library)
        if setup.get("library_sha256") != library_hash:
            raise ValueError("Selected compiler and comparator reader library bytes differ")
        result["cli"] = verify_cli(
            args.index_dump.resolve(),
            args.indexstore_checkout.resolve(),
            args.cli_build_evidence.resolve(),
            out / "setup",
        )
        if args.cartograph:
            result["native_library"] = library_for_cartograph(library, out / "setup")
            result["cartograph_binary_sha256"] = digest(args.cartograph)

        def guard():
            input_guard(state, library, library_hash, args.index_dump, result["cli"]["binary_sha256"])
            if args.cartograph and digest(args.cartograph) != result["cartograph_binary_sha256"]:
                raise ValueError("Native Cartograph executable changed during observation")

        guard()
        accepted_path = state_path.parent.parent / state["last_successful_build"] / "state.json"
        accepted = json.loads(accepted_path.read_text())
        if not state["expected_fresh"]:
            result.update(stale_observation(args, state, accepted, out))
            guard()
            failed = result["native_cartograph_freshness"]["status"] == "failed"
            result["status"] = (
                "failed-native-freshness"
                if failed
                else "stale-gate-passed-baseline-diagnostic" if args.baseline_only else "stale-gate-passed"
            )
            save(out / "results.json", result)
            return int(failed)
        if state["expected_build"] != "success" or accepted["name"] != state["name"]:
            raise ValueError("Fresh observation requires a successful current compiler state")
        commands = json.loads((accepted_path.parent / "commands.json").read_text())
        expected, contexts = compile_manifest(commands, state, setup)
        catalog = adapter.source_catalog(Path(state["project"]), contexts)
        requests = source_requests(catalog, json.loads(args.query_spec.read_text()))
        save(out / "source-catalog.json", catalog_evidence(catalog))
        save(out / "requests-source.json", requests)
        provenance, texts = discover(
            args.index_dump,
            library,
            Path(state["project"]),
            Path(state["store"]),
            expected,
            state["current_sources"],
            out / "index-dump",
        )
        graph = adapter.baseline_graph(Path(state["project"]), catalog, provenance["records"], texts)
        save(out / "index-dump/normalized-graph.json", graph)
        baseline = adapter.graph_observation(graph, requests, "actual-index-dump-plus-external-assembly")
        save(out / "index-dump/observation.json", baseline)
        guard()
        native = (
            native_observations(
                args.cartograph,
                Path(state["project"]),
                Path(state["store"]),
                catalog,
                requests,
                out / "cartograph",
                graph_mode=args.cartograph_graph_mode,
            )
            if args.cartograph
            else {}
        )
        guard()
        result["active_unit_provenance"] = dict(
            status="passed",
            roots=provenance["roots"],
            excluded_units=provenance["excluded_units"],
            project_record_provenances=len(provenance["records"]),
            distinct_records=len(texts),
            source_definitions=sum(e["definition"] for e in catalog),
        )
        result["index_dump_native_freshness"] = dict(
            capability="unsupported", precision=None, recall=None, scored=False
        )
        observations = {"index_dump_assembly": baseline, **native}
        result["observations"] = {
            key: dict(complete=value["complete"], unresolved=value["unresolved"]) for key, value in observations.items()
        }
        if args.no_score:
            result["scores"] = {"status": "not-scored-diagnostic"}
        else:
            result["scores"] = {
                key: grade_observation(
                    value, args.oracle or args.fixture_root / "oracle.json", state["oracle_variant"], args.fixture_root
                )
                for key, value in observations.items()
            }
        if not args.no_score:
            oracle_path = args.oracle or args.fixture_root / "oracle.json"
            result["graph_scores"] = {"index_dump_assembly": grade_graph(graph, oracle_path, state["oracle_variant"])}
            if native:
                native_graph = json.loads((out / "cartograph/normalized-graph.json").read_text())
                result["graph_scores"]["cartograph"] = grade_graph(native_graph, oracle_path, state["oracle_variant"])
                if args.cartograph_graph_mode == "include-self-loops":
                    default_graph = json.loads((out / "cartograph/normalized-default-graph.json").read_text())
                    result["default_graph_diagnostic_score"] = grade_graph(
                        default_graph, oracle_path, state["oracle_variant"]
                    )
                    result["default_graph_diagnostic_role"] = (
                        "retained default behavior; selected compatible mode is scored separately"
                    )
        complete = all(value["complete"] for value in observations.values())
        scored = not args.no_score and all(value["status"] == "passed" for value in result["scores"].values())
        graph_scored = not args.no_score and all(
            value["status"] == "passed" for value in result["graph_scores"].values()
        )
        result["full_comparison"] = bool(complete and scored and graph_scored and native)
        result["status"] = (
            "passed"
            if result["full_comparison"]
            else (
                "baseline-diagnostic-complete"
                if complete and args.baseline_only and (args.no_score or (scored and graph_scored))
                else "failed"
            )
        )
        result["same_input_bytes_verified"] = True
        result["adapter_sha256"] = {
            p.name: digest(p) for p in [Path(__file__), Path(adapter.__file__), args.query_spec]
        }
        save(out / "results.json", result)
        return int(result["status"] == "failed")
    except Exception as error:
        if "guard" in locals():
            try:
                guard()
                result["same_input_bytes_after_failure"] = True
            except Exception as integrity_error:
                result["same_input_bytes_after_failure"] = False
                result["input_integrity_error"] = str(integrity_error)
        result.update(status="failed", error=f"{type(error).__name__}: {error}")
        save(out / "results.json", result)
        print(result["error"])
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
