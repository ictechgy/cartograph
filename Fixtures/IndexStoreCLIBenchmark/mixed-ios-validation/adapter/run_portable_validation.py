#!/usr/bin/env python3
"""Linux 실제 Clang/Swift 계약 검사. iOS 또는 native Cartograph 통과로 해석하지 않는다."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys

import mixed_adapter as adapter
import observe_mixed as hook

PORTABLE_QUERIES = [
    dict(id="q01", context="BridgeKit", signature="CGBase(int)", max_depth=8),
    dict(id="q02", context="BridgeKit", signature="CGAlternate(int)", max_depth=8),
    dict(id="q03", context="BridgeKit", signature="CGHeaderRoute(int)", max_depth=8),
    dict(id="q04", context="BridgeKit", signature="CGCppBridge(int)", max_depth=8),
]


def assert_edges(catalog: list, graph: dict, edited: bool) -> dict:
    """관측 결과와 무관하게 원문에서 미리 정한 다섯 호출 간선을 검증한다."""
    definitions = {node["signature"]: node["id"] for node in catalog if node["definition"]}
    target = "CGAlternate(int)" if edited else "CGBase(int)"
    authored = [
        ("CGHeaderRoute(int)", target),
        ("CGBridge(int)", "CGHeaderRoute(int)"),
        ("CGHeaderCppRoute(int)", target),
        ("cppHelper(int)", "CGHeaderCppRoute(int)"),
        ("CGCppBridge(int)", "cppHelper(int)"),
    ]
    expected = {tuple(definitions[name] for name in edge) for edge in authored}
    actual = {tuple(edge) for edge in graph["edges"]}
    result = dict(
        status="passed" if expected == actual and not graph["unresolved"] else "failed",
        expected_edges=[list(edge) for edge in sorted(expected)],
        false_positive=[list(edge) for edge in sorted(actual - expected)],
        false_negative=[list(edge) for edge in sorted(expected - actual)],
        unresolved=graph["unresolved"],
    )
    if len(definitions) != 9:
        raise ValueError(f"Portable source contract changed: {len(definitions)} definitions")
    return result


def clang_lifecycle(args, output: Path) -> dict:
    output.mkdir()
    project, build, store = output / "Project", output / "Build", output / "IndexStore"
    shutil.copytree(args.fixture_root / "fixture", project)
    build.mkdir()
    store.mkdir()
    sys.path.insert(0, str(args.fixture_root))
    import validation_common as fixture

    swiftc, clang = args.toolchain / "usr/bin/swiftc", args.toolchain / "usr/bin/clang"
    target_info = json.loads(hook.capture([str(swiftc), "-print-target-info"], output, output / "setup/target-info"))
    triple = target_info["target"]["triple"]
    library = args.toolchain / "usr/lib/libIndexStore.so"
    hook.save(
        output / ("setup/setup.json" if args.setup_layout == "nested" else "setup.json"),
        dict(
            status="portable-diagnostic",
            library=str(library),
            library_sha256=hook.digest(library),
            target_triple=triple,
        ),
    )
    query_path = output / "portable-query-spec.json"
    hook.save(query_path, PORTABLE_QUERIES)
    # 예전 산출물과 유닛을 실제 스토어에 남겨 활성 빌드 선택을 시험한다.
    orphan_source = project / "Sources/Orphan.m"
    orphan_source.write_text("int orphanCaller(int value) { return value; }\n")
    orphan_output = build / "removed-target.o"
    hook.capture(
        [
            str(clang),
            "-target",
            triple,
            "-index-store-path",
            str(store),
            "-c",
            str(orphan_source),
            "-o",
            str(orphan_output),
        ],
        project,
        output / "setup/compile-orphan",
    )
    orphan_source.unlink()
    original_sources = hook.source_manifest(project)
    accepted_sources, accepted_name, accepted_outputs = {}, None, []
    results = []
    for name, operation, expected_build, variant in fixture.STAGES[:8]:
        state_dir = output / "runs" / name
        state_dir.mkdir(parents=True)
        before = hook.manifest(store)
        if operation:
            fixture.mutate(project, operation)
        commands, builds = [], []
        if expected_build:
            for filename in ["Core.m", "CppBridge.mm"]:
                source = project / "Sources/BridgeKit" / filename
                obj = build / (filename + ".o")
                argv = [
                    str(clang),
                    "-target",
                    triple,
                    "-I",
                    str(project / "Sources/BridgeKit/include"),
                    "-O0",
                    "-g",
                    "-index-store-path",
                    str(store),
                    "-MD",
                    "-MF",
                    str(obj.with_suffix(".d")),
                ]
                if filename.endswith(".mm"):
                    argv += ["-std=c++17"]
                argv += ["-c", str(source), "-o", str(obj)]
                commands.append(
                    dict(name="clang-" + filename, args=argv, source_paths=[str(source)], outputs=[str(obj)])
                )
            hook.save(state_dir / "commands.json", commands)
            for command in commands:
                result = hook.run(command["args"], project, state_dir / command["name"])
                builds.append(result)
                if result["exit_code"] != 0:
                    break
            success = len(builds) == len(commands) and all(b["exit_code"] == 0 for b in builds)
            if success != (expected_build == "success"):
                raise ValueError(f"Unexpected portable compile result: {name}")
            if expected_build == "failure":
                stderr = Path(builds[-1]["stderr"]).read_text()
                if "RenamedCore.h" not in stderr or "file not found" not in stderr:
                    raise ValueError("Missing-header failure control did not fail for the expected cause")
        current_sources = hook.source_manifest(project)
        index_files = hook.manifest(store)
        if expected_build is None and before != index_files:
            raise ValueError("Source-only mutation changed compiler index bytes")
        if expected_build == "success":
            accepted_sources, accepted_name = current_sources, name
            accepted_outputs = [p for command in commands for p in command["outputs"]]
        changed = sorted(
            path
            for path in set(current_sources) | set(accepted_sources)
            if current_sources.get(path) != accepted_sources.get(path)
        )
        state = dict(
            name=name,
            project=str(project),
            store=str(store),
            triple=triple,
            sdk="none-portable-clang",
            execution="executed",
            expected_build=expected_build or "not-run",
            oracle_variant=variant,
            expected_fresh=variant is not None,
            last_successful_build=accepted_name,
            changed_since_success=changed,
            current_sources=current_sources,
            index_files=index_files,
            active_object_outputs=accepted_outputs,
            builds=builds,
        )
        state_path = state_dir / "state.json"
        hook.save(state_path, state)
        invocation = hook.run(
            [
                sys.executable,
                str(Path(hook.__file__)),
                "--state",
                str(state_path),
                "--fixture-root",
                str(args.fixture_root),
                "--index-dump",
                str(args.index_dump),
                "--indexstore-checkout",
                str(args.indexstore_checkout),
                "--cli-build-evidence",
                str(args.cli_build_evidence),
                "--library",
                str(library),
                "--baseline-only",
                "--no-score",
                "--query-spec",
                str(query_path),
            ],
            project,
            state_dir / "observation-hook",
            300,
        )
        report = json.loads((state_dir / "observation/results.json").read_text())
        if invocation["exit_code"] != 0:
            raise ValueError(f"Portable hook failed: {name}: {report}")
        entry = dict(name=name, hook_status=report["status"])
        if expected_build == "success":
            catalog = json.loads((state_dir / "observation/source-catalog.json").read_text())
            graph = json.loads((state_dir / "observation/index-dump/normalized-graph.json").read_text())
            score = assert_edges(catalog, graph, variant in {"header_edit", "header_rename"})
            hook.save(state_dir / "portable-source-score.json", score)
            if score["status"] != "passed":
                raise ValueError(f"Portable authored graph differs: {name}: {score}")
            if not report["active_unit_provenance"]["excluded_units"]:
                raise ValueError("Actual orphan unit was not excluded by current outputs")
            entry["source_graph"] = score["status"]
            entry["definition_count"] = 9
            entry["edge_count"] = 5
        results.append(entry)
    if hook.source_manifest(project) != original_sources:
        raise ValueError("Portable source bytes not restored")
    result = dict(
        status="passed",
        states=results,
        ios="not-run",
        native_cartograph="not-run",
        comparison="not-claimed",
        native_header_warning="unsupported-index-dump",
        source_restoration="byte-identical",
        role="portable-clang-validation-only",
    )
    hook.save(output / "results.json", result)
    return result


def shared_swift_contract(args, output: Path) -> dict:
    output.mkdir()
    project, build, store = output / "Project", output / "Build", output / "IndexStore"
    (project / "Sources").mkdir(parents=True)
    build.mkdir()
    store.mkdir()
    shared = project / "Sources/Shared.swift"
    shared.write_text(
        "public func leaf(_ value: Int) -> Int { return value }\n"
        "public func route(_ value: Int) -> Int { return leaf(value) }\n"
    )
    swiftc, library = args.toolchain / "usr/bin/swiftc", args.toolchain / "usr/lib/libIndexStore.so"
    info = json.loads(hook.capture([str(swiftc), "-print-target-info"], project, output / "setup/target-info"))
    triple = info["target"]["triple"]
    expected = []
    for module in ["FeatureAlpha", "FeatureBeta"]:
        obj = build / (module + ".o")
        hook.capture(
            [
                str(swiftc),
                "-target",
                triple,
                "-parse-as-library",
                "-module-name",
                module,
                "-module-cache-path",
                str(build / "module-cache"),
                "-index-store-path",
                str(store),
                "-c",
                str(shared),
                "-o",
                str(obj),
            ],
            project,
            output / f"compile-{module}",
        )
        expected.append(
            dict(output=str(obj), source=str(shared), module=module, provider="swift", target=triple, sysroot=None)
        )
    before = hook.manifest(store)
    provenance, texts = hook.discover(
        args.index_dump, library, project, store, expected, hook.source_manifest(project), output / "index-dump"
    )
    catalog = adapter.source_catalog(project, {"Sources/Shared.swift": ["FeatureAlpha", "FeatureBeta"]})
    graph = adapter.baseline_graph(project, catalog, provenance["records"], texts)
    hook.save(output / "source-catalog.json", catalog)
    hook.save(output / "normalized-graph.json", graph)
    expected_edges = {
        (f"{module}::Sources/Shared.swift:2:13", f"{module}::Sources/Shared.swift:1:13")
        for module in ["FeatureAlpha", "FeatureBeta"]
    }
    if graph["unresolved"] or {tuple(e) for e in graph["edges"]} != expected_edges or len(graph["symbols"]) != 4:
        raise ValueError(f"Actual same-file two-module contract failed: {graph}")
    if hook.manifest(store) != before:
        raise ValueError("Swift contract dump mutated compiler input")
    lifecycle = []
    legacy = project / "Sources/Legacy.swift"
    legacy.write_text("public func extra(_ value: Int) -> Int { return value }\n")
    for name, filename in [
        ("legacy-built", "Legacy.swift"),
        ("renamed-built", "Relocated.swift"),
        ("deleted-built", None),
    ]:
        source = project / "Sources" / filename if filename else None
        if filename == "Relocated.swift":
            legacy.rename(source)
        elif filename is None:
            (project / "Sources/Relocated.swift").unlink()
        active = list(expected)
        contexts = {"Sources/Shared.swift": ["FeatureAlpha", "FeatureBeta"]}
        if source:
            obj = build / (filename + ".o")
            hook.capture(
                [
                    str(swiftc),
                    "-target",
                    triple,
                    "-parse-as-library",
                    "-module-name",
                    "AppFlow",
                    "-module-cache-path",
                    str(build / "module-cache"),
                    "-index-store-path",
                    str(store),
                    "-c",
                    str(source),
                    "-o",
                    str(obj),
                ],
                project,
                output / f"compile-{name}",
            )
            active.append(
                dict(
                    output=str(obj), source=str(source), module="AppFlow", provider="swift", target=triple, sysroot=None
                )
            )
            contexts[f"Sources/{filename}"] = ["AppFlow"]
        state_out = output / name
        current_provenance, current_texts = hook.discover(
            args.index_dump, library, project, store, active, hook.source_manifest(project), state_out
        )
        current_catalog = adapter.source_catalog(project, contexts)
        current_graph = adapter.baseline_graph(project, current_catalog, current_provenance["records"], current_texts)
        hook.save(state_out / "normalized-graph.json", current_graph)
        identities = set(current_graph["symbols"].values())
        expected_identities = {node["id"] for node in current_catalog if node["definition"]}
        if current_graph["unresolved"] or identities != expected_identities:
            raise ValueError(f"Swift rename/delete current identity contract failed: {name}")
        if {tuple(edge) for edge in current_graph["edges"]} != expected_edges:
            raise ValueError(f"Swift rename/delete changed unrelated call graph: {name}")
        if name != "legacy-built" and not current_provenance["excluded_units"]:
            raise ValueError("Swift stale source unit was not excluded by active outputs")
        lifecycle.append(
            dict(
                name=name,
                definitions=len(identities),
                excluded_units=current_provenance["excluded_units"],
                status="passed",
            )
        )
    result = dict(
        status="passed",
        active_unit_rename_delete=lifecycle,
        source_paths=[str(shared)],
        physical_source_count=1,
        contexts=["FeatureAlpha", "FeatureBeta"],
        definitions=4,
        call_edges=2,
        distinct_compiler_identities=len(graph["symbols"]),
        ios="not-run",
        objective_c_interop="not-run",
        role="portable-swift-context-contract",
    )
    hook.save(output / "results.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--index-dump", type=Path, required=True)
    parser.add_argument("--indexstore-checkout", type=Path, required=True)
    parser.add_argument("--cli-build-evidence", type=Path, required=True)
    parser.add_argument(
        "--setup-layout",
        choices=["legacy", "nested"],
        default="legacy",
        help="Exercise root setup.json or integrated setup/setup.json discovery",
    )
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Output must be new/empty")
    args.output.mkdir(parents=True, exist_ok=True)
    result = dict(role="portable-validation-not-ios-or-product-comparison", setup_layout=args.setup_layout)
    try:
        result["clang"] = clang_lifecycle(args, args.output / "clang")
        result["shared_swift"] = shared_swift_contract(args, args.output / "shared-swift")
        result["status"] = "passed"
    except Exception as error:
        result.update(status="failed", error=f"{type(error).__name__}: {error}")
    hook.save(args.output / "results.json", result)
    print(json.dumps(result, indent=2))
    return int(result["status"] != "passed")


if __name__ == "__main__":
    raise SystemExit(main())
