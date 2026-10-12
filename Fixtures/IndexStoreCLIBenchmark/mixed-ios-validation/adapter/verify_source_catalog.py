#!/usr/bin/env python3
"""원문으로 얻은 선언/별칭/질의 식별자만 고정 소스 계약과 대조한다."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys
import tempfile

import mixed_adapter as adapter
import observe_mixed as hook


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.fixture_root))
    import validation_common as fixture

    oracle = json.loads((args.fixture_root / "oracle.json").read_text())
    specs = json.loads(Path(__file__).with_name("query-spec.json").read_text())
    results = []
    with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as directory:
        project = Path(directory) / "Project"
        shutil.copytree(args.fixture_root / "fixture", project)
        if hook.source_manifest(project) != json.loads((args.fixture_root / "source-manifest.json").read_text()):
            raise ValueError("Frozen fixture source hashes differ")
        for name, operation, _, variant in fixture.STAGES:
            if operation:
                fixture.mutate(project, operation)
            if variant is None:
                continue
            commands = fixture.command_plan(
                project,
                Path(directory) / "Store",
                Path(directory) / "Build",
                "/sdk",
                "arm64-apple-ios16.0-simulator",
                "/swiftc",
                "/clang",
                "/platform",
            )
            contexts = {}
            for command in commands:
                context = hook.option(command["args"], "-module-name") or "BridgeKit"
                for path in command["source_paths"]:
                    contexts.setdefault(adapter.relative_path(project, path), []).append(context)
            for path in (project / "Sources").rglob("*.h"):
                contexts[str(path.relative_to(project))] = ["BridgeKit"]
            catalog = adapter.source_catalog(project, contexts)
            definitions = {node["id"]: node for node in catalog if node["definition"]}
            authored = {node["id"]: node for node in oracle["variants"][variant]["nodes"]}
            if set(definitions) != set(authored):
                raise ValueError(f"Source declaration inventory mismatch: {name}")
            for identifier, node in authored.items():
                actual = definitions[identifier]
                if any(actual[key] != node[key] for key in ["anchor", "signature", "token", "context"]):
                    raise ValueError(f"Source declaration metadata mismatch: {identifier}")
                actual_aliases = {entry["id"] for entry in catalog if entry.get("alias_of") == identifier}
                aliases = {
                    f'{node["context"]}::{alias["path"]}:{alias["line"]}:{alias["column"]}' for alias in node["aliases"]
                }
                if actual_aliases != aliases:
                    raise ValueError(f"Source declaration alias mismatch: {identifier}")
            requests = hook.source_requests(catalog, specs)
            expected = [
                {key: query[key] for key in ["id", "seed", "max_depth"]}
                for query in oracle["variants"][variant]["queries"]
            ]
            if requests != expected:
                raise ValueError(f"Query source contract mismatch: {name}")
            results.append(
                dict(
                    state=name,
                    variant=variant,
                    definitions=len(definitions),
                    aliases=sum("alias_of" in entry for entry in catalog),
                    queries=len(requests),
                )
            )
    hook.save(
        args.output,
        dict(status="passed", source_identity_contracts=results, graph_or_caller_answers_consumed_by_adapter=False),
    )
    print(f"Passed {len(results)} source declaration/alias/query contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
