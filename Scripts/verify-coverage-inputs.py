#!/usr/bin/env python3
"""Verify coverage reuse rejection with isolated files and stubbed tool boundaries, not measured coverage."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    repository = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="cartograph-coverage-inputs-") as temporary:
        root = Path(temporary)
        scripts = root / "Scripts"
        scripts.mkdir()
        shutil.copyfile(repository / "Scripts/coverage.sh", scripts / "coverage.sh")
        sources = root / "Sources"
        sources.mkdir()
        source = sources / "Probe.swift"
        source.write_text("func probe() {}\n")
        tests = root / "Tests"
        tests.mkdir()
        test = tests / "ProbeTests.swift"
        test.write_text("// isolated freshness input\n")
        fixtures = root / "Fixtures/Probe"
        fixtures.mkdir(parents=True)
        fixture = fixtures / "truth.json"
        fixture.write_text("{}\n")
        ignored = fixtures / ".build"
        ignored.mkdir()
        artifact = ignored / "output.o"
        artifact.write_text("ignored build artifact\n")
        skills = root / "Skills"
        skills.mkdir()
        skill = skills / "SKILL.md"
        skill.write_text("fixture skill\n")
        (root / ".gitignore").write_text(".build/\n")
        subprocess.run(["git", "-c", "init.templateDir=", "init", "--quiet", str(root)], check=True)
        product = root / "products"
        cov = product / "codecov"
        cov.mkdir(parents=True)
        unit = cov / "default.profdata"
        merged = cov / "with-integration.profdata"
        unit.write_text("unit stub")
        merged.write_text("merged stub")
        bundle = product / "Probe.xctest/Contents/MacOS"
        bundle.mkdir(parents=True)
        executable = bundle / "Probe"
        executable.write_text("test binary stub")
        cli = product / "cartograph"
        cli.write_text("#!/bin/sh\nexit 0\n")
        cli.chmod(0o755)
        tools = root / "tools"
        tools.mkdir()
        swift = tools / "swift"
        swift.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
arguments = sys.argv[1:]
if arguments == ["test", "--show-codecov-path"]:
    print(os.environ["TEST_CODECOV_PATH"])
    raise SystemExit(0)
with Path(os.environ["TEST_SWIFT_TRACE"]).open("a") as trace:
    trace.write(json.dumps(arguments) + "\\n")
if arguments != ["test", "--enable-code-coverage", "--no-parallel"]:
    raise SystemExit(91)
status = int(os.environ.get("TEST_SWIFT_EXIT", "0"))
if status:
    raise SystemExit(status)
Path(os.environ["TEST_CODECOV_PATH"]).with_name("default.profdata").write_text("fresh unit stub")
''')
        swift.chmod(0o755)
        xcrun = tools / "xcrun"
        xcrun.write_text('''#!/bin/sh
[ "$1 $2" = "llvm-cov export" ] || exit 92
printf 'export\\n' >> "$TEST_EXPORT_TRACE"
cat "$TEST_EXPORT_PATH"
''')
        xcrun.chmod(0o755)
        export = root / "export.json"
        export.write_text(json.dumps({"data": [{"files": [{
            "filename": str(source), "summary": {"lines": {"covered": 1, "count": 1, "percent": 100}},
        }]}]}))
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                           TEST_CODECOV_PATH=str(cov / "package.json"), TEST_EXPORT_PATH=str(export),
                           TEST_SWIFT_TRACE=str(root / "swift-test.jsonl"),
                           TEST_EXPORT_TRACE=str(root / "exports.txt"))
        base = time.time() - 120

        def stamp(path, offset):
            os.utime(path, (base + offset, base + offset))

        def reset():
            stamp(root / ".gitignore", 0)
            for directory in [sources, tests, scripts, root / "Fixtures", skills]:
                for path in [directory, *directory.rglob("*")]:
                    stamp(path, 0)
            stamp(executable, 10)
            stamp(cli, 10)
            stamp(unit, 20)
            stamp(merged, 30)

        cases = [
            ("current combined", False, None, 0),
            ("current unit", True, None, 0),
            ("new source", False, source, 2),
            ("new test", False, test, 2),
            ("new harness", False, scripts / "coverage.sh", 2),
            ("new fixture", False, fixture, 2),
            ("new skill", True, skill, 2),
            ("ignored fixture build", False, artifact, 0),
            ("new test binary", False, executable, 2),
            ("new CLI binary", False, cli, 2),
            ("new unit profile", False, unit, 2),
            ("new source directory", False, sources, 2),
            ("new source for unit", True, source, 2),
            ("new binary for unit", True, executable, 2),
        ]
        failures = []
        for name, unit_only, changed, expected in cases:
            reset()
            if changed:
                stamp(changed, 40)
            args = ["bash", str(scripts / "coverage.sh"), "--skip-test"]
            if unit_only:
                args.append("--unit-only")
            process = subprocess.run(args, env=environment, capture_output=True, text=True, timeout=30)
            if process.returncode != expected:
                failures.append({"case": name, "expected": expected, "actual": process.returncode,
                                 "stderr": process.stderr})
        for name, expected in [("fresh complete serial run", 0), ("failed test cannot export old profiles", 73)]:
            unit.write_text("old unit stub")
            merged.write_text("old merged stub")
            reset()
            Path(environment["TEST_SWIFT_TRACE"]).write_text("")
            Path(environment["TEST_EXPORT_TRACE"]).write_text("")
            selected_environment = dict(environment, TEST_SWIFT_EXIT=str(expected))
            if expected == 0:
                unit.unlink()
            process = subprocess.run(["bash", str(scripts / "coverage.sh"), "--unit-only"],
                                     env=selected_environment, capture_output=True, text=True, timeout=30)
            calls = [json.loads(line) for line in Path(environment["TEST_SWIFT_TRACE"]).read_text().splitlines()]
            exports = Path(environment["TEST_EXPORT_TRACE"]).read_text().splitlines()
            if (process.returncode != expected
                    or calls != [["test", "--enable-code-coverage", "--no-parallel"]]
                    or bool(exports) != (expected == 0)):
                failures.append({"case": name, "expected": expected, "actual": process.returncode,
                                 "testCalls": calls, "exports": exports, "stderr": process.stderr})
        print(json.dumps({"cases": len(cases) + 2, "failures": failures,
                          "status": "failed" if failures else "passed"}, indent=2))
        return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
