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
import stat
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



def stable_command(row):
    """별도 파일로 출력하는 고정 자식의 반환된 종료/정리 영수증만 인정한다."""
    return (type(row) is dict and type(row.get("observed_returncode")) is int
            and -255 <= row["observed_returncode"] <= 255 and row.get("cleanup_root_unfinished") is False
            and row.get("cleanup_signals") == [] and row.get("failure") in (None, "nested-incomplete")
            and row.get("ownership_uncertain", False) is False
            and row.get("wait_ownership_uncertain", False) is False)


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
                  nested_material_safe=True,
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
            result["nested_material_safe"] = False
            row = wrapper.COMMAND.command(argv[name], ROOT, calls / name / "command", environment, bound)
            result["nested_material_safe"] = stable_command(row)
            result["phases"][name]["originals"] = ({
                suffix: reference(calls / name / ("command" + suffix)) for suffix in (".json", ".stdout", ".stderr")
            } if stable_command(row) else {})
            result["phases"][name].update(status="completed" if complete_command(row, bound) and stable_command(row) else "incomplete",
                                           command_result=row)
            require(complete_command(row, bound) and stable_command(row), "generation-phase-incomplete")
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



DIAGNOSTIC_TYPES = frozenset({
    "OSError", "FileNotFoundError", "FileExistsError", "PermissionError", "IsADirectoryError",
    "NotADirectoryError", "ValueError", "RuntimeError", "KeyError", "TypeError", "KeyboardInterrupt",
    "GenerationError", "AdmissionError", "IncompleteAdmission", "DiscoveryError", "SealError",
})
DIAGNOSTIC_PHASES = frozenset(name for name, _ in PHASES) | {None, "final-receipt", "receipt-close"}


def diagnostic_hash(value):
    return type(value) is str and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def diagnostic_failure(value, *, recovery=False):
    fields = {"phase", "failure_type", "failure_sha256"}
    require(type(value) is dict and (set(value) == fields or recovery and set(value) == fields - {"phase"}),
            "diagnostic-failure-shape")
    phase, kind, digest = value.get("phase"), value["failure_type"], value["failure_sha256"]
    require((phase is None or type(phase) is str) and phase in DIAGNOSTIC_PHASES
            and type(kind) is str and kind in DIAGNOSTIC_TYPES and diagnostic_hash(digest),
            "diagnostic-failure-fields")
    return dict(phase=phase, failure_type=kind, failure_sha256=digest)


def diagnostic_wall(value):
    try:
        return value if type(value) in (int, float) and math.isfinite(value) and value >= 0 else None
    except OverflowError:
        return None


def child_diagnostic(output, row, originals):
    """완료된 자식의 제한된 영수증만 투영하며 원문이나 예외 문자열을 공개하지 않는다."""
    number = lambda value: value if type(value) is int and -255 <= value <= 255 else None
    wall = row.get("wall_seconds")
    result = dict(status="unavailable", source=None, failures={}, original_sha256={},
                  returncode=number(row.get("returncode")), observed_returncode=number(row.get("observed_returncode")),
                  wall_seconds=diagnostic_wall(wall))
    if row.get("cleanup_root_unfinished") is not False or type(row.get("observed_returncode")) is not int:
        return result
    for suffix, label in ((".json", "command"), (".stdout", "stdout"), (".stderr", "stderr")):
        ref = originals.get(suffix)
        if type(ref) is dict and diagnostic_hash(ref.get("sha256")):
            result["original_sha256"][label] = ref["sha256"]
    try:
        for suffix, label in ((".stdout", "stdout"), (".stderr", "stderr")):
            original = originals[suffix]
            identity = GENERATIONS.SELECTOR.file_identity(output / ("command" + suffix), 8 * 1024**2, True)
            require(diagnostic_hash(original["sha256"]) and identity["sha256"] == original["sha256"]
                    and type(original["bytes"]) is int and identity["bytes"] == original["bytes"],
                    "diagnostic-original-changed")
            if not identity["text"].strip():
                continue
            value = GENERATIONS.SELECTOR.strict_json(identity["text"])
            require(type(value) is dict, "diagnostic-receipt-shape")
            if label == "stderr":
                require(set(value) == {"status", "failure_type", "failure_sha256"}
                        and value["status"] == "refused", "diagnostic-refusal-shape")
                failures = {"first_failure": diagnostic_failure({"phase": None,
                    "failure_type": value["failure_type"], "failure_sha256": value["failure_sha256"]})}
            else:
                keys = {"status", "exit_code", "actual_engine_calls", "accepted", "final_protocol_ready"}
                allowed = {"first_failure", "receipt_failure", "receipt_recovery_failure"}
                require(keys <= set(value) <= keys | allowed and type(value["status"]) is str
                        and value["status"] in ("incomplete", "validation-candidate-complete")
                        and type(value["exit_code"]) is int and value["exit_code"] in (0, 125)
                        and type(value["actual_engine_calls"]) is int and value["actual_engine_calls"] == 0
                        and value["accepted"] is False and value["final_protocol_ready"] is False,
                        "diagnostic-controller-shape")
                failures = {key: diagnostic_failure(value[key], recovery=key == "receipt_recovery_failure")
                            for key in sorted(allowed & set(value))}
            result.update(status="decoded", source=label, failures=failures)
            break
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, OverflowError):
        # 원래 상태/비용을 바꾸지 않으며 누락·변조·해석 실패는 같은 고정 분류로 남긴다.
        result.update(status="unavailable", source=None, failures={})
    return result


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
    stable = stable_command(row)
    originals = {}
    if stable:
        try:
            originals = {suffix: reference(output / ("command" + suffix))
                         for suffix in (".json", ".stdout", ".stderr")}
        except (OSError, ValueError, RuntimeError):
            # 원본을 읽을 수 없어도 실제 실패를 보존하되 성공으로 승격하지 않는다.
            originals = {}
    diagnostic = child_diagnostic(output, row, originals)
    result = dict(schema_version=1, profile=PROFILE, accepted=False, final_protocol_ready=False,
                  actual_engine_calls=0, command=row, helper_sha256=hashes, python=python,
                  source_inputs_unchanged=unchanged, child_timeout_seconds=1815,
                  originals=originals, child_diagnostic=diagnostic, nested_material_safe=stable,
                  exit_code=0 if unchanged and len(originals) == 3 and complete_command(row, 1815) else 125,
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
    require(GENERATIONS.identity(value.get("child_diagnostic")) == GENERATIONS.identity(
        child_diagnostic(output, row, value["originals"])), "generation-diagnostic-changed")
    return reference(output / "results.json")


CAPSULE_ROLE = "sdk-generation-failure-capsule-v1"
CAPSULE_MAX_FILE = 8 * 1024**2
CAPSULE_MAX_TOTAL = 64 * 1024**2
CAPSULE_REASONS = frozenset({
    "context-admission", "installation-binding", "native-admission", "sdk-capture", "sdk-postcheck",
    "command-incomplete", "receipt-finalization", "source-changed", "unclassified",
})
CAPSULE_STATUSES = frozenset({
    "started", "passed", "failed", "incomplete", "not-started", "completed", "refused", "unavailable",
    "captured-candidate", "verified-candidate", "candidate-in-progress", "retained-failure",
    "validation-candidate-complete", "validation-candidate-process-complete", "awaiting-root-review",
})


def safe_phase_chain(phase):
    """고정 세 계층만 공개하고 알려지지 않은 예외 값은 해시로만 남긴다."""
    diagnostic = phase.get("diagnostic", {})
    if type(diagnostic) is not dict:
        return []
    admission = diagnostic.get("admission", {}) if "stage" in phase else diagnostic
    rows = [("phase-wrapper", phase)] if "stage" in phase else []
    if type(admission) is dict:
        level = "SDK-capture" if admission.get("checkpoint") in ("sdk-capture", "sdk-postcheck") else "SDK-admission"
        rows.append((level, admission))
    result = []
    for level, value in rows:
        if type(value) is not dict or not ("failure_sha256" in value or "failure_type" in value):
            continue
        checkpoint = value.get("checkpoint", diagnostic.get("checkpoint", "unclassified"))
        kind, digest = value.get("failure_type"), value.get("failure_sha256")
        result.append(dict(level=level,
            checkpoint=checkpoint if type(checkpoint) is str and checkpoint in CAPSULE_REASONS else "unclassified",
            failure_type=kind if type(kind) is str and kind in DIAGNOSTIC_TYPES else None,
            failure_sha256=digest if diagnostic_hash(digest) else None))
    return result


def safe_stream(text):
    """전체 원문 하나가 고정 JSON 스키마일 때만 제한된 상태를 투영한다."""
    unavailable = dict(status="unavailable")
    if len(text.encode("utf-8")) > 65536:
        return unavailable
    try:
        value = GENERATIONS.SELECTOR.strict_json(text)
        require(type(value) is dict, "capsule-stream-shape")
        if set(value) == {"status", "failure_type", "failure_sha256"}:
            require(value["status"] == "refused", "capsule-stream-status")
            failure = diagnostic_failure(dict(phase=None, failure_type=value["failure_type"],
                                              failure_sha256=value["failure_sha256"]))
            return dict(status="decoded", schema="early-refusal", failure=failure)
        phase_keys = {"stage", "exit_code", "accepted", "final_protocol_ready"}
        if phase_keys <= set(value) <= phase_keys | {"failure_chain"}:
            require(value["stage"] in ("before-compilation", "after-generation")
                    and type(value["exit_code"]) is int and 0 <= value["exit_code"] <= 255
                    and value["accepted"] is False and value["final_protocol_ready"] is False,
                    "capsule-phase-stream")
            chain = value.get("failure_chain", [])
            require(type(chain) is list and len(chain) <= 3, "capsule-failure-chain")
            levels = ("phase-wrapper", "SDK-admission", "SDK-capture")
            previous = -1
            for row in chain:
                require(type(row) is dict and set(row) == {"level", "checkpoint", "failure_type", "failure_sha256"}
                        and type(row["level"]) is str and row["level"] in levels
                        and levels.index(row["level"]) > previous
                        and type(row["checkpoint"]) is str and row["checkpoint"] in CAPSULE_REASONS
                        and (row["failure_type"] is None or type(row["failure_type"]) is str
                             and row["failure_type"] in DIAGNOSTIC_TYPES)
                        and (row["failure_sha256"] is None or diagnostic_hash(row["failure_sha256"])),
                        "capsule-failure-chain")
                previous = levels.index(row["level"])
            return dict(status="decoded", schema="phase-terminal", observation=value)
        keys = {"status", "exit_code", "actual_engine_calls", "accepted", "final_protocol_ready"}
        allowed = {"first_failure", "receipt_failure", "receipt_recovery_failure"}
        require(keys <= set(value) <= keys | allowed and value["status"] in
                ("incomplete", "validation-candidate-complete") and type(value["exit_code"]) is int
                and value["exit_code"] in (0, 125) and type(value["actual_engine_calls"]) is int
                and value["actual_engine_calls"] == 0 and value["accepted"] is False
                and value["final_protocol_ready"] is False, "capsule-controller-stream")
        failures = {key: diagnostic_failure(value[key], recovery=key == "receipt_recovery_failure")
                    for key in sorted(allowed & set(value))}
        return dict(status="decoded", schema="controller-terminal", reported_exit=value["exit_code"], failures=failures)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, OverflowError):
        return unavailable


def invocation_status(root):
    require(os.environ.get("GENERATION_STATUS_FINALIZED") == "true", "capsule-status-not-finalized")
    value = read(root / "generation-invocation-status.json")
    require(type(value) is dict and set(value) == {"schema_version", "mode", "source_sha", "actual_shell_exit", "checkpoint",
                                                 "run_id", "run_attempt", "prelaunch_outputs_absent"}
            and type(value["schema_version"]) is int and value["schema_version"] == 1
            and value["mode"] == "sdk-generation-only" and value["checkpoint"] == "invocation-returned"
            and type(value["source_sha"]) is str and len(value["source_sha"]) == 40
            and all(char in "0123456789abcdef" for char in value["source_sha"])
            and value["source_sha"] == os.environ.get("GITHUB_SHA")
            and type(value["actual_shell_exit"]) is int and 0 <= value["actual_shell_exit"] <= 255
            and type(value["prelaunch_outputs_absent"]) is bool
            and all(type(value[key]) is int and value[key] > 0 and str(value[key]) == os.environ.get(environment)
                    for key, environment in (("run_id", "GITHUB_RUN_ID"), ("run_attempt", "GITHUB_RUN_ATTEMPT"))),
            "capsule-invocation-status")
    return value


class CapsuleReader:
    """허용된 슬롯만 no-follow로 읽고 누락까지 끝점 재검사의 일부로 보존한다."""
    def __init__(self, root):
        self.root, self.total, self.inputs = root, 0, {}

    def original(self, relative, *, parse=True):
        path = self.root / relative
        require(relative in CAPSULE_PATHS, "capsule-unknown-slot")
        require(relative not in self.inputs, "capsule-duplicate-read")
        current = self.root
        try:
            for component in Path(relative).parts[:-1]:
                current = current / component
                require(stat.S_ISDIR(current.lstat().st_mode), "capsule-parent-not-directory")
            info = path.lstat()
        except FileNotFoundError:
            self.inputs[relative] = dict(status="unavailable")
            return None
        require(stat.S_ISREG(info.st_mode), "capsule-input-not-regular")
        require(info.st_size <= CAPSULE_MAX_FILE and self.total + info.st_size <= CAPSULE_MAX_TOTAL,
                "capsule-input-byte-limit")
        item = GENERATIONS.SELECTOR.file_identity(path, min(CAPSULE_MAX_FILE, CAPSULE_MAX_TOTAL - self.total), True)
        self.total += item["bytes"]
        self.inputs[relative] = dict(status="available", sha256=item["sha256"], bytes=item["bytes"])
        if not parse:
            return item["text"]
        try:
            value = GENERATIONS.SELECTOR.strict_json(item["text"])
            require(type(value) is dict, "capsule-input-shape")
            return value
        except (ValueError, RuntimeError, TypeError):
            self.inputs[relative]["status"] = "malformed"
            return None


def safe_record(value):
    """숫자·불리언·고정 분류만 투영하고 보고된 SDK 값에는 증명 의미를 부여하지 않는다."""
    result = {}
    if type(value.get("status")) is str and value["status"] in CAPSULE_STATUSES:
        result["reported_status"] = value["status"]
    for key in ("exit_code", "returncode", "observed_returncode"):
        if type(value.get(key)) is int and -255 <= value[key] <= 255:
            result["reported_" + key] = value[key]
    for key in ("wall_seconds", "wall_seconds_before_receipt", "caller_wall_seconds_before_receipt",
                "full_call_wall_seconds_before_receipt", "native_admission_wall_seconds",
                "seal_capture_wall_seconds", "seal_verification_wall_seconds"):
        if diagnostic_wall(value.get(key)) is not None:
            result[key] = value[key]
    for key in ("accepted", "final_protocol_ready", "nested_material_safe"):
        if type(value.get(key)) is bool:
            result["reported_" + key] = value[key]
    for key in ("failure_sha256", "content_sha256", "expectation_sha256"):
        if diagnostic_hash(value.get(key)):
            result["reported_" + key] = value[key]
    if type(value.get("failure_type")) is str and value["failure_type"] in DIAGNOSTIC_TYPES:
        result["failure_type"] = value["failure_type"]
    diagnostic = value.get("diagnostic", {})
    if type(diagnostic) is dict:
        if type(diagnostic.get("checkpoint")) is str and diagnostic["checkpoint"] in CAPSULE_REASONS:
            result["checkpoint"] = diagnostic["checkpoint"]
        if type(diagnostic.get("nested_material_safe")) is bool:
            result["reported_nested_material_safe"] = diagnostic["nested_material_safe"]
        result["failure_chain"] = safe_phase_chain(value)
    for key in ("first_failure", "receipt_failure", "receipt_recovery_failure"):
        try:
            if key in value:
                result[key] = diagnostic_failure(value[key], recovery=key == "receipt_recovery_failure")
        except (ValueError, TypeError, KeyError):
            result[key] = dict(status="unavailable")
    return result


def capsule_command(reader, relative, value, argv, cwd):
    require(value.get("command") == argv and value.get("cwd") == str(cwd), "capsule-command-binding")
    result = safe_record(value)
    for key in ("completed", "passed", "cleanup_root_unfinished"):
        require(type(value.get(key)) is bool, "capsule-command-flags")
        result[key] = value[key]
    require(type(value.get("returncode")) is int and -255 <= value["returncode"] <= 255
            and (value.get("observed_returncode") is None or type(value["observed_returncode"]) is int
                 and -255 <= value["observed_returncode"] <= 255), "capsule-command-exit")
    require(diagnostic_wall(value.get("wall_seconds")) is not None, "capsule-command-wall")
    signals = value.get("cleanup_signals")
    require(type(signals) is list and all(type(x) is str and x in
            ("term-sent", "term-target-already-exited", "kill-sent", "kill-target-already-exited") for x in signals)
            and len(signals) <= 2, "capsule-command-cleanup")
    result["cleanup_signals"] = signals
    result["fixed_failure"] = value.get("failure") if value.get("failure") in (
        None, "nested-incomplete", "signal", "timeout", "interrupt", "launch") else "unclassified"
    result["streams"] = {}
    for suffix in ("stdout", "stderr"):
        target = relative.removesuffix("json") + suffix
        require(value.get(suffix) == str(reader.root / target), "capsule-stream-path")
        if not stable_command(value):
            result["streams"][suffix] = dict(status="withheld-unstable")
            continue
        text = reader.original(target, parse=False)
        row = dict(reader.inputs[target])
        row["safe_json"] = safe_stream(text) if text is not None else dict(status="unavailable")
        decoded = row["safe_json"]
        reported = decoded.get("reported_exit", decoded.get("observation", {}).get("exit_code"))
        row["success_marker_conflict"] = reported == 0 and value.get("observed_returncode") != 0
        result["streams"][suffix] = row
    return result


def native_probe_argv(name, expected):
    if name.startswith("machine-"):
        field = {"machine-machdep_cpu_brand_string": "machdep.cpu.brand_string"}.get(
            name, name.removeprefix("machine-").replace("_", ".", 1))
        # 원래 sysctl 이름은 첫 구분자만 점이며 나머지 밑줄은 필드 일부이다.
        return ["/usr/sbin/sysctl", "-n", field]
    fixed = {
        "sdk-path": ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
        "swift-path": ["/usr/bin/xcrun", "--find", "swiftc"],
        "clang-path": ["/usr/bin/xcrun", "--find", "clang"],
        "os-build": ["/usr/bin/sw_vers", "-buildVersion"],
        "xcode-version": ["/usr/bin/xcodebuild", "-version"],
        "sdk-version": ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
        "sdk-build": ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"],
    }
    return fixed.get(name)



def capsule_controller_prefix(value):
    require(value.get("profile") == PROFILE and value.get("accepted") is False
            and value.get("final_protocol_ready") is False and type(value.get("actual_engine_calls")) is int
            and value["actual_engine_calls"] == 0 and value.get("phase_order") == [name for name, _ in PHASES]
            and type(value.get("phases")) is dict and set(value["phases"]) == {name for name, _ in PHASES},
            "capsule-controller-schema")
    admitted, stopped = [], False
    for name, bound in PHASES:
        phase = value["phases"][name]
        require(type(phase) is dict and phase.get("status") in ("not-started", "started", "completed", "incomplete"),
                "capsule-phase-status")
        if phase["status"] == "not-started":
            require("command_result" not in phase and "originals" not in phase, "capsule-unstarted-receipt")
            stopped = True
            continue
        require(not stopped and type(phase.get("child_timeout_seconds")) is int
                and phase["child_timeout_seconds"] == bound, "capsule-phase-prefix")
        if "command_result" in phase:
            require(type(phase["command_result"]) is dict and
                    (phase["status"] == "completed") == (complete_command(phase["command_result"], bound)
                        and stable_command(phase["command_result"])),
                    "capsule-phase-completion")
        else:
            require(phase["status"] == "started", "capsule-phase-missing-command")
        admitted.append(name)
        stopped = phase["status"] != "completed"
    return admitted


def capsule_phase_record(value, phase, pins):
    require(value.get("stage") == phase and value.get("helper_sha256") == pins
            and value.get("accepted") is False and value.get("final_protocol_ready") is False
            and type(value.get("exit_code")) is int and 0 <= value["exit_code"] <= 255
            and value.get("status") in ("passed", "failed", "incomplete"), "capsule-phase-role-or-source")



def capsule_probe_ledger(diagnostic):
    require(type(diagnostic) is dict, "capsule-admission-diagnostic")
    probes = diagnostic.get("probes", {})
    require(type(probes) is dict and set(probes) <= set(CAPSULE_PROBES), "capsule-probe-membership")
    if not diagnostic:
        return {}
    require(diagnostic.get("probe_order") == list(CAPSULE_PROBES[:len(probes)])
            and set(probes) == set(diagnostic["probe_order"]), "capsule-probe-prefix")
    return probes


def capsule_lifecycle_records(values, root):
    """컴파일러 출력과 분리된 고정 Python 작성 파일의 역할·접두 순서만 묶는다."""
    phase = values.get("controller", {}).get("phases", {}).get("compiler-lifecycle", {})
    argv = phase.get("command", [])
    request_sha = argv[-1] if len(argv) >= 2 and argv[-2] == "--sdk-generation-request-sha256" else None
    summary = values.get("generation-summary")
    output = root / "native-sdk-generations-lifecycle"
    if summary is not None:
        require(summary.get("accepted") is False and summary.get("final_protocol_ready") is False
                and summary.get("request_sha256") == request_sha and diagnostic_hash(request_sha)
                and summary.get("lifecycle_output") == str(output)
                and summary.get("normalization_recipe") == GENERATIONS.NORMALIZATION_RECIPE,
                "capsule-generation-summary-role")
    stopped, seen = False, []
    for stage, _mutation, building, variant in GENERATIONS.STAGE_PLAN:
        state = values.get("lifecycle-state:" + stage)
        boundaries = {side: values.get("generation-boundary:" + stage + ":" + side)
                      for side in ("before", "after")}
        if state is None:
            require(not any(boundaries.values()), "capsule-boundary-without-state")
            stopped = True
            continue
        require(not stopped and state.get("name") == stage and state.get("project") == str(output / "Project")
                and state.get("compiler_index_policy") == "fresh-shared-v2" and state.get("execution") == "executed"
                and state.get("product_checks") == "not-run" and state.get("expected_build") == (building or "not-run")
                and state.get("oracle_variant") == variant and state.get("status") in ("running", "passed", "failed")
                and state.get("sdk") == "iphonesimulator" and state.get("triple") == "arm64-apple-ios16.0-simulator",
                "capsule-lifecycle-state-prefix")
        seen.append(state)
        stopped = state["status"] != "passed"
        require(building or not any(boundaries.values()), "capsule-source-only-boundary")
        for side in ("before", "after"):
            boundary = boundaries[side]
            if boundary is None:
                continue
            declared = state.get("sdk_generation", {}).get(side)
            if declared is not None:
                require(GENERATIONS.identity(declared) == GENERATIONS.identity(boundary),
                        "capsule-generation-boundary-reference")
            if boundary.get("status") == "unavailable":
                require(set(boundary) == {"status", "full_read_completed", "reason"}
                        and boundary["full_read_completed"] is False and boundary["reason"] in
                        ("incomplete-process", "generation-aborted-before-postcheck"), "capsule-boundary-unavailable")
            else:
                require(boundary.get("stage") == stage and boundary.get("boundary") == side
                        and boundary.get("accepted") is False and boundary.get("final_protocol_ready") is False
                        and boundary.get("expectation_sha256") == GENERATIONS.EXPECTATION_SHA256
                        and boundary.get("content_sha256") == GENERATIONS.BASELINE_SHA256
                        and boundary.get("request_sha256") == request_sha
                        and boundary.get("verification_path") == str(root / "native-calibration-sdk-raw/generations" /
                                                                      stage / side / "seal-verification.json"),
                        "capsule-generation-boundary-role")
                # 실제 고정 argv는 이 JSON 영역을 출력 대상으로 삼지 않는다.
                plan = boundary.get("command_plan")
                require(type(plan) is list and len(plan) == 6 and boundary.get("commands_sha256") == GENERATIONS.identity(plan),
                        "capsule-generation-boundary-plan")
                attempt = state.get("generation_attempt")
                require(type(attempt) is dict and attempt.get("build") == str(output / "Generations" / stage / "Build")
                        and attempt.get("store") == str(output / "Generations" / stage / "IndexStore"),
                        "capsule-generation-output-path")
                before = values.get("sdk-admission:before-compilation", {})
                native = before.get("native", {})
                selected = native.get("selected", {})
                require(type(selected) is dict and type(selected.get("sdk")) is str
                        and Path(selected["sdk"]).is_absolute() and len(Path(selected["sdk"]).parents) >= 3
                        and type(selected.get("tools")) is dict
                        and all(type(selected["tools"].get(key)) is str and Path(selected["tools"][key]).is_absolute()
                                for key in ("swift", "clang")), "capsule-generation-selected-inputs-unavailable")
                contract, _ = GENERATIONS.NATIVE.expectation()
                require(selected["sdk"] in contract["sdk_aliases"] and all(
                    selected["tools"][key] in contract["tools"][key]["allowed_paths"] for key in ("swift", "clang")),
                    "capsule-generation-selected-inputs-changed")
                expected = GENERATIONS.frozen_command_plan(output / "Project", Path(attempt["store"]), Path(attempt["build"]),
                    selected["sdk"], "arm64-apple-ios16.0-simulator", selected["tools"]["swift"],
                    selected["tools"]["clang"], str(Path(selected["sdk"]).parents[2]), stage)
                require(GENERATIONS.identity(plan) == GENERATIONS.identity(expected), "capsule-generation-command-plan")
    lifecycle = values.get("lifecycle-result")
    if lifecycle is not None:
        require(lifecycle.get("role") == "validation-only" and lifecycle.get("compiler_index_policy") == "fresh-shared-v2"
                and lifecycle.get("status") in ("running", "passed", "failed"), "capsule-lifecycle-role")
        embedded = lifecycle.get("states", lifecycle.get("retained_states"))
        if embedded is not None:
            expected_states = seen if "states" in lifecycle else sorted(seen, key=lambda row: row["name"])
            require(type(embedded) is list and GENERATIONS.identity(embedded) == GENERATIONS.identity(expected_states),
                    "capsule-lifecycle-state-binding")


def failure_capsule(root):
    """고정 원본 계층을 보수적으로 읽으며 누락된 하위 증거를 만들어 내지 않는다."""
    shell = invocation_status(root)
    require(shell["actual_shell_exit"] != 0, "capsule-requires-actual-failure")
    pins = source_hashes()
    reader = CapsuleReader(root)
    values, projected, safe = {}, {}, {"shell": True, "supervisor": shell["prelaunch_outputs_absent"],
                                      "supervisor-command": shell["prelaunch_outputs_absent"]}
    paths = {role: path for role, path, _parent in CAPSULE_SLOTS}
    context_ok, phase_prefix, probe_ledgers = False, [], {}
    for role, relative, parent in CAPSULE_SLOTS:
        if not safe.get(role, False):
            projected[role] = dict(status="withheld-unstable")
            continue
        value = reader.original(relative)
        row = dict(reader.inputs[relative])
        projected[role] = row
        if value is None:
            continue
        values[role] = value
        if role == "shell":
            require(value == shell, "capsule-shell-changed")
            row["observation"] = shell
            continue
        if role == "supervisor":
            require(value.get("helper_sha256") == pins and value.get("profile") == PROFILE
                    and value.get("accepted") is False and value.get("final_protocol_ready") is False,
                    "capsule-supervisor-source")
        if role.endswith("command") or role.startswith(("phase-command:", "native-probe:")):
            if role == "supervisor-command":
                argv, cwd = controller_argv(root), ROOT
            elif role.startswith("phase-command:"):
                phase_name = role.split(":", 1)[1]
                argv, cwd = commands(root, reader.inputs[CONTEXT]["sha256"])[phase_name], ROOT
                declared = values["controller"]["phases"][phase_name]
                require(value.get("command") == declared.get("command"), "capsule-declared-phase-command")
                if role == "phase-command:compiler-lifecycle":
                    # 요청 경로는 고정 호출에 포함되지만 해시는 읽지 않는 슬롯이므로 엄격히 형식만 확인한다.
                    actual = value.get("command", [])
                    require(actual[:len(argv)] == argv and len(actual) == len(argv) + 2
                            and actual[-2] == "--sdk-generation-request-sha256" and diagnostic_hash(actual[-1]),
                            "capsule-lifecycle-request-command")
                    argv = actual
            elif role.startswith("native-probe:"):
                _, phase, name = role.split(":")
                expected, _ = GENERATIONS.NATIVE.expectation()
                argv = native_probe_argv(name, expected)
                if name == "swift-version":
                    actual = value.get("command")
                    require(type(actual) is list and len(actual) == 2 and actual[1] == "--version"
                            and actual[0] in expected["tools"]["swift"]["allowed_paths"], "capsule-probe-command")
                    argv = actual
                cwd = root / "native-calibration-sdk-raw" / phase / "native"
            else:
                argv = [sys.executable, str(ROOT / "Scripts/benchmark-inputs/select_sdk_roots.py"), "--request",
                        str(root / "sdk-discovery-raw/setup/selector-request.json"), "--output",
                        str(root / "sdk-discovery-raw/setup/discovery"), "--command-runner",
                        str(ROOT / "Scripts/validate-native-measurement.py")]
                cwd = ROOT
            if role == "supervisor-command" and "supervisor" in values:
                require(GENERATIONS.identity(values["supervisor"].get("command")) == GENERATIONS.identity(value),
                        "capsule-supervisor-command-changed")
            if role.startswith("phase-command:") and "controller" in values:
                phase = values["controller"].get("phases", {}).get(role.split(":", 1)[1], {})
                if "command_result" in phase:
                    require(GENERATIONS.identity(phase["command_result"]) == GENERATIONS.identity(value),
                            "capsule-phase-command-changed")
            if role.startswith("native-probe:"):
                _, phase_name, probe_name = role.split(":")
                parent = probe_ledgers[phase_name][probe_name]
                require(GENERATIONS.identity({k: v for k, v in parent.items() if k != "stdout_identity"}) ==
                        GENERATIONS.identity(value), "capsule-native-command-changed")
            if role == "selector-command" and "phase" in values.get("discovery-result", {}):
                require(GENERATIONS.identity(values["discovery-result"]["phase"]) == GENERATIONS.identity(value),
                        "capsule-selector-command-reference")
            row["observation"] = capsule_command(reader, relative, value, argv, cwd)
            bound = 1815 if role == "supervisor-command" else dict(PHASES)[role.split(":", 1)[1]] if role.startswith("phase-command:") else 180 if role == "selector-command" else 30
            row["observation"]["completion_class"] = ("completed-zero-within-bound" if complete_command(value, bound)
                and stable_command(value) else "late-zero" if stable_command(value) and value["observed_returncode"] == 0
                and value["wall_seconds"] > bound else "incomplete-or-nonzero")
            refs = (values.get("supervisor", {}).get("originals", {}) if role == "supervisor-command" else
                    values.get("controller", {}).get("phases", {}).get(role.split(":", 1)[1], {}).get("originals", {})
                    if role.startswith("phase-command:") else {})
            for suffix, ref in refs.items():
                require(suffix in (".json", ".stdout", ".stderr") and type(ref) is dict,
                        "capsule-original-reference-shape")
                target = relative.removesuffix(".json") + suffix
                observed = reader.inputs.get(target)
                if observed and observed["status"] == "available":
                    require(ref == dict(path=str(root / target), sha256=observed["sha256"], bytes=observed["bytes"]),
                            "capsule-original-reference-changed")
            if role == "supervisor-command":
                safe["controller"] = stable_command(value)
                safe["context"] = stable_command(value)
            elif role.startswith("phase-command:") and stable_command(value):
                phase = role.split(":", 1)[1]
                if phase in ("before-compilation", "after-generation"):
                    safe["phase-result:" + phase] = safe["sdk-admission:" + phase] = True
                else:
                    for target, _path, _dep in CAPSULE_SLOTS:
                        if (phase == "compiler-lifecycle" and target.startswith(("lifecycle-", "generation-"))
                                or phase == "sdk-discovery" and target in
                                ("discovery-result", "selector-command")):
                            safe[target] = True
            elif role == "selector-command":
                safe["selector-result"] = stable_command(value)
            continue
        row["observation"] = safe_record(value)
        if role == "context":
            # 누락되거나 파싱할 수 없는 controller는 빈 시작 접두를 증명하지 않는다.
            controller = values.get("controller")
            if type(controller) is not dict:
                row["observation"] = dict(admission_status="unavailable")
                continue
            try:
                verify_context(root / CONTEXT, reader.inputs[CONTEXT]["sha256"], root, current_environment=False)
            except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
                # 어떤 phase도 시작하지 않았다는 원본 접두 증명만 이 조기 거부 경로를 허용한다.
                require(not phase_prefix, "capsule-context-refused-after-launch")
                row["observation"] = dict(admission_status="refused-before-any-phase",
                    failure_sha256=hashlib.sha256(str(error).encode()).hexdigest())
                continue
            context_ok = True
            controller = values.get("controller")
            require(type(controller) is dict and controller.get("context") == dict(path=str(root / CONTEXT),
                    sha256=reader.inputs[CONTEXT]["sha256"], bytes=reader.inputs[CONTEXT]["bytes"]),
                    "capsule-controller-context")
            for phase in phase_prefix:
                safe["phase-command:" + phase] = True
        elif role == "controller":
            phase_prefix = capsule_controller_prefix(value)
            if "context" not in value:
                require(not phase_prefix, "capsule-started-without-context")
        elif role.startswith("sdk-admission:"):
            phase = role.split(":", 1)[1]
            require(value.get("boundary") == phase and value.get("accepted") is False
                    and value.get("final_protocol_ready") is False
                    and ("expectation_sha256" not in value or value["expectation_sha256"] == GENERATIONS.EXPECTATION_SHA256),
                    "capsule-admission-role-or-source")
            phase_result = values.get("phase-result:" + phase, {})
            if "observation" in phase_result:
                require(GENERATIONS.identity(phase_result["observation"]) == GENERATIONS.identity(value),
                        "capsule-admission-original-changed")
            probes = capsule_probe_ledger(value.get("diagnostic", {}))
            if phase in probe_ledgers:
                require(GENERATIONS.identity(probe_ledgers[phase]) == GENERATIONS.identity(probes),
                        "capsule-admission-ledger-reference")
            probe_ledgers[phase] = probes
            for name in probes:
                safe["native-probe:" + phase + ":" + name] = context_ok
        elif role.startswith("phase-result:"):
            phase = role.split(":", 1)[1]
            capsule_phase_record(value, phase, pins)
            actual = values["phase-command:" + phase]["observed_returncode"]
            row["observation"]["actual_exit_conflict"] = value["exit_code"] != actual
            diagnostic = value.get("diagnostic", {})
            require(type(diagnostic) is dict, "capsule-phase-diagnostic")
            # 입장 JSON은 같은 종료된 phase Python이 쓴다. 진행 중인 프로브는 그 파일을 쓰지 않는다.
            # 개별 프로브 스트림은 아래의 실제 종료/정리 영수증으로 따로 차단한다.
            safe["sdk-admission:" + phase] = True
            probes = capsule_probe_ledger(diagnostic.get("admission", {}))
            probe_ledgers[phase] = probes
            for name in probes:
                safe["native-probe:" + phase + ":" + name] = context_ok
        elif role == "discovery-result":
            require(value.get("accepted") is False and value.get("final_protocol_ready") is False
                    and value.get("role") == "SDK and compiler search-root discovery only", "capsule-discovery-role")
            if "helper_hashes" in value:
                helper_paths = ("Scripts/validate-native-sdk-discovery.py", "Scripts/validate-native-measurement.py",
                         "Scripts/benchmark-inputs/select_sdk_roots.py", "Scripts/benchmark-inputs/sdk_content_seal.py",
                         "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/compiler_generations.py",
                         "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/validation_common.py")
                require(value["helper_hashes"] == {path: pins[path] for path in helper_paths}, "capsule-discovery-source")
            for name, reference_role in (("results.json", "lifecycle-result"),
                                         ("state.json", "lifecycle-state:restored_rebuilt")):
                declared = value.get("input_files", {}).get(name)
                observed = reader.inputs.get(paths[reference_role])
                if declared is not None and observed and observed["status"] == "available":
                    require(type(declared) is dict and all(declared.get(key) == observed[key]
                            for key in ("sha256", "bytes")), "capsule-discovery-input-reference")
            if "phase" in value:
                # 선택기 프로세스 영수증은 뒤의 고정 슬롯에서 원본과 다시 비교한다.
                require(type(value["phase"]) is dict, "capsule-selector-parent")
        elif role == "selector-result":
            require(value.get("accepted") is False and value.get("final_protocol_ready") is False
                    and type(value.get("schema_version")) is int and value["schema_version"] == 1,
                    "capsule-selector-role")
            declared = values.get("discovery-result", {}).get("proposal_result_identity")
            if declared is not None:
                require(type(declared) is dict and all(declared.get(key) == row[key] for key in ("sha256", "bytes")),
                        "capsule-selector-result-reference")
    capsule_lifecycle_records(values, root)
    # 요약의 writer는 phase Python이다. 시작 영수증만 있고 wait가 없는 경우에는 읽지 않는다.
    controller = values.get("controller", {})
    phases = controller.get("phases", {})
    if (context_ok and controller.get("nested_material_safe") is True and set(phases) == {name for name, _ in PHASES}
            and all(type(phase) is dict and (phase.get("status") == "not-started" or
                    stable_command(phase.get("command_result"))) for phase in phases.values())):
        role, relative = "sdk-summary", paths["sdk-summary"]
        value = reader.original(relative)
        projected[role] = dict(reader.inputs[relative])
        if value is not None:
            initial = "profile" not in value
            require(type(value.get("schema_version")) is int and value["schema_version"] == 1
                    and value.get("role") == "native-calibration-sdk-candidate"
                    and value.get("helper_sha256") == pins
                    and value.get("accepted") is False and value.get("final_protocol_ready") is False,
                    "capsule-summary-source")
            if initial:
                # 종료된 phase가 최종 갱신 전에 남긴 정확한 최초 요약만 별도 관측으로 보존한다.
                require(set(value) == {"schema_version", "role", "accepted", "final_protocol_ready",
                        "status", "stages", "helper_sha256"} and value["status"] == "started"
                        and type(value["stages"]) is dict and value["stages"] == {}, "capsule-summary-source")
            else:
                require(value["profile"] == PROFILE and value.get("status") in
                        ("candidate-in-progress", "retained-failure"), "capsule-summary-source")
            stages = value.get("stages")
            require(type(stages) is dict and set(stages) in (set(), {"before-compilation"},
                    {"before-compilation", "after-generation"}), "capsule-summary-stage-prefix")
            for name, declared in stages.items():
                phase = values.get("phase-result:" + name)
                target = paths["phase-result:" + name]
                observed = reader.inputs.get(target, {})
                require(type(declared) is dict and set(declared) == {"status", "exit_code", "original"},
                        "capsule-summary-stage-reference")
                if phase is not None:
                    require(declared["status"] == phase["status"] and type(declared["exit_code"]) is int
                            and declared["exit_code"] == phase["exit_code"] and declared["original"] ==
                            dict(path=str(root / target), sha256=observed["sha256"]),
                            "capsule-summary-phase-changed")
            projected[role]["observation"] = safe_record(value)
            projected[role]["observation"]["summary_checkpoint"] = "initial" if initial else "progressed"
    require(source_hashes() == pins, "capsule-source-changed")
    capsule = dict(schema_version=1, role=CAPSULE_ROLE, status="incomplete", execution_exit=shell["actual_shell_exit"],
                   source_sha=shell["source_sha"], helper_sha256=pins, accepted=False, final_protocol_ready=False,
                   actual_engine_calls=0, actual_compiler_commands=None, actual_full_sdk_reads=None,
                   counts_status="unavailable", membership_scope="fixed-selected-slots-only",
                   disk_completion_conflict=(values.get("controller", {}).get("status") == "validation-candidate-complete"
                       or values.get("supervisor", {}).get("status") == "validation-candidate-process-complete"),
                   slots=[dict(slot=role, **projected[role]) for role, _path, _parent in CAPSULE_SLOTS])
    return capsule, reader.inputs


def publish_failure_capsule(root, costs, normalizer):
    started = time.perf_counter()
    capsule, originals = failure_capsule(root)
    costs["capsule_projection"] = dict(full_wall_seconds=time.perf_counter() - started)
    staging, public = root / "native-calibration-sdk-staging", root / "native-calibration-sdk-public"
    staging.mkdir(exist_ok=False)
    save(staging / "results.json", capsule)
    started = time.perf_counter()
    try:
        manifest = normalizer.package(argparse.Namespace(input=staging, output=public, prefix=[]))
    finally:
        costs["capsule_normalizer"] = dict(full_wall_seconds=time.perf_counter() - started)
    require(GENERATIONS.identity(read(public / "results.json")) == GENERATIONS.identity(capsule),
            "capsule-normalized-content-changed")
    endpoint, after = failure_capsule(root)
    require(GENERATIONS.identity(endpoint) == GENERATIONS.identity(capsule) and after == originals,
            "capsule-originals-changed")
    require(len(manifest["files"]) == 1 and manifest["files"][0]["path"] == "results.json",
            "capsule-publication-membership")
    return reference(public / "manifest.json")


CAPSULE_SLOTS = (
    ('shell', 'generation-invocation-status.json', None),
    ('supervisor', 'native-generation-supervisor/results.json', 'shell'),
    ('supervisor-command', 'native-generation-supervisor/command.json', 'supervisor'),
    ('controller', 'native-calibration-sdk-calls/generation-controller.json', 'supervisor-command'),
    ('context', 'native-calibration-sdk-calls/generation-context.json', 'controller'),
    ('phase-command:before-compilation', 'native-calibration-sdk-calls/before-compilation/command.json', 'controller'),
    ('phase-command:compiler-lifecycle', 'native-calibration-sdk-calls/compiler-lifecycle/command.json', 'controller'),
    ('phase-command:sdk-discovery', 'native-calibration-sdk-calls/sdk-discovery/command.json', 'controller'),
    ('phase-command:after-generation', 'native-calibration-sdk-calls/after-generation/command.json', 'controller'),
    ('sdk-summary', 'native-calibration-sdk-raw/results.json', 'controller'),
    ('phase-result:before-compilation', 'native-calibration-sdk-raw/setup/phases/before-compilation.json', 'phase-command:before-compilation'),
    ('sdk-admission:before-compilation', 'native-calibration-sdk-raw/before-compilation/results.json', 'phase-result:before-compilation'),
    ('phase-result:after-generation', 'native-calibration-sdk-raw/setup/phases/after-generation.json', 'phase-command:after-generation'),
    ('sdk-admission:after-generation', 'native-calibration-sdk-raw/after-generation/results.json', 'phase-result:after-generation'),
    ('native-probe:before-compilation:machine-hw_machine', 'native-calibration-sdk-raw/before-compilation/native/machine-hw_machine.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:machine-hw_physicalcpu', 'native-calibration-sdk-raw/before-compilation/native/machine-hw_physicalcpu.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:machine-hw_logicalcpu', 'native-calibration-sdk-raw/before-compilation/native/machine-hw_logicalcpu.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:machine-hw_memsize', 'native-calibration-sdk-raw/before-compilation/native/machine-hw_memsize.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:machine-machdep_cpu_brand_string', 'native-calibration-sdk-raw/before-compilation/native/machine-machdep_cpu_brand_string.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:machine-kern_osrelease', 'native-calibration-sdk-raw/before-compilation/native/machine-kern_osrelease.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:machine-kern_osproductversion', 'native-calibration-sdk-raw/before-compilation/native/machine-kern_osproductversion.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:sdk-path', 'native-calibration-sdk-raw/before-compilation/native/sdk-path.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:swift-path', 'native-calibration-sdk-raw/before-compilation/native/swift-path.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:clang-path', 'native-calibration-sdk-raw/before-compilation/native/clang-path.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:os-build', 'native-calibration-sdk-raw/before-compilation/native/os-build.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:xcode-version', 'native-calibration-sdk-raw/before-compilation/native/xcode-version.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:swift-version', 'native-calibration-sdk-raw/before-compilation/native/swift-version.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:sdk-version', 'native-calibration-sdk-raw/before-compilation/native/sdk-version.json', 'sdk-admission:before-compilation'),
    ('native-probe:before-compilation:sdk-build', 'native-calibration-sdk-raw/before-compilation/native/sdk-build.json', 'sdk-admission:before-compilation'),
    ('native-probe:after-generation:machine-hw_machine', 'native-calibration-sdk-raw/after-generation/native/machine-hw_machine.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:machine-hw_physicalcpu', 'native-calibration-sdk-raw/after-generation/native/machine-hw_physicalcpu.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:machine-hw_logicalcpu', 'native-calibration-sdk-raw/after-generation/native/machine-hw_logicalcpu.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:machine-hw_memsize', 'native-calibration-sdk-raw/after-generation/native/machine-hw_memsize.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:machine-machdep_cpu_brand_string', 'native-calibration-sdk-raw/after-generation/native/machine-machdep_cpu_brand_string.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:machine-kern_osrelease', 'native-calibration-sdk-raw/after-generation/native/machine-kern_osrelease.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:machine-kern_osproductversion', 'native-calibration-sdk-raw/after-generation/native/machine-kern_osproductversion.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:sdk-path', 'native-calibration-sdk-raw/after-generation/native/sdk-path.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:swift-path', 'native-calibration-sdk-raw/after-generation/native/swift-path.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:clang-path', 'native-calibration-sdk-raw/after-generation/native/clang-path.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:os-build', 'native-calibration-sdk-raw/after-generation/native/os-build.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:xcode-version', 'native-calibration-sdk-raw/after-generation/native/xcode-version.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:swift-version', 'native-calibration-sdk-raw/after-generation/native/swift-version.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:sdk-version', 'native-calibration-sdk-raw/after-generation/native/sdk-version.json', 'sdk-admission:after-generation'),
    ('native-probe:after-generation:sdk-build', 'native-calibration-sdk-raw/after-generation/native/sdk-build.json', 'sdk-admission:after-generation'),
    ('generation-summary', 'native-calibration-sdk-raw/generation-results.json', 'phase-command:compiler-lifecycle'),
    ('lifecycle-result', 'native-sdk-generations-lifecycle/results.json', 'phase-command:compiler-lifecycle'),
    ('lifecycle-state:initial', 'native-sdk-generations-lifecycle/runs/initial/state.json', 'generation-summary'),
    ('lifecycle-state:header_edit_unbuilt', 'native-sdk-generations-lifecycle/runs/header_edit_unbuilt/state.json', 'generation-summary'),
    ('lifecycle-state:header_edit_rebuilt', 'native-sdk-generations-lifecycle/runs/header_edit_rebuilt/state.json', 'generation-summary'),
    ('lifecycle-state:header_rename_unbuilt', 'native-sdk-generations-lifecycle/runs/header_rename_unbuilt/state.json', 'generation-summary'),
    ('lifecycle-state:header_rename_rebuilt', 'native-sdk-generations-lifecycle/runs/header_rename_rebuilt/state.json', 'generation-summary'),
    ('lifecycle-state:header_delete_unbuilt', 'native-sdk-generations-lifecycle/runs/header_delete_unbuilt/state.json', 'generation-summary'),
    ('lifecycle-state:header_delete_build_failed', 'native-sdk-generations-lifecycle/runs/header_delete_build_failed/state.json', 'generation-summary'),
    ('lifecycle-state:header_restored_rebuilt', 'native-sdk-generations-lifecycle/runs/header_restored_rebuilt/state.json', 'generation-summary'),
    ('lifecycle-state:swift_rename_unbuilt', 'native-sdk-generations-lifecycle/runs/swift_rename_unbuilt/state.json', 'generation-summary'),
    ('lifecycle-state:swift_rename_rebuilt', 'native-sdk-generations-lifecycle/runs/swift_rename_rebuilt/state.json', 'generation-summary'),
    ('lifecycle-state:swift_delete_unbuilt', 'native-sdk-generations-lifecycle/runs/swift_delete_unbuilt/state.json', 'generation-summary'),
    ('lifecycle-state:swift_delete_rebuilt', 'native-sdk-generations-lifecycle/runs/swift_delete_rebuilt/state.json', 'generation-summary'),
    ('lifecycle-state:restored_rebuilt', 'native-sdk-generations-lifecycle/runs/restored_rebuilt/state.json', 'generation-summary'),
    ('generation-boundary:initial:before', 'native-calibration-sdk-raw/generations/initial/before/results.json', 'lifecycle-state:initial'),
    ('generation-boundary:initial:after', 'native-calibration-sdk-raw/generations/initial/after/results.json', 'lifecycle-state:initial'),
    ('generation-boundary:header_edit_rebuilt:before', 'native-calibration-sdk-raw/generations/header_edit_rebuilt/before/results.json', 'lifecycle-state:header_edit_rebuilt'),
    ('generation-boundary:header_edit_rebuilt:after', 'native-calibration-sdk-raw/generations/header_edit_rebuilt/after/results.json', 'lifecycle-state:header_edit_rebuilt'),
    ('generation-boundary:header_rename_rebuilt:before', 'native-calibration-sdk-raw/generations/header_rename_rebuilt/before/results.json', 'lifecycle-state:header_rename_rebuilt'),
    ('generation-boundary:header_rename_rebuilt:after', 'native-calibration-sdk-raw/generations/header_rename_rebuilt/after/results.json', 'lifecycle-state:header_rename_rebuilt'),
    ('generation-boundary:header_delete_build_failed:before', 'native-calibration-sdk-raw/generations/header_delete_build_failed/before/results.json', 'lifecycle-state:header_delete_build_failed'),
    ('generation-boundary:header_delete_build_failed:after', 'native-calibration-sdk-raw/generations/header_delete_build_failed/after/results.json', 'lifecycle-state:header_delete_build_failed'),
    ('generation-boundary:header_restored_rebuilt:before', 'native-calibration-sdk-raw/generations/header_restored_rebuilt/before/results.json', 'lifecycle-state:header_restored_rebuilt'),
    ('generation-boundary:header_restored_rebuilt:after', 'native-calibration-sdk-raw/generations/header_restored_rebuilt/after/results.json', 'lifecycle-state:header_restored_rebuilt'),
    ('generation-boundary:swift_rename_rebuilt:before', 'native-calibration-sdk-raw/generations/swift_rename_rebuilt/before/results.json', 'lifecycle-state:swift_rename_rebuilt'),
    ('generation-boundary:swift_rename_rebuilt:after', 'native-calibration-sdk-raw/generations/swift_rename_rebuilt/after/results.json', 'lifecycle-state:swift_rename_rebuilt'),
    ('generation-boundary:swift_delete_rebuilt:before', 'native-calibration-sdk-raw/generations/swift_delete_rebuilt/before/results.json', 'lifecycle-state:swift_delete_rebuilt'),
    ('generation-boundary:swift_delete_rebuilt:after', 'native-calibration-sdk-raw/generations/swift_delete_rebuilt/after/results.json', 'lifecycle-state:swift_delete_rebuilt'),
    ('generation-boundary:restored_rebuilt:before', 'native-calibration-sdk-raw/generations/restored_rebuilt/before/results.json', 'lifecycle-state:restored_rebuilt'),
    ('generation-boundary:restored_rebuilt:after', 'native-calibration-sdk-raw/generations/restored_rebuilt/after/results.json', 'lifecycle-state:restored_rebuilt'),
    ('discovery-result', 'sdk-discovery-raw/results.json', 'phase-command:sdk-discovery'),
    ('selector-command', 'sdk-discovery-raw/setup/discovery-process.json', 'discovery-result'),
    ('selector-result', 'sdk-discovery-raw/setup/discovery/results.json', 'selector-command'),
)
CAPSULE_PROBES = ('machine-hw_machine', 'machine-hw_physicalcpu', 'machine-hw_logicalcpu', 'machine-hw_memsize', 'machine-machdep_cpu_brand_string', 'machine-kern_osrelease', 'machine-kern_osproductversion', 'sdk-path', 'swift-path', 'clang-path', 'os-build', 'xcode-version', 'swift-version', 'sdk-version', 'sdk-build')
CAPSULE_PATHS = frozenset(path for _role, path, _parent in CAPSULE_SLOTS) | frozenset(
    path.removesuffix("json") + suffix for role, path, _parent in CAPSULE_SLOTS
    if role.endswith("command") or role.startswith(("phase-command:", "native-probe:"))
    for suffix in ("stdout", "stderr"))


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
        "accepted", "final_protocol_ready", "first_failure", "receipt_failure", "receipt_recovery_failure",
        "child_diagnostic") if key in result}))
    return result["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())
