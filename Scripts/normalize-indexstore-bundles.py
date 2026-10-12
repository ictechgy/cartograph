#!/usr/bin/env python3
"""독립적인 공개 증거를 원자적으로 보존하고 차단된 묶음은 안전한 지문만 남긴다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import sys
import tempfile
from typing import Any

SCRIPT = Path(__file__).with_name("normalize-indexstore-evidence.py")
SPEC = importlib.util.spec_from_file_location("normalize_indexstore_evidence", SCRIPT)
assert SPEC and SPEC.loader
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)

BUNDLES = ("synthetic", "argument-parser", "mixed-setup", "mixed-ios")
SAFE_REASONS = {
    "unexpected-control-or-binary-content",
    "private-key",
    "aws-key",
    "github-token",
    "slack-token",
    "api-token",
    "bearer-token",
    "email-address",
    "credential-url",
    "secret-assignment",
    "secret-argument",
    "environment-dump",
    "credential-field-or-assignment",
    "possible-environment-dump",
    "invalid-url",
    "token-bearing-or-signed-url",
    "symlink-directory",
    "file-count-limit",
    "missing-nonregular-or-symlink-artifact",
    "per-file-size-limit",
    "total-size-limit",
    "log-reference-not-in-public-bundle",
    "unmapped-windows-absolute-path",
    "unmapped-absolute-path",
    "possible-json-environment-dump",
    "credential-json-field",
    "normalized-json-key-collision",
    "non-utf8-or-binary-content",
    "invalid-or-ambiguous-json",
    "normalized-size-limit",
    "raw-evidence-changed-during-normalization",
    "input-must-be-absolute",
    "input-not-directory",
    "synthetic-prefix-conflict",
}


def fingerprint(value: str) -> str:
    """이름과 오류 원문을 공개하지 않고 같은 입력의 재현 여부만 비교한다."""
    return hashlib.sha256(value.encode("utf-8", errors="surrogatepass")).hexdigest()


def diagnostic(error: Exception) -> dict[str, Any]:
    """예외에는 경로나 비밀이 들어갈 수 있으므로 고정 사유와 해시만 공개한다."""
    reason = "unexpected-normalization-error"
    if isinstance(error, EVIDENCE.PublicationBlocked):
        candidate = getattr(error, "reason", None)
        if candidate is None and str(error) in SAFE_REASONS:
            candidate = str(error)
        reason = candidate if isinstance(candidate, str) and candidate in SAFE_REASONS else "normalization-blocked"
    result = {"reason": reason, "error_sha256": fingerprint(str(error))}
    if isinstance(error, EVIDENCE.PublicationBlocked) and reason in SAFE_REASONS:
        for attribute, field in (
            ("artifact_sha256", "artifact_identifier_sha256"),
            ("value_sha256", "offending_value_sha256"),
        ):
            value = getattr(error, attribute, None)
            if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value):
                result[field] = value
    if isinstance(error, OSError):
        result["reason"] = "filesystem-error"
        if isinstance(error.errno, int):
            result["errno"] = error.errno
    return result


def raw_inventory(raw: Path) -> dict[str, Any]:
    """정규화 허용 목록의 제한 안에서 원문 대신 파일 이름과 내용의 지문만 남긴다."""
    entries, total = [], 0
    for path in EVIDENCE.select_files(raw):
        with path.open("rb") as stream:
            data = stream.read(EVIDENCE.MAX_FILE_BYTES + 1)
        total += len(data)
        if len(data) > EVIDENCE.MAX_FILE_BYTES:
            EVIDENCE.block("per-file-size-limit", "bundle")
        if total > EVIDENCE.MAX_TOTAL_BYTES:
            EVIDENCE.block("total-size-limit", "bundle")
        entries.append(
            {
                "relative_path_sha256": fingerprint(path.relative_to(raw).as_posix()),
                "original_raw_sha256": hashlib.sha256(data).hexdigest(),
                "original_bytes": len(data),
            }
        )
    return {
        "status": "hashed",
        "scope": "normalizer-selected-text-candidates",
        "file_count": len(entries),
        "total_bytes": total,
        "files": sorted(entries, key=lambda item: item["relative_path_sha256"]),
    }


def bundle_prefixes(name: str, args: argparse.Namespace) -> list[str]:
    """프로젝트 전용 역할이 synthetic 묶음의 EVIDENCE 역할과 충돌하지 않게 분리한다."""
    prefixes = [value for value in args.prefix if value.partition("=")[0] != "SYNTHETIC_EVIDENCE"]
    if name != "argument-parser":
        return prefixes
    project = [value for value in args.prefix if value.partition("=")[0] == "SYNTHETIC_EVIDENCE"]
    if len(project) > 1:
        raise EVIDENCE.PublicationBlocked("synthetic-prefix-conflict")
    if project and args.synthetic is not None:
        supplied = Path(project[0].partition("=")[2])
        if supplied.resolve() != args.synthetic.resolve():
            raise EVIDENCE.PublicationBlocked("synthetic-prefix-conflict")
    if project:
        prefixes.extend(project)
    elif args.synthetic is not None:
        prefixes.append("SYNTHETIC_EVIDENCE=" + str(args.synthetic))
    return prefixes


def verify_inventory(inventory: dict[str, Any], manifest: dict[str, Any]) -> None:
    """차단 진단용으로 읽은 입력과 실제 정규화한 입력이 다른 경우 공개를 멈춘다."""
    actual = sorted(
        (fingerprint(item["path"]), item["original_raw_sha256"], item["original_bytes"]) for item in manifest["files"]
    )
    expected = sorted(
        (item["relative_path_sha256"], item["original_raw_sha256"], item["original_bytes"])
        for item in inventory["files"]
    )
    if actual != expected:
        EVIDENCE.block("raw-evidence-changed-during-normalization", "bundle")


def normalize_bundle(name: str, args: argparse.Namespace, pending: Path, ready: Path) -> dict[str, Any]:
    """실패 중간 파일은 비공개 영역에 두고 완전히 검증된 묶음만 최종 트리로 옮긴다."""
    source = getattr(args, name.replace("-", "_"))
    entry = {"name": name, "status": "skipped", "diagnostic": {"reason": "input-not-requested"}}
    if source is None:
        return entry
    entry = {
        "name": name,
        "status": "blocked",
        "input_path_sha256": fingerprint(str(source)),
        "raw_inventory": {"status": "unavailable", "scope": "normalizer-selected-text-candidates"},
    }
    try:
        if not source.is_absolute():
            raise EVIDENCE.PublicationBlocked("input-must-be-absolute")
        try:
            source.lstat()
        except FileNotFoundError:
            entry.update(status="unavailable", diagnostic={"reason": "input-missing"})
            return entry
        raw = source.resolve()
        if not raw.is_dir():
            raise EVIDENCE.PublicationBlocked("input-not-directory")
        entry["raw_inventory"] = raw_inventory(raw)
        manifest = EVIDENCE.package(
            argparse.Namespace(input=source, output=pending / name, prefix=bundle_prefixes(name, args))
        )
        verify_inventory(entry["raw_inventory"], manifest)
        os.replace(pending / name, ready / name)
        entry.update(status="normalized_for_review", manifest=name + "/manifest.json")
    except Exception as error:
        entry["diagnostic"] = diagnostic(error)
    return entry


def check_output(output: Path) -> None:
    """이전 결과나 링크를 덮어써 공개 안전성이 확인되지 않은 파일을 재사용하지 않는다."""
    if not output.is_absolute():
        raise EVIDENCE.PublicationBlocked("Output must be absolute")
    if output.is_symlink() or (output.exists() and (not output.is_dir() or any(output.iterdir()))):
        raise EVIDENCE.PublicationBlocked("Output must be absent or an empty non-symlink directory")


def package(args: argparse.Namespace) -> dict[str, Any]:
    """최종 상태 파일까지 준비한 뒤 공개 루트 전체를 한 번에 원자적으로 교체한다."""
    check_output(args.output)
    output = args.output.resolve()
    github_output = args.github_output.resolve() if args.github_output is not None else None
    if github_output is not None and github_output.is_relative_to(output):
        raise EVIDENCE.PublicationBlocked("GitHub output must not overlap public evidence")
    for name in BUNDLES:
        source = getattr(args, name.replace("-", "_"))
        if source is not None:
            try:
                raw = source.resolve()
            except (OSError, RuntimeError, ValueError):
                # 해석할 수 없는 입력은 아래 묶음별 처리에서 안전한 실패 진단으로 남긴다.
                continue
            if github_output is not None and github_output.is_relative_to(raw):
                raise EVIDENCE.PublicationBlocked("GitHub output must not overlap raw evidence")
            if output.is_relative_to(raw) or raw.is_relative_to(output):
                raise EVIDENCE.PublicationBlocked("Raw and public directories must not overlap")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".indexstore-public-", dir=output.parent) as temporary:
        staging = Path(temporary)
        pending, ready = staging / "pending", staging / "ready"
        pending.mkdir()
        ready.mkdir()
        bundles = [normalize_bundle(name, args, pending, ready) for name in BUNDLES]
        blocked = sum(item["status"] == "blocked" for item in bundles)
        manifest = {
            "schema_version": 1,
            "status": "publication_prepared_with_blocked_bundles" if blocked else "publication_prepared",
            "normalized_bundles": sum(item["status"] == "normalized_for_review" for item in bundles),
            "blocked_bundles": blocked,
            "unavailable_bundles": sum(item["status"] == "unavailable" for item in bundles),
            "skipped_bundles": sum(item["status"] == "skipped" for item in bundles),
            "complete_run_evidence": False,
            "bundles": bundles,
            "raw_fallback": False,
            "privacy_note": (
                "Only complete normalized bundles are included. Failed inputs have fixed diagnostic categories "
                "and bounded selected-input hashes where available; raw logs and binary indexes are never copied. "
                "Publication status does not assert benchmark or native validation success. "
                "Automated screening is not a guarantee that arbitrary text is private; review before publication."
            ),
        }
        with (ready / "bundle-status.json").open("x", encoding="utf-8") as stream:
            json.dump(manifest, stream, sort_keys=True, indent=2, ensure_ascii=True, allow_nan=False)
            stream.write("\n")
        check_output(args.output)
        if args.output.resolve() != output:
            raise EVIDENCE.PublicationBlocked("Output changed while preparing evidence")
        os.replace(ready, output)
    return manifest


def main(argv: list[str] | None = None) -> int:
    """공개 가능한 독립 묶음이 있어도 기존 입력 하나가 차단되면 CI 실패를 유지한다."""
    parser = argparse.ArgumentParser(
        description="Publish independent normalized evidence bundles without raw fallback."
    )
    parser.add_argument("--output", type=Path, required=True)
    for name in BUNDLES:
        parser.add_argument("--" + name, type=Path, help="Optional evidence directory; missing inputs are unavailable.")
    parser.add_argument(
        "--prefix",
        action="append",
        default=[],
        metavar="LABEL=ABSOLUTE_PATH",
        help="Normalization prefix; SYNTHETIC_EVIDENCE applies only to argument-parser.",
    )
    parser.add_argument("--github-output", type=Path, help="Set ready=true only after atomic safe publication.")
    args = parser.parse_args(argv)
    try:
        manifest = package(args)
        if args.github_output is not None:
            with args.github_output.open("a", encoding="utf-8") as stream:
                stream.write("ready=true\n")
    except Exception as error:
        print(
            json.dumps({"status": "publication-blocked", "diagnostic": diagnostic(error)}, sort_keys=True),
            file=sys.stderr,
        )
        return 2
    print(
        json.dumps(
            {
                "status": manifest["status"],
                "normalized_bundles": manifest["normalized_bundles"],
                "blocked_bundles": manifest["blocked_bundles"],
                "unavailable_bundles": manifest["unavailable_bundles"],
                "skipped_bundles": manifest["skipped_bundles"],
                "complete_run_evidence": False,
                "manifest": "bundle-status.json",
            },
            sort_keys=True,
        )
    )
    return 2 if manifest["blocked_bundles"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
