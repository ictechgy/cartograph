"""동결한 측정자의 worker 계약만 격리된 bootstrap으로 실행하는 검증 어댑터."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import stat
import statistics
import subprocess
import sys
import time
import threading
from types import SimpleNamespace

import runtime_bootstrap as BOOTSTRAP
import startup_binding as STARTUP

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "vendor/process_tree_measure.py"
HELPER_SHA256 = "03a6cc72657a560e983b95fa99b7df4ff907a6d41f37fcd3692f6ed694d92101"
SPEC = importlib.util.spec_from_file_location("isolated_measure_normalizer", ROOT / "vendor/normalize_evidence.py")
NORMALIZE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NORMALIZE)
SAMPLE_CHUNK_LIMIT = 6 * 1024**2


def save(path, value):
    with Path(path).open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write("\n")


def bootstrap_command(runtime_path, runtime_sha256, script, report, arguments=(), *, runtime=None):
    return [
        STARTUP.launch_interpreter(runtime) if runtime and runtime.get("schema_version") == 3 else sys.executable,
        "-I",
        "-S",
        "-B",
        str(ROOT / "runtime_bootstrap.py"),
        "--runtime",
        str(runtime_path),
        "--runtime-sha256",
        runtime_sha256,
        "--script",
        str(script),
        "--report",
        str(report),
        "--",
        *arguments,
    ]


def checked_environment(value, config, runtime_path):
    fixed = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    private = {"HOME": "home", "TMPDIR": "tmp", "XDG_CACHE_HOME": "cache"}
    required = set(fixed) | set(private)
    if (
        not isinstance(value, dict)
        or not required <= set(value)
        or set(value) - required - {"DEVELOPER_DIR"}
        or any(value[key] != expected for key, expected in fixed.items())
        or any(not isinstance(item, str) or "\0" in item for item in value.values())
    ):
        raise ValueError("Unaccepted runtime environment")
    roots = []
    for key, name in private.items():
        path = Path(value[key])
        if (
            not path.is_absolute()
            or path.name != name
            or path.resolve() != path
            or not path.is_dir()
            or any(path.iterdir())
        ):
            raise ValueError("Runtime private directory is not fresh")
        BOOTSTRAP.boundary(path / "unused-boundary-receipt.json", runtime_path, config)
        roots.append(path.parent)
    if len(set(roots)) != 1:
        raise ValueError("Runtime private directory family differs")
    if "DEVELOPER_DIR" in value:
        developer = Path(value["DEVELOPER_DIR"])
        if not developer.is_absolute() or not developer.is_dir():
            raise ValueError("Unaccepted developer directory")
    return roots[0]


def engine_request(command, runtime_path, runtime_sha256, config):
    if len(command) < 14 or len(command) > 1024 or sum(len(v) for v in command) > 1024**2:
        raise ValueError("Engine must use bounded explicit bootstrap command")
    script, report = Path(command[10]), Path(command[12])
    arguments = command[14:]
    if (
        not script.is_absolute()
        or str(script.resolve()) != str(script)
        or str(script) not in config["code_files"]
        or not report.is_absolute()
        or str(report.resolve()) != str(report)
        or command != bootstrap_command(runtime_path, runtime_sha256, script, report, arguments, runtime=config)
    ):
        raise ValueError("Engine command bypasses selected runtime bootstrap")
    BOOTSTRAP.boundary(report, runtime_path, config)
    return script, report, arguments


def verify_import_guard(receipt, config, phase):
    package = receipt.get("package_" + phase, {})
    expected = config["package"]["content"]["content_sha256"]
    if (
        package.get("matches") is not True
        or package.get("expected_sha256") != expected
        or package.get("actual_sha256") != expected
        or package.get("actual", {}).get("content_sha256") != expected
    ):
        raise ValueError("Runtime package receipt differs from selected bytes")
    snapshot = receipt.get("modules_" + phase, {})
    modules = snapshot.get("modules")
    if not isinstance(modules, dict):
        raise ValueError("Runtime module receipt is missing")
    digest = hashlib.sha256(
        json.dumps(modules, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    ).hexdigest()
    expected_path = str(Path(config["package"]["target"]) / "psutil/__init__.py")
    if (
        digest != snapshot.get("sha256")
        or modules.get("psutil", {}).get("path") != expected_path
        or modules.get("psutil", {}).get("kind") != "private-package"
    ):
        raise ValueError("Runtime module receipt content or package origin differs")


def verify_runtime_receipt(path, config, runtime_sha256, script, arguments, code, expected_environment=None):
    receipt = BOOTSTRAP.strict_json(BOOTSTRAP.read_regular(path))
    if not isinstance(receipt, dict):
        raise ValueError("Runtime receipt is not an object")
    expected_arguments = hashlib.sha256(json.dumps(arguments, separators=(",", ":")).encode()).hexdigest()
    if (
        receipt.get("runtime_receipt_sha256") != runtime_sha256
        or receipt.get("entrypoint") != {"path": str(script), "sha256": config["code_files"][str(script)]}
        or receipt.get("selected_code_files") != config["code_files"]
        or receipt.get("arguments_sha256") != expected_arguments
        or type(receipt.get("exit_code")) is not int
        or receipt["exit_code"] != code
        or type(receipt.get("observed_exit_code")) is not int
        or receipt["observed_exit_code"] != code
        or receipt.get("workload_started") is not True
    ):
        raise ValueError("Runtime receipt contradicts selected engine request or observed return")
    python = receipt.get("python", {})
    if (
        python.get("sha256") != config["python"]["sha256"]
        or python.get("bytes") != config["python"]["bytes"]
        or not isinstance(python.get("path"), str)
        or Path(python["path"]).resolve() != Path(config["python"]["path"]).resolve()
    ):
        raise ValueError("Runtime interpreter receipt differs")
    verify_import_guard(receipt, config, "before")
    if code == 125:
        if receipt.get("status") != "incomplete":
            raise ValueError("Reserved125 runtime receipt is not incomplete")
    else:
        if (
            receipt.get("status") != ("passed" if code == 0 else "failed")
            or receipt.get("code_after", {}).get("status") != "passed"
            or receipt.get("package_after", {}).get("matches") is not True
            or not isinstance(receipt.get("modules_after", {}).get("modules"), dict)
        ):
            raise ValueError("Runtime receipt lacks completed terminal guards")
        verify_import_guard(receipt, config, "after")
    STARTUP.verify_receipt(receipt, config, runtime_sha256, script, arguments, path, code, expected_environment)
    return receipt


def bind_launch(command, runtime_path, runtime_sha256, config, environment):
    if type(config.get("schema_version")) is int and config["schema_version"] == 1:
        return None
    script, report, arguments = engine_request(command, runtime_path, runtime_sha256, config)
    return STARTUP.write_launch(
        config,
        runtime_sha256,
        script,
        arguments,
        environment,
        report,
        lambda: BOOTSTRAP.boundary(report, runtime_path, config),
    )


def read_sample_chunk(path):
    """봉인 입력의 크기 제한은 바꾸지 않고 회전 표본만 별도 한도로 읽는다."""
    before = path.lstat()
    identity = lambda row: (row.st_dev, row.st_ino, row.st_mode, row.st_size, row.st_mtime_ns, row.st_ctime_ns)
    if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= SAMPLE_CHUNK_LIMIT:
        raise ValueError("Invalid bounded sample chunk")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if identity(os.fstat(fd)) != identity(before):
            raise ValueError("Sample chunk changed before read")
        parts, total = [], 0
        while data := os.read(fd, min(65536, SAMPLE_CHUNK_LIMIT + 1 - total)):
            parts.append(data)
            total += len(data)
            if total > SAMPLE_CHUNK_LIMIT:
                raise ValueError("Sample chunk exceeds limit")
        if total != before.st_size or any(
            identity(row) != identity(before) for row in (os.fstat(fd), path.lstat())
        ):
            raise ValueError("Sample chunk changed during read")
        return b"".join(parts)
    finally:
        os.close(fd)


def verify_memory(stem, measured):
    """모든 회전 파일과 표본을 검증하고 요약 수치가 원문에서 다시 계산되는지 확인한다."""
    rss = measured.get("rss")
    if (
        not isinstance(rss, dict)
        or measured.get("primary_timing_eligible") is not False
        or rss.get("read_errors") != []
        or type(rss.get("sample_chunk_limit_bytes")) is not int
        or rss["sample_chunk_limit_bytes"] != SAMPLE_CHUNK_LIMIT
        or not isinstance(rss.get("sample_chunks"), list)
        or len(rss["sample_chunks"]) > NORMALIZE.MAX_FILES - 1
    ):
        raise ValueError("Memory observation is incomplete or malformed")
    chunks = rss["sample_chunks"]
    paths, contents = [], []
    for number, chunk in enumerate(chunks, 1):
        if (
            not isinstance(chunk, dict)
            or set(chunk) != {"name", "sha256", "bytes", "sample_count"}
            or chunk["name"] != stem.name + f".samples.{number:04d}.jsonl"
        ):
            raise ValueError("Memory chunk sequence differs")
        path = stem.parent / chunk["name"]
        data = read_sample_chunk(path)
        if (
            not data.endswith(b"\n") or chunk["sha256"] != hashlib.sha256(data).hexdigest()
            or type(chunk["bytes"]) is not int or chunk["bytes"] != len(data)
            or type(chunk["sample_count"]) is not int or chunk["sample_count"] != len(data.splitlines())
        ):
            raise ValueError("Memory sample chunk integrity differs")
        paths.append(path)
        contents.append(data)
        if sum(map(len, contents)) > NORMALIZE.MAX_TOTAL_BYTES:
            raise ValueError("Memory samples exceed bounded evidence size")
    result_path = Path(str(stem) + ".json")
    if BOOTSTRAP.strict_json(BOOTSTRAP.read_regular(result_path)) != measured:
        raise ValueError("Memory result changed before sample verification")
    selected = [result_path, *paths]
    verified = NORMALIZE.verify_sample_chunks(stem.parent, selected)
    normalizer = NORMALIZE.Normalizer(
        SimpleNamespace(input=stem.parent, output=stem.parent / "unused-public", prefix=[]),
        stem.parent, selected, verified,
    )
    samples, identities = [], set()
    for path, data in zip(paths, contents):
        for line in data.splitlines():
            sample = BOOTSTRAP.strict_json(line)
            if not isinstance(sample, dict):
                raise ValueError("Memory sample is not an object")
            normalizer.helper_sample(sample, path.name)
            if sample["end_seconds"] > measured["wall_seconds"]:
                raise ValueError("Memory sample extends beyond enclosing measured wall")
            if samples and sample["start_seconds"] < samples[-1]["end_seconds"]:
                raise ValueError("Memory sample order differs")
            samples.append(sample)
            identities.update(member["process_id"] for member in sample["processes"])
        if data != read_sample_chunk(path):
            raise ValueError("Memory chunk changed during verification")
    gaps = [b["start_seconds"] - a["start_seconds"] for a, b in zip(samples, samples[1:])]
    integers = dict(
        sample_count=len(samples), sample_total_bytes=sum(map(len, contents)),
        observed_peak_bytes=max((sample["rss_bytes"] for sample in samples), default=0),
    )
    numbers = dict(
        requested_interval_seconds=0.01,
        actual_interval_median_seconds=statistics.median(gaps) if gaps else None,
        actual_interval_max_seconds=max(gaps) if gaps else None,
        sweep_max_seconds=max((s["end_seconds"] - s["start_seconds"] for s in samples), default=0),
    )
    if (
        any(type(rss.get(key)) is not int or rss[key] != value for key, value in integers.items())
        or type(rss.get("observed_process_count")) is not int
        or rss["observed_process_count"] < len(identities)
        or any(
            rss.get(key) is not None if value is None else (
                type(rss.get(key)) not in (int, float) or not math.isfinite(rss[key]) or rss[key] != value
            )
            for key, value in numbers.items()
        )
        or measured.get("status") == "ok" and (not samples or not identities)
    ):
        raise ValueError("Memory summary differs from complete strict samples")
    if BOOTSTRAP.strict_json(BOOTSTRAP.read_regular(result_path)) != measured:
        raise ValueError("Memory result changed during sample verification")


def verify_intervals(measured, mode):
    """요약 구간을 줄여 표본이나 종료 관측보다 빠른 완료로 채점하지 못하게 한다."""
    wall = measured.get("wall_seconds")
    completed = measured.get("status") == "ok"
    if type(wall) not in (int, float) or not math.isfinite(wall) or wall < 0 or completed and wall == 0:
        raise ValueError("Invalid measured wall interval")
    root_exit = measured.get("root_exit_observed_seconds")
    if completed or root_exit is not None:
        if (
            type(root_exit) not in (int, float) or not math.isfinite(root_exit)
            or root_exit < 0 or root_exit > wall or completed and root_exit == 0
        ):
            raise ValueError("Root exit observation is outside measured wall")
    if mode == "timing":
        supervision = measured.get("supervision_total_seconds")
        if completed or supervision is not None:
            if (
                type(supervision) not in (int, float) or not math.isfinite(supervision)
                or supervision < wall
            ):
                raise ValueError("Timing supervision does not enclose measured wall")
        if root_exit is not None and root_exit != wall:
            raise ValueError("Timing wall differs from blocking root exit interval")


def verify_measurement(stem, measured, mode, expected_command):
    """호출 모드·명령 영수증·원문 결과를 묶어 다른 실행의 결과가 채택되지 않게 한다."""
    if (
        not isinstance(measured, dict)
        or mode not in ("timing", "memory") or expected_command.get("measurement_mode") != mode
        or measured.get("helper_sha256") != HELPER_SHA256
        or type(measured.get("schema_version")) is not int or measured["schema_version"] != 2
        or measured.get("measurement_mode") != mode
        or type(measured.get("timed_out")) is not bool
        or measured.get("status") not in ("ok", "failed")
        or measured.get("status") != ("ok" if measured.get("failure") is None else "failed")
        or measured.get("status") == "ok" and (
            measured.get("failure") is not None or type(measured.get("root_returncode")) is not int
            or measured["root_returncode"] != 0 or measured["timed_out"]
            or type(measured.get("returncode")) is not int or measured["returncode"] != 0
        )
        or mode == "timing" and measured.get("sampling_during_timing") is not False
    ):
        raise ValueError("Frozen helper result binding mismatch")
    verify_intervals(measured, mode)
    if measured["status"] == "ok":
        timeout = expected_command.get("timeout_seconds")
        if (
            type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 300
            or measured["wall_seconds"] > timeout
        ):
            raise ValueError("Successful measured wall exceeds declared deadline")
    command_path = Path(str(stem) + ".command.json")
    command_data = BOOTSTRAP.read_regular(command_path)
    if json.dumps(BOOTSTRAP.strict_json(command_data), sort_keys=True) != json.dumps(expected_command, sort_keys=True):
        raise ValueError("Measurement command receipt changed")
    artifacts = measured.get("artifacts")
    if not isinstance(artifacts, dict):
        raise ValueError("Measurement artifacts are not an object")
    artifact = artifacts.get("command", {})
    if artifact != dict(name=command_path.name, sha256=hashlib.sha256(command_data).hexdigest()):
        raise ValueError("Measurement command artifact differs")
    if mode == "memory":
        verify_memory(stem, measured)


def run(command, cwd, stem, runtime_path, runtime_sha256, environment, observer_environment,
        timeout=300, *, mode="timing"):
    """원래 측정 바이트/구간은 유지하고 바깥 launch 비용과 실패를 별도로 기록한다."""
    if hashlib.sha256(HELPER.read_bytes()).hexdigest() != HELPER_SHA256:
        raise ValueError("Frozen measurement helper changed")
    if type(mode) is not str or mode not in ("timing", "memory"):
        raise ValueError("Measurement mode must be exactly timing or memory")
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 300:
        raise ValueError("Invalid bounded diagnostic timeout")
    if not command or not all(isinstance(v, str) for v in command):
        raise ValueError("Invalid workload command")
    runtime_path = Path(runtime_path)
    data = BOOTSTRAP.read_regular(runtime_path)
    if hashlib.sha256(data).hexdigest() != runtime_sha256:
        raise ValueError("Runtime receipt changed before observer launch")
    config_binding = BOOTSTRAP.strict_json(data)
    engine_script, engine_report, engine_arguments = engine_request(
        command, runtime_path, runtime_sha256, config_binding
    )
    stem = Path(stem).resolve()
    observer_directory = stem.parent / "observer-runtime"
    if engine_report.parent.is_relative_to(observer_directory) or observer_directory.is_relative_to(
        engine_report.parent
    ):
        raise ValueError("Observer and engine runtime report directories overlap")
    BOOTSTRAP.boundary(Path(str(stem) + ".observer.json"), runtime_path, config_binding)
    engine_private = checked_environment(environment, config_binding, runtime_path)
    observer_private = checked_environment(observer_environment, config_binding, runtime_path)
    if (
        engine_private == observer_private
        or engine_private.is_relative_to(observer_private)
        or observer_private.is_relative_to(engine_private)
    ):
        raise ValueError("Observer and engine private state overlap")
    stem.parent.mkdir(parents=True, exist_ok=True)
    if list(stem.parent.glob(stem.name + ".samples*.jsonl")):
        raise ValueError("Preserve previous sample evidence")
    for suffix in [
        ".json",
        ".stdout",
        ".stderr",
        ".command.json",
        ".observer.json",
        ".observer.stdout",
        ".observer.stderr",
    ]:
        if Path(str(stem) + suffix).exists() or Path(str(stem) + suffix).is_symlink():
            raise ValueError("Preserve previous measurement evidence")
    runtime_report = stem.parent / "observer-runtime/runtime-result.json"
    argv = bootstrap_command(runtime_path, runtime_sha256, HELPER, runtime_report, ["--worker"], runtime=config_binding)
    config = dict(
        command=command,
        cwd=str(Path(cwd).resolve()),
        stem=str(stem),
        timeout=timeout,
        interval=0.01,
        grace=0.25,
        mode=mode,
        environment=environment,
    )
    command_receipt = dict(
        command=command,
        cwd=config["cwd"],
        timeout_seconds=timeout,
        interval_seconds=0.01,
        measurement_mode=mode,
    )
    save(str(stem) + ".command.json", command_receipt)
    bind_launch(command, runtime_path, runtime_sha256, config_binding, environment)
    bind_launch(argv, runtime_path, runtime_sha256, config_binding, observer_environment)
    result = dict(
        command=list(argv),
        status="incomplete",
        exit_code=125,
        observed_helper_returncode=None,
        measurement=None,
        engine_runtime=None,
        final_evidence=False,
        mode=mode,
        periodic_sampling=mode == "memory",
        cleanup_signals=[],
    )
    started = time.perf_counter()
    process = None
    try:
        with Path(str(stem) + ".observer.stdout").open("xb") as out, Path(str(stem) + ".observer.stderr").open(
            "xb"
        ) as err:
            process = subprocess.Popen(
                argv, stdin=subprocess.PIPE, stdout=out, stderr=err, env=observer_environment, start_new_session=True
            )
            try:
                process.communicate(json.dumps(config).encode(), timeout=timeout + 15)
            except subprocess.TimeoutExpired:
                result["failure"] = "observer-timeout"
                raise
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                        result["cleanup_signals"].append("term-sent")
                    except ProcessLookupError:
                        result["cleanup_signals"].append("term-target-already-exited")
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                            result["cleanup_signals"].append("kill-sent")
                        except ProcessLookupError:
                            result["cleanup_signals"].append("kill-target-already-exited")
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            result["cleanup_root_unfinished"] = True
        result["observed_helper_returncode"] = process.returncode
        if process.returncode != 0 or not runtime_report.is_file():
            raise ValueError("Observer runtime did not complete")
        runtime = verify_runtime_receipt(
            runtime_report, config_binding, runtime_sha256, HELPER, ["--worker"], 0, observer_environment
        )
        result["runtime"] = runtime
        measured = BOOTSTRAP.strict_json(BOOTSTRAP.read_regular(Path(str(stem) + ".json")))
        result["measurement"] = measured
        code = measured["root_returncode"]
        result["workload_returncode"] = code
        verify_measurement(stem, measured, mode, command_receipt)
        incomplete = (
            type(code) is not int or code < 0 or code == 125 or measured.get("failure") not in (None, "nonzero_exit")
        )
        if hashlib.sha256(BOOTSTRAP.read_regular(runtime_path)).hexdigest() != runtime_sha256:
            raise ValueError("Runtime input receipt changed during measurement")
        if type(code) is int and code >= 0 and measured.get("failure") in (None, "nonzero_exit"):
            result["engine_runtime"] = verify_runtime_receipt(
                engine_report, config_binding, runtime_sha256, engine_script, engine_arguments, code, environment
            )
        else:
            result["engine_runtime_unavailable_reason"] = "incomplete-process-outcome"
        result.update(
            status="incomplete" if incomplete else "passed" if measured["status"] == "ok" else "failed",
            exit_code=125 if incomplete else code,
        )
    except (
        OSError,
        ValueError,
        RuntimeError,
        KeyError,
        TypeError,
        KeyboardInterrupt,
        subprocess.TimeoutExpired,
    ) as error:
        result.setdefault("failure", type(error).__name__)
        result["failure_reason"] = str(error)
    finally:
        if process is not None:
            result["observed_helper_returncode"] = process.poll()
    result.update(
        observer_call_wall_seconds=time.perf_counter() - started,
        containment="Frozen observer plus process-group fallback; detached descendants not proved",
        environment_policy="Explicit caller-owned allowlist only; values are not serialized in this adapter",
    )
    save(str(stem) + ".observer.json", result)
    return result


def direct_cleanup_error(result, operation, error):
    """정리의 이차 오류는 원래 실패와 종료 코드를 덮지 않는 제한된 형식으로 남긴다."""
    errors = result["cleanup_errors"]
    if len(errors) < 12:
        errors.append(dict(operation=operation, type=type(error).__name__[:80]))


def record_direct_returncode(result, code):
    """wait와 poll의 관측은 같은 엄격한 정수 종료 코드에만 합쳐 기록한다."""
    if (
        type(code) is not int
        or result["workload_returncode"] is not None and code != result["workload_returncode"]
    ):
        raise ValueError("Cleanup return differs from original process observation")
    result["workload_returncode"] = code


def poll_direct(process, result, operation):
    """다시 관측할 수 없더라도 이미 확인한 원래 종료 코드는 보존한다."""
    try:
        code = process.poll()
        if code is not None:
            record_direct_returncode(result, code)
    except (Exception, KeyboardInterrupt) as error:
        direct_cleanup_error(result, operation, error)
        if result["workload_returncode"] is None and type(process.returncode) is int:
            result["workload_returncode"] = process.returncode
        return None
    return code


def cleanup_direct(process, result):
    """협조적인 프로세스 그룹만 정리하며 분리된 자식의 종료를 증명하지 않는다."""
    for sig, label, grace in [(signal.SIGTERM, "term", 2), (signal.SIGKILL, "kill", 5)]:
        try:
            os.killpg(process.pid, sig)
            result["cleanup_signals"].append(label + "-sent")
        except ProcessLookupError:
            result["cleanup_signals"].append(label + "-target-already-exited")
        except (Exception, KeyboardInterrupt) as error:
            result["cleanup_signals"].append(label + "-failed-" + type(error).__name__[:80])
            direct_cleanup_error(result, label + "-signal", error)
        try:
            record_direct_returncode(result, process.wait(timeout=grace))
            return
        except subprocess.TimeoutExpired:
            continue
        except (Exception, KeyboardInterrupt) as error:
            direct_cleanup_error(result, label + "-wait", error)
    result["cleanup_root_unfinished"] = True


def run_direct(command, cwd, stem, runtime_path, runtime_sha256, environment, timeout=240):
    """같은 bootstrap 명령의 blocking wait만 재고 승인·영수증 비용은 분리한다."""
    caller_started = time.perf_counter()
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 240:
        raise ValueError("Invalid bounded direct timeout")
    if not command or not all(isinstance(value, str) for value in command):
        raise ValueError("Invalid workload command")
    if threading.current_thread() is not threading.main_thread() or signal.getitimer(signal.ITIMER_REAL) != (0, 0):
        raise ValueError("Direct blocking launch needs the main thread and an unused POSIX deadline")
    runtime_path = Path(runtime_path)
    data = BOOTSTRAP.read_regular(runtime_path)
    if hashlib.sha256(data).hexdigest() != runtime_sha256:
        raise ValueError("Runtime receipt changed before direct launch")
    config = BOOTSTRAP.strict_json(data)
    script, report, arguments = engine_request(command, runtime_path, runtime_sha256, config)
    stem = Path(stem).resolve()
    BOOTSTRAP.boundary(Path(str(stem) + ".direct.json"), runtime_path, config)
    checked_environment(environment, config, runtime_path)
    for suffix in (".stdout", ".stderr", ".command.json", ".direct.json"):
        path = Path(str(stem) + suffix)
        if path.exists() or path.is_symlink():
            raise ValueError("Preserve previous direct evidence")
    stem.parent.mkdir(parents=True, exist_ok=True)
    command_receipt = dict(command=command, cwd=str(Path(cwd).resolve()), timeout_seconds=timeout, mode="direct")
    save(str(stem) + ".command.json", command_receipt)
    bind_launch(command, runtime_path, runtime_sha256, config, environment)
    result = dict(
        mode="direct", command=command, status="incomplete", exit_code=125, workload_returncode=None,
        engine_runtime=None, engine_wall_seconds=None, final_evidence=False, cleanup_signals=[], cleanup_errors=[],
        admission_wall_seconds=time.perf_counter() - caller_started, receipt_verification_wall_seconds=None,
        containment="Cooperative process-group cleanup only; detached descendants not proved",
        wait_method="blocking_Popen_wait_with_one_POSIX_ITIMER_REAL_deadline",
        environment_policy="Explicit caller-owned allowlist only; values are not serialized in this adapter",
    )
    process, engine_started, wait_finished = None, None, None
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGALRM, signal.SIGINT, signal.SIGTERM)}

    def deadline(signum, frame):
        result.setdefault("failure", "timeout")
        raise TimeoutError("Direct engine deadline reached")

    def cancel(signum, frame):
        result.setdefault("failure", "cancelled")
        result["cancel_signal"] = signum
        raise InterruptedError("Direct engine cancelled")

    try:
        signal.signal(signal.SIGALRM, deadline)
        signal.signal(signal.SIGINT, cancel)
        signal.signal(signal.SIGTERM, cancel)
        with Path(str(stem) + ".stdout").open("xb") as out, Path(str(stem) + ".stderr").open("xb") as err:
            engine_started = time.perf_counter()
            process = subprocess.Popen(
                command, cwd=command_receipt["cwd"], stdout=out, stderr=err, env=environment, start_new_session=True
            )
            signal.setitimer(signal.ITIMER_REAL, max(0.000001, timeout - (time.perf_counter() - engine_started)))
            try:
                process.wait()
                wait_finished = time.perf_counter()
            finally:
                try:
                    signal.setitimer(signal.ITIMER_REAL, 0)
                except (Exception, KeyboardInterrupt) as error:
                    direct_cleanup_error(result, "wait-deadline-disarm", error)
        result["workload_returncode"] = code = process.returncode
        elapsed = wait_finished - engine_started
        if type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0:
            result["engine_wall_seconds"] = elapsed
        if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or not 0 < elapsed <= timeout:
            raise ValueError("Direct engine wall is outside the positive bounded deadline")
        verification_started = time.perf_counter()
        try:
            if hashlib.sha256(BOOTSTRAP.read_regular(runtime_path)).hexdigest() != runtime_sha256:
                raise ValueError("Runtime input receipt changed during direct launch")
            if type(code) is int and code >= 0:
                result["engine_runtime"] = verify_runtime_receipt(
                    report, config, runtime_sha256, script, arguments, code, environment
                )
            else:
                raise ValueError("Direct engine outcome is incomplete")
            result.update(status="incomplete" if code == 125 else "passed" if code == 0 else "failed", exit_code=code)
        finally:
            result["receipt_verification_wall_seconds"] = time.perf_counter() - verification_started
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, KeyboardInterrupt, subprocess.TimeoutExpired) as error:
        result.setdefault("failure", type(error).__name__)
        result["failure_reason"] = str(error)
    finally:
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)
        except (Exception, KeyboardInterrupt) as error:
            direct_cleanup_error(result, "deadline-disarm", error)
        # 정리 도중 두 번째 취소도 원문 출력/종료 관측의 보존을 중단하지 않는다.
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(sig, lambda signum, frame: result.setdefault("cancel_signal", signum))
            except (Exception, KeyboardInterrupt) as error:
                direct_cleanup_error(result, "cancel-handler-install", error)
        try:
            if process is not None:
                if poll_direct(process, result, "poll-before-cleanup") is None or result.get("failure") is not None:
                    cleanup_direct(process, result)
                if poll_direct(process, result, "poll-after-cleanup") is None:
                    result["cleanup_root_unfinished"] = True
        finally:
            for sig, handler in previous.items():
                try:
                    signal.signal(sig, handler)
                except (Exception, KeyboardInterrupt) as error:
                    direct_cleanup_error(result, "signal-handler-restore", error)
    if result["cleanup_errors"] or result.get("cleanup_root_unfinished"):
        result.update(status="incomplete", exit_code=125)
        result.setdefault("failure", "cleanup-incomplete")
        result.setdefault("failure_reason", "Direct cleanup could not prove a completed terminal observation")
    result["direct_call_wall_seconds"] = time.perf_counter() - caller_started
    result["measurement"] = dict(
        measurement_mode="direct", wall_seconds=result["engine_wall_seconds"],
        root_returncode=result["workload_returncode"],
        status="ok" if result["status"] == "passed" else "failed",
        failure=result.get("failure") or ("nonzero_exit" if result["status"] == "failed" else None),
        timed_out=result.get("failure") == "timeout", primary_timing_eligible=False,
    )
    save(str(stem) + ".direct.json", result)
    return result
