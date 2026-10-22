#!/usr/bin/env python3
"""Capture and compare an exact SwiftPM Git change using two fresh compiler indexes.

Worktrees and logs are retained in a new output directory for review. Building a
package executes its build tools; use this on projects you trust to build.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


class CaptureError(RuntimeError):
    pass


def run(argv: list[str], cwd: Path, *, timeout: int = 600) -> bytes:
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_NO_LAZY_FETCH="1")
    result = subprocess.run(argv, cwd=cwd, env=environment, capture_output=True, timeout=timeout)
    if result.returncode:
        raise CaptureError(f"{argv[0]} failed ({result.returncode}): {result.stderr.decode(errors='replace')}")
    return result.stdout


def git(project: Path, *arguments: str) -> bytes:
    return run(["git", "--no-optional-locks", "-c", "core.fsmonitor=false",
                "-c", "core.hooksPath=" + os.devnull, "-c", "log.showSignature=false",
                "-C", str(project), *arguments], project)


def revision(project: Path, reference: str) -> str:
    return git(project, "rev-parse", "--verify", "--end-of-options", reference + "^{commit}").decode().strip()


def source_paths(project: Path) -> list[str]:
    rows = git(project, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    paths = sorted(set(os.fsdecode(p) for p in rows.split(b"\0") if p))
    for name in paths:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or ".git" in path.parts:
            raise CaptureError(f"Unsupported Git path: {name}")
        candidate = project / path
        if candidate.is_symlink() or (candidate.exists() and not candidate.is_file()):
            raise CaptureError(f"Symlinks and submodules require a manual capture: {name}")
        if not candidate.resolve().is_relative_to(project.resolve()):
            raise CaptureError(f"Source path leaves the project: {name}")
    return paths


def file_identity(path: Path) -> tuple[str, str] | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    mode = "100755" if path.stat().st_mode & 0o100 else "100644"
    return mode, digest.hexdigest()


def source_fingerprint(project: Path) -> str:
    digest = hashlib.sha256()
    for name in source_paths(project):
        identity = file_identity(project / name)
        if identity is None:
            continue
        digest.update(os.fsencode(name) + b"\0")
        digest.update("\0".join(identity).encode("ascii") + b"\0")
    return digest.hexdigest()


def neutralized_filters(project: Path) -> list[str]:
    # 읽기 전용 config 조회만 허용한다. checkout이 저장소 필터를 실행하지 않게 한다.
    result = subprocess.run(["git", "-C", str(project), "config", "-z", "--name-only", "--get-regexp",
                             r"^filter\..*\.(clean|smudge|process)$"], capture_output=True)
    if result.returncode not in (0, 1):
        raise CaptureError("Could not inspect Git content filters")
    arguments = []
    for key in sorted(set(os.fsdecode(x) for x in result.stdout.split(b"\0") if x)):
        name = key[len("filter."):].rsplit(".", 1)[0]
        if "=" in name:
            raise CaptureError("A Git filter cannot be disabled safely; use a fresh checkout")
        for suffix in ("clean", "smudge", "process", "required"):
            arguments.extend(["-c", f"filter.{name}.{suffix}=" + ("false" if suffix == "required" else "")])
    return arguments


def checkout(project: Path, destination: Path, commit: str) -> None:
    git(project, *neutralized_filters(project), "worktree", "add", "--detach", str(destination), commit)


def copy_working_tree(project: Path, destination: Path) -> None:
    original = set(source_paths(project))
    for name in sorted(set(source_paths(destination)) | original):
        source, target = project / name, destination / name
        if source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        elif target.is_file():
            # 새로 만든 전용 worktree 안의 삭제 파일만 반영한다.
            target.unlink()


def changed_paths(before: Path, current: Path) -> list[str]:
    # Git 인덱스 상태와 무관하게 실제 빌드할 두 끝점의 내용과 실행 비트를 비교한다.
    # HEAD 삭제 뒤 비추적 파일로 원본을 복원한 경우도 빈 변경으로 남긴다.
    paths = sorted(set(source_paths(before)) | set(source_paths(current)))
    return [name for name in paths if file_identity(before / name) != file_identity(current / name)]


def capture(binary: Path, project: Path, output: Path, label: str, timeout: int) -> tuple[Path, Path, dict]:
    start = time.monotonic()
    before = source_fingerprint(project)
    scratch = output / (label + "-build")
    command = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch)]
    build = run(command + ["--build-tests"], project, timeout=timeout)
    (output / (label + "-build.log")).write_bytes(build)
    bins = Path(os.fsdecode(run(command + ["--show-bin-path"], project)).strip())
    stores = [scratch / "out", scratch / "index/store", bins / "index/store"]
    store = next((p for p in stores if p.is_dir()), None)
    if store is None:
        raise CaptureError(f"{label}: build did not create a compiler index")
    snapshot = output / (label + ".json")
    snapshot.write_bytes(run([str(binary), "snapshot", "--project", str(project),
                              "--index-store", str(store)], project, timeout=timeout))
    after = source_fingerprint(project)
    if before != after:
        raise CaptureError(f"{label}: sources changed during build/capture. Resolve and commit dependency lockfiles "
                           "(including Package.resolved) before commit capture, or include them in working-tree "
                           "capture. Inspect generated source changes in the retained worktree before retrying.")
    return store, snapshot, {"sourceSHA256": before, "preparationSeconds": time.monotonic() - start,
                             "freshIndex": True, "sourceStableDuringBuild": True}


def analyze(args: argparse.Namespace) -> Path:
    preparation_start = time.monotonic()
    if not 1 <= args.limit <= 10000 or (args.depth is not None and not 1 <= args.depth <= 128):
        raise CaptureError("Limits require 1...10000 results and an optional depth of 1...128")
    project = Path(args.project).resolve()
    root = Path(os.fsdecode(git(project, "rev-parse", "--show-toplevel")).strip()).resolve()
    if project != root or not (project / "Package.swift").is_file():
        raise CaptureError("Automatic capture requires a SwiftPM package at the Git root; use manual snapshots otherwise")
    output = Path(args.output).resolve() if args.output else Path(tempfile.mkdtemp(prefix="cartograph-change-"))
    if args.output:
        output.mkdir(parents=True, exist_ok=False)
    if output.is_relative_to(root):
        raise CaptureError("Output must be outside the source repository")
    binary = Path(shutil.which(args.cartograph) or args.cartograph).resolve()
    base, head = revision(project, args.base), revision(project, args.head or "HEAD")
    initial = source_fingerprint(project) if args.working_tree else None
    before, current = output / "before-source", output / "current-source"
    checkout(project, before, base)
    checkout(project, current, head)
    if args.working_tree:
        copy_working_tree(project, current)
        if source_fingerprint(project) != initial or source_fingerprint(current) != initial:
            raise CaptureError("Working-tree sources changed during copy; retry when editing is idle")
    paths = changed_paths(before, current)
    input_preparation_seconds = time.monotonic() - preparation_start
    _, before_snapshot, before_evidence = capture(binary, before, output, "before", args.timeout)
    current_store, _, current_evidence = capture(binary, current, output, "current", args.timeout)
    command = [str(binary), "impact", "--before", str(before_snapshot), "--format", "json",
               "--project", str(current), "--index-store", str(current_store), "--limit", str(args.limit)]
    if args.depth is not None:
        command += ["--depth", str(args.depth)]
    modeled = [p for p in paths if p.endswith((".swift", ".m", ".mm", ".h", ".xib", ".storyboard"))
               or p.endswith(".xccurrentversion") or (".xcdatamodel/" in p and p.endswith("/contents"))]
    selected_file = output / "selected-files.json"
    selected_file.write_text(json.dumps([str(current / path) for path in modeled]), encoding="utf-8")
    command += ["--files-from", str(selected_file)]
    start = time.monotonic()
    # 아직 빌드되지 않은 선언 등 incomplete(exit 2/64)도 JSON 근거를 보존한다.
    result = subprocess.run(command, cwd=current, capture_output=True, timeout=args.timeout)
    (output / "impact.stderr.log").write_bytes(result.stderr)
    if result.returncode not in (0, 2, 64):
        raise CaptureError(result.stderr.decode(errors="replace"))
    document = json.loads(result.stdout)
    document["changeInput"] = {"base": base, "head": head, "mode": "working-tree" if args.working_tree else "git-commits",
                               "changedFiles": paths, "unmodeledFiles": sorted(set(paths) - set(modeled)),
                               "before": before_evidence, "current": current_evidence,
                               "inputPreparationSeconds": input_preparation_seconds,
                               "analysisSeconds": time.monotonic() - start,
                               "totalSeconds": time.monotonic() - preparation_start,
                               "analysisExitCode": result.returncode,
                               "sourceScope": "tracked-and-nonignored-untracked-regular-files",
                               "selectionPrecision": "file-wide-declarations", "graphPolicy": "separate-revisions"}
    document.setdefault("limitations", []).append("File-wide seeds are review candidates; static tests do not predict failures or authorize skipping tests.")
    document["limitations"].append("Source identities cover tracked and nonignored untracked regular files; "
                                   "ignored inputs, external build dependencies, toolchain and environment are not content-bound by this helper.")
    if set(paths) - set(modeled):
        document["status"] = "incomplete"
        document["limitations"].append("Unmodeled changed files require separate configuration/API/resource review.")
    result_path = output / "impact.json"
    result_path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return result_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default=".")
    parser.add_argument("--cartograph", default="cartograph")
    parser.add_argument("--base", required=True, help="Exact before commit; no implicit merge-base")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--head", help="Exact after commit (default: HEAD)")
    mode.add_argument("--working-tree", action="store_true", help="Include staged, unstaged, and untracked files")
    parser.add_argument("--output", help="New directory outside the repository; retained with worktrees and evidence")
    parser.add_argument("--depth", type=int)
    parser.add_argument("--limit", type=int, default=200)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    try:
        result = analyze(args)
        print(result)
        document = json.loads(result.read_text(encoding="utf-8"))
        return 2 if document["status"] == "incomplete" or document["changeInput"]["analysisExitCode"] != 0 else 0
    except (CaptureError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Capture incomplete: {error}", file=__import__("sys").stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
