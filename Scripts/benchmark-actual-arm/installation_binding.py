"""기존 공식 --target 설치 영수증을 현재 인터프리터·설치 바이트에 묶는다."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "runtime"))
import runtime_bootstrap as bootstrap
import runtime_identity as runtime
import startup_profile
import attempt_receipts

HELPER_PATHS = {
    ".github/workflows/ci.yml",
    "Scripts/validate-native-measurement.py",
    "Scripts/normalize-indexstore-evidence.py",
    *{
        "Scripts/benchmark-measurement/" + name
        for name in (
            "README.md",
            "calibrate_observer.py",
            "machine_manifest.py",
            "paired_sessions.py",
            "process_tree_measure.py",
            "provenance.json",
            "requirements.txt",
            "synthetic_workload.py",
            "test_measurement_helpers.py",
            "test_measurement_integration.py",
        )
    },
}
PROJECTION_FIELDS = {
    "schema_version",
    "source_format",
    "report_version",
    "pip_version",
    "raw_report",
    "distributions",
    "omitted_metadata",
}
OMISSIONS = ["package contacts", "long description and other non-provenance package metadata", "environment"]


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
    data = bootstrap.read_regular(path)
    return bootstrap.strict_json(data), dict(path=str(path), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())


def cost(value):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0, "Invalid retained cost")
    return value


def completed(row):
    require(
        isinstance(row, dict)
        and row.get("completed") is True
        and row.get("passed") is True
        and type(row.get("returncode")) is int
        and row["returncode"] == 0
        and type(row.get("observed_returncode")) is int
        and row["observed_returncode"] == 0
        and row.get("failure") is None
        and row.get("cleanup_root_unfinished") is False
        and row.get("cleanup_signals") == [],
        "Prior helper phase was not normally successful",
    )
    cost(row["wall_seconds"])


def prospective_interpreter(root, result, interpreter, python, required):
    """원래 설치 전후 영수증을 현재 바이트와 비교하되 과거 부재는 추정하지 않는다."""
    if "install_interpreter" not in result:
        require(not required, "Prospective installation interpreter receipt required")
        return None, None
    row, reference = read(root / "setup/install-interpreter.json")
    require(row == result["install_interpreter"], "Prospective duplicate receipt disagrees")
    require(
        isinstance(row, dict)
        and set(row) == {"schema_version", "status", "before", "after", "cost_accounting", "scope"}
        and type(row["schema_version"]) is int
        and row["schema_version"] == 1
        and row["status"] == "matched",
        "Prospective interpreter binding failed",
    )
    fields = {"status", "selected_path", "resolved_path", "bytes", "sha256", "file_identity", "wall_seconds"}
    resolved = interpreter.resolve(strict=True)
    info = resolved.stat()
    current_metadata = [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
    for when in ["before", "after"]:
        item = row[when]
        require(
            isinstance(item, dict)
            and set(item) == fields
            and item["status"] == "available"
            and item["selected_path"] == str(interpreter)
            and item["resolved_path"] == str(resolved)
            and type(item["bytes"]) is int
            and item["bytes"] == python["bytes"]
            and item["sha256"] == python["sha256"]
            and isinstance(item["file_identity"], list)
            and all(type(v) is int for v in item["file_identity"])
            and item["file_identity"] == current_metadata,
            "Prospective interpreter identity differs from current input",
        )
        cost(item["wall_seconds"])
    require(
        row["cost_accounting"] == "Capture costs are nested in diagnostic wall, outside command-only install wall"
        and row["scope"]
        == "Prospective selected interpreter identity only; no dynamic-loader or wheel equivalence proof",
        "Prospective interpreter receipt scope differs",
    )
    return row, reference


def spelling_failure(phase, command, interpreter, measurement_sha256):
    """관측 실패는 부재로 남기고 동일 물리 파일 여부가 원래 거부를 바꾸지 않게 한다."""
    physical = dict(status="unavailable", reason="interpreter-identity-not-observed")
    try:
        left, right = startup_profile.interpreter(command), startup_profile.interpreter(interpreter)
        physical = dict(status="observed-at-failure", equal=startup_profile.same_physical(left, right))
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        pass
    return attempt_receipts.InterpreterSpellingMismatch(phase, command, interpreter, measurement_sha256, physical)


def bind(measurement_results, repository, interpreter, require_prospective=True):
    started = time.perf_counter()
    source = Path(measurement_results)
    repository = Path(repository).resolve(strict=True)
    root = source.resolve(strict=True).parent
    result, result_ref = read(source)
    require(result.get("status") == "completed-synthetic-native-validation", "Measurement prerequisite failed")
    require(result.get("final_comparison") is False, "Unexpected prerequisite scope")
    phases = result["phases"]
    require(set(phases) == {"install", "tests", "machine", "calibration"}, "Unexpected prior phase inventory")
    for phase_name, row in phases.items():
        completed(row)
        try:
            require(row["command"][0] == str(interpreter), "Prior interpreter spellings differ")
        except ValueError as error:
            raise spelling_failure(phase_name, row["command"][0], str(interpreter), result_ref["sha256"]) from error
    install, install_ref = read(root / "setup/install.json")
    require(install == phases["install"], "Duplicate installation receipts disagree")
    argv = install["command"]
    require(
        isinstance(argv, list) and len(argv) == 16 and all(isinstance(v, str) for v in argv),
        "Unexpected installation argv shape",
    )
    target = Path(argv[11])
    require(
        target.is_absolute() and target.resolve(strict=True) == target and ".." not in target.parts,
        "Private installation target is not canonical",
    )
    require(not target.is_relative_to(root) and not root.is_relative_to(target), "Package/evidence boundary overlaps")
    requirements = repository / "Scripts/benchmark-measurement/requirements.txt"
    raw_report = root / "private-setup/install-report.json"
    expected = [
        str(interpreter),
        "-m",
        "pip",
        "install",
        "--index-url",
        "https://pypi.org/simple",
        "--no-input",
        "--disable-pip-version-check",
        "--no-cache-dir",
        "--only-binary=:all:",
        "--target",
        str(target),
        "--report",
        str(raw_report),
        "-r",
        str(requirements),
    ]
    require(argv == expected and Path(install["cwd"]).resolve() == repository, "Installation request differs")
    require(bootstrap.read_regular(requirements) == b"psutil==7.2.2\n", "Requirements changed")
    require(set(result["helper_hashes"]) == HELPER_PATHS, "Prior helper source inventory differs")
    source_refs = {}
    for name in sorted(HELPER_PATHS):
        data = bootstrap.read_regular(repository / name)
        actual = hashlib.sha256(data).hexdigest()
        require(actual == result["helper_hashes"][name], "Prior helper source bytes changed")
        source_refs[name] = actual
    projection, projection_ref = read(root / "setup/install-provenance.json")
    require(
        projection == result["install_provenance"] and set(projection) == PROJECTION_FIELDS,
        "Package provenance receipts differ",
    )
    require(
        projection["report_version"] == "1"
        and isinstance(projection["pip_version"], str)
        and bool(projection["pip_version"])
        and projection["omitted_metadata"] == OMISSIONS,
        "Unexpected projected metadata contract",
    )
    raw = projection["raw_report"]
    require(
        set(raw) == {"bytes", "sha256", "private_relative_path", "publication"}
        and raw["private_relative_path"] == "private-setup/install-report.json"
        and type(raw["bytes"]) is int
        and 0 < raw["bytes"] <= bootstrap.LIMIT,
        "Invalid original report identity",
    )
    # 원래 pip 메타데이터는 해석·복사·출력하지 않고 정규 파일의 전체 바이트만 확인한다.
    data = bootstrap.read_regular(raw_report)
    require(
        len(data) == raw["bytes"] and hashlib.sha256(data).hexdigest() == raw["sha256"],
        "Original installation report changed",
    )
    interpreter = Path(interpreter)
    require(interpreter.is_absolute(), "Interpreter spelling must be explicit")
    python = dict(path=str(interpreter), **runtime.file_identity(interpreter))
    install_interpreter, interpreter_ref = prospective_interpreter(
        root, result, interpreter, python, require_prospective
    )
    package = runtime.package_snapshot(target, projection)
    for reference in [result_ref, install_ref, projection_ref, *([interpreter_ref] if interpreter_ref else [])]:
        current = bootstrap.read_regular(Path(reference["path"]))
        require(
            len(current) == reference["bytes"] and hashlib.sha256(current).hexdigest() == reference["sha256"],
            "Prior installation receipt changed during binding",
        )
    require(
        runtime.file_identity(interpreter) == {key: python[key] for key in ("sha256", "bytes")},
        "Interpreter changed during binding",
    )
    require(
        hashlib.sha256(bootstrap.read_regular(raw_report)).hexdigest() == raw["sha256"],
        "Private report changed during binding",
    )
    for name, expected_hash in source_refs.items():
        require(
            hashlib.sha256(bootstrap.read_regular(repository / name)).hexdigest() == expected_hash,
            "Prior helper source changed during binding",
        )
    if install_interpreter is not None:
        prospective_interpreter(root, result, interpreter, python, True)
    return dict(
        schema_version=1,
        status="bound-for-validation",
        final_evidence=False,
        inputs=dict(
            measurement=result_ref, install=install_ref, projection=projection_ref, interpreter=interpreter_ref
        ),
        install_interpreter=install_interpreter,
        source_hashes=source_refs,
        python=python,
        package=package,
        prior_cost_references=dict(
            install_wall_seconds=cost(install["wall_seconds"]),
            provenance_projection_wall_seconds=cost(result["install_provenance_wall_seconds"]),
            whole_helper_diagnostic_wall_seconds=cost(result["diagnostic_wall_seconds"]),
            nesting="Install and projection are nested in prior diagnostic; do not add them to that whole again",
        ),
        binding_wall_seconds=time.perf_counter() - started,
        historical_interpreter_content=(
            "Prospective before/after install identities match current bytes"
            if install_interpreter
            else "Not captured at original install; current bytes sealed at same recorded spelling"
        ),
        scope="Official install request/report and current installed-byte inventory; no wheel-to-install or OS closure proof",
    )
