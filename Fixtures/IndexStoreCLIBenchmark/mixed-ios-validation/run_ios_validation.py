#!/usr/bin/env python3
"""Build-only mixed-iOS validation lifecycle; optional external observation hook.

No product score is inferred from a successful compiler run. The hook must preserve
raw outputs and report native versus externally supplied capabilities separately.
"""

from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
from validation_common import (
    ROOT,
    STAGES,
    command_plan,
    digest,
    manifest,
    module_artifact_manifest,
    mutate,
    save,
    source_manifest,
)


def run(args: list[str], cwd: Path, stem: Path, timeout: int = 300) -> dict:
    stem.parent.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    failure, interrupted = None, None
    try:
        process = subprocess.run(args, cwd=cwd, capture_output=True, timeout=timeout)
        stdout, stderr, code = process.stdout, process.stderr, process.returncode
    except subprocess.TimeoutExpired as error:
        stdout, stderr, code = error.stdout or b"", error.stderr or b"", "timeout"
    except OSError as error:
        failure = f"{type(error).__name__}: {error}"
        stdout, stderr, code = b"", (failure + "\n").encode(), "launch-error"
    except KeyboardInterrupt as error:
        interrupted = error
        stdout, stderr, code = b"", b"Command interrupted; partial subprocess output unavailable.\n", "interrupted"
    elapsed = time.perf_counter() - started
    stem.with_suffix(".stdout").write_bytes(stdout)
    stem.with_suffix(".stderr").write_bytes(stderr)
    result = dict(
        command=args,
        cwd=str(cwd),
        exit_code=code,
        wall_seconds=elapsed,
        stdout=str(stem.with_suffix(".stdout")),
        stderr=str(stem.with_suffix(".stderr")),
    )
    if failure:
        result["error"] = failure
    save(stem.with_suffix(".json"), result)
    if interrupted is not None:
        raise interrupted
    return result


def setup_capture(args: list[str], root: Path, name: str) -> str:
    record = run(args, root, root / "setup" / name)
    if record["exit_code"] != 0:
        raise RuntimeError(f'Setup failed: {name}; see {record["stderr"]}')
    return Path(record["stdout"]).read_text().strip()


def selected_setup(args: argparse.Namespace, output: Path) -> dict:
    """Keep partial toolchain selection visible when discovery cannot finish."""
    setup = dict(status="selecting", requested_sdk=args.sdk)
    target = output / "setup/setup.json"
    save(target, setup)
    try:
        for key, name, command in [
            ("sdk_path", "sdk-path", ["xcrun", "--sdk", args.sdk, "--show-sdk-path"]),
            ("platform_path", "platform-path", ["xcrun", "--sdk", args.sdk, "--show-sdk-platform-path"]),
            ("swiftc", "swiftc-path", ["xcrun", "--find", "swiftc"]),
            ("clang", "clang-path", ["xcrun", "--find", "clang"]),
        ]:
            setup[key] = setup_capture(command, output, name)
            save(target, setup)
        library = Path(setup["swiftc"]).resolve().parent.parent / "lib/libIndexStore.dylib"
        if not library.is_file():
            raise RuntimeError("Matching libIndexStore.dylib missing beside selected Swift compiler")
        setup.update(library=str(library), library_sha256=digest(library))
        save(target, setup)
        setup_capture([setup["swiftc"], "-help"], output, "swift-help")
        setup_capture([setup["clang"], "-cc1", "--help"], output, "clang-frontend-help")
        for key, name, command in [
            ("sdk_version", "sdk-version", ["xcrun", "--sdk", args.sdk, "--show-sdk-version"]),
            ("sdk_build", "sdk-build", ["xcrun", "--sdk", args.sdk, "--show-sdk-build-version"]),
            ("xcode", "xcode-version", ["xcodebuild", "-version"]),
            ("swift_version", "swift-version", [setup["swiftc"], "--version"]),
            ("clang_version", "clang-version", [setup["clang"], "--version"]),
        ]:
            setup[key] = setup_capture(command, output, name)
            save(target, setup)
        setup.update(status="selected", developer_dir=os.environ.get("DEVELOPER_DIR"), host=platform.platform())
    except (Exception, KeyboardInterrupt) as error:
        setup.update(status="failed", error=f"{type(error).__name__}: {error}")
        save(target, setup)
        raise
    save(target, setup)
    return setup


def retain_private_snapshots(output: Path, state: dict, archives: dict, *, failure: bool = False) -> None:
    """Raw sources and compiler bytes stay outside the public-text selection roots."""
    destination = output / "private-snapshots" / state["name"]
    if failure:
        destination /= "failure"
    destination.mkdir(parents=True, exist_ok=True)
    prefix = "failure_" if failure else ""
    state[prefix + "source_snapshot"] = shutil.make_archive(str(destination / "sources"), "gztar", state["project"])
    files = manifest(Path(state["store"]))
    key = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    if key not in archives:
        archives[key] = shutil.make_archive(str(destination / "index"), "gztar", state["store"])
    state[prefix + "index_snapshot"] = archives[key]


def retain_failed_state(output: Path, state: dict, error: BaseException, archives: dict) -> None:
    """Save the primary failure even if a secondary evidence operation also fails."""
    state.update(status="failed", error=f"{type(error).__name__}: {error}")
    path = output / "runs" / state["name"] / "state.json"
    save(path, state)
    failures = []
    try:
        state["failure_current_sources"] = source_manifest(Path(state["project"]))
        state["failure_index_files"] = manifest(Path(state["store"]))
        state["failure_module_hashes"] = {
            path: digest(Path(path)) if Path(path).is_file() else None for path in state.get("module_artifacts", {})
        }
    except Exception as retention_error:
        failures.append(f"Input manifests: {type(retention_error).__name__}: {retention_error}")
    if state["execution"] == "executed":
        try:
            retain_private_snapshots(output, state, archives, failure="source_snapshot" in state)
        except Exception as retention_error:
            failures.append(f"Private snapshots: {type(retention_error).__name__}: {retention_error}")
    if failures:
        state["retention_errors"] = failures
    save(path, state)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk", choices=["iphonesimulator", "iphoneos"], default="iphonesimulator")
    parser.add_argument("--deployment-target", default="16.0")
    parser.add_argument("--with-tests", action="store_true", help="Compile optional XCTest module; never runs tests")
    parser.add_argument("--plan", action="store_true", help="Plan only, works on Linux; no compiler execution")
    parser.add_argument(
        "--continue-observation-failures",
        action="store_true",
        help="Preserve all failed observations across the declared lifecycle, return failure, and still abort on input mutation",
    )
    parser.add_argument(
        "--hook-json", type=Path, help="JSON argv list; called with --state <state.json> after every stage"
    )
    args = parser.parse_args()
    if not args.plan and platform.system() != "Darwin":
        parser.error("Real iOS SDK execution requires an existing Xcode on macOS; use --plan for offline inspection")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be absent or empty; existing evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    save(output / "results.json", dict(status="running", role="validation-only", superiority_claim=None))
    try:
        return execute(args, output)
    except (Exception, KeyboardInterrupt) as error:
        states, retention_errors = [], []
        for path in sorted((output / "runs").glob("*/state.json")):
            try:
                states.append(json.loads(path.read_text()))
            except (OSError, ValueError) as retention_error:
                retention_errors.append(
                    dict(path=str(path), error=f"{type(retention_error).__name__}: {retention_error}")
                )
        save(
            output / "results.json",
            dict(
                status="failed",
                role="validation-only",
                error=f"{type(error).__name__}: {error}",
                retained_states=states,
                retention_errors=retention_errors,
                superiority_claim=None,
            ),
        )
        print(f"Validation failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


def execute(args: argparse.Namespace, output: Path) -> int:
    if source_manifest(ROOT / "fixture") != json.loads((ROOT / "source-manifest.json").read_text()):
        raise ValueError("Fixture source hashes changed; review and refreeze validation artifacts")
    project = output / "Project"
    shutil.copytree(ROOT / "fixture", project)
    store, build = output / "IndexStore", output / "Build"
    for p in [store, build / "modules"]:
        p.mkdir(parents=True, exist_ok=True)
    if args.plan:
        sdk, platform_path, swiftc, clang = (
            "<selected-ios-sdk>",
            "<selected-ios-platform>",
            "<xcrun-swiftc>",
            "<xcrun-clang>",
        )
        setup = dict(status="plan-only-not-executed")
    else:
        setup = selected_setup(args, output)
        sdk, platform_path, swiftc, clang = (setup[key] for key in ("sdk_path", "platform_path", "swiftc", "clang"))
    architecture = "arm64" if args.sdk == "iphoneos" or platform.machine() == "arm64" else "x86_64"
    triple = f"{architecture}-apple-ios{args.deployment_target}" + (
        "-simulator" if args.sdk == "iphonesimulator" else ""
    )
    setup["target_triple"] = triple
    save(output / "setup" / "setup.json", setup)
    hook = json.loads(args.hook_json.read_text()) if args.hook_json else None
    if hook is not None and (not isinstance(hook, list) or not hook or not all(isinstance(v, str) for v in hook)):
        raise ValueError("Hook must be a nonempty JSON argv array; shell commands are not accepted")
    active_hook = hook if not args.plan else None
    accepted_sources, accepted_state, accepted_outputs = {}, None, []
    accepted_modules = {}
    index_archives = {}
    stages = []
    observation_failures = []
    for stage, operation, expected_build, variant in STAGES:
        state_dir = output / "runs" / stage
        state_dir.mkdir(parents=True)
        builds = []
        state = dict(
            status="running",
            phase="source-mutation",
            name=stage,
            project=str(project),
            store=str(store),
            sdk=args.sdk,
            triple=triple,
            expected_build=expected_build or "not-run",
            execution="plan-only" if args.plan else "executed",
            product_checks="not-run" if active_hook is None else "external-hook",
            native_unit_provenance_gate="not-run" if active_hook is None else "required-in-external-hook",
            oracle_variant=variant,
            expected_fresh=variant is not None,
            last_successful_build=accepted_state,
            active_object_outputs=accepted_outputs,
            module_artifacts=accepted_modules,
            builds=builds,
            input_contract="Same physical compiler store for both arms; verify hashes before and after each arm",
        )
        save(state_dir / "state.json", state)
        try:
            before = manifest(store)
            if operation:
                if not args.plan:
                    time.sleep(1.1)
                mutate(project, operation)
            commands = []
            state["phase"] = "compiler-validation"
            if expected_build:
                commands = command_plan(
                    project, store, build, sdk, triple, swiftc, clang, platform_path, args.with_tests
                )
                save(state_dir / "commands.json", commands)
                if not args.plan:
                    for command in commands:
                        for path in command["outputs"]:
                            Path(path).parent.mkdir(parents=True, exist_ok=True)
                        if "output_file_map" in command:
                            save(Path(command["output_map_path"]), command["output_file_map"])
                        state["command_record"] = str((state_dir / command["name"]).with_suffix(".json"))
                        save(state_dir / "state.json", state)
                        record = run(command["args"], project, state_dir / command["name"])
                        builds.append(record)
                        save(state_dir / "state.json", state)
                        if record["exit_code"] != 0:
                            break
                    success = len(builds) == len(commands) and all(b["exit_code"] == 0 for b in builds)
                    if (expected_build == "success") != success:
                        save(state_dir / "unexpected-build.json", builds)
                        raise RuntimeError(f"{stage}: expected {expected_build}; see retained compiler logs")
                    if expected_build == "failure":
                        diagnostic = Path(builds[-1]["stderr"]).read_text()
                        if (
                            not isinstance(builds[-1]["exit_code"], int)
                            or builds[-1]["exit_code"] <= 0
                            or "RenamedCore.h" not in diagnostic
                            or "file not found" not in diagnostic
                        ):
                            raise RuntimeError("Expected missing-header diagnostic was not observed")
                    if success and not list((store / "v5/units").glob("*")):
                        raise RuntimeError("Compiler succeeded but emitted no completed index units")
                    if success:
                        for command in commands:
                            if not all(Path(p).is_file() for p in command["outputs"]):
                                raise RuntimeError(f'Compiler output missing: {command["name"]}')
                            if command["name"].startswith("clang-"):
                                dependency = Path(command["outputs"][0]).with_suffix(".d").read_text()
                                header_name = (
                                    "RenamedCore.h"
                                    if (project / "Sources/BridgeKit/include/RenamedCore.h").exists()
                                    else "CGCore.h"
                                )
                                if header_name not in dependency:
                                    raise RuntimeError(
                                        f'Expected header absent from compile dependencies: {command["name"]}'
                                    )
            sources = source_manifest(project)
            after = manifest(store)
            if not expected_build and before != after:
                raise RuntimeError(f"Source-only stage mutated index bytes: {stage}")
            stale = sorted(p for p in set(sources) | set(accepted_sources) if sources.get(p) != accepted_sources.get(p))
            if expected_build == "success":
                accepted_sources, accepted_state, stale = sources, stage, []
                accepted_outputs = [p for c in commands for p in c["outputs"]]
                if not args.plan:
                    accepted_modules = module_artifact_manifest(commands, builds)
            state.update(
                phase="evidence",
                last_successful_build=accepted_state,
                changed_since_success=stale,
                current_sources=sources,
                index_files=after,
                active_object_outputs=accepted_outputs,
                module_artifacts=accepted_modules,
            )
            save(state_dir / "state.json", state)
            if not args.plan:
                retain_private_snapshots(output, state, index_archives)
            save(state_dir / "state.json", state)
            if active_hook:
                state["phase"] = "observation"
                save(state_dir / "state.json", state)
                invocation = run(
                    active_hook + ["--state", str(state_dir / "state.json")],
                    project,
                    state_dir / "observation-hook",
                    600,
                )
                state["observation_hook"] = invocation
                if manifest(store) != after or source_manifest(project) != sources:
                    raise RuntimeError(f"Observation hook changed shared input at {stage}")
                if any(
                    not Path(p).is_file() or digest(Path(p)) != record["sha256"]
                    for p, record in accepted_modules.items()
                ):
                    raise RuntimeError(f"Observation hook changed accepted module artifact at {stage}")
                if invocation["exit_code"] != 0:
                    error = RuntimeError(f"Observation failed at {stage}; evidence retained")
                    completed_exit = type(invocation["exit_code"]) is int and invocation["exit_code"] > 0
                    if not completed_exit:
                        state["observation_process_lifecycle"] = {
                            "completed": False,
                            "descendant_cleanup_verified": False,
                            "continuation": "aborted-before-next-source-state",
                            "limitation": "Inner subprocess timeout/signal termination does not prove all descendants exited",
                        }
                    if not args.continue_observation_failures or not completed_exit:
                        raise error
                    retain_failed_state(output, state, error, index_archives)
                    observation_failures.append(stage)
                    stages.append(state)
                    continue
            state.update(status="passed", phase="completed")
            save(state_dir / "state.json", state)
            stages.append(state)
        except (Exception, KeyboardInterrupt) as error:
            retain_failed_state(output, state, error, index_archives)
            raise
    save(
        output / "results.json",
        dict(
            status="failed" if observation_failures else "passed",
            observation_failures=observation_failures,
            role="validation-only",
            setup=setup,
            states=stages,
            ios_execution="not-run" if args.plan else "compiler-only",
            caller_correctness="not-run" if active_hook is None else "see external-hook evidence",
            native_unit_provenance_gate="not-run" if active_hook is None else "see external-hook evidence",
            framework_selection="not-scored",
            runtime_execution="not-run",
            superiority_claim=None,
        ),
    )
    print(f'{"Planned" if args.plan else "Compiled"} {len(stages)} validation states; no superiority claim')
    return 1 if observation_failures else 0


if __name__ == "__main__":
    sys.exit(main())
