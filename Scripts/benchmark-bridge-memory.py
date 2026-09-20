#!/usr/bin/env python3
"""Measure the unchanged bridge source cache and whole-process peak RSS on existing indexes."""

import argparse
import hashlib
import json
import platform
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-directory", type=Path, required=True)
    parser.add_argument("--project", type=Path, action="append", required=True)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("samples must be positive")
    root = Path(__file__).resolve().parents[1]
    products = args.build_directory.resolve()
    modules = products / "Modules" if (products / "Modules").exists() else products
    archive = products / "libCartographKit.a"
    if not archive.is_file():
        parser.error("build the CartographKit static library before measuring")
    includes = [modules, root / ".build/checkouts/Yams/Sources/CYaml/include",
                root / ".build/checkouts/indexstore-db/Sources/IndexStoreDB_CIndexStoreDB/include",
                root / ".build/checkouts/swift-syntax/Sources/_SwiftSyntaxCShims/include"]
    report = {"platform": platform.platform(), "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest(),
              "swift": subprocess.check_output(["swift", "--version"], text=True).strip(), "projects": [],
              "limitations": ["sourceCacheUTF8Bytes is source payload, excluding String and Dictionary overhead.",
                               "peakRSSBytes covers the entire instrumented process, including index and syntax work.",
                               "Peak differences do not isolate sourceCache allocations or prove an optimization.",
                               "The first sample may populate disk caches; later samples reuse them."]}
    with tempfile.TemporaryDirectory(prefix="cartograph-bridge-memory-") as directory:
        binary = Path(directory) / "measure"
        command = ["swiftc", "-O", str(root / "Scripts/measure-bridge-memory.swift")]
        for include in includes:
            command += ["-I", str(include)]
        command += ["-L", str(products), "-lCartographKit", "-lc++", "-o", str(binary)]
        subprocess.run(command, check=True)
        for project in args.project:
            samples = [json.loads(subprocess.check_output([str(binary), str(project.resolve())], text=True))
                       for _ in range(args.samples)]
            assert all(sample["maxReadsPerSource"] <= 1 for sample in samples), "bridge source was reread"
            assert len({sample["documentSHA256"] for sample in samples}) == 1, "bridge facts changed between samples"
            report["projects"].append({"project": project.resolve().name, "samples": samples})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
