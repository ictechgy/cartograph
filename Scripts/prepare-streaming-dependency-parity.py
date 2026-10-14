#!/usr/bin/env python3
"""기존 coverage checkout에만 고정 baseline과 실제 fixture 동등성 검사를 생성한다."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


BASELINE = "7a638355dee84ef01a2b6d7e4e60eea850554abf"
INDEXSTORE = "64aa0b26913249c4e7c21d351a215fba02702003"
READER = "Sources/CartographIndexStore/RawIndexStoreReader.swift"
TEST_ROOT = "Tests/CartographIndexStoreTests/"
FIXTURES = {
    TEST_ROOT + "RawIndexStoreReaderTests.swift": "6326d8fe620830b858f0a51abb4886457f91d76773b371784b414e14c560bd26",
    TEST_ROOT + "HeaderRecordAdmissionTests.swift": "f6392c1b60cfb66bcba90d74cd7621ce671f6e49a9a18b0257451ed6d22d1008",
}
BASELINE_SHA256 = "a6a8567de5602146520d652885a3d186fdb46e23b06fb8501410cbea7390bea9"
RESULT = """struct RawReadResult {
    let occurrences: [SymbolOccurrence]
    let indexedFileDates: [String: Date]
    let oldestIndexedFileDates: [String: Date]
    let admittedHeaderPaths: [String]
}

"""
EAGER_MAP = """            let dependencies = unit.dependencies.map { dependency in
                (
                    kind: dependency.kind,
                    path: dependency.filePath.string,
                    module: dependency.moduleName.string,
                    name: dependency.name.string,
                    isSystem: dependency.isSystem
                )
            }
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Expected exactly one transform anchor: {old[:90]!r}")
    return text.replace(old, new, 1)


def candidate_from_baseline(baseline):
    text = replace_once(baseline, EAGER_MAP, "")
    text = replace_once(text, "            let timestamp = unit.modificationDate\n",
        "            let timestamp = unit.modificationDate\n"
        "            let providerIdentifier = unit.providerIdentifier.string\n"
        "            let isSystemUnit = unit.isSystemUnit\n")
    text = replace_once(text,
        "            for dependency in dependencies where dependency.kind == .record || dependency.kind == .file {\n",
        "            try unit.dependencies.forEach { dependency in\n"
        "                let kind = dependency.kind\n"
        "                guard kind == .record || kind == .file else { return .continue }\n")
    text = replace_once(text, "canonicalDependencyPath(dependency.path,", "canonicalDependencyPath(dependency.filePath.string,")
    text = replace_once(text, "guard readsOccurrences || tracked else { continue }",
        "guard readsOccurrences || tracked else { return .continue }\n                let isSystem = dependency.isSystem")
    text = replace_once(text, "if dependency.kind == .file {", "if kind == .file {")
    text = replace_once(text, "guard readsOccurrences, dependency.kind == .record else { continue }",
        "guard readsOccurrences, kind == .record else { return .continue }")
    text = replace_once(text, "let dependencyModule = dependency.module", "let dependencyModule = dependency.moduleName.string")
    text = replace_once(text, "record: dependency.name,", "record: dependency.name.string,")
    if text.count("unit.isSystemUnit || dependency.isSystem") != 2:
        raise ValueError("Unexpected system-context expression count")
    text = text.replace("unit.isSystemUnit || dependency.isSystem", "isSystemUnit || isSystem")
    text = replace_once(text, "try providerKind(unit.providerIdentifier.string, unit: unitName)",
        "try providerKind(providerIdentifier, unit: unitName)")
    text = replace_once(text, "                    provider: provider\n                ))\n",
        "                    provider: provider\n                ))\n                return .continue\n")
    return text


def renamed_reader(source, name):
    text = replace_once(source, RESULT, "")
    text = replace_once(text, "import CartographCore\n", "import CartographCore\n@testable import CartographIndexStore\n")
    return text.replace("RawIndexStoreReader", name)


def counted_reader(source, name, streaming):
    text = source
    text = replace_once(text, "        recordCachePeak: ((Int, Int) -> Void)? = nil\n",
        "        recordCachePeak: ((Int, Int) -> Void)? = nil,\n"
        "        metadataResult: ((DependencyMetadataCounts) -> Void)? = nil\n")
    text = replace_once(text, "    ) throws -> RawReadResult {\n",
        "    ) throws -> RawReadResult {\n"
        "        var dependencyMetadata = DependencyMetadataCounts()\n"
        "        defer { metadataResult?(dependencyMetadata) }\n")
    if streaming:
        text = replace_once(text, "try unit.dependencies.forEach { dependency in\n",
            "try unit.dependencies.forEach { dependency in\n                dependencyMetadata.dependencies += 1\n")
        gate = "                guard kind == .record || kind == .file else { return .continue }\n"
        text = replace_once(text, gate, gate + "                dependencyMetadata.recordOrFile += 1\n")
        text = replace_once(text, "let isSystem = dependency.isSystem",
            "let isSystem = dependencyMetadata.system(dependency.isSystem)")
    else:
        text = replace_once(text, "let dependencies = unit.dependencies.map { dependency in\n                (\n",
            "let dependencies = unit.dependencies.map { dependency in\n"
            "                dependencyMetadata.dependencies += 1\n                return (\n")
        gate = "            for dependency in dependencies where dependency.kind == .record || dependency.kind == .file {\n"
        text = replace_once(text, gate, gate + "                dependencyMetadata.recordOrFile += 1\n")
        text = replace_once(text, "isSystem: dependency.isSystem\n",
            "isSystem: dependencyMetadata.system(dependency.isSystem)\n")
    for field, expression in [("path", "filePath.string"), ("module", "moduleName.string"), ("name", "name.string")]:
        text = replace_once(text, "dependency." + expression, f"dependencyMetadata.{field}(dependency.{expression})")
    for gate, counter in [
        ("guard readsOccurrences || tracked else {", "admittedContexts"),
        ("guard readsOccurrences, " + ("kind" if streaming else "dependency.kind") + " == .record else {", "admittedRecords"),
    ]:
        statement = "                " + gate + (" return .continue }\n" if streaming else " continue }\n")
        text = replace_once(text, statement, statement + f"                dependencyMetadata.{counter} += 1\n")
    return renamed_reader(text, name)


def read_blob(repository, path):
    return subprocess.run(["git", "show", f"{BASELINE}:{path}"], cwd=repository,
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20).stdout


def regular_file(repository, relative):
    path = repository / relative
    if path.is_symlink() or not path.is_file() or path.resolve() != path.absolute():
        raise ValueError(f"Expected a regular, non-symlink source file: {relative}")
    return path.read_bytes()


def product_hashes(repository):
    paths = [repository / "Package.swift", repository / "Package.resolved"]
    paths += sorted((repository / "Sources").rglob("*"))
    return {str(path.relative_to(repository)): digest(regular_file(repository, path.relative_to(repository)))
        for path in paths if path.is_file() or path.is_symlink()}


def prepare(repository, evidence):
    repository = repository.resolve()
    evidence = evidence.absolute()
    if evidence.exists() or evidence.is_symlink() or evidence.resolve() != evidence:
        raise ValueError("Evidence directory must be new and have no symlink components")
    if evidence.is_relative_to(repository) or not evidence.parent.is_dir():
        raise ValueError("Evidence directory must have an existing parent outside the checkout")
    baseline_bytes = read_blob(repository, READER)
    if digest(baseline_bytes) != BASELINE_SHA256:
        raise ValueError("Pinned baseline reader bytes do not match")
    baseline = baseline_bytes.decode("utf-8")
    candidate_bytes = regular_file(repository, READER)
    candidate = candidate_from_baseline(baseline)
    if candidate_bytes != candidate.encode():
        raise ValueError("Candidate differs from the reviewed dependency-only transform")
    pins = json.loads(regular_file(repository, "Package.resolved"))["pins"]
    if [pin["state"]["revision"] for pin in pins if pin["identity"] == "indexstore-db"] != [INDEXSTORE]:
        raise ValueError("Unexpected IndexStore dependency revision")
    outputs = {}
    originals = {}
    for path, expected in FIXTURES.items():
        original = regular_file(repository, path)
        if digest(original) != expected or original != read_blob(repository, path):
            raise ValueError(f"Unexpected original fixture test bytes: {path}")
        originals[path] = original
        text = original.decode()
        text = text.replace("RawIndexStoreReader(", "DependencyParityRawReader(")
        text = re.sub(r"\bIndexStoreProvider\b", "DependencyParityProvider", text)
        outputs[path] = text.encode()
    template = "Scripts/streaming-dependency-parity/Assertions.swift"
    outputs[TEST_ROOT + "DependencyParityAssertions.generated.swift"] = regular_file(repository, template)
    outputs[TEST_ROOT + "EagerDependencyRawIndexStoreReader.generated.swift"] = renamed_reader(
        baseline, "EagerDependencyRawIndexStoreReader").encode()
    outputs[TEST_ROOT + "CountedEagerDependencyRawIndexStoreReader.generated.swift"] = counted_reader(
        baseline, "CountedEagerDependencyRawIndexStoreReader", False).encode()
    outputs[TEST_ROOT + "CountedStreamingDependencyRawIndexStoreReader.generated.swift"] = counted_reader(
        candidate, "CountedStreamingDependencyRawIndexStoreReader", True).encode()
    for path in outputs:
        target = repository / path
        if target.parent.resolve() != target.parent.absolute():
            raise ValueError(f"Symlinked test destination: {path}")
        if path not in FIXTURES and (target.exists() or target.is_symlink()):
            raise ValueError(f"Generated test destination already exists: {path}")
    before = product_hashes(repository)
    # 모든 입력과 목적지를 확인한 뒤 기록한다. 중간 실패는 이 checkout의 검증 실패다.
    evidence.mkdir()
    for path, data in outputs.items():
        captured = evidence / "generated" / path
        captured.parent.mkdir(parents=True, exist_ok=True)
        captured.write_bytes(data)
        target = repository / path
        if path in FIXTURES:
            if target.read_bytes() != originals[path]:
                raise ValueError(f"Fixture changed during preparation: {path}")
            target.write_bytes(data)
        else:
            with target.open("xb") as stream:
                stream.write(data)
    after = product_hashes(repository)
    if after != before:
        raise ValueError("Production bytes changed during test preparation")
    report = {
        "schema": "cartograph-streaming-dependency-parity-v1",
        "status": "prepared_not_executed",
        "baseline_commit": BASELINE,
        "indexstore_revision": INDEXSTORE,
        "baseline_reader_sha256": digest(baseline_bytes),
        "candidate_reader_sha256": digest(candidate_bytes),
        "original_fixture_sha256": FIXTURES,
        "generated_sha256": {path: digest(data) for path, data in outputs.items()},
        "production_sha256": before,
        "generator_sha256": digest(regular_file(repository, "Scripts/prepare-streaming-dependency-parity.py")),
        "assertion_template_sha256": digest(regular_file(repository, template)),
    }
    (evidence / "preparation.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    report = prepare(args.repository, args.evidence)
    print(json.dumps({"status": report["status"], "generated_files": len(report["generated_sha256"])}, sort_keys=True))


if __name__ == "__main__":
    main()
