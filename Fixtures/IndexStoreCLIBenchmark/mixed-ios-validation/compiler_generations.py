"""공유 컴파일 입력 세대와 양쪽에 동일하게 부과할 준비 비용을 봉인한다."""

from __future__ import annotations
import hashlib
import json
from pathlib import Path
import time

from validation_common import manifest, source_manifest

POLICIES = ("incremental-diagnostic-v1", "fresh-shared-v2")
ARMS = ("cartograph", "index_dump_assembly")
INCOMPLETE_PROCESS_EXIT = 125


class IncompleteProcess(RuntimeError):
    """불완전한 하위 실행의 종료 코드를 모든 래퍼에 보존한다."""


def incomplete_exit(code: object) -> bool:
    """미완료 종료가 일반적인 관측 실패로 축소되지 않게 한다."""
    return type(code) is not int or code < 0 or code == INCOMPLETE_PROCESS_EXIT


def content_digest(value: object) -> str:
    """컴파일 명령 구조를 순서가 고정된 봉인 값으로 연결한다."""
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def tool_digest(path: Path) -> str:
    """큰 실행 파일을 메모리에 한꺼번에 올리지 않고 바이트 교체를 검출한다."""
    # 큰 컴파일러 실행 파일도 고정 크기 버퍼로 해시한다.
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def toolchain_manifest(setup: dict) -> dict:
    """드라이버와 실제 Swift 프런트엔드를 함께 고정한다."""
    paths = [Path(setup[key]).absolute() for key in ("swiftc", "clang", "library")]
    paths.append(paths[0].with_name("swift-frontend"))
    return {str(path): tool_digest(path) for path in paths}


def begin(output: Path, stage: str, project: Path, setup: dict, planned: bool) -> dict:
    """기존 성공 세대에 쓰지 않고 새 시도의 입력과 경로를 기록한다."""
    # 기존 입력을 복사하거나 이동하지 않아, 실패한 쓰기가 승인된 세대에 닿지 않는다.
    root = output / "Generations" / stage
    if (
        Path(stage).name != stage or stage in {"", ".", ".."} or root.exists() or root.is_symlink()
        or not root.parent.resolve().is_relative_to(output.resolve())
    ):
        raise ValueError("Compiler generation must be a new task-owned directory")
    store, build = root / "IndexStore", root / "Build"
    store.mkdir(parents=True)
    (build / "modules").mkdir(parents=True)
    return dict(
        id=stage,
        status="planned" if planned else "building",
        store=str(store),
        build=str(build),
        source_files=source_manifest(project),
        toolchain_files={} if planned else setup["compiler_toolchain_files"],
        sdk_content_identity=setup.get("sdk_content_identity", {"verification": "not-recorded-validation-only"}),
        index_files={},
        build_files={},
    )


def capture_attempt(attempt: dict) -> None:
    """거부된 시도도 원본 바이트와 비교할 수 있게 전 파일 해시를 남긴다."""
    attempt["index_files"] = manifest(Path(attempt["store"]))
    attempt["build_files"] = manifest(Path(attempt["build"]))


def verify_inputs(attempt: dict, project: Path) -> None:
    """컴파일 중 입력 교체가 성공 판정으로 승격되지 않게 한다."""
    if source_manifest(project) != attempt["source_files"]:
        raise ValueError("Source/config bytes changed during compiler generation")
    for name, expected in attempt["toolchain_files"].items():
        if not Path(name).is_file() or tool_digest(Path(name)) != expected:
            raise ValueError("Toolchain bytes changed during compiler generation")


def seal(attempt: dict, project: Path, commands: list[dict]) -> None:
    """검증된 성공 출력만 관측 대상 세대로 승격한다."""
    verify_inputs(attempt, project)
    capture_attempt(attempt)
    attempt["commands_sha256"] = content_digest(commands)
    attempt["status"] = "accepted"


def guard(accepted: dict | None) -> None:
    """양쪽 엔진이 동일한 승인 바이트를 읽었다는 경계를 다시 확인한다."""
    if not accepted:
        return
    if accepted["status"] != "accepted":
        raise ValueError("Compiler generation has not been accepted")
    if (
        manifest(Path(accepted["store"])) != accepted["index_files"]
        or manifest(Path(accepted["build"])) != accepted["build_files"]
    ):
        raise ValueError("Accepted compiler generation bytes changed")
    for name, expected in accepted["toolchain_files"].items():
        if not Path(name).is_file() or tool_digest(Path(name)) != expected:
            raise ValueError("Accepted compiler generation toolchain bytes changed")


def cost(started: float | None, builds: list[dict], *, planned: bool) -> dict:
    """공유 준비 작업 전부를 각 arm에 부과하고 계획을 실측과 구분한다."""
    # 명령 로그/출력 맵/봉인 해시를 포함한 전체 준비 구간을 각 arm에 한 번씩 부과한다.
    wall = None if planned else (time.perf_counter() - started if started is not None else 0.0)
    compiler = None if planned else sum(record["wall_seconds"] for record in builds)
    return dict(
        status="not-measured-plan-only" if planned else "measured",
        scope="full shared compiler/index preparation, command logs, output maps and acceptance seals",
        wall_seconds=wall,
        compiler_subprocess_wall_seconds=compiler,
        charged_wall_seconds_by_arm={arm: wall for arm in ARMS},
        index_or_cache_copy_operations=0,
        snapshot_copy_scope="private evidence only; never used to seed compiler or engine inputs",
    )
