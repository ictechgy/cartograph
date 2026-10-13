#!/usr/bin/env python3
"""사전 기록 실패도 안전한 시도 영수증으로 보존하고 완성된 정규화 트리만 공개한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DISCOVERY = load("sdk_evidence_discovery", ROOT / "Scripts/validate-native-sdk-discovery.py")
BUNDLES = load("sdk_evidence_bundles", ROOT / "Scripts/normalize-indexstore-bundles.py")
SELECTOR = DISCOVERY.SELECTOR


def require(condition):
    if not condition:
        raise ValueError("Invalid bounded attempt receipt")


def raw_hash(path: Path) -> dict:
    value = SELECTOR.file_identity(path)
    return {key: value[key] for key in ("sha256", "bytes")}


def verified_attempt(attempt: Path, raw: Path, lifecycle_results: Path) -> dict:
    value, identity = DISCOVERY.document(attempt / "results.json")
    keys = {
        "schema_version",
        "role",
        "wrapper_sha256",
        "runner_sha256",
        "argv_sha256",
        "exit_code",
        "observed_returncode",
        "completed",
        "child_failure",
        "failure_category",
        "child_wall_seconds",
        "total_wall_seconds",
        "source_inputs_unchanged",
        "descendant_cleanup_verified",
        "stdout",
        "stderr",
        "raw_output_exists",
        "phase_receipt_sha256",
        "cleanup_signals",
        "cleanup_root_unfinished",
        "stderr_diagnostic_status",
    }
    require(
        isinstance(value, dict)
        and set(value) == keys
        and type(value["schema_version"]) is int
        and value["schema_version"] == 1
        and value["role"] == "sdk-discovery-attempt-envelope"
    )
    for key in ("wrapper_sha256", "runner_sha256", "argv_sha256", "phase_receipt_sha256"):
        require(isinstance(value[key], str) and bool(re.fullmatch(r"[0-9a-f]{64}", value[key])))
    require(value["wrapper_sha256"] == DISCOVERY.digest(Path(DISCOVERY.__file__)))
    require(value["runner_sha256"] == SELECTOR.RUNNER_SHA256)
    for key in ("exit_code", "observed_returncode"):
        require(
            (key == "observed_returncode" and value[key] is None)
            or (type(value[key]) is int and -128 <= value[key] <= 255)
        )
    require(value["exit_code"] >= 0)
    for key in (
        "completed",
        "source_inputs_unchanged",
        "descendant_cleanup_verified",
        "raw_output_exists",
        "cleanup_root_unfinished",
    ):
        require(type(value[key]) is bool)
    for key in ("child_wall_seconds", "total_wall_seconds"):
        require(type(value[key]) in (int, float) and math.isfinite(value[key]) and value[key] >= 0)
    require(value["total_wall_seconds"] >= value["child_wall_seconds"])
    require(
        value["failure_category"] in DISCOVERY.ATTEMPT_CATEGORIES
        and value["child_failure"] in (None, "timeout", "interrupt", "launch", "signal", "nested-incomplete")
    )
    require(value["descendant_cleanup_verified"] is False)
    phase, phase_identity = DISCOVERY.document(attempt / "process.json")
    require(phase_identity["sha256"] == value["phase_receipt_sha256"])
    require(
        isinstance(value["cleanup_signals"], list)
        and len(value["cleanup_signals"]) <= 4
        and all(
            v in ("term-sent", "kill-sent", "term-target-already-exited", "kill-target-already-exited")
            for v in value["cleanup_signals"]
        )
    )
    require(
        value["cleanup_signals"] == phase.get("cleanup_signals", [])
        and value["cleanup_root_unfinished"] == phase.get("cleanup_root_unfinished", False)
    )
    argv = phase["command"]
    require(isinstance(argv, list) and len(argv) == 6 and all(isinstance(v, str) for v in argv))
    require(
        Path(argv[1]).resolve() == Path(DISCOVERY.__file__).resolve()
        and argv[2] == "--lifecycle-results"
        and Path(argv[3]).absolute() == lifecycle_results.absolute()
        and argv[4] == "--output"
        and Path(argv[5]).resolve() == raw.resolve()
    )
    require(
        hashlib.sha256(json.dumps(argv, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
        == value["argv_sha256"]
    )
    require(
        phase["observed_returncode"] == value["observed_returncode"]
        and phase["wall_seconds"] == value["child_wall_seconds"]
        and phase["failure"] == value["child_failure"]
    )
    require(type(phase["completed"]) is bool and type(phase["passed"]) is bool and type(phase["returncode"]) is int)
    require(phase["passed"] == (phase["completed"] and phase["returncode"] == 0))
    require(value["source_inputs_unchanged"] or value["exit_code"] != 0)
    require(not value["cleanup_root_unfinished"] or value["exit_code"] == 125)
    if value["exit_code"] == 0:
        require(
            value["completed"]
            and value["observed_returncode"] == 0
            and value["child_failure"] is None
            and value["failure_category"] == "none"
        )
    incomplete = not phase["completed"] or phase["returncode"] == 125
    require(value["completed"] == (not incomplete))
    require(
        value["exit_code"] == (125 if incomplete else phase["returncode"])
        or value["failure_category"] == "supervision-inputs-changed"
    )
    current_identities = {}
    for kind in ("stdout", "stderr"):
        record = value[kind]
        require(isinstance(record, dict))
        if record.get("status") == "available":
            require(
                set(record) == {"status", "sha256", "bytes"}
                and type(record["bytes"]) is int
                and 0 <= record["bytes"] <= DISCOVERY.LOG_IDENTITY_LIMIT
                and isinstance(record["sha256"], str)
                and re.fullmatch(r"[0-9a-f]{64}", record["sha256"])
            )
        else:
            require(
                set(record) == {"status", "reason"}
                and record.get("status") == "unavailable"
                and record["reason"] in DISCOVERY.LOG_UNAVAILABLE_REASONS
            )
        path = attempt / ("process." + kind)
        require(Path(phase[kind]).resolve() == path.resolve())
        current_identities[kind] = DISCOVERY.log_identity(path)
        if record["status"] == "available":
            require(current_identities[kind] == record)
    original_category = "child-incomplete" if incomplete else "none" if phase["passed"] else "child-nonzero"
    category, diagnostic_status = DISCOVERY.diagnostic_category(
        attempt / "process.stderr", value["stderr"], original_category
    )
    require(value["stderr_diagnostic_status"] == diagnostic_status)
    require(value["failure_category"] == category or value["failure_category"] == "supervision-inputs-changed")
    # 과거의 읽기 실패를 나중의 성공 해시로 덮어쓰지 않는다.
    return {**value, "publication_log_identities": current_identities}


def publication_boundary(
    output: Path, lifecycle_results: Path, raw: Path, attempt: Path, scratch_root: Path | None
) -> None:
    """입력 루트가 불명확하면 명시한 CI scratch의 고정 형제 경로만 허용한다."""
    lifecycle = lifecycle_results.absolute().parent
    for destination in (output.absolute(), output.resolve()):
        require(not any(p.name.endswith((".sdk", ".xctoolchain")) for p in [destination, *destination.parents]))
        for source in (
            lifecycle.absolute(),
            lifecycle.resolve(),
            Path(__file__).resolve(),
            Path(DISCOVERY.__file__).resolve(),
        ):
            require(not destination.is_relative_to(source) and not source.is_relative_to(destination))
    try:
        data, _ = DISCOVERY.document(lifecycle_results)
    except SELECTOR.DiscoveryError:
        data = None
    setup = data.get("setup") if isinstance(data, dict) else None
    if isinstance(setup, dict) and all(key in setup for key in ("swiftc", "clang", "library", "sdk_path")):
        DISCOVERY.input_boundary(output, lifecycle, setup)
        return
    require(scratch_root is not None and scratch_root.is_dir())
    scratch = scratch_root.resolve()
    for value, name in (
        (output, "sdk-discovery-public"),
        (raw, "sdk-discovery-raw"),
        (attempt, "sdk-discovery-attempt"),
    ):
        require(value.absolute() == scratch_root.absolute() / name and value.resolve() == scratch / name)
    require(not scratch.is_relative_to(lifecycle.resolve()))


def compiler_path_aliases(raw: Path, lifecycle_results: Path) -> tuple[list[str], dict]:
    """봉인한 드라이버·SDK 요청의 두 고정 libc++ 후보 계열만 정규화한다."""
    paths = [raw / "results.json", raw / "setup/lifecycle-input.json", raw / "setup/selector-request.json"]
    if not all(path.is_file() for path in paths):
        return [], dict(status="unavailable", reason="missing-discovery-input-bindings")
    result, _ = DISCOVERY.document(paths[0])
    retained, retained_identity = DISCOVERY.document(paths[1])
    request, request_identity = DISCOVERY.document(paths[2])
    current, current_identity = DISCOVERY.document(lifecycle_results)
    expected = result.get("input_files", {}).get("results.json", {})
    require(current_identity["sha256"] == expected.get("sha256"))
    require(current == retained)
    setup = current["setup"]
    clang = SELECTOR.clean_path(setup["clang"])
    requested = request["tools"]["clang"]
    require(requested["path"] == str(clang))
    expected_hash = setup["compiler_toolchain_files"][str(clang.absolute())]
    require(requested["sha256"] == expected_hash)
    physical = clang.resolve(strict=True)
    require(SELECTOR.file_identity(physical)["sha256"] == expected_hash)
    chains = [p for p in physical.parents if p.name.endswith(".xctoolchain")]
    require(len(chains) == 1)
    chain = chains[0]
    require(physical.parent == chain / "usr/bin" and clang.parent.resolve() == physical.parent)
    canonical = chain / "usr/include/c++/v1"
    alias = clang.parent / "../include/c++/v1"
    require(alias.resolve() == canonical and canonical.resolve() == canonical)
    sdk = SELECTOR.clean_path(setup["sdk_path"])
    require(request["sdk"] == str(sdk))
    physical_sdk = SELECTOR.existing_directory(str(sdk))
    sdk_canonical = physical_sdk / "usr/include/c++/v1"
    sdk_alias = sdk / "usr/include/c++/v1"
    require(sdk_alias.resolve() == sdk_canonical and sdk_canonical.resolve() == sdk_canonical)
    sdk_stat = physical_sdk.stat()
    # 내용 봉인이 아니라 staging 중 루트 대체를 감지하는 메타데이터 경계다.
    sdk_metadata = [sdk_stat.st_dev, sdk_stat.st_ino, sdk_stat.st_mode, sdk_stat.st_mtime_ns, sdk_stat.st_ctime_ns]
    prefixes = ["CLANG_CXX_HEADERS=" + str(alias), "SDK_CXX_HEADERS=" + str(sdk_alias)]
    return prefixes, dict(
        status="verified",
        token="$CLANG_CXX_HEADERS",
        scope="Two fixed libc++ candidate families only; no SDK contents or input-root acceptance",
        sdk_request_binding="exact-selected-sdk",
        sdk_lexical_prefix_sha256=hashlib.sha256(str(sdk_alias).encode()).hexdigest(),
        sdk_canonical_prefix_sha256=hashlib.sha256(str(sdk_canonical).encode()).hexdigest(),
        sdk_root_metadata_sha256=hashlib.sha256(json.dumps(sdk_metadata, separators=(",", ":")).encode()).hexdigest(),
        lifecycle_sha256=current_identity["sha256"],
        retained_lifecycle_sha256=retained_identity["sha256"],
        request_sha256=request_identity["sha256"],
        clang_sha256=expected_hash,
        lexical_prefix_sha256=hashlib.sha256(str(alias).encode()).hexdigest(),
        canonical_prefix_sha256=hashlib.sha256(str(canonical).encode()).hexdigest(),
    )


def publish(
    raw: Path,
    attempt: Path,
    output: Path,
    prefixes: list[str],
    lifecycle_results: Path,
    scratch_root: Path | None = None,
) -> tuple[dict, int]:
    started = time.perf_counter()
    # 검증 가능한 원래 argv가 있으면 입력 경계를 바꾸어 staging 쓰기를 허용하지 않는다.
    if (attempt / "process.json").exists():
        try:
            phase, _ = DISCOVERY.document(attempt / "process.json")
        except SELECTOR.DiscoveryError:
            phase = None
        argv = phase.get("command") if isinstance(phase, dict) else None
        if isinstance(argv, list) and len(argv) == 6 and all(isinstance(v, str) for v in argv):
            require(argv[2] == "--lifecycle-results" and argv[4] == "--output")
            require(Path(argv[3]).absolute() == lifecycle_results.absolute())
    publication_boundary(output, lifecycle_results, raw, attempt, scratch_root)
    raw = raw.resolve()
    attempt = attempt.resolve()
    output = output.absolute()
    for source in (raw, attempt):
        if output.resolve().is_relative_to(source) or source.is_relative_to(output.resolve()):
            raise ValueError("Publication output overlaps input")
    if output.exists() or output.is_symlink():
        raise FileExistsError("Publication output already exists")
    staging = output.with_name(output.name + ".pending")
    staging.mkdir(parents=True, exist_ok=False)
    ready = staging / "ready"
    ready.mkdir()
    status = dict(
        schema_version=1,
        role="sdk-discovery-publication-envelope",
        raw_fallback=False,
        complete_run_evidence=False,
        attempt_status="missing",
        discovery_bundle_status="missing",
        exit_code=None,
        publication_failure=None,
        raw_path_sha256=BUNDLES.fingerprint(str(raw)),
        attempt_path_sha256=BUNDLES.fingerprint(str(attempt)),
        manifests=[],
    )
    receipt = None
    if (attempt / "results.json").exists():
        try:
            status["attempt_raw_identity"] = raw_hash(attempt / "results.json")
            receipt = verified_attempt(attempt, raw, lifecycle_results)
            SELECTOR.save(ready / "attempt.json", receipt)
            status.update(attempt_status="verified", exit_code=receipt["exit_code"])
            if any(receipt[kind]["status"] != "available" for kind in ("stdout", "stderr")):
                status["publication_failure"] = "log-identities-unavailable"
        except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
            status.update(
                attempt_status="blocked",
                publication_failure="invalid-attempt-receipt",
                attempt_error_sha256=BUNDLES.fingerprint(str(error)),
            )
    else:
        status["publication_failure"] = "missing-attempt-receipt"
    if raw.is_dir():
        try:
            aliases, alias_receipt = compiler_path_aliases(raw, lifecycle_results)
            status["normalization_aliases"] = alias_receipt
            args = argparse.Namespace(input=raw, output=staging / "candidate", prefix=[*prefixes, *aliases])
            BUNDLES.EVIDENCE.package(args)
            require(compiler_path_aliases(raw, lifecycle_results) == (aliases, alias_receipt))
            os.replace(staging / "candidate", ready / "discovery")
            status.update(discovery_bundle_status="normalized", manifests=["discovery/manifest.json"])
        except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
            status.update(discovery_bundle_status="blocked", normalization_diagnostic=BUNDLES.diagnostic(error))
            status["publication_failure"] = "discovery-normalization-blocked"
    elif status["publication_failure"] is None:
        status["publication_failure"] = "missing-discovery-output"
    succeeded = (
        receipt is not None
        and receipt["exit_code"] == 0
        and status["discovery_bundle_status"] == "normalized"
        and status["attempt_status"] == "verified"
        and status["publication_failure"] is None
    )
    code = 0 if succeeded else 125 if receipt is not None and receipt["exit_code"] == 125 else 1
    status.update(
        status="prepared" if succeeded else "prepared-with-failures",
        publication_wall_seconds=time.perf_counter() - started,
        publication_exit_code=code,
    )
    SELECTOR.save(ready / "publication-status.json", status)
    os.replace(ready, output)
    return status, code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--attempt", type=Path, required=True)
    parser.add_argument("--lifecycle-results", type=Path, required=True)
    parser.add_argument("--scratch-root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prefix", action="append", default=[])
    parser.add_argument("--ready-output", type=Path)
    args = parser.parse_args()
    status, code = publish(
        args.input, args.attempt, args.output, args.prefix, args.lifecycle_results, args.scratch_root
    )
    if args.ready_output:
        with args.ready_output.open("a") as stream:
            stream.write("ready=true\n")
    print(
        json.dumps(
            {
                key: status[key]
                for key in (
                    "status",
                    "attempt_status",
                    "discovery_bundle_status",
                    "publication_failure",
                    "publication_exit_code",
                )
            }
        )
    )
    raise SystemExit(code)


if __name__ == "__main__":
    main()
