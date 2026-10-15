#!/usr/bin/env python3
"""고정된 컴파일 전용 수명 주기의 여덟 세대를 같은 SDK 내용으로 괄호 친다."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIXTURE = ROOT / "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation"
BASELINE_SHA256 = "50fcaf77a96f5701e55ff5d16812d0d8ec2fdb2d250a826e58447dac4371613c"
EXPECTATION_SHA256 = "4dfaa59503786926e79da5dec764122cd670cb36309a2fc0107b1fe28f621abc"
FROZEN_HELPERS = {
    "Scripts/normalize-indexstore-evidence.py":
        "17c705fac8670a77f9cbd7305c8f658807e2f6045a0ccb00172c79bccd1f7c17",
    "Scripts/benchmark-inputs/native_calibration_inputs.py":
        "2f11f597fb8c7b2265f789467f9dc6009af6afd7f2c09d1fc7a3b386f9373381",
    "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/validation_common.py":
        "1abf5f434ea0616bc671d5b017945e66c584f515883fa4c6e2086ea5f71b58d1",
    "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/compiler_generations.py":
        "3d249f7cd1ac1a6bd62edafb116c1ea389b903899373e3fe29878f0215e79fca",
    "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/source-manifest.json":
        "6dfdcf2461ef7ab118554932b088eb849f86c426d8503ba1b17b3be6acfa6657",
}
STAGE_PLAN = (
    ("initial", None, "success", "initial"),
    ("header_edit_unbuilt", "edit_header", None, None),
    ("header_edit_rebuilt", None, "success", "header_edit"),
    ("header_rename_unbuilt", "rename_header", None, None),
    ("header_rename_rebuilt", None, "success", "header_rename"),
    ("header_delete_unbuilt", "delete_header", None, None),
    ("header_delete_build_failed", None, "failure", None),
    ("header_restored_rebuilt", "restore", "success", "initial"),
    ("swift_rename_unbuilt", "rename_swift", None, None),
    ("swift_rename_rebuilt", None, "success", "swift_rename"),
    ("swift_delete_unbuilt", "delete_swift", None, None),
    ("swift_delete_rebuilt", None, "success", "swift_delete"),
    ("restored_rebuilt", "restore", "success", "initial"),
)
BUILD_STAGES = tuple(row[0] for row in STAGE_PLAN if row[2])
ARMS = ("cartograph", "index_dump_assembly")
ENVIRONMENT_KEYS = {"PATH", "LC_ALL", "LANG", "DEVELOPER_DIR", "ImageOS", "ImageVersion", "HOME", "TMPDIR"}
NORMALIZATION_RECIPE = "exact-selected-tool-or-longest-path-component-prefix-v1"
LIMITATIONS = [
    "Candidate only: accepted=false and final_protocol_ready=false remain mandatory.",
    "Full reads are before/after observations, not atomic snapshots; intervening ABA mutation is not excluded.",
    "The host macOS SDK, OS and dynamic-loader closure are not established by these two roots.",
    "No linking, JIT, simulator or target execution occurs; target-runtime closure remains unproved.",
    "A terminal compiler driver does not prove containment of detached descendants.",
]


def load(name: str, path: Path):
    """고정된 저장소 파일만 읽고 임의 훅이나 모듈 검색 경로를 받지 않는다."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NATIVE = load("generation_native_inputs", HERE / "native_calibration_inputs.py")
SEAL, SELECTOR = NATIVE.SEAL, NATIVE.SELECTOR
COMMON = load("generation_validation_common", FIXTURE / "validation_common.py")
NORMALIZER = load("generation_alias_normalizer", HERE.parent / "normalize-indexstore-evidence.py")
WINDOWS_PATH = re.compile(r"(?:[A-Za-z]:[\\/]|\\\\[A-Za-z0-9])")
LINK_ENCODING = "interpreter-link-target-slash-components-v1"


class GenerationError(ValueError):
    """실패한 경계를 다음 컴파일로 넘기지 않는다."""


class Deadline:
    """전체 자식 예산으로 해시 읽기와 각 프로브/컴파일의 개별 제한을 함께 묶는다."""

    def __init__(self, started: float, error_type):
        self.expires, self.error_type, self.expired = started + 1200.0, error_type, False
        require(signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0), "existing-lifecycle-alarm")
        self.previous = signal.signal(signal.SIGALRM, self.alarm)
        signal.setitimer(signal.ITIMER_REAL, max(0.001, self.expires - time.monotonic()))

    def alarm(self, signum, frame):
        self.expired = True
        raise self.error_type("SDK generation lifecycle deadline expired")

    def check(self):
        if self.expired or time.monotonic() >= self.expires:
            self.expired = True
            raise self.error_type("SDK generation lifecycle deadline expired")

    def remaining(self, ceiling=300.0):
        self.check()
        self.launch_monotonic = time.monotonic()
        remaining = self.expires - self.launch_monotonic
        require(remaining > 0, "lifecycle-launch-after-deadline")
        return min(float(ceiling), remaining)

    def close(self):
        signal.setitimer(signal.ITIMER_REAL, 0.0)
        signal.signal(signal.SIGALRM, self.previous)


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise GenerationError(reason)


def identity(value: object) -> str:
    """경로 정규화 전후의 구조와 순서를 각각 고정한다."""
    return hashlib.sha256(SEAL.canonical_bytes(value)).hexdigest()


def helper_hashes() -> dict:
    """고정 도우미와 이번 명시적 진입점의 전체 바이트를 요청에 연결한다."""
    paths = set(FROZEN_HELPERS) | {
        "Scripts/benchmark-inputs/native_generation_inputs.py",
        "Scripts/benchmark-inputs/sdk_content_seal.py",
        "Scripts/benchmark-inputs/select_sdk_roots.py",
        "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/run_ios_validation.py",
    }
    observed = {name: SELECTOR.file_identity(ROOT / name)["sha256"] for name in sorted(paths)}
    require(all(observed[name] == digest for name, digest in FROZEN_HELPERS.items()), "unreviewed-generation-helper")
    require(tuple(COMMON.STAGES) == STAGE_PLAN, "changed-stage-plan")
    return observed


def directory_identity(path: Path) -> dict:
    """HOME/TMPDIR의 내용 변경은 허용하되 소유 디렉터리 교체는 거부한다."""
    require(path.is_absolute() and path.resolve(strict=True) == path, "environment-directory-alias")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(), "unowned-environment-directory")
    return dict(path=str(path), device=info.st_dev, inode=info.st_ino, type="directory")


def environment_contract(environment: dict, expected: dict) -> dict:
    """언어·플러그인·로더 변수를 상속하지 않는 정확한 여덟 키만 허용한다."""
    require(isinstance(environment, dict) and set(environment) == ENVIRONMENT_KEYS, "unexpected-child-environment")
    fixed = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", LC_ALL="C", LANG="C",
                 DEVELOPER_DIR=expected["developer_lexical"], **expected["runner"])
    require(all(environment[key] == value for key, value in fixed.items()), "child-environment-mismatch")
    require(all(isinstance(value, str) and value for value in environment.values()), "invalid-child-environment")
    owned = {label: directory_identity(Path(environment[key])) for key, label in (("HOME", "home"), ("TMPDIR", "temporary"))}
    for row in owned.values():
        NATIVE.evidence_boundary(Path(row["path"]), expected)
    home, temporary = (Path(environment[key]) for key in ("HOME", "TMPDIR"))
    require(not home.is_relative_to(temporary) and not temporary.is_relative_to(home), "environment-directory-overlap")
    return owned


def checked_link_target(value: object) -> str:
    """링크 원문은 분리 전과 역변환 뒤에 동일한 비밀·Windows 검사를 거친다."""
    require(type(value) is str and bool(value) and len(os.fsencode(value)) <= 16384, "invalid-interpreter-link-target")
    relative = "generation-interpreter-link-target"
    NORMALIZER.check_sensitive(value, relative)
    match = WINDOWS_PATH.search(value)
    if match:
        NORMALIZER.block("unmapped-windows-absolute-path", relative, match.group())
    return value


def interpreter_alias(alias: dict, *, restore=False) -> dict:
    """새 Python 별칭의 링크 대상만 가역 변환하며 부모 이동도 실행하지 않는 원문으로 보존한다."""
    require(type(alias) is dict and set(alias) == {"lexical_path", "canonical_path", "components"},
            "interpreter-alias-schema")
    require(all(type(alias[key]) is str and Path(alias[key]).is_absolute()
                for key in ("lexical_path", "canonical_path")), "interpreter-alias-path")
    rows = alias["components"]
    require(type(rows) is list and 0 < len(rows) <= SELECTOR.MAX_PATH_COMPONENTS, "interpreter-alias-components")
    projected = []
    for row in rows:
        require(type(row) is dict, "interpreter-alias-component")
        kind = row.get("entry_type")
        fields = {"component", "entry_type", "identity"} | ({"link_target"} if kind == "symlink" else set())
        require(kind in ("directory", "file", "symlink") and set(row) == fields
                and type(row["component"]) is str and "/" not in row["component"]
                and type(row["identity"]) is list and len(row["identity"]) == 3
                and all(type(item) is int and item >= 0 for item in row["identity"]), "interpreter-alias-component")
        result = dict(row)
        if kind == "symlink":
            target = row["link_target"]
            if restore:
                require(type(target) is dict and set(target) == {"encoding", "components", "sha256"}
                        and target["encoding"] == LINK_ENCODING, "interpreter-link-encoding")
                parts = target["components"]
                require(type(parts) is list and bool(parts)
                        and all(type(part) is str and "/" not in part for part in parts), "interpreter-link-components")
                value = checked_link_target("/".join(parts))
                require(SEAL.valid_sha(target["sha256"])
                        and hashlib.sha256(value.encode()).hexdigest() == target["sha256"], "interpreter-link-hash")
                result["link_target"] = value
            else:
                value = checked_link_target(target)
                result["link_target"] = dict(encoding=LINK_ENCODING, components=value.split("/"),
                                             sha256=hashlib.sha256(value.encode()).hexdigest())
        projected.append(result)
    return {**alias, "components": projected}


def interpreter_identity(path: str) -> dict:
    """물리 실행 파일과 전체 별칭 사슬을 고정하되 링크 대상의 슬래시는 정확히 분리한다."""
    original = Path(path)
    require(original.is_absolute(), "absolute-python-required")
    physical = original.resolve(strict=True)
    record = SELECTOR.file_identity(physical)
    return dict(path=str(original), physical_path=str(physical), **record,
                alias=interpreter_alias(NATIVE.path_chain(original)))


def verify_interpreter_identity(record: dict, path: str) -> bool:
    """영수증의 원문 링크와 실제 최신 사슬·파일을 비교하여 재해시된 위조도 거부한다."""
    require(type(record) is dict and "alias" in record, "interpreter-identity-schema")
    restored = {**record, "alias": interpreter_alias(record["alias"], restore=True)}
    current = interpreter_identity(path)
    current["alias"] = interpreter_alias(current["alias"], restore=True)
    return identity(restored) == identity(current)


def validate_candidate(candidate: dict, expected: dict) -> dict:
    """기존 원본 봉인 전체를 읽고 승인된 기준 내용 해시와 연결한다."""
    require(candidate.get("status") == "captured-candidate" and candidate.get("boundary") == "before-compilation"
            and candidate.get("accepted") is False and candidate.get("final_protocol_ready") is False,
            "invalid-generation-candidate")
    require(candidate["expectation_sha256"] == EXPECTATION_SHA256, "generation-expectation-mismatch")
    require(candidate["content_sha256"] == BASELINE_SHA256, "generation-baseline-mismatch")
    NATIVE.assert_native(candidate["native"], expected)
    require(NATIVE.selected_layout(expected, candidate["native"]["selected"]) == candidate["native"]["layout"],
            "generation-aliases-changed")
    seal = SEAL.strict_expected_json(SEAL.expected_bytes(Path(candidate["seal_path"])))
    SEAL.validate_expected(seal)
    require(seal["manifest_sha256"] == candidate["seal_manifest_sha256"]
            and seal["content_sha256"] == BASELINE_SHA256 and seal["roots"] == expected["roots"],
            "generation-seal-mismatch")
    return seal


def make_request(candidate: dict, evidence_root: Path, environment: dict, python_path: str,
                 source_pins: dict | None = None, environment_creation: dict | None = None) -> dict:
    """부모가 명시한 동일 환경과 원본 후보를 한 번의 SHA-bound 요청으로 남긴다."""
    expected, digest = NATIVE.expectation()
    require(digest == EXPECTATION_SHA256, "generation-expectation-mismatch")
    validate_candidate(candidate, expected)
    evidence_root = evidence_root.resolve()
    NATIVE.evidence_boundary(evidence_root, expected)
    owned = environment_contract(environment, expected)
    require(environment_creation == dict(fresh=True, directories=owned), "environment-creation-receipt-mismatch")
    pins = helper_hashes()
    require(source_pins is None or source_pins == pins, "generation-source-pins-mismatch")
    return dict(schema_version=1, profile="mixed-ios-sdk-generation-brackets-v1", accepted=False,
                final_protocol_ready=False, candidate=candidate, candidate_sha256=identity(candidate),
                evidence_root=str(evidence_root), environment=environment_rows(environment),
                environment_directories=owned, environment_creation=environment_creation,
                python=interpreter_identity(python_path), helper_sha256=pins,
                normalization_recipe=NORMALIZATION_RECIPE, expected_full_generation_reads=16,
                expected_total_full_reads=18, planned_commands=48, expected_executed_commands=43)


def validate_request(path: Path, digest: str, *, current_environment=True) -> dict:
    """설정용 컴파일러 프로브 전부터 요청·환경·Python 바인딩을 강제한다."""
    raw = SELECTOR.file_identity(path, SELECTOR.MAX_TEXT_BYTES, True)
    require(SEAL.valid_sha(digest) and raw["sha256"] == digest, "generation-request-sha256-mismatch")
    request = SELECTOR.strict_json(raw["text"])
    fields = {"schema_version", "profile", "accepted", "final_protocol_ready", "candidate", "candidate_sha256",
              "evidence_root", "environment", "environment_directories", "python", "helper_sha256",
              "environment_creation",
              "normalization_recipe", "expected_full_generation_reads", "expected_total_full_reads",
              "planned_commands", "expected_executed_commands"}
    require(isinstance(request, dict) and set(request) == fields, "invalid-generation-request")
    require(type(request["schema_version"]) is int and request["schema_version"] == 1
            and request["profile"] == "mixed-ios-sdk-generation-brackets-v1"
            and request["accepted"] is False and request["final_protocol_ready"] is False,
            "invalid-generation-request")
    for name, value in (("expected_full_generation_reads", 16), ("expected_total_full_reads", 18),
                        ("planned_commands", 48), ("expected_executed_commands", 43)):
        require(type(request[name]) is int and request[name] == value, "changed-generation-count")
    require(request["normalization_recipe"] == NORMALIZATION_RECIPE, "changed-normalization-recipe")
    require(request["helper_sha256"] == helper_hashes(), "generation-helper-changed")
    require(request["candidate_sha256"] == identity(request["candidate"]), "generation-candidate-changed")
    expected, expectation_digest = NATIVE.expectation()
    require(expectation_digest == EXPECTATION_SHA256, "generation-expectation-mismatch")
    environment = request_environment(request)
    require(not current_environment or dict(os.environ) == environment, "child-environment-mismatch")
    require(environment_contract(environment, expected) == request["environment_directories"]
            and request["environment_creation"] == dict(fresh=True, directories=request["environment_directories"]),
            "environment-directory-changed")
    require(verify_interpreter_identity(request["python"], sys.executable), "generation-python-mismatch")
    validate_candidate(request["candidate"], expected)
    return request


PATH_COMPONENTS = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]


def environment_rows(environment: dict) -> list:
    """고정 PATH만 분리하여 일반 스캐너의 드라이브 문자 규칙을 바꾸지 않는다."""
    require(set(environment) == ENVIRONMENT_KEYS and environment["PATH"] == ":".join(PATH_COMPONENTS),
            "unexpected-child-environment")
    return [dict(name=key, value=list(PATH_COMPONENTS) if key == "PATH" else environment[key])
            for key in sorted(ENVIRONMENT_KEYS)]


def request_environment(request: dict) -> dict:
    """정확한 여덟 이름과 PATH의 고정 네 요소를 검증한 뒤 원래 값을 복원한다."""
    rows = request["environment"]
    require(isinstance(rows, list) and len(rows) == len(ENVIRONMENT_KEYS)
            and all(isinstance(row, dict) and set(row) == {"name", "value"} for row in rows),
            "invalid-child-environment")
    require([row["name"] for row in rows] == sorted(ENVIRONMENT_KEYS), "unexpected-child-environment")
    result = {}
    for row in rows:
        name, value = row["name"], row["value"]
        if name == "PATH":
            require(type(value) is list and all(type(part) is str for part in value) and value == PATH_COMPONENTS,
                    "invalid-fixed-path-components")
            result[name] = ":".join(value)
        else:
            require(type(value) is str and bool(value), "invalid-child-environment")
            result[name] = value
    return result


def expected_sources(stage: str) -> dict:
    """수정 연산을 메모리에서 재현하여 현재 디스크 상태를 자기 기대값으로 삼지 않는다."""
    initial = {str(path.relative_to(FIXTURE / "fixture")): path.read_bytes()
               for path in sorted((FIXTURE / "fixture").rglob("*")) if path.is_file()}
    frozen = SELECTOR.strict_json((FIXTURE / "source-manifest.json").read_text())
    require({name: hashlib.sha256(data).hexdigest() for name, data in initial.items()} == frozen,
            "fixture-source-changed")
    current = dict(initial)
    header = "Sources/BridgeKit/include/CGCore.h"
    renamed = header.replace("CGCore.h", "RenamedCore.h")
    legacy = "Sources/AppFlow/Legacy.swift"
    relocated = legacy.replace("Legacy.swift", "Relocated.swift")
    for name, operation, _, _ in STAGE_PLAN:
        if operation == "edit_header":
            for symbol in ("CGHeaderRoute", "CGHeaderCppRoute"):
                old = f"{symbol}(int value) {{\n    return CGBase(value);".encode()
                require(current[header].count(old) == 1, "mutation-anchor-mismatch")
                current[header] = current[header].replace(old, old.replace(b"CGBase", b"CGAlternate"))
        elif operation == "rename_header":
            current[renamed] = current.pop(header)
            for relative in ("Sources/BridgeKit/Core.m", "Sources/BridgeKit/CppBridge.mm",
                             "Sources/BridgeKit/ObjCQuote.m", "Sources/BridgeKit/include/BridgeKit.h"):
                require(current[relative].count(b'"CGCore.h"') == 1, "mutation-anchor-mismatch")
                current[relative] = current[relative].replace(b'"CGCore.h"', b'"RenamedCore.h"')
        elif operation == "delete_header":
            del current[renamed]
        elif operation == "rename_swift":
            current[relocated] = current.pop(legacy)
        elif operation == "delete_swift":
            del current[relocated]
        elif operation == "restore":
            current = dict(initial)
        if name == stage:
            return {relative: hashlib.sha256(data).hexdigest() for relative, data in sorted(current.items())}
    raise GenerationError("unexpected-generation-stage")


def source_identity(project: Path, stage: str) -> dict:
    """허용하지 않은 파일·링크도 빠뜨리지 않는 전체 소스/설정 인벤토리를 남긴다."""
    seal = SEAL.capture({"PROJECT": project})
    require(all(row["type"] in {"file", "directory"} for row in seal["entries"]), "source-link-not-allowed")
    files = {row["path"]: row["sha256"] for row in seal["entries"] if row["type"] == "file"}
    require(files == expected_sources(stage), "generation-source-mismatch")
    directories = {"."} | {str(parent) for name in files for parent in Path(name).parents}
    require({row["path"] for row in seal["entries"] if row["type"] == "directory"} == directories,
            "generation-source-directories-mismatch")
    return seal


def normalize_commands(commands: list, state: dict, setup: dict) -> list:
    """명령의 순서/전체 필드는 보존하고 검증한 완전 경로 접두사만 토큰화한다."""
    attempt = state["generation_attempt"]
    aliases = {state["project"]: "$PROJECT", attempt["store"]: "$STORE", attempt["build"]: "$BUILD",
               setup["sdk_path"]: "$SDK"}
    tools = {setup["swiftc"]: "$SWIFTC", setup["clang"]: "$CLANG"}

    def replace(value):
        if isinstance(value, dict):
            return {replace(key): replace(item) for key, item in value.items()}
        if isinstance(value, list):
            return [replace(item) for item in value]
        if isinstance(value, str):
            if value in tools:
                return tools[value]
            for prefix, token in sorted(aliases.items(), key=lambda item: -len(item[0])):
                if value == prefix or value.startswith(prefix + "/"):
                    return token + value[len(prefix):]
        return value

    return replace(commands)



def validate_command_budget(record: dict):
    """시작 시 남은 전체 예산과 원래 제한을 원본 실제 시간에 연결한다."""
    names = ("wall_seconds", "requested_timeout_seconds", "lifecycle_remaining_at_launch_seconds",
             "lifecycle_elapsed_at_launch_seconds")
    require(all(type(record.get(key)) in (int, float) and math.isfinite(record[key]) for key in names),
            "invalid-command-budget")
    wall, bound, remaining, elapsed = (record[key] for key in names)
    require(0 <= wall <= bound and 0 < remaining <= 1200 and 0 <= elapsed < 1200
            and abs(elapsed + remaining - 1200) <= 1e-6 and bound == min(300.0, remaining),
            "command-budget-mismatch")


def validate_builds(stage: str, commands: list, builds: list, project: Path) -> str:
    """미완료와 정상 양수 실패를 나누고 실행 순서/추가/누락을 모두 거부한다."""
    require(isinstance(builds, list) and bool(builds), "missing-compiler-records")
    for record in builds:
        validate_command_budget(record)
        code = record.get("exit_code")
        require(type(code) is int and code >= 0 and code != 125, "incomplete-compiler-process")
        elapsed = record.get("wall_seconds")
        require(type(elapsed) in (float, int) and math.isfinite(elapsed) and elapsed >= 0, "invalid-compiler-cost")
    expected_count = 1 if stage == "header_delete_build_failed" else 6
    require(len(commands) == 6 and len(builds) == expected_count, "compiler-command-count-mismatch")
    for command, record in zip(commands, builds):
        require(record.get("command") == command["args"] and record.get("cwd") == str(project),
                "compiler-command-mismatch")
    if stage == "header_delete_build_failed":
        require(commands[0]["name"] == "clang-Core.m" and builds[0]["exit_code"] > 0,
                "expected-header-failure-missing")
        diagnostic = SELECTOR.file_identity(Path(builds[0]["stderr"]), SELECTOR.MAX_TEXT_BYTES, True)["text"]
        require("RenamedCore.h" in diagnostic and "file not found" in diagnostic, "expected-header-diagnostic-missing")
        return "expected-positive-missing-header-failure"
    require(all(row["exit_code"] == 0 for row in builds), "unexpected-compiler-failure")
    return "completed-success"


def setup_commands(setup: dict) -> list:
    """원래 설정의 11개 실제 명령을 유지하고 누락/대체 프로브를 거부한다."""
    sdk = "iphonesimulator"
    return [
        ("sdk-path", ["xcrun", "--sdk", sdk, "--show-sdk-path"]),
        ("platform-path", ["xcrun", "--sdk", sdk, "--show-sdk-platform-path"]),
        ("swiftc-path", ["xcrun", "--find", "swiftc"]),
        ("clang-path", ["xcrun", "--find", "clang"]),
        ("swift-help", [setup["swiftc"], "-help"]),
        ("clang-frontend-help", [setup["clang"], "-cc1", "--help"]),
        ("sdk-version", ["xcrun", "--sdk", sdk, "--show-sdk-version"]),
        ("sdk-build", ["xcrun", "--sdk", sdk, "--show-sdk-build-version"]),
        ("xcode-version", ["xcodebuild", "-version"]),
        ("swift-version", [setup["swiftc"], "--version"]),
        ("clang-version", [setup["clang"], "--version"]),
    ]


def prepare(request_path: Path, request_sha256: str, output: Path, setup: dict, *, deadline=None):
    """기존 11개 설정 프로브를 보존한 뒤 실제 선택값을 최초 후보와 비교한다."""
    request = validate_request(request_path, request_sha256)
    validate_setup(request, output, setup, deadline=deadline)
    return Session(request, request_path, request_sha256, output, setup, deadline=deadline)



def validate_setup(request, output, setup, *, deadline=None):
    """수명 주기와 발행자가 동일한 선택값 및 11개 원본 프로브를 확인한다."""
    native = request["candidate"]["native"]
    selected, versions = native["selected"], native["versions"]
    expected = dict(requested_sdk="iphonesimulator", sdk_path=selected["sdk"], swiftc=selected["tools"]["swift"],
                    clang=selected["tools"]["clang"], library=selected["tools"]["index_library"],
                    sdk_version=versions["sdk_version"], sdk_build=versions["sdk_build"], xcode=versions["xcode"],
                    swift_version=versions["swift"], developer_dir=request_environment(request)["DEVELOPER_DIR"],
                    target_triple="arm64-apple-ios16.0-simulator", compiler_index_policy="fresh-shared-v2")
    require(setup.get("status") == "selected" and all(setup.get(key) == value for key, value in expected.items()),
            "generation-setup-mismatch")
    platform = Path(selected["sdk"]).parents[2]
    require(Path(setup["platform_path"]).resolve(strict=True) == platform.resolve(strict=True),
            "generation-platform-mismatch")
    for name, argv in setup_commands(setup):
        stem = output / "setup" / name
        raw = SELECTOR.file_identity(stem.with_suffix(".json"), SELECTOR.MAX_TEXT_BYTES, True)
        row = SELECTOR.strict_json(raw["text"])
        validate_command_budget(row)
        require(row.get("command") == argv and row.get("cwd") == str(output)
                and type(row.get("exit_code")) is int and row["exit_code"] == 0
                and row.get("stdout") == str(stem.with_suffix(".stdout"))
                and row.get("stderr") == str(stem.with_suffix(".stderr")), "generation-setup-probe-mismatch")
        if deadline:
            deadline.check()

class Session:
    """고정된 13개 상태만 진행하며 모든 중단을 원본 경계 영수증에 남긴다."""

    def __init__(self, request, request_path, request_sha256, output, setup, *, deadline=None):
        self.request, self.request_path, self.request_sha256 = request, request_path, request_sha256
        self.output, self.setup = output.resolve(), setup
        self.deadline = deadline
        self.root = Path(request["evidence_root"])
        self.expected, _ = NATIVE.expectation()
        NATIVE.evidence_boundary(self.root, self.expected)
        require(self.root.is_absolute() and self.root.resolve() == self.root, "generation-evidence-alias")
        require(not self.root.is_relative_to(self.output) and not self.output.is_relative_to(self.root),
                "generation-evidence-overlap")
        (self.root / "generations").mkdir(exist_ok=False)
        self.position, self.active, self.records, self.originals = 0, None, [], []
        self.baseline = validate_candidate(request["candidate"], self.expected)
        self.summary = dict(schema_version=1, status="running", accepted=False, final_protocol_ready=False,
                            request_sha256=request_sha256, full_generation_reads=0, planned_commands=0,
                            executed_commands=0, stages=self.records, limitations=LIMITATIONS,
                            normalization_recipe=NORMALIZATION_RECIPE, original_files=self.originals,
                            lifecycle_output=str(self.output))
        self.save()

    def save(self):
        """부분 실행도 마지막 성공과 미실시 경계를 같은 원본에 남긴다."""
        COMMON.save(self.root / "generation-results.json", self.summary)

    def retain_file(self, source, destination):
        """원래 바이트를 복사하고 원본/복사본 모두의 크기와 해시를 연결한다."""
        source, destination = Path(source), Path(destination)
        existing = next((row for row in self.originals if row["original_path"] == str(source)), None)
        if existing:
            require(SELECTOR.file_identity(source) == existing["identity"], "generation-original-changed")
            return
        row = dict(original_path=str(source), copied_path=str(destination), status="unavailable")
        self.originals.append(row)
        try:
            original = SELECTOR.file_identity(source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            require(not destination.exists(), "generation-original-copy-exists")
            shutil.copyfile(source, destination)
            copied = SELECTOR.file_identity(destination)
            require(SELECTOR.file_identity(source) == original
                    and all(copied[key] == original[key] for key in ("sha256", "bytes")),
                    "generation-original-copy-changed")
            row.update(status="bound", identity=original, copied_identity=copied)
        except BaseException as error:
            row.update(failure=str(error), failure_type=type(error).__name__)
            raise
        finally:
            self.save()

    def retain_commands(self, stage, commands, state):
        """완료·실패·미완료 시도 모두의 고정 명령 로그 원본을 보존한다."""
        for command, record in zip(commands, state["builds"]):
            name = command["name"]
            stem = self.output / "runs" / stage / name
            require(record.get("stdout") == str(stem.with_suffix(".stdout"))
                    and record.get("stderr") == str(stem.with_suffix(".stderr")), "compiler-log-path-mismatch")
            for suffix in (".json", ".stdout", ".stderr"):
                self.retain_file(stem.with_suffix(suffix),
                                 self.root / "generations" / stage / "commands" / (name + suffix))

    def finalize_originals(self):
        """최종 직렬화가 끝난 수명 주기와 실제 설정 프로브 원본을 고정한다."""
        paths = [self.request_path, self.output / "results.json", self.output / "setup/setup.json"]
        for name, _ in setup_commands(self.setup):
            paths.extend(self.output / "setup" / (name + suffix) for suffix in (".json", ".stdout", ".stderr"))
        for stage, _, build, _ in STAGE_PLAN:
            state = self.output / "runs" / stage / "state.json"
            if state.exists():
                paths.append(state)
                if build:
                    plan = state.with_name("commands.json")
                    if plan.exists():
                        paths.append(plan)
        for path in paths:
            relative = "request.json" if path == self.request_path else str(path.relative_to(self.output))
            self.retain_file(path, self.root / "lifecycle-originals" / relative)
        self.summary["originals_finalized"] = True
        self.save()
        return self.summary

    def check_stage(self, stage, state, building):
        require(self.active is None and self.position < len(STAGE_PLAN), "generation-stage-order-mismatch")
        row = STAGE_PLAN[self.position]
        require(row[0] == stage and bool(row[2]) == building and state["name"] == stage,
                "generation-stage-order-mismatch")
        require(state["project"] == str(self.output / "Project") and state["builds"] == [],
                "unexpected-stage-processes")
        require(state["execution"] == "executed" and state["product_checks"] == "not-run"
                and state["compiler_index_policy"] == "fresh-shared-v2", "generation-mode-mismatch")
        require(state["expected_build"] == (row[2] or "not-run") and state["oracle_variant"] == row[3]
                and state["sdk"] == "iphonesimulator" and state["triple"] == self.setup["target_triple"],
                "generation-stage-contract-mismatch")
        return row

    def context(self):
        if self.deadline:
            self.deadline.check()
        validate_request(self.request_path, self.request_sha256)
        result = NATIVE.selected_layout(self.expected, self.request["candidate"]["native"]["selected"])
        if self.deadline:
            self.deadline.check()
        return result

    def boundary(self, stage, side, state, commands):
        started = time.perf_counter()
        directory = self.root / "generations" / stage / side
        directory.mkdir(parents=True, exist_ok=False)
        result = dict(schema_version=1, status="failed", accepted=False, final_protocol_ready=False,
                      stage=stage, boundary=side, content_sha256=BASELINE_SHA256,
                      expectation_sha256=EXPECTATION_SHA256, request_sha256=self.request_sha256,
                      verification_path=str(directory / "seal-verification.json"), full_read_completed=False,
                      command_plan=commands, commands_sha256=identity(commands),
                      normalized_commands=normalize_commands(commands, state, self.setup),
                      normalization_recipe=NORMALIZATION_RECIPE, limitations=LIMITATIONS)
        result["normalized_commands_sha256"] = identity(result["normalized_commands"])
        try:
            layout = self.context()
            result["layout"] = layout
            require(layout == self.request["candidate"]["native"]["layout"], "generation-aliases-changed")
            verification = SEAL.verify(self.baseline, {key: Path(value) for key, value in layout["roots"].items()})
            if self.deadline:
                self.deadline.check()
            NATIVE.write_manifest(directory / "seal-verification.json", verification)
            result.update(full_read_completed=True, verification_manifest_sha256=identity(verification))
            self.summary["full_generation_reads"] += 1
            require(verification["matches"] is True, "generation-sdk-content-changed")
            require(self.context() == layout, "generation-aliases-changed")
            result["sources"] = source_identity(Path(state["project"]), stage)
            if side == "after":
                result["generated_outputs"] = SEAL.capture({
                    "BUILD": Path(state["generation_attempt"]["build"]),
                    "INDEX": Path(state["generation_attempt"]["store"]),
                })
            if self.deadline:
                self.deadline.check()
            result["status"] = "verified-candidate"
        except BaseException as error:
            result.update(status="incomplete" if isinstance(error, KeyboardInterrupt)
                          or (self.deadline and self.deadline.expired) else "failed",
                          failure=str(error), failure_type=type(error).__name__)
            raise
        finally:
            result["wall_seconds"] = time.perf_counter() - started
            result["charged_wall_seconds_by_arm"] = {arm: result["wall_seconds"] for arm in ARMS}
            result["cost_scope"] = "Nested boundary diagnostic; included in full generation preparation, not added again"
            COMMON.save(directory / "results.json", result)
            state.setdefault("sdk_generation", {})[side] = result
            self.save()
        return result

    def before(self, stage, commands, state):
        self.check_stage(stage, state, True)
        attempt = state["generation_attempt"]
        require(attempt["store"] == str(self.output / "Generations" / stage / "IndexStore")
                and attempt["build"] == str(self.output / "Generations" / stage / "Build"),
                "generation-output-path-mismatch")
        expected = COMMON.command_plan(Path(state["project"]), Path(attempt["store"]), Path(attempt["build"]),
                                       self.setup["sdk_path"], self.setup["target_triple"], self.setup["swiftc"],
                                       self.setup["clang"], self.setup["platform_path"], False)
        require(commands == expected and len(commands) == 6, "generation-command-plan-mismatch")
        self.active = stage
        self.active_commands = commands
        self.summary["planned_commands"] += len(commands)
        return self.boundary(stage, "before", state, commands)

    def after(self, stage, commands, state):
        require(self.active == stage, "generation-stage-order-mismatch")
        builds = state["builds"]
        self.retain_commands(stage, commands, state)
        require(builds and all(type(row.get("exit_code")) is int and row["exit_code"] >= 0
                              and row["exit_code"] != 125 for row in builds), "incomplete-compiler-process")
        result = self.boundary(stage, "after", state, commands)
        outcome = validate_builds(stage, commands, builds, Path(state["project"]))
        require(result["sources"]["content_sha256"] == state["sdk_generation"]["before"]["sources"]["content_sha256"],
                "generation-source-changed-during-build")
        state["sdk_generation"].update(status="verified-candidate", outcome=outcome,
                                       compiler_records_sha256=identity(builds), compiler_records=builds)
        self.records.append(dict(stage=stage, kind="build", status="verified-candidate", outcome=outcome,
                                 planned_commands=6, executed_commands=len(builds),
                                 before=str(self.root / "generations" / stage / "before/results.json"),
                                 after=str(self.root / "generations" / stage / "after/results.json")))
        self.summary["executed_commands"] += len(builds)
        self.active, self.position = None, self.position + 1
        self.save()
        return result

    def source_only(self, stage, state):
        self.check_stage(stage, state, False)
        require(state["generation_attempt"] is None, "source-only-generation-attempt")
        self.context()
        source = source_identity(Path(state["project"]), stage)
        state["sdk_generation"] = dict(status="source-only-no-build", compiler_records=[], sources=source)
        self.records.append(dict(stage=stage, kind="source-only", status="source-only-no-build",
                                 planned_commands=0, executed_commands=0))
        self.position += 1
        self.save()

    def fail(self, stage, state, error):
        """미실시 후검사를 성공으로 올리지 않고 모든 부분 컴파일 결과를 남긴다."""
        record = state.setdefault("sdk_generation", {})
        builds = state["builds"]
        if stage == self.active and hasattr(self, "active_commands") and len(builds) < len(self.active_commands):
            next_command = self.active_commands[len(builds)]
            expected_record = (self.output / "runs" / stage / next_command["name"]).with_suffix(".json")
            if state.get("command_record") == str(expected_record):
                try:
                    raw = SELECTOR.file_identity(expected_record, SELECTOR.MAX_TEXT_BYTES, True)
                    interrupted = SELECTOR.strict_json(raw["text"])
                    require(interrupted.get("command") == next_command["args"], "compiler-command-mismatch")
                    builds.append(interrupted)
                except Exception as retention_error:
                    record["unfinished_command_record"] = dict(path=str(expected_record), status="unavailable",
                                                              failure=str(retention_error))
        incomplete = isinstance(error, KeyboardInterrupt) or (self.deadline and isinstance(error, self.deadline.error_type)) or any(
            type(row.get("exit_code")) is not int or row["exit_code"] < 0 or row["exit_code"] == 125 for row in builds)
        record.update(status="incomplete" if incomplete else "failed", compiler_records=builds,
                      postcheck_certified=bool(record.get("after", {}).get("status") == "verified-candidate")
                      and not incomplete, failure=str(error))
        if stage == self.active and hasattr(self, "active_commands"):
            try:
                self.retain_commands(stage, self.active_commands, state)
            except Exception as retention_error:
                record["original_retention_failure"] = str(retention_error)
        if "after" not in record and stage in BUILD_STAGES:
            record["after"] = dict(status="unavailable", full_read_completed=False,
                                   reason="incomplete-process" if incomplete else "generation-aborted-before-postcheck")
            directory = self.root / "generations" / stage / "after"
            directory.mkdir(parents=True, exist_ok=True)
            COMMON.save(directory / "results.json", record["after"])
        self.summary.update(status=record["status"], failed_stage=stage, failure=str(error),
                            incomplete_compiler_records=builds)
        self.save()

    def finish(self, states):
        require(self.position == len(STAGE_PLAN) and self.active is None, "missing-generation-stages")
        require(self.summary["full_generation_reads"] == 16 and self.summary["planned_commands"] == 48
                and self.summary["executed_commands"] == 43, "generation-count-mismatch")
        require([state["name"] for state in states] == [row[0] for row in STAGE_PLAN], "generation-state-order-mismatch")
        for state in states:
            cost = state["shared_input_cost"]
            require(cost["charged_wall_seconds_by_arm"] == {arm: cost["wall_seconds"] for arm in ARMS},
                    "generation-shared-cost-mismatch")
            bracket = state["sdk_generation"]
            if state["name"] in BUILD_STAGES:
                nested = sum(bracket[side]["wall_seconds"] for side in ("before", "after"))
                require(cost["wall_seconds"] >= nested + cost["compiler_subprocess_wall_seconds"],
                        "generation-cost-interval-mismatch")
                attempt = state["generation_attempt"]
                outputs = bracket["after"]["generated_outputs"]["entries"]
                for root, key in (("BUILD", "build_files"), ("INDEX", "index_files")):
                    files = {row["path"]: row["sha256"] for row in outputs
                             if row["root"] == root and row["type"] == "file"}
                    require(files == attempt[key], "generation-output-seal-mismatch")
                require(attempt["source_files"] == expected_sources(state["name"]), "generation-source-mismatch")
                if state["name"] == "header_delete_build_failed":
                    require(attempt["status"] == "rejected" and state["accepted_generation"]["id"]
                            == "header_rename_rebuilt", "failed-generation-predecessor-mismatch")
                else:
                    require(attempt["status"] == "accepted" and state["accepted_generation"]["id"] == state["name"],
                            "generation-acceptance-mismatch")
                    commands = bracket["before"]["command_plan"]
                    require(attempt["commands_sha256"] == hashlib.sha256(
                        json.dumps(commands, sort_keys=True).encode()).hexdigest(), "generation-command-seal-mismatch")
        self.summary.update(status="verified-candidate", lifecycle_states_sha256=identity(states),
                            total_full_reads_with_parent_capture_and_final=18,
                            cost_scope="Parent lifecycle child interval includes serialization/teardown; detailed intervals overlap")
        self.save()
        return self.summary


def verify_originals(summary: dict) -> dict:
    """발행 전후에 고정 원본 경로와 복사본을 다시 읽되 어떤 명령도 실행하지 않는다."""
    require(summary.get("accepted") is False and summary.get("final_protocol_ready") is False
            and summary.get("status") in ("verified-candidate", "failed", "incomplete"), "generation-summary-status")
    require(summary.get("originals_finalized") is True, "generation-originals-not-finalized")
    rows = summary.get("original_files")
    require(isinstance(rows, list) and bool(rows), "generation-originals-missing")
    request_rows = [row for row in rows if row["copied_path"].endswith("/lifecycle-originals/request.json")]
    require(len(request_rows) == 1, "generation-original-request-missing")
    request_row = request_rows[0]
    raw = SELECTOR.file_identity(Path(request_row["original_path"]), SELECTOR.MAX_TEXT_BYTES, True)
    require(raw["sha256"] == summary["request_sha256"], "generation-request-sha256-mismatch")
    request = validate_request(Path(request_row["original_path"]), summary["request_sha256"], current_environment=False)
    lifecycle, evidence = Path(summary["lifecycle_output"]), Path(request["evidence_root"])
    allowed = {str(Path(request_row["original_path"])): str(evidence / "lifecycle-originals/request.json")}
    fixed = ["results.json", "setup/setup.json"]
    setup_raw = SELECTOR.file_identity(lifecycle / "setup/setup.json", SELECTOR.MAX_TEXT_BYTES, True)
    setup = SELECTOR.strict_json(setup_raw["text"])
    validate_setup(request, lifecycle, setup)
    for name, _ in setup_commands(setup):
        fixed.extend("setup/" + name + suffix for suffix in (".json", ".stdout", ".stderr"))
    missing, states = False, []
    for stage, _, building, _ in STAGE_PLAN:
        path = lifecycle / "runs" / stage / "state.json"
        if not path.exists():
            missing = True
            continue
        require(not missing, "generation-state-order-mismatch")
        fixed.append(str(path.relative_to(lifecycle)))
        state = SELECTOR.strict_json(SELECTOR.file_identity(path, SELECTOR.MAX_TEXT_BYTES, True)["text"])
        states.append(state)
        builds = state["builds"]
        if building:
            plan = path.with_name("commands.json")
            if not plan.exists():
                require(not builds, "missing-generation-command-plan")
                continue
            fixed.append(str(plan.relative_to(lifecycle)))
            commands = SELECTOR.strict_json(SELECTOR.file_identity(plan, SELECTOR.MAX_TEXT_BYTES, True)["text"])
            require(isinstance(commands, list) and len(commands) == 6 and len(builds) <= 6,
                    "compiler-command-count-mismatch")
            for command, record in zip(commands, builds):
                require(record["command"] == command["args"], "compiler-command-mismatch")
                for suffix in (".json", ".stdout", ".stderr"):
                    original = (path.parent / command["name"]).with_suffix(suffix)
                    copied = evidence / "generations" / stage / "commands" / (command["name"] + suffix)
                    allowed[str(original)] = str(copied)
        else:
            require(builds == [] and state["generation_attempt"] is None, "unexpected-stage-processes")
    for relative in fixed:
        allowed[str(lifecycle / relative)] = str(evidence / "lifecycle-originals" / relative)
    require({row["original_path"]: row["copied_path"] for row in rows} == allowed,
            "generation-original-membership-mismatch")
    originals, copies = set(), set()
    for row in rows:
        original, copied = Path(row["original_path"]), Path(row["copied_path"])
        require(str(original) not in originals and str(copied) not in copies, "duplicate-generation-original")
        originals.add(str(original))
        copies.add(str(copied))
        require(row["status"] == "bound" and (original == Path(request_row["original_path"])
                or original.is_relative_to(lifecycle)) and copied.is_relative_to(evidence),
                "generation-original-path-mismatch")
        require(SELECTOR.file_identity(original) == row["identity"]
                and SELECTOR.file_identity(copied) == row["copied_identity"]
                and all(row["identity"][key] == row["copied_identity"][key] for key in ("sha256", "bytes")),
                "generation-original-changed")
    semantic = regrade_states(summary, states, setup, request)
    lifecycle_result = retained_document(lifecycle / "results.json")
    if summary["status"] == "verified-candidate":
        require(lifecycle_result["status"] == "passed" and lifecycle_result["ios_execution"] == "compiler-only"
                and lifecycle_result["observation_failures"] == [] and lifecycle_result["runtime_execution"] == "not-run"
                and identity(lifecycle_result["states"]) == identity(states), "generation-lifecycle-result-binding")
        stable = {key: value for key, value in summary.items() if key not in ("original_files", "originals_finalized")}
        earlier = {key: value for key, value in lifecycle_result["sdk_generation"].items()
                   if key not in ("original_files", "originals_finalized")}
        require(identity(stable) == identity(earlier), "generation-lifecycle-summary-binding")
    return dict(status="verified-candidate", accepted=False, final_protocol_ready=False,
                originals_sha256=identity(rows), original_file_count=len(rows), semantic=semantic,
                runtime_closure_proven=False)


def frozen_command_plan(
    project: Path,
    store: Path,
    build: Path,
    sdk: str,
    triple: str,
    swiftc: str,
    clang: str,
    platform: str,
    stage: str,
    with_tests: bool = False,
) -> list[dict]:
    """고정 원본 recipe를 현재 디스크 glob 없이 과거 세대의 파일 집합에 적용한다."""
    require(with_tests is False, "unexpected-test-compiler-plan")
    include = project / "Sources/BridgeKit/include"
    modules = build / "modules"
    common = ["-target", triple, "-isysroot", sdk, "-I", str(include), "-O0", "-g", "-index-store-path", str(store)]
    result = []
    for filename in ["Core.m", "CppBridge.mm", "ObjCQuote.m"]:
        source = project / "Sources/BridgeKit" / filename
        obj = build / "BridgeKit" / (filename + ".o")
        args = [clang, *common]
        if filename.endswith(".mm"):
            args += ["-std=c++17"]
        if filename == "ObjCQuote.m":
            args += ["-fobjc-arc"]
        args += ["-MD", "-MF", str(obj.with_suffix(".d")), "-c", str(source), "-o", str(obj)]
        result.append(dict(name="clang-" + filename, args=args, outputs=[str(obj)], source_paths=[str(source)]))
    groups = [
        ("FeatureAlpha", [project / "Sources/Shared/SharedCalls.swift"]),
        ("FeatureBeta", [project / "Sources/Shared/SharedCalls.swift"]),
        ("AppFlow", [project / name for name in sorted(expected_sources(stage))
                     if name.startswith("Sources/AppFlow/") and name.endswith(".swift")]),
    ]
    if with_tests:
        groups.append(("FixtureTests", [project / "Tests/FixtureTests.swift"]))
    for module, sources in groups:
        output_map = {str(s): {"object": str(build / module / (s.name + ".o"))} for s in sources}
        mapping_path = build / module / "output-file-map.json"
        args = [
            swiftc,
            "-target",
            triple,
            "-sdk",
            sdk,
            "-parse-as-library",
            "-Onone",
            "-g",
            "-module-name",
            module,
            "-I",
            str(include),
            "-I",
            str(modules),
            "-module-cache-path",
            str(build / "module-cache"),
            "-index-store-path",
            str(store),
            "-emit-object",
            "-emit-module",
            "-emit-module-path",
            str(modules / (module + ".swiftmodule")),
            "-output-file-map",
            str(mapping_path),
        ]
        if module == "FixtureTests":
            args += [
                "-F",
                str(Path(platform) / "Developer/Library/Frameworks"),
                "-I",
                str(Path(platform) / "Developer/usr/lib"),
            ]
        args += [str(s) for s in sources]
        result.append(
            dict(
                name="swift-" + module,
                args=args,
                output_file_map=output_map,
                output_map_path=str(mapping_path),
                source_paths=[str(s) for s in sources],
                outputs=[v["object"] for v in output_map.values()],
            )
        )
    return result


def retained_document(path: Path) -> dict:
    return SELECTOR.strict_json(SELECTOR.file_identity(path, SELECTOR.MAX_TEXT_BYTES, True)["text"])


def source_seal(seal: dict, project: Path, stage: str):
    SEAL.validate_expected(seal)
    require(seal["roots"] == {"PROJECT": str(project)} and all(
        row["type"] in ("directory", "file") and row["root"] == "PROJECT" for row in seal["entries"]),
        "generation-source-seal-schema")
    files = {row["path"]: row["sha256"] for row in seal["entries"] if row["type"] == "file"}
    require(files == expected_sources(stage), "generation-source-mismatch")
    directories = {"."} | {str(parent) for name in files for parent in Path(name).parents}
    require({row["path"] for row in seal["entries"] if row["type"] == "directory"} == directories,
            "generation-source-directories-mismatch")


def finite_cost(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def regrade_states(summary, states, setup, request):
    """최종 원본에서 상태/명령/봉인/비용을 다시 결합하며 전체 SDK를 다시 읽지 않는다."""
    lifecycle, evidence = Path(summary["lifecycle_output"]), Path(request["evidence_root"])
    project = lifecycle / "Project"
    require(isinstance(states, list) and 0 < len(states) <= len(STAGE_PLAN)
            and [state["name"] for state in states] == [row[0] for row in STAGE_PLAN[:len(states)]],
            "generation-state-order-mismatch")
    complete = summary["status"] == "verified-candidate"
    require(not complete or len(states) == len(STAGE_PLAN), "generation-state-count")
    counts = dict(full_generation_reads=0, planned_commands=0, executed_commands=0)
    records, accepted = [], None
    for position, state in enumerate(states):
        stage, operation, building, variant = STAGE_PLAN[position]
        passed = state["status"] == "passed"
        require(passed or (not complete and position == len(states) - 1), "generation-state-status")
        require(state["project"] == str(project) and state["compiler_index_policy"] == "fresh-shared-v2"
                and state["execution"] == "executed" and state["product_checks"] == "not-run"
                and state["expected_build"] == (building or "not-run") and state["oracle_variant"] == variant,
                "generation-state-contract-mismatch")
        builds = state["builds"]
        bracket = state.get("sdk_generation", {})
        if not building:
            require(builds == [] and state["generation_attempt"] is None, "unexpected-stage-processes")
            if passed:
                require(bracket["status"] == "source-only-no-build" and bracket["compiler_records"] == [],
                        "source-only-binding")
                source_seal(bracket["sources"], project, stage)
                records.append(dict(stage=stage, kind="source-only", status="source-only-no-build",
                                    planned_commands=0, executed_commands=0))
        else:
            attempt = state["generation_attempt"]
            plan_path = lifecycle / "runs" / stage / "commands.json"
            if attempt is None or not plan_path.exists():
                require(not passed and builds == [] and not any(
                    side in bracket and bracket[side].get("full_read_completed") is True for side in ("before", "after")),
                    "unstarted-generation-has-work")
                require(not plan_path.exists(), "unstarted-generation-has-plan")
                continue
            require(attempt["id"] == stage and attempt["store"] == str(lifecycle / "Generations" / stage / "IndexStore")
                    and attempt["build"] == str(lifecycle / "Generations" / stage / "Build"), "generation-output-path-mismatch")
            commands = frozen_command_plan(project, Path(attempt["store"]), Path(attempt["build"]), setup["sdk_path"],
                setup["target_triple"], setup["swiftc"], setup["clang"], setup["platform_path"], stage)
            plan_path = lifecycle / "runs" / stage / "commands.json"
            require(identity(retained_document(plan_path)) == identity(commands), "generation-command-plan-mismatch")
            counts["planned_commands"] += 6
            require(type(builds) is list and len(builds) <= 6, "compiler-command-count-mismatch")
            for command, row in zip(commands, builds):
                stem = lifecycle / "runs" / stage / command["name"]
                require(identity(retained_document(stem.with_suffix(".json"))) == identity(row)
                        and row["command"] == command["args"] and row["cwd"] == str(project)
                        and row["stdout"] == str(stem.with_suffix(".stdout"))
                        and row["stderr"] == str(stem.with_suffix(".stderr")), "compiler-original-binding")
            for side in ("before", "after"):
                path = evidence / "generations" / stage / side / "results.json"
                if not path.exists():
                    require(not passed, "missing-generation-boundary")
                    continue
                boundary = retained_document(path)
                require(identity(boundary) == identity(bracket[side]), "generation-boundary-state-binding")
                verification_path = path.with_name("seal-verification.json")
                if not verification_path.exists():
                    require(not passed and boundary["status"] != "verified-candidate", "missing-generation-verification")
                    continue
                verification = SEAL.strict_expected_json(SEAL.expected_bytes(verification_path))
                SEAL.validate_expected(verification["actual"])
                require(identity(verification) == boundary["verification_manifest_sha256"]
                        and boundary["verification_path"] == str(verification_path)
                        and boundary["full_read_completed"] is True
                        and verification["expected_sha256"] == BASELINE_SHA256
                        and verification["actual_sha256"] == verification["actual"]["content_sha256"]
                        and type(verification["matches"]) is bool
                        and verification["matches"] == (verification["actual_sha256"] == BASELINE_SHA256),
                        "generation-verification-binding")
                counts["full_generation_reads"] += 1
                require(boundary["stage"] == stage and boundary["boundary"] == side
                        and boundary["accepted"] is False and boundary["final_protocol_ready"] is False
                        and boundary["request_sha256"] == summary["request_sha256"]
                        and boundary["expectation_sha256"] == EXPECTATION_SHA256
                        and boundary["content_sha256"] == BASELINE_SHA256
                        and identity(boundary["command_plan"]) == identity(commands)
                        and boundary["commands_sha256"] == identity(commands)
                        and boundary["normalization_recipe"] == NORMALIZATION_RECIPE
                        and boundary["normalized_commands"] == normalize_commands(commands, state, setup)
                        and boundary["normalized_commands_sha256"] == identity(boundary["normalized_commands"])
                        and identity(boundary["layout"]) == identity(request["candidate"]["native"]["layout"])
                        and verification["actual"]["roots"] == boundary["layout"]["roots"], "generation-boundary-binding")
                require(finite_cost(boundary["wall_seconds"]) and identity(boundary["charged_wall_seconds_by_arm"])
                        == identity({arm: boundary["wall_seconds"] for arm in ARMS}), "generation-boundary-cost")
                if passed:
                    require(boundary["status"] == "verified-candidate" and verification["matches"] is True,
                            "generation-boundary-incomplete")
                    source_seal(boundary["sources"], project, stage)
            if passed:
                outcome = validate_builds(stage, commands, builds, project)
                require(bracket["status"] == "verified-candidate" and bracket["outcome"] == outcome
                        and bracket["compiler_records_sha256"] == identity(builds)
                        and identity(bracket["compiler_records"]) == identity(builds), "compiler-result-binding")
                require(bracket["before"]["sources"]["content_sha256"] == bracket["after"]["sources"]["content_sha256"],
                        "generation-source-changed-during-build")
                outputs = bracket["after"]["generated_outputs"]
                SEAL.validate_expected(outputs)
                require(outputs["roots"] == {"BUILD": attempt["build"], "INDEX": attempt["store"]}, "generation-output-roots")
                for root, key in (("BUILD", "build_files"), ("INDEX", "index_files")):
                    require({row["path"]: row["sha256"] for row in outputs["entries"]
                             if row["root"] == root and row["type"] == "file"} == attempt[key], "generation-output-seal-mismatch")
                require(attempt["source_files"] == expected_sources(stage)
                        and attempt["toolchain_files"] == setup["compiler_toolchain_files"], "generation-input-seal-mismatch")
                counts["executed_commands"] += len(builds)
                if building == "success":
                    require(attempt["status"] == "accepted" and attempt["commands_sha256"] == hashlib.sha256(
                        json.dumps(commands, sort_keys=True).encode()).hexdigest(), "generation-acceptance-mismatch")
                    accepted = attempt
                else:
                    require(attempt["status"] == "rejected" and accepted is not None
                            and accepted["id"] == "header_rename_rebuilt", "failed-generation-predecessor-mismatch")
                records.append(dict(stage=stage, kind="build", status="verified-candidate", outcome=outcome,
                                    planned_commands=6, executed_commands=len(builds),
                                    before=str(evidence / "generations" / stage / "before/results.json"),
                                    after=str(evidence / "generations" / stage / "after/results.json")))
        if passed:
            require(accepted is not None and identity(state["accepted_generation"]) == identity(accepted)
                    and state["index_files"] == accepted["index_files"]
                    and state["current_sources"] == expected_sources(stage), "generation-current-state-binding")
            cost = state["shared_input_cost"]
            require(cost["status"] == "measured" and finite_cost(cost["wall_seconds"])
                    and finite_cost(cost["compiler_subprocess_wall_seconds"])
                    and cost["compiler_subprocess_wall_seconds"] == sum(row["wall_seconds"] for row in builds)
                    and identity(cost["charged_wall_seconds_by_arm"]) == identity({arm: cost["wall_seconds"] for arm in ARMS}),
                    "generation-shared-cost-mismatch")
            nested = sum(bracket[side]["wall_seconds"] for side in ("before", "after")) if building else 0
            require(cost["wall_seconds"] >= nested + cost["compiler_subprocess_wall_seconds"], "generation-cost-interval-mismatch")
    require(identity(summary["stages"]) == identity(records), "generation-stage-ledger-mismatch")
    for key, value in counts.items():
        require(type(summary[key]) is int and summary[key] == value, "generation-count-mismatch")
    if complete:
        require(counts == dict(full_generation_reads=16, planned_commands=48, executed_commands=43)
                and type(summary["total_full_reads_with_parent_capture_and_final"]) is int
                and summary["total_full_reads_with_parent_capture_and_final"] == 18
                and summary["lifecycle_states_sha256"] == identity(states), "generation-complete-counts")
    return dict(counts=counts, states_sha256=identity(states), status="verified-candidate" if complete else "incomplete-prefix")
