#!/usr/bin/env python3
"""Git 이 무시하지만 컴파일된 소스(생성 코드)의 보존 경계를 새 컴파일러 인덱스로 양방향 검증한다.

무시 파일은 저장소에 커밋할 수 없으므로 픽스처 사본 안에 템플릿을 옮겨 만든 뒤 `git init` 으로 무시 상태를
재현하고 빌드한다. 기대값은 사람이 소스에서 정한 전체 목록이며, 제품 출력에서 기대값을 만들지 않는다.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import tempfile

spec = importlib.util.spec_from_file_location(
    "recursive_harness", Path(__file__).with_name("verify-recursive-calls.py")
)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
run, require, compare = shared.run, shared.require, shared.compare

CORPUS = Path(__file__).resolve().parents[1] / "Fixtures/IgnoredSourceCorpus"
# 템플릿 → 사본 안의 무시 경로. 앞의 둘은 SwiftPM 이 컴파일하고, 마지막은 타깃 밖이라 컴파일되지 않는다.
IGNORED_FILES = {
    "GeneratedAccessors.swift.txt": "Sources/IgnoredSources/GeneratedAccessors.swift",
    "R.generated.swift.txt": "Sources/IgnoredSources/R.generated.swift",
    "WorktreeCaller.swift.txt": ".claude/worktrees/copy/Sources/IgnoredSources/WorktreeCaller.swift",
}
# 무시된 링크 → 추적 파일. 링크를 무시 소스로 다시 읽으면 추적된 죽은 코드가 부르는 선언이 살아남는다.
IGNORED_LINKS = {"Links/DeadChain.swift": "../Sources/IgnoredSources/DeadChain.swift"}
EXCLUSION_PREFIX = "source-discovery-exclusions: "
RETAINED_SENTENCE = "Declarations used by ignored sources the compiler indexed are retained (ignoredSourceReference)."
# 기본 제외만 쓰는 코퍼스라 R.generated.swift 하나가 기본 패턴 하나에 걸린다. 걸리지 않은 기본 패턴은 이름이 없어야 한다.
OUTSIDE_SCOPE_SENTENCE = (
    ' 1 ignored source file(s) are outside the include/exclude scope (matched by exclude patterns '
    '["**/*.generated.swift"]), so declarations used only by them are not retained and can be reported as unused; '
    "remove the matching exclude pattern to follow them."
)
UNWALKED_SENTENCE = (
    " Generated sources inside build directories that discovery does not walk (such as .build and DerivedData, "
    "where build-tool plugins write their output) are not examined."
)
# 선언 이름 → 기대 도달성 상태와 보존 근거. 무시 소스가 쓰는 선언만 ignoredSourceReference 로 남는다.
EXPECTED_STATES = {
    "usedByGenerated": ("retained", "ignoredSourceReference"),
    "fallbackTitle": ("retained", "ignoredSourceReference"),
    "AdoptedByGenerated": ("retained", "ignoredSourceReference"),
    "neverCalled": ("unreachable", None),
    "usedOnlyByUncompiledCopy": ("unreachable", None),
    "usedOnlyByExcludedGenerated": ("unreachable", None),
    "ExtendedOnly": ("unreachable", None),
    "DeadCallee": ("unreachable", None),
}


def isolate_git_environment() -> None:
    """호출자의 `GIT_*` 변수를 이 프로세스와 모든 자식(Git·SwiftPM·Cartograph)에서 지운다.

    Git 훅은 `GIT_DIR` 을 내보낸다. 그 상태로 `git -C <사본> init` 을 하면 사본이 아니라 바깥 저장소를 다시
    초기화하고 사본에는 `.git` 이 생기지 않는다. 제품도 `GitSourceSelection.select` 에서 같은 변수를 지운다.
    """
    for key in [key for key in os.environ if key.startswith("GIT_")]:
        del os.environ[key]


def git(project: Path, output: Path, name: str, arguments: list[str], expected: int = 0) -> str:
    """훅을 끄고 Git 을 실행한다. 무시 판정은 제품이 쓰는 `--exclude-standard` 와 같은 규칙을 따른다."""
    command = ["git", "-c", "core.hooksPath=/dev/null", "-C", str(project)]
    return run([*command, *arguments], project, output, name, expected=expected)


def init_repository(project: Path, output: Path) -> None:
    """사본만의 저장소를 만들고, 사용자의 전역 무시 파일이 판정을 바꾸지 못하게 지역 설정으로 끈다.

    제품의 `git ls-files --exclude-standard` 도 저장소 지역 설정의 `core.excludesFile` 을 읽으므로 둘이 같은 규칙을 본다.
    """
    git(project, output, "git-init", ["init", "-q"])
    git(project, output, "git-config-excludes", ["config", "core.excludesFile", "/dev/null"])
    top = git(project, output, "git-toplevel", ["rev-parse", "--show-toplevel"]).strip()
    require((project / ".git").is_dir() and Path(top).resolve() == project.resolve(),
            f"Git did not initialise the fixture copy as its own repository (top level {top!r})")


def materialize(project: Path, output: Path) -> list[str]:
    """무시 파일과 링크를 만들고 Git 이 실제로 무시하는지 확인한다. 무시 경로를 정렬해 돌려준다."""
    isolate_git_environment()
    for template, destination in IGNORED_FILES.items():
        target = project / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(project / "Templates" / template, target)
    for link, destination in IGNORED_LINKS.items():
        (project / link).parent.mkdir(parents=True, exist_ok=True)
        (project / link).symlink_to(destination)
    init_repository(project, output)
    ignored = sorted([*IGNORED_FILES.values(), *IGNORED_LINKS])
    for index, path in enumerate(ignored):
        git(project, output, f"git-check-ignored-{index}", ["check-ignore", "-q", path])
    listed = git(project, output, "git-ls-files", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    selected = {path for path in listed.split("\0") if path}
    # 무시 규칙이 바뀌어 추적 소스나 매니페스트까지 숨기면 아래 기대 목록 전체가 다른 이유로 맞거나 틀린다.
    swift = {path.relative_to(project).as_posix() for path in project.rglob("*.swift") if ".git" not in path.parts}
    expected = (swift | {"Package.swift"}) - set(ignored)
    require(expected <= selected and not selected & set(ignored),
            f"Git selection drifted: expected {sorted(expected)} selected, {ignored} ignored; got {sorted(selected)}")
    return ignored


def unused_messages(document: dict) -> list[str]:
    return sorted(row["message"] for row in document["diagnostics"] if row["ruleIdentifier"] == "unused-symbol")


def exclusion_limitation(document: dict) -> str:
    matches = [item for item in document.get("limitations", []) if item.startswith(EXCLUSION_PREFIX)]
    require(len(matches) == 1, f"Expected one {EXCLUSION_PREFIX!r} limitation, got {document.get('limitations')}")
    return matches[0]


def verify_findings(harness: shared.Harness, project: Path, ignored: list[str]) -> None:
    """미사용 목록 전체와, 무시 파일에서 나온 진단·정점이 없는지 본다."""
    dead = harness.document("dead", ["dead", "--report-format", "json"])
    expected = (project / "expected-unused.txt").read_text().splitlines()
    compare(unused_messages(dead), expected, "complete unused-symbol inventory")
    paths = {row["location"]["path"] for row in dead["diagnostics"] if row.get("location")}
    require(not any(path.endswith(tuple(ignored)) for path in paths), f"Ignored file produced findings: {paths}")
    limitation = exclusion_limitation(dead)
    compare(json.loads(limitation.split("; paths: ", 1)[1]), ignored, "ignored path inventory")
    require(limitation.startswith(f"{EXCLUSION_PREFIX}{len(ignored)} "), f"Wrong exclusion count: {limitation}")
    require(RETAINED_SENTENCE in limitation, f"Limitation lost the retention sentence: {limitation}")
    require(OUTSIDE_SCOPE_SENTENCE in limitation, f"Limitation hid the excluded ignored source: {limitation}")
    require(UNWALKED_SENTENCE in limitation, f"Limitation lost the unwalked build directory sentence: {limitation}")
    graph = harness.document("graph", ["graph", "--level", "symbol", "--format", "json"])
    located = {node["location"]["path"] for node in graph["nodes"] if node.get("location")}
    require(located and not any(path.endswith(tuple(ignored)) for path in located), f"Ignored nodes: {located}")
    for level in ("type", "symbol"):
        cycles = harness.document(f"cycles-{level}", ["cycles", "--level", level, "--report-format", "json"])
        compare(cycles["diagnostics"], [], f"{level} cycles with the ignored file outside the graph")


def verify_states(harness: shared.Harness) -> None:
    """선언마다 도달성 상태와 근거가 기대와 같은지, --explain 이 근거를 문장으로 말하는지 본다."""
    for name, (state, reason) in EXPECTED_STATES.items():
        document = harness.document(f"query-{name}", ["query", name])
        compare(document["status"], "found", f"query {name} status")
        reachability = document["result"]["reachability"]
        compare((reachability["state"], reachability.get("reason")), (state, reason), f"query {name} reachability")
    explanation = harness.text("explain-usedByGenerated", ["dead", "--explain", "usedByGenerated"])
    require(
        "referenced from a Git-ignored source file the compiler indexed" in explanation,
        f"--explain did not name the ignored source: {explanation}",
    )


def verify_control(harness: shared.Harness, project: Path) -> None:
    """같은 인덱스에서 생성 파일의 무시를 풀면 순환과 그 파일의 미사용 선언이 보여야 한다(검사가 비어 있지 않음).

    무시를 풀면 아무도 쓰지 않는 생성 타입 자체가 보고되고, 그 안의 멤버는 타입에 접혀 따로 나오지 않는다.
    """
    gitignore = project / ".gitignore"
    original = gitignore.read_text()
    line = f"/{IGNORED_FILES['GeneratedAccessors.swift.txt']}\n"
    require(line in original, f"Fixture .gitignore no longer ignores {line.strip()}")
    gitignore.write_text(original.replace(line, ""))
    try:
        cycles = harness.document("control-cycles-type", ["cycles", "--level", "type", "--report-format", "json"])
        members = {"Screen", "GeneratedAccessors"}
        named = {name for row in cycles["diagnostics"] for name in members if name in row["message"]}
        compare(named, members, "control: type cycle through the un-ignored file")
        dead = harness.document("control-dead", ["dead", "--report-format", "json"])
        own = {"enum 'IgnoredSources.GeneratedAccessors' is never used",
               "struct 'IgnoredSources.GeneratedConformer' is never used"}
        require(own <= set(unused_messages(dead)), "control: the un-ignored file's own declarations were not reported")
    finally:
        gitignore.write_text(original)


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Git-ignored compiled source retention on a fresh index.")
    parser.add_argument("--cartograph", type=Path, required=True, help="Exact Cartograph executable to test.")
    parser.add_argument("--output-dir", type=Path, help="New or empty directory for logs, workspace and index.")
    parser.add_argument("--swiftpm-flags", default=os.environ.get("SWIFTPM_FLAGS", ""))
    args = parser.parse_args()
    isolate_git_environment()
    binary = args.cartograph.expanduser().resolve()
    if binary.is_dir():
        binary /= "cartograph"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"Cartograph executable not found: {binary}")
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-ignored-sources-"))).resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error(f"Output directory must be empty; choose a new path to preserve prior evidence: {output}")
    output.mkdir(parents=True, exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    project = workspace / CORPUS.name
    shutil.copytree(CORPUS, project, ignore=shutil.ignore_patterns(".build", ".swiftpm", "__pycache__"))
    ignored = materialize(project, output)
    run(["swift", "--version"], project, output, "swift-version")
    _, store = shared.build_index(project, workspace / "build", output, shlex.split(args.swiftpm_flags))
    harness = shared.Harness(binary, project, store, output)
    verify_findings(harness, project, ignored)
    verify_states(harness)
    verify_control(harness, project)
    result = {
        "status": "passed",
        "cartographSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "ignoredPaths": ignored,
        "unusedSymbols": len((project / "expected-unused.txt").read_text().splitlines()),
    }
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"  ok  무시 컴파일 소스 경계 {len(ignored)}개 경로·미사용 {result['unusedSymbols']}건이 기대와 일치 ({output})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
