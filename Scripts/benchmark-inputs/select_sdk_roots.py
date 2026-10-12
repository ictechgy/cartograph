#!/usr/bin/env python3
"""고정 컴파일러의 실제 검색 경계를 기록하되 SDK 봉인 범위를 자동 승인하지 않는다."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time

MAX_TEXT_BYTES = 4 * 1024**2
MAX_TOOL_BYTES = 1024**3
CONTEXTS = ["c", "objective-c", "c++", "objective-c++"]
RUNNER_SHA256 = "7305066cdfa9acf17076d0ee7fe95d927883a2224ff1ba62c15eeb2e62807d50"
OVERRIDES = (
    "CPATH",
    "C_INCLUDE_PATH",
    "CPLUS_INCLUDE_PATH",
    "OBJC_INCLUDE_PATH",
    "OBJCPLUS_INCLUDE_PATH",
    "SDKROOT",
    "DEVELOPER_DIR",
    "TOOLCHAINS",
    "SWIFT_EXEC",
    "CCC_OVERRIDE_OPTIONS",
    "CLANG_MODULE_CACHE_PATH",
    "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC",
    "SWIFT_DRIVER_CLANG_EXEC",
    "DYLD_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH",
    "DYLD_INSERT_LIBRARIES",
    "LD_PRELOAD",
)


class DiscoveryError(ValueError):
    """경로나 환경 값 대신 고정 오류 분류만 결과에 기록한다."""


def save(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DiscoveryError("duplicate-json-key")
        result[key] = value
    return result


def strict_json(text: str) -> dict:
    try:
        return json.loads(
            text,
            object_pairs_hook=unique_pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(DiscoveryError("invalid-json-number")),
        )
    except (json.JSONDecodeError, UnicodeError) as error:
        raise DiscoveryError("invalid-json") from error


def fingerprint(info: os.stat_result) -> tuple:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def file_identity(path: Path, limit: int = MAX_TOOL_BYTES, include_text: bool = False) -> dict:
    """FIFO와 링크를 열지 않고 바이트 한도 및 읽기 전후 파일 정체성을 검사한다."""
    fd = None
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise DiscoveryError("input-not-regular-file")
        if before.st_size > limit:
            raise DiscoveryError("input-byte-limit")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        if fingerprint(os.fstat(fd)) != fingerprint(before):
            raise DiscoveryError("input-changed-during-read")
        digest, total, parts = hashlib.sha256(), 0, []
        while block := os.read(fd, min(1024**2, limit + 1 - total)):
            total += len(block)
            if total > limit:
                raise DiscoveryError("input-byte-limit")
            digest.update(block)
            if include_text:
                parts.append(block)
        if (
            total != before.st_size
            or fingerprint(os.fstat(fd)) != fingerprint(before)
            or fingerprint(path.lstat()) != fingerprint(before)
        ):
            raise DiscoveryError("input-changed-during-read")
        result = dict(sha256=digest.hexdigest(), bytes=total, file_identity=list(fingerprint(before)))
        if include_text:
            result["text"] = b"".join(parts).decode("utf-8")
        return result
    except (OSError, UnicodeError) as error:
        raise DiscoveryError("unreadable-input") from error
    finally:
        if fd is not None:
            os.close(fd)


def clean_path(value: object) -> Path:
    if not isinstance(value, str) or not value.startswith("/") or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise DiscoveryError("invalid-absolute-path")
    if len(value.encode("utf-8")) > 16384 or ".." in Path(value).parts:
        raise DiscoveryError("invalid-absolute-path")
    return Path(value)


def existing_directory(value: object) -> Path:
    try:
        path = clean_path(value).resolve(strict=True)
        if not path.is_dir():
            raise DiscoveryError("input-not-directory")
        return path
    except (OSError, RuntimeError) as error:
        raise DiscoveryError("unreadable-directory") from error


def parse_clang_search(text: str, aliases: dict[str, str] | None = None) -> dict:
    """하나의 완결된 순서 보존 검색 목록과 명시한 무시 사유를 해석한다."""
    effective, ignored = [], []
    state, finished = None, False

    def reported(value):
        if aliases and value in aliases:
            canonical = str(clean_path(aliases[value]))
            return dict(path=canonical, reported_path=value, lexical_alias="selected-compiler-libcxx")
        return dict(path=str(clean_path(value)))

    for line in text.splitlines():
        if line == '#include "..." search starts here:':
            if state is not None or finished:
                raise DiscoveryError("ambiguous-clang-search-list")
            state = "quote"
        elif line == "#include <...> search starts here:":
            if state != "quote" or finished:
                raise DiscoveryError("ambiguous-clang-search-list")
            state = "angle"
        elif line == "End of search list.":
            if state != "angle" or finished:
                raise DiscoveryError("ambiguous-clang-search-list")
            state, finished = None, True
        elif state is not None:
            if not line.startswith(" "):
                raise DiscoveryError("invalid-clang-search-entry")
            value = line.strip()
            kind = "framework" if value.endswith(" (framework directory)") else "include"
            if kind == "framework":
                value = value[: -len(" (framework directory)")]
            elif re.search(r" \([^)]*\)$", value):
                raise DiscoveryError("invalid-clang-search-entry")
            effective.append(dict(**reported(value), kind=kind, group=state))
        elif line.startswith("ignoring "):
            match = re.fullmatch(r'ignoring (nonexistent|duplicate) directory "([^"\r\n]+)"', line)
            if not match:
                raise DiscoveryError("unknown-clang-ignore-diagnostic")
            ignored.append(dict(**reported(match.group(2)), reason=match.group(1)))
    if not finished or state is not None:
        raise DiscoveryError("incomplete-clang-search-list")
    return dict(effective=effective, ignored=ignored)


def relative_components(parts: tuple[str, ...]) -> list[str]:
    """루트 상대 경로를 손실 없는 JSON 조각으로 나타내며 경로 구문은 새로 허용하지 않는다."""
    if any(
        not isinstance(part, str)
        or not part
        or part in {".", ".."}
        or "/" in part
        or "\\" in part
        or any(ord(c) < 32 or ord(c) == 127 for c in part)
        for part in parts
    ):
        raise DiscoveryError("invalid-relative-path-component")
    return list(parts)


def covered_path(value: str, roots: dict[str, Path]) -> dict:
    target = existing_directory(value)
    for label, root in roots.items():
        if target.is_relative_to(root):
            return dict(
                path=value,
                canonical_path=str(target),
                root=label,
                relative_path_components=relative_components(target.relative_to(root).parts),
                scope="declared-immutable-root",
            )
    raise DiscoveryError("external-search-path")


MAX_DISCOVERED_PATHS = 128
MAX_PATH_COMPONENTS = 64
MAX_PATH_DIAGNOSTIC_BYTES = 1024**2


def path_observation(value: str) -> dict:
    """범위를 확장하거나 내용을 열지 않고 예상 밖 경로의 존재와 링크 문맥만 남긴다."""
    path = clean_path(value)
    if len(path.parts) > MAX_PATH_COMPONENTS:
        raise DiscoveryError("diagnostic-component-limit")
    result = dict(entry_type="unavailable", components=[], content_read=False)
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current = current / component
        row = dict(component=component)
        try:
            info = current.lstat()
            kind = (
                "symlink"
                if stat.S_ISLNK(info.st_mode)
                else "directory" if stat.S_ISDIR(info.st_mode) else "file" if stat.S_ISREG(info.st_mode) else "special"
            )
            row["entry_type"] = kind
            if kind == "symlink":
                target = os.readlink(current)
                if len(target.encode("utf-8")) > 16384:
                    raise DiscoveryError("diagnostic-link-limit")
                row["link_target"] = target
        except FileNotFoundError:
            row["entry_type"] = "missing"
        except OSError as error:
            row.update(entry_type="unavailable", failure_type=type(error).__name__)
        result["components"].append(row)
        result["entry_type"] = row["entry_type"]
        if row["entry_type"] in ("missing", "unavailable"):
            break
    try:
        result["canonical_path"] = str(path.resolve(strict=True))
    except (OSError, RuntimeError) as error:
        result["canonical_status"] = "unavailable"
        result["canonical_failure_type"] = type(error).__name__
    return result


def diagnostic_binding(value: str, roots: dict[str, Path], result: dict, usage: str) -> dict:
    """미해결 검색 경로는 관측만 계속하고, 승인된 루트나 입력으로 승격하지 않는다."""
    clean_path(value)
    result["observed_path_count"] += 1
    if result["observed_path_count"] > MAX_DISCOVERED_PATHS:
        raise DiscoveryError("diagnostic-path-count-limit")
    try:
        return covered_path(value, roots)
    except DiscoveryError as error:
        if str(error) not in {"external-search-path", "input-not-directory", "unreadable-directory"}:
            raise
        entry = dict(
            path=value,
            scope="diagnostic-only-uncovered-path",
            usage=usage,
            reason=str(error),
            observation=path_observation(value),
        )
        retained = result["unresolved_effective_paths"] + [entry]
        if len(json.dumps(retained, ensure_ascii=False).encode("utf-8")) > MAX_PATH_DIAGNOSTIC_BYTES:
            raise DiscoveryError("diagnostic-byte-limit")
        result["unresolved_effective_paths"].append(entry)
        return entry


def prepare(request: dict) -> dict:
    expected = {
        "schema_version",
        "sdk_name",
        "sdk",
        "target",
        "tools",
        "contexts",
        "additional_immutable_roots",
        "project_roots",
        "search_flags",
        "context_options",
        "extra_contexts",
    }
    if (
        not isinstance(request, dict)
        or set(request) != expected
        or type(request["schema_version"]) is not int
        or request["schema_version"] != 1
    ):
        raise DiscoveryError("invalid-request-schema")
    if request["contexts"] != CONTEXTS:
        raise DiscoveryError("invalid-contexts")
    if (
        request["sdk_name"] not in ("iphonesimulator", "iphoneos", "macosx")
        or not isinstance(request["target"], str)
        or not re.fullmatch(r"[A-Za-z0-9_.+-]{1,128}", request["target"])
    ):
        raise DiscoveryError("invalid-target")
    if not isinstance(request["tools"], dict) or set(request["tools"]) != {"swift", "clang", "index_library", "xcrun"}:
        raise DiscoveryError("invalid-tools")
    options = request["context_options"]
    allowed_options = {
        "c": {"-std=c11"},
        "objective-c": {"-std=c11", "-fobjc-arc"},
        "c++": {"-std=c++17"},
        "objective-c++": {"-std=c++17", "-fobjc-arc"},
    }

    def check_options(language, values):
        if (
            not isinstance(values, list)
            or len(values) > 2
            or any(not isinstance(v, str) or v not in allowed_options[language] for v in values)
            or len(values) != len(set(values))
        ):
            raise DiscoveryError("unsupported-context-options")

    if not isinstance(options, dict) or set(options) != set(CONTEXTS):
        raise DiscoveryError("unsupported-context-options")
    contexts = []
    for language in CONTEXTS:
        check_options(language, options[language])
        contexts.append(dict(id=language, language=language, options=options[language]))
    extras = request["extra_contexts"]
    if not isinstance(extras, list) or len(extras) > 4:
        raise DiscoveryError("invalid-extra-context")
    for item in extras:
        if (
            not isinstance(item, dict)
            or set(item) != {"id", "language", "options"}
            or not isinstance(item["id"], str)
            or not re.fullmatch(r"[a-z][a-z0-9-]{0,47}", item["id"])
            or item["id"] in [c["id"] for c in contexts]
            or item["language"] not in CONTEXTS
        ):
            raise DiscoveryError("invalid-extra-context")
        check_options(item["language"], item["options"])
        if any(c["language"] == item["language"] and c["options"] == item["options"] for c in contexts):
            raise DiscoveryError("duplicate-context-variant")
        contexts.append(item)
    tools, toolchains = {}, []
    for name, item in sorted(request["tools"].items()):
        if (
            not isinstance(item, dict)
            or set(item) != {"path", "sha256"}
            or not isinstance(item["sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"])
        ):
            raise DiscoveryError("invalid-tool-request")
        original = clean_path(item["path"])
        try:
            path = original.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise DiscoveryError("unreadable-tool") from error
        identity = file_identity(path)
        if identity["sha256"] != item["sha256"]:
            raise DiscoveryError("tool-identity-mismatch")
        tools[name] = dict(original_path=str(original), path=str(path), **identity)
        if name != "xcrun":
            ancestors = [p for p in path.parents if p.name.endswith(".xctoolchain")]
            if len(ancestors) != 1:
                raise DiscoveryError("missing-toolchain-ancestor")
            toolchains.append(ancestors[0])
    if len(set(toolchains)) != 1:
        raise DiscoveryError("mixed-toolchains")
    toolchain = toolchains[0]
    if toolchain.parent.name != "Toolchains":
        raise DiscoveryError("unsupported-developer-layout")
    roots = {"SDK": existing_directory(request["sdk"]), "TOOLCHAIN": toolchain}
    extra = request["additional_immutable_roots"]
    if not isinstance(extra, dict) or len(extra) > 8:
        raise DiscoveryError("invalid-additional-roots")
    for label, value in extra.items():
        if not isinstance(label, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,47}", label) or label in roots:
            raise DiscoveryError("invalid-root-label")
        roots[label] = existing_directory(value)
    for label, path in roots.items():
        if any(
            path.is_relative_to(other) or other.is_relative_to(path) for key, other in roots.items() if key != label
        ):
            raise DiscoveryError("overlapping-roots")
    projects = request["project_roots"]
    if not isinstance(projects, dict) or len(projects) > 8:
        raise DiscoveryError("invalid-project-roots")
    project_paths = {}
    for label, item in projects.items():
        if (
            not isinstance(label, str)
            or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,47}", label)
            or label in roots
            or not isinstance(item, dict)
            or set(item) != {"path", "manifest_sha256"}
            or not isinstance(item["manifest_sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", item["manifest_sha256"])
        ):
            raise DiscoveryError("invalid-project-root")
        project_paths[label] = existing_directory(item["path"])
    all_paths = {**roots, **project_paths}
    for label, path in all_paths.items():
        if any(
            path.is_relative_to(other) or other.is_relative_to(path) for key, other in all_paths.items() if key != label
        ):
            raise DiscoveryError("overlapping-roots")
    flags = request["search_flags"]
    if not isinstance(flags, dict) or set(flags) != {"clang", "swift"}:
        raise DiscoveryError("invalid-search-flags")
    explicit = {}
    for compiler, argv in flags.items():
        allowed = (
            {"-I", "-F", "-isystem", "-iquote", "-iframework"} if compiler == "clang" else {"-I", "-F", "-Fsystem"}
        )
        if not isinstance(argv, list) or len(argv) > 64 or len(argv) % 2 or any(not isinstance(v, str) for v in argv):
            raise DiscoveryError("unsupported-search-flags")
        explicit[compiler] = []
        for index in range(0, len(argv), 2):
            if argv[index] not in allowed:
                raise DiscoveryError("unsupported-search-flags")
            coverage = covered_path(argv[index + 1], all_paths)
            if coverage["root"] in projects:
                coverage.update(
                    scope="project-generation-reference", manifest_sha256=projects[coverage["root"]]["manifest_sha256"]
                )
            explicit[compiler].append(dict(flag=argv[index], coverage=coverage))
    return dict(
        roots=roots,
        contexts=contexts,
        project_paths=project_paths,
        explicit_search_paths=explicit,
        tools=tools,
        developer=toolchain.parent.parent,
        root_aliases={
            "SDK": request["sdk"],
            "TOOLCHAIN": str(toolchain),
            **extra,
            **{k: v["path"] for k, v in projects.items()},
        },
    )


def compiler_alias_state(selection: dict) -> dict:
    """선택한 Clang의 고정 후보만 허용하고 실제로 지나는 디렉터리 정체성을 묶는다."""
    original = Path(selection["tools"]["clang"]["original_path"])
    chain = selection["roots"]["TOOLCHAIN"]
    canonical = chain / "usr/include/c++/v1"
    alias = original.parent / "../include/c++/v1"
    if original.parent.resolve(strict=True) != chain / "usr/bin":
        return dict(aliases={}, directory_identity_sha256=None)
    if alias.resolve() != canonical or canonical.resolve() != canonical:
        raise DiscoveryError("compiler-alias-escape")
    watched = [
        original.parent,
        chain,
        Path(selection["root_aliases"]["SDK"]),
        selection["roots"]["SDK"],
        canonical,
    ]
    identities = {}
    for path in watched:
        current = Path(path.anchor)
        for component in ("", *path.parts[1:]):
            if component:
                current = current / component
            try:
                info = current.lstat()
            except FileNotFoundError:
                identities[str(current)] = dict(entry_type="missing")
                break
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)):
                raise DiscoveryError("compiler-alias-nondirectory")
            identities[str(current)] = dict(identity=[info.st_dev, info.st_ino, info.st_mode])
            if stat.S_ISLNK(info.st_mode):
                identities[str(current)]["link_target"] = os.readlink(current)
    return dict(
        aliases={str(alias): str(canonical)},
        directory_identity_sha256=hashlib.sha256(json.dumps(identities, sort_keys=True).encode()).hexdigest(),
    )


def guard(selection: dict) -> None:
    """루트 별칭과 실행 도구는 매 프로브 뒤 다시 확인하며 전체 SDK 봉인은 별도다."""
    for label, original in selection["root_aliases"].items():
        if existing_directory(original) != {**selection["roots"], **selection["project_paths"]}[label]:
            raise DiscoveryError("root-selection-changed")
    if "compiler_alias_state" in selection and compiler_alias_state(selection) != selection["compiler_alias_state"]:
        raise DiscoveryError("compiler-alias-generation-changed")
    for name, item in selection["tools"].items():
        try:
            path = Path(item["original_path"]).resolve(strict=True)
            identity = file_identity(path)
        except (DiscoveryError, OSError, RuntimeError) as error:
            raise DiscoveryError("tool-generation-changed") from error
        if str(path) != item["path"] or any(identity[key] != item[key] for key in ("sha256", "bytes", "file_identity")):
            raise DiscoveryError("tool-generation-changed")


def record(
    request: dict, output: Path, runner, runner_identity: dict | None = None, request_identity: dict | None = None
) -> dict:
    """원본 요청과 모든 프로브 비용/실패를 남긴 뒤 검토 대기 제안만 만든다."""
    output = output.absolute()
    # 입력 트리와 출력의 중첩은 출력 디렉터리를 만들기 전에 거부한다.
    if isinstance(request, dict):
        candidates = [request.get("sdk")]
        if isinstance(request.get("additional_immutable_roots"), dict):
            candidates += list(request["additional_immutable_roots"].values())
        if isinstance(request.get("project_roots"), dict):
            candidates += [v.get("path") for v in request["project_roots"].values() if isinstance(v, dict)]
        if isinstance(request.get("tools"), dict):
            for item in request["tools"].values():
                if isinstance(item, dict) and isinstance(item.get("path"), str):
                    for tool_path in (Path(item["path"]), Path(item["path"]).resolve()):
                        candidates += [str(p) for p in tool_path.parents if p.name.endswith(".xctoolchain")]
        for raw in candidates:
            if isinstance(raw, str):
                root = Path(raw).resolve()
                destination = output.resolve()
                if destination.is_relative_to(root) or root.is_relative_to(destination):
                    raise DiscoveryError("evidence-input-overlap")
    output.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()
    result = dict(
        schema_version=1,
        status="failed",
        accepted=False,
        final_protocol_ready=False,
        exit_code=1,
        probes=[],
        observed_path_count=0,
        unresolved_effective_paths=[],
        probe_wall_seconds=0.0,
        runner_identity=runner_identity,
        environment_policy=dict(removed_keys=list(OVERRIDES), explicit_developer_dir="selected-toolchain-parent"),
        limitations=[
            "Proposal only; actual selected roots and link layout require review before any accepted seal.",
            "No SDK contents are hashed by this discovery; full declared-root sealing is separate.",
            "Ignored external missing paths are unsealed absence dependencies requiring a final policy.",
            "Full tool identities, probes and pre/post guards are charged shared setup costs; no costs are subtracted.",
            "No complete OS/dynamic-loader dependency closure or detached-descendant containment is claimed.",
        ],
    )
    save(output / "request.json", request)
    if request_identity is not None:
        save(output / "request-input.json", request_identity)
    try:
        selection = prepare(request)
        selection["compiler_alias_state"] = compiler_alias_state(selection)
        result["compiler_path_aliases"] = selection["compiler_alias_state"]
        guard(selection)
        result["selected_tools"] = selection["tools"]
        env = dict(os.environ)
        for key in OVERRIDES:
            env.pop(key, None)
        env["DEVELOPER_DIR"] = str(selection["developer"])
        env["LC_ALL"] = "C"
        roots = selection["roots"]
        sdk = str(roots["SDK"])
        tools = selection["tools"]
        xcrun, clang, swift = (tools[n]["original_path"] for n in ["xcrun", "clang", "swift"])

        def probe(name, argv):
            guard(selection)
            row = runner(argv, output, output / "probes" / name, env, 60.0)
            if (
                not isinstance(row, dict)
                or type(row.get("wall_seconds")) not in (int, float)
                or not math.isfinite(row["wall_seconds"])
                or row["wall_seconds"] < 0
            ):
                raise DiscoveryError("invalid-probe-receipt")
            retained = dict(name=name, **row)
            result["probes"].append(retained)
            result["probe_wall_seconds"] += row["wall_seconds"]
            incomplete = not row.get("completed") or row.get("returncode") == 125
            if incomplete or row.get("cleanup_root_unfinished"):
                retained["post_probe_guard"] = dict(
                    status="unavailable", reason="incomplete-process-cleanup-unverified", wall_seconds=0.0
                )
            else:
                guard_started = time.perf_counter()
                try:
                    guard(selection)
                    retained["post_probe_guard"] = dict(status="passed")
                except DiscoveryError as error:
                    retained["post_probe_guard"] = dict(status="failed", failure=str(error))
                retained["post_probe_guard"]["wall_seconds"] = time.perf_counter() - guard_started
            if incomplete:
                result["status"] = "incomplete"
                result["exit_code"] = 125
                raise DiscoveryError("incomplete-probe")
            if not row.get("passed") or row.get("returncode") != 0:
                raise DiscoveryError("failed-probe")
            if retained["post_probe_guard"]["status"] != "passed":
                raise DiscoveryError(retained["post_probe_guard"].get("failure", "post-probe-guard-unavailable"))
            return {kind: file_identity(Path(row[kind]), MAX_TEXT_BYTES, True)["text"] for kind in ("stdout", "stderr")}

        path = probe("sdk-path", [xcrun, "--sdk", request["sdk_name"], "--show-sdk-path"])["stdout"].strip()
        if existing_directory(path) != roots["SDK"]:
            raise DiscoveryError("sdk-probe-mismatch")
        version = probe("sdk-version", [xcrun, "--sdk", request["sdk_name"], "--show-sdk-version"])["stdout"].strip()
        build = probe("sdk-build", [xcrun, "--sdk", request["sdk_name"], "--show-sdk-build-version"])["stdout"].strip()
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version) or not re.fullmatch(r"[A-Za-z0-9.]{1,64}", build):
            raise DiscoveryError("invalid-sdk-version")
        resource = probe("clang-resource", [clang, "-print-resource-dir"])["stdout"].strip()
        resource_binding = diagnostic_binding(resource, roots, result, "clang-resource-directory")
        swift_info = strict_json(
            probe(
                "swift-target",
                [
                    swift,
                    "-print-target-info",
                    "-target",
                    request["target"],
                    "-sdk",
                    sdk,
                    *request["search_flags"]["swift"],
                ],
            )["stdout"]
        )
        expected_paths = {"runtimeResourcePath", "runtimeLibraryPaths", "runtimeLibraryImportPaths"}
        paths = swift_info.get("paths") if isinstance(swift_info, dict) else None
        if (
            not isinstance(paths, dict)
            or set(paths) not in (expected_paths, expected_paths | {"sdkPath"})
            or ("sdkPath" in paths and not isinstance(paths["sdkPath"], str))
            or not isinstance(paths["runtimeResourcePath"], str)
            or any(
                not isinstance(paths[k], list) or not all(isinstance(v, str) for v in paths[k])
                for k in ("runtimeLibraryPaths", "runtimeLibraryImportPaths")
            )
        ):
            raise DiscoveryError("unexpected-swift-path-schema")
        if not isinstance(swift_info.get("target"), dict) or swift_info["target"].get("triple") != request["target"]:
            raise DiscoveryError("swift-target-mismatch")
        if "sdkPath" in paths and existing_directory(paths["sdkPath"]) != roots["SDK"]:
            raise DiscoveryError("swift-sdk-mismatch")
        usages = {
            "runtimeResourcePath": "swift-resource-directory",
            "runtimeLibraryPaths": "swift-runtime-library-search",
            "runtimeLibraryImportPaths": "swift-compiler-import-search",
            "sdkPath": "swift-selected-sdk",
        }
        swift_bindings = {
            key: [
                diagnostic_binding(value, roots, result, usages[key])
                for value in (values if isinstance(values, list) else [values])
            ]
            for key, values in paths.items()
        }
        searches, absences = [], []
        source = output / "probe-input"
        source.write_bytes(b"")
        for context in selection["contexts"]:
            language = context["language"]
            data = probe(
                "clang-" + context["id"].replace("+", "x"),
                [
                    clang,
                    "-target",
                    request["target"],
                    "-isysroot",
                    sdk,
                    "-E",
                    "-v",
                    "-x",
                    language,
                    *context["options"],
                    *request["search_flags"]["clang"],
                    str(source),
                ],
            )
            parsed = parse_clang_search(data["stderr"], selection["compiler_alias_state"]["aliases"])
            for item in parsed["effective"]:
                item["coverage"] = diagnostic_binding(
                    item["path"],
                    {**roots, **selection["project_paths"]},
                    result,
                    "clang-" + context["id"] + "-include-search",
                )
                if item["coverage"].get("root") in request["project_roots"]:
                    item["coverage"].update(
                        scope="project-generation-reference",
                        manifest_sha256=request["project_roots"][item["coverage"]["root"]]["manifest_sha256"],
                    )
            for item in parsed["ignored"]:
                path = clean_path(item["path"])
                if item["reason"] == "nonexistent":
                    if path.exists() or path.is_symlink():
                        raise DiscoveryError("ignored-absence-exists")
                    item["coverage"] = "unsealed-absence"
                    absences.append(dict(language=language, **item))
                else:
                    item["coverage"] = diagnostic_binding(
                        item["path"],
                        {**roots, **selection["project_paths"]},
                        result,
                        "clang-" + context["id"] + "-include-search",
                    )
            searches.append(
                dict(context_id=context["id"], language=language, context_options=context["options"], **parsed)
            )
        guard(selection)
        result["proposal"] = dict(
            roots={k: str(v) for k, v in roots.items()},
            project_roots=request["project_roots"],
            explicit_search_paths=selection["explicit_search_paths"],
            search_flags=request["search_flags"],
            sdk_name=request["sdk_name"],
            sdk_version=version,
            sdk_build=build,
            target=request["target"],
            clang_resource=resource_binding,
            swift_paths=swift_bindings,
            clang_search_paths=searches,
            unsealed_absence_dependencies=absences,
        )
        if result["unresolved_effective_paths"]:
            raise DiscoveryError("unresolved-effective-paths")
        result.update(status="awaiting-root-review", exit_code=0)
    except DiscoveryError as error:
        result["failure"] = str(error)
    except KeyboardInterrupt:
        result.update(status="incomplete", exit_code=125, failure="interrupt")
    except (OSError, RuntimeError, ValueError, TypeError, KeyError) as error:
        result["failure"] = "unclassified-discovery-error"
        result["failure_type"] = type(error).__name__
    result["total_wall_seconds"] = time.perf_counter() - started
    result["setup_and_guard_wall_seconds"] = result["total_wall_seconds"] - result["probe_wall_seconds"]
    save(output / "results.json", result)
    return result


def check_input_file_overlap(output: Path, inputs: list[Path]) -> None:
    """요청/실행기 별칭의 실제 파일과 출력 경계도 첫 읽기 전에 확인한다."""
    destination = output.resolve()
    for input_path in inputs:
        target = input_path.resolve()
        if target.is_relative_to(destination) or destination.is_relative_to(target):
            raise DiscoveryError("evidence-input-file-overlap")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--command-runner", type=Path, required=True)
    args = parser.parse_args()
    started = time.perf_counter()
    try:
        check_input_file_overlap(args.output, [args.request, args.command_runner])
        request_input = file_identity(args.request, MAX_TEXT_BYTES, True)
        request = strict_json(request_input.pop("text"))
        runner_input = file_identity(args.command_runner, MAX_TEXT_BYTES, True)
        runner_source = runner_input.pop("text")
        if runner_input["sha256"] != RUNNER_SHA256:
            raise DiscoveryError("unreviewed-command-runner")
        namespace = {"__name__": "reviewed_probe_command", "__file__": str(args.command_runner.resolve())}
        exec(compile(runner_source, str(args.command_runner), "exec"), namespace)
        runner_input["load_wall_seconds"] = time.perf_counter() - started
        result = record(
            request,
            args.output,
            runner=namespace["command"],
            runner_identity=runner_input,
            request_identity=request_input,
        )
    except (DiscoveryError, OSError, RuntimeError, ValueError) as error:
        print(
            json.dumps(
                dict(
                    status="refused-before-record",
                    reason=str(error) if isinstance(error, DiscoveryError) else type(error).__name__,
                    wall_seconds=time.perf_counter() - started,
                )
            ),
            file=sys.stderr,
        )
        raise SystemExit(1)
    print(json.dumps(dict(status=result["status"], accepted=False, exit_code=result["exit_code"])))
    raise SystemExit(result["exit_code"])


if __name__ == "__main__":
    main()
