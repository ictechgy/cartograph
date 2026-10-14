#!/usr/bin/env python3
"""한 후보 SDK 봉인의 전체 항목을 기존 공개 한도 안에서 가역적인 JSON 조각으로 나눈다."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import stat
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("calibration_publication_seal", HERE / "sdk_content_seal.py")
SEAL = importlib.util.module_from_spec(spec)
spec.loader.exec_module(SEAL)
spec = importlib.util.spec_from_file_location("calibration_publication_normalizer",
                                             HERE.parent / "normalize-indexstore-evidence.py")
NORMALIZER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(NORMALIZER)
# 일반 정규화기의 Windows 검사식과 같게 유지하며, 분리 전 전체 문자열에 적용한다.
WINDOWS_PATH = re.compile(r"(?:[A-Za-z]:[\\/]|\\\\[A-Za-z0-9])")
MAX_FILE_BYTES = 8 * 1024**2
MAX_TOTAL_BYTES = 64 * 1024**2
CHUNK_BYTES = 4 * 1024**2
PROJECTION = Path("setup/sdk-content-projection")
SERIALIZATION = ("Entry and symlink-target paths use reversible path_components; all original JSON fields and "
                 "entry order are recovered; original raw bytes are separately hashed.")
NORMALIZATION = "Root paths and other non-entry text may be normalized; public bytes are derivatives."
SOURCES = {
    "before-compilation": "before-compilation/seal.json",
    "after-generation": "after-generation/seal-verification.json",
    "after-calibration": "after-calibration/seal-verification.json",
}


class ProjectionError(ValueError):
    """누락이나 한도 초과를 잘린 성공으로 바꾸지 않는다."""


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ProjectionError(reason)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encoded(value: object) -> bytes:
    """기존 정규화기의 JSON 직렬화와 같게 써 항목 내용의 변화를 검출할 수 있게 한다."""
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode()


def read_document(path: Path, *, limit: int = MAX_FILE_BYTES) -> tuple[dict, dict]:
    """원본은 기존 no-follow 본문 읽기로 제한하며 중복 키를 거부한다."""
    data = SEAL.expected_bytes(path)
    require(len(data) <= limit, "projection-file-byte-limit")
    value = SEAL.strict_expected_json(data)
    return value, dict(bytes=len(data), sha256=digest(data))


def strict_array(data: bytes) -> list:
    """항목 조각도 객체와 같은 중복 키·비유한 수 거부 규칙으로 읽는다."""
    wrapped = SEAL.strict_expected_json(b'{"entries":' + data + b'}')
    require(isinstance(wrapped["entries"], list), "chunk-not-entry-array")
    return wrapped["entries"]


def seal_from_record(label: str, document: dict) -> dict:
    """후검증 원본의 비용·비일치 상태를 보존하고 실제 봉인의 구조만 검증한다."""
    if label == "before-compilation":
        seal = document
    else:
        require(set(document) == {"matches", "expected_sha256", "actual_sha256", "actual", "wall_seconds"},
                "invalid-verification-schema")
        require(type(document["matches"]) is bool, "invalid-verification-status")
        elapsed = document["wall_seconds"]
        require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0, "invalid-verification-cost")
        seal = document["actual"]
        require(document["actual_sha256"] == seal["content_sha256"]
                and document["matches"] == (document["actual_sha256"] == document["expected_sha256"]),
                "incoherent-verification")
    SEAL.validate_expected(seal)
    return seal


def checked_path(value: str, relative: str) -> str:
    """구성 요소 경계로 비밀이나 Windows 경로가 숨지 않도록 원문 전체를 먼저 검사한다."""
    NORMALIZER.check_sensitive(value, relative)
    match = WINDOWS_PATH.search(value)
    if match:
        NORMALIZER.block("unmapped-windows-absolute-path", relative, match.group())
    require(SEAL.valid_relative(value), "invalid-sdk-relative-path")
    return value


def project_entry(entry: dict, relative: str) -> dict:
    """전체 봉인 검증 뒤 알려진 두 경로 필드만 복사하여 가역적으로 분리한다."""
    result = {key: value for key, value in entry.items() if key != "path"}
    result["path_components"] = checked_path(entry["path"], relative).split("/")
    if entry["type"] == "symlink":
        target = entry["target"]
        result["target"] = dict(root=target["root"],
                                path_components=checked_path(target["path"], relative).split("/"))
    return result


def restore_path(components: object, relative: str) -> str:
    """한 표기만 받아 빈 요소·구분자·부모 이동과 비정규 루트 표기를 거부한다."""
    require(isinstance(components, list) and bool(components)
            and all(isinstance(part, str) and part and "/" not in part and part != ".." for part in components)
            and (components == ["."] or "." not in components), "invalid-path-components")
    return checked_path("/".join(components), relative)


def restore_entry(entry: object, relative: str) -> dict:
    """일반 JSON에 신뢰를 주지 않고 v2 봉인 항목의 정확한 형식만 역변환한다."""
    require(isinstance(entry, dict) and isinstance(entry.get("root"), str)
            and type(entry.get("mode")) is int and 0 <= entry["mode"] <= 0o7777,
            "invalid-projected-entry")
    common = {"root", "path_components", "mode", "type"}
    kind = entry.get("type")
    if kind == "file":
        require(set(entry) == common | {"bytes", "sha256"} and type(entry["bytes"]) is int
                and entry["bytes"] >= 0 and SEAL.valid_sha(entry["sha256"]), "invalid-projected-entry")
    elif kind == "directory":
        require(set(entry) == common, "invalid-projected-entry")
    elif kind == "symlink":
        require(set(entry) == common | {"target", "link_text_sha256"}
                and SEAL.valid_sha(entry["link_text_sha256"]), "invalid-projected-entry")
        target = entry["target"]
        require(isinstance(target, dict) and set(target) == {"root", "path_components"}
                and isinstance(target["root"], str), "invalid-projected-target")
    else:
        raise ProjectionError("invalid-projected-entry")
    result = {key: value for key, value in entry.items() if key != "path_components"}
    result["path"] = restore_path(entry["path_components"], relative)
    if kind == "symlink":
        result["target"] = dict(root=target["root"], path=restore_path(target["path_components"], relative))
    return result


def entry_chunks(entries: list) -> list[bytes]:
    """항목 순서와 모든 필드를 그대로 두고 고정된 4 MiB 경계에서만 나눈다."""
    chunks, parts, count = [], [], 5
    for entry in entries:
        body = json.dumps(entry, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False)
        item = ("\n".join("  " + line for line in body.splitlines())).encode()
        require(len(item) + 5 <= CHUNK_BYTES, "single-entry-chunk-limit")
        added = len(item) + (2 if parts else 0)
        if parts and count + added > CHUNK_BYTES:
            chunks.append(b"[\n" + b",\n".join(parts) + b"\n]\n")
            parts, count, added = [], 5, len(item)
        parts.append(item)
        count += added
    if parts:
        chunks.append(b"[\n" + b",\n".join(parts) + b"\n]\n")
    return chunks


def write_chunks(base: Path, label: str, entries: list) -> list[dict]:
    """조각의 순서·오프셋·크기·해시를 각 원본 레코드에 연결한다."""
    rows, offset = [], 0
    for ordinal, data in enumerate(entry_chunks(entries)):
        require(len(data) <= CHUNK_BYTES < MAX_FILE_BYTES, "chunk-byte-limit")
        relative = f"{label}/entries-{ordinal:06d}.json"
        path = base / relative
        used = sum(item.stat().st_size for item in base.rglob("*") if item.is_file())
        require(used + len(data) <= MAX_TOTAL_BYTES, "projection-size-limit")
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as stream:
            stream.write(data)
        count = len(strict_array(data))
        rows.append(dict(path=relative, ordinal=ordinal, entry_offset=offset, entry_count=count,
                         bytes=len(data), sha256=digest(data)))
        offset += count
    require(offset == len(entries), "chunk-count-mismatch")
    return rows


def record_projection(base: Path, label: str, document: dict, raw_identity: dict, candidate_entries: list | None) -> dict:
    """후검증 항목은 후보와 완전히 같을 때만 후보 항목을 참조한다."""
    seal = seal_from_record(label, document)
    entries = seal["entries"]
    non_entries = {key: value for key, value in seal.items() if key != "entries"}
    remainder = non_entries if label == "before-compilation" else {**document, "actual": non_entries}
    row = dict(state="present", source_relative_path=SOURCES[label], raw_identity=raw_identity,
               original_value_sha256=digest(SEAL.canonical_bytes(document)), document_without_entries=remainder,
               entry_count=len(entries))
    if label != "before-compilation" and entries == candidate_entries:
        row["entries_reference"] = "before-compilation"
    else:
        row["chunks"] = write_chunks(base, label, [project_entry(entry, SOURCES[label]) for entry in entries])
    return row


def projection_files(base: Path) -> dict[str, bytes]:
    """예상하지 않은 파일·링크·특수 항목을 제외하지 않고 거부한다."""
    require(base.is_dir() and not base.is_symlink(), "invalid-projection-directory")
    files, total = {}, 0
    for path in sorted(base.rglob("*")):
        info = path.lstat()
        require(not stat.S_ISLNK(info.st_mode), "projection-symlink")
        if stat.S_ISDIR(info.st_mode):
            continue
        require(stat.S_ISREG(info.st_mode), "projection-special-file")
        data = SEAL.expected_bytes(path)
        total += len(data)
        require(len(data) <= MAX_FILE_BYTES and total <= MAX_TOTAL_BYTES, "projection-size-limit")
        files[path.relative_to(base).as_posix()] = data
    return files


def restore_documents(base: Path, *, normalized: bool = False) -> tuple[dict, dict]:
    """조각을 역변환하며 이름·순서·중복·해시·개수와 전체 내용 정체성을 검사한다."""
    files = projection_files(base)
    require("projection.json" in files, "missing-projection-manifest")
    manifest = SEAL.strict_expected_json(files["projection.json"])
    require(set(manifest) == {"schema_version", "kind", "accepted", "final_protocol_ready", "records",
                              "serialization", "normalization", "projection_creation_wall_seconds"},
            "invalid-projection-schema")
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 2
            and manifest["kind"] == "native-calibration-sdk-entry-chunks-v2"
            and manifest["accepted"] is False and manifest["final_protocol_ready"] is False
            and set(manifest["records"]) == set(SOURCES), "invalid-projection-status")
    elapsed = manifest["projection_creation_wall_seconds"]
    require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0
            and manifest["serialization"] == SERIALIZATION and manifest["normalization"] == NORMALIZATION,
            "invalid-projection-metadata")
    expected_files, documents, all_entries = {"projection.json"}, {}, {}
    for label in SOURCES:
        row = manifest["records"][label]
        if row.get("state") == "missing":
            require(row == dict(state="missing", source_relative_path=SOURCES[label]), "invalid-missing-record")
            continue
        common = {"state", "source_relative_path", "raw_identity", "original_value_sha256",
                  "document_without_entries", "entry_count"}
        require(row.get("state") == "present" and row.get("source_relative_path") == SOURCES[label]
                and set(row) in (common | {"chunks"}, common | {"entries_reference"}), "invalid-record-schema")
        require(set(row["raw_identity"]) == {"bytes", "sha256"}
                and type(row["raw_identity"]["bytes"]) is int
                and 0 < row["raw_identity"]["bytes"] <= SEAL.MAX_MANIFEST_BYTES
                and SEAL.valid_sha(row["raw_identity"]["sha256"])
                and SEAL.valid_sha(row["original_value_sha256"]), "invalid-source-identity")
        require(type(row["entry_count"]) is int and 0 < row["entry_count"] <= SEAL.MAX_ENTRIES,
                "invalid-entry-count")
        if "entries_reference" in row:
            require(label != "before-compilation" and row["entries_reference"] == "before-compilation"
                    and "before-compilation" in all_entries, "invalid-entry-reference")
            entries = all_entries["before-compilation"]
        else:
            entries = []
            require(isinstance(row["chunks"], list) and bool(row["chunks"]), "missing-entry-chunks")
            for ordinal, chunk in enumerate(row["chunks"]):
                name = f"{label}/entries-{ordinal:06d}.json"
                require(set(chunk) == {"path", "ordinal", "entry_offset", "entry_count", "bytes", "sha256"}
                        and chunk["path"] == name and type(chunk["ordinal"]) is int and chunk["ordinal"] == ordinal
                        and type(chunk["entry_offset"]) is int and chunk["entry_offset"] == len(entries)
                        and type(chunk["entry_count"]) is int and chunk["entry_count"] > 0
                        and type(chunk["bytes"]) is int and 0 < chunk["bytes"] <= CHUNK_BYTES,
                        "invalid-chunk-order-or-schema")
                require(name in files and name not in expected_files, "missing-or-duplicate-chunk")
                data = files[name]
                require(len(data) == chunk["bytes"] and digest(data) == chunk["sha256"], "chunk-identity-mismatch")
                values = strict_array(data)
                require(len(values) == chunk["entry_count"], "chunk-entry-count-mismatch")
                entries.extend(restore_entry(value, (PROJECTION / name).as_posix()) for value in values)
                require(len(entries) <= SEAL.MAX_ENTRIES, "entry-count-limit")
                expected_files.add(name)
        require(len(entries) == row["entry_count"], "total-entry-count-mismatch")
        remainder = row["document_without_entries"]
        require(isinstance(remainder, dict), "invalid-record-remainder")
        seal_remainder = remainder if label == "before-compilation" else remainder.get("actual")
        require(isinstance(seal_remainder, dict) and isinstance(seal_remainder.get("roots"), dict)
                and bool(seal_remainder["roots"]), "invalid-record-roots")
        roots = seal_remainder["roots"]
        require(all(entry["root"] in roots and (entry["type"] != "symlink" or entry["target"]["root"] in roots)
                    for entry in entries), "entry-root-mismatch")
        document = ({**remainder, "entries": entries} if label == "before-compilation"
                    else {**remainder, "actual": {**remainder["actual"], "entries": entries}})
        if normalized:
            seal = document if label == "before-compilation" else document["actual"]
            require(SEAL.identity(sorted(seal["roots"]), entries) == seal["content_sha256"], "content-identity-mismatch")
        else:
            require(digest(SEAL.canonical_bytes(document)) == row["original_value_sha256"], "inverse-value-mismatch")
            seal_from_record(label, document)
        if label != "before-compilation":
            require("before-compilation" in documents
                    and document["expected_sha256"] == documents["before-compilation"]["content_sha256"],
                    "verification-candidate-mismatch")
            if "entries_reference" in row:
                require(document["actual"]["content_sha256"] == documents["before-compilation"]["content_sha256"],
                        "referenced-content-mismatch")
        documents[label], all_entries[label] = document, entries
    require(set(files) == expected_files, "extra-projection-files")
    return documents, manifest


def verify_projection(staging_dir: Path) -> dict:
    """정규화 전 원본 JSON 값의 가역성을 검증하고 원본 바이트 동일성은 주장하지 않는다."""
    started = time.perf_counter()
    documents, manifest = restore_documents(staging_dir / PROJECTION)
    files = projection_files(staging_dir / PROJECTION)
    return dict(status="verified-reversible-projection", accepted=False, final_protocol_ready=False,
                records=list(documents), projection_manifest_sha256=digest(files["projection.json"]),
                files=len(files), bytes=sum(len(value) for value in files.values()),
                original_raw_bytes_reproduced=False, wall_seconds=time.perf_counter() - started)


def verify_sources(raw_dir: Path, staging_dir: Path) -> dict:
    """공개 준비가 끝날 때까지 큰 원본 세 개와 명시한 부재 상태를 다시 확인한다."""
    started = time.perf_counter()
    documents, manifest = restore_documents(staging_dir / PROJECTION)
    for label, relative in SOURCES.items():
        path = raw_dir / relative
        require(not raw_dir.is_symlink() and not path.parent.is_symlink(), "source-directory-symlink")
        if label in documents:
            document, identity = read_document(path, limit=SEAL.MAX_MANIFEST_BYTES)
            require(document == documents[label] and identity == manifest["records"][label]["raw_identity"],
                    "source-changed")
        else:
            try:
                path.lstat()
            except FileNotFoundError:
                continue
            raise ProjectionError("missing-source-appeared")
    return dict(status="source-identities-unchanged", wall_seconds=time.perf_counter() - started)


def prepare_projection(raw_dir: Path, staging_dir: Path) -> dict:
    """세 개의 고정 원본만 변환하고 성공적인 역검사 뒤 부모의 정규화 입력에 넣는다."""
    started = time.perf_counter()
    raw_dir, staging_dir = raw_dir.absolute(), staging_dir.absolute()
    require(not raw_dir.is_symlink() and raw_dir.is_dir(), "invalid-raw-directory")
    raw, stage = raw_dir.resolve(), staging_dir.resolve()
    require(not stage.is_relative_to(raw) and not raw.is_relative_to(stage), "projection-input-overlap")
    final = staging_dir / PROJECTION
    pending = staging_dir.with_name(staging_dir.name + "-sdk-projection-pending")
    require(not final.exists() and not final.is_symlink(), "existing-projection")
    pending.mkdir(parents=True, exist_ok=False)
    records, originals, candidate_entries = {}, {}, None
    for label, relative in SOURCES.items():
        path = raw_dir / relative
        require(not path.parent.is_symlink(), "source-directory-symlink")
        try:
            path.lstat()
        except FileNotFoundError:
            records[label] = dict(state="missing", source_relative_path=relative)
            continue
        document, raw_identity = read_document(path, limit=SEAL.MAX_MANIFEST_BYTES)
        seal = seal_from_record(label, document)
        if label == "before-compilation":
            candidate_entries = seal["entries"]
        else:
            require(candidate_entries is not None, "verification-without-candidate")
        records[label] = record_projection(pending, label, document, raw_identity, candidate_entries)
        originals[label] = document
    manifest = dict(schema_version=2, kind="native-calibration-sdk-entry-chunks-v2", accepted=False,
                    final_protocol_ready=False, records=records,
                    serialization=SERIALIZATION, normalization=NORMALIZATION,
                    projection_creation_wall_seconds=time.perf_counter() - started)
    data = encoded(manifest)
    used = sum(item.stat().st_size for item in pending.rglob("*") if item.is_file())
    require(len(data) <= MAX_FILE_BYTES and used + len(data) <= MAX_TOTAL_BYTES, "projection-size-limit")
    with (pending / "projection.json").open("xb") as stream:
        stream.write(data)
    restored, _ = restore_documents(pending)
    require(restored == originals, "inverse-document-mismatch")
    for label in originals:
        document, identity = read_document(raw_dir / SOURCES[label], limit=SEAL.MAX_MANIFEST_BYTES)
        require(document == originals[label] and identity == records[label]["raw_identity"], "source-changed")
    for label in set(SOURCES) - set(originals):
        path = raw_dir / SOURCES[label]
        try:
            path.lstat()
        except FileNotFoundError:
            continue
        raise ProjectionError("missing-source-appeared")
    final.parent.mkdir(parents=True, exist_ok=True)
    pending.rename(final)
    verified = verify_projection(staging_dir)
    verified["prepare_wall_seconds"] = time.perf_counter() - started
    return verified


def verify_normalized_projection(public_dir: Path, expected_projection_manifest_sha256: str) -> dict:
    """정규화 뒤 항목 내용과 원본→공개 해시 연결을 확인하고 가려진 원본 경로를 복원하지 않는다."""
    started = time.perf_counter()
    documents, _ = restore_documents(public_dir / PROJECTION, normalized=True)
    outer, _ = read_document(public_dir / "manifest.json")
    require(outer.get("status") == "normalized_for_review" and outer.get("source_raw_unchanged") is True,
            "normalization-not-verified")
    rows = outer["files"]
    require(isinstance(rows, list) and len({row["path"] for row in rows}) == len(rows),
            "duplicate-normalization-file")
    by_path = {row["path"]: row for row in rows}
    manifest_path = (PROJECTION / "projection.json").as_posix()
    require(by_path[manifest_path]["original_raw_sha256"] == expected_projection_manifest_sha256,
            "normalization-source-mismatch")
    for name, data in projection_files(public_dir / PROJECTION).items():
        relative = (PROJECTION / name).as_posix()
        row = by_path[relative]
        require(row["normalized_sha256"] == digest(data) and row["normalized_bytes"] == len(data),
                "normalized-file-mismatch")
        if name != "projection.json":
            require(row["original_raw_sha256"] == row["normalized_sha256"]
                    and row["original_bytes"] == row["normalized_bytes"], "normalized-entry-chunk-changed")
    return dict(status="verified-normalized-projection", accepted=False, final_protocol_ready=False,
                records=list(documents), entries_content_identity_preserved=True,
                non_entry_fields_normalized=True, original_raw_bytes_reproduced=False,
                wall_seconds=time.perf_counter() - started)


def verify_publication(staging_dir: Path, public_dir: Path, manifest: dict) -> dict:
    """부모가 받은 기존 정규화 영수증을 실제 출력 및 원본 투영과 함께 연결한다."""
    source = verify_projection(staging_dir)
    retained, _ = read_document(public_dir / "manifest.json")
    require(retained == manifest, "normalization-receipt-changed")
    return verify_normalized_projection(public_dir, source["projection_manifest_sha256"])
