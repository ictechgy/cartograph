#!/usr/bin/env python3
"""Score the frozen external-project pilot without converting setup failures to misses."""

import argparse
import hashlib
import json
import statistics
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote, urlparse


def read(path):
    return json.loads(path.read_text())


def relative(value, project):
    path = unquote(urlparse(value).path) if value.startswith("file:") else value
    marker = f"/repos/{project}/"
    return path.split(marker, 1)[1] if marker in path else path


def in_scope(path, project):
    prefixes = {"alamofire": ["Source/"], "kingfisher": ["Sources/"],
                "argument-parser": ["Sources/ArgumentParser/", "Sources/ArgumentParserToolInfo/"]}
    return any(path.startswith(prefix) for prefix in prefixes[project])


def score(actual, expected):
    return {"matched": len(actual & expected), "extra": sorted(actual - expected),
            "missed": sorted(expected - actual), "exact": actual == expected}


def stable(values):
    normalized = [json.dumps(value, sort_keys=True) for value in values]
    return len(set(normalized)) == 1


def query_scores(root, tasks):
    output = []
    raw = root / "raw"
    for task in tasks:
        tid, project = task["id"], task["project"]
        expected = {(gold["path"], gold["line"]) for gold in task["gold"]}
        projected = set(expected)
        if "nonlocalProjection" in task:
            projection = task["nonlocalProjection"]
            projected.remove((projection["path"], projection["localLine"]))
            projected.add((projection["path"], projection["nonlocalLine"]))
        witnesses = {(gold["path"], line) for gold in task["gold"] for line in gold["referenceLines"]}
        documents, lsp_values, references, timings, mcp_documents, sessions = [], [], [], [], [], []
        text_hits = []
        for sample in range(3):
            stem = raw / "queries-final" / f"{tid}-cartograph-{sample}"
            meta, document = read(stem.with_suffix(".json")), read(stem.with_suffix(".stdout"))
            assert meta["exit"] == 0 and document["status"] == "found", (tid, meta, document["status"])
            assert not document["truncated"]["output"], tid
            documents.append(document)
            incoming = read(raw / "queries-final" / f"{tid}-lsp-incoming-{sample}.json")
            prepare = read(raw / "queries-final" / f"{tid}-lsp-prepare-{sample}.json")
            assert prepare["response"].get("result"), (tid, "LSP target was not resolved")
            current = []
            for response in incoming:
                assert "error" not in response["response"], response
                current.extend(response["response"].get("result") or [])
            lsp_values.append(sorted(current, key=lambda value: (
                value["from"]["uri"], value["from"]["selectionRange"]["start"]["line"])))
            ref = read(raw / "queries-final" / f"{tid}-lsp-references-{sample}.json")
            assert "error" not in ref["response"]
            references.append(sorted(ref["response"]["result"], key=lambda value: (
                value["uri"], value["range"]["start"]["line"], value["range"]["start"]["character"])))
            mcp = read(raw / "mcp-final" / f"{tid}-mcp-{sample}.json")
            structured = mcp["response"]["result"]["structuredContent"]
            mcp_documents.append(structured["result"])
            sessions.append(structured["session"])
            text_meta = read(raw / "queries-final" / f"{tid}-rg-{sample}.json")
            assert text_meta["exit"] in (0, 1)
            hits = [json.loads(line)["data"] for line in
                    (raw / "queries-final" / f"{tid}-rg-{sample}.stdout").read_text().splitlines()
                    if json.loads(line)["type"] == "match"]
            text_hits.append(sorted((hit["path"]["text"], hit["line_number"]) for hit in hits))
            timings.append({
                "cliMs": meta["seconds"] * 1000, "mcpMs": mcp["seconds"] * 1000,
                "lspReferencesMs": ref["seconds"] * 1000,
                "lspCallHierarchyMs": (prepare["seconds"] + sum(r["seconds"] for r in incoming)) * 1000,
                "rgMs": text_meta["seconds"] * 1000,
            })
        assert stable(documents) and stable(lsp_values) and stable(references) and stable(text_hits), tid
        assert documents == mcp_documents, (tid, "CLI/MCP semantic output differs")
        assert len({(session["generation"], session["fingerprint"]) for session in sessions}) == 1, tid
        actual = {(relative(value["symbol"]["location"]["path"], project),
                   value["symbol"]["location"]["line"]) for value in documents[0]["affected"]}
        lsp = {(relative(value["from"]["uri"], project), value["from"]["selectionRange"]["start"]["line"] + 1)
               for value in lsp_values[0] if in_scope(relative(value["from"]["uri"], project), project)}
        lsp_refs = {(relative(value["uri"], project), value["range"]["start"]["line"] + 1)
                    for value in references[0] if in_scope(relative(value["uri"], project), project)}
        output.append({
            "id": tid, "goldConsumers": len(expected), "goldReferenceLines": len(witnesses),
            "cartographExactLocal": score(actual, expected), "lspExactLocal": score(lsp, expected),
            "cartographNonlocal": score(actual, projected), "lspNonlocal": score(lsp, projected),
            "lspReferenceLines": score(lsp_refs, witnesses),
            "rgWitnessRetrieval": score(set(text_hits[0]), witnesses),
            "rgRawMatchingLines": len(text_hits[0]), "cartographCandidates": len(actual),
            "lspCandidatesInScope": len(lsp), "cartographOutputBytes":
                (raw / "queries-final" / f"{tid}-cartograph-0.stdout").stat().st_size,
            "lspResultBytes": len(json.dumps(lsp_values[0], sort_keys=True).encode()),
            "medianMs": {key: statistics.median(sample[key] for sample in timings) for key in timings[0]},
            "samples": timings, "stable": True, "cliMcpEqual": True,
        })
    return output


def scan_scores(root):
    output = []
    for project in ["alamofire", "kingfisher", "argument-parser"]:
        folder = "scans-scope-corrected" if project == "argument-parser" else "scans"
        raw = root / "raw" / folder
        for suffix in ["graph", "periphery-assign-only"]:
            metadata = read(raw / f"{project}-{suffix}.json")
            assert metadata["exit"] == 0 and "timeout" not in metadata, (project, suffix, metadata)
        graph = read(raw / f"{project}-graph.stdout")
        assert graph["nodeCount"] > 0 and graph["edgeCount"] > 0, project
        documents = {}
        samples = {}
        for tool in ["cartograph", "periphery"]:
            documents[tool] = []
            samples[tool] = []
            for sample in range(3):
                meta = read(raw / f"{project}-{tool}-{sample}.json")
                assert meta["exit"] == 0, (project, tool, meta)
                value = read(raw / f"{project}-{tool}-{sample}.stdout")
                if tool == "periphery":
                    value.sort(key=lambda d: (d["location"], d["name"], d["ids"]))
                    assert all(in_scope(relative(d["location"].rsplit(":", 2)[0], project), project) for d in value)
                documents[tool].append(value)
                samples[tool].append(meta["seconds"])
            assert stable(documents[tool]), (project, tool)
        cartograph, periphery = documents["cartograph"][0], documents["periphery"][0]
        cids = {value["subject"] for value in cartograph["diagnostics"]}
        common = [value for value in periphery if value["kind"] != "var.parameter"]
        pids = {usr for value in common for usr in value["ids"]}
        native = read(raw / f"{project}-periphery-assign-only.stdout")
        extra = [value for value in native if any(hint == "assignOnlyProperty" for hint in value["hints"])]
        output.append({
            "project": project, "cartographCount": len(cartograph["diagnostics"]),
            "peripheryCount": len(periphery), "peripheryParameters": len(periphery) - len(common),
            "peripheryNonparameterCount": len(common), "overlapUSRs": len(cids & pids),
            "cartographOnlyUSRs": sorted(cids - pids), "peripheryOnlyUSRs": sorted(pids - cids),
            "peripheryAssignOnlyCount": len(extra), "peripheryAssignOnlyDiagnostics": extra,
            "medianSeconds": {tool: statistics.median(values) for tool, values in samples.items()},
            "samplesSeconds": samples, "stable": True, "limitations": cartograph["limitations"],
        })
    return output


def agent_scores(root, tasks):
    answers = read(root / "agent-results.json")
    by_id = {task["id"]: task for task in tasks}
    results = []
    for trial in answers["trials"]:
        start = datetime.fromisoformat(trial["startedAt"])
        end = datetime.fromisoformat(trial["finishedAt"])
        scored = []
        for answer in trial["results"]:
            task = by_id[answer["id"]]
            expected = {(value["path"], value["line"]) for value in task["gold"]}
            actual = {(value["path"], value["line"]) for value in answer["consumers"]}
            exact = score(actual, expected)
            if "nonlocalProjection" in task:
                projection = task["nonlocalProjection"]
                local = (projection["path"], projection["localLine"])
                nonlocal_key = (projection["path"], projection["nonlocalLine"])
                expected = {nonlocal_key if value == local else value for value in expected}
                actual = {nonlocal_key if value == local else value for value in actual}
            scored.append({"id": answer["id"], "exactLocal": exact, "nonlocal": score(actual, expected)})
        results.append({"agent": trial["agent"], "project": trial["project"], "arm": trial["arm"],
                        "clockSeconds": (end - start).total_seconds(), "results": scored})
    return {"model": answers["model"], "role": answers["role"], "repetitions": 1,
            "timingCaveat": "Agent-reported second-resolution clock readings; no token/cost accounting.",
            "trials": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    tasks = read(args.root / "tasks.json")
    frozen = read(args.root / "oracle-frozen.json")
    assert hashlib.sha256((args.root / "tasks.json").read_bytes()).hexdigest() == frozen["sha256"]
    result = {"queryScores": query_scores(args.root, tasks), "scanScores": scan_scores(args.root),
              "agentScores": agent_scores(args.root, tasks)}
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"tasks": len(result["queryScores"]), "projects": len(result["scanScores"]),
                      "stableAndValidated": True}))


if __name__ == "__main__":
    main()
