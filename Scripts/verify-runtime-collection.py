#!/usr/bin/env python3
"""Verify automatic Objective-C runtime collection with a real debug executable."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-runtime-collection-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "project"
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/RuntimeCollectionCorpus"
    shutil.copytree(corpus, project, ignore=shutil.ignore_patterns(".build"))
    scratch = output / "build"

    def run(command, name, expected=0, **kwargs):
        process = subprocess.run(command, cwd=project, capture_output=True, text=True, timeout=180, **kwargs)
        (output / (name + ".stdout.log")).write_text(process.stdout)
        (output / (name + ".stderr.log")).write_text(process.stderr)
        if process.returncode != expected:
            raise RuntimeError(f"{name}: expected exit {expected}, got {process.returncode}; see {output}")
        return process

    build_args = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch)]
    run(build_args, "build")
    bin_path = Path(run(build_args + ["--show-bin-path"], "bin-path").stdout.strip())
    stores = [scratch / "out", scratch / "index/store", bin_path / "index/store"]
    index_store = next((candidate for candidate in stores if candidate.is_dir()), None)
    if index_store is None:
        raise RuntimeError(f"No compiler index in {scratch}")
    executable = bin_path / "RuntimeCollectionProbe"

    baseline = subprocess.run(
        [str(executable), "forwarded-token"],
        cwd=project,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
    )
    (output / "baseline.combined.log").write_text(baseline.stdout)
    if baseline.returncode != 0:
        raise RuntimeError(f"baseline app failed with {baseline.returncode}; see {output}")

    common = [
        str(binary), "runtime", "collect",
        "--project", str(project), "--index-store", str(index_store),
        "--executable", str(executable), "--timeout", "10",
    ]

    def collect(name, app_args, expected=0, executable_path=None, timeout=None):
        destination = output / (name + ".json")
        command = list(common)
        if executable_path is not None:
            position = command.index("--executable") + 1
            command[position] = str(executable_path)
        if timeout is not None:
            position = command.index("--timeout") + 1
            command[position] = str(timeout)
        command += ["--output", str(destination), "--"] + app_args
        process = run(command, name, expected=expected)
        if process.stdout:
            raise AssertionError(f"{name}: child output contaminated cartograph stdout: {process.stdout!r}")
        return json.loads(destination.read_text()), process.stderr

    def wait_until_ready(process, path, name):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and process.poll() is None:
            if path.is_file():
                return
            time.sleep(0.02)
        raise RuntimeError(f"{name}: application did not reach the mutation checkpoint; see {output}")

    traced, traced_output = collect("complete", ["forwarded-token"])
    written_line = f"Wrote {output / 'complete.json'}\n"
    if traced_output.replace(written_line, "") != baseline.stdout:
        raise AssertionError(f"application output changed under collection; see {output}")
    assert traced["format"] == "runtime-trace" and traced["version"] == 1, traced
    assert traced["collectorActive"] and traced["collectionComplete"], traced
    assert traced["processExitCode"] == 0 and traced["droppedEvents"] == 0, traced
    events = traced["events"]

    def matching(api, phase, name):
        return [event for event in events
                if event["api"] == api and event["phase"] == phase and event.get("name") == name]

    missing_class = matching("NSClassFromString", "lookup", "CartographDefinitelyMissingClass")
    missing_protocol = matching("NSProtocolFromString", "lookup", "CartographDefinitelyMissingProtocol")
    missing_selector = matching(
        "NSSelectorFromString", "lookup", "cartographDefinitelyMissingSelector:"
    )
    assert missing_class and missing_class[0]["result"] is False, missing_class
    assert missing_protocol and missing_protocol[0]["result"] is False, missing_protocol
    assert missing_selector and missing_selector[0]["result"] is True, missing_selector
    assert matching("NSObject.performSelector", "invocation-returned", "description"), events
    one_argument = matching("NSObject.performSelector:withObject", "invocation-returned", "handle:")
    two_arguments = matching(
        "NSObject.performSelector:withObject:withObject", "invocation-returned", "handle:second:"
    )
    assert one_argument and two_arguments, events
    class_events = matching("NSObject.performSelector", "invocation-returned", "classGreeting")
    assert class_events and class_events[0]["receiverIsClass"] is True, class_events
    void_events = matching("NSObject.performSelector", "invocation-returned", "markVoid")
    primitive_events = matching("NSObject.performSelector", "invocation-returned", "primitiveValue")
    assert void_events and primitive_events, events
    registrations = matching("NotificationCenter.addObserver", "registration", "receive:")
    assert registrations and registrations[0]["receiverIsClass"] is False, registrations
    app_path = executable.resolve()
    local_callees = one_argument + two_arguments + class_events + void_events + primitive_events + registrations
    assert all(event.get("calleeSymbol", "").endswith("To") for event in local_callees), local_callees
    assert all(Path(event["calleeImage"]).resolve() == app_path for event in local_callees), local_callees
    assert not any(event.get("name") == "CartographChildOnlyMissingClass" for event in events), events
    assert all(Path(event["callerImage"]).resolve() == app_path
               for event in events if event.get("callerImage")), events
    assert any(event.get("callerSymbol") for event in events), events

    discovered = run([
        str(binary), "runtime", "discover",
        "--project", str(project), "--index-store", str(index_store),
        "--trace", str(output / "complete.json"), "--executable", str(executable),
        "--limit", "100",
    ], "discover-with-trace")
    comparison = json.loads(discovered.stdout)
    assert comparison["format"] == "runtime-discovery-comparison", comparison
    assert comparison["observed"]["eventCount"] == len(events), comparison
    assert comparison["observed"]["connectionCount"] >= 6, comparison
    observed_targets = {connection["target"]["name"]
                        for connection in comparison["observed"]["connections"]}
    assert {"handle(_:)", "handle(_:second:)", "classGreeting()", "markVoid()",
            "primitiveValue()", "receive(_:)"}.issubset(observed_targets), observed_targets

    shell = output / "not-a-mach-o.sh"
    shell.write_text("#!/bin/sh\nprintf 'shell-ran\\n'\n")
    shell.chmod(0o700)
    partial, _ = collect("collector-partial", [], expected=2, executable_path=shell)
    assert not partial["collectionComplete"], partial
    assert partial["processExitCode"] == 0 and partial["events"] == [], partial
    # 실행 환경에 따라 셸 인터프리터에도 수집기가 로드될 수 있다.
    expected_limitation = ("did not record a normal process shutdown" if partial["collectorActive"]
                           else "did not become active")
    assert any(expected_limitation in item for item in partial["limitations"]), partial
    partial_discovery = run([
        str(binary), "runtime", "discover",
        "--project", str(project), "--index-store", str(index_store),
        "--trace", str(output / "collector-partial.json"), "--executable", str(shell),
        "--limit", "100",
    ], "discover-partial-trace", expected=2)
    partial_comparison = json.loads(partial_discovery.stdout)
    assert partial_comparison["observed"]["status"] == "partial", partial_comparison
    assert partial_comparison["observed"]["connectionCount"] == 0, partial_comparison

    failed, _ = collect("application-failed", ["fail"], expected=2)
    assert failed["collectorActive"] and not failed["collectionComplete"], failed
    assert failed["processExitCode"] == 7 and failed["events"], failed

    timed_out, _ = collect("application-timeout", ["timeout"], expected=2, timeout=0.1)
    assert not timed_out["collectionComplete"], timed_out
    assert any("timeout" in item for item in timed_out["limitations"]), timed_out

    mutable_executable = output / "RuntimeCollectionProbe-mutating"
    shutil.copy2(executable, mutable_executable)
    executable_changed_path = output / "executable-changed.json"
    executable_ready = output / "executable-changed.ready"
    executable_changed_command = list(common)
    executable_changed_command[executable_changed_command.index("--executable") + 1] = str(mutable_executable)
    executable_changed_command += [
        "--output", str(executable_changed_path), "--", "pause", str(executable_ready),
    ]
    executable_changed_process = subprocess.Popen(
        executable_changed_command,
        cwd=project,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    wait_until_ready(executable_changed_process, executable_ready, "executable-changed")
    with mutable_executable.open("ab") as changed_binary:
        changed_binary.write(b"\0")
    changed_stdout, changed_stderr = executable_changed_process.communicate(timeout=30)
    (output / "executable-changed.stdout.log").write_text(changed_stdout)
    (output / "executable-changed.stderr.log").write_text(changed_stderr)
    if executable_changed_process.returncode != 2:
        raise RuntimeError(
            f"executable-changed: expected exit 2, got {executable_changed_process.returncode}; see {output}"
        )
    executable_changed = json.loads(executable_changed_path.read_text())
    assert not executable_changed["collectionComplete"] and executable_changed["events"], executable_changed
    assert any("executable changed" in item.lower()
               for item in executable_changed["limitations"]), executable_changed

    changed_path = output / "inputs-changed.json"
    input_ready = output / "inputs-changed.ready"
    changed_command = list(common) + [
        "--output", str(changed_path), "--", "pause", str(input_ready),
    ]
    changed_process = subprocess.Popen(
        changed_command,
        cwd=project,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    wait_until_ready(changed_process, input_ready, "inputs-changed")
    source = project / "Sources/RuntimeCollectionProbe/main.swift"
    source.write_text(source.read_text() + "\n// changed while runtime collection was active\n")
    changed_stdout, changed_stderr = changed_process.communicate(timeout=30)
    (output / "inputs-changed.stdout.log").write_text(changed_stdout)
    (output / "inputs-changed.stderr.log").write_text(changed_stderr)
    if changed_process.returncode != 2:
        raise RuntimeError(f"inputs-changed: expected exit 2, got {changed_process.returncode}; see {output}")
    changed = json.loads(changed_path.read_text())
    assert not changed["collectionComplete"] and changed["events"], changed
    assert any("inputs changed" in item for item in changed["limitations"]), changed

    result = {
        "status": "passed",
        "events": len(events),
        "failedClassLookups": len(missing_class),
        "failedProtocolLookups": len(missing_protocol),
        "observedConnections": comparison["observed"]["connectionCount"],
        "partialCollectorActive": partial["collectorActive"],
        "partialCollectionExit": 2,
        "partialDiscoveryExit": 2,
        "applicationFailureExit": 2,
        "timeoutExit": 2,
        "executableChangeExit": 2,
        "inputChangeExit": 2,
    }
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    print(f"Evidence: {output}")


if __name__ == "__main__":
    main()
