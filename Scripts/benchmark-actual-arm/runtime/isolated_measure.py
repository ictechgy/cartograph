"""동결한 측정자의 worker 계약만 격리된 bootstrap으로 실행하는 검증 어댑터."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import runtime_bootstrap as BOOTSTRAP
import startup_binding as STARTUP

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "vendor/process_tree_measure.py"
HELPER_SHA256 = "03a6cc72657a560e983b95fa99b7df4ff907a6d41f37fcd3692f6ed694d92101"


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


def run(command, cwd, stem, runtime_path, runtime_sha256, environment, observer_environment, timeout=300):
    """원래 측정 바이트/구간은 유지하고 바깥 launch 비용과 실패를 별도로 기록한다."""
    if hashlib.sha256(HELPER.read_bytes()).hexdigest() != HELPER_SHA256:
        raise ValueError("Frozen measurement helper changed")
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
        mode="timing",
        environment=environment,
    )
    save(
        str(stem) + ".command.json",
        dict(
            command=command,
            cwd=config["cwd"],
            timeout_seconds=timeout,
            interval_seconds=0.01,
            measurement_mode="timing",
        ),
    )
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
        mode="timing",
        periodic_sampling=False,
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
        measured = json.loads(Path(str(stem) + ".json").read_text())
        result["measurement"] = measured
        if (
            measured.get("helper_sha256") != HELPER_SHA256
            or measured.get("measurement_mode") != "timing"
            or measured.get("sampling_during_timing") is not False
        ):
            raise ValueError("Frozen helper result binding mismatch")
        code = measured["root_returncode"]
        result["workload_returncode"] = code
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
