#!/usr/bin/env python3
"""Verify bounded KVC key-path and predicate discovery against real Foundation execution."""

import argparse
from collections import Counter
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-runtime-keypaths-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/RuntimeKeyPathCorpus"
    project = output / "project"
    shutil.copytree(corpus, project, ignore=shutil.ignore_patterns(".build", ".swiftpm"))
    truth = json.loads((project / "ground-truth.json").read_text())
    result = {"status": "failed", "output": str(output)}

    def run(command, label):
        process = subprocess.run(command, cwd=project, capture_output=True, text=True, timeout=240)
        (output / f"{label}.stdout.log").write_text(process.stdout)
        (output / f"{label}.stderr.log").write_text(process.stderr)
        if process.returncode != 0:
            raise RuntimeError(f"{label}: expected exit 0, got {process.returncode}; see {output}")
        return process.stdout

    try:
        scratch = output / "build"
        build = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch)]
        run(build, "build")
        bin_path = Path(run(build + ["--show-bin-path"], "bin-path").strip())
        store = next(path for path in [scratch / "out", scratch / "index/store", bin_path / "index/store"]
                     if (path / "v5/units").is_dir() or (path / "units").is_dir())
        execution = run([str(bin_path / "RuntimeKeyPathProbe")], "execution").splitlines()
        assert "keypath=before->after,optional=nil,override=override" in execution
        assert "predicate=true,true,true" in execution
        common = ["--project", str(project), "--index-store", str(store)]
        snapshot = json.loads(run([str(binary), "snapshot"] + common, "snapshot"))["snapshot"]
        report = json.loads(run([str(binary), "runtime", "discover", "--limit", "10000"] + common, "discover"))
        symbols = {symbol["usr"]: symbol for symbol in snapshot["symbols"]}

        def owner(subject):
            symbol = symbols.get(subject.get("usr"), {})
            seen = set()
            while symbol.get("parentUSR") and symbol["parentUSR"] not in seen:
                seen.add(symbol["parentUSR"])
                symbol = symbols.get(symbol["parentUSR"], {})
                if symbol.get("kind") in ["class", "struct", "protocol", "enum"]:
                    return symbol.get("name")
            return None

        expected = Counter(
            (item["source"], item["target"], item["kind"], item["owner"])
            for item in truth["supportedConnections"]
        )
        actual = Counter()
        for finding in report["findings"]:
            if finding["status"] != "resolved":
                continue
            source = (finding.get("source") or {}).get("name")
            for target in finding["targets"]:
                actual[(source, target["name"], finding["kind"], owner(target))] += 1
        matched = actual & expected
        missing = expected - actual
        unexpected = actual - expected
        tp, fp, fn = sum(matched.values()), sum(unexpected.values()), sum(missing.values())
        classification_errors = []
        for expected_case in truth["classifications"]:
            matches = [finding for finding in report["findings"]
                       if (finding.get("source") or {}).get("name") == expected_case["source"]
                       and finding["kind"] == expected_case["kind"] and finding["api"] == expected_case["api"]]
            good = [finding for finding in matches
                    if finding["status"] == expected_case["status"]
                    and len(finding["candidates"]) == expected_case["candidateCount"]]
            if len(good) != 1:
                classification_errors.append({"expected": expected_case, "actual": matches})
        for source in truth["silentCases"]:
            if any((finding.get("source") or {}).get("name") == source for finding in report["findings"]):
                classification_errors.append({"source": source, "error": "unsupported call produced a boundary"})
        for expected_limit in truth["unsupported"]:
            fragment = expected_limit["limitationContains"]
            if not any(fragment in limitation for limitation in report["limitations"]):
                classification_errors.append({"label": expected_limit["label"], "error": "missing limitation"})
        precision = tp / (tp + fp) if tp + fp else 0
        recall = tp / sum(expected.values()) if expected else 0
        result.update(
            tp=tp, fp=fp, fn=fn, precision=precision, recall=recall,
            expectedRelationships=sum(expected.values()), boundaryCount=report["boundaryCount"],
            connectionCount=report["connectionCount"], classificationErrors=classification_errors,
            missing=[{"tuple": list(key), "count": value} for key, value in missing.items()],
            unexpected=[{"tuple": list(key), "count": value} for key, value in unexpected.items()],
            foundationExecutionPassed=True,
        )
        result["status"] = "passed" if precision == 1 and recall == 1 and not classification_errors else "failed"
    except Exception as error:
        result["error"] = str(error)
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
