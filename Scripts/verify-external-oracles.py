#!/usr/bin/env python3
"""Validate frozen source-reference witnesses with isolated compiler mutations."""

import argparse
import hashlib
import json
import os
import re
import runpy
import subprocess
import time
from pathlib import Path


TARGETS = {"alamofire": "Alamofire", "kingfisher": "Kingfisher", "argument-parser": "ArgumentParser"}


def verify_inputs(root, tasks):
    digest = hashlib.sha256((root / "tasks.json").read_bytes()).hexdigest()
    frozen = json.loads((root / "oracle-frozen.json").read_text())
    if digest != frozen["sha256"]:
        raise ValueError("Task file differs from the frozen oracle")
    validator = runpy.run_path(str(Path(__file__).with_name("benchmark-external-projects.py")))
    verified = validator["validate_inputs"](root / "repos")
    metadata = json.loads((root / "metadata.json").read_text())
    sources = {}
    for task in tasks:
        name, path = task["project"], task["target"]["path"]
        project = root / "repos" / name
        content = (project / path).read_bytes()
        committed = subprocess.check_output(["git", "show", f"HEAD:{path}"], cwd=project)
        if content != committed:
            raise ValueError(f"Target source differs from the pinned commit: {name}/{path}")
        sources[f"{name}/{path}"] = hashlib.sha256(content).hexdigest()
    return {"tasksSHA256": digest, "toolAndSourcePreflight": verified, "targetSourceSHA256": sources,
            "revisions": {name: details["revision"] for name, details in metadata["repos"].items()}}


def build(project, target, scratch, output, label):
    command = ["swift", "build", "--scratch-path", str(scratch), "--target", target, "-j", "4"]
    started = time.perf_counter()
    try:
        process = subprocess.run(command, cwd=project, capture_output=True, timeout=300)
        code, stdout, stderr = process.returncode, process.stdout, process.stderr
    except subprocess.TimeoutExpired as error:
        code, stdout, stderr = None, error.stdout or b"", error.stderr or b""
    (output / f"{label}.stdout").write_bytes(stdout)
    (output / f"{label}.stderr").write_bytes(stderr)
    result = {"command": command, "exit": code, "seconds": time.perf_counter() - started}
    (output / f"{label}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result, (stdout + stderr).decode(errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    output = root / "raw/oracle-mutations"
    output.mkdir(parents=True, exist_ok=True)
    tasks = json.loads((root / "tasks.json").read_text())
    tasks.append({"id": "kf-alias-diagnostic", "project": "kingfisher", "target": {
        "path": "Sources/SwiftUI/KFAnimatedImage.swift", "line": 77,
        "identifier": "KFCrossPlatformViewRepresentable",
    }, "gold": [{"path": "Sources/SwiftUI/KFAnimatedImage.swift", "referenceLines": [85]}]})
    identities = verify_inputs(root, tasks)
    (output / "preflight.json").write_text(json.dumps(identities, indent=2, sort_keys=True) + "\n")
    results = []
    for name, target in TARGETS.items():
        project = root / "repos" / name
        baseline, _ = build(project, target, project / ".build-oracle-baseline", output, f"{name}-baseline")
        if baseline["exit"] != 0:
            raise RuntimeError(f"Unmodified baseline did not compile: {name}")
        for task in [task for task in tasks if task["project"] == name]:
            declaration = task["target"]
            path = project / declaration["path"]
            original = path.read_bytes()
            stat = path.stat()
            lines = original.decode().splitlines(keepends=True)
            position = declaration["line"] - 1
            if task["id"] == "af-clock":
                assert "init()" in lines[position]
                lines[position] = lines[position].replace("init()", "init(cartographOracleProbe: Void)", 1)
            else:
                token = declaration["identifier"]
                assert token in lines[position]
                lines[position] = lines[position].replace(token, token + "__CartographOracleProbe", 1)
            try:
                path.write_text("".join(lines))
                result, log = build(project, target, project / f".build-oracle-{task['id']}", output, task["id"])
            finally:
                path.write_bytes(original)
                os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
            assert path.read_bytes() == original
            errors = {(match.group(1).removeprefix(str(project) + "/"), int(match.group(2)))
                      for match in re.finditer(r"([^\n]+\.swift):(\d+):\d+: error:", log)}
            expected = {(gold["path"], line) for gold in task["gold"] for line in gold["referenceLines"]}
            result.update({
                "id": task["id"], "sourceSHA256": hashlib.sha256(original).hexdigest(),
                "tasksSHA256": identities["tasksSHA256"], "revision": identities["revisions"][name],
                "sourceRestored": True, "expectedReferenceLines": sorted(expected),
                "compilerErrorLines": sorted(errors), "witnessesObserved": sorted(expected & errors),
                "witnessesNotDiagnosed": sorted(expected - errors),
            })
            results.append(result)
            (output / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
            print(json.dumps({"id": task["id"], "exit": result["exit"],
                              "witnesses": len(expected & errors), "expected": len(expected)}), flush=True)
            if result["exit"] is None or result["exit"] == 0:
                raise RuntimeError(f"Mutation failed to establish a compiler rejection: {task['id']}")


if __name__ == "__main__":
    main()
