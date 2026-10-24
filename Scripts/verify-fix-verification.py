#!/usr/bin/env python3
"""Exercise the actual CLI against compiler indexes and a dirty Git worktree."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time


def run(argv, cwd, *, expected=0, timeout=180):
    result = subprocess.run(list(map(str, argv)), cwd=cwd, capture_output=True, timeout=timeout)
    if result.returncode != expected:
        raise AssertionError((argv, result.returncode, result.stdout[-5000:], result.stderr[-5000:]))
    return result


def git(root, *argv):
    return run(["git", "--no-optional-locks", "-c", "core.hooksPath=/dev/null", "-C", root, *argv], root).stdout


def write(root, name, source):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="cartograph-fix-proof-"))
    if args.output:
        output.mkdir(parents=True, exist_ok=False)
    root = output / "project"
    root.mkdir()
    binary = args.cartograph.resolve()
    write(root, "Package.swift", '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FixVerificationFixture", targets: [
    .target(name: "Lib"), .target(name: "Unused"),
    .target(name: "Mid", dependencies: ["Lib", "Unused"]),
    .executableTarget(name: "App", dependencies: ["Mid"])
])
''')
    write(root, "Sources/Lib/Lib.swift", "public extension Int { static let magic = 42 }\n")
    write(root, "Sources/Unused/Unused.swift", "public struct Unused {}\n")
    original = b'''import Lib
import Unused
public func midValue() -> Int { .magic }
#if VERIFY_SHOULD_FAIL
#error("Intentional verifier-only build failure")
#endif
'''
    source = root / "Sources/Mid/Mid.swift"
    source.parent.mkdir(parents=True)
    source.write_bytes(original)
    write(root, "Sources/App/main.swift", "import Mid\nprint(midValue())\n")
    write(root, ".gitignore", ".build/\nignored.txt\n")
    git(root, "init", "-q")
    git(root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "add", ".")
    git(root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
    source.write_bytes(original + b"// staged user's content\n")
    git(root, "add", "Sources/Mid/Mid.swift")
    dirty = source.read_bytes() + b"// unstaged user's content\n"
    source.write_bytes(dirty)
    write(root, "untracked.txt", "user's untracked data\n")
    write(root, "ignored.txt", "user's ignored data\n")
    index_bytes = (root / ".git/index").read_bytes()
    status = git(root, "status", "--porcelain=v1", "-z")
    swift = ["swift", "build", *shlex.split(os.environ.get("SWIFTPM_FLAGS", ""))]
    records = []

    def reset():
        source.write_bytes(dirty)
        result = run(swift, root)
        (output / "last-fixture-build.log").write_bytes(result.stdout + result.stderr)
        assert (root / ".git/index").read_bytes() == index_bytes

    def command(label, verifier, expected=2, extra=()):
        recovery = output / (label + "-recovery")
        argv = [str(binary), "fix", "--apply", "--format", "json", "--project", str(root),
                "--verify-command", json.dumps(verifier), "--recovery-directory", str(recovery), *extra]
        result = run(argv, root, expected=expected)
        (output / (label + ".stdout.json")).write_bytes(result.stdout)
        (output / (label + ".stderr")).write_bytes(result.stderr)
        document = json.loads(result.stdout)
        assert document["editCount"] == 1 and document["edits"][0]["rule"] == "unused-import", document
        assert document["verification"]["recoveryDirectory"] == str(recovery)
        assert (root / ".git/index").read_bytes() == index_bytes, "Git index changed"
        assert (root / "untracked.txt").read_text() == "user's untracked data\n"
        assert (root / "ignored.txt").read_text() == "user's ignored data\n"
        records.append({"case": label, "exit": result.returncode, "verification": document["verification"]})
        return document

    reset()
    plan = json.loads(run([binary, "fix", "--format", "json", "--project", root], root).stdout)
    assert plan["editCount"] == 1 and "verification" not in plan
    assert source.read_bytes() == dirty
    assert git(root, "status", "--porcelain=v1", "-z") == status
    records.append({"case": "default-dry-run", "editCount": plan["editCount"], "sourceAndIndexUnchanged": True})

    write(output, "not-a-directory", "preserve existing evidence\n")
    setup = run([binary, "fix", "--apply", "--format", "json", "--project", root,
                 "--verify-command", '["/usr/bin/true"]',
                 "--recovery-directory", output / "not-a-directory/child"], root, expected=2)
    assert b"no source files changed" in setup.stderr and source.read_bytes() == dirty
    assert (root / ".git/index").read_bytes() == index_bytes
    records.append({"case": "recovery-setup-io-failure", "exit": 2, "sourceAndIndexUnchanged": True})

    success = command("build-passed", swift, expected=0)
    assert success["verification"]["status"] == "passed" and success["applied"]
    assert b"import Lib" in source.read_bytes() and b"import Unused" not in source.read_bytes()

    reset()
    failed = command("build-failed", swift + ["-Xswiftc", "-DVERIFY_SHOULD_FAIL"])
    assert failed["verification"]["status"] == "failed" and failed["verification"]["rollback"] == "restored"
    assert source.read_bytes() == dirty and not failed["applied"]
    assert git(root, "status", "--porcelain=v1", "-z") == status

    reset()
    timed = command("timeout", [sys.executable, "-c", "import time; time.sleep(20)"], extra=["--verify-timeout", "0.1"])
    assert timed["verification"]["status"] == "timed-out" and source.read_bytes() == dirty

    for number in [signal.SIGINT, signal.SIGTERM]:
        reset()
        label = "signal-" + str(number)
        recovery = output / (label + "-recovery")
        ready = output / (label + "-ready")
        verifier = [sys.executable, "-c", f"from pathlib import Path; import time; Path({str(ready)!r}).write_text('ready'); time.sleep(20)"]
        argv = [binary, "fix", "--apply", "--format", "json", "--project", root,
                "--verify-command", json.dumps(verifier), "--recovery-directory", recovery]
        with (output / (label + ".stdout.json")).open("wb") as stdout, (output / (label + ".stderr")).open("wb") as stderr:
            process = subprocess.Popen(list(map(str, argv)), cwd=root, stdout=stdout, stderr=stderr)
            deadline = time.monotonic() + 60
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            assert ready.exists(), "Verifier did not start"
            process.send_signal(number)  # 이 하네스가 시작한 CLI 하나에만 보낸다.
            assert process.wait(timeout=10) == 2
        document = json.loads((output / (label + ".stdout.json")).read_bytes())
        assert document["verification"]["status"] == "interrupted", document
        assert document["verification"]["signal"] == number
        assert document["verification"]["rollback"] == "restored" and source.read_bytes() == dirty
        assert (root / ".git/index").read_bytes() == index_bytes
        records.append({"case": label, "exit": 2, "verification": document["verification"]})

    reset()
    conflict_text = "// another editor's change\n"
    conflict = command("conflict", [sys.executable, "-c",
        f"from pathlib import Path; Path('Sources/Mid/Mid.swift').write_text({conflict_text!r}); raise SystemExit(9)"])
    assert conflict["verification"]["rollback"] == "conflict"
    assert source.read_text() == conflict_text
    backup = output / "conflict-recovery/original-0"
    assert backup.read_bytes() == dirty

    reset()
    missing = command("restore-failed", [sys.executable, "-c",
        "from pathlib import Path; Path('Sources/Mid/Mid.swift').unlink(); raise SystemExit(9)"])
    assert missing["verification"]["rollback"] == "restore-failed" and not source.exists()
    assert (output / "restore-failed-recovery/original-0").read_bytes() == dirty
    source.write_bytes(dirty)
    assert (root / ".git/index").read_bytes() == index_bytes
    assert git(root, "status", "--porcelain=v1", "-z") == status

    evidence = {"fixture": "public extension Int.magic + unused import; staged/unstaged/untracked/ignored data",
                "originalSourceSHA256": hashlib.sha256(dirty).hexdigest(),
                "indexSHA256": hashlib.sha256(index_bytes).hexdigest(), "cases": records}
    (output / "verification.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"passedCases": len(records), "evidence": str(output / "verification.json")}, sort_keys=True))


if __name__ == "__main__":
    main()
