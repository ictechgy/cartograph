#!/usr/bin/env python3
"""Verify local-function refinement against frozen before/after comparison artifacts."""

import argparse
import collections
import hashlib
import importlib.util
import json
from pathlib import Path


def load_collector():
    spec = importlib.util.spec_from_file_location(
        "external_collector", Path(__file__).with_name("benchmark-external-projects.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def signature(edges):
    result = collections.Counter()
    for edge in edges:
        result[(edge["source"], edge["target"], edge["kind"])] += edge["weight"]
    return result


def verify_symbol_projection(before, after):
    old = {node["id"]: node for node in before["nodes"]}
    new = {node["id"]: node for node in after["nodes"]}
    locals_ = {key for key in new if key.startswith("cartograph:local-function:")}
    assert set(new) - locals_ == set(old), "Indexed node inventory changed"
    assert all(old[key] == new[key] for key in old), "Indexed node metadata changed"
    parents = collections.defaultdict(set)
    for edge in after["edges"]:
        if edge["kind"] == "member":
            parents[edge["target"]].add(edge["source"])
    projection = {key: key for key in old}
    for local in locals_:
        current, seen = local, set()
        while current not in old:
            assert current not in seen and len(parents[current]) == 1, "Ambiguous local containment"
            seen.add(current)
            current = next(iter(parents[current]))
        projection[local] = current
    contracted = []
    for edge in after["edges"]:
        source, target = projection[edge["source"]], projection[edge["target"]]
        if source != target:
            contracted.append({**edge, "source": source, "target": target})
    assert signature(before["edges"]) == signature(contracted), "Original relationship multiplicity changed"
    outgoing = collections.defaultdict(set)
    for edge in after["edges"]:
        if edge["kind"] in ("call", "reference"):
            outgoing[edge["source"]].add(edge["target"])
    by_owner = collections.defaultdict(set)
    for local in locals_:
        by_owner[projection[local]].add(local)
    for owner, members in by_owner.items():
        seen, queue = {owner}, collections.deque([owner])
        while queue:
            for target in outgoing[queue.popleft()]:
                if target in members and target not in seen:
                    seen.add(target)
                    queue.append(target)
        assert members <= seen, "Promoted local lacks an entry chain from its original owner"
    return {"promotedLocalFunctions": len(locals_), "indexedNodesUnchanged": len(old),
            "contractedEdgesEqual": True, "allLocalsHaveActualEntryChain": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--comparison", type=Path, required=True)
    parser.add_argument("--evaluation-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    comparison = json.loads((args.comparison / "results.json").read_text())
    collector = load_collector()
    for identity in comparison["binaries"].values():
        assert hashlib.sha256(Path(identity["binary"]).read_bytes()).hexdigest() == identity["sha256"]
    results = []
    for row in comparison["projects"]:
        project = row["project"]
        documents = [json.loads((args.comparison / project / arm / "graph.stdout").read_text())
                     for arm in ("before", "after")]
        result = {"project": project, "revision": row["revision"],
                  **verify_symbol_projection(*documents), "rollups": {}}
        before = {item["subject"] for item in row["arms"]["before"]["unused"]}
        after = {item["subject"] for item in row["arms"]["after"]["unused"]}
        assert before == after, f"Unexpected unused-code delta: {project}: {before ^ after}"
        result["unchangedUnusedFindings"] = len(before)
        for level in ("type", "file", "module"):
            graphs = []
            for arm in ("before", "after"):
                binary = comparison["binaries"][arm]["binary"]
                repository = args.evaluation_root / "repos" / project
                directory = args.output / project / arm
                directory.mkdir(parents=True, exist_ok=True)
                _, output = collector.run([binary, "graph", *collector.cartograph_args(
                    repository, collector.PROJECTS[project]), "--level", level, "--format", "json"],
                    repository, directory / level)
                graphs.append(json.loads(output))
            assert graphs[0] == graphs[1], f"Changed {level} rollup: {project}"
            result["rollups"][level] = {"equal": True, "nodes": graphs[0]["nodeCount"],
                                       "edges": graphs[0]["edgeCount"]}
        results.append(result)
        collector.save(args.output / "verification.json", results)
        print(json.dumps(result), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
