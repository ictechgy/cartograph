#!/usr/bin/env python3
"""공개된 파일만 포함한 고정 pilot 증거 ZIP과 정규화 지문을 제한 안에서 검증한다."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile

ROOT = Path(__file__).resolve().parents[1] / "docs/evaluation/evidence/2026-10-12"
MAX_COMPRESSED = 8 * 1024 * 1024
MAX_UNCOMPRESSED = 64 * 1024 * 1024
MAX_MEMBER = 8 * 1024 * 1024
MAX_FILES = 10_000


def verify_auxiliary(member: str, bundle: dict, data: bytes) -> None:
    """명시적으로 검토한 SDK·실제 팔의 공개 영수증만 상태 인벤토리와 함께 허용한다."""
    if member == "bundle-status.json":
        return
    contracts = {
        "sdk-input-discovery": ("sdk-discovery", ([], ["discovery/manifest.json"])),
        "actual-arm-correctness-validation": ("actual-arm-correctness", ([],)),
    }
    kind = bundle.get("artifact_kind")
    if kind not in contracts:
        raise ValueError("Unexpected auxiliary evidence path")
    role_prefix, manifests = contracts[kind]
    roles = {
        "attempt.json": role_prefix + "-attempt-envelope",
        "publication-status.json": role_prefix + "-publication-envelope",
    }
    if member not in roles or bundle["manifests"] not in manifests:
        raise ValueError("Unexpected auxiliary evidence path")
    value = json.loads(data)
    if (
        not isinstance(value, dict)
        or type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
        or value.get("role") != roles[member]
    ):
        raise ValueError("Unexpected auxiliary envelope role")
    if member == "publication-status.json" and (
        value.get("raw_fallback") is not False or value.get("complete_run_evidence") is not False
    ):
        raise ValueError("Unexpected auxiliary publication policy")


def verify(root: Path = ROOT) -> dict:
    inventory = json.loads((root / "bundles.json").read_text())
    archives, normalized, auxiliary = [], 0, 0
    total_compressed, total_uncompressed = 0, 0
    for bundle in inventory["bundles"]:
        name = bundle["archive"]
        if Path(name).name != name or not name.endswith("-normalized.zip"):
            raise ValueError("Unexpected archive path")
        path = root / name
        if path.is_symlink() or path.stat().st_size > MAX_COMPRESSED:
            raise ValueError("Archive exceeds bound or is a symlink")
        content = path.read_bytes()
        if len(content) != bundle["compressed_bytes"] or hashlib.sha256(content).hexdigest() != bundle["sha256"]:
            raise ValueError("Archive bytes differ from reviewed inventory")
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            names = [entry.filename for entry in entries]
            size = sum(entry.file_size for entry in entries)
            if len(names) != len(set(names)) or len(names) > MAX_FILES or size > MAX_UNCOMPRESSED:
                raise ValueError("Duplicate entries or archive bounds exceeded")
            if size != bundle["uncompressed_bytes"] or len(names) != bundle["archive_entries"]:
                raise ValueError("Archive dimensions changed")
            for entry in entries:
                relative = PurePosixPath(entry.filename)
                if (
                    relative.is_absolute()
                    or ".." in relative.parts
                    or "\\" in entry.filename
                    or entry.is_dir()
                    or (entry.external_attr >> 16) & 0o170000 == 0o120000
                    or entry.file_size > MAX_MEMBER
                ):
                    raise ValueError("Unsafe or oversized ZIP member")
                archive.read(entry).decode("utf-8")
            selected = set(bundle["manifests"])
            verified = 0
            for manifest_name in bundle["manifests"]:
                manifest = json.loads(archive.read(manifest_name))
                prefix = PurePosixPath(manifest_name).parent
                for record in manifest["files"]:
                    member = str(prefix / record["path"])
                    if member in selected:
                        raise ValueError("Duplicated normalized evidence reference")
                    data = archive.read(member)
                    if (
                        len(data) != record["normalized_bytes"]
                        or hashlib.sha256(data).hexdigest() != record["normalized_sha256"]
                    ):
                        raise ValueError("Normalized evidence bytes changed")
                    selected.add(member)
                    verified += 1
            for record in bundle.get("auxiliary_files", []):
                member = record["path"]
                if member in selected:
                    raise ValueError("Duplicated auxiliary evidence reference")
                if member not in names:
                    raise ValueError("Missing auxiliary evidence")
                data = archive.read(member)
                verify_auxiliary(member, bundle, data)
                if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
                    raise ValueError("Auxiliary evidence bytes changed")
                selected.add(member)
                auxiliary += 1
            if selected != set(names) or verified != bundle["verified_normalized_files"]:
                raise ValueError("Missing or unmanifested public artifact")
        normalized += verified
        total_compressed += len(content)
        total_uncompressed += size
        archives.append(name)
    if (
        total_compressed != inventory["total_compressed_bytes"]
        or total_uncompressed != inventory["total_uncompressed_bytes"]
    ):
        raise ValueError("Combined bundle sizes changed")
    return {
        "archives": len(archives),
        "auxiliary_files": auxiliary,
        "normalized_files": normalized,
        "compressed_bytes": total_compressed,
        "uncompressed_bytes": total_uncompressed,
        "superiority_claim": None,
    }


if __name__ == "__main__":
    print(json.dumps(verify(), sort_keys=True))
