#!/usr/bin/env python3
"""Verify source-authored expectations, mutation coverage, command plans, and scorer sensitivity.

Optional Clang check compiles only the exact portable Core.m and CppBridge.mm;
it is not an iOS SDK, Foundation, Swift interop, or product correctness result.
"""

from __future__ import annotations
import argparse
from collections import deque
import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from validation_common import (
    ROOT,
    STAGES,
    HEADER,
    QUERY_KEYS,
    command_plan,
    digest,
    manifest,
    mutate,
    save,
    source_manifest,
)
from score_calls import grade


def require(value: bool, reason: str) -> None:
    if not value:
        raise ValueError(reason)


def verify_variant(project: Path, variant: dict) -> None:
    bykey = {n["key"]: n for n in variant["nodes"]}
    require(len(bykey) == len(variant["nodes"]), "Duplicate node key")
    require(len({n["id"] for n in variant["nodes"]}) == len(bykey), "Duplicate context identity")
    for node in variant["nodes"]:
        for anchor in [node, *node["aliases"]]:
            lines = (project / anchor["path"]).read_text().splitlines()
            text = lines[anchor["line"] - 1]
            require(text == anchor["anchor"], f'Declaration anchor changed: {node["key"]}')
            require(text.encode()[anchor["column"] - 1 :].startswith(anchor["token"].encode()), "Wrong UTF8 column")
        require(node["id"] == f'{node["context"]}::{node["path"]}:{node["line"]}:{node["column"]}', "Identity mismatch")
    reverse = {}
    for edge in variant["edges"]:
        require(edge["caller"] in bykey and edge["callee"] in bykey, "Unknown edge identity")
        require(edge["path"] == bykey[edge["caller"]]["path"], "Wrong call-site file")
        require(
            (project / edge["path"]).read_text().splitlines()[edge["line"] - 1] == edge["anchor"], "Call-site drift"
        )
        reverse.setdefault(edge["callee"], set()).add(edge["caller"])
    all_ids = {n["id"] for n in bykey.values()}
    require(
        [q["id"] for q in variant["queries"]] == [f"q{i:02d}" for i in range(1, 11)], "Fixed ten-query ID/order drift"
    )
    require([q["seed_key"] for q in variant["queries"]] == QUERY_KEYS, "Fixed seed order drift")
    for query in variant["queries"]:
        require(query["seed"] == bykey[query["seed_key"]]["id"], "Seed/source identity mismatch")
        require(query["max_depth"] == 8, "Fixed query depth changed")
        seed = query["seed_key"]
        distances = {seed: 0}
        queue = deque([seed])
        while queue:
            current = queue.popleft()
            if distances[current] == query["max_depth"]:
                continue
            for caller in reverse.get(current, []):
                if caller not in distances:
                    distances[caller] = distances[current] + 1
                    queue.append(caller)
        distances.pop(seed)
        actual = {bykey[key]["id"]: distance for key, distance in distances.items()}
        require(
            actual == {i["id"]: i["minimum_depth"] for i in query["transitive"]},
            "Authored transitive answer inconsistent",
        )
        require(
            set(query["direct"]) == {key for key, d in actual.items() if d == 1}, "Direct caller answer inconsistent"
        )
        require(
            set(query["explicit_negatives"]) == all_ids - set(actual) - {query["seed"]}, "Negative controls incomplete"
        )


def synthetic_observation(variant: dict) -> dict:
    # 스코어러 자체 검사에만 쓰며 제품 출력이나 제품 통과 근거가 아니다.
    return dict(
        arm="scorer-self-test-only",
        operation="compiler-callers",
        capability="supported",
        fresh=True,
        complete=True,
        unresolved=[],
        queries=[
            {k: copy.deepcopy(q[k]) for k in ["id", "seed", "max_depth", "direct", "transitive"]}
            for q in variant["queries"]
        ],
    )


def self_test_scorer(oracle: dict) -> int:
    observation = synthetic_observation(oracle["variants"]["initial"])
    require(grade(observation, oracle, "initial")["status"] == "passed", "Scorer rejected exact synthetic input")
    checks = 1
    for mutation in [
        "false_positive",
        "false_negative",
        "wrong_depth",
        "duplicate",
        "missing_query",
        "unresolved",
        "stale",
    ]:
        bad = copy.deepcopy(observation)
        if mutation == "false_positive":
            bad["queries"][0]["transitive"].append(dict(id="Unknown::extra.swift:1:1", minimum_depth=1))
        elif mutation == "false_negative":
            bad["queries"][0]["transitive"].pop()
        elif mutation == "wrong_depth":
            bad["queries"][0]["transitive"][0]["minimum_depth"] = 8
        elif mutation == "duplicate":
            bad["queries"][0]["transitive"].append(bad["queries"][0]["transitive"][0])
        elif mutation == "missing_query":
            bad["queries"].pop()
        elif mutation == "unresolved":
            bad["unresolved"] = ["unknown compiler identity"]
        elif mutation == "stale":
            bad["fresh"] = False
        rejected = False
        try:
            rejected = grade(bad, oracle, "initial")["status"] == "failed"
        except ValueError:
            rejected = True
        require(rejected, f"Scorer did not reject {mutation}")
        checks += 1
    unsupported = grade(
        dict(arm="index-dump-native", operation="compiler-callers", capability="unsupported"), oracle, "initial"
    )
    require(
        unsupported["scored"] is False and unsupported["recall"] is None, "Unsupported operation fabricated zero recall"
    )
    require(
        grade(observation, oracle, "initial")["queries"]["q02"]["transitive"]["recall"] is None,
        "Empty truth recall must be null",
    )
    return checks + 2


def portable_clang(clang: Path, output: Path) -> dict:
    project, store = output / "PortableProject", output / "PortableIndex"
    shutil.copytree(ROOT / "fixture", project)
    output.mkdir(exist_ok=True, parents=True)
    commands = []
    for state in ["initial", "header_edit", "restored"]:
        if state == "header_edit":
            mutate(project, "edit_header")
        if state == "restored":
            mutate(project, "restore")
        for name in ["Core.m", "CppBridge.mm"]:
            target = output / (name + ".o")
            command = [
                str(clang),
                "-O0",
                "-I",
                str(project / "Sources/BridgeKit/include"),
                "-index-store-path",
                str(store),
                "-MD",
                "-MF",
                str(output / (state + "-" + name + ".d")),
                "-c",
                str(project / "Sources/BridgeKit" / name),
                "-o",
                str(target),
            ]
            if name.endswith(".mm"):
                command.insert(1, "-std=c++17")
            record = subprocess.run(command, capture_output=True)
            stem = output / (state + "-" + name)
            stem.with_suffix(stem.suffix + ".stdout").write_bytes(record.stdout)
            stem.with_suffix(stem.suffix + ".stderr").write_bytes(record.stderr)
            commands.append(dict(command=command, exit_code=record.returncode))
            require(record.returncode == 0, record.stderr.decode(errors="replace"))
            require(
                str(project / HEADER) in (output / (state + "-" + name + ".d")).read_text(),
                "Header absent from real compiler dependencies",
            )
        require(len(list((store / "v5/units").glob("*"))) >= 2, "No Clang index units")
        save(output / (state + "-index-manifest.json"), manifest(store))
    result = dict(
        status="passed",
        scope="Linux/native Clang Core.m + CppBridge.mm only",
        ios_sdk="not-run",
        objective_c_method="not-run",
        swift_interop="not-run",
        product_accuracy="not-run",
        commands=commands,
    )
    save(output / "portable-result.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "offline-results")
    parser.add_argument("--clang", type=Path)
    args = parser.parse_args()
    require(not args.output.exists() or not any(args.output.iterdir()), "Output must be absent or empty")
    args.output.mkdir(parents=True, exist_ok=True)
    expected = json.loads((ROOT / "source-manifest.json").read_text())
    require(source_manifest(ROOT / "fixture") == expected, "Fixture source hash/universe drift")
    oracle = json.loads((ROOT / "oracle.json").read_text())
    states = []
    with tempfile.TemporaryDirectory(prefix="source-check-", dir=args.output) as temp:
        project = Path(temp) / "Project"
        shutil.copytree(ROOT / "fixture", project)
        for name, operation, build, variant in STAGES:
            if operation:
                mutate(project, operation)
            if variant:
                verify_variant(project, oracle["variants"][variant])
            commands = command_plan(
                project,
                Path(temp) / "IndexStore",
                Path(temp) / "Build",
                "/SelectedIOSSDK",
                "arm64-apple-ios16.0-simulator",
                "/Xcode/swiftc",
                "/Xcode/clang",
                "/SelectedPlatform",
                True,
            )
            require(
                len({c["args"][c["args"].index("-index-store-path") + 1] for c in commands}) == 1,
                "Split compiler stores",
            )
            shared = [c for c in commands if c["name"] in ["swift-FeatureAlpha", "swift-FeatureBeta"]]
            require(
                len(shared) == 2 and shared[0]["source_paths"] == shared[1]["source_paths"],
                "Shared source copied or lost",
            )
            require(all("-target" in c["args"] for c in commands), "Missing explicit iOS target")
            states.append(
                dict(
                    name=name,
                    source_oracle="checked" if variant else "intentionally-stale",
                    command_count=len(commands),
                )
            )
        require(source_manifest(project) == expected, "Restoration did not restore exact source bytes")
        for change in ["missing_query", "wrong_seed", "changed_depth"]:
            bad = copy.deepcopy(oracle["variants"]["initial"])
            if change == "missing_query":
                bad["queries"].pop()
            elif change == "wrong_seed":
                bad["queries"][1]["seed"] = next(n["id"] for n in bad["nodes"] if n["key"] == "unused_c")
            else:
                bad["queries"][0]["max_depth"] = 7
            rejected = False
            try:
                verify_variant(project, bad)
            except ValueError:
                rejected = True
            require(rejected, f"Source oracle failed to reject {change}")
        changed = project / HEADER
        changed.write_text(changed.read_text().replace("return CGBase(value);", "return CGUnusedC(value);"))
        rejected = False
        try:
            verify_variant(project, oracle["variants"]["initial"])
        except ValueError:
            rejected = True
        require(rejected, "Source oracle accepted a wrong call target")
    checks = self_test_scorer(oracle)
    result = dict(
        status="passed",
        source_files=len(expected),
        source_states=len(states),
        source_identities=len(oracle["variants"]["initial"]["nodes"]),
        authored_edges=len(oracle["variants"]["initial"]["edges"]),
        queries_per_state=10,
        scorer_self_tests=checks,
        oracle_contract_mutation_checks=3,
        source_tamper_rejected=True,
        states=states,
        ios_execution="not-run",
        product_correctness="not-run",
    )
    if args.clang:
        result["portable_clang"] = portable_clang(args.clang.resolve(), args.output / "clang")
    save(args.output / "result.json", result)
    print(json.dumps({k: v for k, v in result.items() if k not in ["states", "portable_clang"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
