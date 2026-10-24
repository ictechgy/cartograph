#!/usr/bin/env python3
"""Real finite-package capture/CLI/MCP/selected-test checks on the public Xcode fixture."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
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


def fixture_method_selection(document, selectors):
    """Require the exact observed compiler method and its blueprint selector before executing it."""
    require(isinstance(document, dict), "Fixture affected document is malformed")
    scope = document.get("targetScope")
    require(isinstance(scope, dict) and scope.get("evidenceStatus") == "matched-capture",
            "Fixture method selection lacks matched capture evidence")
    xcode = scope.get("xcode")
    require(isinstance(xcode, dict) and xcode.get("selectionStatus") == "review-candidates"
            and xcode.get("selectorTargetByModule") == {
                "ChecksModule": "ChecksBlueprint", "OtherModule": "OtherBlueprint"},
            "Fixture method selection has unknown or different module-to-blueprint mapping")
    tests = document.get("tests")
    require(isinstance(tests, list) and len(tests) == 1 and isinstance(tests[0], dict),
            "Fixture method selection must contain exactly one test")
    # AffectedDocument는 빈 uncertain 목록을 optional nil로 생략한다. null/다른 형식은 허용하지 않는다.
    require(document.get("uncertainTestCandidates", []) == [], "Fixture method selection contains uncertain tests")
    expected = {"usr": "c:@M@ChecksModule@objc(cs)ChangedTests(im)testChanged", "name": "testChanged()",
                "qualifiedName": "ChecksModule.testChanged()", "module": "ChecksModule", "kind": "method"}
    symbol = tests[0].get("symbol")
    require(isinstance(symbol, dict) and all(symbol.get(key) == value for key, value in expected.items()),
            "Fixture selected compiler method identity differs")
    require(tests[0].get("xcodebuildIdentifier") == "ChecksModule/ChangedTests/testChanged",
            "Fixture selected test identifier differs")
    require(selectors == ["-only-testing:ChecksBlueprint/ChangedTests/testChanged"],
            "Fixture selector is not the exact observed test method")
    return "method"


def generated_metadata(directory):
    """Read only the public fixture's generated metadata, never certify membership."""
    require(not directory.is_symlink() and directory.resolve() == directory,
            "Generated metadata root is not canonical")
    if not directory.exists():
        return {"exists": False, "entries": [], "totalBytes": 0}
    require(directory.is_dir(), "Generated metadata root is not a directory")
    result, pending, count, total = [], [(directory, 0)], 0, 0
    while pending:
        parent, depth = pending.pop()
        require(depth <= 8, "Generated metadata depth budget exceeded")
        children = []
        with os.scandir(parent) as scan:
            for entry in scan:
                count += 1
                require(count <= 128, "Generated metadata entry budget exceeded")
                children.append(Path(entry.path))
        for path in sorted(children):
            relative = path.relative_to(directory).as_posix()
            require(len(relative) <= 256 and not path.is_symlink() and path.resolve() == path
                    and path.resolve().is_relative_to(directory), "Generated metadata path boundary exceeded")
            if path.is_dir():
                result.append({"path": relative, "type": "directory"})
                pending.append((path, depth + 1))
                continue
            require(path.is_file(), "Generated metadata nonregular entry")
            with path.open("rb") as stream:
                data = stream.read(8 * 1024 + 1)
            total += len(data)
            require(len(data) <= 8 * 1024 and total <= 32 * 1024, "Generated metadata byte budget exceeded")
            row = {"path": relative, "type": "file", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            if path.suffix in (".xcworkspacedata", ".xcsettings", ".plist", ".json", ".xcscheme"):
                try:
                    row["utf8Metadata"] = data.decode("utf-8")
                except UnicodeDecodeError:
                    row["contentStatus"] = "not-utf8; hash-only"
            else:
                row["contentStatus"] = "unrecognized metadata extension; hash-only"
            result.append(row)
    return {"exists": True, "entries": sorted(result, key=lambda x: x["path"]), "totalBytes": total}


def record_generated_metadata(project, output, phase):
    report = {"phase": phase, "scope": "public synthetic Packages/LocalMath/.swiftpm only",
              "limitation": "Diagnostic only; unsupported inputs still refuse product receipts",
              "processLogsPresent": {name: (output / "capture" / (name + ".stdout")).is_file()
                                     for name in ("build-for-testing", "snapshot", "package-fresh-snapshot")}}
    try:
        report.update(generated_metadata(project / "Packages/LocalMath/.swiftpm"))
        report["status"] = "observed"
    except Exception as error:
        report.update(status="diagnostic-refused", reason=type(error).__name__ + ": " + str(error))
    try:
        SCOPE.save(output / ("generated-metadata-" + phase + ".json"), report)
    except Exception as error:
        report["persistenceError"] = type(error).__name__
    # ASCII JSON keeps control characters inert; only bounded public fixture metadata.
    try:
        print("GENERATED_METADATA " + json.dumps(report, ensure_ascii=True, sort_keys=True), flush=True)
    except OSError:
        pass  # Diagnostic output must not replace the original capture failure.
    return report


def emit_bounded_observation(prefix, report):
    """Bound the ASCII JSON payload; the fixed prefix is additional diagnostic text."""
    encoded = json.dumps(report, ensure_ascii=True, sort_keys=True)
    if len(encoded) > 64 * 1024:
        report = {"status": "diagnostic-output-budget-exceeded", "bytes": len(encoded),
                  "sha256": hashlib.sha256(encoded.encode("ascii")).hexdigest(),
                  "limitation": "Read the captured fixture artifacts; the product gate is unchanged."}
        encoded = json.dumps(report, ensure_ascii=True, sort_keys=True)
    try:
        print(prefix + " " + encoded, flush=True)
    except OSError:
        pass  # The original product assertion must remain the failure.
    return report


def record_scope_observation(document, receipt):
    """Expose bounded public-fixture refusal reasons without changing any product gate."""
    report = {"status": "observed", "targetScope": document.get("targetScope"),
              "limitations": document.get("limitations"),
              "receipt": {key: receipt.get(key) for key in ("version", "inputFingerprint", "selectedTargetIDs")},
              "limitation": "Public synthetic fixture diagnostic only; capture success does not certify selector safety."}
    return emit_bounded_observation("SCOPE_OBSERVATION", report)


def record_selector_observation(document, selectors):
    """Expose actual fixture selectors and test identities; never change their acceptance gate."""
    report = {"status": "observed", "limitation": "Public fixture diagnostic only; selector expectations are unchanged."}
    try:
        require(isinstance(selectors, list) and len(selectors) <= 1000
                and all(isinstance(value, str) and len(value) <= 4096 for value in selectors),
                "Selector diagnostic argument budget/schema exceeded")
        mapping = document.get("targetScope", {}).get("xcode", {}).get("selectorTargetByModule", {})
        require(isinstance(mapping, dict) and all(isinstance(key, str) and isinstance(value, str)
                for key, value in mapping.items()), "Selector diagnostic mapping is malformed")
        report["arguments"] = selectors
        for key in ("tests", "uncertainTestCandidates"):
            rows = document.get(key) or []
            require(isinstance(rows, list) and len(rows) <= 1000, "Selector diagnostic test budget exceeded")
            observed = []
            for row in rows:
                require(isinstance(row, dict) and isinstance(row.get("symbol"), dict),
                        "Selector diagnostic test identity is malformed")
                symbol = {name: row["symbol"].get(name) for name in ("usr", "name", "qualifiedName", "module", "kind")}
                identifier = row.get("xcodebuildIdentifier")
                require(all(value is None or (isinstance(value, str) and len(value) <= 4096)
                            for value in [*symbol.values(), identifier]), "Selector diagnostic identity field is malformed")
                observed.append({"symbol": symbol, "blueprint": mapping.get(symbol["module"]),
                                 "xcodebuildIdentifier": identifier})
            report[key] = observed
    except Exception as error:
        report = {"status": "diagnostic-refused", "reason": type(error).__name__ + ": " + str(error),
                  "limitation": "Original selector assertion remains authoritative."}
    return emit_bounded_observation("SELECTOR_OBSERVATION", report)


def test_run_targets(value):
    configurations = value.get("TestConfigurations")
    if configurations is not None:
        require(isinstance(configurations, list) and len(configurations) == 1,
                "Fixture observation requires one test-run configuration")
        rows = configurations[0].get("TestTargets")
    else:
        rows = [row for key, row in value.items() if not key.startswith("__") and isinstance(row, dict)]
    require(isinstance(rows, list) and len(rows) <= 1000 and all(isinstance(row, dict) for row in rows),
            "Fixture test-run target observation budget/schema exceeded")
    return rows


def record_test_run_observation(receipt):
    """Show actual dependency identities, not receipt product membership as a substitute."""
    report = {"status": "observed", "limitation": "Public fixture observation only; no dependency admission implied."}
    try:
        data = SCOPE.bounded(Path(receipt["testRunPath"]), 8 * 1024 * 1024)
        rows = test_run_targets(plistlib.loads(data))
        for row in rows:
            require(all(isinstance(row.get(key), str) for key in ("BlueprintName", "TestBundlePath")),
                    "Fixture test-run identity fields are not strings")
            paths = row.get("DependentProductPaths")
            require(paths is None or (isinstance(paths, list) and len(paths) <= 1000
                    and all(isinstance(path, str) for path in paths)),
                    "Fixture test-run dependency fields are not bounded string paths")
        report.update(testRunSHA256=hashlib.sha256(data).hexdigest(),
                      capturedTestRunSHA256=receipt["testRunSHA256"],
                      aggregateOutput=receipt["localPackage"]["aggregate"]["output"],
                      testTargets=[{key: row.get(key) for key in
                          ("BlueprintName", "TestBundlePath", "DependentProductPaths")} for row in rows])
    except Exception as error:
        report.update(status="diagnostic-refused", reason=type(error).__name__ + ": " + str(error))
    return emit_bounded_observation("TEST_RUN_OBSERVATION", report)


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
        require(before["result"]["targetScope"]["xcode"]["generatedMetadataOrigin"] == "capture-created",
                "Native MCP lost the producer's metadata origin observation")
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


def affected_process(supervisor, argv, cwd, stem, expected):
    """예상된 CLI 거부만 새 감독 receipt로 확인하고 감독 실패는 계속 거부한다."""
    paths = {name: Path(str(stem) + "." + name) for name in ("json", "stdout", "stderr")}
    require(all(not path.exists() and not path.is_symlink() for path in paths.values()),
            "Affected process evidence already exists")
    returned = None
    try:
        returned = supervisor.run(argv, cwd, stem, 120, stream_limit=4 * 1024 * 1024)
    except RuntimeError:
        # 공유 supervisor는 정상적으로 reap한 nonzero도 receipt 저장 후 throw한다.
        # 성공 호출의 실패는 재분류하지 않고, 아래에서 예상 거부의 전체 신원을 확인한다.
        if expected == 0:
            raise
    try:
        require(all(path.is_file() and not path.is_symlink() for path in paths.values()),
                "Affected process evidence is missing or redirected")
        raw_receipt = SCOPE.bounded(paths["json"], 64 * 1024)
        process = json.loads(raw_receipt)
        require(isinstance(process, dict), "Affected process receipt is malformed")
        code = process.get("returncode")
        expected_code = type(code) is int and (code > 0 if expected is None else code == expected)
        require(expected_code and type(process.get("raw_returncode")) is int and process["raw_returncode"] == code
                and process.get("command") == argv and process.get("cwd") == str(cwd)
                and type(process.get("pid")) is int and process["pid"] > 0
                and process.get("timed_out") is False and process.get("owned_root_reaped") is True
                and process.get("ownership_lost") is False and process.get("cleanup_errors") == []
                and process.get("output_limit_exceeded") is None and "exception_type" not in process
                and process.get("stream_limit_bytes") == 4 * 1024 * 1024,
                "Unexpected affected process outcome: " + stem.name)
        require(returned is None or returned == process, "Returned affected process receipt differs")
        counts = process.get("retained_stream_bytes")
        require(type(counts) is dict and set(counts) == {"stdout", "stderr"}, "Affected stream counts are missing")
        streams = {}
        for name in ("stdout", "stderr"):
            require(process.get(name) == str(paths[name]) and type(counts[name]) is int
                    and 0 <= counts[name] <= 4 * 1024 * 1024, "Affected stream identity differs")
            data = SCOPE.bounded(paths[name], 4 * 1024 * 1024)
            require(len(data) == counts[name], "Affected stream bytes differ")
            streams[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        emit_bounded_observation("AFFECTED_PROCESS_OBSERVATION", {
            "status": "validated-process-outcome", "process": stem.name, "returncode": code,
            "receiptSHA256": hashlib.sha256(raw_receipt).hexdigest(), "streams": streams,
            "argvSHA256": hashlib.sha256(json.dumps(argv, ensure_ascii=True).encode()).hexdigest(),
            "cwdSHA256": hashlib.sha256(str(cwd).encode()).hexdigest(),
            "limitation": "Process outcome only; each product assertion remains mandatory."})
        return process
    except Exception:
        OBS.record_process_failure(stem)
        raise


def verify(binary, output):
    output.mkdir(parents=True, exist_ok=False)
    project = output / "project"
    shutil.copytree(ROOT / "Fixtures/XcodeLocalPackageScope", project)
    started = time.monotonic()
    args = argparse.Namespace(project=str(project), xcode_project="Scope.xcodeproj", scheme="Scope",
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
    record_generated_metadata(project, output, "before-capture")
    try:
        receipt_path = SCOPE.capture(args)
    except Exception:
        record_generated_metadata(project, output, "after-capture-failure")
        for path in sorted((output / "capture").glob("*.stderr"), key=lambda p: p.stat().st_mtime)[-3:]:
            print(path.name + ":\n" + path.read_bytes()[-4096:].decode(errors="replace"), flush=True)
        raise
    record_generated_metadata(project, output, "after-capture-success")
    receipt = json.loads(receipt_path.read_text())
    metadata = json.loads((output / "capture/capture.json").read_text())
    require(receipt["version"] == 2 and receipt["localPackage"]["product"] == "ArithmeticProduct"
            and receipt["localPackage"]["module"] == "ArithmeticCore", "Package/product identities were lost")
    package = receipt["localPackage"]
    dependencies = record_test_run_observation(receipt)
    try:
        SCOPE.save(output / "test-run-observation.json", dependencies)
    except OSError:
        pass  # Diagnostic persistence must not replace the original product assertion.
    require(package["generatedMetadataOrigin"] == "capture-created"
            and {p: value for p, value in package["inventory"].items()
                 if p == ".swiftpm" or p.startswith(".swiftpm/")} == {
                     ".swiftpm": "directory", ".swiftpm/xcode": "directory"},
            "Fresh fixture did not capture exactly the observed empty metadata directory pair")
    supervisor = OBS.process_supervisor()
    def invoke(label, format="json", expected=0, captured_receipt=receipt_path,
               project_root=project, index_store=metadata["indexStore"]):
        common = ["--project", str(project_root), "--index-store", index_store, "--target-scope", str(captured_receipt)]
        argv = [str(binary), "affected", "packageValue", *common, "--format", format]
        affected_process(supervisor, argv, project_root, output / label, expected)
        raw = SCOPE.bounded(output / (label + ".stdout"), 4 * 1024 * 1024)
        return json.loads(raw) if format == "json" and raw else raw.decode()
    document = invoke("candidate-json")
    scope = document["targetScope"]
    record_scope_observation(document, receipt)
    require(scope["evidenceStatus"] == "matched-capture" and scope["xcode"]["selectionStatus"] == "review-candidates",
            "Actual package record and linker proof did not produce review candidates")
    require(scope["xcode"]["generatedMetadataOrigin"] == "capture-created",
            "CLI scope lost the producer's metadata origin observation")
    require(scope["xcode"]["selectorTargetByModule"] == {"ChecksModule": "ChecksBlueprint", "OtherModule": "OtherBlueprint"}
            and scope["xcode"]["testBundleByModule"] == {"ChecksModule": "RunnableChecks.xctest", "OtherModule": "OtherRunnable.xctest"},
            "Blueprint, compiler module and bundle identities were conflated")
    product_root = str(Path(receipt["testRunPath"]).parent)
    require(dependencies["status"] == "observed" and {row["BlueprintName"] for row in dependencies["testTargets"]}
            == {"ChecksBlueprint", "OtherBlueprint"} and {
        path.replace("__TESTROOT__", product_root) for row in dependencies["testTargets"]
        for path in (row.get("DependentProductPaths") or [])} == {
            product_root + "/Debug/" + name for name in ("CoreKit.framework", "RunnableChecks.xctest", "OtherRunnable.xctest")},
        "Actual xctestrun does not match both selected native test targets and their closure products")
    selectors = invoke("candidate-selectors", "xcodebuild").splitlines()
    record_selector_observation(document, selectors)
    selection_granularity = fixture_method_selection(document, selectors)
    controls = []
    # Rehash the edited artifact in the receipt so product freshness alone cannot
    # explain rejection: only selected native/package dependency proof may admit it.
    test_run_path = Path(receipt["testRunPath"])
    test_run_bytes, test_run_stamp = test_run_path.read_bytes(), test_run_path.stat()
    receipt_bytes = receipt_path.read_bytes()
    unrelated = test_run_path.parent / "Debug/FixtureUnrelatedDependency.o"
    require(not unrelated.exists(), "Negative-control product already exists")
    for label in ("dependency-path-substitution", "dependency-captured-unrelated"):
        changed = json.loads(receipt_bytes)
        value = plistlib.loads(test_run_bytes)
        target = test_run_targets(value)[0]
        if label == "dependency-path-substitution":
            dependency = product_root + "/Debug/../Debug/CoreKit.framework"
        else:
            dependency = str(unrelated)
            unrelated.write_bytes(b"captured bytes without selected package contribution\n")
            changed["products"][dependency] = hashlib.sha256(unrelated.read_bytes()).hexdigest()
        try:
            target["DependentProductPaths"] = target["DependentProductPaths"] + [dependency]
            new_bytes = plistlib.dumps(value)
            test_run_path.write_bytes(new_bytes)
            os.utime(test_run_path, ns=(test_run_stamp.st_atime_ns, test_run_stamp.st_mtime_ns))
            digest = hashlib.sha256(new_bytes).hexdigest()
            changed["testRunSHA256"] = digest
            changed["products"][str(test_run_path)] = digest
            SCOPE.save(receipt_path, changed)
            document = invoke(label + "-json")
            require(document["targetScope"]["evidenceStatus"] == "unknown"
                    and "Test-run dependency products are outside the verified target closure." in json.dumps(document),
                    "Negative dependency failed for a different reason")
            require(invoke(label, "xcodebuild", 2) == "", "Unproved dependency emitted selectors")
        finally:
            test_run_path.write_bytes(test_run_bytes)
            os.utime(test_run_path, ns=(test_run_stamp.st_atime_ns, test_run_stamp.st_mtime_ns))
            receipt_path.write_bytes(receipt_bytes)
            if label == "dependency-captured-unrelated":
                unrelated.unlink()
        controls.append(label)
    for label, path, append in [
        ("source-bytes", project / "Packages/LocalMath/Sources/ArithmeticCore/Math.swift", b"\n// changed\n"),
        ("manifest-bytes", project / "Packages/LocalMath/Package.swift", b"\n// changed\n"),
        ("unexpected-clang", project / "Packages/LocalMath/Sources/ArithmeticCore/Hidden.cpp", b"int hidden;\n"),
        ("unexpected-resource", project / "Packages/LocalMath/blob.bin", b"resource"),
        ("metadata-file-added", project / "Packages/LocalMath/.swiftpm/xcode/hidden.json", b"{}")]:
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
    metadata_directory = project / "Packages/LocalMath/.swiftpm/xcode"
    metadata_directory.rmdir()
    try:
        require(invoke("metadata-directory-removed", "xcodebuild", 2) == "", "Missing metadata directory emitted selectors")
    finally:
        metadata_directory.mkdir()
    controls.append("metadata-directory-removed")
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
    # Real prior failure: ChecksOnly builds Other, so Xcode lists OtherRunnable in
    # DependentProductPaths although it is outside TestAction. Keep this refusal.
    outside_project = output / "outside-test-action-project"
    shutil.copytree(ROOT / "Fixtures/XcodeLocalPackageScope", outside_project)
    outside = argparse.Namespace(**vars(args))
    outside.project, outside.output, outside.scheme = str(outside_project), str(output / "outside-test-action-capture"), "ChecksOnly"
    outside_receipt_path = SCOPE.capture(outside)
    outside_receipt = json.loads(outside_receipt_path.read_text())
    outside_metadata = json.loads((Path(outside.output) / "capture.json").read_text())
    outside_observation = record_test_run_observation(outside_receipt)
    require(outside_observation["status"] == "observed"
            and {row["BlueprintName"] for row in outside_observation["testTargets"]} == {"ChecksBlueprint"}
            and any("__TESTROOT__/Debug/OtherRunnable.xctest" in (row.get("DependentProductPaths") or [])
                    for row in outside_observation["testTargets"]), "Prior outside-TestAction dependency was not reproduced")
    outside_arguments = {"captured_receipt": outside_receipt_path, "project_root": outside_project,
                         "index_store": outside_metadata["indexStore"]}
    outside_document = invoke("outside-test-action-json", **outside_arguments)
    require(outside_document["targetScope"]["evidenceStatus"] == "unknown"
            and "Test-run dependency products are outside the verified target closure." in json.dumps(outside_document),
            "Outside-TestAction product did not retain the exact refusal")
    require(invoke("outside-test-action-selectors", "xcodebuild", 2, **outside_arguments) == "",
            "Outside-TestAction product emitted selectors")
    controls.append("built-product-outside-test-action")
    # Build the package for Other while only Checks belongs to TestAction. Lack of a
    # CoreKit join must refuse the receipt; it must never turn the package into 'outside'.
    negative_project = output / "other-only-project"
    shutil.copytree(ROOT / "Fixtures/XcodeLocalPackageScope", negative_project)
    negative_logs = output / "other-only-mutation"
    negative_logs.mkdir()
    OBS.prepare_variant(negative_project, negative_logs, negative=True)
    negative = argparse.Namespace(**vars(args))
    negative.project, negative.output, negative.scheme = str(negative_project), str(output / "other-only-capture"), "ChecksOnly"
    try:
        SCOPE.capture(negative)
        raise RuntimeError("Compiled package without selected consumer was accepted")
    except ValueError as error:
        require("selected universe" in str(error), "Unexpected negative capture failure: " + str(error))
        SCOPE.save(output / "other-only-refusal.json", {"reason": str(error), "compiled": True,
            "limitation": "Other is built/indexed but is outside this TestAction; absence is not package completeness proof."})
    SCOPE.save(output / "results.json", {"status": "passed", "selectors": selectors, "selectionGranularity": selection_granularity,
        **execution, "negativeControls": controls + ["same-session-record-rehash", "compiled-for-other-only"],
        "scheme": args.scheme, "testUniverse": ["ChecksBlueprint", "OtherBlueprint"],
        "observedTestRun": dependencies,
        "generatedMetadataOrigin": package["generatedMetadataOrigin"],
        "originLimitation": "Unsigned producer observation; not independently authenticated historical provenance.",
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
