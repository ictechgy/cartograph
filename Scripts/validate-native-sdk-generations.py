#!/usr/bin/env python3
"""고정 컴파일 수명 주기를 SDK 세대 괄호와 연결하는 검증 전용 실행기."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts/benchmark-inputs"))
import native_generation_inputs as GENERATIONS

PROFILE = "sdk-generation-brackets"
PHASES = (("before-compilation", 570), ("compiler-lifecycle", 1200),
          ("sdk-discovery", 180), ("after-generation", 570))
BOUND_SECONDS = 1800
CONTEXT = "native-calibration-sdk-calls/generation-context.json"
SOURCE_PATHS = (
    "Scripts/validate-native-sdk-generations.py", "Scripts/validate-native-calibration-inputs.py",
    "Scripts/validate-native-sdk-discovery.py", "Scripts/validate-native-measurement.py",
    "Scripts/benchmark-inputs/native_calibration_publication.py",
    "Scripts/normalize-indexstore-evidence.py", ".github/workflows/native-calibration.yml",
)


def require(value, reason):
    GENERATIONS.require(value, reason)


def load_wrapper():
    path = ROOT / "Scripts/validate-native-calibration-inputs.py"
    spec = importlib.util.spec_from_file_location("generation_stage_wrapper", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_hashes():
    result = GENERATIONS.helper_hashes()
    for name in SOURCE_PATHS:
        result[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    return result


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write("\n")


def read(path):
    return GENERATIONS.SELECTOR.strict_json(GENERATIONS.SELECTOR.file_identity(path, 8 * 1024**2, True)["text"])


def reference(path):
    identity = GENERATIONS.SELECTOR.file_identity(path, 8 * 1024**2)
    return dict(path=str(path), sha256=identity["sha256"], bytes=identity["bytes"])


def context_environment(context):
    return GENERATIONS.request_environment({"environment": context["environment"]})


def verify_context(path, digest, root, *, current_environment=True):
    require(path == root / CONTEXT and reference(path)["sha256"] == digest, "generation-context-reference")
    value = read(path)
    require(set(value) == {"schema_version", "profile", "accepted", "final_protocol_ready", "scratch",
                          "environment", "environment_creation", "python", "helper_sha256"},
            "generation-context-schema")
    require(type(value["schema_version"]) is int and value["schema_version"] == 1 and value["profile"] == PROFILE
            and value["accepted"] is False and value["final_protocol_ready"] is False,
            "generation-context-schema")
    require(value["scratch"] == GENERATIONS.directory_identity(root), "generation-scratch-changed")
    require(value["helper_sha256"] == source_hashes(), "generation-source-changed")
    expected, _ = GENERATIONS.NATIVE.expectation()
    environment = context_environment(value)
    owned = GENERATIONS.environment_contract(environment, expected)
    require(value["environment_creation"] == dict(fresh=True, directories=owned), "generation-environment-changed")
    require(GENERATIONS.verify_interpreter_identity(value["python"], sys.executable), "generation-python-changed")
    require(not current_environment or dict(os.environ) == environment, "generation-environment-changed")
    return value


def create_context(root):
    expected, _ = GENERATIONS.NATIVE.expectation()
    require(all(os.environ.get(key) == value for key, value in expected["runner"].items())
            and os.environ.get("DEVELOPER_DIR") == expected["developer_lexical"], "generation-outer-native-context")
    home, temporary = root / "native-generation-home", root / "native-generation-tmp"
    home.mkdir(exist_ok=False)
    temporary.mkdir(exist_ok=False)
    environment = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C",
                       DEVELOPER_DIR=expected["developer_lexical"], **expected["runner"],
                       HOME=str(home), TMPDIR=str(temporary))
    require(not list(home.iterdir()) and not list(temporary.iterdir()), "generation-environment-not-fresh")
    owned = GENERATIONS.environment_contract(environment, expected)
    value = dict(schema_version=1, profile=PROFILE, accepted=False, final_protocol_ready=False,
                 scratch=GENERATIONS.directory_identity(root),
                 environment=GENERATIONS.environment_rows(environment),
                 environment_creation=dict(fresh=True, directories=owned),
                 python=GENERATIONS.interpreter_identity(sys.executable), helper_sha256=source_hashes())
    save(root / CONTEXT, value)
    return value


def complete_command(row, bound=None):
    return (row.get("completed") is True and row.get("passed") is True
            and type(row.get("returncode")) is int and row["returncode"] == 0
            and type(row.get("observed_returncode")) is int and row["observed_returncode"] == 0
            and row.get("failure") is None and row.get("cleanup_signals") == []
            and row.get("cleanup_root_unfinished") is False
            and type(row.get("wall_seconds")) in (int, float) and math.isfinite(row["wall_seconds"])
            and row["wall_seconds"] > 0 and (bound is None or row["wall_seconds"] <= bound))


def commands(root, context_sha):
    python = str(Path(sys.executable).absolute())
    prefix = [python, "-I", "-S", "-B"]
    wrapper = str(ROOT / "Scripts/validate-native-calibration-inputs.py")
    shared = ["--scratch-root", str(root), "--generation-context-sha256", context_sha, "--execute-stage"]
    lifecycle = root / "native-sdk-generations-lifecycle"
    request = root / "native-calibration-sdk-raw/setup/generation-request.json"
    return {
        "before-compilation": prefix + [wrapper, "--stage", "before-compilation"] + shared,
        "compiler-lifecycle": [python, "-B", str(GENERATIONS.FIXTURE / "run_ios_validation.py"),
            "--output", str(lifecycle), "--sdk", "iphonesimulator", "--deployment-target", "16.0",
            "--compiler-index-policy", "fresh-shared-v2", "--sdk-generation-request", str(request)],
        "sdk-discovery": prefix + [str(ROOT / "Scripts/validate-native-sdk-discovery.py"),
            "--lifecycle-results", str(lifecycle / "results.json"), "--output", str(root / "sdk-discovery-raw")],
        "after-generation": prefix + [wrapper, "--stage", "after-generation"] + shared,
    }


def execute(root, *, clock=time.monotonic, started=None):
    started = clock() if started is None else started
    wrapper = load_wrapper()
    expires = started + BOUND_SECONDS
    calls = root / "native-calibration-sdk-calls"
    calls.mkdir(exist_ok=False)
    result = dict(schema_version=1, profile=PROFILE, status="incomplete", exit_code=125, accepted=False,
                  final_protocol_ready=False, actual_engine_calls=0, expected_full_content_reads=18,
                  planned_compiler_commands=48, expected_executed_compiler_commands=43,
                  setup_probes=11, discovery_probes=10, phase_order=[name for name, _ in PHASES],
                  phases={name: dict(status="not-started", reason="prior-phase-unfinished") for name, _ in PHASES},
                  limitations=GENERATIONS.LIMITATIONS + [
                      "The 45-minute job can end before publication; incomplete-attempt upload is best effort.",
                      "No final composed endpoint is reported; nested costs must not be added twice.",
                      "Caller wall below excludes its own final receipt serialization and interpreter teardown.",
                  ])
    def alarm(_signal, _frame):
        raise KeyboardInterrupt("generation-controller-deadline")
    require(signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0), "existing-controller-alarm")
    previous = signal.signal(signal.SIGALRM, alarm)
    signal.setitimer(signal.ITIMER_REAL, max(0.001, expires - clock()))
    active = None
    try:
        context = create_context(root)
        context_sha = reference(root / CONTEXT)["sha256"]
        result["context"] = reference(root / CONTEXT)
        argv = commands(root, context_sha)
        environment = context_environment(context)
        for name, bound in PHASES:
            active = name
            require(expires - clock() >= bound, "insufficient-complete-phase-budget")
            verify_context(root / CONTEXT, context_sha, root, current_environment=False)
            if name == "compiler-lifecycle":
                candidate = read(root / "native-calibration-sdk-raw/before-compilation/results.json")
                request = GENERATIONS.make_request(candidate, root / "native-calibration-sdk-raw", environment,
                                                   sys.executable, environment_creation=context["environment_creation"])
                target = root / "native-calibration-sdk-raw/setup/generation-request.json"
                save(target, request)
                argv[name] += ["--sdk-generation-request-sha256", reference(target)["sha256"]]
            result["phases"][name] = dict(status="not-started", reason="launch-admission",
                                          command=argv[name], child_timeout_seconds=bound)
            save(calls / name / "started.json", result["phases"][name])
            require(expires - clock() >= bound, "insufficient-complete-phase-budget")
            result["phases"][name].update(status="started")
            del result["phases"][name]["reason"]
            row = wrapper.COMMAND.command(argv[name], ROOT, calls / name / "command", environment, bound)
            result["phases"][name]["originals"] = {
                suffix: reference(calls / name / ("command" + suffix)) for suffix in (".json", ".stdout", ".stderr")
            }
            result["phases"][name].update(status="completed" if complete_command(row, bound) else "incomplete",
                                           command_result=row)
            require(complete_command(row, bound), "generation-phase-incomplete")
            require(clock() < expires, "generation-controller-deadline")
            verify_context(root / CONTEXT, context_sha, root, current_environment=False)
            if name == "compiler-lifecycle":
                summary = read(root / "native-calibration-sdk-raw/generation-results.json")
                require(summary["status"] == "verified-candidate", "generation-lifecycle-incomplete")
                result["generation_originals"] = GENERATIONS.verify_originals(summary)
            elif name in ("before-compilation", "after-generation"):
                phase = read(root / "native-calibration-sdk-raw/setup/phases" / (name + ".json"))
                require(phase["status"] == "passed" and type(phase["exit_code"]) is int and phase["exit_code"] == 0
                        and phase["accepted"] is False and phase["final_protocol_ready"] is False,
                        "generation-seal-phase-incomplete")
            else:
                discovery = read(root / "sdk-discovery-raw/results.json")
                require(discovery["status"] == "awaiting-root-review" and type(discovery["exit_code"]) is int
                        and discovery["exit_code"] == 0 and discovery["accepted"] is False
                        and discovery["final_protocol_ready"] is False, "generation-discovery-incomplete")
        require(clock() < expires, "generation-controller-deadline")
        result.update(status="validation-candidate-complete", exit_code=0)
    except (KeyboardInterrupt, OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        result["first_failure"] = dict(phase=active, failure_type=type(error).__name__,
                                      failure_sha256=hashlib.sha256(str(error).encode()).hexdigest())
        if active and result["phases"][active]["status"] == "not-started":
            result["phases"][active]["reason"] = "phase-admission-or-deadline-refused"
        result.update(status="incomplete", exit_code=125)
    result["caller_wall_seconds_before_receipt"] = clock() - started
    result["bound_seconds"] = BOUND_SECONDS
    result["charged_wall_seconds_by_arm"] = {arm: result["caller_wall_seconds_before_receipt"]
                                            for arm in GENERATIONS.ARMS}
    target = calls / "generation-controller.json"
    receipt = None
    try:
        receipt = target.open("x+")
        json.dump(result, receipt, sort_keys=True, indent=2, allow_nan=False)
        receipt.write("\n")
        receipt.flush()
        require(clock() < expires, "generation-receipt-deadline")
    except (KeyboardInterrupt, OSError, ValueError, RuntimeError) as error:
        # 독점 생성한 열린 핸들만 실패로 확정한다. 생성 실패나 경로 교체 시 재개방하지 않는다.
        signal.setitimer(signal.ITIMER_REAL, 0)
        result.update(status="incomplete", exit_code=125)
        failure = dict(phase="final-receipt", failure_type=type(error).__name__,
                       failure_sha256=hashlib.sha256(str(error).encode()).hexdigest())
        result.setdefault("first_failure", failure)
        result["receipt_failure"] = failure
        if receipt is not None:
            try:
                receipt.seek(0)
                receipt.truncate()
                json.dump(result, receipt, sort_keys=True, indent=2, allow_nan=False)
                receipt.write("\n")
                receipt.flush()
            except (OSError, ValueError) as secondary:
                result["receipt_recovery_failure"] = dict(failure_type=type(secondary).__name__,
                    failure_sha256=hashlib.sha256(str(secondary).encode()).hexdigest())
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        if receipt is not None:
            try:
                receipt.close()
            except OSError as error:
                result.update(status="incomplete", exit_code=125)
                failure = dict(phase="receipt-close", failure_type=type(error).__name__,
                               failure_sha256=hashlib.sha256(str(error).encode()).hexdigest())
                result.setdefault("first_failure", failure)
                result["receipt_recovery_failure"] = failure
    return result



def verify_controller(root):
    """성공 표지만 신뢰하지 않고 고정 호출 원본과 완료된 세대 수를 다시 연결한다."""
    path = root / "native-calibration-sdk-calls/generation-controller.json"
    result = read(path)
    require(result["profile"] == PROFILE and result["accepted"] is False and result["final_protocol_ready"] is False
            and type(result["actual_engine_calls"]) is int and result["actual_engine_calls"] == 0,
            "generation-controller-schema")
    context = root / CONTEXT
    require(result["context"] == reference(context), "generation-context-changed")
    verify_context(context, result["context"]["sha256"], root, current_environment=False)
    require(result["phase_order"] == [name for name, _ in PHASES]
            and set(result["phases"]) == set(result["phase_order"]), "generation-phase-membership")
    expected = commands(root, reference(context)["sha256"])
    request = root / "native-calibration-sdk-raw/setup/generation-request.json"
    if request.exists():
        expected["compiler-lifecycle"] += ["--sdk-generation-request-sha256", reference(request)["sha256"]]
    stopped = False
    for name, bound in PHASES:
        phase = result["phases"][name]
        if phase["status"] == "not-started":
            require("command_result" not in phase and "originals" not in phase,
                    "unstarted-generation-has-process-receipt")
            stopped = True
            continue
        require(not stopped and phase["command"] == expected[name] and phase["child_timeout_seconds"] == bound,
                "generation-phase-order-or-command")
        if "command_result" in phase:
            row = phase["command_result"]
            for suffix in (".json", ".stdout", ".stderr"):
                target = root / "native-calibration-sdk-calls" / name / ("command" + suffix)
                require(phase["originals"][suffix] == reference(target), "generation-command-original-changed")
            require(GENERATIONS.identity(row) == GENERATIONS.identity(read(
                root / "native-calibration-sdk-calls" / name / "command.json")), "generation-command-receipt-changed")
            require(row["command"] == expected[name] and row["cwd"] == str(ROOT), "generation-command-changed")
            require((phase["status"] == "completed") == complete_command(row, bound), "generation-command-status")
        else:
            require(phase["status"] == "started", "generation-phase-status")
        stopped = phase["status"] != "completed"
    wall = result["caller_wall_seconds_before_receipt"]
    require(type(wall) in (int, float) and math.isfinite(wall) and wall > 0
            and result["charged_wall_seconds_by_arm"] == {arm: wall for arm in GENERATIONS.ARMS}
            and type(result["bound_seconds"]) is int and result["bound_seconds"] == BOUND_SECONDS,
            "generation-controller-cost")
    if result["status"] == "validation-candidate-complete":
        require(type(result["exit_code"]) is int and result["exit_code"] == 0 and not stopped
                and wall <= BOUND_SECONDS and "first_failure" not in result, "generation-controller-incomplete")
        summary = read(root / "native-calibration-sdk-raw/generation-results.json")
        require(summary["status"] == "verified-candidate" and summary["accepted"] is False
                and summary["final_protocol_ready"] is False
                and summary["lifecycle_output"] == str(root / "native-sdk-generations-lifecycle")
                and summary["request_sha256"] == reference(request)["sha256"], "generation-summary-status")
        for key, value in (("full_generation_reads", 16), ("planned_commands", 48), ("executed_commands", 43)):
            require(type(summary[key]) is int and summary[key] == value, "generation-summary-count")
        require(GENERATIONS.verify_originals(summary) == result["generation_originals"], "generation-originals-changed")
        for name in ("before-compilation", "after-generation"):
            phase = read(root / "native-calibration-sdk-raw/setup/phases" / (name + ".json"))
            require(phase["status"] == "passed" and type(phase["exit_code"]) is int and phase["exit_code"] == 0
                    and phase["accepted"] is False and phase["final_protocol_ready"] is False,
                    "generation-terminal-seal-status")
            observation = phase["observation"]
            if name == "before-compilation":
                require(observation["content_sha256"] == GENERATIONS.BASELINE_SHA256,
                        "generation-terminal-content")
            else:
                verification = observation["verification"]
                require(verification["matches"] is True
                        and verification["expected_sha256"] == verification["actual_sha256"] == GENERATIONS.BASELINE_SHA256,
                        "generation-terminal-content")
        discovery = read(root / "sdk-discovery-raw/setup/discovery/results.json")
        require(len(discovery["probes"]) == 10 and all(complete_command(row, 60) for row in discovery["probes"]),
                "generation-discovery-command-count")
    else:
        require(result["status"] == "incomplete" and type(result["exit_code"]) is int
                and result["exit_code"] == 125 and "first_failure" in result, "generation-controller-status")
    verify_supervisor(root, result)
    return reference(path)


def controller_argv(root):
    return [str(Path(sys.executable).absolute()), "-I", "-S", "-B", str(Path(__file__).resolve()),
            "--scratch-root", str(root), "--execute-controller"]


def supervise(root):
    """동일 실행기 한 번만 감싸 자식 영수증 종료 뒤 실제 상태와 전체 비용을 남긴다."""
    started = time.monotonic()
    output = root / "native-generation-supervisor"
    output.mkdir(exist_ok=False)
    wrapper = load_wrapper()
    hashes = source_hashes()
    python = GENERATIONS.interpreter_identity(sys.executable)
    row = wrapper.COMMAND.command(controller_argv(root), ROOT, output / "command", dict(os.environ), 1815)
    unchanged = source_hashes() == hashes and GENERATIONS.verify_interpreter_identity(python, sys.executable)
    result = dict(schema_version=1, profile=PROFILE, accepted=False, final_protocol_ready=False,
                  actual_engine_calls=0, command=row, helper_sha256=hashes, python=python,
                  source_inputs_unchanged=unchanged, child_timeout_seconds=1815,
                  originals={suffix: reference(output / ("command" + suffix))
                             for suffix in (".json", ".stdout", ".stderr")},
                  exit_code=0 if unchanged and complete_command(row, 1815) else 125,
                  full_call_wall_seconds_before_receipt=time.monotonic() - started,
                  cost_scope="Controller child includes its receipt/teardown; inner details overlap this interval; "
                             "supervisor final receipt/teardown excluded, no composed endpoint")
    result["status"] = "validation-candidate-process-complete" if result["exit_code"] == 0 else "incomplete"
    result["charged_wall_seconds_by_arm"] = {arm: result["full_call_wall_seconds_before_receipt"]
                                            for arm in GENERATIONS.ARMS}
    save(output / "results.json", result)
    return result


def verify_supervisor(root, inner):
    """자식 JSON의 완료 주장과 실제 외부 wait 결과를 같은 고정 호출에 묶는다."""
    output = root / "native-generation-supervisor"
    value = read(output / "results.json")
    require(value["profile"] == PROFILE and value["accepted"] is False and value["final_protocol_ready"] is False
            and type(value["actual_engine_calls"]) is int and value["actual_engine_calls"] == 0,
            "generation-supervisor-schema")
    require(value["helper_sha256"] == source_hashes() and value["source_inputs_unchanged"] is True
            and GENERATIONS.verify_interpreter_identity(value["python"], sys.executable), "generation-supervisor-inputs")
    require(type(value["child_timeout_seconds"]) is int and value["child_timeout_seconds"] == 1815,
            "generation-supervisor-bound")
    for suffix in (".json", ".stdout", ".stderr"):
        require(value["originals"][suffix] == reference(output / ("command" + suffix)),
                "generation-supervisor-original-changed")
    row = value["command"]
    require(GENERATIONS.identity(row) == GENERATIONS.identity(read(output / "command.json"))
            and row["command"] == controller_argv(root) and row["cwd"] == str(ROOT),
            "generation-supervisor-command")
    completed = complete_command(row, 1815)
    require(type(value["exit_code"]) is int and value["exit_code"] == (0 if completed else 125),
            "generation-supervisor-status")
    require(type(row.get("observed_returncode")) is int and row["observed_returncode"] == inner["exit_code"],
            "generation-controller-exit-mismatch")
    require((inner["status"] == "validation-candidate-complete") == completed, "generation-controller-exit-mismatch")
    wall = value["full_call_wall_seconds_before_receipt"]
    require(type(wall) in (int, float) and math.isfinite(wall) and wall >= row["wall_seconds"]
            and value["charged_wall_seconds_by_arm"] == {arm: wall for arm in GENERATIONS.ARMS},
            "generation-supervisor-cost")
    return reference(output / "results.json")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-root", required=True, type=Path)
    parser.add_argument("--execute-controller", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    started = time.monotonic()
    wrapper = load_wrapper()
    try:
        root = wrapper.fixed_root(args.scratch_root)
        result = execute(root, started=started) if args.execute_controller else supervise(root)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        print(json.dumps(dict(status="refused", failure_type=type(error).__name__,
                              failure_sha256=hashlib.sha256(str(error).encode()).hexdigest())), file=sys.stderr)
        return 1
    print(json.dumps({key: result[key] for key in ("status", "exit_code", "actual_engine_calls",
        "accepted", "final_protocol_ready", "first_failure", "receipt_failure", "receipt_recovery_failure") if key in result}))
    return result["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())
