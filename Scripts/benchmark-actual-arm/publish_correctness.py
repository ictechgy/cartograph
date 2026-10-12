#!/usr/bin/env python3
"""완전한 정규화 트리와 별도 안전 시도 영수증만 원자적으로 게시한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import re
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import correctness_controller as controller
import attempt_receipts
import runtime_publication
import state_inputs
import runtime_bootstrap as bootstrap

SPEC = importlib.util.spec_from_file_location("actual_arm_normalizer", ROOT / "runtime/vendor/normalize_evidence.py")
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
    if "pre_record_diagnostic" in row:
        diagnostic = attempt_receipts.pre_record_diagnostic(phase, row["stderr"])
        require(same_json(row["pre_record_diagnostic"], diagnostic))
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
    public["selected_launch"] = selected_launch_summary(args, attempt, row["source_sha256"])
    NORMALIZER.check_sensitive(json.dumps(public), "attempt.json")
    return public


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
        record = controller.selected_launch.verify(args, attempt.parent, sources)
        return dict(
            status="verified",
            mode=record["request"]["mode"],
            request_sha256=record["request_ref"]["sha256"],
            observation_sha256=record["observation_ref"]["sha256"],
        )
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        return result


def completed_launch(record, raw, attempt, runtime):
    summary = attempt.get("selected_launch")
    require(isinstance(summary, dict) and set(summary) == {"status", "mode", "request_sha256", "observation_sha256"})
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
    require(actual["request_sha256"] == summary["request_sha256"])
    require(same_json(actual["installation"], controller.selected_launch.identity(binding)))
    require(same_json(runtime["python"], binding["python"]))
    require(actual["actual_interpreter"]["selected_path"] == runtime["python"]["path"])
    require(all(actual["source_sha256"].get(path) == digest for path, digest in runtime["code_files"].items()))
    references["installation_binding"] = binding_ref
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
        and state.get("order") == "AB"
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
    )
    require(phase.get("command") == expected)
    runtime_receipt = controller.isolated_measure.verify_runtime_receipt(
        raw / "setup/state-runtime/runtime-result.json",
        runtime,
        runtime_ref["sha256"],
        ROOT / "state_worker.py",
        arguments,
        0,
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
        **contract_refs,
        **launch_refs,
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
        ]:
            paths["contracts_" + label + "_" + key] = "setup/contracts/" + label + "/" + suffix
    for key, digest in completion.get("bound_file_sha256", {}).items():
        require(hashes.get(paths[key]) == digest)


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
