#!/usr/bin/env python3
"""Actual workspace build, prior refusal/new selectors, execution and tamper controls."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("candidate", "baseline", "output"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--packages", type=int, choices=(0, 1, 2), default=0)
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    scope, fixture = load("cartograph-xcode-scope"), load("xcode-workspace-fixture")
    project = fixture.make(output / "project", packages=args.packages)
    config = project / "scope.yml"
    config.write_text('exclude:\n  - "Unbuilt/Tool.swift"\n')
    scope.run(["git", "-c", "core.hooksPath=/dev/null", "init", "-q"], project, output, "git-init", 30)
    (project / ".gitignore").write_text("Unbuilt/Tool.swift\n")
    started = time.monotonic()
    receipt_path = scope.capture(argparse.Namespace(project=str(project), workspace="Scope.xcworkspace", scheme="Scope",
        test_plan=None, local_package=bool(args.packages), cartograph=args.candidate, output=str(output / "capture"), config=str(config), timeout=600))
    receipt = json.loads(receipt_path.read_text())
    metadata = json.loads((output / "capture/capture.json").read_text())
    common = ["--project", str(project), "--index-store", metadata["indexStore"], "--config", str(config)]
    def invoke(label, extra, expected=0, executable=args.candidate):
        argv = [str(Path(executable).resolve()), "affected", "changedValue", *common, *extra]
        result = subprocess.run(argv, capture_output=True, timeout=180)
        (output / (label + ".stdout")).write_bytes(result.stdout)
        (output / (label + ".stderr")).write_bytes(result.stderr)
        scope.save(output / (label + ".process.json"), {"argv": argv, "exitCode": result.returncode})
        assert result.returncode == expected, (label, result.returncode, result.stderr.decode(errors="replace"))
        return json.loads(result.stdout) if "json" in extra else result.stdout.decode()
    assert invoke("baseline-default-refused", ["--format", "xcodebuild"], 2, args.baseline) == ""
    baseline_help = subprocess.run([str(Path(args.baseline).resolve()), "affected", "--help"], capture_output=True, timeout=30)
    assert baseline_help.returncode == 0
    if b"--target-scope" in baseline_help.stdout:
        assert invoke("baseline-v3-refused", ["--target-scope", str(receipt_path), "--format", "xcodebuild"], 2, args.baseline) == ""
    result = invoke("candidate-json", ["--target-scope", str(receipt_path), "--format", "json"])
    actual = result["targetScope"]
    assert actual["evidenceStatus"] == "matched-capture" and actual["xcode"]["selectionStatus"] == "review-candidates", actual
    assert actual["xcode"]["workspace"] == "Scope.xcworkspace", actual
    assert actual["xcode"]["projects"] == ["App.xcodeproj", "Core.xcodeproj"], actual
    assert any(x["classification"] == "outside-selected-targets" and x["path"] == "Unbuilt/Tool.swift" for x in actual["paths"]), actual
    assert any(x.startswith("source-discovery-exclusions:") for x in result["limitations"]), result
    selectors = invoke("candidate-selectors", ["--target-scope", str(receipt_path), "--format", "xcodebuild"]).splitlines()
    native_gate = load("verify-xcode-local-package-native")
    if result["tests"][0].get("xcodebuildIdentifier") is not None:
        granularity = native_gate.fixture_method_selection(result, selectors)
    else:
        # A missing parent/class identity must retain the exact whole-target fallback.
        assert selectors == ["-only-testing:ChecksBlueprint"], selectors
        assert any(x.startswith("uncertain-test-identity:") for x in result["limitations"]), result["limitations"]
        granularity = "whole-target"
    # Execute the untouched captured bundle before deliberately corrupting executable bytes.
    # Restoring a Mach-O's bytes does not promise that the OS clears a prior vnode signature cache.
    run = scope.run(["xcodebuild", "test-without-building", "-xctestrun", receipt["testRunPath"], "-destination", receipt["destination"],
        "-resultBundlePath", str(output / "selected-test.xcresult"), *selectors],
        project, output, "selected-test-run", 300, 16 * 1024 * 1024).decode(errors="replace")
    execution = native_gate.executed_tests(run)
    assert execution["executedTestCount"] == 1
    local_receipt = project / "workspace-scope-receipt.json"
    local_receipt.write_bytes(receipt_path.read_bytes())
    requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "workspace-scope-fixture", "version": "1"}}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "cartograph_affected", "arguments": {"symbols": ["changedValue"], "targetScope": "workspace-scope-receipt.json"}}}]
    mcp = subprocess.run([str(Path(args.candidate).resolve()), "serve", *common],
        input="".join(json.dumps(x) + "\n" for x in requests).encode(), capture_output=True, timeout=180)
    (output / "mcp.stdout").write_bytes(mcp.stdout)
    (output / "mcp.stderr").write_bytes(mcp.stderr)
    assert mcp.returncode == 0 and len(mcp.stdout) <= 4 * 1024 * 1024
    response = next(x for x in (json.loads(line) for line in mcp.stdout.splitlines() if line.strip()) if x.get("id") == 2)
    assert "error" not in response, response
    structured = response["result"].get("structuredContent")
    if structured is None:
        structured = json.loads(next(x["text"] for x in response["result"]["content"] if x.get("type") == "text"))
    mcp_scope = structured["result"]["targetScope"]
    assert mcp_scope["evidenceStatus"] == "matched-capture" and mcp_scope["xcode"]["selectionStatus"] == "review-candidates", mcp_scope
    assert mcp_scope["xcode"]["workspace"] == "Scope.xcworkspace", mcp_scope
    controls = []
    for label in ("missing-project", "unqualified-target", "wrong-workspace", "wrong-version"):
        changed = copy.deepcopy(receipt)
        if label == "missing-project": changed["projects"].remove("Core.xcodeproj")
        elif label == "unqualified-target": changed["selectedTargetIDs"][0] = changed["selectedTargetIDs"][0].split("::")[1]
        elif label == "wrong-workspace": changed["workspace"] = "Other.xcworkspace"
        else: changed["version"] = 2
        path = output / (label + ".json")
        scope.save(path, changed)
        assert invoke(label, ["--target-scope", str(path), "--format", "xcodebuild"], 2) == ""
        controls.append(label)
    for index, package in enumerate(receipt["localPackages"]):
        for kind, path in (("record", Path(package["records"][0]["path"])), ("object", Path(package["compilations"][0]["object"]))):
            label = "package-" + str(index) + "-" + kind + "-bytes"
            original, stamp = path.read_bytes(), path.stat()
            try:
                path.write_bytes(original + b"\nchanged-proof-bytes\n")
                import os
                os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                assert invoke(label, ["--target-scope", str(receipt_path), "--format", "xcodebuild"], 2) == ""
            finally:
                path.write_bytes(original)
                os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            controls.append(label)
    for label, path in (("workspace-edit", project / "Scope.xcworkspace/contents.xcworkspacedata"),
                        ("project-edit", project / "Core.xcodeproj/project.pbxproj"),
                        ("scheme-edit", project / receipt["schemePath"]),
                        ("product-edit", next(Path(p) for p in receipt["products"] if "/RunnableChecks.xctest/Contents/MacOS/" in p))):
        original, stamp = path.read_bytes(), path.stat()
        try:
            path.write_bytes(original + b"\n ")
            assert invoke(label, ["--target-scope", str(receipt_path), "--format", "xcodebuild"], 2) == ""
        finally:
            import os
            path.write_bytes(original)
            os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        controls.append(label)
    scope.save(output / "results.json", {"status": "passed", "selectors": selectors, "negativeControls": controls,
        "projects": receipt["projects"], "receiptVersion": 3, "executedTestCount": 1, "localPackageCount": args.packages,
        "selectionGranularity": granularity, "mcpScopeStatus": "review-candidates",
        "secondsIncludingPreparation": time.monotonic() - started,
        "candidateSHA256": hashlib.sha256(Path(args.candidate).read_bytes()).hexdigest(),
        "baselineSHA256": hashlib.sha256(Path(args.baseline).read_bytes()).hexdigest(),
        "limits": "Public synthetic two-project native macOS Swift/XCTest workspace. Not the private 22-project workspace, iOS, dynamic coverage or safe test omission."})
    print(json.dumps({"status": "passed", "output": str(output), "selectors": selectors}, sort_keys=True))


if __name__ == "__main__":
    main()
