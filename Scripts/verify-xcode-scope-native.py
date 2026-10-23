#!/usr/bin/env python3
"""Native Xcode prior-fail/new-pass and fail-closed controls on a public synthetic project."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("xcode_scope", ROOT / "Scripts/cartograph-xcode-scope.py")
SCOPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCOPE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    project = output / "project"
    shutil.copytree(ROOT / "Fixtures/XcodeAffectedScope", project)
    # Exercise a real SDK framework input in addition to the locally built CoreProduct.
    pbx = project / "Scope.xcodeproj/project.pbxproj"
    plist = json.loads(SCOPE.run(["plutil", "-convert", "json", "-o", "-", str(pbx)], project, output, "fixture-project", 30))
    objects = plist["objects"]
    phase = next(x for x in objects.values() if x["isa"] == "PBXFrameworksBuildPhase")
    objects["000000000000000000000050"] = {"isa": "PBXFileReference", "sourceTree": "SDKROOT", "path": "System/Library/Frameworks/Foundation.framework"}
    objects["000000000000000000000051"] = {"isa": "PBXBuildFile", "fileRef": "000000000000000000000050"}
    phase.setdefault("files", []).append("000000000000000000000051")
    pbx.write_bytes(plistlib.dumps(plist))
    SCOPE.run(["git", "init", "-q"], project, output, "git-init", 30)
    (project / ".gitignore").write_text("Unbuilt/Tool.swift\n", encoding="utf-8")
    config = project / "scope.yml"
    config.write_text('exclude:\n  - "Unbuilt/Tool.swift"\n', encoding="utf-8")
    started = time.monotonic()
    try:
        receipt_path = SCOPE.capture(argparse.Namespace(project=str(project), xcode_project="Scope.xcodeproj", scheme="Scope",
            test_plan=None, cartograph=args.candidate, output=str(output / "capture"), config=str(config), timeout=600))
    except Exception:
        # Public synthetic inputs only; keep failure diagnosis visible even if the
        # artifact transport is unavailable. Bound output independently of logs.
        for log in sorted((output / "capture").glob("*.stderr"), key=lambda p: p.stat().st_mtime)[-3:]:
            print(log.name + ":\n" + log.read_bytes()[-4096:].decode(errors="replace"), flush=True)
        raise
    receipt = json.loads(receipt_path.read_text())
    metadata = json.loads((output / "capture/capture.json").read_text())
    common = ["--project", str(project), "--index-store", metadata["indexStore"], "--config", str(config)]
    binary = str(Path(args.candidate).resolve())

    def invoke(label, extra, expected=0, executable=binary):
        argv = [executable, "affected", "changedValue", *common, *extra]
        result = subprocess.run(argv, capture_output=True, timeout=120)
        (output / (label + ".stdout")).write_bytes(result.stdout)
        (output / (label + ".stderr")).write_bytes(result.stderr)
        SCOPE.save(output / (label + ".process.json"), {"argv": argv, "exitCode": result.returncode})
        assert result.returncode == expected, (label, result.returncode, result.stderr.decode(errors="replace"))
        return json.loads(result.stdout) if "json" in extra else result.stdout.decode()

    assert invoke("baseline-refused", ["--format", "xcodebuild"], 2, str(Path(args.baseline).resolve())) == ""
    baseline = invoke("baseline-json", ["--format", "json"], executable=str(Path(args.baseline).resolve()))
    assert baseline["summary"]["testCount"] > 0
    result = invoke("candidate-json", ["--format", "json", "--target-scope", str(receipt_path)])
    scope = result["targetScope"]
    assert scope["evidenceStatus"] == "matched-capture", scope
    assert scope["xcode"]["selectionStatus"] == "review-candidates", scope
    assert scope["xcode"]["selectorTargetByModule"]["ChecksModule"] == "RunnableChecks", scope
    assert any(x["path"] == "Unbuilt/Tool.swift" and x["classification"] == "outside-selected-targets" for x in scope["paths"]), scope
    assert any(x.startswith("source-discovery-exclusions:") for x in result["limitations"])
    selectors = invoke("candidate-selectors", ["--format", "xcodebuild", "--target-scope", str(receipt_path)]).splitlines()
    assert selectors and all(x.startswith("-only-testing:RunnableChecks") for x in selectors), selectors
    assert not any("ChecksModule" in x or "ChecksBlueprint" in x or "OtherRunnable" in x for x in selectors), selectors
    # Unbound MCP input cannot use a fresh fingerprint as a stamp on a previous generation.
    local_receipt = project / "scope-receipt.json"
    local_receipt.write_bytes(receipt_path.read_bytes())
    requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "scope-fixture", "version": "1"}}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "cartograph_affected", "arguments": {"symbols": ["changedValue"], "targetScope": "scope-receipt.json"}}}]
    mcp = subprocess.run([binary, "serve", *common], input="".join(json.dumps(x) + "\n" for x in requests).encode(), capture_output=True, timeout=120)
    (output / "mcp.stdout").write_bytes(mcp.stdout); (output / "mcp.stderr").write_bytes(mcp.stderr)
    responses = [json.loads(line) for line in mcp.stdout.splitlines() if line.strip()]
    answer = next(x for x in responses if x.get("id") == 2)
    assert "error" not in answer, answer
    structured = answer["result"].get("structuredContent")
    if structured is None:
        structured = json.loads(next(x["text"] for x in answer["result"]["content"] if x.get("type") == "text"))
    assert structured["result"]["targetScope"]["xcode"]["selectionStatus"] == "review-candidates", structured

    controls = []
    for label, relative, replacement in [
        ("source-edit", "Core/Core.swift", b"\n// source changed\n"),
        ("scheme-edit", "Scope.xcodeproj/xcshareddata/xcschemes/Scope.xcscheme", b"\n<!-- changed -->\n"),
        ("plan-edit", "Scope.xctestplan", b"\n "),
        ("unknown-source", "Unknown.swift", b"func unknownCaller() {}\n")]:
        path = project / relative
        original = path.read_bytes() if path.exists() else None
        stamp = path.stat() if path.exists() else None
        path.write_bytes((original or b"") + replacement)
        changed = invoke(label, ["--format", "json", "--target-scope", str(receipt_path)])
        assert changed["targetScope"]["evidenceStatus"] == "unknown", changed["targetScope"]
        assert invoke(label + "-refused", ["--format", "xcodebuild", "--target-scope", str(receipt_path)], 2) == ""
        if original is None: path.unlink()
        else:
            path.write_bytes(original)
            os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        controls.append(label)
    for label in ("wrong-module", "wrong-destination", "wrong-selected-target", "wrong-bundle", "module-collision", "dependency-product", "dependency-path", "external-host"):
        changed = json.loads(receipt_path.read_text())
        if label == "wrong-module": changed["targets"][0]["module"] = "Unrelated"
        elif label == "wrong-destination": changed["destination"] = "platform=iOS Simulator"
        elif label == "wrong-selected-target": changed["selectedTargetIDs"] = [x["id"] for x in changed["targets"] if x["name"] == "UnbuiltBlueprint"]
        elif label in ("module-collision", "dependency-product"):
            settings = json.loads(changed["buildSettingsJSON"])
            if label == "module-collision":
                next(x for x in changed["targets"] if x["name"] == "UnbuiltBlueprint")["module"] = "ChecksModule"
                next(x for x in settings if x["target"] == "UnbuiltBlueprint")["buildSettings"]["PRODUCT_MODULE_NAME"] = "ChecksModule"
            else:
                next(x for x in settings if x["target"] == "CoreBlueprint")["buildSettings"]["TARGET_BUILD_DIR"] = str(output / "outside")
            changed["buildSettingsJSON"] = json.dumps(settings)
        else:
            path = Path(changed["testRunPath"])
            original = path.read_bytes()
            run = plistlib.loads(original)
            rows = run["TestConfigurations"][0]["TestTargets"] if "TestConfigurations" in run else [v for k,v in run.items() if not k.startswith("__")]
            if label == "wrong-bundle": rows[0]["TestBundlePath"] = "__TESTROOT__/Debug/Unrelated.xctest"
            elif label == "dependency-path": rows[0]["DependentProductPaths"] = [str(output / "outside/CoreProduct.framework")]
            else: rows[0]["TestHostPath"] = str(output / "outside/Host.app/Contents/MacOS/Host")
            path.write_bytes(plistlib.dumps(run))
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            changed["products"][str(path)] = digest
            changed["testRunSHA256"] = digest
        path_receipt = output / (label + ".json")
        SCOPE.save(path_receipt, changed)
        assert invoke(label, ["--format", "xcodebuild", "--target-scope", str(path_receipt)], 2) == ""
        if label in ("wrong-bundle", "dependency-path", "external-host"): path.write_bytes(original)
        controls.append(label)
    product = next(Path(p) for p in receipt["products"] if "/RunnableChecks.xctest/Contents/MacOS/" in p)
    original = product.read_bytes()
    product.write_bytes(original + b"changed")
    assert invoke("changed-product", ["--format", "xcodebuild", "--target-scope", str(receipt_path)], 2) == ""
    product.write_bytes(original)
    controls.append("changed-product")
    # Read current xcodebuild documentation and run precisely the emitted selectors against captured bundles.
    SCOPE.run(["xcodebuild", "-help"], project, output, "xcodebuild-help", 60)
    run = SCOPE.run(["xcodebuild", "test-without-building", "-xctestrun", receipt["testRunPath"],
                     "-destination", receipt["destination"], *selectors], project, output, "selected-test-run", 300, 16 * 1024 * 1024).decode(errors="replace")
    assert "testChanged" in run and "Executed 1 test" in run and "testOther'" not in run, run[-8000:]
    SCOPE.save(output / "results.json", {"status": "passed", "baselineCommit": "5dc4718812b81baf981741f9dd0931f24fde6004",
        "candidateCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "selectors": selectors, "negativeControls": controls, "secondsIncludingPreparation": time.monotonic() - started,
        "baselineSHA256": hashlib.sha256(Path(args.baseline).read_bytes()).hexdigest(),
        "candidateSHA256": hashlib.sha256(Path(args.candidate).read_bytes()).hexdigest(),
        "limits": "Public synthetic single-project macOS Swift/XCTest fixture only; not the private 22-project workspace or an omission guarantee."})


if __name__ == "__main__":
    main()
