#!/usr/bin/env python3
"""Compare two explicit Cartograph builds on the frozen external-project inputs."""

import argparse
import hashlib
import importlib.util
import json
import os
import statistics
import subprocess
from pathlib import Path


def load_collector():
    path = Path(__file__).with_name("benchmark-external-projects.py")
    spec = importlib.util.spec_from_file_location("external_collector", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--evaluation-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--order", choices=["before-after", "after-before"], default="before-after")
    parser.add_argument("--consumer-granularity", choices=["nonlocal", "exact"], default="nonlocal")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    collector = load_collector()
    metadata = json.loads((args.evaluation_root / "metadata.json").read_text())
    tasks = json.loads((args.evaluation_root / "tasks.json").read_text())
    swift = subprocess.check_output(["swift", "--version"], text=True, stderr=subprocess.PIPE).strip()
    if swift != metadata["swiftVersion"]:
        raise RuntimeError("Swift toolchain differs from the frozen project manifest")
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    candidates = [
        Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
        Path("/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib"),
        Path("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"),
    ]
    library = next((path for path in candidates if path.is_file()), None)
    if library is None:
        raise RuntimeError("No index library found for the measured toolchain")
    identities = {}
    for label, binary in [("before", args.before), ("after", args.after)]:
        binary = binary.resolve()
        identities[label] = {
            "binary": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "version": subprocess.check_output([str(binary), "--version"], text=True).strip(),
        }
    summary = {"binaries": identities, "projects": [], "order": args.order, "swift": swift,
               "consumerGranularity": args.consumer_granularity,
               "indexLibrary": {"path": str(library), "sha256": hashlib.sha256(library.read_bytes()).hexdigest()}}

    class Client(collector.MCPClient):
        def __init__(self, binary, project, config, log):
            collector.LSPClient.__init__(self, project, log,
                command=[str(binary), "serve", *collector.cartograph_args(project, config), "--retain-public"])

    for project_name, config in collector.PROJECTS.items():
        project = args.evaluation_root / "repos" / project_name
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project, text=True).strip()
        if revision != metadata["repos"][project_name]["revision"]:
            raise RuntimeError(f"Project revision changed: {project_name}")
        if subprocess.run(["git", "diff", "HEAD", "--quiet"], cwd=project).returncode:
            raise RuntimeError(f"Tracked sources changed: {project_name}")
        untracked = subprocess.check_output(["git", "ls-files", "--others", "--",
            *[pattern.removesuffix("/**") for pattern in config["include"]],
            ".cartograph.yml", ".cartograph.yaml", ".cartograph-baseline.json"], cwd=project, text=True)
        if untracked.strip():
            raise RuntimeError(f"Untracked analysis inputs exist: {project_name}")
        selected = [task for task in tasks if task["project"] == project_name]
        row = {"project": project_name, "revision": revision, "arms": {}}
        arms = [("before", args.before.resolve()), ("after", args.after.resolve())]
        if args.order == "after-before":
            arms.reverse()
        for label, binary in arms:
            directory = args.output / project_name / label
            directory.mkdir(parents=True, exist_ok=True)
            _, raw = collector.run([str(binary), "dead", *collector.cartograph_args(project, config),
                "--retain-public", "--report-format", "json"], project, directory / "dead")
            dead = json.loads(raw)
            _, graph_raw = collector.run([str(binary), "graph", *collector.cartograph_args(project, config),
                "--level", "symbol", "--format", "json"], project, directory / "graph")
            graph = json.loads(graph_raw)
            if graph["nodeCount"] == 0:
                raise RuntimeError(f"Empty graph: {project_name}/{label}")
            client = Client(binary, project, config, directory / "mcp.stderr")
            try:
                client.request("server/discover", {})
                initial = client.request("tools/call", {"name": "cartograph_status", "arguments": {}})
                initial_session = initial["response"]["result"]["structuredContent"]
                client.request("tools/call", {"name": "cartograph_query", "arguments": {
                    "symbols": [selected[0]["target"]["usr"]], "depth": 1, "limit": 1000,
                }})
                queries = []
                for task in selected:
                    times, values = [], []
                    for sample in range(3):
                        sample_times = []
                        for request in range(10):
                            result = client.request("tools/call", {"name": "cartograph_query", "arguments": {
                                "symbols": [task["target"]["usr"]], "depth": 1, "limit": 1000,
                            }})
                            envelope = result["response"]["result"]["structuredContent"]
                            if envelope["session"] != initial_session:
                                raise RuntimeError("Session changed during a timed sample")
                            document = envelope["result"]["results"][0]
                            if document["status"] != "found":
                                raise RuntimeError("Frozen query target did not resolve")
                            values.append(document)
                            sample_times.append(result["seconds"] * 1000)
                        times.append(sample_times)
                    if any(value != values[0] for value in values):
                        raise RuntimeError("Query output changed on unchanged inputs")
                    collector.save(directory / f"{task['id']}-query.json", values[0])
                    _, cli_raw = collector.run([str(binary), "query", task["target"]["usr"],
                        *collector.cartograph_args(project, config), "--retain-public",
                        "--depth", "1", "--limit", "1000"], project, directory / f"{task['id']}-cli-query")
                    if json.loads(cli_raw) != values[0]:
                        raise RuntimeError("CLI/MCP query output differs")
                    impact = client.request("tools/call", {"name": "cartograph_impact", "arguments": {
                        "symbols": [task["target"]["usr"]], "depth": 1, "limit": 1000,
                    }})
                    collector.save(directory / f"{task['id']}-impact.json",
                        impact["response"]["result"]["structuredContent"]["result"])
                    callers = values[0]["result"]["usedBy"]
                    actual = {(str(Path(value["location"]["path"]).relative_to(project)), value["location"]["line"])
                              for value in callers}
                    expected = {(value["path"], value["line"]) for value in task["gold"]}
                    if args.consumer_granularity == "nonlocal" and "nonlocalProjection" in task:
                        projection = task["nonlocalProjection"]
                        expected.remove((projection["path"], projection["localLine"]))
                        expected.add((projection["path"], projection["nonlocalLine"]))
                        local_consumer = (projection["path"], projection["localLine"])
                        if local_consumer in actual:
                            actual.remove(local_consumer)
                            actual.add((projection["path"], projection["nonlocalLine"]))
                    queries.append({
                        "id": task["id"], "milliseconds": times,
                        "sampleMediansMs": [statistics.median(sample) for sample in times],
                        "medianMs": statistics.median(value for sample in times for value in sample),
                        "matched": len(actual & expected), "extra": sorted(actual - expected),
                        "missed": sorted(expected - actual), "cliMcpEqual": True,
                    })
                final = client.request("tools/call", {"name": "cartograph_status", "arguments": {}})
                if final["response"]["result"]["structuredContent"] != initial_session:
                    raise RuntimeError("Session changed after the timed sample")
            finally:
                collector.save(directory / "mcp-transcript.json", client.transcript)
                client.close()
            row["arms"][label] = {
                "unused": dead["diagnostics"], "limitations": dead["limitations"],
                "nodes": graph["nodeCount"], "edges": graph["edgeCount"], "queries": queries,
            }
        before = {value["subject"]: value for value in row["arms"]["before"]["unused"]}
        after = {value["subject"]: value for value in row["arms"]["after"]["unused"]}
        row["newlyReported"] = [after[key] for key in sorted(after.keys() - before.keys())]
        row["noLongerReported"] = [before[key] for key in sorted(before.keys() - after.keys())]
        row["beforeAfterQueryEquality"] = []
        for task in selected:
            first = json.loads((args.output / project_name / "before" / f"{task['id']}-query.json").read_text())
            second = json.loads((args.output / project_name / "after" / f"{task['id']}-query.json").read_text())
            row["beforeAfterQueryEquality"].append({
                "id": task["id"], "equal": first == second,
                "beforeSHA256": hashlib.sha256(json.dumps(first, sort_keys=True).encode()).hexdigest(),
                "afterSHA256": hashlib.sha256(json.dumps(second, sort_keys=True).encode()).hexdigest(),
            })
        summary["projects"].append(row)
        collector.save(args.output / "results.json", summary)
        print(json.dumps({"project": project_name, "before": len(before), "after": len(after),
                          "new": len(row["newlyReported"]), "removed": len(row["noLongerReported"])}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
