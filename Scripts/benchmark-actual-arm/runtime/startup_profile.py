#!/usr/bin/env python3
"""발신 환경을 바꾸지 않고 요청에 묶인 Python 시작 환경 차이만 관측한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import importlib.machinery
import json
import math
import os
from pathlib import Path
import stat
import sys
import time

KEY = "__CF_USER_TEXT_ENCODING"
IDENTIFIER = "core-foundation-user-text-encoding"
MAX_VALUE_BYTES = 256
MAX_RECEIPT_BYTES = 64 * 1024
MAX_SOURCE_BYTES = 4 * 1024**2
MAX_EXECUTABLE_BYTES = 256 * 1024**2
FIXED = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C", TZ="UTC", PYTHONDONTWRITEBYTECODE="1")
PRIVATE = {"HOME", "TMPDIR", "XDG_CACHE_HOME"}
OPTIONAL = {"RUNNER_TEMP", "DEVELOPER_DIR"}


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def valid_sha(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def strict(data):
    def pairs(rows):
        result = {}
        for key, value in rows:
            require(key not in result, "duplicate-field")
            result[key] = value
        return result

    return json.loads(
        data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite"))
    )


def fingerprint(info):
    return [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def read_file(path, limit):
    path = Path(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_size <= limit, "input-not-bounded-regular-file")
        parts, size = [], 0
        while True:
            part = os.read(descriptor, min(1024**2, limit + 1 - size))
            if not part:
                break
            size += len(part)
            require(size <= limit, "input-byte-limit")
            parts.append(part)
        require(
            size == before.st_size
            and fingerprint(os.fstat(descriptor)) == fingerprint(before)
            and fingerprint(path.lstat()) == fingerprint(before),
            "input-changed",
        )
        return b"".join(parts), fingerprint(before)
    finally:
        os.close(descriptor)


def file_identity(path, limit=MAX_SOURCE_BYTES):
    data, metadata = read_file(path, limit)
    return dict(sha256=sha(data), bytes=len(data), metadata=metadata)


def interpreter(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "nonexplicit-interpreter")
    resolved = path.resolve(strict=True)
    identity = file_identity(resolved, MAX_EXECUTABLE_BYTES)
    require(path.resolve(strict=True) == resolved, "interpreter-alias-changed")
    return dict(selected_path=str(path), resolved_path=str(resolved), **identity)


def same_physical(left, right):
    return encoded({k: v for k, v in left.items() if k != "selected_path"}) == encoded(
        {k: v for k, v in right.items() if k != "selected_path"}
    )


def environment_request(environment):
    require(isinstance(environment, dict), "environment-not-object")
    keys = set(environment)
    require(set(FIXED) | PRIVATE <= keys and keys <= set(FIXED) | PRIVATE | OPTIONAL, "launch-key-inventory")
    require(all(environment[k] == v for k, v in FIXED.items()), "launch-fixed-value")
    require(
        all(isinstance(v, str) and "\0" not in v and len(v.encode()) <= 4096 for v in environment.values()),
        "launch-value-limit",
    )
    for key in PRIVATE | (keys & OPTIONAL):
        path = Path(environment[key])
        require(
            path.is_absolute() and ".." not in path.parts and path.is_dir() and path.resolve() == path,
            "launch-directory",
        )
    return dict(keys=sorted(environment), sha256=sha(encoded(environment)))


def validate_environment_request(expected):
    require(isinstance(expected, dict) and set(expected) == {"keys", "sha256"}, "environment-request-shape")
    keys = expected["keys"]
    require(
        isinstance(keys, list) and all(isinstance(k, str) for k in keys) and keys == sorted(set(keys)),
        "environment-request-keys",
    )
    require(
        set(FIXED) | PRIVATE <= set(keys) and set(keys) <= set(FIXED) | PRIVATE | OPTIONAL,
        "environment-request-inventory",
    )
    require(valid_sha(expected["sha256"]), "environment-request-digest")


def observe_request(expected, actual, *, platform=None):
    """직접 요청한 값은 완전 비교하고, Darwin의 한 관측 키만 해시로 따로 기록한다."""
    validate_environment_request(expected)
    platform = sys.platform if platform is None else platform
    require(isinstance(actual, dict), "observed-environment-shape")
    keys = set(actual)
    base = set(expected["keys"])
    require(base <= keys and keys - base <= {KEY}, "observed-key-inventory")
    require(all(isinstance(value, str) for value in actual.values()), "observed-value-type")
    selected = {key: actual[key] for key in expected["keys"]}
    require(all(len(value.encode()) <= 4096 for value in selected.values()), "observed-base-value-limit")
    require(sha(encoded(selected)) == expected["sha256"], "observed-requested-values-differ")
    addition = None
    if KEY in actual:
        require(platform == "darwin", "unexpected-nondarwin-addition")
        value = actual[KEY].encode("utf-8")
        require(len(value) <= MAX_VALUE_BYTES and b"\0" not in value, "startup-value-limit")
        addition = dict(identifier=IDENTIFIER, utf8_bytes=len(value), sha256=sha(value))
    return dict(
        schema_version=1,
        surface="python-environment-mapping",
        platform=platform,
        requested_environment=expected,
        addition=addition,
    )


def validate_observation(row):
    require(
        isinstance(row, dict)
        and set(row) == {"schema_version", "surface", "platform", "requested_environment", "addition"},
        "observation-shape",
    )
    require(
        type(row["schema_version"]) is int
        and row["schema_version"] == 1
        and row["surface"] == "python-environment-mapping",
        "observation-schema",
    )
    require(row["platform"] in {"linux", "darwin"}, "unsupported-platform")
    validate_environment_request(row["requested_environment"])
    item = row["addition"]
    if item is not None:
        require(
            row["platform"] == "darwin"
            and isinstance(item, dict)
            and set(item) == {"identifier", "utf8_bytes", "sha256"},
            "addition-shape",
        )
        require(
            item["identifier"] == IDENTIFIER
            and type(item["utf8_bytes"]) is int
            and 0 <= item["utf8_bytes"] <= MAX_VALUE_BYTES
            and valid_sha(item["sha256"]),
            "addition-identity",
        )
    return row


def profile(row):
    validate_observation(row)
    return {key: row[key] for key in ["schema_version", "surface", "platform", "addition"]}


def verify_observation(row, expected_environment, accepted_profile):
    validate_observation(row)
    require(row["requested_environment"] == expected_environment, "different-launch-request")
    require(profile(row) == accepted_profile, "different-startup-profile")


def source_inputs(paths):
    require(isinstance(paths, (tuple, list)) and 1 <= len(paths) <= 64, "source-count-limit")
    result = {}
    for value in paths:
        path = Path(value)
        require(path.is_absolute() and path.resolve() == path and str(path) not in result, "source-path-identity")
        result[str(path)] = file_identity(path)
    return result


def directory_inputs(environment):
    result = {}
    for key in sorted(PRIVATE | (set(environment) & OPTIONAL)):
        path = Path(environment[key])
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) and path.resolve(strict=True) == path, "private-directory-changed")
        result[key] = dict(path=str(path), identity=[info.st_dev, info.st_ino, info.st_mode])
    return result


def guard(request):
    for entry in request["directories"].values():
        path = Path(entry["path"])
        info = path.lstat()
        require(
            stat.S_ISDIR(info.st_mode)
            and path.resolve(strict=True) == path
            and encoded([info.st_dev, info.st_ino, info.st_mode]) == encoded(entry["identity"]),
            "private-directory-changed",
        )
    require(
        encoded(source_inputs([Path(p) for p in request["source_inputs"]])) == encoded(request["source_inputs"]),
        "source-inputs-changed",
    )
    require(
        encoded(interpreter(request["interpreter"]["selected_path"])) == encoded(request["interpreter"]),
        "selected-interpreter-changed",
    )
    require(same_physical(interpreter(sys.executable), request["interpreter"]), "actual-interpreter-differs")


def request(environment, selected_interpreter, import_target, sources):
    here = Path(__file__).resolve()
    target = Path(import_target).resolve(strict=True)
    require(target.name == "correctness_controller.py", "unsupported-import-target")
    require(here in sources and target in sources, "unbound-probe-or-import-target")
    return dict(
        schema_version=1,
        role="prospective-python-startup-request",
        environment=environment_request(environment),
        interpreter=interpreter(selected_interpreter),
        import_target=str(target),
        source_inputs=source_inputs(sources),
        directories=directory_inputs(environment),
    )


def validate_request(row):
    require(
        isinstance(row, dict)
        and set(row)
        == {"schema_version", "role", "environment", "interpreter", "import_target", "source_inputs", "directories"},
        "probe-request-shape",
    )
    require(
        type(row["schema_version"]) is int
        and row["schema_version"] == 1
        and row["role"] == "prospective-python-startup-request",
        "probe-request-schema",
    )
    validate_environment_request(row["environment"])
    require(
        isinstance(row["source_inputs"], dict)
        and str(Path(__file__).resolve()) in row["source_inputs"]
        and row["import_target"] in row["source_inputs"],
        "probe-input-binding",
    )
    require(Path(row["import_target"]).name == "correctness_controller.py", "probe-import-boundary")
    require(
        isinstance(row["directories"], dict)
        and set(row["directories"]) == PRIVATE | (set(row["environment"]["keys"]) & OPTIONAL),
        "directory-inventory",
    )
    guard(row)


def save(path, row):
    data = encoded(row) + b"\n"
    require(len(data) <= MAX_RECEIPT_BYTES, "receipt-byte-limit")
    with Path(path).open("xb") as stream:
        stream.write(data)


def import_admitted_controller(request):
    """선택한 로컬 Python 소스는 캐시 대신 검증한 바이트를 직접 컴파일한다."""
    target = Path(request["import_target"])
    admitted = request["source_inputs"]
    original = importlib.machinery.SourceFileLoader.get_code
    original_sourceless = importlib.machinery.SourcelessFileLoader.get_code
    original_create = importlib.machinery.ExtensionFileLoader.create_module
    original_exec = importlib.machinery.ExtensionFileLoader.exec_module

    def exact_code(path):
        data, metadata = read_file(path, MAX_SOURCE_BYTES)
        require(
            encoded(dict(sha256=sha(data), bytes=len(data), metadata=metadata)) == encoded(admitted[str(path)]),
            "import-source-changed",
        )
        return compile(data, str(path), "exec")

    def code(loader, fullname):
        selected = Path(loader.path).resolve(strict=True)
        if str(selected) in admitted:
            return exact_code(selected)
        require(
            not Path(loader.path).absolute().is_relative_to(target.parent)
            and not selected.is_relative_to(target.parent),
            "unbound-local-import",
        )
        return original(loader, fullname)

    def sourceless(loader, fullname):
        selected = Path(loader.path).resolve(strict=True)
        require(
            not Path(loader.path).absolute().is_relative_to(target.parent)
            and not selected.is_relative_to(target.parent),
            "unbound-local-bytecode",
        )
        return original_sourceless(loader, fullname)

    def native_allowed(loader):
        selected = Path(loader.path).resolve(strict=True)
        require(
            not Path(loader.path).absolute().is_relative_to(target.parent)
            and not selected.is_relative_to(target.parent),
            "unbound-local-native-extension",
        )

    def native_create(loader, spec):
        native_allowed(loader)
        return original_create(loader, spec)

    def native_exec(loader, module):
        native_allowed(loader)
        return original_exec(loader, module)

    importlib.machinery.ExtensionFileLoader.create_module = native_create
    importlib.machinery.ExtensionFileLoader.exec_module = native_exec
    importlib.machinery.SourceFileLoader.get_code = code
    importlib.machinery.SourcelessFileLoader.get_code = sourceless
    try:
        spec = importlib.util.spec_from_file_location("bound_controller_startup_probe", target)
        module = importlib.util.module_from_spec(spec)
        exec(exact_code(target), module.__dict__)
    finally:
        importlib.machinery.SourceFileLoader.get_code = original
        importlib.machinery.SourcelessFileLoader.get_code = original_sourceless
        importlib.machinery.ExtensionFileLoader.create_module = original_create
        importlib.machinery.ExtensionFileLoader.exec_module = original_exec


def execute(request_path, expected_sha256, report):
    """원문 환경 값 없이 정상 실패와 입력 가드의 관측을 함께 보존한다."""
    started = time.perf_counter()
    row = dict(
        schema_version=1,
        role="prospective-python-startup-observation",
        status="failed",
        exit_code=1,
        request_sha256=expected_sha256,
        early=None,
        after_import=None,
        terminal_guard={"status": "not-run"},
    )
    ready = False
    value = None
    try:
        require(sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode, "probe-requires-isolation")
        data, _ = read_file(request_path, MAX_RECEIPT_BYTES)
        require(sha(data) == expected_sha256, "probe-request-changed")
        value = strict(data)
        validate_request(value)
        report = Path(report)
        require(
            report.is_absolute()
            and report.parent.is_dir()
            and report.parent.resolve() == report.parent
            and not report.exists()
            and not report.is_symlink(),
            "probe-report-boundary",
        )
        for name in [request_path, *value["source_inputs"], value["interpreter"]["resolved_path"]]:
            path = Path(name).resolve()
            require(
                not (report == path or report.is_relative_to(path) or path.is_relative_to(report)),
                "probe-output-overlap",
            )
        ready = True
        row["actual_interpreter"] = interpreter(sys.executable)
        row["early"] = observe_request(value["environment"], dict(os.environ))
        import_admitted_controller(value)
        row["after_import"] = observe_request(value["environment"], dict(os.environ))
        require(profile(row["early"]) == profile(row["after_import"]), "startup-profile-not-stable")
        row.update(status="passed", exit_code=0)
    except SystemExit as error:
        code = int(error.code) & 255 if type(error.code) is int else 0 if error.code is None else 1
        row.update(
            status="incomplete" if code == 125 else "failed",
            exit_code=125 if code == 125 else 1,
            failure_category="import-system-exit",
            observed_import_exit=code,
        )
    except KeyboardInterrupt:
        row.update(status="incomplete", exit_code=125, failure_category="interrupt")
    except Exception as error:
        row.update(
            status="failed", exit_code=1, failure_type=type(error).__name__, failure_sha256=sha(str(error).encode())
        )
    if value is not None and row["exit_code"] != 125:
        try:
            guard(value)
            current, _ = read_file(request_path, MAX_RECEIPT_BYTES)
            require(sha(current) == expected_sha256, "probe-request-changed")
            row["terminal_guard"] = dict(status="passed")
        except Exception as error:
            row.update(
                status="failed",
                exit_code=1,
                terminal_guard=dict(
                    status="failed", failure_type=type(error).__name__, failure_sha256=sha(str(error).encode())
                ),
            )
    elif row["exit_code"] == 125:
        row["terminal_guard"] = dict(status="unavailable", reason="incomplete-probe")
    row["wall_seconds_before_receipt"] = time.perf_counter() - started
    if ready:
        save(report, row)
    else:
        print(
            json.dumps(
                dict(
                    status="refused-before-probe-record",
                    exit_code=row["exit_code"],
                    wall_seconds=row["wall_seconds_before_receipt"],
                )
            ),
            file=sys.stderr,
        )
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(execute(args.request, args.sha256, args.report)["exit_code"])


if __name__ == "__main__":
    main()
