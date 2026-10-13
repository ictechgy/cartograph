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
HELPER_PHASES = {"install", "tests", "machine", "calibration"}


EXPECTED_ENVIRONMENT_KEYS = {
    "PATH": "executable-search-path",
    "LANG": "language",
    "LC_ALL": "all-locale-categories",
    "TZ": "time-zone",
    "PYTHONDONTWRITEBYTECODE": "bytecode-policy",
    "HOME": "home-directory",
    "TMPDIR": "temporary-directory",
    "XDG_CACHE_HOME": "cache-directory",
    "RUNNER_TEMP": "runner-scratch",
}
KNOWN_STARTUP_KEYS = {
    "LC_CTYPE": "python-locale-category",
    "__CF_USER_TEXT_ENCODING": "core-foundation-user-text-encoding",
    "__PYVENV_LAUNCHER__": "python-venv-launcher",
}


def environment_difference(expected, actual):
    """예상 키의 고정 식별자와 추가 키 이름 집합의 지문만 보존한다. 값은 읽어 비교만 한다."""
    if set(expected) != set(EXPECTED_ENVIRONMENT_KEYS):
        raise ValueError("Fixed private environment schema differs")
    extra = sorted(set(actual) - set(expected))
    return dict(
        missing_expected_keys=sorted(EXPECTED_ENVIRONMENT_KEYS[key] for key in expected if key not in actual),
        changed_expected_keys=sorted(
            EXPECTED_ENVIRONMENT_KEYS[key] for key in expected if key in actual and expected[key] != actual[key]
        ),
        extra_key_count=len(extra),
        extra_key_names_sha256=sha(json.dumps(extra, separators=(",", ":"), ensure_ascii=True).encode()),
        known_extra_keys=sorted(KNOWN_STARTUP_KEYS[key] for key in extra if key in KNOWN_STARTUP_KEYS),
    )


def valid_environment_difference(row):
    if not isinstance(row, dict) or set(row) != {
        "missing_expected_keys",
        "changed_expected_keys",
        "extra_key_count",
        "extra_key_names_sha256",
        "known_extra_keys",
    }:
        return False
    for name, allowed in [
        ("missing_expected_keys", set(EXPECTED_ENVIRONMENT_KEYS.values())),
        ("changed_expected_keys", set(EXPECTED_ENVIRONMENT_KEYS.values())),
        ("known_extra_keys", set(KNOWN_STARTUP_KEYS.values())),
    ]:
        values = row[name]
        if (
            not isinstance(values, list)
            or len(values) > len(allowed)
            or any(not isinstance(value, str) or value not in allowed for value in values)
            or values != sorted(set(values))
        ):
            return False
    count = row["extra_key_count"]
    key_hash = row["extra_key_names_sha256"]
    return (
        type(count) is int
        and 0 <= count <= 65536
        and len(row["known_extra_keys"]) <= count
        and isinstance(key_hash, str)
        and re.fullmatch("[a-f0-9]{64}", key_hash) is not None
        and (count != 0 or key_hash == sha(b"[]"))
        and not set(row["missing_expected_keys"]) & set(row["changed_expected_keys"])
        and bool(count or row["missing_expected_keys"] or row["changed_expected_keys"])
    )


class PrivateEnvironmentMismatch(ValueError):
    def __init__(self, expected, actual):
        self.summary = environment_difference(expected, actual)
        if not valid_environment_difference(self.summary):
            raise ValueError("Environment mismatch diagnostic requires a difference")
        super().__init__("Private launch environment differs")


def spelling_sha256(value):
    """해석하거나 정규화하지 않은 정확한 표시 문자열만 지문으로 바꾼다."""
    if not isinstance(value, str):
        raise ValueError("Interpreter spelling is not text")
    return sha(value.encode("utf-8", errors="surrogatepass"))


def valid_digest(value):
    return isinstance(value, str) and re.fullmatch("[a-f0-9]{64}", value) is not None


def unavailable_selected_request():
    return dict(status="unavailable", reason="selected-request-not-bound")


def valid_selected_request_projection(row):
    if row == unavailable_selected_request():
        return True
    return (
        isinstance(row, dict)
        and set(row) == {"status", "mode", "request_sha256", "source_inputs_sha256"}
        and row["status"] == "bound-request"
        and row["mode"] in {"direct", "one-exec"}
        and valid_digest(row["request_sha256"])
        and valid_digest(row["source_inputs_sha256"])
    )


def valid_interpreter_spelling(row):
    if not isinstance(row, dict) or set(row) != {
        "schema_version",
        "measurement_sha256",
        "phase",
        "phase_command_spelling_sha256",
        "interpreter_spelling_sha256",
        "physical_identity",
        "selected_request",
    }:
        return False
    physical = row["physical_identity"]
    return (
        type(row["schema_version"]) is int
        and row["schema_version"] == 1
        and isinstance(row["phase"], str)
        and row["phase"] in HELPER_PHASES
        and all(
            valid_digest(row[key])
            for key in ("measurement_sha256", "phase_command_spelling_sha256", "interpreter_spelling_sha256")
        )
        and row["phase_command_spelling_sha256"] != row["interpreter_spelling_sha256"]
        and (
            physical == {"status": "unavailable", "reason": "interpreter-identity-not-observed"}
            or (
                isinstance(physical, dict)
                and set(physical) == {"status", "equal"}
                and physical["status"] == "observed-at-failure"
                and type(physical["equal"]) is bool
            )
        )
        and valid_selected_request_projection(row["selected_request"])
    )


class InterpreterSpellingMismatch(ValueError):
    """거부된 원래 문자열 비교를 유지하며 그 순간 관측한 입력 지문만 더한다."""

    def __init__(self, phase, command, interpreter, measurement_sha256, physical_identity):
        self.summary = dict(
            schema_version=1,
            measurement_sha256=measurement_sha256,
            phase=phase,
            phase_command_spelling_sha256=spelling_sha256(command),
            interpreter_spelling_sha256=spelling_sha256(interpreter),
            physical_identity=physical_identity,
            selected_request=unavailable_selected_request(),
        )
        if not valid_interpreter_spelling(self.summary):
            raise ValueError("Interpreter spelling diagnostic is invalid")
        super().__init__("Prior interpreter spellings differ")


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
        if type(error) is PrivateEnvironmentMismatch and stage == "selected-launch":
            self.diagnostic["environment_difference"] = error.summary
        if type(error) is InterpreterSpellingMismatch and stage in {"selected-launch", "installation-binding"}:
            if valid_interpreter_spelling(error.summary):
                self.diagnostic["interpreter_spelling"] = error.summary
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
        fields = {"schema_version", "status", "stage", "failure", "reason", "message_sha256", "exit_code"}
        if (
            not isinstance(row, dict)
            or set(row) not in (fields, fields | {"environment_difference"}, fields | {"interpreter_spelling"})
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
        if "environment_difference" in row and not (
            row["stage"] == "selected-launch"
            and row["reason"] == "selected-launch-private-environment-mismatch"
            and row["failure"] == "ValueError"
            and row["exit_code"] == 1
            and valid_environment_difference(row["environment_difference"])
        ):
            return None
        if "interpreter_spelling" in row and not (
            row["stage"] in {"selected-launch", "installation-binding"}
            and row["reason"] == "installation-interpreter-spelling-mismatch"
            and row["failure"] == "ValueError"
            and row["exit_code"] == 1
            and valid_interpreter_spelling(row["interpreter_spelling"])
        ):
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
