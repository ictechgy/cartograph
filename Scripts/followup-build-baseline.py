#!/usr/bin/env python3
"""Build the frozen first-feedback commit separately from the candidate."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--github-env", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("scope_capture", root / "Scripts/cartograph-swiftpm-scope.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    revision = "fae3c24b1776af8d75151663821f8ff221d928f8"
    module.run(["git", "-c", "core.hooksPath=/dev/null", "fetch", "--depth", "1", "origin", revision],
               root, output, "fetch", 120)
    source = output / "source"
    module.run(["git", "-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", str(source), revision],
               root, output, "checkout", 120)
    module.run(["swift", "build", "--jobs", "3"], source, output, "build", 1200)
    directory = module.run(["swift", "build", "--show-bin-path"], source, output, "bin-path", 60).decode().strip()
    binary = Path(directory) / "cartograph"
    tree = module.run(["git", "rev-parse", "HEAD^{tree}"], source, output, "tree", 30).decode().strip()
    module.save(output / "results.json", {"commit": revision, "tree": tree, "binary": str(binary),
        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()})
    with Path(args.github_env).open("a", encoding="utf-8") as environment:
        environment.write("FOLLOWUP_BASELINE=" + str(binary) + "\n")


if __name__ == "__main__":
    main()
