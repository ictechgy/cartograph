#!/usr/bin/env python3
"""격리된 Python에서 봉인한 설치/스크립트만 가져오고 모든 정상 종료 결과를 남긴다."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.machinery
import json
import os
from pathlib import Path
import runpy
import re
import stat
import sys
import time
import types
import traceback

LIMIT = 4 * 1024**2


def read_regular(path: Path) -> bytes:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > LIMIT:
        raise ValueError("Invalid bounded bootstrap input")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identity(os.fstat(fd)) != identity(before):
            raise ValueError("Bootstrap input changed")
        parts = []
        total = 0
        while chunk := os.read(fd, min(1024**2, LIMIT + 1 - total)):
            total += len(chunk)
            if total > LIMIT:
                raise ValueError("Bootstrap input exceeds limit")
            parts.append(chunk)
        if (
            total != before.st_size
            or identity(os.fstat(fd)) != identity(before)
            or identity(path.lstat()) != identity(before)
        ):
            raise ValueError("Bootstrap input changed")
        return b"".join(parts)
    finally:
        os.close(fd)


def strict_json(data):
    def pairs(rows):
        value = {}
        for key, item in rows:
            if key in value:
                raise ValueError("Duplicate bootstrap field")
            value[key] = item
        return value

    return json.loads(
        data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite value"))
    )


def boundary(report: Path, config_path: Path, config: dict):
    candidates = [
        config_path,
        Path(config["package"]["target"]),
        *[Path(p) for p in config["code_files"]],
        Path(config["python"]["path"]),
    ]
    destination = report.resolve().parent
    for path in candidates:
        target = path.resolve()
        if destination.is_relative_to(target) or target.is_relative_to(destination):
            raise ValueError("Runtime evidence overlaps inputs")
    if report.exists() or report.is_symlink():
        raise ValueError("Preserve prior runtime receipt")


def execute(args):
    started = time.perf_counter()
    record = dict(
        schema_version=1,
        status="failed",
        workload_started=False,
        observed_exit_code=None,
        exit_code=1,
        final_evidence=False,
        package_after=dict(status="not-run"),
        modules_after=dict(status="not-run"),
        code_after=dict(status="not-run"),
    )
    ready = False
    code = 1
    runtime = None
    config = None
    startup = None
    launch_request = None
    try:
        if not (sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode):
            raise ValueError("Python must start with -I -S -B")
        data = read_regular(args.runtime)
        if hashlib.sha256(data).hexdigest() != args.runtime_sha256:
            raise ValueError("Runtime receipt changed")
        config = strict_json(data)
        if (
            not isinstance(config, dict)
            or set(config)
            != (
                {"schema_version", "package", "python", "code_files"}
                | ({"startup_profile"} if config.get("schema_version") == 2 else set())
            )
            or type(config["schema_version"]) is not int
            or config["schema_version"] not in (1, 2)
            or not isinstance(config["code_files"], dict)
            or not 1 <= len(config["code_files"]) <= 64
        ):
            raise ValueError("Invalid runtime receipt schema")
        python_binding = config["python"]
        if (
            not isinstance(python_binding, dict)
            or set(python_binding) != {"path", "sha256", "bytes"}
            or not isinstance(python_binding["path"], str)
            or not Path(python_binding["path"]).is_absolute()
            or ".." in Path(python_binding["path"]).parts
            or not isinstance(python_binding["sha256"], str)
            or not re.fullmatch(r"[a-f0-9]{64}", python_binding["sha256"])
            or type(python_binding["bytes"]) is not int
            or not 0 < python_binding["bytes"] <= 256 * 1024**2
        ):
            raise ValueError("Invalid exact interpreter binding")
        for path, digest in config["code_files"].items():
            if (
                not isinstance(path, str)
                or not Path(path).is_absolute()
                or Path(path).resolve() != Path(path)
                or not isinstance(digest, str)
                or not re.fullmatch(r"[a-f0-9]{64}", digest)
            ):
                raise ValueError("Invalid exact code binding")
        boundary(args.report, args.runtime, config)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        ready = True
        record["runtime_receipt_sha256"] = args.runtime_sha256
        code_files = config["code_files"]
        record["selected_code_files"] = code_files
        source_bytes = {}
        for path, expected in code_files.items():
            if not isinstance(expected, str) or len(expected) != 64:
                raise ValueError("Invalid script digest")
            source_bytes[path] = read_regular(Path(path))
            if hashlib.sha256(source_bytes[path]).hexdigest() != expected:
                raise ValueError("Selected script changed")
        here = Path(__file__).resolve()
        helper = here.with_name("runtime_identity.py")
        if (
            str(here.parent / "vendor/sdk_content_seal.py") not in code_files
            or str(here) not in code_files
            or str(helper) not in code_files
            or str(args.script.resolve()) not in code_files
        ):
            raise ValueError("Unbound bootstrap or workload script")
        runtime = types.ModuleType("runtime_identity")
        runtime.__file__ = str(helper)
        sys.modules["runtime_identity"] = runtime
        exec(compile(source_bytes[str(helper)], str(helper), "exec"), runtime.__dict__)
        python = runtime.file_identity(Path(sys.executable))
        if Path(config["python"]["path"]).resolve() != Path(sys.executable).resolve() or any(
            python[k] != config["python"][k] for k in ["sha256", "bytes"]
        ):
            raise ValueError("Interpreter binding changed")
        if config["schema_version"] == 2:
            for name in ["startup_profile", "startup_binding"]:
                path = here.with_name(name + ".py")
                if str(path) not in source_bytes:
                    raise ValueError("Unbound startup profile helper")
                module = types.ModuleType(name)
                module.__file__ = str(path)
                sys.modules[name] = module
                exec(compile(source_bytes[str(path)], str(path), "exec"), module.__dict__)
            startup = sys.modules["startup_binding"]
            launch_request, launch_sha = startup.read_launch(
                config, args.runtime_sha256, args.script.resolve(), args.arguments, args.report
            )
            record["environment_request_sha256"] = launch_sha
            record["environment_before"] = startup.observe(config, launch_request, dict(os.environ))
        target = Path(config["package"]["target"])
        record["python"] = dict(
            path=sys.executable, version=sys.version, implementation=sys.implementation.name, **python
        )
        record["package_before"] = runtime.verify_package(target, config["package"])
        pycache = args.report.parent / "bytecode-cache"
        pycache.mkdir(exist_ok=False)
        sys.pycache_prefix = str(pycache)
        sys.path.insert(0, str(target.resolve()))
        package = importlib.import_module("psutil")
        if (
            package.__version__ != "7.2.2"
            or Path(package.__file__).resolve() != target.resolve() / "psutil/__init__.py"
        ):
            raise ValueError("Imported package origin differs")
        extensions = [
            m
            for n, m in sys.modules.items()
            if n.startswith("psutil.")
            and any(str(getattr(m, "__file__", "")).endswith(s) for s in importlib.machinery.EXTENSION_SUFFIXES)
        ]
        if not extensions or any(not Path(m.__file__).resolve().is_relative_to(target.resolve()) for m in extensions):
            raise ValueError("Imported package extension is unbound")
        record["modules_before"] = runtime.module_snapshot(dict(sys.modules), target, code_files, pycache)
        record["entrypoint"] = dict(path=str(args.script.resolve()), sha256=code_files[str(args.script.resolve())])
        record["arguments_sha256"] = hashlib.sha256(
            json.dumps(args.arguments, separators=(",", ":")).encode()
        ).hexdigest()
        record["workload_started"] = True
        previous = sys.argv
        sys.argv = [str(args.script), *args.arguments]
        try:
            runpy.run_path(str(args.script), run_name="__main__")
            code = 0
            record["exit_code_origin"] = "completed-workload-return"
        except SystemExit as error:
            record["exit_code_origin"] = "workload-system-exit"
            if error.code is None:
                code = 0
            elif isinstance(error.code, int):
                record["system_exit_integer"] = int(error.code)
                code = int(error.code) & 255
            else:
                code = 1
                message = str(error.code)
                record["system_exit_message_sha256"] = hashlib.sha256(message.encode()).hexdigest()
                print(message, file=sys.stderr)
        except Exception as error:
            code = 1
            record["exit_code_origin"] = "mapped-unhandled-python-exception"
            original_trace = traceback.format_exc()
            record["workload_exception"] = dict(
                type=type(error).__name__, traceback_sha256=hashlib.sha256(original_trace.encode()).hexdigest()
            )
            print(original_trace, end="", file=sys.stderr)
        finally:
            sys.argv = previous
        record["observed_exit_code"] = code
        if code == 125:
            record.update(
                status="incomplete",
                package_after=dict(status="unavailable", reason="incomplete-workload"),
                modules_after=dict(status="unavailable", reason="incomplete-workload"),
                code_after=dict(status="unavailable", reason="incomplete-workload"),
            )
        else:
            record["code_after"] = dict(status="checking")
            for path, expected in code_files.items():
                if hashlib.sha256(read_regular(Path(path))).hexdigest() != expected:
                    raise ValueError("Selected script changed during execution")
            if runtime.file_identity(Path(sys.executable)) != python:
                raise ValueError("Interpreter changed during execution")
            record["code_after"] = dict(status="passed", files=len(code_files), interpreter_unchanged=True)
            record["package_after"] = runtime.verify_package(target, config["package"])
            record["modules_after"] = runtime.module_snapshot(dict(sys.modules), target, code_files, pycache)
            if any(pycache.iterdir()):
                raise ValueError("Private bytecode cache was modified")
            if startup is not None:
                current, digest = startup.read_launch(
                    config, args.runtime_sha256, args.script.resolve(), args.arguments, args.report
                )
                if digest != record["environment_request_sha256"]:
                    raise ValueError("Runtime environment request changed")
                record["environment_after"] = startup.observe(config, current, dict(os.environ))
            record["status"] = "passed" if code == 0 else "failed"
    except KeyboardInterrupt:
        code = 125
        record.update(
            status="incomplete",
            failure_category="interrupt",
            package_after=dict(status="unavailable", reason="incomplete-workload"),
            modules_after=dict(status="unavailable", reason="incomplete-workload"),
            code_after=dict(status="unavailable", reason="incomplete-workload"),
        )
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, ImportError) as error:
        code = 1
        record.update(
            status="failed",
            failure_type=type(error).__name__,
            failure_category="runtime-binding-failed",
            failure_reason=str(error),
        )
    record.update(
        exit_code=code,
        wall_seconds_before_receipt=time.perf_counter() - started,
        scope="Validation-only runtime binding; complete loader/stdlib/SDK closure and detached containment unproved",
    )
    if ready:
        with args.report.open("x") as stream:
            json.dump(record, stream, sort_keys=True, indent=2, allow_nan=False)
            stream.write("\n")
    else:
        print(
            json.dumps(
                {
                    "status": "refused-before-runtime-record",
                    "exit_code": code,
                    "wall_seconds": record["wall_seconds_before_receipt"],
                }
            ),
            file=sys.stderr,
        )
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--runtime-sha256", required=True)
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.arguments[:1] == ["--"]:
        args.arguments = args.arguments[1:]
    raise SystemExit(execute(args))


if __name__ == "__main__":
    main()
