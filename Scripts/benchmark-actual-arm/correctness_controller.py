#!/usr/bin/env python3
"""새 설치 없이 승인된 복구 상태를 한 번 관측하고 외부 실행 영수증을 보존한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import types
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent

# 초기 정책 파일은 자체 import 캐시를 거치지 않는다. 바깥 원래 소스 가드도 이 파일을 봉인한다.
_policy_path = ROOT / "source_import_policy.py"
_policy_fd = os.open(_policy_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
try:
    _before = os.fstat(_policy_fd)
    _identity = lambda row: (row.st_dev, row.st_ino, row.st_mode, row.st_size, row.st_mtime_ns, row.st_ctime_ns)
    if not stat.S_ISREG(_before.st_mode) or not 0 < _before.st_size <= 65536:
        raise ValueError("Initial source policy is not bounded")
    _data = os.read(_policy_fd, 65537)
    if (
        len(_data) != _before.st_size
        or _identity(os.fstat(_policy_fd)) != _identity(_before)
        or _identity(_policy_path.lstat()) != _identity(_before)
    ):
        raise ValueError("Initial source policy changed")
finally:
    os.close(_policy_fd)
source_policy = types.ModuleType("source_import_policy")
source_policy.__file__ = str(_policy_path)
exec(compile(_data, str(_policy_path), "exec"), source_policy.__dict__)
sys.modules["source_import_policy"] = source_policy

with source_policy.guarded_imports(ROOT):
    sys.path.insert(0, str(ROOT))
    sys.path.insert(0, str(ROOT / "runtime"))
    sys.path.insert(0, str(ROOT / "primitive"))
    import runtime_bootstrap as bootstrap
    import runtime_identity as identity
    import isolated_measure
    import installation_binding
    import selected_launch
    import startup_profile
    import profile_collection
    import state_inputs
    import attempt_receipts
    import contract_prerequisites

    sys.path.insert(0, str(ROOT / "primitive/vendor"))
    import command_runner

SOURCE_FILES = list(source_policy.ENGINE_SOURCES)


def source_hashes(names=None):
    if names is None:
        names = contract_prerequisites.source_paths(SOURCE_FILES)
    return {str((ROOT / name).resolve()): identity.file_identity(ROOT / name)["sha256"] for name in names}


def isolation():
    if not (sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode):
        raise ValueError("Controller requires -I -S -B before all imports")


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write("\n")


def canonical_scratch(value):
    root = Path(value)
    selected = os.environ.get("RUNNER_TEMP")
    state_inputs.require(selected is not None, "Explicit current CI scratch root unavailable")
    state_inputs.require(
        root.is_absolute() and root.resolve(strict=True) == Path(selected).resolve(strict=True),
        "CI scratch request differs",
    )
    root = root.resolve(strict=True)
    state_inputs.require(root.is_dir() and root != Path("/"), "Invalid CI scratch root")
    state_inputs.require(
        not any(p.name.endswith((".sdk", ".xctoolchain")) for p in [root, *root.parents]),
        "Scratch overlaps compiler inputs",
    )
    return root


def before_write(args, destination):
    candidates = [
        ROOT,
        args.repository,
        args.lifecycle.parent,
        args.measurement.parent,
        args.setup.parent,
        Path(sys.executable),
        Path(sys.base_prefix),
    ]
    # 완전한 입력을 해석할 수 없는 경우에도 이미 알려진 경로와 별칭은 쓰기 전에 거부한다.
    for path in [args.lifecycle, args.measurement, args.setup]:
        candidates.append(path)
        try:
            value = bootstrap.strict_json(bootstrap.read_regular(path))
        except (OSError, ValueError):
            continue
        if not isinstance(value, dict):
            continue
        if path == args.lifecycle and isinstance(value.get("setup"), dict):
            setup = value["setup"]
            candidates += [
                Path(setup[key])
                for key in ("sdk_path", "developer_dir", "clang", "swiftc", "library")
                if isinstance(setup.get(key), str)
            ]
            for key in ("clang", "swiftc"):
                if isinstance(setup.get(key), str):
                    candidates += [p for p in Path(setup[key]).resolve().parents if p.name.endswith(".xctoolchain")]
        if path == args.measurement:
            command = value.get("phases", {}).get("install", {}).get("command", [])
            if (
                isinstance(command, list)
                and command.count("--target") == 1
                and command.index("--target") + 1 < len(command)
            ):
                target = command[command.index("--target") + 1]
                if isinstance(target, str):
                    candidates.append(Path(target))
    state_inputs.disjoint(destination, candidates)


def execute(args):
    """독립 시도 감독기 내부에서만 새 원시 출력과 런타임을 준비한다."""
    started = time.perf_counter()
    pre_record = attempt_receipts.pre_record
    pre_record("isolation", isolation)
    root = pre_record("scratch-boundary", canonical_scratch, args.scratch_root)
    output = root / "actual-arm-correctness-raw"
    pre_record("output-boundary", before_write, args, output)
    plan = pre_record(
        "state-inputs", state_inputs.prepare, args.repository, args.lifecycle, args.setup, args.measurement
    )
    pre_record("selected-launch", prepare_startup_profile, args, root)
    binding, launch = pre_record(
        "selected-launch", selected_launch.prepare, args, root, Path(sys.executable), source_hashes, save
    )
    sdk_path = root / "sdk-discovery-raw/results.json"
    pre_record("sdk-binding", state_inputs.bind_sdk_discovery, plan, sdk_path)
    roots = plan["input_roots"] + [binding["package"]["target"], str(sdk_path.parent)]
    if getattr(args, "calibration_mode", None) is not None:
        pre_record("calibration-sdk-binding", state_inputs.bind_calibration_sdk, plan, root)
        roots += [str(root / name) for name in ("native-calibration-sdk-raw", "native-calibration-sdk-calls")]
    pre_record("accepted-output-boundary", state_inputs.disjoint, output, roots)
    pre_record("raw-output-create", output.mkdir)
    result = dict(
        schema_version=1,
        status="failed",
        exit_code=1,
        final_evidence=False,
        role="actual-arm-correctness-controller",
        performance_ratio=None,
        superiority_claim=None,
        selected_launch={key: launch[key + "_ref"]["sha256"] for key in ("request", "observation")},
    )
    try:
        save(output / "setup/installation-binding.json", binding)
        for key in ("request", "observation"):
            save(output / ("setup/selected-launch-" + key + ".json"), launch[key])
        accepted_startup = launch["request"]["startup_profile"]["accepted_profile"]
        copy_startup_profile(root, output, args.startup_profile_sha256)
        result["contracts"] = contract_prerequisites.run(
            binding, output, SOURCE_FILES, command_runner, save, startup_profile=accepted_startup,
            interpreter_relation=launch["request"]["startup_profile"]["interpreter_relation"]
        )
        if result["contracts"]["status"] != "passed":
            raise contract_prerequisites.Failed(result["contracts"]["exit_code"])
        plan["input_roots"] = roots
        plan["raw_output"] = str(output)
        if getattr(args, "calibration_mode", None) is not None:
            state_inputs.require(args.calibration_mode == "native-observer-v1", "Unknown calibration mode")
            plan["calibration"] = state_inputs.calibration_plan()
        save(output / "setup/plan.json", plan)
        sources = source_hashes(SOURCE_FILES)
        runtime = dict(
            schema_version=3,
            package=binding["package"],
            python=binding["python"],
            code_files=sources,
            startup_profile=accepted_startup,
            interpreter_relation=launch["request"]["startup_profile"]["interpreter_relation"],
        )
        runtime_path = output / "setup/runtime.json"
        save(runtime_path, runtime)
        runtime_ref = state_inputs.reference(runtime_path)
        plan_ref = state_inputs.reference(output / "setup/plan.json")
        env = identity.private_environment(output / "private-state", Path(plan["engine_config"]["developer_directory"]))
        command = isolated_measure.bootstrap_command(
            runtime_path,
            runtime_ref["sha256"],
            ROOT / "state_worker.py",
            output / "setup/state-runtime/runtime-result.json",
            [
                "--plan",
                plan_ref["path"],
                "--plan-sha256",
                plan_ref["sha256"],
                "--runtime",
                str(runtime_path),
                "--runtime-sha256",
                runtime_ref["sha256"],
                "--output",
                str(output),
            ],
            runtime=runtime,
        )
        isolated_measure.bind_launch(command, runtime_path, runtime_ref["sha256"], runtime, env)
        call_started = time.perf_counter()
        result["preparation_wall_seconds"] = call_started - started
        result["controller_intervals"] = [
            dict(name="preparation", start=started, end=call_started, seconds=call_started - started)
        ]
        phase = command_runner.command(
            command, Path(plan["engine_config"]["project"]), output / "setup/whole-state", env,
            915 if "calibration" in plan else 540,
        )
        call_finished = time.perf_counter()
        result["controller_intervals"].append(
            dict(
                name="whole-state-supervision-call",
                start=call_started,
                end=call_finished,
                seconds=call_finished - call_started,
            )
        )
        result["whole_state_process"] = phase
        if not phase["completed"] or phase["returncode"] == 125:
            result.update(status="incomplete", exit_code=125)
        else:
            result["terminal_guard"] = state_inputs.guard(plan)
            result["runtime_source_inputs_unchanged"] = source_hashes(SOURCE_FILES) == sources
            receipt = isolated_measure.verify_runtime_receipt(
                output / "setup/state-runtime/runtime-result.json",
                runtime,
                runtime_ref["sha256"],
                ROOT / "state_worker.py",
                command[14:],
                phase["returncode"],
                env,
            )
            result["state_runtime"] = receipt
            rechecked_launch = selected_launch.verify(args, root, source_hashes())
            state_inputs.require(
                all(
                    rechecked_launch[key + "_ref"]["sha256"] == value
                    for key, value in result["selected_launch"].items()
                ),
                "Selected launch receipts changed during whole state",
            )
            state = state_inputs.document(state_inputs.reference(output / "results.json"))
            result["state_result"] = state
            if result["terminal_guard"]["status"] == "incomplete":
                result.update(status="incomplete", exit_code=125)
            elif phase["passed"] and state["status"] == "passed" and result["terminal_guard"]["status"] == "passed":
                result.update(status="passed", exit_code=0)
            else:
                result["exit_code"] = phase["returncode"] or 1
        if result.get("runtime_source_inputs_unchanged") is False and result["exit_code"] != 125:
            result.update(status="failed", exit_code=1)
    except contract_prerequisites.Failed as error:
        result.update(status="incomplete" if error.code == 125 else "failed", exit_code=error.code)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, KeyboardInterrupt) as error:
        result.update(status="incomplete", exit_code=125, failure=type(error).__name__)
    ended = time.perf_counter()
    intervals = result.setdefault("controller_intervals", [])
    previous = intervals[-1]["end"] if intervals else started
    intervals.append(
        dict(name="terminal-verification-or-failed-work", start=previous, end=ended, seconds=ended - previous)
    )
    result["total_wall_seconds_before_receipt"] = ended - started
    result["cost_accounting"] = (
        "Preparation + whole-state process + terminal verification are nested in outer child wall; no endpoint or ratio is exported"
    )
    # 상태 작업자가 시작되기 전 실패해도 정규화기의 필수 루트 영수증을 보존한다.
    if not (output / "results.json").exists():
        save(
            output / "results.json",
            dict(
                schema_version=1,
                role="actual-arm-controller-failure-before-state-result",
                status=result["status"],
                exit_code=result["exit_code"],
                final_evidence=False,
                whole_state_started="whole_state_process" in result,
            ),
        )
    save(output / "setup/controller-result.json", result)
    return result


def prepare_startup_profile(args, root):
    expected = selected_launch.private_environment(root)
    # 알려지지 않은 키/변경은 프로브를 시작하기 전에도 그대로 거부한다.
    startup_profile.observe_request(startup_profile.environment_request(expected), dict(os.environ))
    path = root / "actual-arm-correctness-attempt/startup-profile/results.json"
    if getattr(args, "selected_launch_sha256", None) is not None:
        state_inputs.require(
            getattr(args, "startup_profile_sha256", None) is not None, "Replacement startup profile is missing"
        )
        selected_launch.startup_binding(args, root, source_hashes())
        return
    state_inputs.require(
        getattr(args, "startup_profile_sha256", None) is None, "Initial process cannot supply a prior startup profile"
    )
    selected, _ = selected_launch.selected_binding(args)
    result = profile_collection.collect(
        expected,
        Path(sys.executable),
        selected,
        ROOT / "correctness_controller.py",
        [Path(name) for name in source_hashes()],
        path.parent,
        command_runner.command,
    )
    if result["exit_code"] == 125:
        raise KeyboardInterrupt("Startup profile collection incomplete")
    state_inputs.require(
        result["status"] == "passed" and type(result["exit_code"]) is int and result["exit_code"] == 0,
        "Startup profile collection failed",
    )
    args.startup_profile_sha256 = state_inputs.reference(path)["sha256"]
    selected_launch.startup_binding(args, root, source_hashes())


def copy_startup_profile(root, output, expected_sha256):
    source = root / "actual-arm-correctness-attempt/startup-profile"
    reference = state_inputs.reference(source / "results.json")
    state_inputs.require(reference["sha256"] == expected_sha256, "Startup profile changed before copy")
    result = state_inputs.document(reference)
    names = ["results.json"]
    for index in range(1, len(result["probes"]) + 1):
        names += [
            f"spelling-{index:04d}/" + name
            for name in ["request.json", "observation.json", "process.json", "process.stdout", "process.stderr"]
        ]
    copies = []
    for name in names:
        data, _ = startup_profile.read_file(source / name, startup_profile.MAX_RECEIPT_BYTES)
        target = output / "setup/startup-profile" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
        state_inputs.require(
            startup_profile.read_file(source / name, startup_profile.MAX_RECEIPT_BYTES)[0] == data,
            "Startup profile changed during copy",
        )
        copies.append(
            dict(
                original_path=str(source / name),
                artifact="setup/startup-profile/" + name,
                sha256=startup_profile.sha(data),
                bytes=len(data),
            )
        )
    save(
        output / "setup/startup-profile/copy-manifest.json",
        dict(schema_version=1, role="exact-startup-profile-copies", collection_sha256=expected_sha256, files=copies),
    )


def supervise(args):
    started = time.perf_counter()
    isolation()
    root = canonical_scratch(args.scratch_root)
    attempt = root / "actual-arm-correctness-attempt"
    before_write(args, attempt)
    attempt.mkdir()
    sources = source_hashes()
    argv = [
        sys.executable,
        "-I",
        "-S",
        "-B",
        str(Path(__file__).resolve()),
        "--execute",
        "--repository",
        str(args.repository),
        "--lifecycle",
        str(args.lifecycle),
        "--setup",
        str(args.setup),
        "--measurement",
        str(args.measurement),
        "--scratch-root",
        str(root),
    ]
    if getattr(args, "calibration_mode", None) is not None:
        state_inputs.require(args.calibration_mode == "native-observer-v1", "Unknown calibration mode")
        argv += ["--calibration-mode", args.calibration_mode]
    env = identity.private_environment(attempt / "private-preparation")
    # 작업 소유 scratch 경계만 명시적으로 전달한다. 자식은 그 외 상속 값을 읽지 않는다.
    env["RUNNER_TEMP"] = str(root)
    phase = command_runner.command(
        argv, ROOT, attempt / "process", env,
        1200 if getattr(args, "calibration_mode", None) is not None else 600,
    )
    receipt = attempt_receipts.envelope(phase, argv, sources, time.perf_counter() - started)
    try:
        receipt["source_inputs_unchanged"] = source_hashes() == sources
        receipt["source_guard_status"] = "passed" if receipt["source_inputs_unchanged"] else "changed"
    except (OSError, ValueError, RuntimeError) as error:
        receipt.update(
            source_inputs_unchanged=False, source_guard_status="unavailable", source_guard_failure=type(error).__name__
        )
    if not receipt["source_inputs_unchanged"] and receipt["exit_code"] != 125:
        receipt["exit_code"] = 1
    receipt["phase_receipt_sha256"] = attempt_receipts.sha((attempt / "process.json").read_bytes())
    save(attempt / "results.json", receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repository", "lifecycle", "setup", "measurement", "scratch-root"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--selected-launch-sha256")
    parser.add_argument("--startup-profile-sha256")
    parser.add_argument("--calibration-mode", choices=["native-observer-v1"])
    args = parser.parse_args()
    try:
        if args.selected_launch_sha256 is not None and not args.execute:
            raise ValueError("Selected launch marker requires measured child")
        result = execute(args) if args.execute else supervise(args)
    except attempt_receipts.PreRecordFailure as error:
        print(json.dumps(error.diagnostic, sort_keys=True), file=sys.stderr)
        raise SystemExit(error.exit_code)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, KeyboardInterrupt) as error:
        print(json.dumps(dict(status="refused-before-record", failure=type(error).__name__)), file=sys.stderr)
        raise SystemExit(125 if isinstance(error, KeyboardInterrupt) else 1)
    print(
        json.dumps(
            dict(status=result.get("status", "attempt-recorded"), final_evidence=False, exit_code=result["exit_code"])
        )
    )
    raise SystemExit(result["exit_code"])


if __name__ == "__main__":
    main()
