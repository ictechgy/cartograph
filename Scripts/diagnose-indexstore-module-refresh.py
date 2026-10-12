#!/usr/bin/env python3
"""PCM·오브젝트·IR과 인덱스 유닛을 분리해 헤더 변경 뒤의 모듈 재인덱싱을 진단한다."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/adapter"
sys.path.insert(0, str(ADAPTER))
import mixed_adapter
import observe_mixed

spec = importlib.util.spec_from_file_location("benchmark_base", ROOT / "Scripts/benchmark-indexstore-cli.py")
BASE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(BASE)
HEADER = "int base(int);\nint alternate(int);\nstatic inline int headerRoute(int value) { return base(value); }\n"
SWIFT = "import Bridge\npublic func call(_ value: Int32) -> Int32 { headerRoute(value) }\n"
STAGES = ("initial", "edited", "renamed", "cache-refreshed", "fresh-index")


def require(value: bool, message: str) -> None:
    if not value:
        raise ValueError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(path: Path) -> dict:
    return {str(p.relative_to(path)): digest(p) for p in sorted(path.rglob("*")) if p.is_file()}


def move_owned_tree(path: Path, retained: Path, workspace: Path) -> dict:
    """전역 캐시를 건드리지 않고 이번 실행이 만든 입력을 이동해 원본 바이트를 보존한다."""
    require(path.is_dir() and not path.is_symlink(), "Refresh source must be an owned regular directory")
    require(path.resolve().is_relative_to(workspace.resolve()), "Refresh source is outside private workspace")
    require(not retained.exists() and retained.parent.resolve() == workspace.resolve(), "Unsafe refresh destination")
    before = manifest(path)
    started = time.perf_counter()
    path.rename(retained)
    path.mkdir()
    elapsed = time.perf_counter() - started
    require(manifest(retained) == before, "Refresh changed retained bytes")
    return {
        "operation": "move owned tree aside and recreate empty directory",
        "source": str(path),
        "retained": str(retained),
        "retained_sha256": before,
        "wall_seconds": elapsed,
    }


def object_targets(text: str) -> set[str]:
    lines = [line for line in text.splitlines() if "RELOC" in line or "R_" in line]
    return {m.group(1) for line in lines for m in re.finditer(r"(?:^|\W)_?(base|alternate)(?:[-+\s]|$)", line)}


def ir_targets(text: str) -> set[str]:
    return set(re.findall(r"\bcall\b[^\n]*?@(?:base|alternate)\b", text))


def classify_ir(text: str) -> set[str]:
    return {match.rsplit("@", 1)[1] for match in ir_targets(text)}


class Diagnostic:
    def __init__(self, setup: dict, setup_path: Path, output: Path, workspace: Path, sdk: str, objdump: Path):
        self.setup, self.output, self.workspace = setup, output, workspace
        self.swiftc = Path(setup["toolchain"]["swiftc"]).absolute()
        self.library = Path(setup["toolchain"]["library"]).resolve()
        self.cli = Path(setup["comparator_setup"]["binary"]).resolve()
        self.objdump, self.sdk = objdump.resolve(), sdk
        self.identities = {str(p): digest(p) for p in (self.swiftc, self.library, self.cli, self.objdump)}
        require(digest(self.library) == setup["toolchain"]["library_sha256"], "Shared library bytes changed")
        self.cli_provenance = observe_mixed.verify_cli(
            self.cli, Path(setup["comparator_setup"]["checkout"]), setup_path, output / "setup/cli"
        )
        self.project, self.build, self.store = [workspace / name for name in ("Project", "Build", "IndexStore")]
        for path in (self.project, self.build, self.store):
            path.mkdir()
        self.cache = self.build / "module-cache"
        self.header = self.project / "Bridge.h"
        self.header.write_text(HEADER)
        self.modulemap = self.project / "module.modulemap"
        self.modulemap.write_text('module Bridge { header "Bridge.h" export * }\n')
        self.source = self.project / "Caller.swift"
        self.source.write_text(SWIFT)
        BASE.save(
            output / "setup/corpus.json",
            {
                "header": HEADER,
                "swift": SWIFT,
                "module_map": self.modulemap.read_text(),
                "independent_targets": {s: "base" if s == "initial" else "alternate" for s in STAGES},
            },
        )
        self.capture([self.swiftc, "--version"], output / "setup/swift-version")
        self.capture([self.objdump, "--version"], output / "setup/objdump-version")

    def capture(self, command: list, stem: Path) -> str:
        text, _ = BASE.capture([str(x) for x in command], self.project, stem, timeout=120)
        return text

    def pcm_manifest(self) -> dict:
        return {str(p.relative_to(self.cache)): digest(p) for p in sorted(self.cache.rglob("Bridge-*.pcm"))}

    def dump(self, name: str, stage: Path) -> str:
        require(Path(name).name == name and "/" not in name, "Invalid compiler unit/record name")
        return self.capture(
            [self.cli, name, "--lib-index-store", self.library, "--index-store", self.store], stage / name
        )

    def module_evidence(self, stage: Path, expected_header: str, target: str) -> dict:
        roots = []
        for path in sorted((self.store / "v5/units").glob("Caller.o-*")):
            unit = mixed_adapter.parse_unit(path.name, self.dump(path.name, stage / "units"))
            if Path(unit["metadata"]["Output File"]).resolve() == (self.build / "Caller.o").resolve():
                roots.append(unit)
        require(len(roots) == 1, "Current compiler output must identify one source unit")
        dependencies = [d for d in roots[0]["dependencies"] if d["kind"] == "Unit" and d["module"] == "Bridge"]
        require(len(dependencies) == 1 and dependencies[0]["name"] is not None, "Expected one named Bridge PCM unit")
        dependency = dependencies[0]
        unit = mixed_adapter.parse_unit(dependency["name"], self.dump(dependency["name"], stage / "units"))
        meta = unit["metadata"]
        require(meta["Module"] == "Bridge" and meta["Provider Identifier"] == "clang", "Wrong module provider")
        require(Path(meta["Output File"]).resolve() == Path(dependency["path"]).resolve(), "PCM output mismatch")
        require(Path(meta["Output File"]).resolve().is_relative_to(self.cache.resolve()), "PCM is outside owned cache")
        records = [
            d
            for d in unit["dependencies"]
            if d["kind"] == "Record" and Path(d["path"]).parent.resolve() == self.project.resolve()
        ]
        require(len(records) == 1, "Expected one authored project header record")
        record = records[0]
        text = self.dump(record["name"], stage / "records")
        edges = mixed_adapter.record_edges(mixed_adapter.parse_record(text))
        expected = {(f"c:{expected_header}@F@headerRoute", "c:@F@" + target)}
        return {
            "source_unit": roots[0],
            "module_unit": unit,
            "module_unit_sha256": digest(self.store / "v5/units" / dependency["name"]),
            "record_dump_sha256": hashlib.sha256(text.encode()).hexdigest(),
            "observed_edges": sorted(edges),
            "expected_edges": sorted(expected),
            "expected_header": expected_header,
            "index_matches_authored_source": edges == expected
            and Path(record["path"]).resolve() == self.header.resolve(),
        }

    def run_stage(self, name: str) -> dict:
        out = self.output / "runs" / name
        out.mkdir(parents=True)
        require(all(digest(Path(p)) == sha for p, sha in self.identities.items()), "Executed tool bytes changed")
        refresh = None
        if name == "edited":
            time.sleep(1.1)
            self.header.write_text(HEADER.replace("return base", "return alternate"))
        elif name == "renamed":
            time.sleep(1.1)
            self.header.rename(self.project / "Renamed.h")
            self.header = self.project / "Renamed.h"
            self.modulemap.write_text('module Bridge { header "Renamed.h" export * }\n')
        elif name in {"cache-refreshed", "fresh-index"}:
            path = self.cache if name == "cache-refreshed" else self.store
            refresh = move_owned_tree(path, self.workspace / ("retained-" + name), self.workspace)
            BASE.save(out / "refresh.json", refresh)
        common = [
            self.swiftc,
            "-parse-as-library",
            "-module-name",
            "Client",
            "-module-cache-path",
            self.cache,
            "-I",
            self.project,
            "-Onone",
        ]
        if self.sdk:
            common += ["-sdk", self.sdk]
        self.capture(
            [*common, "-c", "-index-store-path", self.store, self.source, "-o", self.build / "Caller.o"],
            out / "compile",
        )
        pcm_before, index_before = self.pcm_manifest(), manifest(self.store)
        require(len(pcm_before) == 1, "Expected one private Bridge PCM")
        object_text = self.capture([self.objdump, "-dr", self.build / "Caller.o"], out / "object")
        ir = self.capture([*common, "-emit-ir", self.source, "-o", "-"], out / "ir")
        require(index_before == manifest(self.store), "IR or object diagnostics mutated the compiler index")
        require(pcm_before == self.pcm_manifest(), "IR diagnostic changed the accepted PCM bytes")
        target = "base" if name == "initial" else "alternate"
        require(
            object_targets(object_text) == {target}, "Object relocations disagree with independent source expectation"
        )
        require(classify_ir(ir) == {target}, "LLVM IR disagrees with independent source expectation")
        evidence = self.module_evidence(out, self.header.name, target)
        require(index_before == manifest(self.store), "Read-only index-dump changed compiler index bytes")
        result = {
            "stage": name,
            "status": "observed",
            "expected_target": target,
            "pcm_before_ir": pcm_before,
            "pcm_after_ir": self.pcm_manifest(),
            "index_file_hashes": index_before,
            "object_sha256": digest(self.build / "Caller.o"),
            "object_targets": sorted(object_targets(object_text)),
            "ir_targets": sorted(classify_ir(ir)),
            "source_file_hashes": manifest(self.project),
            "refresh": refresh,
            "compiler_index": evidence,
        }
        BASE.save(out / "result.json", result)
        if name in {"initial", "fresh-index"}:
            require(evidence["index_matches_authored_source"], "Required initial/fresh-index compiler control failed")
        return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--setup-results", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--sdk", default="")
    parser.add_argument("--objdump", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())), "Output must be absent or empty")
    output.mkdir(parents=True, exist_ok=True)
    workspace = (args.workspace or Path(tempfile.mkdtemp(prefix="cartograph-module-diagnostic-"))).resolve()
    require(
        not workspace.exists() or (workspace.is_dir() and not any(workspace.iterdir())),
        "Private workspace must be empty",
    )
    require(
        not workspace.is_relative_to(output) and not output.is_relative_to(workspace),
        "Raw workspace and text evidence must be separate",
    )
    workspace.mkdir(parents=True, exist_ok=True)
    result = {
        "role": "compiler-only-module-reindex-diagnostic",
        "superiority_claim": None,
        "states": [],
        "engine_comparison": "not-run",
        "harness_sha256": digest(Path(__file__)),
        "adapter_sha256": {p.name: digest(p) for p in (ADAPTER / "mixed_adapter.py", ADAPTER / "observe_mixed.py")},
        "cost_scope": "Every setup/compile/diagnostic/refresh record retained; no engine timing claim",
    }
    try:
        setup = json.loads(args.setup_results.read_text())
        diagnostic = Diagnostic(setup, args.setup_results.resolve(), output, workspace, args.sdk, args.objdump)
        result.update(executables=diagnostic.identities, cli=diagnostic.cli_provenance)
        for stage in STAGES:
            result["states"].append(diagnostic.run_stage(stage))
        require(all(digest(Path(p)) == sha for p, sha in diagnostic.identities.items()), "Executed tool bytes changed")
        result["status"] = "completed-diagnostic"
    except Exception as error:
        result.update(status="failed", error=f"{type(error).__name__}: {error}")
    BASE.save(output / "results.json", result)
    print(
        json.dumps({"status": result["status"], "completed_states": len(result["states"]), "superiority_claim": None})
    )
    return int(result["status"] != "completed-diagnostic")


if __name__ == "__main__":
    raise SystemExit(main())
