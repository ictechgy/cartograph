#!/usr/bin/env python3
"""Run the shipped payload on the real compiler corpus without changing that corpus."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from test_component import runner_source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--binary", default="")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cartograph-gitlab-live-") as directory:
        checkout = Path(directory).resolve()
        project = checkout / "fixtures/Swift Project"
        shutil.copytree(args.corpus, project, ignore=shutil.ignore_patterns(".build", ".DS_Store"))
        subprocess.run(["swift", "build", "--build-tests"], cwd=project, check=True)
        environment = {
            **os.environ, "CI_PROJECT_DIR": str(checkout), "CARTOGRAPH_PROJECT": "fixtures/Swift Project",
            "CARTOGRAPH_COMMAND": "dead", "CARTOGRAPH_BUILD": "none", "CARTOGRAPH_ARGS": "",
            "CARTOGRAPH_FAIL_ON_FINDINGS": "false", "CARTOGRAPH_BINARY": args.binary,
            "CARTOGRAPH_VERSION": "0.20.0",
            "CARTOGRAPH_SHA256": "833eb3c86deffc8e7c845297df57d41e35bb644bd5a943b09843e52075c6f072",
        }
        result = subprocess.run([sys.executable, "-c", runner_source()], cwd=checkout, env=environment)
        if result.returncode != 0:
            raise RuntimeError(f"The real component failed with exit {result.returncode}")
        raw = json.loads((checkout / "cartograph-report.json").read_text())
        quality = json.loads((checkout / "gl-code-quality-report.json").read_text())
        status = json.loads((checkout / "cartograph-status.json").read_text())
        assert raw["diagnostics"] and quality, "Live validation must contain actual compiler findings"
        expected = sorted((item["ruleIdentifier"], item["message"], item["location"]["line"])
                          for item in raw["diagnostics"] if item.get("location"))
        actual = sorted((item["check_name"], item["description"], item["location"]["lines"]["begin"])
                        for item in quality)
        assert actual == expected, "The conversion changed or dropped a located diagnostic"
        for finding in quality:
            path = finding["location"]["path"]
            assert path.startswith("fixtures/Swift Project/")
            assert (checkout / path).is_file(), path
            assert finding["severity"] in {"info", "minor", "major"}
        expected_unused = sorted((project / "expected-unused.txt").read_text().splitlines())
        actual_unused = sorted(item["description"] for item in quality if item["check_name"] == "unused-symbol")
        assert actual_unused == expected_unused, "Compiler findings differ from the corpus's complete golden"
        assert status["cli_exit_code"] == 1, "The probe must exercise report-only findings"
        for filename in ["cartograph-report.json", "gl-code-quality-report.json", "cartograph-status.json"]:
            shutil.copyfile(checkout / filename, output / filename)
        evidence = {"status": "passed", "cli_version": raw["version"], "diagnostics": len(raw["diagnostics"]),
                    "code_quality_findings": len(quality), "rules": sorted({item["check_name"] for item in quality}),
                    "source_paths_verified": True, "unused_golden_verified": True}
        (output / "live-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
        print(json.dumps(evidence, sort_keys=True))


if __name__ == "__main__":
    main()
