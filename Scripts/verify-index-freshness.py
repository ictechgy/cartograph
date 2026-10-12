#!/usr/bin/env python3
"""실제 컴파일러 인덱스로 헤더·삭제 경로와 여러 문맥의 신선도 경고를 검증한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

spec = importlib.util.spec_from_file_location(
    "recursive_harness", Path(__file__).with_name("verify-recursive-calls.py")
)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
run, require = shared.run, shared.require
PREFIXES = ("index-staleness:", "unindexed-sources:", "missing-sources:", "unreadable-sources:")


def check_limitations(document: dict, expected: dict[str, set[str]]) -> None:
    require(document.get("status") == "found", "Freshness query must resolve the unchanged base function")
    limitations = document.get("limitations")
    require(isinstance(limitations, list) and all(isinstance(x, str) for x in limitations), "Missing limitations array")
    actual = {}
    for item in limitations:
        if not item.startswith(PREFIXES):
            continue
        prefix = item.split(":", 1)[0]
        require("; paths: " in item, f"Freshness diagnostic lacks paths: {item}")
        paths = json.loads(item.split("; paths: ", 1)[1])
        require(isinstance(paths, list) and all(isinstance(p, str) for p in paths), "Invalid diagnostic path array")
        require(all(not p.startswith("/") and ".." not in Path(p).parts for p in paths), "Unscoped diagnostic path")
        require(prefix not in actual, f"Duplicate freshness limitation: {prefix}")
        actual[prefix] = set(paths)
    require(actual == expected, f"Expected exact freshness paths {expected}, got {actual}")


class Harness:
    def __init__(self, binary: Path, output: Path):
        self.output = output
        self.project = output / "Project"
        fixture = Path(__file__).resolve().parents[1] / "Fixtures/SourceFreshnessCorpus"
        shutil.copytree(fixture, self.project)
        self.build = output / "Build"
        self.build.mkdir()
        self.store = output / "IndexStore"
        self.store.mkdir()
        self.swiftc = run(["xcrun", "--find", "swiftc"], self.project, output, "swiftc-path").strip()
        self.clang = run(["xcrun", "--find", "clang"], self.project, output, "clang-path").strip()
        self.sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], self.project, output, "sdk-path").strip()
        run([self.swiftc, "--version"], self.project, output, "swift-version")
        self.native = shared.Harness(binary, self.project, self.store, output)
        self.states = []

    def swift(self, stage: str, module: str, source: str = "Shared.swift") -> None:
        run(
            [
                self.swiftc,
                "-c",
                "-parse-as-library",
                "-module-name",
                module,
                "-sdk",
                self.sdk,
                "-module-cache-path",
                str(self.build / "ModuleCache"),
                "-index-store-path",
                str(self.store),
                str(self.project / "Sources" / source),
                "-o",
                str(self.build / f"{module}.o"),
            ],
            self.project,
            self.output,
            f"{stage}-{module}",
        )

    def clang_build(self, stage: str) -> None:
        run(
            [
                self.clang,
                "-c",
                "-isysroot",
                self.sdk,
                "-index-store-path",
                str(self.store),
                str(self.project / "Sources/Caller.m"),
                "-o",
                str(self.build / "Caller.o"),
            ],
            self.project,
            self.output,
            f"{stage}-clang",
        )

    def observe(self, stage: str, expected: dict[str, set[str]]) -> None:
        document = self.native.document(stage, ["query", "c:@F@base", "--depth", "2", "--edge-kind", "call"])
        check_limitations(document, expected)
        self.states.append(stage)

    def snapshot(self, stage: str) -> dict:
        return self.native.document(stage, ["snapshot"])["snapshot"]

    def verify(self) -> dict:
        self.swift("initial", "Alpha")
        self.swift("initial", "Beta")
        self.clang_build("initial")
        self.observe("initial", {})
        initial = self.snapshot("snapshot-initial")
        header = str(self.project / "Sources/Header.h")
        require(header in initial["oldestIndexedFileDates"], "Snapshot lost header dependency coverage")
        require(initial["admittedHeaderPaths"] == [header], "Snapshot lost actual header record admission")

        # 관측된 유닛 시각과 파일 수정 시각이 분명히 갈리도록 기다린다.
        time.sleep(1.1)
        path = self.project / "Sources/Header.h"
        path.write_text(path.read_text() + "// Edited after the build.\n")
        self.observe("header-edit-unbuilt", {"index-staleness": {"Sources/Header.h"}})
        self.clang_build("header-edit")
        self.observe("header-edit-rebuilt", {})

        time.sleep(1.1)
        path.rename(self.project / "Sources/Renamed.h")
        caller = self.project / "Sources/Caller.m"
        caller.write_text(caller.read_text().replace('"Header.h"', '"Renamed.h"'))
        self.observe(
            "header-rename-unbuilt",
            {
                "missing-sources": {"Sources/Header.h"},
                "unindexed-sources": {"Sources/Renamed.h"},
                "index-staleness": {"Sources/Caller.m"},
            },
        )
        self.clang_build("header-rename")
        self.observe("header-rename-rebuilt", {})
        renamed = self.project / "Sources/Renamed.h"
        content = renamed.read_text()
        renamed.unlink()
        self.observe("header-delete-unbuilt", {"missing-sources": {"Sources/Renamed.h"}})
        missing = self.snapshot("snapshot-header-deleted")
        require(str(renamed) in missing["oldestIndexedFileDates"], "Snapshot dropped deleted header coverage")
        require(missing["admittedHeaderPaths"] == [], "Deleted header was admitted as a current declaration source")
        renamed.write_text(content)
        self.clang_build("header-restore")
        self.observe("header-restored", {})

        time.sleep(1.1)
        source = self.project / "Sources/Shared.swift"
        source.write_text(source.read_text().replace("{ 1 }", "{ 2 }"))
        self.swift("partial", "Alpha")
        self.observe("partial-context-rebuild", {"index-staleness": {"Sources/Shared.swift"}})
        partial = self.snapshot("snapshot-partial")
        latest, oldest = partial["indexedFileDates"][str(source)], partial["oldestIndexedFileDates"][str(source)]
        require(latest > oldest, "Latest and oldest observed covering contexts were collapsed")
        self.swift("complete", "Beta")
        self.observe("all-contexts-rebuilt", {})

        source.rename(self.project / "Sources/Relocated.swift")
        self.observe(
            "swift-rename-unbuilt",
            {
                "missing-sources": {"Sources/Shared.swift"},
                "unindexed-sources": {"Sources/Relocated.swift"},
            },
        )
        self.swift("renamed", "Alpha", "Relocated.swift")
        self.swift("renamed", "Beta", "Relocated.swift")
        self.observe("swift-rename-rebuilt", {})
        (self.project / "Sources/Relocated.swift").unlink()
        self.observe("swift-delete-unbuilt", {"missing-sources": {"Sources/Relocated.swift"}})
        return {
            "status": "passed",
            "states": self.states,
            "partial_context_control": True,
            "header_graph_admission": "scoped-observed-records",
            "snapshot_dependency_dates": "passed",
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify source freshness using real compiler index dependencies.")
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.expanduser().resolve()
    require(binary.is_file() and os.access(binary, os.X_OK), "Exact Cartograph executable is required")
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-freshness-"))).resolve()
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())), "Output must be absent or empty")
    output.mkdir(parents=True, exist_ok=True)
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    try:
        result = Harness(binary, output).verify()
        require(hashlib.sha256(binary.read_bytes()).hexdigest() == binary_hash, "Cartograph executable changed")
    except Exception as error:
        result = {"status": "failed", "error": f"{type(error).__name__}: {error}"}
    result["cartograph_sha256"] = binary_hash
    (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))
    if result["status"] != "passed":
        print(f"Diagnostics retained at {output}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
