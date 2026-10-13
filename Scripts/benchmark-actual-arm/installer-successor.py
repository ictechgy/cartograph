#!/usr/bin/env python3
"""기존 macOS CI에서 고정 합성 측정 진단을 실행하고 모든 단계 결과를 남긴다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / "Scripts/benchmark-measurement"


def save(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def plan() -> dict:
    return dict(
        role="fixed synthetic native helper validation only",
        final_comparison=False,
        pairs_per_workload_mode=4,
        randomization_seed=20261012,
        bootstrap_seed=101226,
        sample_interval_seconds=0.01,
        runner_regime="moving macos-latest/newest-Xcode pilot",
        real_engine_calibration="not-run",
        sdk_content_identity="not-proved",
        containment="known cooperative/retained identities only; detached macOS ancestry gaps remain",
        cache_policy="OS filesystem caches and unrelated host load uncontrolled",
    )


def command(argv: list[str], cwd: Path, stem: Path, environment: dict, timeout: float) -> dict:
    """완료되지 않은 단계는 125로 남긴다. 다음 단계는 호출자가 시작하지 않는다."""
    stem.parent.mkdir(parents=True, exist_ok=True)
    stdout, stderr = Path(str(stem) + ".stdout"), Path(str(stem) + ".stderr")
    if any(Path(str(stem) + suffix).exists() for suffix in (".stdout", ".stderr", ".json")):
        raise ValueError("Existing command evidence must not be overwritten")
    started = time.perf_counter()
    cleanup_signals, cleanup_root_unfinished = [], False
    failure, process, completed, code = None, None, False, 125
    with stdout.open("xb") as out, stderr.open("xb") as err:
        try:
            process = subprocess.Popen(argv, cwd=cwd, env=environment, stdout=out, stderr=err, start_new_session=True)
            code = process.wait(timeout=timeout)
            completed = code >= 0 and code != 125
            if not completed:
                failure = "nested-incomplete" if code == 125 else "signal"
        except subprocess.TimeoutExpired:
            failure = "timeout"
        except KeyboardInterrupt:
            failure = "interrupt"
        except OSError:
            failure = "launch"
        finally:
            if process is not None and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    cleanup_signals.append("term-sent")
                except ProcessLookupError:
                    cleanup_signals.append("term-target-already-exited")
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                        cleanup_signals.append("kill-sent")
                    except ProcessLookupError:
                        cleanup_signals.append("kill-target-already-exited")
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        cleanup_root_unfinished = True
    row = dict(
        command=argv,
        cwd=str(cwd),
        returncode=code if completed else 125,
        observed_returncode=process.returncode if process is not None else None,
        completed=completed,
        passed=completed and code == 0,
        failure=failure,
        wall_seconds=time.perf_counter() - started,
        descendant_cleanup_verified=False,
        containment="POSIX process-group fallback only; no detached-descendant guarantee",
        stdout=str(stdout.resolve()),
        stderr=str(stderr.resolve()),
        cleanup_signals=cleanup_signals,
        cleanup_root_unfinished=cleanup_root_unfinished,
    )
    save(Path(str(stem) + ".json"), row)
    return row


def helper_hashes() -> dict:
    return {
        str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(
            [
                *HELPERS.iterdir(),
                Path(__file__).resolve(),
                ROOT / "Scripts/normalize-indexstore-evidence.py",
                ROOT / ".github/workflows/ci.yml",
            ]
        )
        if p.is_file()
    }


def interpreter_observation(selected: str) -> dict:
    """선택한 실행 경로와 실제 정규 파일을 제한된 no-follow 읽기로 묶는다."""
    started = time.perf_counter()
    row = dict(status="unavailable", selected_path=selected)
    descriptor = None
    try:
        path = Path(selected)
        if not path.is_absolute():
            raise ValueError("interpreter-path-not-absolute")
        resolved = path.resolve(strict=True)
        before = resolved.lstat()
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= 256 * 1024**2:
            raise ValueError("interpreter-not-bounded-regular-file")

        def identity(info):
            return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

        descriptor = os.open(resolved, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        if identity(os.fstat(descriptor)) != identity(before):
            raise ValueError("interpreter-changed-during-capture")
        digest, count = hashlib.sha256(), 0
        while chunk := os.read(descriptor, 1024**2):
            count += len(chunk)
            if count > before.st_size:
                raise ValueError("interpreter-changed-during-capture")
            digest.update(chunk)
        if (
            count != before.st_size
            or identity(os.fstat(descriptor)) != identity(before)
            or identity(resolved.lstat()) != identity(before)
            or path.resolve(strict=True) != resolved
        ):
            raise ValueError("interpreter-changed-during-capture")
        row.update(
            status="available",
            resolved_path=str(resolved),
            bytes=count,
            sha256=digest.hexdigest(),
            file_identity=list(identity(before)),
        )
    except ValueError as error:
        row["failure"] = str(error)
    except (OSError, RuntimeError):
        row["failure"] = "interpreter-identity-unavailable"
    except KeyboardInterrupt:
        row.update(status="incomplete", failure="interpreter-capture-interrupted")
    finally:
        if descriptor is not None:
            os.close(descriptor)
        row["wall_seconds"] = time.perf_counter() - started
    return row


def same_interpreter(before: dict, after: dict) -> bool:
    """시점별 비용은 정체성 비교에서 제외하고 경로·내용·메타데이터는 모두 비교한다."""
    keys = ("selected_path", "resolved_path", "bytes", "sha256", "file_identity")
    return before.get("status") == after.get("status") == "available" and all(before[key] == after[key] for key in keys)


def install_provenance(output: Path) -> dict:
    """공개 패키지의 연락처/설명은 원본에만 두고 필요한 배포 증거를 엄격히 추린다."""
    path = output / "private-setup/install-report.json"
    target = output / "setup/install-provenance.json"
    if target.exists() or path.is_symlink() or not path.is_file():
        raise ValueError("Invalid or existing package provenance evidence")
    with path.open("rb") as stream:
        raw = stream.read(4 * 1024**2 + 1)
    if len(raw) > 4 * 1024**2:
        raise ValueError("Package report exceeds fixed size limit")
    retained = dict(
        private_relative_path="private-setup/install-report.json",
        sha256=hashlib.sha256(raw).hexdigest(),
        bytes=len(raw),
        publication="Full original omitted; package metadata and environment remain private",
    )
    save(output / "setup/install-report-retention.json", retained)

    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate package report key")
            result[key] = value
        return result

    report = json.loads(raw, object_pairs_hook=unique_pairs)
    if (
        not isinstance(report, dict)
        or set(report) != {"version", "pip_version", "install", "environment"}
        or report["version"] != "1"
        or not isinstance(report["pip_version"], str)
        or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", report["pip_version"])
        or not isinstance(report["environment"], dict)
        or not isinstance(report["install"], list)
        or len(report["install"]) != 1
    ):
        raise ValueError("Unsupported package report schema or distribution count")
    entry = report["install"][0]
    if (
        not isinstance(entry, dict)
        or set(entry) != {"download_info", "is_direct", "is_yanked", "requested", "metadata"}
        or entry["is_direct"] is not False
        or entry["is_yanked"] is not False
        or entry["requested"] is not True
    ):
        raise ValueError("Unsupported package distribution flags")
    metadata, download = entry["metadata"], entry["download_info"]
    if (
        not isinstance(metadata, dict)
        or metadata.get("name") != "psutil"
        or metadata.get("version") != "7.2.2"
        or not isinstance(download, dict)
        or set(download) != {"url", "archive_info"}
        or not isinstance(download["url"], str)
    ):
        raise ValueError("Unexpected package or distribution schema")
    url = urlsplit(download["url"])
    if (
        url.scheme != "https"
        or url.netloc != "files.pythonhosted.org"
        or url.query
        or url.fragment
        or not re.fullmatch(
            r"/packages/[a-f0-9]{2}/[a-f0-9]{2}/[a-f0-9]{60}/psutil-7\.2\.2-[A-Za-z0-9._-]+\.whl",
            url.path,
        )
    ):
        raise ValueError("Distribution URL is not the expected unsigned official wheel URL")
    archive = download["archive_info"]
    if (
        not isinstance(archive, dict)
        or set(archive) != {"hash", "hashes"}
        or not isinstance(archive["hashes"], dict)
        or set(archive["hashes"]) != {"sha256"}
        or not isinstance(archive["hashes"]["sha256"], str)
        or not re.fullmatch(r"[a-f0-9]{64}", archive["hashes"]["sha256"])
        or archive["hash"] != "sha256=" + archive["hashes"]["sha256"]
    ):
        raise ValueError("Distribution hash is missing, inconsistent or unsupported")
    projected = dict(
        schema_version=1,
        source_format="pip-install-report-v1",
        raw_report=retained,
        report_version=report["version"],
        pip_version=report["pip_version"],
        distributions=[
            dict(
                name="psutil",
                version="7.2.2",
                url=download["url"],
                sha256=archive["hashes"]["sha256"],
                is_direct=False,
                is_yanked=False,
                requested=True,
            )
        ],
        omitted_metadata=[
            "package contacts",
            "long description and other non-provenance package metadata",
            "environment",
        ],
    )
    save(target, projected)
    return projected


def calibration_passed(output: Path, config: dict) -> bool:
    """도우미의 종료 0만으로 실패한 합성 쌍이나 빠진 그룹을 통과시키지 않는다."""
    directory = output / "runs/calibration"
    try:
        summary = json.loads((directory / "summary.json").read_text())
        groups = summary["groups"]
        expected = {(w, m) for w in ["one_sustained_process", "twelve_cli_subprocesses"] for m in ["timing", "memory"]}
        return (
            summary["all_outputs_agree"] is True
            and len(groups) == 4
            and {(g["workload"], g["mode"]) for g in groups} == expected
            and summary["plan_sha256"] == hashlib.sha256((directory / "plan.json").read_bytes()).hexdigest()
            and all(
                g["failed_pairs"] == []
                and g["pair_count"] == config["pairs_per_workload_mode"]
                and g["AB_count"] == g["BA_count"] == config["pairs_per_workload_mode"] // 2
                for g in groups
            )
        )
    except (OSError, ValueError, KeyError, TypeError):
        return False


def validate(output: Path, dependencies: Path) -> dict:
    """진단 단계가 실패하면 증거를 남기되 이후 실행으로 오염을 전파하지 않는다."""
    if sys.platform != "darwin":
        raise ValueError("This diagnostic requires native macOS; no platform substitution")
    output, dependencies = output.resolve(), dependencies.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError("Evidence output must be absent or empty")
    if dependencies.exists():
        raise ValueError("Dependency directory must be new and task-owned")
    if dependencies.is_relative_to(output) or output.is_relative_to(dependencies):
        raise ValueError("Dependency bytes and publishable raw evidence must be separate")
    started = time.perf_counter()
    output.mkdir(parents=True, exist_ok=True)
    (output / "runs").mkdir()
    (output / "private-setup").mkdir()
    config, hashes = plan(), helper_hashes()
    save(output / "setup/plan.json", config)
    save(output / "setup/helper-hashes.json", hashes)
    # 사용자 pip 구성/추가 인덱스를 상속하지 않고 공식 PyPI만 사용한다. 값은 증거에 기록하지 않는다.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("PIP_")}
    environment["PIP_CONFIG_FILE"] = os.devnull
    environment["PYTHONPATH"] = str(dependencies)
    phases = [
        (
            "install",
            [
                sys.executable,
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
                str(dependencies),
                "--report",
                str(output / "private-setup/install-report.json"),
                "-r",
                str(HELPERS / "requirements.txt"),
            ],
            180,
        ),
        ("tests", [sys.executable, "-m", "unittest", "discover", "-s", str(HELPERS), "-p", "test_*.py", "-v"], 180),
        (
            "machine",
            [
                sys.executable,
                str(HELPERS / "machine_manifest.py"),
                "--output-dir",
                str(output / "setup/machine"),
                "--concurrency-policy",
                "Sequential diagnostic; background host activity uncontrolled",
                "--cache-policy",
                config["cache_policy"],
                "--runner-regime",
                config["runner_regime"],
                "--collect-toolchain",
            ],
            120,
        ),
        (
            "calibration",
            [
                sys.executable,
                str(HELPERS / "calibrate_observer.py"),
                "--output-dir",
                str(output / "runs/calibration"),
                "--pairs",
                str(config["pairs_per_workload_mode"]),
                "--seed",
                str(config["randomization_seed"]),
                "--bootstrap-seed",
                str(config["bootstrap_seed"]),
                "--interval",
                str(config["sample_interval_seconds"]),
            ],
            180,
        ),
    ]
    result = dict(status="running", **config, phases={}, helper_hashes=hashes)
    save(output / "results.json", result)
    for name, argv, timeout in phases:
        if helper_hashes() != hashes:
            result.update(status="failed", failed_phase=name, failure="helper-input-changed-before-phase")
            break
        if name == "install":
            before = interpreter_observation(argv[0])
            result["install_interpreter"] = dict(
                schema_version=1,
                before=before,
                after=dict(status="unavailable", failure="install-not-started"),
                status=before["status"] if before["status"] != "available" else "pending",
                cost_accounting="Capture costs are nested in diagnostic wall, outside command-only install wall",
                scope="Prospective selected interpreter identity only; no dynamic-loader or wheel equivalence proof",
            )
            save(output / "setup/install-interpreter.json", result["install_interpreter"])
            if before["status"] != "available":
                result.update(
                    status="failed", failed_phase="install-interpreter", failure="interpreter-precheck-failed"
                )
                break
        row = command(argv, ROOT, output / "setup" / name, environment, timeout)
        result["phases"][name] = row
        if name == "install":
            binding = result["install_interpreter"]
            if row["completed"]:
                binding["after"] = interpreter_observation(argv[0])
                binding["status"] = (
                    "matched"
                    if same_interpreter(binding["before"], binding["after"])
                    else ("changed" if binding["after"]["status"] == "available" else binding["after"]["status"])
                )
            else:
                binding.update(status="incomplete", after=dict(status="unavailable", failure="install-incomplete"))
            save(output / "setup/install-interpreter.json", binding)
            if binding["status"] != "matched":
                result.update(
                    status="failed",
                    failed_phase="install-interpreter" if row["passed"] else "install",
                    failure="interpreter-postcheck-failed" if row["passed"] else "phase-failed",
                )
                break
        if name == "install" and ((output / "private-setup/install-report.json").exists() or row["passed"]):
            projection_started = time.perf_counter()
            try:
                result["install_provenance"] = install_provenance(output)
            except (ValueError, OSError):
                result.update(status="failed", failed_phase="install-provenance", failure="package-provenance-refused")
                break
            finally:
                result["install_provenance_wall_seconds"] = time.perf_counter() - projection_started
        if not row["passed"] or helper_hashes() != hashes:
            result.update(
                status="failed",
                failed_phase=name,
                failure="phase-failed" if not row["passed"] else "helper-input-changed-after-phase",
            )
            break
    else:
        if calibration_passed(output, config):
            result["status"] = "completed-synthetic-native-validation"
        else:
            result.update(status="failed", failed_phase="calibration", failure="calibration-oracle-failed")
    result["diagnostic_wall_seconds"] = time.perf_counter() - started
    save(output / "results.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dependencies", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = validate(args.output, args.dependencies)
    except (ValueError, OSError) as error:
        print(f"Diagnostic setup refused: {type(error).__name__}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {"status": result["status"], "failed_phase": result.get("failed_phase"), "final_comparison": False},
            sort_keys=True,
        )
    )
    if result["status"] == "completed-synthetic-native-validation":
        return 0
    incomplete = any(not r["completed"] for r in result["phases"].values()) or (
        result.get("install_interpreter", {}).get("status") == "incomplete"
    )
    return 125 if incomplete else 1


if __name__ == "__main__":
    raise SystemExit(main())
