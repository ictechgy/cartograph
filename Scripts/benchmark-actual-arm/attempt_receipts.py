"""원문 없는 외부 시도 영수증과 현재/과거 로그 정체성을 구분한다."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import re
from pathlib import Path
import time

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "actual_arm_receipt_reader", ROOT / "runtime/vendor/discovery_receipts.py"
)
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)
REASONS = {"input-not-regular-file", "input-byte-limit", "input-changed-during-read", "unreadable-input"}


PRE_RECORD_STAGES = {
    "isolation",
    "scratch-boundary",
    "output-boundary",
    "state-inputs",
    "installation-binding",
    "selected-launch",
    "sdk-binding",
    "accepted-output-boundary",
    "raw-output-create",
}
PRE_RECORD_REASONS = {
    "Different physical interpreter cannot be selected": "selected-launch-physical-mismatch",
    "Selected launch request changed": "selected-launch-request-changed",
    "Selected launch source changed": "selected-launch-source-changed",
    "Private launch environment differs": "selected-launch-private-environment-mismatch",
    "Prior interpreter spellings differ": "installation-interpreter-spelling-mismatch",
    "Prospective interpreter identity differs from current input": "prospective-interpreter-identity-mismatch",
    "Private installation target is not canonical": "installation-target-not-canonical",
    "Prior helper phase was not normally successful": "measurement-prerequisite-not-successful",
    "Installation request differs": "installation-request-mismatch",
    "Unexpected installed target entries": "package-unexpected-entries",
    "Original native/tool setup prerequisites failed": "tool-setup-prerequisite-failed",
    "Accepted developer directory context changed": "developer-context-changed",
    "Selected lexical input lacks the accepted developer ancestor": "developer-ancestor-mismatch",
    "Selected compiler/library developer contexts disagree": "compiler-context-disagreement",
    "Selected SDK is outside accepted developer/platform context": "sdk-context-disagreement",
    "Evidence/input overlap": "output-input-overlap",
}
PRE_RECORD_FAILURES = {"OSError", "ValueError", "RuntimeError", "KeyError", "TypeError", "KeyboardInterrupt"}


class PreRecordFailure(RuntimeError):
    """메시지 원문 없이 허용된 단계와 알려진 이유 또는 전체 메시지 지문만 전달한다."""

    def __init__(self, stage, error):
        if stage not in PRE_RECORD_STAGES:
            raise ValueError("Unknown pre-record stage")
        self.exit_code = 125 if isinstance(error, KeyboardInterrupt) else 1
        failure = next(
            name
            for name, kind in [
                ("KeyboardInterrupt", KeyboardInterrupt),
                ("KeyError", KeyError),
                ("TypeError", TypeError),
                ("ValueError", ValueError),
                ("OSError", OSError),
                ("RuntimeError", RuntimeError),
            ]
            if isinstance(error, kind)
        )
        message = str(error)
        reason = PRE_RECORD_REASONS.get(message, "unclassified-error")
        self.diagnostic = dict(
            schema_version=1,
            status="refused-before-record",
            stage=stage,
            failure=failure,
            reason=reason,
            message_sha256=(
                sha(message.encode("utf-8", errors="surrogatepass")) if reason == "unclassified-error" else None
            ),
            exit_code=self.exit_code,
        )
        super().__init__("Pre-record admission failed")


def pre_record(stage, operation, *args):
    try:
        return operation(*args)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, KeyboardInterrupt) as error:
        raise PreRecordFailure(stage, error) from error


def pre_record_diagnostic(phase, historical):
    """정상적으로 반환한 한정된 자식 진단만 원래 로그 지문에 묶어 공개한다."""
    if (
        historical.get("status") != "available"
        or type(phase.get("returncode")) is not int
        or phase["returncode"] not in (1, 125)
        or type(phase.get("observed_returncode")) is not int
        or phase["observed_returncode"] != phase["returncode"]
        or phase.get("failure") not in (None, "nested-incomplete")
    ):
        return None
    try:
        identity = READER.file_identity(Path(phase["stderr"]), 4096, include_text=True)
        if {k: identity[k] for k in ("bytes", "sha256")} != {k: historical[k] for k in ("bytes", "sha256")}:
            return None
        row = READER.strict_json(identity["text"])
        if (
            not isinstance(row, dict)
            or set(row) != {"schema_version", "status", "stage", "failure", "reason", "message_sha256", "exit_code"}
            or type(row["schema_version"]) is not int
            or row["schema_version"] != 1
            or row["status"] != "refused-before-record"
            or row["stage"] not in PRE_RECORD_STAGES
            or row["failure"] not in PRE_RECORD_FAILURES
            or type(row["exit_code"]) is not int
            or row["exit_code"] != phase["returncode"]
            or (row["failure"] == "KeyboardInterrupt") != (row["exit_code"] == 125)
            or row["reason"] not in {*PRE_RECORD_REASONS.values(), "unclassified-error"}
        ):
            return None
        if row["reason"] == "unclassified-error":
            if not isinstance(row["message_sha256"], str) or not re.fullmatch("[a-f0-9]{64}", row["message_sha256"]):
                return None
        elif row["message_sha256"] is not None:
            return None
        return row
    except (OSError, ValueError, TypeError, KeyError, READER.DiscoveryError):
        return None


def sha(data):
    return hashlib.sha256(data).hexdigest()


def log_identity(path):
    try:
        row = READER.file_identity(Path(path), 1024**3)
        return dict(status="available", sha256=row["sha256"], bytes=row["bytes"])
    except READER.DiscoveryError as error:
        return dict(status="unavailable", reason=str(error) if str(error) in REASONS else "unreadable-input")


def envelope(phase, argv, sources, total_seconds):
    incomplete = not phase.get("completed") or phase.get("returncode") == 125
    stdout, stderr = (log_identity(phase[k]) for k in ("stdout", "stderr"))
    return dict(
        schema_version=1,
        role="actual-arm-correctness-attempt-envelope",
        final_evidence=False,
        source_sha256=sources,
        argv_sha256=sha(json.dumps(argv, separators=(",", ":"), ensure_ascii=True).encode()),
        exit_code=125 if incomplete else phase["returncode"],
        observed_returncode=phase.get("observed_returncode"),
        completed=not incomplete,
        child_failure=phase.get("failure"),
        child_wall_seconds=phase["wall_seconds"],
        supervisor_wall_seconds=total_seconds,
        stdout=stdout,
        stderr=stderr,
        pre_record_diagnostic=pre_record_diagnostic(phase, stderr),
        cleanup_signals=phase.get("cleanup_signals", []),
        cleanup_root_unfinished=phase.get("cleanup_root_unfinished", False),
        descendant_cleanup_verified=False,
        scope="Whole process, serialization and normal teardown observed; detached macOS descendants remain unproved",
    )


def verify_historical_logs(receipt, phase):
    current = {}
    for kind in ("stdout", "stderr"):
        historic = receipt[kind]
        if not isinstance(historic, dict):
            raise ValueError("Invalid historical log identity")
        if historic.get("status") == "available":
            if (
                set(historic) != {"status", "sha256", "bytes"}
                or not isinstance(historic["sha256"], str)
                or not re.fullmatch("[a-f0-9]{64}", historic["sha256"])
                or type(historic["bytes"]) is not int
                or not 0 <= historic["bytes"] <= 1024**3
            ):
                raise ValueError("Invalid historical available log identity")
        elif set(historic) != {"status", "reason"}:
            raise ValueError("Invalid historical unavailable log identity")
        present = log_identity(phase[kind])
        current[kind] = present
        if historic.get("status") == "available":
            if historic != present:
                raise ValueError("Previously sealed attempt log changed")
        elif historic.get("status") != "unavailable" or historic.get("reason") not in REASONS:
            raise ValueError("Invalid historical unavailable log observation")
    return current
