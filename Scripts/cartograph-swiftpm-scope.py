#!/usr/bin/env python3
"""Capture bounded SwiftPM source membership for affected --target-scope.

This explicitly builds the selected local package. Only use it on a package you
trust to build. The receipt is a producer claim, not a signature or Xcode scheme
proof. Raw commands, output, timings and the snapshot remain in a new directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import time


class CaptureError(RuntimeError):
    pass


def inventory(root: Path) -> dict[str, str]:
    result, pending, entries, total = {}, [root], 0, 0
    while pending:
        directory = pending.pop()
        for path in sorted(directory.iterdir()):
            entries += 1
            if entries > 50_000:
                raise CaptureError("Inventory entry budget exceeded")
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode) and path.name in (".build", ".git"):
                continue
            if stat.S_ISLNK(mode):
                raise CaptureError(f"Symlinked inventory is unsupported: {path}")
            if stat.S_ISDIR(mode):
                pending.append(path)
                continue
            if path.suffix not in (".swift", ".m", ".mm", ".h", ".xib", ".storyboard") and path.name != "Package.resolved":
                continue
            if not stat.S_ISREG(mode):
                raise CaptureError(f"Nonregular input: {path}")
            with path.open("rb") as source:
                data = source.read(4 * 1024 * 1024 + 1)
            total += len(data)
            if len(data) > 4 * 1024 * 1024 or total > 64 * 1024 * 1024 or len(result) >= 10_000:
                raise CaptureError("Source inventory budget exceeded")
            result[path.relative_to(root).as_posix()] = hashlib.sha256(data).hexdigest()
    return result


def save(path: Path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(argv, root: Path, output: Path, name: str, timeout: int, maximum=8 * 1024 * 1024):
    started = time.monotonic()
    stdout, stderr = output / (name + ".stdout"), output / (name + ".stderr")
    receipt = {"argv": argv, "cwd": str(root), "timeoutSeconds": timeout, "cleanupErrors": []}
    with stdout.open("xb") as out, stderr.open("xb") as err:
        process = subprocess.Popen(argv, cwd=root, stdout=out, stderr=err, start_new_session=os.name == "posix")
        try:
            receipt["exitCode"] = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            receipt["timedOut"] = True
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired) as error:
                receipt["cleanupErrors"].append(str(error))
        finally:
            receipt["seconds"] = time.monotonic() - started
            save(output / (name + ".process.json"), receipt)
    if receipt.get("exitCode") != 0:
        raise CaptureError(f"{name} failed or timed out; inspect {output / (name + '.process.json')}")
    with stdout.open("rb") as source:
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise CaptureError(f"{name} output exceeds {maximum} bytes; retained for review")
    return data


def capture(args):
    root, binary, output = Path(args.project).resolve(), Path(args.cartograph).resolve(), Path(args.output).resolve()
    if output.is_relative_to(root):
        raise CaptureError("Use a new output directory outside the package root")
    if not 1 <= args.timeout <= 3600 or not 1 <= len(args.test_target) <= 1000:
        raise CaptureError("Timeout must be 1...3600 seconds and 1...1000 explicit test targets are required")
    if output.exists():
        raise CaptureError("Output directory already exists; choose a new path to retain old evidence")
    output.mkdir(parents=True)
    started = time.monotonic()
    before = inventory(root)
    description_bytes = run(["swift", "package", "describe", "--type", "json"], root, output, "describe-before", args.timeout)
    description = json.loads(description_bytes)
    if description.get("dependencies") != []:
        raise CaptureError("External package dependencies are unsupported; membership remains unknown")
    run(["swift", "build", "--build-tests", "--enable-index-store", "--jobs", "2"], root, output, "build", args.timeout)
    bin_path = run(["swift", "build", "--show-bin-path"], root, output, "bin-path", args.timeout).decode().strip()
    explicit_store = getattr(args, "index_store", None)
    candidates = [Path(explicit_store).resolve()] if explicit_store else [root / ".build/out", Path(bin_path).resolve() / "index/store"]
    stores = sorted({path.resolve() for path in candidates
                     if (path / "v5/units").is_dir() or (path / "units").is_dir()})
    if len(stores) != 1:
        raise CaptureError("Expected one actual compiler index with units; select the intended build using --index-store")
    store = stores[0]
    if not store.is_relative_to(root / ".build"):
        raise CaptureError("The captured SwiftPM index must be inside this package's .build directory")
    command = [str(binary), "snapshot", "--project", str(root), "--index-store", str(store)]
    if args.config:
        command += ["--config", str(Path(args.config).resolve())]
    snapshot = json.loads(run(command, root, output, "snapshot", args.timeout, 128 * 1024 * 1024))
    after_description = run(["swift", "package", "describe", "--type", "json"], root, output, "describe-after", args.timeout)
    after = inventory(root)
    if before != after or json.loads(after_description) != description:
        raise CaptureError("Package inputs changed during describe/build/capture. Review generated source or Package.resolved, then recapture")
    fingerprint = snapshot.get("inputFingerprint")
    if not isinstance(fingerprint, str) or len(fingerprint) != 64:
        raise CaptureError("Snapshot did not contain a bound input fingerprint")
    receipt = {"format": "cartograph-swiftpm-target-scope", "version": 1,
               "projectRoot": str(root), "inputFingerprint": fingerprint,
               "descriptionJSON": description_bytes.decode(), "selectedTargets": args.test_target,
               "descriptionSHA256": hashlib.sha256(description_bytes).hexdigest(),
               "before": before, "after": after, "buildExitCode": 0}
    encoded = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()
    if len(encoded) > 8 * 1024 * 1024:
        raise CaptureError("Receipt exceeds its 8 MiB bound")
    (output / "target-scope.json").write_bytes(encoded)
    save(output / "capture.json", {"indexStore": str(store), "secondsIncludingPreparation": time.monotonic() - started,
        "snapshotSHA256": hashlib.sha256((output / "snapshot.stdout").read_bytes()).hexdigest(),
        "receipt": str(output / "target-scope.json"), "schemeIdentity": "unverified",
        "limitation": "Captured source membership only; resource contents and build environment are not a current "
                      "completeness proof. Not test coverage, scheme selection or permission to omit tests"})
    return output / "target-scope.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--cartograph", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--test-target", action="append", required=True)
    parser.add_argument("--config")
    parser.add_argument("--index-store", help="Disambiguate an actual compiler index inside the package .build directory")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    try:
        print(capture(args))
    except (CaptureError, OSError, ValueError) as error:
        parser.exit(2, str(error) + "\n")


if __name__ == "__main__":
    main()
