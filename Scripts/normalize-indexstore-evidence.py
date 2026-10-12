#!/usr/bin/env python3
"""원본 증거를 보존하면서 허용된 텍스트만 별도의 공개 검토 묶음으로 만든다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
from urllib.parse import parse_qsl, urlsplit

MAX_FILES = 10_000
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
TEXT_SUFFIXES = {".json", ".stdout", ".stderr"}
LOG_REFERENCE_KEYS = {
    "stdout",
    "stderr",
    "log_path",
    "results",
    "normalized_result",
    "graph",
    "setup_results",
    "cg_config",
}
SYSTEM_PREFIXES = {
    "/usr/bin": "$SYSTEM_BIN",
    "/usr/lib": "$SYSTEM_LIB",
    "/usr/include": "$SYSTEM_INCLUDE",
    "/bin": "$SYSTEM_BASE_BIN",
    "/sbin": "$SYSTEM_SBIN",
    "/System/Library": "$SYSTEM_LIBRARY",
    "/Library/Developer/CommandLineTools": "$SYSTEM_CLT",
    "/dev/null": "$SYSTEM_NULL",
    "/dev/fd": "$SYSTEM_FD",
}
CREDENTIAL_KEYS = {
    "password",
    "passwd",
    "clientsecret",
    "apikey",
    "accesskey",
    "accesstoken",
    "refreshtoken",
    "authorization",
    "cookie",
    "setcookie",
    "awsaccesskeyid",
    "awssecretaccesskey",
    "awssessiontoken",
    "githubtoken",
    "ghtoken",
    "slacktoken",
    "openaiapikey",
    "token",
    "secret",
    "credentials",
    "credential",
    "privatekey",
    "sessiontoken",
    "oauthtoken",
    "bearertoken",
    "apitoken",
    "awssecuritytoken",
}
SIGNED_QUERY_KEYS = CREDENTIAL_KEYS | {
    "signature",
    "sig",
    "xamzsignature",
    "xamzsecuritytoken",
    "xamzcredential",
    "xgoogsignature",
    "xgoogcredential",
    "googleaccessid",
    "key",
    "se",
    "sp",
    "sv",
}
ENVIRONMENT_KEYS = {"HOME", "USER", "PATH", "SHELL", "TMPDIR", "PWD", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY"}
ABSOLUTE_PATH = re.compile(
    r"(?<![A-Za-z0-9_/])(?:-[ILF]|-isystem=?|--?[A-Za-z0-9_-]+=)?" r"(?P<path>/(?!/)[^\s\"'`<>|,;)}\]]+)"
)
URL = re.compile(r"https?://[^\s\"'<>]+", re.IGNORECASE)
SENSITIVE_PATTERNS = [
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----")),
    ("aws-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{16,}\b")),
    ("api-token", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b")),
    ("bearer-token", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{12,}", re.IGNORECASE)),
    ("email-address", re.compile(r"\b[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
    ("credential-url", re.compile(r"https?://[^\s/:@]+:[^\s/@]+@", re.IGNORECASE)),
    (
        "secret-assignment",
        re.compile(
            r"(?i)\b(?:password|passwd|client_secret|api_key|access_token|refresh_token|authorization|cookie)"
            r"[\"']?\s*[:=]\s*[\"']?(?!\$|null\b|none\b|false\b)[^\s\"',;}]{4,}"
        ),
    ),
    (
        "secret-argument",
        re.compile(r"""["']--(?:password|token|api-key|client-secret)["']\s*,\s*["'][^"']+["']""", re.IGNORECASE),
    ),
    (
        "environment-dump",
        re.compile(r"(?m)^(?:HOME|USER|PATH|SHELL|TMPDIR|AWS_SECRET_ACCESS_KEY|GITHUB_TOKEN|SSH_AUTH_SOCK)="),
    ),
]


class PublicationBlocked(ValueError):
    """불확실한 데이터를 공개 묶음에 싣지 않고 호출자에게 검토를 요구한다."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def block(category: str, relative: str, value: str = "") -> None:
    """문제 원문 대신 위치와 지문만 진단에 남겨 비밀의 재노출을 피한다."""
    signature = digest(value.encode("utf-8"))[:16] if value else "none"
    safe_relative = relative
    if relative.startswith("/") or any(pattern.search(relative) for _, pattern in SENSITIVE_PATTERNS):
        safe_relative = "artifact-sha256-" + digest(relative.encode())[:16]
    raise PublicationBlocked(f"{category}; artifact={safe_relative}; value_sha256_prefix={signature}")


def check_sensitive(text: str, relative: str) -> None:
    if any(ord(character) < 32 and character not in "\n\r\t" or ord(character) == 127 for character in text):
        block("unexpected-control-or-binary-content", relative)
    for category, pattern in SENSITIVE_PATTERNS:
        match = pattern.search(text)
        if match:
            block(category, relative, match.group())
    for match in re.finditer(r"""\b([A-Za-z][A-Za-z0-9_-]*)["']?\s*[:=]\s*""", text):
        if re.sub(r"[^a-z0-9]", "", match.group(1).lower()) in CREDENTIAL_KEYS:
            block("credential-field-or-assignment", relative, match.group(1))
    # 로그 안에 삽입된 JSON은 파일 전체 JSON 파서에 닿지 않을 수 있다.
    # 값은 해석하지 않고 인코딩된 키만 확인해 비밀 필드 우회를 막는다.
    for match in re.finditer(r'("(?:[^"\\\r\n]|\\.)*")\s*:', text):
        try:
            name = json.loads(match.group(1))
        except (ValueError, json.JSONDecodeError):
            continue
        if re.sub(r"[^a-z0-9]", "", name.lower()) in CREDENTIAL_KEYS:
            block("credential-json-field", relative, match.group(1))
    assignments = re.findall(r"(?m)^[A-Z][A-Z0-9_]{2,}=", text)
    if len(assignments) >= 3:
        block("possible-environment-dump", relative)
    for match in URL.finditer(text):
        try:
            parsed = urlsplit(match.group())
        except ValueError:
            block("invalid-url", relative, match.group())
        if parsed.username or parsed.password:
            block("credential-url", relative, match.group())
        parameters = parse_qsl(parsed.query, keep_blank_values=True) + parse_qsl(
            parsed.fragment, keep_blank_values=True
        )
        for name, _ in parameters:
            if re.sub(r"[^a-z0-9]", "", name.lower()) in SIGNED_QUERY_KEYS:
                block("token-bearing-or-signed-url", relative, match.group())


def strict_json(text: str) -> Any:
    def pairs(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result

    def constant(_: str) -> None:
        raise ValueError("Non-finite JSON value")

    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def bounded_walk(base: Path, raw: Path) -> list[Path]:
    """허용 디렉터리 안의 심볼릭 링크는 따라가지도 조용히 생략하지도 않는다."""
    if base.is_symlink():
        block("symlink-directory", str(base.relative_to(raw)))
    if not base.exists():
        return []
    found = []
    for directory, names, files in os.walk(base, followlinks=False):
        for name in names:
            path = Path(directory) / name
            if path.is_symlink():
                block("symlink-directory", str(path.relative_to(raw)))
        found.extend(Path(directory) / name for name in files)
    return found


def select_files(raw: Path) -> list[Path]:
    """빌드 산출물과 이진 인덱스를 탐색·복사 대상에서 처음부터 제외한다."""
    files = [raw / "results.json"]
    for name in ("setup", "runs"):
        for path in bounded_walk(raw / name, raw):
            if path.suffix in TEXT_SUFFIXES or (
                name == "setup"
                and path.relative_to(raw / name).as_posix() in {"indexstore-Package.resolved", "cartograph.yml"}
            ):
                files.append(path)
    fixture_root = raw / "fixtures"
    if fixture_root.is_symlink():
        block("symlink-directory", "fixtures")
    if fixture_root.exists():
        for case in sorted(fixture_root.iterdir()):
            if case.is_symlink():
                block("symlink-directory", str(case.relative_to(raw)))
            if not case.is_dir():
                continue
            files.extend(path for path in bounded_walk(case / "Sources", raw) if path.suffix == ".swift")
            for relative in ("oracle.json", ".cartograph.yml", ".build/output-file-map.json"):
                path = case / relative
                if path.exists() or path.is_symlink():
                    files.append(path)
    selected = sorted(set(files))
    if len(selected) > MAX_FILES:
        block("file-count-limit", "bundle")
    total = 0
    for path in selected:
        relative = str(path.relative_to(raw))
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(raw):
            block("missing-nonregular-or-symlink-artifact", relative)
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            block("per-file-size-limit", relative)
        total += size
    if total > MAX_TOTAL_BYTES:
        block("total-size-limit", "bundle")
    return selected


class Normalizer:
    """선언된 경로 접두사만 치환하고 모르는 절대 경로는 공개 전에 차단한다."""

    def __init__(self, args: argparse.Namespace, raw: Path, selected: list[Path]):
        self.raw = raw
        self.selected = {str(path.relative_to(raw)) for path in selected}
        self.mappings: list[tuple[str, str]] = []
        self.mapping_manifest = []
        explicit = [("--input", args.input, "$EVIDENCE"), ("--output", args.output, "$PUBLIC_BUNDLE")]
        labels = {"EVIDENCE", "PUBLIC_BUNDLE"}
        for specification in args.prefix:
            label, separator, value = specification.partition("=")
            if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,31}", label) or label in labels:
                raise PublicationBlocked("--prefix requires a unique LABEL=ABSOLUTE_PATH")
            labels.add(label)
            explicit.append((f"--prefix:{label}", Path(value), f"${label}"))
        seen = {}
        for argument, path, token in explicit:
            if not path.is_absolute():
                raise PublicationBlocked(f"{argument} must be absolute")
            aliases = {str(path.absolute()).rstrip("/"), str(path.resolve()).rstrip("/")}
            if "" in aliases:
                raise PublicationBlocked("Filesystem root cannot be a normalization prefix")
            for alias in aliases:
                if alias in seen and seen[alias] != token:
                    raise PublicationBlocked("Different normalization roles have the same prefix")
                seen[alias] = token
                self.mappings.append((alias, token))
            self.mapping_manifest.append(
                {
                    "argument": argument,
                    "token": token,
                    "source": "explicit",
                    "provided_prefix_sha256": digest(str(path).encode()),
                    "alias_prefix_sha256": sorted(digest(alias.encode()) for alias in aliases),
                }
            )
        for prefix, token in SYSTEM_PREFIXES.items():
            self.mappings.append((prefix, token))
            self.mapping_manifest.append({"prefix": prefix, "token": token, "source": "fixed-system-prefix"})
        self.mappings.sort(key=lambda item: len(item[0]), reverse=True)
        self.command = ["normalize-indexstore-evidence.py"]
        for argument, _, token in explicit:
            if argument.startswith("--prefix:"):
                self.command.extend(["--prefix", argument.split(":", 1)[1] + "=" + token])
            else:
                self.command.extend([argument, token])

    def string(self, value: str, relative: str, key: str | None = None) -> str:
        check_sensitive(value, relative)
        if key in LOG_REFERENCE_KEYS and value.startswith("/"):
            path = Path(value).resolve()
            if path.is_relative_to(self.raw):
                reference = str(path.relative_to(self.raw))
                if reference not in self.selected:
                    block("log-reference-not-in-public-bundle", relative, value)
                return reference
        for prefix, token in self.mappings:
            pattern = re.compile(
                r"(?:(?<![A-Za-z0-9_$/])|(?<=-[ILF])|(?<=file://))" + re.escape(prefix) + r"""(?=$|[/\s"'`:,;)\]}])"""
            )
            value = pattern.sub(lambda _: token, value)
        path_text = URL.sub("PUBLIC_URL", value).replace("file://", "")
        # index-dump가 출력한 나눗셈 연산자 이름은 파일 경로가 아니다.
        path_text = re.sub(r"(?m)^((?:\d+:\d+ \| )?)/(?=\([^\n|]*\) \| )", r"\1SWIFT_DIVISION_OPERATOR", path_text)
        # Clang 도움말의 고정 옵션 표기는 경로가 아니다. 해당 토큰만 가리고
        # 같은 줄이나 다른 위치에 있는 경로/비밀값 검사는 그대로 둔다.
        if relative == "setup/clang-frontend-help.stdout":
            path_text = re.sub(
                r"(?m)^([ \t]+--show-includes[ \t]+Print cl\.exe style )/showIncludes(?= to stdout[ \t]*$)",
                r"\1CLANG_SHOW_INCLUDES_OPTION",
                path_text,
            )
        windows_path = re.search(r"(?:[A-Za-z]:[\\/]|\\\\[A-Za-z0-9])", path_text)
        if windows_path:
            block("unmapped-windows-absolute-path", relative, windows_path.group())
        match = ABSOLUTE_PATH.search(path_text)
        if match:
            block("unmapped-absolute-path", relative, match.group("path"))
        return value

    def value(self, value: Any, relative: str, key: str | None = None) -> Any:
        if isinstance(value, str):
            return self.string(value, relative, key)
        if isinstance(value, list):
            return [self.value(item, relative) for item in value]
        if isinstance(value, dict):
            if len(ENVIRONMENT_KEYS.intersection(value)) >= 3:
                block("possible-json-environment-dump", relative)
            result = {}
            for name, item in value.items():
                if re.sub(r"[^a-z0-9]", "", name.lower()) in CREDENTIAL_KEYS:
                    block("credential-json-field", relative, name)
                normalized_name = self.string(name, relative)
                if normalized_name in result:
                    block("normalized-json-key-collision", relative)
                result[normalized_name] = self.value(item, relative, name)
            return result
        return value

    def file(self, path: Path) -> bytes:
        relative = str(path.relative_to(self.raw))
        check_sensitive(relative, relative)
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            block("non-utf8-or-binary-content", relative)
        check_sensitive(text, relative)
        mandatory_json = path.suffix == ".json" or path.name == "indexstore-Package.resolved"
        candidate_json = mandatory_json or text.lstrip().startswith(("{", "["))
        if candidate_json:
            try:
                parsed = strict_json(text)
            except (ValueError, json.JSONDecodeError, RecursionError):
                if mandatory_json:
                    block("invalid-or-ambiguous-json", relative)
            else:
                normalized = self.value(parsed, relative)
                return (
                    json.dumps(normalized, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
                ).encode()
        return self.string(text, relative).encode("utf-8")


def package(args: argparse.Namespace) -> dict[str, Any]:
    raw, output = args.input.resolve(), args.output.resolve()
    if not raw.is_dir():
        raise PublicationBlocked("--input must be an existing evidence directory")
    if output.is_relative_to(raw) or raw.is_relative_to(output):
        raise PublicationBlocked("Raw and public directories must not overlap")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise PublicationBlocked("--output must be absent or empty")
    selected = select_files(raw)
    normalizer = Normalizer(args, raw, selected)
    prepared, entries = [], []
    normalized_total = 0
    for path in selected:
        relative = str(path.relative_to(raw))
        original = path.read_bytes()
        normalized = normalizer.file(path)
        normalized_total += len(normalized)
        if len(normalized) > MAX_FILE_BYTES or normalized_total > MAX_TOTAL_BYTES:
            block("normalized-size-limit", relative)
        if path.read_bytes() != original:
            block("raw-evidence-changed-during-normalization", relative)
        prepared.append((relative, normalized))
        entries.append(
            {
                "path": relative,
                "original_raw_sha256": digest(original),
                "normalized_sha256": digest(normalized),
                "original_bytes": len(original),
                "normalized_bytes": len(normalized),
            }
        )
    manifest = {
        "schema_version": 1,
        "status": "normalized_for_review",
        "source_raw_unchanged": True,
        "command": normalizer.command,
        "prefix_mappings": normalizer.mapping_manifest,
        "files": entries,
        "limits": {
            "maximum_files": MAX_FILES,
            "maximum_file_bytes": MAX_FILE_BYTES,
            "maximum_total_bytes": MAX_TOTAL_BYTES,
        },
        "excluded": ["binary index records", "build objects", "executables", "dependency checkouts", "global caches"],
        "privacy_note": (
            "Only declared path prefixes and fixed system paths were normalized. "
            "Unknown absolute paths and configured sensitive-content patterns block generation. "
            "Automated screening is not a guarantee that arbitrary text is private; review before publication."
        ),
    }
    # 전체 검증이 끝나기 전에는 공개 디렉터리에 일부 원문조차 쓰지 않는다.
    for entry in entries:
        if digest((raw / entry["path"]).read_bytes()) != entry["original_raw_sha256"]:
            block("raw-evidence-changed-during-normalization", entry["path"])
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise PublicationBlocked("Output changed while preparing evidence")
    for relative, normalized in prepared:
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(normalized)
    with (output / "manifest.json").open("x", encoding="utf-8") as stream:
        json.dump(manifest, stream, sort_keys=True, indent=2, ensure_ascii=False)
        stream.write("\n")
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Create a bounded, path-normalized public evidence bundle; raw input is unchanged."
    )
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prefix", action="append", default=[], metavar="LABEL=ABSOLUTE_PATH")
    args = parser.parse_args(argv)
    try:
        manifest = package(args)
    except PublicationBlocked as error:
        print(f"Public evidence blocked: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"Public evidence blocked: filesystem error {error.errno}; no raw fallback is allowed", file=sys.stderr)
        return 2
    print(json.dumps({"status": manifest["status"], "files": len(manifest["files"]), "manifest": "manifest.json"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
