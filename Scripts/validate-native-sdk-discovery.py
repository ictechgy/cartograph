#!/usr/bin/env python3
"""검증된 iOS 컴파일 세대를 읽어 SDK 검색 경계를 제안하고 승인 없이 보존한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ROOT / "Scripts/benchmark-inputs"
FIXTURE = ROOT / "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation"
sys.path.insert(0, str(FIXTURE))
import compiler_generations as GENERATIONS
import validation_common as COMMON


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SELECTOR = load_module("sdk_root_selector", INPUTS / "select_sdk_roots.py")
RUNNER_PATH = ROOT / "Scripts/validate-native-measurement.py"


def reviewed_command():
    """검토한 실행기 바이트만 불러오며 해시 뒤 파일을 다시 열지 않는다."""
    identity = SELECTOR.file_identity(RUNNER_PATH, SELECTOR.MAX_TEXT_BYTES, True)
    require(identity["sha256"] == SELECTOR.RUNNER_SHA256, "unreviewed-command-runner")
    namespace = {"__name__": "sdk_discovery_runner", "__file__": str(RUNNER_PATH)}
    exec(compile(identity["text"], str(RUNNER_PATH), "exec"), namespace)
    return namespace["command"]


def digest(path: Path) -> str:
    return SELECTOR.file_identity(path.resolve())["sha256"]


def helper_hashes() -> dict:
    paths = [
        Path(__file__),
        RUNNER_PATH,
        INPUTS / "select_sdk_roots.py",
        INPUTS / "sdk_content_seal.py",
        Path(GENERATIONS.__file__),
        Path(COMMON.__file__),
    ]
    return {str(p.relative_to(ROOT)): digest(p) for p in paths}


def document(path: Path) -> tuple[dict, dict]:
    identity = SELECTOR.file_identity(path, SELECTOR.MAX_TEXT_BYTES, True)
    value = SELECTOR.strict_json(identity.pop("text"))
    if not isinstance(value, dict) and not isinstance(value, list):
        raise SELECTOR.DiscoveryError("invalid-input-document")
    return value, identity


def require(value: bool, reason: str) -> None:
    if not value:
        raise SELECTOR.DiscoveryError(reason)


def input_boundary(output: Path, lifecycle: Path, setup: dict) -> None:
    destinations = [output.absolute(), output.resolve()]
    candidates = [lifecycle.absolute(), lifecycle.resolve()]
    for key in ("swiftc", "clang", "library"):
        path = SELECTOR.clean_path(setup[key])
        for identity in (path.absolute(), path.resolve()):
            candidates += [p for p in identity.parents if p.name.endswith(".xctoolchain")]
    sdk = SELECTOR.clean_path(setup["sdk_path"])
    candidates += [sdk.absolute(), sdk.resolve()]
    for destination in destinations:
        for path in candidates:
            require(
                not destination.is_relative_to(path) and not path.is_relative_to(destination), "evidence-input-overlap"
            )


def build_request(setup: dict, state: dict, commands: list[dict], lifecycle: Path, xcrun: Path) -> dict:
    accepted = state["accepted_generation"]
    project = lifecycle / "Project"
    store = lifecycle / "Generations/restored_rebuilt/IndexStore"
    build = lifecycle / "Generations/restored_rebuilt/Build"
    require(accepted.get("status") == "accepted" and accepted.get("id") == "restored_rebuilt", "unaccepted-generation")
    require(
        Path(state["project"]).resolve() == project.resolve()
        and Path(accepted["store"]).resolve() == store.resolve()
        and Path(accepted["build"]).resolve() == build.resolve(),
        "generation-path-boundary",
    )
    require(
        all(p.resolve().is_relative_to(lifecycle.resolve()) for p in [project, store, build]),
        "generation-path-boundary",
    )
    require(accepted["toolchain_files"] == setup["compiler_toolchain_files"], "toolchain-receipt-mismatch")
    expected_tools = {str(Path(setup[k]).absolute()) for k in ("swiftc", "clang", "library")}
    expected_tools.add(str(Path(setup["swiftc"]).with_name("swift-frontend").absolute()))
    require(set(accepted["toolchain_files"]) == expected_tools, "unexpected-toolchain-inputs")
    expected = COMMON.command_plan(
        project,
        store,
        build,
        setup["sdk_path"],
        setup["target_triple"],
        setup["swiftc"],
        setup["clang"],
        setup["platform_path"],
        False,
    )
    require(
        commands == expected and GENERATIONS.content_digest(commands) == accepted["commands_sha256"],
        "compiler-context-mismatch",
    )
    tools = {
        name: dict(path=setup[key], sha256=accepted["toolchain_files"][str(Path(setup[key]).absolute())])
        for name, key in [("swift", "swiftc"), ("clang", "clang"), ("index_library", "library")]
    }
    tools["xcrun"] = dict(path=str(xcrun), sha256=digest(xcrun))
    module_files = {
        name.removeprefix("modules/"): sha
        for name, sha in accepted["build_files"].items()
        if name.startswith("modules/")
    }
    require(bool(module_files), "missing-module-generation")
    return dict(
        schema_version=1,
        sdk_name=setup["requested_sdk"],
        sdk=setup["sdk_path"],
        target=setup["target_triple"],
        tools=tools,
        contexts=SELECTOR.CONTEXTS,
        additional_immutable_roots={},
        project_roots={
            "PROJECT": dict(path=str(project), manifest_sha256=GENERATIONS.content_digest(accepted["source_files"])),
            "MODULES": dict(path=str(build / "modules"), manifest_sha256=GENERATIONS.content_digest(module_files)),
        },
        search_flags={
            "clang": ["-I", str(project / "Sources/BridgeKit/include")],
            "swift": ["-I", str(project / "Sources/BridgeKit/include"), "-I", str(build / "modules")],
        },
        context_options={"c": [], "objective-c": [], "c++": ["-std=c++17"], "objective-c++": ["-std=c++17"]},
        extra_contexts=[dict(id="objective-c-arc", language="objective-c", options=["-fobjc-arc"])],
    )


def execute(lifecycle_results: Path, output: Path, *, command=None, xcrun: Path = Path("/usr/bin/xcrun")) -> dict:
    started = time.perf_counter()
    lifecycle_results = lifecycle_results.absolute()
    lifecycle = lifecycle_results.parent
    data, input_identity = document(lifecycle_results)
    setup = data.get("setup", {})
    input_boundary(output, lifecycle, setup)
    output.mkdir(parents=True, exist_ok=False)
    result = dict(
        schema_version=1,
        status="failed",
        accepted=False,
        final_protocol_ready=False,
        exit_code=1,
        role="SDK and compiler search-root discovery only",
        input_files={"results.json": input_identity},
        retained_inputs=[],
        cost_scope="Entire diagnostic including receipt reads, generation guards, tool hashes, command setup and probes; identical full cost assigned to each arm for later accounting",
        limitations=[
            "No full SDK/toolchain content seal is attempted or accepted.",
            "Actual Apple root/link layout still requires review before acceptance.",
            "No compiler generation or graph/query oracle is changed.",
            "Project/module reference hashes are bound to this accepted generation only.",
            "Moving CI runner, OS/dynamic-loader dependencies and detached descendants are not hermetically proved.",
        ],
    )
    SELECTOR.save(output / "setup/lifecycle-input.json", data)
    try:
        require(
            data.get("status") == "passed"
            and data.get("ios_execution") == "compiler-only"
            and data.get("compiler_index_policy") == "fresh-shared-v2"
            and data.get("observation_failures") == [],
            "unaccepted-lifecycle",
        )
        state, state_id = document(lifecycle / "runs/restored_rebuilt/state.json")
        commands, commands_id = document(lifecycle / "runs/restored_rebuilt/commands.json")
        result["input_files"].update({"state.json": state_id, "commands.json": commands_id})
        require(
            state.get("name") == "restored_rebuilt"
            and state.get("status") == "passed"
            and state.get("compiler_index_policy") == "fresh-shared-v2",
            "unaccepted-final-state",
        )
        request = build_request(setup, state, commands, lifecycle, xcrun)
        accepted = state["accepted_generation"]
        project = Path(state["project"])
        initial_helpers = helper_hashes()
        result["helper_hashes"] = initial_helpers
        require(
            initial_helpers[str(RUNNER_PATH.relative_to(ROOT))] == SELECTOR.RUNNER_SHA256, "unreviewed-command-runner"
        )
        for name, value in [
            ("accepted-generation", accepted),
            ("compiler-contexts", commands),
            ("selector-request", request),
        ]:
            relative = "setup/" + name + ".json"
            SELECTOR.save(output / relative, value)
            result["retained_inputs"].append(relative)

        def guard(name):
            at = time.perf_counter()
            receipt = dict(status="failed")
            try:
                GENERATIONS.guard(accepted)
                GENERATIONS.verify_inputs(accepted, project)
                require(
                    COMMON.source_manifest(project) == json.loads((FIXTURE / "source-manifest.json").read_text()),
                    "source-fixture-mismatch",
                )
                require(helper_hashes() == initial_helpers, "helper-inputs-changed")
                for relative, identity in result["input_files"].items():
                    original = (
                        lifecycle_results
                        if relative == "results.json"
                        else lifecycle / "runs/restored_rebuilt" / relative
                    )
                    require(
                        SELECTOR.file_identity(original, SELECTOR.MAX_TEXT_BYTES)["sha256"] == identity["sha256"],
                        "input-receipts-changed",
                    )
                receipt["status"] = "passed"
            except (OSError, ValueError, RuntimeError, KeyError) as error:
                receipt["failure"] = "generation-inputs-changed"
                receipt["failure_type"] = type(error).__name__
            receipt["wall_seconds"] = time.perf_counter() - at
            result[name] = receipt
            return receipt["status"] == "passed"

        require(guard("generation_guard_before"), "generation-inputs-changed")
        argv = [
            sys.executable,
            str(INPUTS / "select_sdk_roots.py"),
            "--request",
            str(output / "setup/selector-request.json"),
            "--output",
            str(output / "setup/discovery"),
            "--command-runner",
            str(RUNNER_PATH),
        ]
        phase = (command or reviewed_command())(argv, ROOT, output / "setup/discovery-process", dict(os.environ), 180.0)
        result["phase"] = phase
        incomplete = not phase.get("completed") or phase.get("returncode") == 125
        if incomplete:
            result["generation_guard_after"] = dict(
                status="unavailable", reason="incomplete-process-cleanup-unverified", wall_seconds=0.0
            )
            result.update(status="incomplete", exit_code=125)
            raise SELECTOR.DiscoveryError("incomplete-discovery")
        after = guard("generation_guard_after")
        require(phase.get("passed") and phase.get("returncode") == 0, "selector-failed")
        require(after, "generation-inputs-changed")
        proposal, proposal_id = document(output / "setup/discovery/results.json")
        result["proposal_result_identity"] = proposal_id
        require(
            proposal.get("status") == "awaiting-root-review"
            and proposal.get("accepted") is False
            and proposal.get("final_protocol_ready") is False
            and proposal.get("exit_code") == 0,
            "invalid-proposal-status",
        )
        require(
            proposal["proposal"]["sdk_version"] == setup["sdk_version"]
            and proposal["proposal"]["sdk_build"] == setup["sdk_build"],
            "sdk-version-changed",
        )
        result.update(status="awaiting-root-review", exit_code=0, proposal="setup/discovery/results.json")
    except SELECTOR.DiscoveryError as error:
        result["failure"] = str(error)
    except KeyboardInterrupt:
        result.update(status="incomplete", exit_code=125, failure="interrupt")
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        result.update(failure="invalid-discovery-input", failure_type=type(error).__name__)
    result["total_wall_seconds"] = time.perf_counter() - started
    result["charged_wall_seconds_by_arm"] = {arm: result["total_wall_seconds"] for arm in GENERATIONS.ARMS}
    SELECTOR.save(output / "results.json", result)
    return result


ATTEMPT_CATEGORIES = {
    "none",
    "child-nonzero",
    "child-incomplete",
    "invalid-json",
    "duplicate-json-key",
    "invalid-json-number",
    "unreadable-input",
    "input-not-regular-file",
    "input-byte-limit",
    "input-changed-during-read",
    "evidence-input-overlap",
    "invalid-absolute-path",
    "KeyError",
    "FileNotFoundError",
    "FileExistsError",
    "unrecognized-prerecord-failure",
    "supervision-inputs-changed",
}


LOG_IDENTITY_LIMIT = 1024**3
LOG_UNAVAILABLE_REASONS = {
    "input-not-regular-file",
    "input-byte-limit",
    "input-changed-during-read",
    "unreadable-input",
}


def log_identity(path: Path) -> dict:
    """원래 프로세스 결과를 잃지 않도록 전체 바이트 해시 실패도 형식화한다."""
    try:
        value = SELECTOR.file_identity(path, LOG_IDENTITY_LIMIT)
        return dict(status="available", sha256=value["sha256"], bytes=value["bytes"])
    except SELECTOR.DiscoveryError as error:
        reason = str(error) if str(error) in LOG_UNAVAILABLE_REASONS else "unreadable-input"
        return dict(status="unavailable", reason=reason)


def diagnostic_category(path: Path, identity: dict, category: str) -> tuple[str, str]:
    """진단 해석 한도와 전체 로그 정체성 한도를 분리하고 본문은 영수증에 담지 않는다."""
    if category != "child-nonzero":
        return category, "not-needed"
    if identity["status"] != "available":
        return category, "hash-unavailable"
    try:
        value = SELECTOR.file_identity(path, SELECTOR.MAX_TEXT_BYTES, True)
        if value["sha256"] != identity["sha256"] or value["bytes"] != identity["bytes"]:
            return category, "input-changed-during-read"
        error = SELECTOR.strict_json(value["text"].strip())
    except SELECTOR.DiscoveryError as error:
        reason = str(error)
        return category, reason if reason in LOG_UNAVAILABLE_REASONS else "invalid-json"
    if isinstance(error, dict) and error.get("status") == "refused-before-record":
        reason = error.get("reason")
        return (
            reason if isinstance(reason, str) and reason in ATTEMPT_CATEGORIES else "unrecognized-prerecord-failure"
        ), "parsed"
    return category, "unrecognized-diagnostic"


def supervise(lifecycle_results: Path, output: Path, attempt: Path, *, command=None) -> dict:
    """거부된 출력과 별개인 작업 전용 경로에 내용 없는 시도 영수증을 남긴다."""
    started = time.perf_counter()
    destination = attempt.resolve()
    raw = output.resolve()
    lifecycle = lifecycle_results.absolute().parent.resolve()
    require(not destination.is_relative_to(raw) and not raw.is_relative_to(destination), "attempt-output-overlap")
    require(
        not destination.is_relative_to(lifecycle) and not lifecycle.is_relative_to(destination), "attempt-input-overlap"
    )
    require(
        not any(p.name.endswith((".sdk", ".xctoolchain")) for p in [destination, *destination.parents]),
        "attempt-input-overlap",
    )
    # 읽을 수 없는 요청은 도구 루트를 제공하지 못한다. 이름이 고정된 독립 scratch 목적지만 허용한다.
    try:
        data, _ = document(lifecycle_results)
    except SELECTOR.DiscoveryError:
        data = None
    if (
        isinstance(data, dict)
        and isinstance(data.get("setup"), dict)
        and all(key in data["setup"] for key in ("swiftc", "clang", "library", "sdk_path"))
    ):
        input_boundary(destination, lifecycle, data["setup"])
    attempt.mkdir(parents=True, exist_ok=False)
    wrapper_sha = digest(Path(__file__))
    runner_sha = digest(RUNNER_PATH)
    require(runner_sha == SELECTOR.RUNNER_SHA256, "unreviewed-command-runner")
    argv = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--lifecycle-results",
        str(lifecycle_results),
        "--output",
        str(output),
    ]
    phase = (command or reviewed_command())(argv, ROOT, attempt / "process", dict(os.environ), 240.0)
    incomplete = not phase.get("completed") or phase.get("returncode") == 125
    category = "child-incomplete" if incomplete else "none" if phase.get("passed") else "child-nonzero"
    stdout = log_identity(Path(phase["stdout"]))
    stderr = log_identity(Path(phase["stderr"]))
    category, diagnostic_status = diagnostic_category(Path(phase["stderr"]), stderr, category)
    code = 125 if incomplete else phase["returncode"]
    unchanged = digest(Path(__file__)) == wrapper_sha and digest(RUNNER_PATH) == runner_sha
    if not unchanged and not incomplete:
        code = 1
        category = "supervision-inputs-changed"
    total = time.perf_counter() - started
    receipt = dict(
        schema_version=1,
        role="sdk-discovery-attempt-envelope",
        wrapper_sha256=wrapper_sha,
        runner_sha256=runner_sha,
        argv_sha256=hashlib.sha256(json.dumps(argv, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest(),
        exit_code=code,
        observed_returncode=phase.get("observed_returncode"),
        completed=not incomplete,
        child_failure=phase.get("failure"),
        failure_category=category,
        child_wall_seconds=phase["wall_seconds"],
        total_wall_seconds=total,
        source_inputs_unchanged=unchanged,
        descendant_cleanup_verified=False,
        stdout=stdout,
        stderr=stderr,
        stderr_diagnostic_status=diagnostic_status,
        raw_output_exists=output.is_dir(),
        phase_receipt_sha256=digest(attempt / "process.json"),
        cleanup_signals=phase.get("cleanup_signals", []),
        cleanup_root_unfinished=phase.get("cleanup_root_unfinished", False),
    )
    SELECTOR.save(attempt / "results.json", receipt)
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lifecycle-results", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--attempt-output", type=Path)
    args = parser.parse_args()
    started = time.perf_counter()
    try:
        if args.attempt_output is not None:
            result = supervise(args.lifecycle_results, args.output, args.attempt_output)
        else:
            result = execute(args.lifecycle_results, args.output)
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(
            json.dumps(
                dict(
                    status="refused-before-record",
                    reason=str(error) if isinstance(error, SELECTOR.DiscoveryError) else type(error).__name__,
                    wall_seconds=time.perf_counter() - started,
                )
            ),
            file=sys.stderr,
        )
        raise SystemExit(1)
    print(json.dumps(dict(status=result.get("status", "attempt-recorded"), accepted=False, final_protocol_ready=False)))
    raise SystemExit(result["exit_code"])


if __name__ == "__main__":
    main()
