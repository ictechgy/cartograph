#!/usr/bin/env python3
"""Real finite-package capture/CLI/MCP/selected-test checks on the public Xcode fixture."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SCOPE = load("scope", ROOT / "Scripts/cartograph-xcode-scope.py")
OBS = load("observation", ROOT / "Scripts/observe-xcode-local-package.py")


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def executed_tests(text):
    """Require the terminal XCTest aggregate and the exact observed case identity."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    expected = "-[ChecksModule.ChangedTests testChanged]"
    cases = []
    for line in lines:
        if line.startswith("Test Case "):
            match = re.fullmatch(r"Test Case '([^']+)' (started\.|passed \([0-9.]+ seconds\)\.)", line)
            require(match is not None, "Unexpected failed/skipped/unparsed test-case event")
            cases.append((match[1], "started" if match[2] == "started." else "passed"))
    require(cases == [(expected, "started"), (expected, "passed")],
            "Actual test-case identity/count differs from the one selected fixture case")
    all_suites = [i for i, line in enumerate(lines) if line.startswith("Test Suite 'All tests' passed at ")]
    require(len(all_suites) == 1, "Missing or multiple terminal All tests aggregates")
    index = all_suites[0]
    require(index + 1 < len(lines), "Missing terminal aggregate count")
    match = re.fullmatch(r"Executed (\d+) tests?, with (\d+) failures \((\d+) unexpected\) in [0-9.]+ \([0-9.]+\) seconds",
                         lines[index + 1])
    require(match is not None and tuple(map(int, match.groups())) == (1, 0, 0),
            "Terminal test aggregate is not exactly one passing test")
    require(not any(line.startswith(("Test Case ", "Executed ", "Test Suite ")) for line in lines[index + 2:])
            and "** TEST EXECUTE SUCCEEDED **" in lines, "Test execution continued after the claimed final aggregate")
    return {"executedTestCount": int(match[1]), "executedTestIdentities": [expected], "aggregate": lines[index + 1]}


def mcp_worker(binary, output):
    peer_module = load("preparation_peer", ROOT / "Scripts/followup-verify-mcp-preparation.py")
    metadata = json.loads((output / "capture/capture.json").read_text())
    receipt_path = output / "capture/target-scope.json"
    receipt = json.loads(receipt_path.read_text())
    project = output / "project"
    local_receipt = project / "local-package-receipt.json"
    local_receipt.write_bytes(receipt_path.read_bytes())
    logs = output / "mcp"
    logs.mkdir()
    peer = peer_module.Peer(binary, project, logs, "full", ["--index-store", metadata["indexStore"]])
    record = Path(receipt["localPackage"]["records"][0]["path"])
    original, stamp = record.read_bytes(), record.stat()
    result = {"status": "failed"}
    try:
        peer.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                    "clientInfo": {"name": "local-package-scope", "version": "1"}})
        peer.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        peer.process.stdin.flush()
        def affected():
            return peer.request("tools/call", {"name": "cartograph_affected", "arguments": {
                "symbols": ["packageValue"], "targetScope": local_receipt.name}}, timeout=120)
        def content(response):
            body = response["result"]
            return body.get("structuredContent") or json.loads(body["content"][0]["text"])
        first = affected()
        before = content(first)
        require(not first["result"].get("isError") and before["result"]["targetScope"]["xcode"]["selectionStatus"] == "review-candidates",
                "Native MCP did not consume current package proof")
        # Updating only the current file hash must not bless the old cached graph.
        record.write_bytes(b"invalid changed raw index record\n")
        os.utime(record, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        identity = receipt["localPackage"]["files"][str(record)]
        identity.update(sha256=hashlib.sha256(record.read_bytes()).hexdigest(), bytes=record.stat().st_size)
        SCOPE.save(local_receipt, receipt)
        second = affected()
        require(second.get("error") or second.get("result", {}).get("isError"),
                "Cached MCP graph certified changed backing record without invalidation")
        status = peer.request("tools/call", {"name": "cartograph_prepare", "arguments": {"action": "status"}}, timeout=30)
        require(content(status)["state"] != "ready", "Failed v2 proof retained ready MCP metadata")
        result.update({"status": "passed", "firstGeneration": before.get("session", {}).get("generation"),
                       "changedRecordResponse": second, "postFailurePreparation": content(status),
                       "control": "same unit/source/product identity; changed record bytes and receipt hash; same MCP process"})
    finally:
        record.write_bytes(original)
        os.utime(record, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        local_receipt.write_bytes(receipt_path.read_bytes())
        try:
            peer.close()
        finally:
            result["ownedServerClosed"] = peer.closed
            if not peer.closed:
                result["status"] = "failed"
            SCOPE.save(output / "mcp-result.json", result)


def verify(binary, output):
    output.mkdir(parents=True, exist_ok=False)
    project = output / "project"
    shutil.copytree(ROOT / "Fixtures/XcodeLocalPackageScope", project)
    started = time.monotonic()
    args = argparse.Namespace(project=str(project), xcode_project="Scope.xcodeproj", scheme="ChecksOnly",
        test_plan=None, cartograph=str(binary), output=str(output / "capture"), config=None, timeout=600, local_package=True)
    # Existing v1/default admission stays conservative, before any project command.
    default = argparse.Namespace(**vars(args))
    default.local_package, default.output = False, str(output / "default-refused")
    try:
        SCOPE.capture(default)
        raise RuntimeError("Default v1 unexpectedly accepted a local package")
    except SCOPE.CaptureError as error:
        require(not (Path(default.output) / "build-for-testing.stdout").exists(), "Default refusal happened after build")
        SCOPE.save(output / "default-refusal.json", {"status": "refused-before-build", "reason": str(error)})
    try:
        receipt_path = SCOPE.capture(args)
    except Exception:
        for path in sorted((output / "capture").glob("*.stderr"), key=lambda p: p.stat().st_mtime)[-3:]:
            print(path.name + ":\n" + path.read_bytes()[-4096:].decode(errors="replace"), flush=True)
        raise
    receipt = json.loads(receipt_path.read_text())
    metadata = json.loads((output / "capture/capture.json").read_text())
    require(receipt["version"] == 2 and receipt["localPackage"]["product"] == "ArithmeticProduct"
            and receipt["localPackage"]["module"] == "ArithmeticCore", "Package/product identities were lost")
    common = ["--project", str(project), "--index-store", metadata["indexStore"], "--target-scope", str(receipt_path)]
    supervisor = OBS.process_supervisor()
    def invoke(label, format="json", expected=0):
        argv = [str(binary), "affected", "packageValue", *common, "--format", format]
        process = supervisor.run(argv, project, output / label, 120, stream_limit=4 * 1024 * 1024)
        expected_code = process["returncode"] > 0 if expected is None else process["returncode"] == expected
        require(expected_code and not process["timed_out"] and process["owned_root_reaped"]
                and not process["ownership_lost"] and not process["cleanup_errors"]
                and not process.get("output_limit_exceeded") and not process.get("exception_type"),
                "Unexpected affected process outcome: " + label)
        raw = SCOPE.bounded(output / (label + ".stdout"), 4 * 1024 * 1024)
        return json.loads(raw) if format == "json" and raw else raw.decode()
    document = invoke("candidate-json")
    scope = document["targetScope"]
    require(scope["evidenceStatus"] == "matched-capture" and scope["xcode"]["selectionStatus"] == "review-candidates",
            "Actual package record and linker proof did not produce review candidates")
    require(scope["xcode"]["selectorTargetByModule"] == {"ChecksModule": "ChecksBlueprint"}
            and scope["xcode"]["testBundleByModule"] == {"ChecksModule": "RunnableChecks.xctest"},
            "Blueprint, compiler module and bundle identities were conflated")
    selectors = invoke("candidate-selectors", "xcodebuild").splitlines()
    require(selectors == ["-only-testing:ChecksBlueprint"], "Expected honest whole-target selector fallback")
    controls = []
    for label, path, append in [
        ("source-bytes", project / "Packages/LocalMath/Sources/ArithmeticCore/Math.swift", b"\n// changed\n"),
        ("manifest-bytes", project / "Packages/LocalMath/Package.swift", b"\n// changed\n"),
        ("unexpected-clang", project / "Packages/LocalMath/Sources/ArithmeticCore/Hidden.cpp", b"int hidden;\n"),
        ("unexpected-resource", project / "Packages/LocalMath/blob.bin", b"resource")]:
        original = path.read_bytes() if path.exists() else None
        stamp = path.stat() if path.exists() else None
        path.write_bytes((original or b"") + append)
        if stamp:
            os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        try:
            require(invoke(label, "xcodebuild", 2) == "", "Changed package emitted selectors")
        finally:
            if original is None:
                path.unlink()
            else:
                path.write_bytes(original)
                os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        controls.append(label)
    package = receipt["localPackage"]
    proof_paths = {"record-bytes": package["records"][0]["path"], "object-bytes": package["compilations"][0]["object"],
                   "link-map-bytes": package["links"][0]["link"]["linkMap"],
                   "response-bytes": next(p for p in package["files"] if p.endswith(".resp"))}
    for label, name in proof_paths.items():
        path = Path(name)
        original, stamp = path.read_bytes(), path.stat()
        path.write_bytes(original + b"changed")
        os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        try:
            require(invoke(label, "xcodebuild", None if label == "record-bytes" else 2) == "", "Changed proof emitted selectors")
        finally:
            path.write_bytes(original)
            os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        controls.append(label)
    OBS.run([sys.executable, str(Path(__file__).resolve()), "--candidate", str(binary), "--output", str(output), "--mcp-worker"],
            ROOT, output, "mcp-worker", 360, 8 * 1024 * 1024)
    executed = OBS.run(["xcodebuild", "test-without-building", "-xctestrun", receipt["testRunPath"],
                       "-destination", receipt["destination"], *selectors], project, output, "selected-test-run", 300,
                      16 * 1024 * 1024).decode(errors="replace")
    execution = executed_tests(executed)
    # Build the package for Other while only Checks belongs to TestAction. Lack of a
    # CoreKit join must refuse the receipt; it must never turn the package into 'outside'.
    negative_project = output / "other-only-project"
    shutil.copytree(ROOT / "Fixtures/XcodeLocalPackageScope", negative_project)
    negative_logs = output / "other-only-mutation"
    negative_logs.mkdir()
    OBS.prepare_variant(negative_project, negative_logs, negative=True)
    negative = argparse.Namespace(**vars(args))
    negative.project, negative.output = str(negative_project), str(output / "other-only-capture")
    try:
        SCOPE.capture(negative)
        raise RuntimeError("Compiled package without selected consumer was accepted")
    except ValueError as error:
        require("selected universe" in str(error), "Unexpected negative capture failure: " + str(error))
        SCOPE.save(output / "other-only-refusal.json", {"reason": str(error), "compiled": True,
            "limitation": "Other is built/indexed but is outside this TestAction; absence is not package completeness proof."})
    SCOPE.save(output / "results.json", {"status": "passed", "selectors": selectors, "selectionGranularity": "whole-target",
        **execution, "negativeControls": controls + ["same-session-record-rehash", "compiled-for-other-only"],
        "receiptSHA256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(), "recordCount": len(package["records"]),
        "proofFileCount": len(package["files"]), "proofBytesByKind": {kind: sum(v["bytes"] for v in package["files"].values() if v["kind"] == kind)
            for kind in ("document", "object", "record")}, "captureSecondsIncludingPreparation": metadata["secondsIncludingPreparation"],
        "totalSecondsIncludingControls": time.monotonic() - started,
        "limitation": "Finite public single-project macOS library fixture; no private workspace or test-omission guarantee."})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mcp-worker", action="store_true")
    args = parser.parse_args()
    if args.mcp_worker:
        mcp_worker(args.candidate.resolve(), args.output.resolve())
    else:
        verify(args.candidate.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
