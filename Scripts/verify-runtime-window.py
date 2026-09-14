#!/usr/bin/env python3
"""Verify sealed observation intervals separately from application exit success."""

import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import uuid


def native_wire_probe(repo, output):
    source = (repo / "Sources/cartograph/RuntimeCollectorSource.swift").read_text()
    source = source.split('static let source = #"""', 1)[1].rsplit('"""#', 1)[0]
    directory = output / "wire"
    directory.mkdir(mode=0o700)
    (directory / "Collector.m").write_text("\n".join(
        line[4:] if line.startswith("    ") else line for line in source.splitlines()))
    (directory / "Probe.m").write_text('''#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <unistd.h>
@interface SwappingTarget : NSObject
- (NSString *)first;
- (NSString *)second;
@end
@implementation SwappingTarget
- (NSString *)first {
    method_exchangeImplementations(class_getInstanceMethod([SwappingTarget class], @selector(first)),
                                   class_getInstanceMethod([SwappingTarget class], @selector(second)));
    return @"first";
}
- (NSString *)second { return @"second"; }
@end
int main(void) { @autoreleasepool {
    SwappingTarget *target = [SwappingTarget new];
    NSString *actual = [target performSelector:NSSelectorFromString(@"first")];
    if (![actual isEqualToString:@"first"]) return 8;
    for (int i = 0; i < 500; i++) {
        (void)NSSelectorFromString(@"cartographWindowTick");
        usleep(10000);
    }
    return 0;
} }
''')
    for arguments in [
        ["-O2", "-fno-objc-arc", "-dynamiclib", str(directory / "Collector.m"),
         "-framework", "Foundation", "-o", str(directory / "Collector.dylib")],
        [str(directory / "Probe.m"), "-framework", "Foundation", "-o", str(directory / "Probe")],
    ]:
        subprocess.run(["xcrun", "clang"] + arguments, check=True, capture_output=True, timeout=60)
    nonce = uuid.uuid4().hex
    environment = os.environ.copy()
    environment.update(
        DYLD_INSERT_LIBRARIES=str(directory / "Collector.dylib"),
        CARTOGRAPH_RUNTIME_TRACE_FILE=str(directory / "events.jsonl"),
        CARTOGRAPH_RUNTIME_TRACE_STATUS=str(directory / "status.bin"),
        CARTOGRAPH_RUNTIME_TRACE_SEAL_REQUEST=str(directory / "request.bin"),
        CARTOGRAPH_RUNTIME_TRACE_SEAL_ACK=str(directory / "ack.bin"),
        CARTOGRAPH_RUNTIME_TRACE_SEAL_NONCE=nonce,
    )
    app = subprocess.Popen([str(directory / "Probe")], env=environment)
    try:
        deadline = time.monotonic() + 3
        while not (directory / "status.bin").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        time.sleep(0.2)

        def request(token, pid, mode=0o600):
            data = struct.pack("<8sIi32sQ", b"CTREQ001", 1, pid, token.encode(), 100)
            staging = directory / "request-staging.bin"
            descriptor = os.open(staging, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            try:
                assert os.write(descriptor, data) == len(data)
                os.fchmod(descriptor, mode)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            assert not (directory / "request.bin").exists()
            staging.rename(directory / "request.bin")

        for token, pid in [("0" * 32, app.pid), (nonce, app.pid + 1)]:
            request(token, pid)
            time.sleep(0.15)
            assert not (directory / "ack.bin").exists(), "A foreign checkpoint request was accepted"
            (directory / "request.bin").unlink()
        request(nonce, app.pid, mode=0o644)
        time.sleep(0.15)
        assert not (directory / "ack.bin").exists(), "A public checkpoint request was accepted"
        (directory / "request.bin").unlink()
        valid_request = directory / "request-target.bin"
        valid_request.write_bytes(struct.pack("<8sIi32sQ", b"CTREQ001", 1, app.pid, nonce.encode(), 100))
        os.chmod(valid_request, 0o600)
        (directory / "request.bin").symlink_to(valid_request)
        time.sleep(0.15)
        assert not (directory / "ack.bin").exists(), "A symlink checkpoint request was followed"
        (directory / "request.bin").unlink()
        request(nonce, app.pid)
        deadline = time.monotonic() + 2
        while not (directory / "ack.bin").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        ack = struct.unpack("<8sIi32sQQQIIQ", (directory / "ack.bin").read_bytes())
        assert ack[:4] == (b"CTSEAL01", 1, app.pid, nonce.encode())
        before = (directory / "events.jsonl").read_bytes()
        events = [json.loads(line) for line in before.splitlines()]
        assert len(events) == ack[4] and ack[5:9] == (0, 0, 127, 1) and ack[9] >= 100_000_000
        assert any(event.get("name") == "cartographWindowTick" for event in events)
        swaps = [event for event in events if event.get("name") == "first"
                 and event["phase"] == "invocation-returned"]
        assert len(swaps) == 1 and swaps[0].get("dispatchUncertain"), swaps
        assert "calleeSymbol" not in swaps[0], "Post-call replacement was mistaken for the executed implementation"
        time.sleep(0.4)
        assert app.poll() is None
        assert (directory / "events.jsonl").read_bytes() == before, "Late events crossed the seal boundary"
        return {"events": len(events), "foreignNonceRejected": True, "foreignPIDRejected": True,
                "publicRequestRejected": True, "symlinkRequestRejected": True,
                "changedDispatchNotMisattributed": True,
                "lateEventsExcludedWhileRunning": True}
    finally:
        if app.poll() is None:
            app.terminate()
        app.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    repo = Path(__file__).resolve().parents[1]
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-window-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "project"
    shutil.copytree(repo / "Fixtures/RuntimeWindowCorpus", project, ignore=shutil.ignore_patterns(".build"))
    result = {"status": "failed"}

    def run(command, label, expected=0):
        process = subprocess.run(command, capture_output=True, text=True, timeout=180)
        (output / f"{label}.stdout.log").write_text(process.stdout)
        (output / f"{label}.stderr.log").write_text(process.stderr)
        if process.returncode != expected:
            raise RuntimeError(f"{label}: expected {expected}, got {process.returncode}; see {output}")
        return process

    try:
        scratch = output / "build"
        build = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch)]
        run(build, "build")
        bin_path = Path(run(build + ["--show-bin-path"], "bin-path").stdout.strip())
        store = next(path for path in [scratch / "out", scratch / "index/store", bin_path / "index/store"]
                     if (path / "v5/units").is_dir() or (path / "units").is_dir())
        executable = bin_path / "RuntimeWindowProbe"
        common = [str(binary), "runtime", "collect", "--project", str(project), "--index-store", str(store),
                  "--executable", str(executable), "--duration", "0.25", "--timeout", "5"]
        for label, arguments, expected in [
            ("window", [], 0), ("early-exit", ["--exit-early"], 2), ("oversized-name", ["--oversized-name"], 2),
        ]:
            destination = output / f"{label}.json"
            process = run(common + ["--output", str(destination), "--"] + arguments, label, expected)
            assert not process.stdout
            document = json.loads(destination.read_text())
            assert document["version"] == 2 and not document["collectionComplete"]
            assert document["evidenceComplete"] == (expected == 0)
            assert document["observationWindow"]["complete"] == (expected == 0)
            if expected == 0:
                assert "result:early" in process.stderr
                assert "processExitCode" not in document
                assert document["observationWindow"]["processOutcome"] == "stoppedAfterSeal"
                pid = document["launch"]["processID"]
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("Collected application remained alive after cleanup")
                assert any(e.get("name") == "early" and e["phase"] == "invocation-returned"
                           for e in document["events"])
                assert not any(e.get("name") == "late" for e in document["events"])
        discovery = json.loads(run([
            str(binary), "runtime", "discover", "--project", str(project), "--index-store", str(store),
            "--executable", str(executable), "--trace", str(output / "window.json"),
        ], "discover").stdout)
        observed = discovery["observed"]
        assert observed["status"] != "partial"
        relationships = {(e["source"]["name"], e["target"]["name"], e["kind"]) for e in observed["connections"]}
        assert ("collectEarly(_:)", "early()", "selectorInvocation") in relationships, relationships
        assert any("scenario success" in item for item in observed["limitations"])
        result.update(status="passed", observedConnections=observed["connectionCount"],
                      wire=native_wire_probe(repo, output),
                      cases=["sealed-window", "scenario-success-not-claimed", "early-exit", "oversized-name",
                             "exact-compiler-identity", "stopped-after-seal"])
    finally:
        (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
