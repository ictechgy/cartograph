#!/usr/bin/env python3
"""실제 Linux Swift/고정 CLI의 모듈 봉인과 변조 거부를 검증하고 관측한 문법을 구분한다."""

import argparse
import json
from pathlib import Path
import sys

import mixed_adapter as adapter
import observe_mixed as hook

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validation_common import module_artifact_manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--index-dump", type=Path, required=True)
    parser.add_argument("--indexstore-checkout", type=Path, required=True)
    parser.add_argument("--cli-build-evidence", type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    if root.exists() and any(root.iterdir()):
        parser.error("Output must be new/empty")
    project, build, store = root / "Project", root / "Build", root / "IndexStore"
    (project / "Sources").mkdir(parents=True)
    build.mkdir()
    store.mkdir()
    sources = {
        "Leaf.swift": "public func leaf() -> Int { return 1 }\n",
        "Client.swift": "import FeatureAlpha\npublic func caller() -> Int { return leaf() }\n",
    }
    for name, text in sources.items():
        (project / "Sources" / name).write_text(text)
    swiftc = args.toolchain.resolve() / "usr/bin/swiftc"
    library = args.toolchain.resolve() / "usr/lib/libIndexStore.so"
    result = dict(role="actual-linux-compiler-cli-validation-only", native_cartograph="not-run", superiority_claim=None)
    try:
        result["cli"] = hook.verify_cli(
            args.index_dump.resolve(),
            args.indexstore_checkout.resolve(),
            args.cli_build_evidence.resolve(),
            root / "setup",
        )
        result["library_sha256"] = hook.digest(library)
        result["swiftc_sha256"] = hook.digest(swiftc)
        target = json.loads(hook.capture([str(swiftc), "-print-target-info"], project, root / "setup/target"))[
            "target"
        ]["triple"]
        commands, builds = [], []
        for module, name in [("FeatureAlpha", "Leaf.swift"), ("AppFlow", "Client.swift")]:
            source, obj = project / "Sources" / name, build / (module + ".o")
            argv = [
                str(swiftc),
                "-target",
                target,
                "-sdk",
                "/",
                "-parse-as-library",
                "-module-name",
                module,
                "-module-cache-path",
                str(build / "module-cache"),
                "-index-store-path",
                str(store),
                "-I",
                str(build),
                "-emit-module",
                "-emit-module-path",
                str(build / (module + ".swiftmodule")),
                "-c",
                str(source),
                "-o",
                str(obj),
            ]
            commands.append(dict(name=module, args=argv, source_paths=[str(source)], outputs=[str(obj)]))
            record = hook.run(argv, project, root / "build-logs" / module)
            builds.append(record)
            if record["exit_code"] != 0:
                raise ValueError("Real module compiler failed; logs retained")
        state = dict(
            project=str(project),
            store=str(store),
            triple=target,
            current_sources=hook.source_manifest(project),
            index_files=hook.manifest(store),
            builds=builds,
            active_object_outputs=[p for command in commands for p in command["outputs"]],
            module_artifacts=module_artifact_manifest(commands, builds),
        )
        hook.save(root / "accepted-state.json", state)
        expected, contexts = hook.compile_manifest(commands, state, {"sdk_path": "/"})
        provenance, texts = hook.discover(
            args.index_dump.resolve(), library, project, store, expected, state["current_sources"], root / "index-dump"
        )
        catalog = adapter.source_catalog(project, contexts)
        graph = adapter.baseline_graph(project, catalog, provenance["records"], texts)
        hook.save(root / "normalized-graph.json", graph)
        edges = {("AppFlow::Sources/Client.swift:2:13", "FeatureAlpha::Sources/Leaf.swift:1:13")}
        if graph["unresolved"] or {tuple(edge) for edge in graph["edges"]} != edges:
            raise ValueError("Independent cross-module call edge did not match")
        associations = provenance["module_artifact_dependencies"]
        hook.input_guard(state, library, hook.digest(library), args.index_dump, hook.digest(args.index_dump))
        module_path = build / "FeatureAlpha.swiftmodule"
        original = module_path.read_bytes()
        module_path.write_bytes(original + b"validation-only mutation")
        rejected = []
        checks = [
            lambda: hook.compile_manifest(commands, state, {"sdk_path": "/"}),
            lambda: hook.input_guard(
                state, library, hook.digest(library), args.index_dump, hook.digest(args.index_dump)
            ),
        ]
        if associations:
            checks.append(lambda: adapter.select_units(provenance["units"], expected))
        for check in checks:
            try:
                check()
            except ValueError:
                rejected.append(True)
            else:
                rejected.append(False)
        module_path.write_bytes(original)
        if rejected != [True] * len(checks):
            raise ValueError("Changed module bytes escaped a required guard")
        hook.input_guard(state, library, hook.digest(library), args.index_dump, hook.digest(args.index_dump))
        result.update(
            status="passed",
            call_edges=1,
            nameless_artifact_associations=len(associations),
            nameless_native_coverage="exercised" if associations else "not-exercised-by-this-compiler",
            replaced_module_guards_exercised=len(checks),
            replaced_module_rejected=True,
            restored_module_verified=True,
        )
    except Exception as error:
        result.update(status="failed", error=f"{type(error).__name__}: {error}")
    hook.save(root / "results.json", result)
    print(json.dumps(result, indent=2))
    return int(result["status"] != "passed")


if __name__ == "__main__":
    sys.exit(main())
