#!/usr/bin/env python3
"""Score automatic runtime relationships against an independently labelled compiler corpus."""

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-discovery-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/RuntimeDiscoveryCorpus"
    project = output / "project"
    shutil.copytree(corpus, project, ignore=shutil.ignore_patterns(".build", ".swiftpm"))
    truth = json.loads((project / "ground-truth.json").read_text())
    result = {"status": "failed", "output": str(output), "unscoredCommonPatterns": truth["unscoredCommonPatterns"]}

    def run(command, name, expected=0):
        process = subprocess.run(command, cwd=project, capture_output=True, text=True, timeout=240)
        (output / f"{name}.stdout.log").write_text(process.stdout)
        (output / f"{name}.stderr.log").write_text(process.stderr)
        if process.returncode != expected:
            raise RuntimeError(f"{name}: expected exit {expected}, got {process.returncode}")
        return process.stdout

    def build(label):
        scratch = output / f"{label}-build"
        cmd = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch)]
        run(cmd, f"{label}-build")
        bin_path = Path(run(cmd + ["--show-bin-path"], f"{label}-bin").strip())
        for path in [scratch / "out", scratch / "index/store", bin_path / "index/store"]:
            if (path / "v5/units").is_dir() or (path / "units").is_dir():
                return path, bin_path / "RuntimeDiscoveryApp"
        raise RuntimeError(f"{label}: compiler index was not produced")

    def document(command, label, store, expected=0):
        return json.loads(run([str(binary)] + command + ["--project", str(project), "--index-store", str(store)],
                              label, expected))

    try:
        store, executable = build("before")
        execution = run([str(executable)], "before-executable")
        assert "kvc=before->after" in execution.splitlines(), "Foundation KVC execution did not match the model"
        assert "kvc-priority=aliased-getter,getter-property,aliased-property" in execution.splitlines(), (
            "Foundation KVC getter precedence did not match the negative cases"
        )
        assert "notification-identity=1,1,1,1" in execution.splitlines(), (
            "Foundation notification identity did not match the static model"
        )
        assert "notification-post-before-observer=0,0" in execution.splitlines(), (
            "A fresh local center delivered a notification posted before observer registration"
        )
        assert "notification-removed-before-post=0,0" in execution.splitlines(), (
            "A removed local observer received a later notification"
        )
        assert "notification-branch-removal=0,1" in execution.splitlines(), (
            "A branch-local removal was applied outside its executed path"
        )
        assert "notification-defer=0,1" in execution.splitlines(), (
            "Deferred observer removal was applied at the wrong scope boundary"
        )
        assert "notification-combine-cancel=0" in execution.splitlines(), (
            "A cancelled NotificationCenter publisher received a later notification"
        )
        before = document(["snapshot"], "snapshot", store)
        snapshot_path = output / "before.json"
        snapshot_path.write_text(json.dumps(before))
        assert before["version"] == 2, "new captures must preserve runtime facts in snapshot v2"
        report = document(["runtime", "discover", "--limit", "10000"], "discover", store)
        assert not report["truncated"], "scored report was truncated"
        symbols = {symbol["usr"]: symbol for symbol in before["snapshot"]["symbols"]}

        def owner(subject):
            symbol = symbols.get(subject.get("usr"), {})
            seen = set()
            while symbol.get("parentUSR") and symbol["parentUSR"] not in seen:
                seen.add(symbol["parentUSR"])
                symbol = symbols.get(symbol["parentUSR"], {})
                if symbol.get("kind") in ["class", "struct", "protocol", "enum"]:
                    return symbol.get("name")
            return None

        qualified = {(x["source"], x["target"], x["kind"]) for x in truth["supportedConnections"] if "owner" in x}
        def key(source, target, kind, target_owner=None):
            base = (source, target, kind)
            return base + ((target_owner if base in qualified else None),)

        expected = Counter(key(x["source"], x["target"], x["kind"], x.get("owner"))
                           for x in truth["supportedConnections"])
        actual = Counter()
        for finding in report["findings"]:
            if finding["status"] in ["resolved", "alreadyIndexed"]:
                source = (finding.get("source") or {}).get("name")
                for target in finding["targets"]:
                    actual[key(source, target["name"], finding["kind"], owner(target))] += 1
        matched = actual & expected
        missing, extra = expected - actual, actual - expected
        tp, fp, fn = sum(matched.values()), sum(extra.values()), sum(missing.values())
        precision = tp / (tp + fp) if tp + fp else 0
        recall = tp / sum(expected.values()) if expected else 0
        classification_errors = []
        forbidden_violations = []
        for case in truth.get("forbiddenConnections", []):
            forbidden_key = key(case["source"], case["target"], case["kind"], case.get("owner"))
            if actual[forbidden_key] > 0:
                forbidden_violations.append(case["label"])
                classification_errors.append({"label": case["label"], "error": "forbidden connection was reported"})
        for case in truth["classifications"]:
            matching = [f for f in report["findings"]
                        if (f.get("source") or {}).get("name") == case["source"]
                        and f["kind"] == case["kind"] and f["api"] == case["api"]]
            good = [f for f in matching if f["status"] in case.get("acceptedStatuses", [case["status"]])
                    and ("name" not in case or f.get("name") == case["name"])
                    and ("candidateCount" not in case or len(f["candidates"]) == case["candidateCount"])]
            if len(good) != 1:
                classification_errors.append({"label": case["label"], "expected": case,
                    "actual": [{"status": f["status"], "name": f.get("name"),
                                "candidates": len(f["candidates"]), "reason": f.get("reason")} for f in matching]})
        for case in truth["silentCases"]:
            if any((f.get("source") or {}).get("name") == case["source"] for f in report["findings"]):
                classification_errors.append({"label": case["label"], "error": "non-boundary wrapper was invented"})
        for case in truth["unsupported"]:
            exact = case.get("limitation")
            fragment = case.get("limitationContains")
            matched_limitation = exact in report["limitations"] if exact is not None else any(
                fragment in limitation for limitation in report["limitations"]
            )
            if not matched_limitation:
                classification_errors.append({"label": case["label"], "error": "unsupported boundary was not reported"})
        result.update(tp=tp, fp=fp, fn=fn, precision=precision, recall=recall,
                      expectedRelationships=sum(expected.values()), boundaryCount=report["boundaryCount"],
                      newAutomaticConnections=report["connectionCount"], countsByStatus=report["countsByStatus"],
                      forbiddenViolations=forbidden_violations,
                      missing=[{"tuple": list(k), "count": v} for k, v in missing.items()],
                      unexpected=[{"tuple": list(k), "count": v} for k, v in extra.items()],
                      classificationErrors=classification_errors)
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")

        # 해석 대상 소스가 unit보다 새로우면 예전 연결을 확정하지 않는다.
        stale_file = project / "Sources/RuntimeDiscoveryApp/StaleCases.swift"
        original = stale_file.read_text()
        stale_file.write_text(original + "\n// changed after indexing\n")
        import os
        os.utime(stale_file, (time.time() + 5, time.time() + 5))
        stale = document(["runtime", "discover", "--limit", "10000"], "stale", store)
        entry = next(f for f in stale["findings"] if (f.get("source") or {}).get("name") == "staleLookup()"
                     or (f["kind"] == "classLookup" and f["location"]["path"].endswith("StaleCases.swift")))
        assert entry["status"] == "stale", "stale source retained a proven connection"
        stale_file.write_text(original)

        legacy = project / "Sources/RuntimeDiscoveryApp/LegacyCases.swift"
        content = legacy.read_text()
        for section in ["METHOD", "CALL"]:
            content = re.sub(rf"    // BEGIN_LEGACY_{section}.*?    // END_LEGACY_{section}\n", "", content, flags=re.S)
        legacy.write_text(content.replace("renamedAction", "newAction"))
        after_store, _ = build("after")
        historical_errors = []
        for case in truth["historicalComparisons"]:
            comparison = document(["impact", case["query"], "--before", str(snapshot_path), "--format", "json"],
                                  "historical-" + case["label"], after_store)
            before_runtime = comparison["before"].get("automaticRuntime") or {}
            found = any(f["kind"] == case["kind"] and (f.get("source") or {}).get("name") == case["source"]
                        and any(t["name"] == case["target"] for t in f["targets"])
                        for f in before_runtime.get("findings", []))
            if not found or comparison["status"] != "found":
                historical_errors.append(case["label"])
        result["historicalErrors"] = historical_errors
        result["staleClassificationPassed"] = True
        result["foundationKVCExecutionPassed"] = True
        result["notificationIdentityExecutionPassed"] = True
        result["notificationRemovalExecutionPassed"] = True
        result["notificationBranchExecutionPassed"] = True
        result["notificationDeferredExecutionPassed"] = True
        result["notificationCancellationExecutionPassed"] = True
        passed = precision == 1 and recall >= .95 and not classification_errors and not historical_errors
        result["status"] = "passed" if passed else "failed"
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return 0 if passed else 1
    except Exception as error:
        result["error"] = str(error)
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
