#!/usr/bin/env python3
"""Verify runtime collection against a real UIKit app on an explicitly selected test simulator."""

import argparse
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--simulator", required=True, help="Booted dedicated test simulator UUID")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-simulator-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "project"
    project.mkdir()
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/RuntimeSimulatorCorpus"
    shutil.copy2(corpus / "Probe.swift", project / "Probe.swift")
    store = output / "index"
    app = output / "CartographSimulatorProbe.app"
    app.mkdir()
    executable = app / "CartographSimulatorProbe"
    bundle = "dev.cartograph.simulator-corpus." + uuid.uuid4().hex
    result = {"status": "failed", "simulator": args.simulator}

    def run(command, label, expected=0, timeout=120):
        process = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        (output / f"{label}.stdout.log").write_text(process.stdout)
        (output / f"{label}.stderr.log").write_text(process.stderr)
        if process.returncode != expected:
            raise RuntimeError(f"{label}: expected exit {expected}, got {process.returncode}; see {output}")
        return process

    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], "sdk").stdout.strip()
    run([
        "xcrun", "swiftc", "-sdk", sdk, "-target", f"{platform.machine()}-apple-ios17.0-simulator",
        "-Onone", "-g", "-parse-as-library", "-module-name", "SimulatorProbe",
        "-index-store-path", str(store), str(project / "Probe.swift"), "-o", str(executable),
    ], "build")
    info = {
        "CFBundleIdentifier": bundle, "CFBundleExecutable": executable.name,
        "CFBundleName": "Cartograph Simulator Probe", "CFBundlePackageType": "APPL",
        "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
        "UIDeviceFamily": [1, 2], "LSRequiresIPhoneOS": True, "UILaunchScreen": {},
        "UIApplicationSceneManifest": {
            "UIApplicationSupportsMultipleScenes": False,
            "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{
                "UISceneConfigurationName": "Default Configuration",
                "UISceneDelegateClassName": "CartographSimulatorScene",
            }]},
        },
    }
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    run(["xcrun", "simctl", "install", args.simulator, str(app)], "install")
    common = [
        str(args.cartograph.resolve()), "runtime", "collect", "--project", str(project),
        "--index-store", str(store), "--executable", str(executable), "--simulator", args.simulator,
        "--bundle-id", bundle,
    ]

    def collect(label, application_args=(), expected=0, timeout=15, duration=None):
        destination = output / f"{label}.json"
        window = [] if duration is None else ["--duration", str(duration)]
        process = run(common + window + ["--timeout", str(timeout), "--output", str(destination), "--"]
                      + list(application_args), label, expected)
        assert not process.stdout, "Application output leaked into cartograph stdout"
        return json.loads(destination.read_text()), process

    try:
        baseline = run(["xcrun", "simctl", "launch", "--console", args.simulator, bundle], "baseline")
        assert "probe-result:called" in baseline.stdout
        complete, process = collect("complete")
        assert complete["collectorActive"] and complete["collectionComplete"], complete["limitations"]
        assert complete["processExitCode"] == 0 and complete["droppedEvents"] == 0
        assert complete["launch"]["platform"] == "iOSSimulator"
        assert complete["launch"]["simulatorID"] == args.simulator
        assert complete["launch"]["bundleID"] == bundle and complete["launch"]["processID"] > 0
        assert "probe-result:called" in process.stderr
        calls = [event for event in complete["events"]
                 if event["phase"] == "invocation-returned" and event.get("name") == "work"]
        assert calls and calls[0]["receiverClass"] == "CartographSimulatorTarget", calls
        assert calls[0].get("calleeSymbol", "").endswith("To"), calls
        discovery = run([
            str(args.cartograph.resolve()), "runtime", "discover", "--project", str(project),
            "--index-store", str(store), "--trace", str(output / "complete.json"),
            "--executable", str(executable), "--limit", "10000",
        ], "discover")
        document = json.loads(discovery.stdout)
        observed = document["observed"]
        assert observed["status"] != "partial", observed
        relationships = {(edge["source"]["name"], edge["target"]["name"], edge["kind"])
                         for edge in observed["connections"]}
        assert ("exerciseRuntime()", "RuntimeTarget", "classLookup") in relationships, relationships
        assert ("exerciseRuntime()", "work()", "selectorInvocation") in relationships, relationships
        window, _ = collect("window", ["--wait", "--ignore-term"], duration=4)
        assert window["version"] == 2 and window["evidenceComplete"]
        assert not window["collectionComplete"] and "processExitCode" not in window
        assert window["observationWindow"]["complete"]
        assert window["observationWindow"]["processOutcome"] == "stoppedAfterSeal"
        assert any(event.get("name") == "work" and event["phase"] == "invocation-returned"
                   for event in window["events"])
        window_discovery = json.loads(run([
            str(args.cartograph.resolve()), "runtime", "discover", "--project", str(project),
            "--index-store", str(store), "--trace", str(output / "window.json"),
            "--executable", str(executable), "--limit", "10000",
        ], "window-discover").stdout)
        assert window_discovery["observed"]["status"] != "partial"
        assert any(edge["source"]["name"] == "exerciseRuntime()" and edge["target"]["name"] == "work()"
                   for edge in window_discovery["observed"]["connections"])
        early, _ = collect("window-early-exit", ["--exit-before-scenario"], duration=2, expected=2)
        assert early["version"] == 2 and not early["evidenceComplete"] and not early["collectionComplete"]
        for label, app_args in [
            ("failure", ["--fail"]), ("crash", ["--crash"]),
            ("immediate-exit", ["--immediate-exit"]), ("timeout", ["--wait", "--ignore-term"]),
        ]:
            partial, _ = collect(label, app_args, expected=2, timeout=4 if label == "timeout" else 15)
            assert not partial["collectionComplete"], label
            assert partial["collectorActive"], label
            if label == "failure":
                assert partial["processExitCode"] == 7, partial
            if label in ["crash", "immediate-exit"]:
                assert "processExitCode" not in partial, partial
            processes = run(["xcrun", "simctl", "spawn", args.simulator, "launchctl", "list"], label + "-processes")
            for line in processes.stdout.splitlines():
                fields = line.split()
                assert not (len(fields) >= 3 and fields[0].isdigit()
                            and fields[2].startswith(f"UIKitApplication:{bundle}[")), line
        run(["xcrun", "simctl", "launch", args.simulator, bundle, "--wait"], "start-running")
        refused = run(common + ["--output", str(output / "already-running.json")], "already-running", expected=2)
        assert "already running" in refused.stderr
        run(["xcrun", "simctl", "terminate", args.simulator, bundle], "stop-running")
        original = executable.read_bytes()
        try:
            executable.write_bytes(original + b"mismatch")
            mismatch = run(common + ["--output", str(output / "mismatch.json")], "mismatch", expected=2)
            assert "differs from --executable" in mismatch.stderr
        finally:
            executable.write_bytes(original)
        result.update(status="passed", eventCount=len(complete["events"]),
                      exactConnectionCount=observed["connectionCount"],
                      requiredRelationshipsVerified=["exerciseRuntime() -> RuntimeTarget (classLookup)",
                                                     "exerciseRuntime() -> work() (selectorInvocation)"],
                      cases=["return-preserved", "exact-identities", "exit7", "crash", "immediate-exit",
                             "timeout", "already-running", "installed-binary-mismatch",
                             "sealed-observation-window", "early-exit-before-seal"])
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", args.simulator, bundle], capture_output=True)
        uninstall = subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle], capture_output=True)
        if uninstall.returncode != 0:
            result["cleanupError"] = "Could not uninstall the uniquely named test app"
            result["status"] = "failed"
        (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if result["status"] != "passed":
        raise RuntimeError(f"Simulator verification or fixture cleanup failed; see {output}")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
