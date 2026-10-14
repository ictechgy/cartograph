#!/usr/bin/env python3
"""완전한 정규화 트리와 별도 안전 시도 영수증만 원자적으로 게시한다."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import math
import os
import stat
import types
import re
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
    import correctness_controller as controller
    import attempt_receipts
    import runtime_publication
    import state_inputs
    import state_worker
    import runtime_bootstrap as bootstrap

    SPEC = importlib.util.spec_from_file_location(
        "actual_arm_normalizer", ROOT / "runtime/vendor/normalize_evidence.py"
    )
    NORMALIZER = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(NORMALIZER)

FAILURES = {None, "nested-incomplete", "signal", "timeout", "interrupt", "launch"}
CLEANUP = {"term-sent", "kill-sent", "term-target-already-exited", "kill-target-already-exited"}


BLOCK_REASONS = {
    "unmapped-absolute-path",
    "helper-process-identity-not-injective",
    "credential-url",
    "helper-process-identity-unbound",
    "normalized-json-key-collision",
    "slack-token",
    "bearer-token",
    "invalid-or-ambiguous-json",
    "helper-process-identity-reassigned",
    "non-utf8-or-binary-content",
    "possible-environment-dump",
    "file-count-limit",
    "environment-dump",
    "credential-field-or-assignment",
    "api-token",
    "helper-process-identity-cleanup",
    "aws-key",
    "possible-json-environment-dump",
    "unmapped-windows-absolute-path",
    "log-reference-not-in-public-bundle",
    "helper-process-identity-schema",
    "invalid-url",
    "helper-process-identity-rss-sum",
    "normalized-size-limit",
    "sample-chunk-integrity-changed",
    "private-key",
    "email-address",
    "per-file-size-limit",
    "secret-argument",
    "invalid-or-ambiguous-jsonl",
    "unexpected-control-or-binary-content",
    "github-token",
    "symlink-directory",
    "raw-evidence-changed-during-normalization",
    "missing-nonregular-or-symlink-artifact",
    "secret-assignment",
    "total-size-limit",
    "token-bearing-or-signed-url",
    "sample-chunk-integrity",
    "credential-json-field",
}


def blocked_diagnostic(error):
    values = dict(reason=error.reason, artifact_sha256=error.artifact_sha256, value_sha256=error.value_sha256)
    if values["reason"] not in BLOCK_REASONS:
        return None
    for key in ("artifact_sha256", "value_sha256"):
        value = values[key]
        if key == "value_sha256" and value is None:
            continue
        if not isinstance(value, str) or not re.fullmatch("[a-f0-9]{64}", value):
            return None
    return values


def same_json(left, right):
    # Python의 False == 0 동등성으로 중복 영수증의 형식 차이를 숨기지 않는다.
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)


def require(value):
    if not value:
        raise ValueError("Attempt evidence verification failed")


def public_attempt(args, attempt):
    row = state_inputs.document(state_inputs.reference(attempt / "results.json"))
    phase_ref = state_inputs.reference(attempt / "process.json")
    phase = state_inputs.document(phase_ref)
    require(type(phase.get("completed")) is bool and type(phase.get("returncode")) is int)
    require(phase.get("observed_returncode") is None or type(phase.get("observed_returncode")) is int)
    if phase["completed"]:
        require(
            phase["returncode"] >= 0
            and phase["returncode"] != 125
            and phase.get("failure") is None
            and phase["returncode"] == phase["observed_returncode"]
        )
    else:
        require(phase["returncode"] == 125)
    argv = [
        sys.executable,
        "-I",
        "-S",
        "-B",
        str(ROOT / "correctness_controller.py"),
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
        str(Path(args.scratch_root).resolve()),
    ]
    mode = getattr(args, "calibration_mode", None)
    if mode is not None:
        require(mode == "native-observer-v1")
        argv += ["--calibration-mode", mode]
    require(
        phase["command"] == argv
        and row["argv_sha256"]
        == attempt_receipts.sha(json.dumps(argv, separators=(",", ":"), ensure_ascii=True).encode())
    )
    require(row["phase_receipt_sha256"] == phase_ref["sha256"])
    require(
        row["schema_version"] == 1
        and type(row["schema_version"]) is int
        and row["role"] == "actual-arm-correctness-attempt-envelope"
        and row["final_evidence"] is False
    )
    require(type(row["completed"]) is bool and row["descendant_cleanup_verified"] is False)
    require(row["observed_returncode"] is None or type(row["observed_returncode"]) is int)
    require(type(row["source_inputs_unchanged"]) is bool)
    require(row["source_guard_status"] in {"passed", "changed", "unavailable"})
    require((row["source_guard_status"] == "passed") is row["source_inputs_unchanged"])
    require(
        row["scope"]
        == "Whole process, serialization and normal teardown observed; detached macOS descendants remain unproved"
    )
    expected_sources = {
        str(ROOT / name) for name in controller.contract_prerequisites.source_paths(controller.SOURCE_FILES)
    }
    require(set(row["source_sha256"]) == expected_sources)
    try:
        current_sources = controller.source_hashes()
        if set(current_sources) != expected_sources:
            current_sources = None
    except (OSError, ValueError, RuntimeError):
        current_sources = None
    require(
        all(isinstance(value, str) and re.fullmatch("[a-f0-9]{64}", value) for value in row["source_sha256"].values())
    )
    require(row["observed_returncode"] == phase["observed_returncode"] and row["completed"] == phase["completed"])
    require(row["child_failure"] == phase["failure"] and row["child_failure"] in FAILURES)
    require(
        type(row["exit_code"]) is int
        and (
            row["exit_code"] == phase["returncode"]
            or (row["exit_code"] == 1 and row["source_inputs_unchanged"] is False)
        )
    )
    for key in ["child_wall_seconds", "supervisor_wall_seconds"]:
        require(type(row[key]) in (int, float) and math.isfinite(row[key]) and row[key] >= 0)
    require(
        row["child_wall_seconds"] == phase["wall_seconds"]
        and row["supervisor_wall_seconds"] >= row["child_wall_seconds"]
    )
    require(row["cleanup_signals"] == phase["cleanup_signals"] and all(s in CLEANUP for s in row["cleanup_signals"]))
    require(
        row["cleanup_root_unfinished"] == phase["cleanup_root_unfinished"]
        and type(row["cleanup_root_unfinished"]) is bool
    )
    for kind in ["stdout", "stderr"]:
        require(Path(phase[kind]).resolve() == attempt / ("process." + kind))
    current = attempt_receipts.verify_historical_logs(row, phase)
    # 내용 없는 외부 영수증에는 절대 경로 키 대신 검증한 자체 소스의 상대 이름만 둔다.
    public = {
        k: row[k]
        for k in [
            "schema_version",
            "role",
            "final_evidence",
            "argv_sha256",
            "exit_code",
            "observed_returncode",
            "completed",
            "child_failure",
            "child_wall_seconds",
            "supervisor_wall_seconds",
            "stdout",
            "stderr",
            "cleanup_signals",
            "cleanup_root_unfinished",
            "descendant_cleanup_verified",
            "scope",
            "source_inputs_unchanged",
            "source_guard_status",
            "phase_receipt_sha256",
        ]
    }
    if mode is not None:
        public["calibration_mode"] = mode
    if "pre_record_diagnostic" in row:
        diagnostic = attempt_receipts.pre_record_diagnostic(phase, row["stderr"])
        require(same_json(row["pre_record_diagnostic"], diagnostic))
        if diagnostic is not None and "interpreter_spelling" in diagnostic:
            verify_interpreter_spelling(args, attempt, row["source_sha256"], diagnostic["interpreter_spelling"])
        public["pre_record_diagnostic"] = diagnostic
    public["source_sha256"] = {str(Path(path).relative_to(ROOT)): value for path, value in row["source_sha256"].items()}
    public["publication_log_identities"] = current
    public["publication_source_sha256"] = (
        {str(Path(path).relative_to(ROOT)): value for path, value in current_sources.items()}
        if current_sources is not None
        else None
    )
    public["publication_source_status"] = "available" if current_sources is not None else "unavailable"
    public["publication_source_inputs_unchanged"] = current_sources == row["source_sha256"]
    if "source_guard_failure" in row:
        require(
            row["source_guard_failure"]
            in {"OSError", "ValueError", "RuntimeError", "FileNotFoundError", "PermissionError"}
        )
        public["source_guard_failure"] = row["source_guard_failure"]
    public["startup_profile_collection"] = profile_summary(attempt, row["source_sha256"])
    public["selected_launch"] = selected_launch_summary(args, attempt, row["source_sha256"])
    NORMALIZER.check_sensitive(json.dumps(public), "attempt.json")
    return public


def verify_interpreter_spelling(args, attempt, sources, summary):
    """원래 실패의 측정 요청과 선택 요청을 다시 확인하며 누락된 관측은 보충하지 않는다."""
    require(attempt_receipts.valid_interpreter_spelling(summary))
    require(same_json(controller.source_hashes(), sources))
    reference = state_inputs.reference(args.measurement)
    require(reference["sha256"] == summary["measurement_sha256"])
    measurement = state_inputs.document(reference)
    phase = measurement["phases"][summary["phase"]]
    controller.installation_binding.completed(phase)
    require(attempt_receipts.spelling_sha256(phase["command"][0]) == summary["phase_command_spelling_sha256"])
    selected = summary["selected_request"]
    if selected["status"] == "bound-request":
        bound_args = copy.copy(args)
        profile = state_inputs.reference(attempt / "startup-profile/results.json")
        bound_args.startup_profile_sha256 = profile["sha256"]
        require(same_json(selected, controller.selected_launch.request_projection(bound_args, attempt.parent, sources)))
        require(state_inputs.reference(attempt / "startup-profile/results.json") == profile)
    require(state_inputs.reference(args.measurement) == reference)


def profile_summary(attempt, sources=None):
    """실패한 수집도 원래 해시와 비용을 보존하되 성공 승인으로 사용하지 않는다."""
    path = attempt / "startup-profile/results.json"
    result = dict(status="unavailable", reason="startup-profile-collection-not-verified")
    try:
        reference = state_inputs.reference(path)
        result["sha256"] = reference["sha256"]
        value = state_inputs.document(reference)
        require(
            type(value.get("schema_version")) is int
            and value["schema_version"] == 1
            and value.get("role") == "prospective-startup-profile-collection"
            and type(value.get("exit_code")) is int
            and value["exit_code"] in {0, 1, 125}
            and value.get("status") == {0: "passed", 1: "failed", 125: "incomplete"}[value["exit_code"]]
            and value.get("final_evidence") is False
        )
        wall = value["wall_seconds_before_receipt"]
        require(type(wall) in (int, float) and math.isfinite(wall) and wall >= 0)
        require(isinstance(value["probes"], list) and len(value["probes"]) <= 2)
        result.update(
            status="retained",
            outcome=value["status"],
            exit_code=value["exit_code"],
            probe_attempts=len(value["probes"]),
            wall_seconds_before_receipt=wall,
            cost_scope="Nested in original supervised child wall; no additive double count",
        )
        result["interpreter_probes"] = []
        for number, entry in enumerate(value["probes"], 1):
            projected = dict(status="unavailable", reason="probe-interpreter-not-verified", probe=number)
            try:
                require(sources is not None and same_json(controller.source_hashes(), sources))
                projected = controller.profile_collection.interpreter_projection(
                    path,
                    entry,
                    number,
                    controller.selected_launch.private_environment(attempt.parent),
                    ROOT / "correctness_controller.py",
                    sources,
                )
            except (OSError, ValueError, KeyError, TypeError, RuntimeError):
                pass
            result["interpreter_probes"].append(projected)
        require(state_inputs.reference(path) == reference)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError):
        result["status"] = "unavailable"
        if "interpreter_probes" in result:
            result["interpreter_probes"] = [
                dict(status="unavailable", reason="probe-interpreter-not-verified", probe=number)
                for number in range(1, len(result["interpreter_probes"]) + 1)
            ]
    return result


def selected_launch_summary(args, attempt, sources):
    result = dict(
        status="unavailable", reason="selected-launch-not-verified", request_sha256=None, observation_sha256=None
    )
    for key in ("request", "observation"):
        try:
            result[key + "_sha256"] = state_inputs.reference(attempt / ("selected-launch-" + key + ".json"))["sha256"]
        except (OSError, ValueError, TypeError, KeyError):
            pass
    try:
        bound_args = copy.copy(args)
        profile_ref = state_inputs.reference(attempt / "startup-profile/results.json")
        bound_args.startup_profile_sha256 = profile_ref["sha256"]
        record = controller.selected_launch.verify(bound_args, attempt.parent, sources)
        return dict(
            status="verified",
            mode=record["request"]["mode"],
            request_sha256=record["request_ref"]["sha256"],
            observation_sha256=record["observation_ref"]["sha256"],
            startup_profile_sha256=profile_ref["sha256"],
        )
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        try:
            require(same_json(controller.source_hashes(), sources))
            projected = controller.selected_launch.request_projection(bound_args, attempt.parent, sources)
            require(projected["request_sha256"] == result["request_sha256"])
            result["request_projection"] = projected
        except (OSError, ValueError, TypeError, KeyError, RuntimeError):
            result["request_projection"] = attempt_receipts.unavailable_selected_request()
        return result


def completed_launch(record, raw, attempt, runtime):
    summary = attempt.get("selected_launch")
    require(
        isinstance(summary, dict)
        and set(summary) == {"status", "mode", "request_sha256", "observation_sha256", "startup_profile_sha256"}
    )
    require(summary["status"] == "verified" and summary["mode"] in {"direct", "one-exec"})
    require(
        same_json(record.get("selected_launch"), {key: summary[key + "_sha256"] for key in ("request", "observation")})
    )
    references, values = {}, {}
    for key in ("request", "observation"):
        reference = state_inputs.reference(raw / ("setup/selected-launch-" + key + ".json"))
        require(reference["sha256"] == summary[key + "_sha256"])
        references["selected_launch_" + key] = reference
        values[key] = state_inputs.document(reference)
    binding_ref = state_inputs.reference(raw / "setup/installation-binding.json")
    binding = state_inputs.document(binding_ref)
    actual = values["observation"]
    require(values["request"]["mode"] == summary["mode"])
    require(values["request"]["arguments"].get("calibration_mode") == attempt.get("calibration_mode"))
    require(actual["request_sha256"] == summary["request_sha256"])
    require(same_json(actual["installation"], controller.selected_launch.identity(binding)))
    require(same_json(runtime["python"], binding["python"]))
    require(all(actual["source_sha256"].get(path) == digest for path, digest in runtime["code_files"].items()))
    require(type(runtime.get("schema_version")) is int and runtime["schema_version"] == 3)
    profile = values["request"]["startup_profile"]
    relation = runtime["interpreter_relation"]
    controller.selected_launch.interpreter_relation.validate(
        relation, runtime["python"], runtime["code_files"], runtime["startup_profile"]
    )
    require(same_json(profile["interpreter_relation"], relation))
    reported = relation["reported_interpreter"]
    require(same_json(actual["actual_interpreter"], dict(
        selected_path=reported["selected_path"], resolved_path=reported["resolved_path"],
        sha256=reported["sha256"], bytes=reported["bytes"], file_identity=reported["metadata"],
    )))
    require(profile["collection_sha256"] == summary["startup_profile_sha256"])
    require(same_json(profile, actual["startup_profile"]))
    require(same_json(runtime["startup_profile"], profile["accepted_profile"]))
    references.update(completed_profile(raw, summary["startup_profile_sha256"], relation))
    references["installation_binding"] = binding_ref
    return references


def completed_profile(raw, expected, relation=None):
    folder = raw / "setup/startup-profile"
    manifest_ref = state_inputs.reference(folder / "copy-manifest.json")
    manifest = state_inputs.document(manifest_ref)
    require(
        set(manifest) == {"schema_version", "role", "collection_sha256", "files"}
        and type(manifest["schema_version"]) is int
        and manifest["schema_version"] == 1
        and manifest["role"] == "exact-startup-profile-copies"
        and manifest["collection_sha256"] == expected
    )
    collection = state_inputs.document(state_inputs.reference(folder / "results.json"))
    require(
        type(collection.get("exit_code")) is int
        and collection["exit_code"] == 0
        and collection.get("status") == "passed"
        and 1 <= len(collection["probes"]) <= 2
    )
    names = ["results.json"]
    for number in range(1, len(collection["probes"]) + 1):
        names += [
            f"spelling-{number:04d}/" + name
            for name in ["request.json", "observation.json", "process.json", "process.stdout", "process.stderr"]
        ]
    rows = manifest["files"]
    require(isinstance(rows, list) and len(rows) == len(names))
    refs = {"startup-copy:setup/startup-profile/copy-manifest.json": manifest_ref}
    for row, name in zip(rows, names):
        require(
            set(row) == {"original_path", "artifact", "sha256", "bytes"}
            and row["artifact"] == "setup/startup-profile/" + name
            and type(row["bytes"]) is int
        )
        source = raw.parent / "actual-arm-correctness-attempt/startup-profile" / name
        require(row["original_path"] == str(source))
        original = controller.startup_profile.file_identity(source, controller.startup_profile.MAX_RECEIPT_BYTES)
        copied = controller.startup_profile.file_identity(
            raw / row["artifact"], controller.startup_profile.MAX_RECEIPT_BYTES
        )
        require(all(original[key] == copied[key] == row[key] for key in ("sha256", "bytes")))
        refs["startup-copy:" + row["artifact"]] = state_inputs.reference(raw / row["artifact"])
    require(refs["startup-copy:setup/startup-profile/results.json"]["sha256"] == expected)
    if relation is not None:
        completed_profile_relation(expected, collection, relation, refs)
    return refs


def completed_profile_relation(expected, collection, relation, references):
    """재구성한 관계도 게시한 원래 선택 프로브의 세 영수증 해시에 결합한다."""
    require(relation["collection_sha256"] == expected and relation["probe"] == len(collection["probes"]))
    probe = "spelling-%04d" % relation["probe"]
    values = {}
    for key in ("request", "observation", "process"):
        name = probe + "/" + key + ".json"
        reference = references["startup-copy:setup/startup-profile/" + name]
        require(reference["sha256"] == relation[key + "_sha256"])
        values[key] = state_inputs.document(reference)
    entry = collection["probes"][-1]
    require(
        same_json(values["request"]["interpreter"], relation["requested_interpreter"])
        and same_json(values["observation"]["actual_interpreter"], relation["reported_interpreter"])
        and same_json(values["observation"], entry["observation"])
        and same_json(values["process"], entry["process"])
        and same_json({path: value["sha256"] for path, value in values["request"]["source_inputs"].items()},
                      relation["source_inputs"])
        and relation["startup_profile_sha256"] == controller.startup_profile.sha(
            controller.startup_profile.encoded(collection["accepted_profile"]))
    )
    accepted = controller.profile_collection.verify_record(
        values["observation"], values["request"], relation["request_sha256"], values["process"]
    )
    require(same_json(accepted, collection["accepted_profile"]))


ARM_COMPLETION_FILES = (
    "input.json",
    "arm-result.json",
    "worker-result.json",
    "whole-arm.command.json",
    "whole-arm.json",
    "whole-arm.observer.json",
    "engine-runtime/runtime-result.json",
    "engine-runtime/environment-request.json",
    "observer-runtime/runtime-result.json",
    "observer-runtime/environment-request.json",
)


def completed_arm(raw, arm, embedded, plan, runtime, runtime_ref):
    """성공 요약 대신 각 팔의 원래 요청·측정·관측·환경 파일을 연결한다."""
    folder = raw / "runs/restored_rebuilt" / arm
    references = {name: state_inputs.reference(folder / name) for name in ARM_COMPLETION_FILES}
    values = {name: state_inputs.document(reference) for name, reference in references.items()}
    row, worker = values["arm-result.json"], values["worker-result.json"]
    observer, measured = values["whole-arm.observer.json"], values["whole-arm.json"]
    request = values["whole-arm.command.json"]
    require(same_json(values["input.json"], dict(plan["engine_config"], arm=arm, output=str(folder))))
    require(
        same_json(embedded, row)
        and same_json(row.get("worker"), worker)
        and same_json(row.get("observer"), observer)
        and same_json(observer.get("measurement"), measured)
        and same_json(observer.get("runtime"), values["observer-runtime/runtime-result.json"])
        and same_json(observer.get("engine_runtime"), values["engine-runtime/runtime-result.json"])
    )
    require(
        row.get("arm") == arm
        and row.get("status") == "passed"
        and type(row.get("exit_code")) is int
        and row["exit_code"] == 0
        and row.get("may_continue") is True
        and row.get("final_evidence") is False
        and worker.get("status") == "ok"
        and worker.get("arm") == arm
        and worker.get("state_id") == plan["engine_config"]["state_id"]
    )
    for phase in ("before", "after"):
        guard = row.get("guard_" + phase, {})
        require(guard.get("status") == "passed" and same_json(guard.get("generation"), plan["accepted"]))
    require(
        observer.get("status") == "passed"
        and all(type(observer.get(key)) is int and observer[key] == 0
                for key in ("exit_code", "observed_helper_returncode", "workload_returncode"))
        and observer.get("failure") is None
        and observer.get("cleanup_root_unfinished", False) is False
        and observer.get("cleanup_signals") == []
        and observer.get("final_evidence") is False
        and observer.get("mode") == "timing"
        and observer.get("periodic_sampling") is False
    )
    require(
        measured.get("status") == "ok"
        and all(type(measured.get(key)) is int and measured[key] == 0 for key in ("returncode", "root_returncode"))
        and measured.get("failure") is None
        and measured.get("timed_out") is False
        and measured.get("helper_sha256") == controller.isolated_measure.HELPER_SHA256
        and measured.get("measurement_mode") == "timing"
        and measured.get("sampling_during_timing") is False
        and measured.get("primary_timing_eligible") is True
        and measured.get("containment", {}).get("read_errors") == []
        and (measured.get("cleanup") is None or measured["cleanup"].get("remaining_observed_pids") == [])
    )
    require(
        request.get("cwd") == str(Path(plan["engine_config"]["project"]).resolve())
        and type(request.get("timeout_seconds")) in (int, float)
        and request["timeout_seconds"] == 240
        and type(request.get("interval_seconds")) in (int, float)
        and request["interval_seconds"] == 0.01
        and request.get("measurement_mode") == "timing"
        and same_json(measured.get("artifacts", {}).get("command"),
                      dict(name="whole-arm.command.json", sha256=references["whole-arm.command.json"]["sha256"]))
    )
    engine_arguments = ["--input", references["input.json"]["path"], "--sha256", references["input.json"]["sha256"]]
    for role, script, arguments, actual in (
        ("engine", ROOT / "engine_worker.py", engine_arguments, request.get("command")),
        ("observer", controller.isolated_measure.HELPER, ["--worker"], observer.get("command")),
    ):
        report = folder / (role + "-runtime/runtime-result.json")
        expected = controller.isolated_measure.bootstrap_command(
            Path(runtime_ref["path"]), runtime_ref["sha256"], script, report, arguments, runtime=runtime
        )
        require(same_json(actual, expected))
        environment = controller.isolated_measure.STARTUP.existing_environment(
            raw / "private-readers" / arm / role, plan["engine_config"]["developer_directory"]
        )
        verified = controller.isolated_measure.verify_runtime_receipt(
            report, runtime, runtime_ref["sha256"], script, arguments, 0, environment
        )
        require(same_json(verified, values[role + "-runtime/runtime-result.json"]))
    return {"arm-copy:" + str(Path(reference["path"]).relative_to(raw)): reference
            for reference in references.values()}


CALIBRATION_COMMON_FILES = (
    "input.json", "arm-result.json", "calibration-result.json", "worker-result.json", "source-catalog.json",
    "normalized-graph.json", "observation.json",
    "whole-arm.command.json", "whole-arm.stdout", "whole-arm.stderr",
    "engine-runtime/runtime-result.json", "engine-runtime/environment-request.json",
)


def completed_calibration_invocation(raw, item, embedded, plan, runtime, runtime_ref, oracle):
    """같은 엔진의 직접·관측 호출을 각 원래 파일과 다시 계산한 정답에 결합한다."""
    folder = raw / "runs/calibration" / item["folder"]
    direct = item["observer"] == "direct"
    names = CALIBRATION_COMMON_FILES + (("whole-arm.direct.json",) if direct else (
        "whole-arm.json", "whole-arm.observer.json", "whole-arm.observer.stdout", "whole-arm.observer.stderr",
        "observer-runtime/runtime-result.json", "observer-runtime/environment-request.json",
    ))
    references = {name: state_inputs.reference(folder / name) for name in names}
    values = {name: state_inputs.document(ref) for name, ref in references.items() if name.endswith(".json")}
    calibration, arm, worker = (
        values[name] for name in ("calibration-result.json", "arm-result.json", "worker-result.json")
    )
    row = dict(arm, invocation=calibration.get("invocation"), evaluation=calibration.get("evaluation"))
    observer = values["whole-arm.direct.json" if direct else "whole-arm.observer.json"]
    measured, request = observer.get("measurement"), values["whole-arm.command.json"]
    require(
        set(calibration) == {"invocation", "evaluation", "arm_result"}
        and "invocation" not in arm and "evaluation" not in arm
        and same_json(calibration["arm_result"], references["arm-result.json"])
        and same_json(embedded, dict(invocation=item, result=references["calibration-result.json"],
                                    status=arm.get("status"), exit_code=arm.get("exit_code")))
        and same_json(row.get("invocation"), item)
        and same_json(arm.get("worker"), worker) and same_json(arm.get("observer"), observer)
        and same_json(worker.get("graph"), values["normalized-graph.json"])
        and same_json(worker.get("observation"), values["observation.json"])
        and same_json(values["input.json"], dict(plan["engine_config"], arm=item["engine"], output=str(folder)))
        and row.get("arm") == item["engine"] and row.get("status") == "passed"
        and type(row.get("exit_code")) is int and row["exit_code"] == 0 and row.get("may_continue") is True
        and row.get("final_evidence") is False and worker.get("status") == "ok"
        and worker.get("arm") == item["engine"] and worker.get("state_id") == plan["engine_config"]["state_id"]
    )
    for phase in ("before", "after"):
        guard = row.get("guard_" + phase, {})
        require(guard.get("status") == "passed" and same_json(guard.get("generation"), plan["accepted"]))
    require(
        isinstance(measured, dict) and observer.get("mode") == item["observer"]
        and observer.get("status") == "passed" and observer.get("failure") is None
        and observer.get("final_evidence") is False and observer.get("cleanup_root_unfinished", False) is False
        and observer.get("cleanup_signals") == []
        and all(type(observer.get(key)) is int and observer[key] == 0 for key in ("exit_code", "workload_returncode"))
        and measured.get("measurement_mode") == item["observer"] and measured.get("status") == "ok"
        and type(measured.get("root_returncode")) is int and measured["root_returncode"] == 0
        and measured.get("failure") is None and measured.get("timed_out") is False
        and type(measured.get("wall_seconds")) in (int, float)
        and math.isfinite(measured["wall_seconds"]) and measured["wall_seconds"] > 0
        and request.get("cwd") == str(Path(plan["engine_config"]["project"]).resolve())
        and type(request.get("timeout_seconds")) in (int, float) and request["timeout_seconds"] == 240
    )
    if direct:
        require(
            set(request) == {"command", "cwd", "timeout_seconds", "mode"} and request["mode"] == "direct"
            and same_json(observer.get("command"), request.get("command"))
            and type(observer.get("engine_wall_seconds")) in (int, float)
            and same_json(observer["engine_wall_seconds"], measured["wall_seconds"])
            and 0 < measured["wall_seconds"] <= request["timeout_seconds"]
            and measured.get("primary_timing_eligible") is False
            and observer.get("wait_method") == "blocking_Popen_wait_with_one_POSIX_ITIMER_REAL_deadline"
            and type(observer.get("cleanup_errors")) is list and observer["cleanup_errors"] == []
            and not (folder / "observer-runtime").exists() and not (folder / "whole-arm.json").exists()
        )
    else:
        require(
            same_json(measured, values["whole-arm.json"])
            and same_json(observer.get("runtime"), values["observer-runtime/runtime-result.json"])
            and type(observer.get("observed_helper_returncode")) is int and observer["observed_helper_returncode"] == 0
            and observer.get("periodic_sampling") is (item["observer"] == "memory")
            and set(request) == {"command", "cwd", "timeout_seconds", "interval_seconds", "measurement_mode"}
            and type(request.get("interval_seconds")) in (int, float) and request["interval_seconds"] == 0.01
            and request.get("measurement_mode") == item["observer"]
            and measured.get("primary_timing_eligible") is (item["observer"] == "timing")
            and (measured.get("cleanup") is None or measured["cleanup"].get("remaining_observed_pids") == [])
            and not (folder / "whole-arm.direct.json").exists()
        )
        controller.isolated_measure.verify_measurement(folder / "whole-arm", measured, item["observer"], request)
        if item["observer"] == "timing":
            require(measured.get("containment", {}).get("read_errors") == [])
        for name in ("stdout", "stderr"):
            require(same_json(measured.get("artifacts", {}).get(name),
                              dict(name="whole-arm." + name, sha256=references["whole-arm." + name]["sha256"])))
        for chunk in (measured.get("rss") or {}).get("sample_chunks", []):
            path = folder / chunk["name"]
            data = controller.isolated_measure.read_sample_chunk(path)
            references[chunk["name"]] = dict(path=str(path), sha256=hashlib.sha256(data).hexdigest())
            require(references[chunk["name"]]["sha256"] == chunk["sha256"])
    require(same_json(observer.get("engine_runtime"), values["engine-runtime/runtime-result.json"]))
    arguments = ["--input", references["input.json"]["path"], "--sha256", references["input.json"]["sha256"]]
    roles = [("engine", ROOT / "engine_worker.py", arguments, request.get("command"))]
    if not direct:
        roles.append(("observer", controller.isolated_measure.HELPER, ["--worker"], observer.get("command")))
    for role, script, argv, actual in roles:
        report = folder / (role + "-runtime/runtime-result.json")
        expected = controller.isolated_measure.bootstrap_command(
            Path(runtime_ref["path"]), runtime_ref["sha256"], script, report, argv, runtime=runtime
        )
        require(same_json(actual, expected))
        environment = controller.isolated_measure.STARTUP.existing_environment(
            raw / "private-readers" / item["folder"] / role, plan["engine_config"]["developer_directory"]
        )
        verified = controller.isolated_measure.verify_runtime_receipt(
            report, runtime, runtime_ref["sha256"], script, argv, 0, environment
        )
        require(same_json(verified, values[role + "-runtime/runtime-result.json"]))
    evaluation = state_worker.evaluate(arm, oracle)
    require(evaluation.get("status") == "passed" and same_json(row.get("evaluation"), evaluation))
    return ({"calibration-copy:" + str(Path(ref["path"]).relative_to(raw)): ref for ref in references.values()}, row)


def completed_calibration(raw, state, plan, runtime, runtime_ref, attempt):
    """32개 원래 호출과 엔진별 시간 적격성을 모두 재검증해야 성공으로 취급한다."""
    require(attempt.get("calibration_mode") == "native-observer-v1")
    rebound = copy.deepcopy(plan)
    state_inputs.bind_calibration_sdk(rebound, raw.parent)
    require(same_json(rebound["calibration_sdk"], plan["calibration_sdk"])
            and same_json(rebound["prior_costs"]["calibration_sdk"], plan["prior_costs"]["calibration_sdk"])
            and same_json(rebound["inputs"], plan["inputs"]))
    jobs = runtime_publication.calibration_inventory(raw, plan, complete=True)
    plan_ref = state_inputs.reference(raw / "setup/calibration-plan.json")
    require(
        same_json(state_inputs.document(plan_ref), plan["calibration"])
        and same_json(state.get("plan"), plan["calibration"])
        and type(state.get("schema_version")) is int and state["schema_version"] == 1
        and state.get("role") == "actual-engine-observer-calibration"
        and state.get("skipped_invocations") == [] and state.get("superiority_claim") is None
        and isinstance(state.get("invocations"), list) and len(state["invocations"]) == len(jobs)
        and same_json([row.get("invocation") for row in state["invocations"]], jobs)
        and type(state.get("wall_seconds_before_receipt")) in (int, float)
        and math.isfinite(state["wall_seconds_before_receipt"]) and 0 <= state["wall_seconds_before_receipt"] < 900
    )
    for name in ("initial_guard", "terminal_guard"):
        require(state.get(name, {}).get("status") == "passed"
                and same_json(state[name].get("generation"), plan["accepted"]))
    oracle = state_inputs.document(plan["inputs"]["oracle"])
    references = {"calibration-copy:setup/calibration-plan.json": plan_ref}
    started = raw / "setup/calibration-started"
    require(not started.is_symlink()
            and {path.name for path in started.iterdir()} == {item["folder"] + ".json" for item in jobs})
    rows = []
    for item, row in zip(jobs, state["invocations"]):
        ref = state_inputs.reference(started / (item["folder"] + ".json"))
        require(same_json(state_inputs.document(ref), item))
        references["calibration-copy:" + str(Path(ref["path"]).relative_to(raw))] = ref
        bound, full = completed_calibration_invocation(raw, item, row, plan, runtime, runtime_ref, oracle)
        references.update(bound)
        rows.append(full)
    groups = state_inputs.calibration_groups(rows)
    require(same_json(state.get("groups"), groups))
    require({group["engine"] for group in groups if group["mode"] == "timing" and group["timing_eligible"] is True}
            == {"baseline", "cartograph"})
    return references


def completed_success(record, raw, attempt):
    required = {
        "schema_version",
        "status",
        "exit_code",
        "final_evidence",
        "role",
        "performance_ratio",
        "superiority_claim",
        "preparation_wall_seconds",
        "controller_intervals",
        "whole_state_process",
        "contracts",
        "terminal_guard",
        "runtime_source_inputs_unchanged",
        "state_runtime",
        "state_result",
        "total_wall_seconds_before_receipt",
        "cost_accounting",
        "selected_launch",
    }
    require(set(record) == required and record["performance_ratio"] is None and record["superiority_claim"] is None)
    phase_ref = state_inputs.reference(raw / "setup/whole-state.json")
    phase = state_inputs.document(phase_ref)
    require(same_json(record["whole_state_process"], phase))
    require(
        phase.get("completed") is True
        and phase.get("passed") is True
        and type(phase.get("returncode")) is int
        and phase["returncode"] == 0
        and type(phase.get("observed_returncode")) is int
        and phase["observed_returncode"] == 0
        and phase.get("failure") is None
        and phase.get("cleanup_root_unfinished") is False
        and phase.get("cleanup_signals") == []
    )
    runtime_ref = state_inputs.reference(raw / "setup/runtime.json")
    runtime = state_inputs.document(runtime_ref)
    launch_refs = completed_launch(record, raw, attempt, runtime)
    contract_refs = controller.contract_prerequisites.verify(raw / "setup/contracts", record["contracts"], runtime)
    plan_ref = state_inputs.reference(raw / "setup/plan.json")
    plan = state_inputs.document(plan_ref)
    state_ref = state_inputs.reference(raw / "results.json")
    state = state_inputs.document(state_ref)
    require(
        same_json(record["state_result"], state)
        and state.get("status") == "passed"
        and type(state.get("exit_code")) is int
        and state["exit_code"] == 0
        and state.get("final_evidence") is False
    )
    arm_refs = {}
    if "calibration" in plan:
        arm_refs.update(completed_calibration(raw, state, plan, runtime, runtime_ref, attempt))
    else:
        require(attempt.get("calibration_mode") is None)
        require(
            state.get("order") == "AB"
            and state.get("role") == "single-restored-state-correctness-validation"
            and [a.get("arm") for a in state.get("arms", [])] == ["baseline", "cartograph"]
            and all(
                a.get("status") == "passed"
                and type(a.get("exit_code")) is int
                and a["exit_code"] == 0
                and a.get("may_continue") is True
                for a in state["arms"]
            )
        )
        for arm, embedded in zip(("baseline", "cartograph"), state["arms"]):
            arm_refs.update(completed_arm(raw, arm, embedded, plan, runtime, runtime_ref))
    arguments = [
        "--plan",
        plan_ref["path"],
        "--plan-sha256",
        plan_ref["sha256"],
        "--runtime",
        runtime_ref["path"],
        "--runtime-sha256",
        runtime_ref["sha256"],
        "--output",
        str(raw),
    ]
    expected = controller.isolated_measure.bootstrap_command(
        Path(runtime_ref["path"]),
        runtime_ref["sha256"],
        ROOT / "state_worker.py",
        raw / "setup/state-runtime/runtime-result.json",
        arguments,
        runtime=runtime,
    )
    require(phase.get("command") == expected)
    runtime_receipt = controller.isolated_measure.verify_runtime_receipt(
        raw / "setup/state-runtime/runtime-result.json",
        runtime,
        runtime_ref["sha256"],
        ROOT / "state_worker.py",
        arguments,
        0,
        controller.isolated_measure.STARTUP.existing_environment(
            raw / "private-state", plan["engine_config"]["developer_directory"]
        ),
    )
    require(same_json(record["state_runtime"], runtime_receipt))
    require(
        record["terminal_guard"].get("status") == "passed"
        and same_json(record["terminal_guard"].get("generation"), plan["accepted"])
        and record["runtime_source_inputs_unchanged"] is True
    )
    return dict(
        phase=phase_ref,
        runtime=state_inputs.reference(raw / "setup/state-runtime/runtime-result.json"),
        state=state_ref,
        plan=plan_ref,
        runtime_inputs=runtime_ref,
        runtime_environment=state_inputs.reference(raw / "setup/state-runtime/environment-request.json"),
        **contract_refs,
        **launch_refs,
        **arm_refs,
    )


def completion_receipt(raw, attempt):
    """요약의 참/거짓 대신 실제 프로세스·상태·런타임 영수증을 연결한다."""
    try:
        reference = state_inputs.reference(raw / "setup/controller-result.json")
        record = state_inputs.document(reference)
        require(
            type(record.get("schema_version")) is int
            and record["schema_version"] == 1
            and record.get("role") == "actual-arm-correctness-controller"
            and record.get("final_evidence") is False
        )
        require(
            type(record.get("exit_code")) is int
            and type(attempt.get("exit_code")) is int
            and record["exit_code"] == attempt["exit_code"]
        )
        require(record.get("status") in {"passed", "failed", "incomplete"})
        require((record["status"] == "passed") is (record["exit_code"] == 0))
        require((record["status"] == "incomplete") is (record["exit_code"] == 125))
        if record["status"] == "passed":
            references = completed_success(record, raw, attempt)
            return dict(
                status="verified",
                outcome="passed",
                sha256=reference["sha256"],
                bound_file_sha256={k: v["sha256"] for k, v in references.items()},
            )
        if "whole_state_process" in record:
            phase = state_inputs.document(state_inputs.reference(raw / "setup/whole-state.json"))
            require(same_json(record["whole_state_process"], phase))
        return dict(status="verified", outcome="retained-" + record["status"], sha256=reference["sha256"])
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, AttributeError):
        return dict(status="unavailable", reason="whole-controller-completion-not-verified")


def verify_completion_manifest(completion, manifest):
    if completion["status"] != "verified":
        return
    hashes = {row["path"]: row["original_raw_sha256"] for row in manifest["files"]}
    require(hashes.get("setup/controller-result.json") == completion["sha256"])
    paths = {
        "phase": "setup/whole-state.json",
        "runtime": "setup/state-runtime/runtime-result.json",
        "state": "results.json",
        "plan": "setup/plan.json",
        "runtime_inputs": "setup/runtime.json",
        "runtime_environment": "setup/state-runtime/environment-request.json",
        "selected_launch_request": "setup/selected-launch-request.json",
        "selected_launch_observation": "setup/selected-launch-observation.json",
        "installation_binding": "setup/installation-binding.json",
    }
    paths.update(contracts_results="setup/contracts/results.json", contracts_inputs="setup/contracts/runtime.json")
    for label in ["integration", "runtime"]:
        for key, suffix in [
            ("process", "process.json"),
            ("runtime", "runtime-result.json"),
            ("summary", "summary.json"),
            ("environment", "environment-request.json"),
        ]:
            paths["contracts_" + label + "_" + key] = "setup/contracts/" + label + "/" + suffix
    for key, digest in completion.get("bound_file_sha256", {}).items():
        if key.startswith(("startup-copy:", "arm-copy:", "calibration-copy:")):
            target = key.split(":", 1)[1]
        else:
            target = paths[key]
        require(hashes.get(target) == digest)


def publish(args):
    started = time.perf_counter()
    controller.isolation()
    scratch = controller.canonical_scratch(args.scratch_root)
    raw = scratch / "actual-arm-correctness-raw"
    attempt = scratch / "actual-arm-correctness-attempt"
    output = scratch / "actual-arm-correctness-public"
    controller.before_write(args, output)
    state_inputs.disjoint(output, [raw, attempt])
    pending = output.with_name(output.name + ".pending")
    controller.before_write(args, pending)
    pending.mkdir()
    ready = pending / "ready"
    ready.mkdir()
    status = dict(
        schema_version=1,
        role="actual-arm-correctness-publication-envelope",
        raw_fallback=False,
        complete_run_evidence=False,
        exit_code=None,
        attempt_status="missing",
        bundle_status="missing",
        final_evidence=False,
    )
    receipt = None
    try:
        receipt = public_attempt(args, attempt)
        controller.save(ready / "attempt.json", receipt)
        status.update(attempt_status="verified", exit_code=receipt["exit_code"])
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        status.update(
            attempt_status="blocked", failure="attempt-verification-blocked", failure_type=type(error).__name__
        )
    if raw.is_dir() and receipt is not None:
        try:
            prefixes = [
                "WORKSPACE=" + str(Path(args.repository).resolve()),
                "RUNTIME_SOURCES=" + str(ROOT),
                "RUNNER_TEMP=" + str(scratch),
                "USR=/usr",
                "OPT=/opt",
                "BIN=/bin",
                "DEV=/dev",
                "PRIVATE=/private",
                "TEMP=/var",
            ]
            # 공개 prefix 는 경로 정규화만 하며 입력 봉인이나 실행 경계 승인으로 사용하지 않는다.
            try:
                data = state_inputs.document(state_inputs.reference(args.lifecycle))
                developer = state_inputs.generation.developer_context(data["setup"])["developer_directory"]
                prefixes += ["DEVELOPER=" + str(Path(developer).resolve())]
            except (OSError, ValueError, KeyError, TypeError):
                pass
            dest = pending / "normalized"
            manifest = runtime_publication.package(
                NORMALIZER, argparse.Namespace(input=raw, output=dest, prefix=prefixes)
            )
            staged_receipt = public_attempt(args, attempt)
            controller.save(ready / "attempt-after-staging.json", staged_receipt)
            status["post_staging_source_inputs_unchanged"] = staged_receipt["publication_source_inputs_unchanged"]
            require(staged_receipt["publication_source_inputs_unchanged"] is True)
            require(same_json(staged_receipt.get("selected_launch"), receipt.get("selected_launch")))
            status["controller_completion"] = completion_receipt(raw, receipt)
            verify_completion_manifest(status["controller_completion"], manifest)
            dest.rename(ready / "validation")
            status.update(
                bundle_status="normalized",
                manifest_sha256=attempt_receipts.sha((ready / "validation/manifest.json").read_bytes()),
            )
        except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
            status.update(bundle_status="blocked", failure="normalization-blocked")
            if isinstance(error, NORMALIZER.PublicationBlocked):
                diagnostic = blocked_diagnostic(error)
                if diagnostic is not None:
                    status["normalization_diagnostic"] = diagnostic
            status["error_sha256"] = attempt_receipts.sha(str(error).encode())
    status.setdefault("controller_completion", dict(status="unavailable", reason="no-verified-staged-completion"))
    historical_unavailable = receipt is not None and any(
        receipt[k]["status"] != "available" for k in ("stdout", "stderr")
    )
    if historical_unavailable:
        status["failure"] = "capture-log-identity-unavailable"
    source_unavailable = receipt is not None and (
        not receipt["source_inputs_unchanged"] or not receipt["publication_source_inputs_unchanged"]
    )
    if source_unavailable:
        status["failure"] = "source-identity-changed"
    status["complete_run_evidence"] = (
        status["bundle_status"] == "normalized"
        and status["attempt_status"] == "verified"
        and not historical_unavailable
        and not source_unavailable
        and status["controller_completion"]["status"] == "verified"
    )
    status["publication_wall_seconds"] = time.perf_counter() - started
    code = (
        125 if status["exit_code"] == 125 else 0 if status["exit_code"] == 0 and status["complete_run_evidence"] else 1
    )
    status["publication_exit_code"] = code
    NORMALIZER.check_sensitive(json.dumps(status), "publication-status.json")
    controller.save(ready / "publication-status.json", status)
    ready.rename(output)
    return status, code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["repository", "lifecycle", "setup", "measurement", "scratch-root"]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--calibration-mode", choices=["native-observer-v1"])
    args = parser.parse_args()
    try:
        status, code = publish(args)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(json.dumps(dict(status="publication-refused", reason=type(error).__name__)), file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps(dict(status="safe-publication-ready", diagnostic_exit_code=code, final_evidence=False)))
    if "GITHUB_OUTPUT" in controller.os.environ:
        with Path(controller.os.environ["GITHUB_OUTPUT"]).open("a") as stream:
            stream.write("ready=true\n")
    raise SystemExit(code)


if __name__ == "__main__":
    main()
