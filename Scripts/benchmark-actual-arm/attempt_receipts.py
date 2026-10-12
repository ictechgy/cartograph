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
