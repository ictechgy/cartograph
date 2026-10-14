"""검증용 Python 실행에서 선택한 설치 바이트와 관측한 모듈 정체성만 기록한다."""

from __future__ import annotations

import email.parser
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sysconfig
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("runtime_content_seal", ROOT / "vendor/sdk_content_seal.py")
SEAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SEAL)
MAX_ENTRIES = 4096
MAX_PACKAGE_BYTES = 64 * 1024**2
MAX_MODULES = 1024
MAX_MODULE_BYTES = 256 * 1024**2


def file_identity(path: Path) -> dict:
    """이미 선택한 정규 파일을 no-follow 읽기로 확인하고 내용 해시만 반환한다."""
    path = path.resolve(strict=True)
    info = path.lstat()
    if not path.is_file() or info.st_size > MAX_MODULE_BYTES:
        raise ValueError("Invalid bounded runtime input")
    return dict(sha256=SEAL.hash_file(path, SEAL.fingerprint(info)), bytes=info.st_size)


def sha(value: object) -> str:
    return hashlib.sha256(SEAL.canonical_bytes(value)).hexdigest()


def distribution(projection: dict) -> dict:
    """기존 공식 설치 투영의 단일 패키지 식별자만 사용한다. 재설치는 하지 않는다."""
    if (
        not isinstance(projection, dict)
        or type(projection.get("schema_version")) is not int
        or projection["schema_version"] != 1
        or projection.get("source_format") != "pip-install-report-v1"
        or not isinstance(projection.get("distributions"), list)
        or len(projection["distributions"]) != 1
    ):
        raise ValueError("Invalid installation projection")
    item = projection["distributions"][0]
    if (
        not isinstance(item, dict)
        or set(item) != {"name", "version", "url", "sha256", "is_direct", "is_yanked", "requested"}
        or item["name"] != "psutil"
        or item["version"] != "7.2.2"
        or item["is_direct"] is not False
        or item["is_yanked"] is not False
        or item["requested"] is not True
        or not isinstance(item["sha256"], str)
        or not re.fullmatch("[a-f0-9]{64}", item["sha256"])
        or not isinstance(item["url"], str)
    ):
        raise ValueError("Unexpected installation distribution")
    url = urlsplit(item["url"])
    if (
        url.scheme != "https"
        or url.netloc != "files.pythonhosted.org"
        or url.query
        or url.fragment
        or not re.fullmatch(
            r"/packages/[a-f0-9]{2}/[a-f0-9]{2}/[a-f0-9]{60}/psutil-7\.2\.2-[A-Za-z0-9._-]+\.whl", url.path
        )
    ):
        raise ValueError("Unaccepted distribution origin")
    return item


def package_snapshot(target: Path, projection: dict) -> dict:
    """명시한 --target 전체를 봉인하며 여분 배포나 링크를 조용히 제외하지 않는다."""
    started = time.perf_counter()
    item = distribution(projection)
    target = target.resolve(strict=True)
    if {p.name for p in target.iterdir()} != {"psutil", "psutil-7.2.2.dist-info"}:
        raise ValueError("Unexpected installed target entries")
    seal = SEAL.capture(
        {"PACKAGE": target}, max_entries=MAX_ENTRIES, max_bytes=MAX_PACKAGE_BYTES, max_path_bytes=1024**2
    )
    if any(e["type"] not in {"file", "directory"} for e in seal["entries"]):
        raise ValueError("Installed target links are not accepted")
    metadata = target / "psutil-7.2.2.dist-info/METADATA"
    data = SEAL.expected_bytes(metadata)
    parsed = email.parser.BytesParser().parsebytes(data)
    if parsed.get_all("Name") != ["psutil"] or parsed.get_all("Version") != ["7.2.2"]:
        raise ValueError("Installed metadata identity mismatch")
    if not (target / "psutil/__init__.py").is_file() or not (target / "psutil-7.2.2.dist-info/RECORD").is_file():
        raise ValueError("Missing package input")
    return dict(
        schema_version=1,
        target=str(target),
        name="psutil",
        version="7.2.2",
        distribution=item,
        projection_sha256=sha(projection),
        content=seal,
        wall_seconds=time.perf_counter() - started,
        scope="Observed installed bytes only; wheel-to-install equivalence and OS/runtime closure not proved",
    )


def validate_package_receipt(expected):
    fields = {
        "schema_version",
        "target",
        "name",
        "version",
        "distribution",
        "projection_sha256",
        "content",
        "wall_seconds",
        "scope",
    }
    if (
        not isinstance(expected, dict)
        or set(expected) != fields
        or type(expected["schema_version"]) is not int
        or expected["schema_version"] != 1
        or expected["name"] != "psutil"
        or expected["version"] != "7.2.2"
        or not isinstance(expected["target"], str)
        or not Path(expected["target"]).is_absolute()
        or not isinstance(expected["projection_sha256"], str)
        or not re.fullmatch("[a-f0-9]{64}", expected["projection_sha256"])
        or type(expected["wall_seconds"]) not in (int, float)
        or not math.isfinite(expected["wall_seconds"])
        or expected["wall_seconds"] < 0
    ):
        raise ValueError("Invalid exact package receipt")
    distribution(
        {"schema_version": 1, "source_format": "pip-install-report-v1", "distributions": [expected["distribution"]]}
    )
    SEAL.validate_expected(expected["content"])


def verify_package(target: Path, expected: dict) -> dict:
    """수집한 설치 인벤토리를 매번 새로 읽고 변경되면 실행 전에 거부한다."""
    validate_package_receipt(expected)
    if (
        not isinstance(expected, dict)
        or expected.get("name") != "psutil"
        or expected.get("version") != "7.2.2"
        or Path(expected["target"]).resolve() != target.resolve()
    ):
        raise ValueError("Installed target binding mismatch")
    actual = SEAL.verify(expected["content"], {"PACKAGE": target})
    if not actual["matches"]:
        raise ValueError("Installed target bytes changed")
    if any(e["type"] not in {"file", "directory"} for e in actual["actual"]["entries"]):
        raise ValueError("Installed target contains an unaccepted link")
    return actual


def _module_cache_path(module, spec) -> Path | None:
    """새 spec 캐시를 우선하되 남아 있는 구형 메타데이터와의 모순도 거부한다."""
    paths = []
    for value in (getattr(spec, "cached", None), getattr(module, "__cached__", None)):
        if value is None:
            continue
        if not isinstance(value, str) or not value or "\x00" in value:
            raise ValueError("Invalid module bytecode cache metadata")
        try:
            paths.append(Path(value).resolve())
        except (OSError, RuntimeError, ValueError) as error:
            raise ValueError("Invalid module bytecode cache path") from error
    if len(paths) == 2 and paths[0] != paths[1]:
        raise ValueError("Conflicting module bytecode cache metadata")
    return paths[0] if paths else None


def module_snapshot(
    modules: dict, target: Path, code_files: dict[str, str], bytecode_cache_root: Path | None = None
) -> dict:
    """실제로 관측한 모듈만 분류한다. 비관측 표준 라이브러리 전체를 봉인했다고 말하지 않는다."""
    started = time.perf_counter()
    if len(modules) > MAX_MODULES:
        raise ValueError("Runtime module count exceeds limit")
    target = target.resolve(strict=True)
    stdlib = Path(sysconfig.get_path("stdlib")).resolve(strict=True)
    selected = {str(Path(path).resolve(strict=True)): value for path, value in code_files.items()}
    if len(selected) != len(code_files):
        raise ValueError("Duplicate selected code identity")
    result, total = {}, 0
    for name, module in sorted(modules.items()):
        if not isinstance(name, str) or len(name) > 512 or module is None:
            raise ValueError("Invalid observed module")
        spec = getattr(module, "__spec__", None)
        origin = getattr(spec, "origin", None)
        if origin in {"built-in", "frozen"}:
            result[name] = dict(kind=origin)
            continue
        origin = origin or getattr(module, "__file__", None)
        if not isinstance(origin, str):
            # Python 3.11/3.12 typing은 두 폐기 예정 래퍼를 sys.modules에 직접 등록한다.
            parent = modules.get("typing")
            suffix = name.removeprefix("typing.")
            if name not in {"typing.io", "typing.re"} or parent is None or getattr(parent, suffix, None) is not module:
                raise ValueError("Unbound namespace or dynamic module origin: " + name)
            parent_path = Path(parent.__file__).resolve(strict=True)
            if parent_path != stdlib / "typing.py" or getattr(module, "__module__", None) != "typing":
                raise ValueError("Unbound typing namespace implementation")
            identity = file_identity(parent_path)
            total += identity["bytes"]
            if total > MAX_MODULE_BYTES:
                raise ValueError("Observed module bytes exceed limit")
            result[name] = dict(kind="stdlib-derived-namespace", parent="typing", path=str(parent_path), **identity)
            continue
        try:
            path = Path(origin).resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise ValueError("Unreadable observed module origin") from error
        if path.is_relative_to(target):
            kind = "private-package"
        elif str(path) in selected:
            kind = "selected-script"
        elif path.is_relative_to(stdlib) and "site-packages" not in path.relative_to(stdlib).parts:
            kind = "observed-stdlib"
        else:
            raise ValueError("Observed module is outside selected runtime inputs")
        identity = file_identity(path)
        total += identity["bytes"]
        if total > MAX_MODULE_BYTES:
            raise ValueError("Observed module bytes exceed limit")
        if kind == "selected-script" and identity["sha256"] != selected[str(path)]:
            raise ValueError("Selected module bytes changed")
        row = dict(kind=kind, path=str(path), **identity)
        cache = _module_cache_path(module, spec)
        if cache is not None:
            if not cache.is_relative_to(path.parent) and not (
                bytecode_cache_root is not None and cache.is_relative_to(bytecode_cache_root.resolve())
            ):
                raise ValueError("Module bytecode cache escapes selected origin")
            row["bytecode_cache"] = dict(path=str(cache), exists=cache.exists())
            if cache.exists():
                cached_identity = file_identity(cache)
                total += cached_identity["bytes"]
                if total > MAX_MODULE_BYTES:
                    raise ValueError("Observed module bytes exceed limit")
                row["bytecode_cache"].update(cached_identity)
        result[name] = row
    return dict(
        modules=result,
        sha256=sha(result),
        bytes=total,
        wall_seconds=time.perf_counter() - started,
        scope="Observed module files and explicit built-in/frozen origins only; not complete loader or stdlib closure",
    )


def private_environment(root: Path, developer_directory: Path | None = None) -> dict:
    """상속 환경값을 읽지 않고 검증 전용 자식의 고정 환경만 새로 만든다."""
    root = root.resolve()
    if root.exists():
        raise ValueError("Private environment root must be new")
    root.mkdir(parents=True)
    directories = {}
    for key, name in [("HOME", "home"), ("TMPDIR", "tmp"), ("XDG_CACHE_HOME", "cache")]:
        path = root / name
        path.mkdir()
        directories[key] = str(path)
    result = dict(
        PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C", TZ="UTC", PYTHONDONTWRITEBYTECODE="1", **directories
    )
    if developer_directory is not None:
        selected = developer_directory.resolve(strict=True)
        if not selected.is_dir():
            raise ValueError("Developer directory is not a directory")
        result["DEVELOPER_DIR"] = str(selected)
    return result
