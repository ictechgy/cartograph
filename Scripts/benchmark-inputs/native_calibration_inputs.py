#!/usr/bin/env python3
"""검토 대기 네이티브 입력을 컴파일 전에 봉인하고 같은 경계만 다시 검사한다."""

from __future__ import annotations

import importlib.util
import json
import math
import os
from pathlib import Path
import stat
import sys
import time

HERE = Path(__file__).resolve().parent
EXPECTATION = HERE / "native_calibration_expectation.json"


def load_module(name: str, filename: str):
    """기존 봉인·선택기의 의미를 복제하지 않고 그대로 재사용한다."""
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SELECTOR = load_module("native_calibration_selector", "select_sdk_roots.py")
SEAL = load_module("native_calibration_seal", "sdk_content_seal.py")


class AdmissionError(ValueError):
    """추정이나 새 도구 선택 없이 고정된 거부 이유를 보존한다."""


class IncompleteAdmission(AdmissionError):
    """실행이 끝나지 않은 관측은 단순 불일치와 구분한다."""


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise AdmissionError(reason)


def expectation() -> tuple[dict, str]:
    """이 소스 옆의 검토 가능한 고정 계약만 읽고 대체 계약은 받지 않는다."""
    item = SELECTOR.file_identity(EXPECTATION, SELECTOR.MAX_TEXT_BYTES, True)
    value = SELECTOR.strict_json(item["text"])
    require(value["accepted"] is False and value["final_protocol_ready"] is False, "invalid-expectation-status")
    require(value["limits"] == dict(max_entries=SEAL.MAX_ENTRIES, max_bytes=SEAL.MAX_BYTES,
                                     max_path_bytes=SEAL.MAX_PATH_BYTES), "changed-seal-limits")
    for filename, digest in value["helper_sha256"].items():
        require(SELECTOR.file_identity(HERE / filename)["sha256"] == digest, "unreviewed-input-helper")
    return value, item["sha256"]


def clean_environment(environment: dict, expected: dict) -> dict:
    """컴파일러 검색 환경은 선택기와 같은 금지 목록 및 명시한 개발자 경로를 쓴다."""
    require(environment.get("DEVELOPER_DIR") == expected["developer_lexical"], "developer-environment-mismatch")
    env = {key: value for key, value in environment.items() if key not in SELECTOR.OVERRIDES}
    env.update(DEVELOPER_DIR=expected["developer_lexical"], LC_ALL="C")
    return env


def path_chain(path: Path, *, absent: bool = False) -> dict:
    """누락을 ENOENT로만 판정하고 링크와 가장 가까운 기존 조상의 정체성을 남긴다."""
    require(path.is_absolute() and len(path.parts) <= SELECTOR.MAX_PATH_COMPONENTS, "invalid-boundary-path")
    rows, current, nearest = [], Path(path.anchor), None
    for component in ("", *path.parts[1:]):
        if component:
            current = current / component
        try:
            info = current.lstat()
        except FileNotFoundError:
            require(absent and nearest is not None, "required-path-missing")
            rows.append(dict(component=component, entry_type="missing"))
            return dict(lexical_path=str(path), canonical_path=str(path.resolve()), components=rows,
                        nearest_existing_ancestor=nearest, missing_components=list(path.parts[len(rows) - 1:]))
        kind = "symlink" if stat.S_ISLNK(info.st_mode) else "directory" if stat.S_ISDIR(info.st_mode) else "file"
        require(kind != "file" or (current == path and not absent and stat.S_ISREG(info.st_mode)),
                "unexpected-boundary-entry")
        row = dict(component=component, entry_type=kind, identity=[info.st_dev, info.st_ino, info.st_mode])
        resolved = current.resolve(strict=True)
        if kind == "symlink":
            row["link_target"] = os.readlink(current)
            require(len(os.fsencode(row["link_target"])) <= 16384, "boundary-link-limit")
            if current != path or absent:
                require(resolved.is_dir(), "boundary-link-not-directory")
        rows.append(row)
        nearest = dict(lexical_path=str(current), canonical_path=str(resolved), identity=row["identity"])
    require(not absent, "absence-dependency-exists")
    return dict(lexical_path=str(path), canonical_path=str(path.resolve(strict=True)), components=rows)


def selected_layout(expected: dict, selected: dict) -> dict:
    """명시한 두 물리적 루트와 허용한 별칭만 인정하고 자동 루트 추가를 막는다."""
    physical = Path(expected["developer_physical"])
    lexical = Path(expected["developer_lexical"])
    require(lexical.resolve(strict=True) == physical and physical.resolve(strict=True) == physical,
            "developer-alias-mismatch")
    roots = {label: Path(value) for label, value in expected["roots"].items()}
    require(set(roots) == {"SDK", "TOOLCHAIN"}, "unexpected-root-set")
    require(SEAL.selected_roots(roots) == roots, "physical-root-mismatch")
    paths = {"developer": lexical, "SDK": Path(selected["sdk"]),
             "TOOLCHAIN": lexical / "Toolchains/XcodeDefault.xctoolchain"}
    tools = {}
    for name, contract in expected["tools"].items():
        original = Path(selected["tools"][name])
        require(str(original) in contract["allowed_paths"], "unexpected-tool-alias")
        target = original.resolve(strict=True)
        require(str(target) == contract["physical_path"], "tool-physical-path-mismatch")
        identity = SELECTOR.file_identity(target)
        require(all(identity[key] == contract[key] for key in ("bytes", "sha256")), "native-tool-mismatch")
        tools[name] = dict(original_path=str(original), path=str(target), **identity)
        paths["tool-" + name] = original
    require(selected["sdk"] in expected["sdk_aliases"], "unexpected-sdk-alias")
    require(Path(selected["sdk"]).resolve(strict=True) == roots["SDK"], "sdk-alias-mismatch")
    for label, path in roots.items():
        paths["physical-" + label] = path
    for index, alias in enumerate(expected["sdk_aliases"]):
        require(Path(alias).resolve(strict=True) == roots["SDK"], "sdk-alias-mismatch")
        paths[f"sdk-alias-{index}"] = Path(alias)
    clang = Path(selected["tools"]["clang"])
    libcxx = clang.parent / "../include/c++/v1"
    missing = {
        "sdk-local-include": roots["SDK"] / "usr/local/include",
        "sdk-library-frameworks": roots["SDK"] / "Library/Frameworks",
        "compiler-libcxx": libcxx,
    }
    absences = {key: path_chain(path, absent=True) for key, path in missing.items()}
    canonical = roots["TOOLCHAIN"] / "usr/include/c++/v1"
    require(absences["compiler-libcxx"]["canonical_path"] == str(canonical), "compiler-alias-escape")
    aliases = {key: path_chain(path) for key, path in paths.items()}
    selection = dict(roots=roots, tools=tools, root_aliases={"SDK": selected["sdk"]})
    return dict(roots={k: str(v) for k, v in roots.items()}, tools=tools, aliases=aliases,
                absences=absences, compiler_path_aliases=SELECTOR.compiler_alias_state(selection))


def assert_native(observed: dict, expected: dict) -> None:
    """이름뿐인 runner 선언이나 일부 버전 일치를 통과로 보지 않는다."""
    require(observed["platform"] == "darwin", "native-macos-required")
    require(observed["runner"] == expected["runner"], "runner-image-mismatch")
    require(observed["machine"] == expected["machine"], "native-machine-mismatch")
    require(observed["versions"] == expected["versions"], "native-version-mismatch")


def collect_native(output: Path, *, machine_fields, command, environment: dict, expected: dict) -> dict:
    """기존 macOS 필드 관측기를 주입받고 모든 추가 읽기 명령의 원본·비용을 보존한다."""
    output.mkdir(parents=True, exist_ok=False)
    env = clean_environment(environment, expected)
    observed = dict(platform=sys.platform, runner={key: environment.get(key) for key in expected["runner"]}, probes={})
    require(observed["platform"] == "darwin", "native-macos-required")
    require(observed["runner"] == expected["runner"], "runner-image-mismatch")
    xcrun = expected["tools"]["xcrun"]
    before_xcrun = SELECTOR.file_identity(Path(xcrun["physical_path"]))
    require(all(before_xcrun[k] == xcrun[k] for k in ("bytes", "sha256")), "native-tool-mismatch")

    def probe(name, argv):
        row = command(argv, output, output / name, env, 30.0)
        observed["probes"][name] = row
        if isinstance(row, dict) and (row.get("completed") is not True or row.get("returncode") == 125
                                     or row.get("cleanup_root_unfinished") is True):
            raise IncompleteAdmission("native-probe-incomplete")
        require(isinstance(row, dict) and row.get("completed") is True and row.get("passed") is True
                and type(row.get("returncode")) is int and row["returncode"] == 0
                and row.get("cleanup_root_unfinished") is False, "native-probe-failed")
        elapsed = row.get("wall_seconds")
        require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0, "invalid-probe-cost")
        identity = SELECTOR.file_identity(Path(row["stdout"]), SELECTOR.MAX_TEXT_BYTES, True)
        row["stdout_identity"] = {k: v for k, v in identity.items() if k != "text"}
        return identity["text"].strip()

    def sysctl(argv):
        return dict(status="ok", stdout=probe("machine-" + argv[-1].replace(".", "_"), argv))

    observed["machine"], failures = machine_fields(sysctl)
    require(not failures, "native-machine-unavailable")
    selected = dict(sdk=probe("sdk-path", ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]), tools={})
    for name, tool in (("swift", "swiftc"), ("clang", "clang")):
        selected["tools"][name] = probe(name + "-path", ["/usr/bin/xcrun", "--find", tool])
    selected["tools"].update(
        swift_frontend=str(Path(selected["tools"]["swift"]).with_name("swift-frontend")),
        index_library=expected["tools"]["index_library"]["physical_path"], xcrun="/usr/bin/xcrun")
    layout_before = selected_layout(expected, selected)
    observed["versions"] = {
        "os_build": probe("os-build", ["/usr/bin/sw_vers", "-buildVersion"]),
        "xcode": probe("xcode-version", ["/usr/bin/xcodebuild", "-version"]),
        "swift": probe("swift-version", [selected["tools"]["swift"], "--version"]),
        "sdk_version": probe("sdk-version", ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]),
        "sdk_build": probe("sdk-build", ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"]),
    }
    assert_native(observed, expected)
    require(selected_layout(expected, selected) == layout_before, "native-inputs-changed")
    observed.update(selected=selected, layout=layout_before)
    return observed


def evidence_boundary(output: Path, expected: dict) -> None:
    """증거를 입력 안이나 입력을 품는 위치에 써서 봉인 자체가 변하는 일을 막는다."""
    for raw in (expected["developer_lexical"], expected["developer_physical"], *expected["roots"].values()):
        for root in (Path(raw).absolute(), Path(raw).resolve()):
            for destination in (output.absolute(), output.resolve()):
                require(not destination.is_relative_to(root) and not root.is_relative_to(destination),
                        "evidence-input-overlap")


def write_manifest(path: Path, value: dict) -> None:
    """수신 측과 같은 크기 한도로 전체 원본 봉인을 빠짐 없이 보존한다."""
    data = SEAL.canonical_bytes(value)
    require(len(data) <= SEAL.MAX_MANIFEST_BYTES, "seal-manifest-byte-limit")
    with path.open("xb") as stream:
        stream.write(data)


def candidate_receipt(boundary: str) -> dict:
    return dict(schema_version=1, status="failed", accepted=False, final_protocol_ready=False, boundary=boundary,
                full_cost_required_per_arm=True, runtime_closure_proven=False,
                limitations=["Candidate only; independent content/root/link readback and freeze remain required.",
                             "The host macOS SDK and source-built tool input closure are outside these two roots.",
                             "No OS, dynamic-loader, link, JIT or target-execution closure is proved."])


def begin(output: Path, *, machine_fields, command, environment: dict) -> dict:
    """호출자가 어떤 커버된 컴파일도 시작하기 전에 이 성공 영수증을 요구해야 한다."""
    started, result, created = time.perf_counter(), candidate_receipt("before-compilation"), False
    output = output.absolute()
    try:
        expected, digest = expectation()
        evidence_boundary(output, expected)
        output.mkdir(parents=True, exist_ok=False)
        created = True
        result["expectation_sha256"] = digest
        at = time.perf_counter()
        try:
            observed = collect_native(output / "native", machine_fields=machine_fields, command=command,
                                      environment=environment, expected=expected)
            result["native"] = observed
        finally:
            result["native_admission_wall_seconds"] = time.perf_counter() - at
        roots = {key: Path(value) for key, value in observed["layout"]["roots"].items()}
        at = time.perf_counter()
        try:
            seal = SEAL.capture(roots, **expected["limits"])
            write_manifest(output / "seal.json", seal)
            result.update(seal_path=str(output / "seal.json"), seal_manifest_sha256=seal["manifest_sha256"],
                          content_sha256=seal["content_sha256"])
        finally:
            result["seal_capture_wall_seconds"] = time.perf_counter() - at
        require(selected_layout(expected, observed["selected"]) == observed["layout"], "native-inputs-changed")
        result["status"] = "captured-candidate"
    except (KeyboardInterrupt, IncompleteAdmission) as error:
        result.update(status="incomplete", failure="interrupt" if isinstance(error, KeyboardInterrupt) else str(error))
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        result.update(failure=str(error) if isinstance(error, (AdmissionError, SEAL.SealError))
                      else "admission-unavailable",
                      failure_type=type(error).__name__)
    finally:
        result["wall_seconds"] = time.perf_counter() - started
        if created:
            SELECTOR.save(output / "results.json", result)
    return result


def verify_boundary(candidate: dict, output: Path, *, machine_fields, command,
                    environment: dict, boundary: str) -> dict:
    """세대 생성 후와 측정 종료 후에 전체 본문과 별칭·부재를 다시 읽는다."""
    started, result, created = time.perf_counter(), candidate_receipt(boundary), False
    output = output.absolute()
    try:
        require(boundary in {"after-generation", "after-calibration"}, "invalid-boundary")
        require(candidate.get("status") == "captured-candidate" and candidate.get("boundary") == "before-compilation"
                and candidate.get("accepted") is False and candidate.get("final_protocol_ready") is False,
                "invalid-candidate")
        expected, digest = expectation()
        require(digest == candidate["expectation_sha256"], "expectation-changed")
        evidence_boundary(output, expected)
        output.mkdir(parents=True, exist_ok=False)
        created = True
        at = time.perf_counter()
        try:
            observed = collect_native(output / "native", machine_fields=machine_fields, command=command,
                                      environment=environment, expected=expected)
            result["native"] = observed
            require(observed["selected"] == candidate["native"]["selected"]
                    and observed["layout"] == candidate["native"]["layout"], "native-inputs-changed")
        finally:
            result["native_admission_wall_seconds"] = time.perf_counter() - at
        at = time.perf_counter()
        try:
            seal = SEAL.strict_expected_json(SEAL.expected_bytes(Path(candidate["seal_path"])))
            require(seal["manifest_sha256"] == candidate["seal_manifest_sha256"]
                    and seal["content_sha256"] == candidate["content_sha256"], "candidate-seal-changed")
            verification = SEAL.verify(seal, {k: Path(v) for k, v in observed["layout"]["roots"].items()})
            write_manifest(output / "seal-verification.json", verification)
            result["verification_path"] = str(output / "seal-verification.json")
            result["verification"] = {k: v for k, v in verification.items() if k != "actual"}
            require(verification["matches"] is True, "sdk-content-changed")
        finally:
            result["seal_verification_wall_seconds"] = time.perf_counter() - at
        require(selected_layout(expected, observed["selected"]) == observed["layout"], "native-inputs-changed")
        result["status"] = "verified-candidate"
    except (KeyboardInterrupt, IncompleteAdmission) as error:
        result.update(status="incomplete", failure="interrupt" if isinstance(error, KeyboardInterrupt) else str(error))
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        result.update(failure=str(error) if isinstance(error, (AdmissionError, SEAL.SealError))
                      else "verification-unavailable",
                      failure_type=type(error).__name__)
    finally:
        result["wall_seconds"] = time.perf_counter() - started
        if created:
            SELECTOR.save(output / "results.json", result)
    return result


def covered(value: Path, roots: dict, projects: dict) -> dict:
    """프로젝트 경로에는 세대 해시를 유지하고 SDK 입력으로 승격하지 않는다."""
    row = SELECTOR.covered_path(str(value), {**roots, **{k: Path(v["path"]).resolve() for k, v in projects.items()}})
    if row["root"] in projects:
        row.update(scope="project-generation-reference", manifest_sha256=projects[row["root"]]["manifest_sha256"])
    return row


def expected_searches(selection: dict, request: dict) -> tuple[list, list]:
    """이미 관측한 다섯 컨텍스트의 순서와 유효·부재 경로를 정확히 고정한다."""
    roots, projects = selection["roots"], request["project_roots"]
    sdk, chain = roots["SDK"], roots["TOOLCHAIN"]
    include = Path(projects["PROJECT"]["path"]) / "Sources/BridgeKit/include"
    common = [(chain / "usr/lib/clang/21/include", "include"), (sdk / "usr/include", "include"),
              (chain / "usr/include", "include"), (sdk / "System/Library/Frameworks", "framework"),
              (sdk / "System/Library/SubFrameworks", "framework")]
    aliases = selection["compiler_alias_state"]["aliases"]
    require(len(aliases) == 1, "compiler-alias-missing")
    alias, canonical = next(iter(aliases.items()))
    searches, absences = [], []
    for context in selection["contexts"]:
        paths = [(include, "include")]
        ignored = []
        if context["language"] in {"c++", "objective-c++"}:
            paths.append((sdk / "usr/include/c++/v1", "include"))
            ignored.append(dict(path=canonical, reported_path=alias, lexical_alias="selected-compiler-libcxx",
                                reason="nonexistent", coverage="unsealed-absence"))
        ignored += [dict(path=str(sdk / suffix), reason="nonexistent", coverage="unsealed-absence")
                    for suffix in ("usr/local/include", "Library/Frameworks")]
        effective = [dict(path=str(path), group="angle", kind=kind, coverage=covered(path, roots, projects))
                     for path, kind in paths + common]
        searches.append(dict(context_id=context["id"], language=context["language"], context_options=context["options"],
                             effective=effective, ignored=ignored))
        absences += [dict(language=context["language"], **row) for row in ignored]
    return searches, absences


def deferred_reference(result: dict, phase: dict, roots: dict, expected: dict) -> dict:
    """링크·JIT·실행 범위를 열지 않고 원본 Swift 프로브에 연결된 단일 참조만 남긴다."""
    probes = [row for row in result["probes"] if row.get("name") == "swift-target"]
    require(len(probes) == 1, "missing-swift-target-probe")
    identity = SELECTOR.file_identity(Path(probes[0]["stdout"]), SELECTOR.MAX_TEXT_BYTES, True)
    swift = SELECTOR.strict_json(identity["text"])
    require(swift.get("compilerVersion") == SELECTOR.REVIEWED_SWIFT_VERSION
            and swift.get("swiftCompilerTag") == "swiftlang-6.3.3.1.3"
            and swift.get("target", {}).get("triple") == phase["target"]
            and swift["target"].get("platform") == "iphonesimulator", "unreviewed-swift-target")
    expected_paths = {
        "runtimeResourcePath": str(roots["TOOLCHAIN"] / "usr/lib/swift"),
        "runtimeLibraryPaths": [str(roots["TOOLCHAIN"] / "usr/lib/swift/iphonesimulator"), "/usr/lib/swift"],
        "runtimeLibraryImportPaths": [str(roots["TOOLCHAIN"] / "usr/lib/swift/iphonesimulator"),
                                      str(roots["SDK"] / "usr/lib/swift")],
        "sdkPath": str(roots["SDK"]),
    }
    def normalized_paths(paths):
        return {key: [canonical_search_spellings({"path": item}, expected)["path"] for item in value]
                if isinstance(value, list) else canonical_search_spellings({"path": value}, expected)["path"]
                for key, value in paths.items()}
    require(normalized_paths(swift["paths"]) == expected_paths, "unreviewed-swift-paths")
    observation = SELECTOR.path_observation("/usr/lib/swift")
    require(observation.get("canonical_path") == "/usr/lib/swift" and observation["entry_type"] == "directory"
            and all(row["entry_type"] == "directory" for row in observation["components"]),
            "unreviewed-target-runtime-reference")
    return dict(path="/usr/lib/swift", scope="phase-deferred-target-runtime-reference",
                usage="swift-runtime-library-search", reason="external-search-path", observation=observation,
                path_field="runtimeLibraryPaths", path_index=1, compile_phase_sha256=SELECTOR.content_digest(phase),
                probe_name="swift-target", probe_stdout_sha256=identity["sha256"],
                required_for_phases=["link", "jit", "target-execution"], runtime_closure_proven=False)


def canonical_search_spellings(proposal: dict, expected: dict) -> dict:
    """기록은 원문으로 유지하며 이미 포착한 명시적 루트 별칭의 path 필드만 비교에 맞춘다."""
    aliases = {value: expected["roots"]["SDK"] for value in expected["sdk_aliases"]}
    for contract in expected["tools"].values():
        for value in contract["allowed_paths"]:
            parents = [parent for parent in Path(value).parents if parent.name == "XcodeDefault.xctoolchain"]
            if parents:
                aliases[str(parents[0])] = expected["roots"]["TOOLCHAIN"]

    def normalize(value, field=None):
        if isinstance(value, dict):
            return {key: normalize(item, key) for key, item in value.items()}
        if isinstance(value, list):
            return [normalize(item) for item in value]
        if field == "path" and isinstance(value, str):
            for alias, physical in sorted(aliases.items(), key=lambda item: -len(item[0])):
                if value == alias or value.startswith(alias + "/"):
                    require(Path(alias).resolve(strict=True) == Path(physical), "search-alias-changed")
                    return physical + value[len(alias):]
        return value

    return normalize(proposal)


def bind_discovery(candidate: dict, request: dict, result: dict) -> dict:
    """컴파일 뒤 제안이 컴파일 전 봉인과 정확히 같은 루트·검색 문맥인지 검사한다."""
    started = time.perf_counter()
    expected, digest = expectation()
    require(candidate.get("status") == "captured-candidate" and candidate.get("boundary") == "before-compilation"
            and candidate.get("accepted") is False and candidate.get("final_protocol_ready") is False,
            "invalid-candidate")
    require(candidate["expectation_sha256"] == digest, "expectation-changed")
    native = candidate["native"]
    require(selected_layout(expected, native["selected"]) == native["layout"], "native-inputs-changed")
    require(request["additional_immutable_roots"] == {} and request["target"] == expected["target"]
            and request["sdk"] == native["selected"]["sdk"], "discovery-context-mismatch")
    require(request["tools"] == {name: dict(path=native["selected"]["tools"][name], sha256=contract["sha256"])
                                 for name, contract in expected["tools"].items() if name != "swift_frontend"},
            "discovery-tools-mismatch")
    selection = SELECTOR.prepare(request)
    selection["compiler_alias_state"] = SELECTOR.compiler_alias_state(selection)
    require(selection["compile_phase"] is not None and len(request["compile_phase"]["commands"]) == 6,
            "unreviewed-compile-phase")
    require({k: str(v) for k, v in selection["roots"].items()} == native["layout"]["roots"], "discovery-roots-mismatch")
    require(selection["tools"] == native["layout"]["tools"], "discovery-tool-identities-changed")
    require(selection["compiler_alias_state"] == native["layout"]["compiler_path_aliases"], "discovery-aliases-changed")
    require(result.get("status") == "awaiting-root-review" and result.get("accepted") is False
            and result.get("final_protocol_ready") is False and type(result.get("exit_code")) is int
            and result["exit_code"] == 0 and result.get("unresolved_effective_paths") == [], "invalid-discovery-result")
    phase = selection["compile_phase"]
    require(result["compile_phase"] == phase and result["selected_tools"] == selection["tools"]
            and result["compiler_path_aliases"] == selection["compiler_alias_state"], "discovery-binding-mismatch")
    searches, absences = expected_searches(selection, request)
    roots, projects = selection["roots"], request["project_roots"]
    sdk, chain = roots["SDK"], roots["TOOLCHAIN"]
    runtime = deferred_reference(result, phase, roots, expected)
    proposal = dict(roots=native["layout"]["roots"], project_roots=projects,
                    explicit_search_paths=selection["explicit_search_paths"], search_flags=request["search_flags"],
                    sdk_name="iphonesimulator", sdk_version=expected["versions"]["sdk_version"],
                    sdk_build=expected["versions"]["sdk_build"], target=expected["target"],
                    clang_resource=covered(chain / "usr/lib/clang/21", roots, {}),
                    swift_paths={
                        "runtimeResourcePath": [covered(chain / "usr/lib/swift", roots, {})],
                        "runtimeLibraryPaths": [covered(chain / "usr/lib/swift/iphonesimulator", roots, {}), runtime],
                        "runtimeLibraryImportPaths": [covered(chain / "usr/lib/swift/iphonesimulator", roots, {}),
                                                      covered(sdk / "usr/lib/swift", roots, {})],
                        "sdkPath": [covered(sdk, roots, {})],
                    }, clang_search_paths=searches, unsealed_absence_dependencies=absences)
    require(canonical_search_spellings(result["proposal"], expected) == proposal
            and result["deferred_target_runtime_references"] == [runtime],
            "unexpected-effective-search-context")
    require(selected_layout(expected, native["selected"]) == native["layout"], "native-inputs-changed")
    return dict(status="bound-candidate", accepted=False, final_protocol_ready=False,
                precompilation_content_sha256=candidate["content_sha256"],
                selector_request_sha256=SELECTOR.content_digest(request),
                selector_result_sha256=SELECTOR.content_digest(result), compile_phase=phase,
                absence_dependencies=native["layout"]["absences"], deferred_target_runtime_references=[runtime],
                runtime_closure_proven=False, wall_seconds=time.perf_counter() - started)
