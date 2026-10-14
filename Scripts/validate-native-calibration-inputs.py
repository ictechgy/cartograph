#!/usr/bin/env python3
"""기존 설치·SDK 봉인·정규화기를 고정 수동 진단 단계에 연결한다."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ROOT / "Scripts/benchmark-inputs"
ACTUAL = ROOT / "Scripts/benchmark-actual-arm"
MEASUREMENT = ROOT / "Scripts/benchmark-measurement"
sys.path[:0] = [str(INPUTS), str(ACTUAL), str(ACTUAL / "runtime")]
import native_calibration_inputs as admission
import installation_binding
import runtime_bootstrap
import state_inputs


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COMMAND = load("calibration_command", ROOT / "Scripts/validate-native-measurement.py")
NORMALIZER = load("calibration_normalizer", ROOT / "Scripts/normalize-indexstore-evidence.py")
# 정규화기의 고정 분류만 공개하며 알 수 없는 예외 속성을 로그 문자열로 쓰지 않는다.
PUBLICATION_FAILURE_CATEGORIES = frozenset({
    "api-token", "aws-key", "bearer-token", "credential-field-or-assignment", "credential-json-field",
    "credential-url", "email-address", "environment-dump", "file-count-limit", "github-token",
    "helper-process-identity-cleanup", "helper-process-identity-not-injective", "helper-process-identity-reassigned",
    "helper-process-identity-rss-sum", "helper-process-identity-schema", "helper-process-identity-unbound",
    "invalid-or-ambiguous-json", "invalid-or-ambiguous-jsonl", "invalid-url", "log-reference-not-in-public-bundle",
    "missing-nonregular-or-symlink-artifact", "non-utf8-or-binary-content", "normalized-json-key-collision",
    "normalized-size-limit", "per-file-size-limit", "possible-environment-dump", "possible-json-environment-dump",
    "private-key", "raw-evidence-changed-during-normalization", "sample-chunk-integrity",
    "sample-chunk-integrity-changed", "secret-argument", "secret-assignment", "slack-token", "symlink-directory",
    "token-bearing-or-signed-url", "total-size-limit", "unexpected-control-or-binary-content",
    "unmapped-absolute-path", "unmapped-windows-absolute-path",
})


def save(path, value, *, exclusive=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x" if exclusive else "w") as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write("\n")


def document(path):
    return runtime_bootstrap.strict_json(runtime_bootstrap.read_regular(path))


def fixed_root(value):
    path = Path(value)
    selected = os.environ.get("RUNNER_TEMP")
    admission.require(selected is not None and path.is_absolute() and ".." not in path.parts,
                      "missing-current-scratch")
    root = path.resolve(strict=True)
    admission.require(root == Path(selected).resolve(strict=True) and root.is_dir() and root != Path("/"),
                      "scratch-context-mismatch")
    admission.evidence_boundary(root / "native-calibration-sdk-raw", admission.expectation()[0])
    admission.require(not root.is_relative_to(ROOT) and not ROOT.is_relative_to(root), "repository-scratch-overlap")
    return root


def helper_hashes():
    paths = [
        Path(__file__), INPUTS / "native_calibration_inputs.py", INPUTS / "native_calibration_expectation.json",
        INPUTS / "native_calibration_publication.py", INPUTS / "sdk_content_seal.py",
        INPUTS / "select_sdk_roots.py", ROOT / "Scripts/normalize-indexstore-evidence.py",
        ROOT / ".github/workflows/native-calibration.yml",
    ]
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def bound_machine_fields(root):
    # 기존 설치 영수증을 검증한 뒤에만 같은 psutil 트리를 관측 함수 import에 사용한다.
    measurement = root / "measurement-helper-raw/results.json"
    result = document(measurement)
    selected = Path(result["install_interpreter"]["before"]["selected_path"])
    admission.require(Path(sys.executable).resolve(strict=True) == selected.resolve(strict=True),
                      "different-current-interpreter")
    binding = installation_binding.bind(measurement, ROOT, selected)
    sys.path[:0] = [binding["package"]["target"], str(MEASUREMENT)]
    machine = load("calibration_machine_fields", MEASUREMENT / "machine_manifest.py")
    return machine.macos_fields, binding


def stage(name, root):
    started = time.perf_counter()
    raw = root / "native-calibration-sdk-raw"
    phases = raw / "setup/phases"
    phase_path = phases / (name + ".json")
    if name == "before-compilation":
        raw.mkdir(exist_ok=False)
        save(raw / "results.json", dict(
            schema_version=1, role="native-calibration-sdk-candidate", accepted=False,
            final_protocol_ready=False, status="started", stages={}, helper_sha256=helper_hashes(),
        ))
    summary = document(raw / "results.json")
    admission.require(not phase_path.exists(), "preserve-existing-stage")
    admission.require(summary["helper_sha256"] == helper_hashes(), "calibration-input-source-changed")
    save(phases / (name + ".started.json"), dict(stage=name, status="started", final_protocol_ready=False))
    phase = dict(stage=name, status="failed", exit_code=1, accepted=False, final_protocol_ready=False,
                 helper_sha256=summary["helper_sha256"])
    try:
        required = {"before-compilation": set(), "after-generation": {"before-compilation"},
                    "after-calibration": {"before-compilation", "after-generation"}}[name]
        admission.require(set(summary["stages"]) == required and all(
            item["status"] == "passed" and type(item["exit_code"]) is int and item["exit_code"] == 0
            for item in summary["stages"].values()), "prior-stage-incomplete")
        prior_phases = {}
        for previous in sorted(required):
            prior = summary["stages"][previous]
            expected_path = phases / (previous + ".json")
            admission.require(prior["original"] == state_inputs.reference(expected_path), "prior-phase-changed")
            prior_phases[previous] = state_inputs.document(prior["original"])
            admission.require(prior_phases[previous]["stage"] == previous
                              and prior_phases[previous]["helper_sha256"] == summary["helper_sha256"]
                              and prior_phases[previous]["status"] == "passed"
                              and type(prior_phases[previous]["exit_code"]) is int
                              and prior_phases[previous]["exit_code"] == 0
                              and prior_phases[previous]["accepted"] is False
                              and prior_phases[previous]["final_protocol_ready"] is False,
                              "prior-phase-binding-changed")
        if required:
            admission.require(json.dumps(document(raw / "before-compilation/results.json"), sort_keys=True, allow_nan=False) ==
                              json.dumps(prior_phases["before-compilation"]["observation"], sort_keys=True, allow_nan=False),
                              "candidate-result-changed")
        machine_fields, binding = bound_machine_fields(root)
        phase["installation_binding"] = binding
        options = dict(machine_fields=machine_fields, command=COMMAND.command, environment=dict(os.environ))
        if name == "before-compilation":
            observed = admission.begin(raw / name, **options)
            passed = observed["status"] == "captured-candidate"
        else:
            candidate = document(raw / "before-compilation/results.json")
            observed = admission.verify_boundary(candidate, raw / name, boundary=name, **options)
            passed = observed["status"] == "verified-candidate"
            if passed and name == "after-generation":
                at = time.perf_counter()
                try:
                    request_path = root / "sdk-discovery-raw/setup/selector-request.json"
                    result_path = root / "sdk-discovery-raw/setup/discovery/results.json"
                    request, discovery = document(request_path), document(result_path)
                    phase["discovery_inputs"] = {
                        "request": state_inputs.reference(request_path), "result": state_inputs.reference(result_path),
                    }
                    phase["discovery_binding"] = admission.bind_discovery(candidate, request, discovery)
                finally:
                    phase["discovery_binding_wall_seconds"] = time.perf_counter() - at
            if name == "after-calibration":
                original = root / "actual-arm-correctness-raw/setup/controller-result.json"
                phase["calibration_controller"] = state_inputs.reference(original)
                controller = document(original)
                phase["calibration_status"] = dict(status=controller["status"], exit_code=controller["exit_code"])
                passed = passed and controller["status"] == "passed" and type(controller["exit_code"]) is int and controller["exit_code"] == 0
        phase["observation"] = observed
        phase.update(status="passed" if passed else "incomplete" if observed["status"] == "incomplete" else "failed", exit_code=0 if passed else 125
                     if observed["status"] == "incomplete" else 1)
        admission.require(helper_hashes() == summary["helper_sha256"], "calibration-input-source-changed")
    except (KeyboardInterrupt, OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        phase.update(status="incomplete" if isinstance(error, KeyboardInterrupt) else "failed",
                     exit_code=125 if isinstance(error, KeyboardInterrupt) else 1,
                     failure_type=type(error).__name__, failure_sha256=hashlib.sha256(str(error).encode()).hexdigest())
    phase["wall_seconds_before_receipt"] = time.perf_counter() - started
    save(phase_path, phase)
    summary["stages"][name] = dict(status=phase["status"], exit_code=phase["exit_code"],
                                  original=state_inputs.reference(phase_path))
    if phase["exit_code"] != 0 and "first_failure" not in summary:
        summary["first_failure"] = dict(stage=name, exit_code=phase["exit_code"])
    summary["status"] = "retained-failure" if "first_failure" in summary else "candidate-in-progress"
    if set(summary["stages"]) == {"before-compilation", "after-generation", "after-calibration"} and "first_failure" not in summary:
        summary["status"] = "candidate-evidence-ready"
    save(raw / "results.json", summary, exclusive=False)
    return phase["exit_code"]


def supervise(name, root):
    """단계의 Python 시작·영수증 기록까지 실제 자식 종료로 관측한다."""
    started = time.perf_counter()
    output = root / "native-calibration-sdk-calls" / name
    output.mkdir(parents=True, exist_ok=False)
    argv = [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()),
            "--stage", name, "--scratch-root", str(root), "--execute-stage"]
    save(output / "started.json", dict(stage=name, command=argv, status="started"))
    result = dict(stage=name, command=None, helper_sha256=helper_hashes(),
                  accepted=False, final_protocol_ready=False, status="failed", exit_code=1)
    try:
        phase = COMMAND.command(argv, ROOT, output / "command", dict(os.environ), 570)
        result["command"] = phase
        ref = state_inputs.reference(root / "native-calibration-sdk-raw/setup/phases" / (name + ".json"))
        original = state_inputs.document(ref)
        result["original_phase"] = ref
        admission.require(phase["completed"] is True and phase["passed"] is True
                          and type(phase["returncode"]) is int and phase["returncode"] == 0
                          and type(phase["observed_returncode"]) is int and phase["observed_returncode"] == 0 and phase["failure"] is None
                          and phase["cleanup_signals"] == [] and phase["cleanup_root_unfinished"] is False
                          and original["stage"] == name and original["status"] == "passed"
                          and type(original["exit_code"]) is int and original["exit_code"] == 0
                          and original["helper_sha256"] == result["helper_sha256"]
                          and original["accepted"] is False and original["final_protocol_ready"] is False,
                          "stage-call-incomplete")
        result.update(status="passed", exit_code=0)
    except (KeyboardInterrupt, OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        incomplete = isinstance(error, KeyboardInterrupt) or result["command"] is None or result["command"]["returncode"] == 125
        result.update(status="incomplete" if incomplete else "failed",
                      exit_code=125 if incomplete else 1,
                      failure_type=type(error).__name__, failure_sha256=hashlib.sha256(str(error).encode()).hexdigest())
    result["full_call_wall_seconds_before_receipt"] = time.perf_counter() - started
    save(output / "results.json", result)
    return result["exit_code"]


def original_small_files(raw, calls):
    """대형 봉인을 제외한 모든 원본의 집합과 바이트를 경계마다 같은 방식으로 읽는다."""
    excluded = {"before-compilation/seal.json", "after-generation/seal-verification.json",
                "after-calibration/seal-verification.json"}
    rows = {}
    for label, base in (("raw", raw), ("calls", calls)):
        try:
            base.lstat()
        except FileNotFoundError:
            continue
        admission.require(not base.is_symlink() and base.is_dir(), "publication-source-type")
        for directory, names, files in os.walk(base, followlinks=False):
            admission.require(all(not (Path(directory) / name).is_symlink() for name in names), "publication-symlink")
            for name in files:
                path = Path(directory) / name
                relative = path.relative_to(base).as_posix()
                if label == "raw" and relative in excluded:
                    continue
                admission.require(path.suffix in {".json", ".stdout", ".stderr"} and not path.is_symlink(),
                                  "unexpected-publication-file")
                rows[label + "/" + relative] = runtime_bootstrap.read_regular(path)
    return rows


def publication_failure(error):
    """실패 원문 대신 고정 분류와 이미 계산된 SHA 식별자만 공개한다."""
    result = dict(category="publication-failure", artifact_sha256=None, value_sha256=None)
    if type(error) is NORMALIZER.PublicationBlocked:
        reason = error.reason
        result["category"] = (reason if type(reason) is str and reason in PUBLICATION_FAILURE_CATEGORIES
                              else "normalizer-publication-blocked")
        for key in ("artifact_sha256", "value_sha256"):
            value = getattr(error, key, None)
            if type(value) is str and len(value) == 64 and all(char in "0123456789abcdef" for char in value):
                result[key] = value
    return result


def publish(root):
    started = time.perf_counter()
    path = root / "native-calibration-sdk-publication.json"
    admission.require(not path.exists(), "preserve-publication-receipt")
    result = dict(status="failed", exit_code=1, accepted=False, final_protocol_ready=False, costs={},
                  publication_failure=None)
    try:
        result["public_manifest"] = publish_bundle(root, result["costs"])
        result.update(status="passed", exit_code=0)
    except (KeyboardInterrupt, OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        result.update(status="incomplete" if isinstance(error, KeyboardInterrupt) else "failed",
                      exit_code=125 if isinstance(error, KeyboardInterrupt) else 1,
                      failure_type=type(error).__name__, failure_sha256=hashlib.sha256(str(error).encode()).hexdigest(),
                      publication_failure=publication_failure(error))
    result["full_wall_seconds_before_receipt"] = time.perf_counter() - started
    save(path, result)
    # 실패 분류·SHA와 기존 비용·상태만 남기고 원문은 일반 스캐너가 통과한 번들에만 싣는다.
    print(json.dumps({key: result[key] for key in ("status", "exit_code", "costs", "publication_failure",
                                                 "full_wall_seconds_before_receipt")},
                     sort_keys=True, allow_nan=False))
    return result["exit_code"]


def publish_bundle(root, costs):
    # 큰 봉인 원본은 정확한 가역 분할 표현으로만 옮기고 동일한 일반 스캐너를 통과시킨다.
    raw = root / "native-calibration-sdk-raw"
    summary = document(raw / "results.json")
    admission.require(summary["helper_sha256"] == helper_hashes(), "calibration-input-source-changed")
    projection = load("calibration_seal_projection", INPUTS / "native_calibration_publication.py")
    staging = root / "native-calibration-sdk-staging"
    public = root / "native-calibration-sdk-public"
    admission.require(not staging.exists() and not public.exists(), "preserve-publication")
    staging.mkdir()
    save(staging / "results.json", summary)
    calls = root / "native-calibration-sdk-calls"
    originals = original_small_files(raw, calls)
    for relative, data in originals.items():
        target = staging / "setup/original" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
    def measured(name, function, *args):
        at = time.perf_counter()
        try:
            value = function(*args)
            costs[name] = dict(status="passed", result=value)
            return value
        finally:
            costs.setdefault(name, dict(status="failed"))["full_wall_seconds"] = time.perf_counter() - at

    measured("prepare_projection", projection.prepare_projection, raw, staging)
    save(staging / "setup/original-copy-manifest.json", dict(files=[
        dict(path=name, sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
        for name, data in sorted(originals.items())
    ]))
    prefixes = [
        "WORKSPACE=" + str(ROOT), "RUNNER_TEMP=" + str(root),
        "RUNNER_HOME=" + str(Path.home()), "DEVELOPER=" + admission.expectation()[0]["developer_physical"],
        "APPLICATIONS=/Applications", "LIBRARY=/Library", "SYSTEM=/System", "PRIVATE=/private",
        "USR=/usr", "OPT=/opt", "BIN=/bin", "DEV=/dev", "TEMP=/var",
    ]
    at = time.perf_counter()
    try:
        manifest = NORMALIZER.package(argparse.Namespace(input=staging, output=public, prefix=prefixes))
        costs["normalizer"] = dict(status="passed")
    finally:
        costs.setdefault("normalizer", dict(status="failed"))["full_wall_seconds"] = time.perf_counter() - at
    measured("verify_publication", projection.verify_publication, staging, public, manifest)
    measured("verify_sources", projection.verify_sources, raw, staging)
    admission.require(original_small_files(raw, calls) == originals, "original-publication-input-changed")
    admission.require(summary["helper_sha256"] == helper_hashes(), "calibration-input-source-changed")
    return state_inputs.reference(public / "manifest.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["before-compilation", "after-generation", "after-calibration", "publish"], required=True)
    parser.add_argument("--scratch-root", type=Path, required=True)
    parser.add_argument("--execute-stage", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        root = fixed_root(args.scratch_root)
        admission.require(not (args.execute_stage and args.stage == "publish"), "invalid-internal-stage")
        code = publish(root) if args.stage == "publish" else (
            stage(args.stage, root) if args.execute_stage else supervise(args.stage, root))
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        print(json.dumps(dict(status="refused", failure_type=type(error).__name__,
                              failure_sha256=hashlib.sha256(str(error).encode()).hexdigest())), file=sys.stderr)
        return 1
    print(json.dumps(dict(stage=args.stage, exit_code=code, accepted=False, final_protocol_ready=False)))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
