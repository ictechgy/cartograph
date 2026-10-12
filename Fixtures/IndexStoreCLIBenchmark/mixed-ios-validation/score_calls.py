#!/usr/bin/env python3
"""Grade normalized compiler-call observations against immutable source identities.

This is a scorer, not a normalizer. It cannot read compiler USRs or tool graphs,
remove unknown identities, infer expected answers, or synthesize unsupported APIs.
"""

from __future__ import annotations
import argparse
import json
from pathlib import Path
from validation_common import ROOT, save


def exact(actual: set, expected: set) -> dict:
    tp = len(actual & expected)
    return dict(
        exact=actual == expected,
        false_positive=sorted(actual - expected),
        false_negative=sorted(expected - actual),
        precision=tp / len(actual) if actual else None,
        recall=tp / len(expected) if expected else None,
    )


def grade(observation: dict, oracle: dict, variant: str) -> dict:
    if observation.get("operation") != "compiler-callers":
        raise ValueError("Only compiler-callers can be scored against this oracle")
    if observation.get("capability") == "unsupported":
        if observation.get("arm") != "index-dump-native":
            raise ValueError("Comparable caller arms must implement callers or fail explicitly")
        return dict(status="unsupported", precision=None, recall=None, scored=False)
    if observation.get("capability") != "supported":
        raise ValueError("Missing explicit supported/unsupported capability")
    if observation.get("arm") == "index-dump-native":
        raise ValueError("index-dump has no native caller command; name the external assembly arm")
    if observation.get("fresh") is not True:
        raise ValueError("Stale/unknown input cannot be scored as current caller correctness")
    if observation.get("complete") is not True or observation.get("unresolved") != []:
        raise ValueError("Partial, ambiguous, or unresolved answers must fail instead of disappearing")
    expected = {q["id"]: q for q in oracle["variants"][variant]["queries"]}
    items = observation.get("queries")
    if not isinstance(items, list) or len(items) != len(expected):
        raise ValueError("Expected exactly the declared ten queries")
    actual = {item["id"]: item for item in items}
    if set(actual) != set(expected) or len(actual) != len(items):
        raise ValueError("Missing, duplicate, or unexpected query")
    scores = {}
    for key, query in expected.items():
        result = actual[key]
        if result.get("seed") != query["seed"] or result.get("max_depth") != query["max_depth"]:
            raise ValueError(f"Wrong seed/depth: {key}")
        direct = result.get("direct")
        transitive = result.get("transitive")
        if not isinstance(direct, list) or not isinstance(transitive, list):
            raise ValueError("Answers must be explicit lists, including empty answers")
        if not all(isinstance(item, str) for item in direct) or len(set(direct)) != len(direct):
            raise ValueError("Invalid or duplicate direct identity")
        distances = {}
        for item in transitive:
            identity, depth = item["id"], item["minimum_depth"]
            if not isinstance(identity, str) or type(depth) is not int or not 1 <= depth <= query["max_depth"]:
                raise ValueError("Invalid caller source identity/depth")
            if identity in distances:
                raise ValueError("Duplicate transitive caller identity")
            distances[identity] = depth
        authored = {item["id"]: item["minimum_depth"] for item in query["transitive"]}
        direct_score = exact(set(direct), set(query["direct"]))
        transitive_score = exact(set(distances), set(authored))
        wrong_depth = {
            key: dict(actual=distances[key], expected=authored[key])
            for key in sorted(distances.keys() & authored.keys())
            if distances[key] != authored[key]
        }
        scores[key] = dict(
            direct=direct_score,
            transitive=transitive_score,
            wrong_depth=wrong_depth,
            negative_hits=sorted(set(distances) & set(query["explicit_negatives"])),
        )
    passed = all(
        item["direct"]["exact"]
        and item["transitive"]["exact"]
        and not item["wrong_depth"]
        and not item["negative_hits"]
        for item in scores.values()
    )
    return dict(status="passed" if passed else "failed", scored=True, role="validation-only", queries=scores)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--observation", type=Path, required=True)
    parser.add_argument(
        "--variant", choices=["initial", "header_edit", "header_rename", "swift_rename", "swift_delete"], required=True
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = grade(
        json.loads(args.observation.read_text()), json.loads((ROOT / "oracle.json").read_text()), args.variant
    )
    save(args.output, result)
    return int(result["status"] == "failed")


if __name__ == "__main__":
    raise SystemExit(main())
