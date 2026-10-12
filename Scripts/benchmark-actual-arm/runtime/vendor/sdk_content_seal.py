#!/usr/bin/env python3
"""명시한 SDK/컴파일러 입력 트리의 전체 내용과 링크 경계를 봉인한다."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import time

MAX_ENTRIES = 500_000
MAX_BYTES = 64 * 1024**3
MAX_PATH_BYTES = 64 * 1024**2
MAX_MANIFEST_BYTES = 64 * 1024**2
CHUNK_BYTES = 1024**2


class SealError(ValueError):
    """공개 가능한 고정 이유만 담고 원시 경로나 예외 산문은 노출하지 않는다."""


def canonical_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode()


def fingerprint(info: os.stat_result) -> tuple:
    # atime은 읽기 자체로 변하므로 경쟁 상태 판별에서 제외한다.
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def selected_roots(roots: dict[str, Path]) -> dict[str, Path]:
    if not isinstance(roots, dict) or not roots:
        raise SealError("invalid-roots")
    if any(not isinstance(label, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,47}", label) for label in roots):
        raise SealError("invalid-root-label")
    selected = {}
    for label, path in sorted(roots.items()):
        try:
            target = Path(path).resolve(strict=True)
            if not target.is_dir():
                raise SealError("root-not-directory")
        except (OSError, RuntimeError) as error:
            raise SealError("unreadable-root") from error
        if any(target.is_relative_to(other) or other.is_relative_to(target) for other in selected.values()):
            raise SealError("overlapping-roots")
        selected[label] = target
    return selected


def target_identity(path: Path, roots: dict[str, Path]) -> dict:
    try:
        target = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SealError("invalid-link") from error
    for label, root in roots.items():
        if target.is_relative_to(root):
            return dict(root=label, path=target.relative_to(root).as_posix())
    raise SealError("escaping-link")


def inventory(roots: dict[str, Path], max_entries: int, max_bytes: int, max_path_bytes: int) -> dict:
    """해싱 전에 모든 물리적 항목과 링크 목적지의 경계를 검사한다."""
    entries, total_bytes, path_bytes = {}, 0, 0
    try:
        for label, root in roots.items():
            stack = [root]
            while stack:
                path = stack.pop()
                info = path.lstat()
                relative = path.relative_to(root).as_posix()
                try:
                    path_bytes += len(relative.encode("utf-8")) + len(label)
                except UnicodeError as error:
                    raise SealError("invalid-path-encoding") from error
                if path_bytes > max_path_bytes:
                    raise SealError("path-byte-limit")
                key = (label, relative)
                entry = dict(root=label, path=relative, mode=stat.S_IMODE(info.st_mode))
                if stat.S_ISLNK(info.st_mode):
                    link_text = os.readlink(path)
                    entry.update(
                        type="symlink",
                        target=target_identity(path, roots),
                        link_text_sha256=hashlib.sha256(os.fsencode(link_text)).hexdigest(),
                    )
                elif stat.S_ISDIR(info.st_mode):
                    entry["type"] = "directory"
                    with os.scandir(path) as children:
                        for child in children:
                            stack.append(Path(child.path))
                            if len(entries) + len(stack) + 1 > max_entries:
                                raise SealError("entry-limit")
                elif stat.S_ISREG(info.st_mode):
                    entry.update(type="file", bytes=info.st_size)
                    total_bytes += info.st_size
                else:
                    raise SealError("unsupported-entry")
                entries[key] = dict(entry=entry, metadata=fingerprint(info), absolute=path)
                if len(entries) > max_entries or total_bytes > max_bytes:
                    raise SealError("resource-limit")
    except OSError as error:
        raise SealError("unreadable-inventory") from error
    return entries


def hash_file(path: Path, expected: tuple) -> str:
    """재연결된 파일이나 읽는 동안 변한 파일을 유효한 내용으로 채택하지 않는다."""
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = None
            if fingerprint(os.fstat(stream.fileno())) != expected:
                raise SealError("input-mutated")
            hasher, count = hashlib.sha256(), 0
            while data := stream.read(CHUNK_BYTES):
                count += len(data)
                if count > expected[3]:
                    raise SealError("input-mutated")
                hasher.update(data)
            if count != expected[3] or fingerprint(os.fstat(stream.fileno())) != expected:
                raise SealError("input-mutated")
            return hasher.hexdigest()
    except OSError as error:
        raise SealError("unreadable-file") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def identity(labels: list[str], entries: list[dict]) -> str:
    return hashlib.sha256(canonical_bytes(dict(root_labels=labels, entries=entries))).hexdigest()


def capture(
    roots: dict[str, Path],
    *,
    max_entries: int = MAX_ENTRIES,
    max_bytes: int = MAX_BYTES,
    max_path_bytes: int = MAX_PATH_BYTES,
) -> dict:
    """완전한 전후 인벤토리가 일치할 때만 내용 봉인과 전체 비용을 반환한다."""
    started = time.perf_counter()
    if any(
        type(n) is not int or n < 1 or n > ceiling
        for n, ceiling in [
            (max_entries, MAX_ENTRIES),
            (max_bytes, MAX_BYTES),
            (max_path_bytes, MAX_PATH_BYTES),
        ]
    ):
        raise SealError("invalid-limits")
    selected = selected_roots(roots)
    before = inventory(selected, max_entries, max_bytes, max_path_bytes)
    entries = []
    for key in sorted(before):
        item = before[key]
        entry = dict(item["entry"])
        if entry["type"] == "file":
            entry["sha256"] = hash_file(item["absolute"], item["metadata"])
        entries.append(entry)
    after = inventory(selected, max_entries, max_bytes, max_path_bytes)
    if before != after or selected_roots(roots) != selected:
        raise SealError("input-mutated")
    files = [entry for entry in entries if entry["type"] == "file"]
    result = dict(
        schema_version=1,
        roots={label: str(path) for label, path in selected.items()},
        entries=entries,
        content_sha256=identity(list(selected), entries),
        files=len(files),
        bytes=sum(entry["bytes"] for entry in files),
        limits=dict(max_entries=max_entries, max_bytes=max_bytes, max_path_bytes=max_path_bytes),
        wall_seconds=time.perf_counter() - started,
        scope="explicit input trees only; no complete OS/toolchain hermeticity proof",
        consistency="before/after observed metadata; not an atomic or adversarial snapshot",
    )
    result["manifest_sha256"] = manifest_identity(result)
    return result


def manifest_identity(value: dict) -> str:
    return hashlib.sha256(canonical_bytes({k: v for k, v in value.items() if k != "manifest_sha256"})).hexdigest()


def valid_relative(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and path.as_posix() == value


def valid_sha(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value) is not None


def validate_expected(expected: dict) -> None:
    """체크섬을 다시 계산한 비정상 영수증도 올바른 봉인으로 취급하지 않는다."""
    required = {
        "schema_version",
        "roots",
        "entries",
        "content_sha256",
        "files",
        "bytes",
        "limits",
        "wall_seconds",
        "scope",
        "consistency",
        "manifest_sha256",
    }
    try:
        if not isinstance(expected, dict) or set(expected) != required:
            raise SealError("invalid-seal")
        if type(expected["schema_version"]) is not int or expected["schema_version"] != 1:
            raise SealError("invalid-seal")
        if (
            not valid_sha(expected["manifest_sha256"])
            or not valid_sha(expected["content_sha256"])
            or expected["manifest_sha256"] != manifest_identity(expected)
        ):
            raise SealError("invalid-seal")
        roots, entries, limits = expected["roots"], expected["entries"], expected["limits"]
        ceilings = dict(max_entries=MAX_ENTRIES, max_bytes=MAX_BYTES, max_path_bytes=MAX_PATH_BYTES)
        if (
            not isinstance(roots, dict)
            or not roots
            or not isinstance(entries, list)
            or not isinstance(limits, dict)
            or set(limits) != set(ceilings)
        ):
            raise SealError("invalid-seal")
        if any(type(value) is not int or not 1 <= value <= ceilings[key] for key, value in limits.items()):
            raise SealError("invalid-seal")
        for label, path in roots.items():
            if (
                not isinstance(label, str)
                or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,47}", label)
                or not isinstance(path, str)
                or not Path(path).is_absolute()
                or os.path.normpath(path) != path
            ):
                raise SealError("invalid-seal")
        elapsed = expected["wall_seconds"]
        if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or elapsed < 0:
            raise SealError("invalid-seal")
        if (
            expected["scope"] != "explicit input trees only; no complete OS/toolchain hermeticity proof"
            or expected["consistency"] != "before/after observed metadata; not an atomic or adversarial snapshot"
        ):
            raise SealError("invalid-seal")
        keys, index, files, size, path_bytes = [], {}, 0, 0, 0
        for entry in entries:
            if (
                not isinstance(entry, dict)
                or entry.get("root") not in roots
                or not valid_relative(entry.get("path"))
                or type(entry.get("mode")) is not int
                or not 0 <= entry["mode"] <= 0o7777
            ):
                raise SealError("invalid-seal")
            common = {"root", "path", "mode", "type"}
            kind = entry.get("type")
            if kind == "file":
                if (
                    set(entry) != common | {"bytes", "sha256"}
                    or type(entry["bytes"]) is not int
                    or entry["bytes"] < 0
                    or not valid_sha(entry["sha256"])
                ):
                    raise SealError("invalid-seal")
                files += 1
                size += entry["bytes"]
            elif kind == "directory":
                if set(entry) != common:
                    raise SealError("invalid-seal")
            elif kind == "symlink":
                target = entry.get("target")
                if (
                    set(entry) != common | {"target", "link_text_sha256"}
                    or not valid_sha(entry["link_text_sha256"])
                    or not isinstance(target, dict)
                    or set(target) != {"root", "path"}
                    or target["root"] not in roots
                    or not valid_relative(target["path"])
                ):
                    raise SealError("invalid-seal")
            else:
                raise SealError("invalid-seal")
            key = (entry["root"], entry["path"])
            keys.append(key)
            index[key] = entry
            path_bytes += len(entry["root"]) + len(entry["path"].encode("utf-8"))
        if keys != sorted(set(keys)) or len(keys) > limits["max_entries"] or path_bytes > limits["max_path_bytes"]:
            raise SealError("invalid-seal")
        for label in roots:
            if index.get((label, "."), {}).get("type") != "directory":
                raise SealError("invalid-seal")
        for key, entry in index.items():
            if entry["path"] != ".":
                parent = PurePosixPath(entry["path"]).parent.as_posix()
                if index.get((entry["root"], parent), {}).get("type") != "directory":
                    raise SealError("invalid-seal")
            if entry["type"] == "symlink":
                target = entry["target"]
                if index.get((target["root"], target["path"]), {}).get("type") not in ("file", "directory"):
                    raise SealError("invalid-seal")
        if (
            type(expected["files"]) is not int
            or type(expected["bytes"]) is not int
            or expected["files"] != files
            or expected["bytes"] != size
            or size > limits["max_bytes"]
            or expected["content_sha256"] != identity(sorted(roots), entries)
        ):
            raise SealError("invalid-seal")
    except (KeyError, TypeError, ValueError, OverflowError, UnicodeError) as error:
        raise SealError("invalid-seal") from error


def expected_bytes(path: Path) -> bytes:
    """기대 영수증도 특수 파일/링크를 열거나 읽는 중 바뀐 상태를 채택하지 않는다."""
    descriptor = None
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_MANIFEST_BYTES:
            raise SealError("invalid-expected-file")
        before = fingerprint(info)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = None
            if fingerprint(os.fstat(stream.fileno())) != before:
                raise SealError("expected-file-mutated")
            data = stream.read(MAX_MANIFEST_BYTES + 1)
            if (
                len(data) != info.st_size
                or fingerprint(os.fstat(stream.fileno())) != before
                or fingerprint(path.lstat()) != before
            ):
                raise SealError("expected-file-mutated")
            return data
    except OSError as error:
        raise SealError("unreadable-expected-file") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def strict_expected_json(data: bytes) -> dict:
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise SealError("invalid-seal")
            value[key] = item
        return value

    def reject_constant(value):
        raise SealError("invalid-seal")

    try:
        parsed = json.loads(data, object_pairs_hook=unique, parse_constant=reject_constant)
        if not isinstance(parsed, dict):
            raise SealError("invalid-seal")
        return parsed
    except (ValueError, UnicodeError, RecursionError) as error:
        raise SealError("invalid-seal") from error


def verify(expected: dict, roots: dict[str, Path]) -> dict:
    """예전 해시를 재사용하지 않고 동일한 루트 전체를 다시 읽어 비교한다."""
    started = time.perf_counter()
    validate_expected(expected)
    selected = selected_roots(roots)
    if {label: str(path) for label, path in selected.items()} != expected["roots"]:
        raise SealError("root-set-changed")
    actual = capture(roots, **expected["limits"])
    return dict(
        matches=expected["content_sha256"] == actual["content_sha256"],
        expected_sha256=expected["content_sha256"],
        actual_sha256=actual["content_sha256"],
        actual=actual,
        wall_seconds=time.perf_counter() - started,
    )


def write_new(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True, allow_nan=False) + "\n")


def record(
    roots: dict[str, Path],
    output: Path,
    *,
    expected: dict | None = None,
    expected_path: Path | None = None,
    max_entries: int = MAX_ENTRIES,
    max_bytes: int = MAX_BYTES,
    max_path_bytes: int = MAX_PATH_BYTES,
) -> dict:
    """출력 디렉터리 단위로 증거를 새로 만들고 실패 시간도 보존한다."""
    started = time.perf_counter()
    if expected is not None and expected_path is not None:
        raise SealError("ambiguous-expected-seal")
    output = output.resolve()
    if output.exists():
        raise SealError("existing-output")
    # 잘못된 입력도 원래 트리 안에 실패 영수증을 쓰지 않는다.
    for source in roots.values():
        root = Path(source).resolve()
        if output.is_relative_to(root) or root.is_relative_to(output):
            raise SealError("output-input-overlap")
    output.mkdir(parents=True)
    limits = dict(max_entries=max_entries, max_bytes=max_bytes, max_path_bytes=max_path_bytes)
    request = dict(
        schema_version=1,
        operation="verify" if expected is not None or expected_path is not None else "capture",
        roots={str(label): str(Path(path).resolve()) for label, path in roots.items()},
        requested_capture_limits=limits,
        verification_limits="bound expected manifest" if expected is not None or expected_path is not None else None,
        expected_path=str(expected_path.absolute()) if expected_path is not None else None,
        expected_manifest_sha256=expected.get("manifest_sha256") if isinstance(expected, dict) else None,
        implementation_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    )
    write_new(output / "request.json", request)
    result = dict(schema_version=1, operation=request["operation"], status="failed")
    try:
        if expected_path is not None:
            data = expected_bytes(expected_path)
            result["expected_file_sha256"] = hashlib.sha256(data).hexdigest()
            expected = strict_expected_json(data)
            if not isinstance(expected, dict):
                raise SealError("invalid-seal")
        if expected is None:
            current = capture(roots, **limits)
            result.update(status="passed", actual_sha256=current["content_sha256"])
        else:
            checked = verify(expected, roots)
            current = checked["actual"]
            result.update(
                status="passed" if checked["matches"] else "mismatch",
                expected_sha256=checked["expected_sha256"],
                actual_sha256=checked["actual_sha256"],
            )
        if (
            len((json.dumps(current, indent=2, sort_keys=True, ensure_ascii=True, allow_nan=False) + "\n").encode())
            > MAX_MANIFEST_BYTES
        ):
            raise SealError("manifest-byte-limit")
        write_new(output / "seal.json", current)
        result["seal"] = "seal.json"
    except SealError as error:
        result["status"] = "failed"
        result["failure"] = str(error)
    except KeyboardInterrupt:
        result.update(status="incomplete", failure="interrupt")
    except (OSError, ValueError, TypeError, KeyError):
        result.update(status="failed", failure="unhandled-input-or-output-error")
    result["wall_seconds"] = time.perf_counter() - started
    result["request_sha256"] = hashlib.sha256((output / "request.json").read_bytes()).hexdigest()
    write_new(output / "result.json", result)
    return result


def main() -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="append", required=True, metavar="LABEL=PATH")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    roots = {}
    for item in args.root:
        if "=" not in item:
            parser.error("Each root requires LABEL=PATH")
        label, path = item.split("=", 1)
        if label in roots:
            parser.error("Root labels must be unique")
        roots[label] = Path(path)
    try:
        result = record(roots, args.output, expected_path=args.verify)
    except (OSError, ValueError, TypeError):
        print("Seal setup refused; no input was promoted", file=sys.stderr)
        return 2
    print(json.dumps({k: result.get(k) for k in ["status", "failure", "wall_seconds"]}, sort_keys=True))
    return 0 if result["status"] == "passed" else 125 if result["status"] == "incomplete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
