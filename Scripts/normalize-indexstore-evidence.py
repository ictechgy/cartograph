#!/usr/bin/env python3
"""원본 증거를 보존하면서 허용된 텍스트만 별도의 공개 검토 묶음으로 만든다."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
from typing import Any
from urllib.parse import parse_qsl, urlsplit

KNOWN_MEASUREMENT_HELPERS = {
    "03a6cc72657a560e983b95fa99b7df4ff907a6d41f37fcd3692f6ed694d92101",
}
MAX_FILES = 10_000
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
TEXT_SUFFIXES = {".json", ".stdout", ".stderr"}
SAMPLE_JSONL = re.compile(r".+\.samples(?:\.[0-9]{4,})?\.jsonl$")
LOG_REFERENCE_KEYS = {
    "stdout",
    "stderr",
    "log_path",
    "results",
    "normalized_result",
    "graph",
    "setup_results",
    "cg_config",
    "samples",
    "samples_path",
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

    def __init__(
        self,
        message: str,
        *,
        reason: str | None = None,
        artifact_sha256: str | None = None,
        value_sha256: str | None = None,
    ):
        super().__init__(message)
        self.reason = reason
        self.artifact_sha256 = artifact_sha256
        self.value_sha256 = value_sha256


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def block(category: str, relative: str, value: str = "") -> None:
    """문제 원문 대신 위치와 지문만 진단에 남겨 비밀의 재노출을 피한다."""
    signature = digest(value.encode("utf-8"))[:16] if value else "none"
    safe_relative = relative
    if relative.startswith("/") or any(pattern.search(relative) for _, pattern in SENSITIVE_PATTERNS):
        safe_relative = "artifact-sha256-" + digest(relative.encode())[:16]
    raise PublicationBlocked(
        f"{category}; artifact={safe_relative}; value_sha256_prefix={signature}",
        reason=category,
        artifact_sha256=digest(relative.encode("utf-8")),
        value_sha256=digest(value.encode("utf-8")) if value else None,
    )


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

    def finite_float(value: str) -> float:
        parsed = float(value)
        if not math.isfinite(parsed):
            raise ValueError("Non-finite JSON value")
        return parsed

    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant, parse_float=finite_float)


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
            if path.suffix in TEXT_SUFFIXES or SAMPLE_JSONL.fullmatch(path.name) or (
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


def verify_sample_chunks(raw: Path, selected: list[Path]) -> list[str]:
    """분할된 원본 표본이 빠지거나 순서·내용이 바뀌어도 요약만 공개되지 않도록 막는다."""
    verified = []
    selected_set = set(selected)
    for result in selected:
        if result.suffix != ".json":
            continue
        relative = str(result.relative_to(raw))
        try:
            value = strict_json(result.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, ValueError, RecursionError):
            block("invalid-or-ambiguous-json", relative)
        rss = value.get("rss") if isinstance(value, dict) else None
        if not isinstance(rss, dict) or "sample_chunks" not in rss:
            continue
        chunks = rss["sample_chunks"]
        if not isinstance(chunks, list):
            block("sample-chunk-integrity", relative)
        prefix = result.stem + ".samples."
        expected_names = [prefix + f"{number:04d}.jsonl" for number in range(1, len(chunks) + 1)]
        names = [chunk.get("name") if isinstance(chunk, dict) else None for chunk in chunks]
        present_names = sorted(path.name for path in result.parent.glob(result.stem + ".samples*.jsonl"))
        if names != expected_names or present_names != expected_names:
            block("sample-chunk-integrity", relative)
        total_bytes, total_samples = 0, 0
        for chunk in chunks:
            path = result.parent / chunk["name"]
            if path not in selected_set:
                block("sample-chunk-integrity", relative)
            data = path.read_bytes()
            if (
                chunk.get("sha256") != digest(data)
                or type(chunk.get("bytes")) is not int
                or chunk["bytes"] != len(data)
                or type(chunk.get("sample_count")) is not int
                or chunk["sample_count"] != len(data.splitlines())
            ):
                block("sample-chunk-integrity", relative)
            total_bytes += len(data)
            total_samples += len(data.splitlines())
        if (
            type(rss.get("sample_total_bytes")) is not int
            or rss["sample_total_bytes"] != total_bytes
            or type(rss.get("sample_count")) is not int
            or rss["sample_count"] != total_samples
        ):
            block("sample-chunk-integrity", relative)
        verified.append(relative)
    return verified


def has_process_identity(value: Any) -> bool:
    """도우미 결과 안에서 예상하지 못한 위치로 이동한 원시 식별자를 공개하지 않는다."""
    if isinstance(value, dict):
        return bool({"pid", "create_time", "remaining_observed_pids"}.intersection(value)) or any(
            has_process_identity(item) for item in value.values()
        )
    return isinstance(value, list) and any(has_process_identity(item) for item in value)


class Normalizer:
    """선언된 경로 접두사만 치환하고 모르는 절대 경로는 공개 전에 차단한다."""

    def __init__(self, args: argparse.Namespace, raw: Path, selected: list[Path], verified_samples: list[str]):
        self.raw = raw
        self.selected = {str(path.relative_to(raw)) for path in selected}
        self.mappings: list[tuple[str, str]] = []
        self.mapping_manifest = []
        self.helper_identities = {}
        self.helper_sample_paths = set()
        self.verified_samples = set(verified_samples)
        self.omitted_helper_identity_fields = set()
        self.verified_memory_results = {}
        self.embedded_memory_bindings = set()
        for relative in verified_samples:
            value = strict_json((raw / relative).read_text(encoding="utf-8"))
            if (isinstance(value, dict) and isinstance(value.get("helper_sha256"), str)
                    and value["helper_sha256"] in KNOWN_MEASUREMENT_HELPERS
                    and value.get("measurement_mode") == "memory"):
                fingerprint = self.memory_fingerprint(value, relative)
                self.verified_memory_results.setdefault(fingerprint, []).append(relative)
        for result in selected:
            if result.suffix != ".json":
                continue
            relative = str(result.relative_to(raw))
            value = strict_json(result.read_text(encoding="utf-8"))
            self.helper_result(value, relative)
            if (isinstance(value, dict) and isinstance(value.get("helper_sha256"), str)
                    and value["helper_sha256"] in KNOWN_MEASUREMENT_HELPERS):
                if value.get("measurement_mode") == "memory":
                    for chunk in value["rss"]["sample_chunks"]:
                        self.helper_sample_paths.add(str((result.parent / chunk["name"]).relative_to(raw)))
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
        # 원문에서 금지된 NUL 표식은 실제로 치환한 접두사만 구별한다.
        # 공개 문자열에는 기존 토큰을 복원하고 검사용 문자열에서만 경로를 가린다.
        for index, (prefix, _) in enumerate(self.mappings):
            pattern = re.compile(
                r"(?:(?<![A-Za-z0-9_$/\x00])|(?<=-[ILF])|(?<=file://))" + re.escape(prefix) + r"""(?=$|[/\s"'`:,;)\]}])"""
            )
            value = pattern.sub(lambda _, index=index: f"\x00{index}\x00", value)
        marked_value = value
        value = re.sub(r"\x00([0-9]+)\x00", lambda match: self.mappings[int(match[1])][1], value)
        path_text = URL.sub("PUBLIC_URL", marked_value).replace("file://", "")
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
        if relative == "setup/swift-help.stdout":
            # Swift 도움말의 정확한 예시/언어 이름만 다룬다. 일반 자리표시자나
            # 경로 접두사는 허용하지 않고 토큰 앞뒤의 원문 검사도 유지한다.
            path_text = re.sub(
                r"(?m)^([ \t]+Generate instrumented code to collect (?:context sensitive )?"
                r"execution counts into <directory>)/default\.profraw"
                r"(?= \(overridden by LLVM_PROFILE_FILE env var\)[ \t]*$)",
                r"\1SWIFT_DEFAULT_PROFILE_FILE",
                path_text,
            )
            path_text = re.sub(
                r"(?m)^([ \t]+-Xcc <arg>[ \t]+Pass <arg> to the C/C\+\+)/Objective-C(?= compiler[ \t]*$)",
                r"\1SWIFT_OBJC_LANGUAGE",
                path_text,
            )
        windows_path = re.search(r"(?:[A-Za-z]:[\\/]|\\\\[A-Za-z0-9])", path_text)
        if windows_path:
            block("unmapped-windows-absolute-path", relative, windows_path.group())
        def mapped_path(match: re.Match[str]) -> str:
            # '..'는 선언된 루트 안에서만 허용한다. 뒤따르는 별도 경로나
            # 모호한 문장부호는 가리지 않아 아래의 기존 검사를 계속 받는다.
            prefix = self.mappings[int(match["mapping"])][0]
            spelling = prefix + match["suffix"]
            # 더 구체적인 별칭의 형제 이름에 넓은 조상 루트의 신뢰를 주지 않는다.
            for narrower, _ in self.mappings:
                if (len(narrower) > len(prefix) and spelling.startswith(narrower)
                        and len(spelling) > len(narrower) and spelling[len(narrower)] != "/"):
                    block("unmapped-absolute-path", relative, spelling)
            depth = 0
            for component in match["suffix"].split("/"):
                if component == "..":
                    depth -= 1
                    if depth < 0:
                        block("unmapped-absolute-path", relative, value)
                elif component not in ("", "."):
                    depth += 1
            return "MAPPED_PATH"

        path_text = re.sub(
            r"\x00(?P<mapping>[0-9]+)\x00(?P<suffix>(?:/[A-Za-z0-9_.+-]+)*/?)"
            r"(?=$|[\s\"'`<>|,;)}\]:=])",
            mapped_path,
            path_text,
        )
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
            value = self.helper_result(value, relative)
            if "remaining_observed_pids" in value or {"process_id", "pid", "rss_bytes"} <= set(value):
                block("helper-process-identity-unbound", relative)
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

    def helper_sample(self, parsed: dict, relative: str) -> dict:
        schema = {"start_seconds", "end_seconds", "rss_bytes", "process_count", "processes"}
        if relative not in self.helper_sample_paths:
            if "processes" in parsed or has_process_identity(parsed) or set(parsed) == schema:
                block("helper-process-identity-unbound", relative)
            return parsed
        if set(parsed) != schema or any(
            type(parsed[key]) not in (int, float) or not math.isfinite(parsed[key]) or parsed[key] < 0
            for key in ("start_seconds", "end_seconds")
        ) or parsed["end_seconds"] < parsed["start_seconds"]:
            block("helper-process-identity-schema", relative)
        members = parsed["processes"]
        if (
            not isinstance(members, list)
            or type(parsed["process_count"]) is not int
            or parsed["process_count"] != len(members)
        ):
            block("helper-process-identity-schema", relative)
        run = re.sub(r"\.samples(?:\.[0-9]{4,})?\.jsonl$", "", relative)
        identities = self.helper_identities.setdefault(run, {})
        observed, observed_pids, normalized = set(), set(), []
        for member in members:
            if not isinstance(member, dict) or set(member) != {"process_id", "pid", "create_time", "rss_bytes"}:
                block("helper-process-identity-schema", relative)
            identity, pid, rss = member["process_id"], member["pid"], member["rss_bytes"]
            created = member.get("create_time")
            if (
                type(identity) is not int
                or identity < 1
                or identity in observed
                or type(pid) is not int
                or pid < 1
                or pid in observed_pids
                or type(rss) is not int
                or rss < 0
                or type(created) not in (int, float)
                or not math.isfinite(created)
                or created <= 0
            ):
                block("helper-process-identity-schema", relative)
            raw_identity = (pid, created)
            if identity in identities and identities[identity] != raw_identity:
                block("helper-process-identity-reassigned", relative)
            if created is not None and any(
                key != identity and value == raw_identity for key, value in identities.items()
            ):
                block("helper-process-identity-not-injective", relative)
            identities[identity] = raw_identity
            observed.add(identity)
            observed_pids.add(pid)
            normalized.append({"process_id": identity, "rss_bytes": rss})
            self.omitted_helper_identity_fields.add("processes[].pid")
            if "create_time" in member:
                self.omitted_helper_identity_fields.add("processes[].create_time")
        if type(parsed["rss_bytes"]) is not int or parsed["rss_bytes"] != sum(item["rss_bytes"] for item in normalized):
            block("helper-process-identity-rss-sum", relative)
        return {**parsed, "processes": normalized}

    def memory_fingerprint(self, value: dict, relative: str) -> str:
        """중첩 사본은 전체 원본과 일치해야 하며 호출자 측 경과 시간만 추가할 수 있다."""
        if "caller_elapsed_seconds" in value:
            elapsed = value["caller_elapsed_seconds"]
            if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or elapsed < 0:
                block("helper-process-identity-schema", relative)
        payload = {key: item for key, item in value.items() if key != "caller_elapsed_seconds"}
        return digest(json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode())

    def helper_result(self, parsed: Any, relative: str) -> Any:
        """알려진 도우미의 검증된 구조에서만 식별자를 제거하고 알 수 없는 결과는 차단한다."""
        if not isinstance(parsed, dict):
            return parsed
        cleanup = parsed.get("cleanup")
        looks_like_helper = (
            ("measurement_mode" in parsed and "helper_sha256" in parsed and "schema_version" in parsed)
            or (parsed.get("measurement_mode") in ("timing", "memory")
                and ("rss" in parsed or "schema_version" in parsed))
            or isinstance(cleanup, dict) and "remaining_observed_pids" in cleanup
        )
        if not looks_like_helper:
            return parsed
        helper = parsed.get("helper_sha256")
        if not isinstance(helper, str) or helper not in KNOWN_MEASUREMENT_HELPERS:
            block("helper-process-identity-unbound", relative)
        if type(parsed.get("schema_version")) is not int or parsed["schema_version"] != 2:
            block("helper-process-identity-schema", relative)
        mode, rss = parsed.get("measurement_mode"), parsed.get("rss")
        if mode == "memory":
            if (not isinstance(rss, dict)
                    or rss.get("metric") != "observed_sampled_near_simultaneous_process_tree_rss_bytes"):
                block("helper-process-identity-unbound", relative)
            candidates = self.verified_memory_results.get(self.memory_fingerprint(parsed, relative), [])
            if relative not in candidates:
                if len(candidates) != 1:
                    block("helper-process-identity-unbound", relative)
                self.embedded_memory_bindings.add((relative, candidates[0]))
        elif mode != "timing" or rss is not None:
            block("helper-process-identity-schema", relative)
        if cleanup is None:
            if has_process_identity(parsed):
                block("helper-process-identity-schema", relative)
            return parsed
        if not isinstance(cleanup, dict) or set(cleanup) != {"method", "seconds", "remaining_observed_pids"}:
            block("helper-process-identity-cleanup", relative)
        if (cleanup["method"] != "identity_checked_individual_TERM_then_STOP_discover_KILL; process-group independent"
                or type(cleanup["seconds"]) not in (int, float)
                or not math.isfinite(cleanup["seconds"]) or cleanup["seconds"] < 0):
            block("helper-process-identity-cleanup", relative)
        remaining = cleanup["remaining_observed_pids"]
        if (not isinstance(remaining, list) or any(type(pid) is not int or pid < 1 for pid in remaining)
                or len(set(remaining)) != len(remaining)):
            block("helper-process-identity-cleanup", relative)
        normalized = {key: value for key, value in cleanup.items() if key != "remaining_observed_pids"}
        normalized.update(
            remaining_observed_process_count=len(remaining), remaining_identity_unresolved=bool(remaining)
        )
        self.omitted_helper_identity_fields.add("cleanup.remaining_observed_pids")
        result = {**parsed, "cleanup": normalized}
        if has_process_identity(result):
            block("helper-process-identity-schema", relative)
        return result

    def file(self, path: Path) -> bytes:
        relative = str(path.relative_to(self.raw))
        check_sensitive(relative, relative)
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            block("non-utf8-or-binary-content", relative)
        check_sensitive(text, relative)
        if SAMPLE_JSONL.fullmatch(path.name):
            normalized_lines = []
            for line in text.splitlines():
                try:
                    parsed = strict_json(line)
                    if not isinstance(parsed, dict):
                        raise ValueError("Samples must be JSON objects")
                except (ValueError, json.JSONDecodeError, RecursionError):
                    block("invalid-or-ambiguous-jsonl", relative)
                normalized_lines.append(
                    json.dumps(
                        self.value(self.helper_sample(parsed, relative), relative),
                        sort_keys=True,
                        ensure_ascii=False,
                        allow_nan=False,
                    )
                )
            return "".join(line + "\n" for line in normalized_lines).encode("utf-8")
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
    verified_samples = verify_sample_chunks(raw, selected)
    normalizer = Normalizer(args, raw, selected, verified_samples)
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
        "verified_sample_chunk_results": verified_samples,
        "omitted_helper_identity_fields": sorted(normalizer.omitted_helper_identity_fields),
        "identity_normalized_sample_chunks": sorted(normalizer.helper_sample_paths),
        "embedded_memory_result_bindings": [
            {"artifact": artifact, "verified_standalone_result": result}
            for artifact, result in sorted(normalizer.embedded_memory_bindings)
        ],
        "sample_hash_policy": (
            "Embedded sample chunk hashes describe unchanged raw inputs; "
            "use manifest normalized_sha256 for public derivatives."
        ),
        "limits": {
            "maximum_files": MAX_FILES,
            "maximum_file_bytes": MAX_FILE_BYTES,
            "maximum_total_bytes": MAX_TOTAL_BYTES,
        },
        "excluded": ["binary index records", "build objects", "executables", "dependency checkouts", "global caches"],
        "privacy_note": (
            "Declared path prefixes and fixed system paths were normalized; "
            "listed verified-helper identity metadata was omitted. "
            "Unknown absolute paths and configured sensitive-content patterns block generation. "
            "Automated screening is not a guarantee that arbitrary text is private; review before publication."
        ),
    }
    # 전체 검증이 끝나기 전에는 공개 디렉터리에 일부 원문조차 쓰지 않는다.
    if verify_sample_chunks(raw, selected) != verified_samples:
        block("sample-chunk-integrity-changed", "bundle")
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
