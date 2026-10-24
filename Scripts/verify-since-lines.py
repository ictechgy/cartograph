#!/usr/bin/env python3
"""Verify dead --since-lines with real Git changes, compiler indexes and CLI exits."""

import argparse
import errno
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-since-lines-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "project"
    project.mkdir()  # 기존 프로젝트를 덮어쓰지 않는다.
    sources = project / "Sources"
    sources.mkdir()
    build = project / ".build"
    build.mkdir()
    environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_TERMINAL_PROMPT="0")
    (output / "tmp").mkdir()
    environment["TMPDIR"] = str(output / "tmp") + "/"
    result = {"status": "failed", "output": str(output), "skipped": []}

    def run(command, label, expected=0, cwd=project):
        process = subprocess.run([str(value) for value in command], cwd=cwd, env=environment,
                                 capture_output=True, text=True, timeout=240)
        (output / f"{label}.stdout.log").write_text(process.stdout)
        (output / f"{label}.stderr.log").write_text(process.stderr)
        if process.returncode != expected:
            raise AssertionError(f"{label}: expected exit {expected}, got {process.returncode}; see {output}")
        return process.stdout

    def git(*arguments):
        return run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                    "-c", "commit.gpgsign=false", *arguments], "git").strip()

    def write(name, text):
        (sources / name).write_text(text)

    def compile_sources(label):
        run(["xcrun", "swiftc", "-module-name", "SinceLines", "-index-store-path", build / "index",
             *sorted(sources.glob("*.swift")), "-o", build / "fixture"], label)

    def report(label, *extra, expected=1, cwd=project, project_path=project):
        raw = run([binary, "dead", "--project", project_path, "--index-store", build / "index",
                   "--report-format", "json", "--strict", *extra], label, expected, cwd)
        diagnostics = json.loads(raw)["diagnostics"]
        return sorted(re.search(r"'([^']+)'", item["message"]).group(1).removeprefix("SinceLines.").removesuffix("()")
                      for item in diagnostics if item["ruleIdentifier"] == "unused-symbol")

    try:
        git("init", "-q")
        git("config", "user.name", "Cartograph CLI fixture")
        git("config", "user.email", "fixture@example.invalid")
        (project / ".gitignore").write_text(".build/\n")
        (project / ".gitattributes").write_text(
            "Sources/Binary.swift -diff\nSources/Code.swift filter=sentinel diff=sentinel\n")
        write("main.swift", 'print("entry")\n')
        original = ('func untouchedDead() {}\nfunc editedDead() {}\nfunc bodyOnlyDead() {\n'
                    '    print("before")\n}\nfunc shiftedDead() {}\n')
        write("Code.swift", original)
        write("Old.swift", "func renamedDead() {}\n")
        write("Deleted.swift", "func deletedDead() {}\n")
        write("Deletion.swift", "// remove this line\nfunc survivingDead() {}\n")
        write("Binary.swift", "func binaryDead() {}\n")
        write("Mode.swift", "func modeDead() {}\n")
        odd = "space [*]\t한글\n.swift"
        write(odd, "func oddDead() {}\n")
        git("add", "-A")
        git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        write("Code.swift", original.replace("editedDead() {}", 'editedDead() { print("committed") }'))
        git("add", "Sources/Code.swift")
        git("commit", "-qm", "committed change")
        committed = (sources / "Code.swift").read_text()
        write("Code.swift", committed + "func stagedDead() {}\n")
        git("add", "Sources/Code.swift")
        current = (sources / "Code.swift").read_text()
        write("Code.swift", "func unstagedDead() {}\n" + current.replace('print("before")', 'print("after")'))
        git("mv", "Sources/Old.swift", "Sources/Renamed.swift")
        (sources / "Deleted.swift").unlink()
        write("Deletion.swift", "func survivingDead() {}\n")
        write("Binary.swift", 'func binaryDead() { print("binary diff") }\n')
        (sources / "Mode.swift").chmod(0o755)
        write(odd, 'func oddDead() { print("odd path") }\n')
        write("New.swift", "func untrackedDead() {}\n")
        compile_sources("compile-current")

        # 설정이 있는 상태에서만 분석한다. 준비용 git add/commit 이 marker 를 실행하지 않는다.
        marker = output / "unexpected-driver"
        driver = output / "driver.sh"
        driver.write_text("#!/bin/sh\nprintf ran >> " + shlex.quote(str(marker)) + "\n")
        driver.chmod(0o755)
        for key in ["diff.external", "diff.sentinel.textconv", "filter.sentinel.clean",
                    "filter.sentinel.smudge", "filter.sentinel.process", "core.fsmonitor"]:
            git("config", key, str(driver))
        git("config", "filter.sentinel.required", "true")
        git("config", "diff.relative", "true")
        git("config", "diff.noprefix", "true")
        git("config", "diff.interHunkContext", "100")
        environment["GIT_DIFF_OPTS"] = "-U100"
        hooks = output / "hooks"
        hooks.mkdir()
        (hooks / "post-index-change").write_text(driver.read_text())
        (hooks / "post-index-change").chmod(0o755)
        git("config", "core.hooksPath", str(hooks))
        expected_lines = sorted(["editedDead", "stagedDead", "unstagedDead", "renamedDead", "binaryDead",
                                 "modeDead", "oddDead", "untrackedDead"])
        expected_files = sorted(expected_lines + ["untouchedDead", "bodyOnlyDead", "shiftedDead", "survivingDead"])
        assert report("file-default", "--since", base) == expected_files
        assert report("changed-lines", "--since", base, "--since-lines") == expected_lines
        assert report("subdirectory", "--since", base, "--since-lines", cwd=sources) == expected_lines
        alias = output / "project-alias"
        alias.symlink_to(project, target_is_directory=True)
        assert report("symlink-root", "--since", base, "--since-lines", project_path=alias) == expected_lines
        assert report("head-lines", "--since", "HEAD", "--since-lines") == sorted(
            set(expected_lines) - {"editedDead"})
        assert "whole-file fallback" in (output / "changed-lines.stderr.log").read_text()
        assert not marker.exists(), "repository-defined driver or hook executed"
        # 본문만 바꾸면 선언 위치는 줄 범위 밖이다. strict 는 파일 모드 1, 줄 모드 0 이어야 한다.
        for path in sources.glob("*.swift"):
            if path.name != "main.swift":
                path.unlink()
        write("Only.swift", 'func outsideChange() {\n    print("before")\n}\n')
        # 다음 기준 커밋을 만들기 전에 fixture 에서만 만든 드라이버 설정을 걷어 낸다.
        for key in ["diff.external", "diff.sentinel.textconv", "filter.sentinel.clean",
                    "filter.sentinel.smudge", "filter.sentinel.process", "core.fsmonitor", "filter.sentinel.required"]:
            git("config", "--unset", key)
        git("add", "-A")
        git("commit", "-qm", "body-only base")
        write("Only.swift", 'func outsideChange() {\n    print("after")\n}\n')
        # 없어진 소스의 옛 유닛이 남아 진단을 오염시키지 않게 독립 스토어를 다시 만든다.
        shutil.rmtree(build / "index")
        compile_sources("compile-body-only")
        assert report("body-file", "--since", "HEAD") == ["outsideChange"]
        assert report("body-line", "--since", "HEAD", "--since-lines", expected=0) == []
        run([binary, "dead", "--since-lines"], "missing-since", 64)
        run([binary, "dead", "--project", project, "--since=--output=" + str(marker), "--since-lines"],
            "option-reference", 2)
        assert not marker.exists()
        bad_path = os.fsencode(sources) + b"/invalid-\xff.swift"
        try:
            with open(bad_path, "wb") as stream:
                stream.write(b"func invalidPath() {}\n")
            run([binary, "dead", "--project", project, "--since", "HEAD", "--since-lines"],
                "invalid-utf8-path", 2)
        except OSError as error:
            if error.errno != errno.EILSEQ:
                raise
            result["skipped"].append("invalid-utf8-path: filesystem rejects non-UTF-8 filenames")
        finally:
            if os.path.exists(bad_path):
                os.unlink(bad_path)
        branch = git("symbolic-ref", "--short", "HEAD")
        git("checkout", "-qb", "conflict-side")
        write("Only.swift", 'func outsideChange() {\n    print("side")\n}\n')
        git("add", "-A")
        git("commit", "-qm", "side")
        git("checkout", "-q", branch)
        write("Only.swift", 'func outsideChange() {\n    print("main")\n}\n')
        git("add", "-A")
        git("commit", "-qm", "main")
        run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "merge", "--no-commit", "conflict-side"],
            "make-conflict", 1)
        run([binary, "dead", "--project", project, "--since", "HEAD", "--since-lines"], "unmerged", 2)
        assert "unmerged" in (output / "unmerged.stderr.log").read_text()
        tree = git("rev-parse", "HEAD^{tree}")
        left = git("commit-tree", tree, "-p", base, "-m", "left")
        right = git("commit-tree", tree, "-p", base, "-m", "right")
        first = git("commit-tree", tree, "-p", left, "-p", right, "-m", "first merge")
        second = git("commit-tree", tree, "-p", right, "-p", left, "-m", "second merge")
        git("update-ref", "HEAD", first)
        run([binary, "dead", "--project", project, "--since", second, "--since-lines"], "ambiguous-base", 2)
        assert "unambiguous merge-base" in (output / "ambiguous-base.stderr.log").read_text()
        result.update(status="passed", fileFindings=expected_files, lineFindings=expected_lines,
                      checks=["committed", "staged", "unstaged", "current-coordinates", "declaration-location",
                              "rename", "deletion", "binary", "mode-only", "untracked", "literal-paths",
                              "subdirectory", "symlink-root", "driver-neutralization", "context-neutralization",
                              "invalid-utf8-path", "unmerged", "ambiguous-merge-base", "exit-0-1-2-64"])
        print(json.dumps(result, sort_keys=True))
    finally:
        (output / "verification.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
