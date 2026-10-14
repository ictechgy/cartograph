"""검증된 런타임 모듈 지도만 손실 없이 목록으로 표현하고 원래 영수증을 계속 검증한다."""

from __future__ import annotations

import copy
import hashlib
import json
import re
from pathlib import Path

import state_inputs
import isolated_measure
import runtime_bootstrap as bootstrap
import startup_binding

ROOT = Path(__file__).resolve().parent
FORMAT = "sorted-named-module-entries-v1"
CATALOG_FORMAT = "source-catalog-declaration-lexeme-v1"


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def restore(receipt):
    value = copy.deepcopy(receipt)
    for phase in ["before", "after"]:
        snapshot = value.get("modules_" + phase, {})
        if snapshot.get("modules_format") != FORMAT:
            continue
        rows = snapshot["modules"]
        state_inputs.require(isinstance(rows, list), "Projected module entries are not a list")
        names = [row.get("name") for row in rows if isinstance(row, dict)]
        state_inputs.require(
            len(names) == len(rows)
            and all(isinstance(name, str) and name for name in names)
            and names == sorted(set(names))
            and all(set(row) == {"name", "record"} for row in rows),
            "Projected module entries are duplicated, reordered or malformed",
        )
        modules = {row["name"]: row["record"] for row in rows}
        state_inputs.require(digest(modules) == snapshot["sha256"], "Projected module content differs")
        snapshot["modules"] = modules
        del snapshot["modules_format"]
    return value


def module_record(name, row):
    state_inputs.require(
        isinstance(name, str)
        and bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*", name))
        and isinstance(row, dict),
        "Unexpected module name or non-record value",
    )
    kind = row.get("kind")
    if kind in {"built-in", "frozen"}:
        state_inputs.require(set(row) == {"kind"}, "Unexpected built-in module fields")
        return
    fields = {"kind", "path", "sha256", "bytes"}
    if kind == "stdlib-derived-namespace":
        fields.add("parent")
        state_inputs.require(
            row.get("parent") == "typing" and name in {"typing.io", "typing.re"}, "Unexpected derived namespace"
        )
    else:
        state_inputs.require(
            kind in {"private-package", "selected-script", "observed-stdlib"}, "Unexpected module kind"
        )
        if "bytecode_cache" in row:
            fields.add("bytecode_cache")
            cache = row["bytecode_cache"]
            state_inputs.require(
                isinstance(cache, dict) and type(cache.get("exists")) is bool, "Unexpected bytecode identity"
            )
            expected = {"path", "exists", *({"sha256", "bytes"} if cache["exists"] else set())}
            state_inputs.require(set(cache) == expected, "Unexpected bytecode fields")
            file_record(cache, cache["exists"])
    state_inputs.require(set(row) == fields, "Unexpected module record fields")
    file_record(row, True)


def file_record(row, content):
    state_inputs.require(
        isinstance(row.get("path"), str) and Path(row["path"]).is_absolute() and ".." not in Path(row["path"]).parts,
        "Unexpected module path",
    )
    if content:
        state_inputs.require(
            isinstance(row.get("sha256"), str)
            and bool(re.fullmatch("[a-f0-9]{64}", row["sha256"]))
            and type(row.get("bytes")) is int
            and 0 <= row["bytes"] <= 256 * 1024**2,
            "Unexpected module content identity",
        )


def project(receipt):
    value = copy.deepcopy(receipt)
    for phase in ["before", "after"]:
        snapshot = value.get("modules_" + phase, {})
        modules = snapshot.get("modules")
        if not isinstance(modules, dict):
            continue
        state_inputs.require(
            "modules_format" not in snapshot and digest(modules) == snapshot["sha256"], "Original module digest differs"
        )
        for name, row in modules.items():
            module_record(name, row)
        snapshot["modules"] = [{"name": name, "record": row} for name, row in sorted(modules.items())]
        snapshot["modules_format"] = FORMAT
    state_inputs.require(encoded(restore(value)) == encoded(receipt), "Module projection is not lossless")
    return value


def catalog_rows(value, lexeme):
    fields = {"id", "context", "path", "line", "column", lexeme, "signature", "anchor", "definition", "language"}
    state_inputs.require(isinstance(value, list), "Source catalog is not a list")
    for row in value:
        state_inputs.require(
            isinstance(row, dict) and set(row) in (fields, fields | {"alias_of"}), "Unexpected source catalog fields"
        )
        state_inputs.require(
            all(isinstance(row[key], str) and row[key] for key in fields - {"line", "column", "definition"})
            and all(type(row[key]) is int and row[key] > 0 for key in ("line", "column"))
            and type(row["definition"]) is bool
            and ("alias_of" not in row or isinstance(row["alias_of"], str) and bool(row["alias_of"])),
            "Unexpected source catalog types",
        )
        path = Path(row["path"])
        state_inputs.require(
            not path.is_absolute() and ".." not in path.parts and str(path) == row["path"]
            and path.suffix in {".swift", ".m", ".mm", ".h", ".c", ".cpp"}
            and row["language"] == ("swift" if path.suffix == ".swift" else "clang")
            and re.fullmatch(r"\w+", row[lexeme]) is not None
            and row["id"] == f'{row["context"]}::{row["path"]}:{row["line"]}:{row["column"]}',
            "Unexpected source catalog declaration",
        )
    state_inputs.require(len({row["id"] for row in value}) == len(value), "Duplicate source catalog declaration")


def restore_catalog(value):
    catalog_rows(value, "declaration_lexeme")
    return [{("token" if key == "declaration_lexeme" else key): item for key, item in row.items()} for row in value]


def project_catalog(value):
    catalog_rows(value, "token")
    # 원래 진단 생산자의 동일한 필드 대응만 재사용하며 값을 지우거나 다시 해석하지 않는다.
    result = state_inputs.generation.observer.catalog_evidence(value)
    state_inputs.require(
        encoded(restore_catalog(result)) == encoded(value), "Source catalog projection is not lossless"
    )
    return result


def calibration_inventory(raw, plan, complete=False):
    """선언한 호출만 변환하고 완료 판정에는 정확한 전체 디렉터리 집합을 요구한다."""
    expected = state_inputs.calibration_plan()
    state_inputs.require(encoded(plan.get("calibration")) == encoded(expected), "Calibration plan differs")
    jobs = expected["invocations"]
    names = {item["folder"] for item in jobs}
    for relative in ("runs/calibration", "private-readers"):
        root = Path(raw) / relative
        entries = list(root.iterdir()) if root.exists() else []
        state_inputs.require(
            not root.is_symlink()
            and all(path.is_dir() and not path.is_symlink() and path.name in names for path in entries)
            and (not complete or {path.name for path in entries} == names),
            "Calibration invocation folders differ",
        )
    state_inputs.require(
        not (Path(raw) / "runs/restored_rebuilt").exists(), "Calibration contains ordinary arm folders"
    )
    return jobs


class Projection:
    def __init__(self, raw):
        self.raw = Path(raw)
        self.accepted = {}
        self.bindings = []
        self.files = {}
        self.applied = []
        self.catalogs = {}
        self.catalog_bindings = []
        self.catalog_applied = []
        self.catalog_sources = []

    def read(self, path):
        reference = state_inputs.reference(path)
        self.files[reference["path"]] = reference["sha256"]
        return state_inputs.document(reference), reference

    def bind(self, config_path, report, script, arguments, code, command=None, environment=None):
        if not report.exists():
            return
        state_inputs.require(
            type(code) is int and 0 <= code <= 255, "Incomplete raw return has no accepted runtime receipt"
        )
        config, config_ref = self.read(config_path)
        expected = isolated_measure.bootstrap_command(
            config_path, config_ref["sha256"], script, report, arguments, runtime=config
        )
        if command is not None:
            state_inputs.require(command == expected, "Runtime projection request differs")
        original, reference = self.read(report)
        verified = isolated_measure.verify_runtime_receipt(
            report, config, config_ref["sha256"], script, arguments, code, environment
        )
        state_inputs.require(encoded(original) == encoded(verified), "Runtime receipt changed during verification")
        if config.get("schema_version") in (2, 3):
            self.read(startup_binding.launch_path(report))
        key = digest(original)
        project(original)
        self.accepted[key] = original
        self.bindings.append(
            dict(
                artifact=str(report.relative_to(self.raw)),
                original_raw_sha256=reference["sha256"],
                original_receipt_content_sha256=key,
                runtime_input_sha256=config_ref["sha256"],
                selected_script_sha256=config["code_files"][str(script)],
            )
        )

    def phase_code(self, phase):
        code = phase.get("returncode")
        state_inputs.require(
            type(code) is int
            and type(phase.get("observed_returncode")) is int
            and code == phase["observed_returncode"]
            and (
                (phase.get("completed") is True and code >= 0 and code != 125 and phase.get("failure") is None)
                or (phase.get("completed") is False and code == 125 and phase.get("failure") == "nested-incomplete")
            ),
            "Runtime projection phase outcome is not a typed observed exit",
        )
        return code

    def environment(self, path, developer=None):
        config_path = self.raw / "setup/runtime.json"
        if not config_path.exists():
            config_path = self.raw / "setup/contracts/runtime.json"
        config, _ = self.read(config_path)
        return startup_binding.existing_environment(path, developer) if config.get("schema_version") in (2, 3) else None

    def arm_environment(self, arm, role):
        plan, _ = self.read(self.raw / "setup/plan.json")
        return self.environment(self.raw / "private-readers" / arm / role, plan["engine_config"]["developer_directory"])

    def bind_catalog(self, arm, folder=None):
        folder = folder or self.raw / "runs/restored_rebuilt" / arm
        path = folder / "source-catalog.json"
        if not path.exists():
            return
        relative = str(path.relative_to(self.raw))
        engine = str((folder / "engine-runtime/runtime-result.json").relative_to(self.raw))
        binding = next((row for row in self.bindings if row["artifact"] == engine), None)
        state_inputs.require(binding is not None, "Source catalog has no bound original engine request")
        plan, plan_ref = self.read(self.raw / "setup/plan.json")
        config, config_ref = self.read(folder / "input.json")
        state_inputs.require(
            encoded(config) == encoded(dict(plan["engine_config"], arm=arm, output=str(folder))),
            "Source catalog engine input differs from selected plan",
        )
        derived = state_inputs.generation.verify(config)
        state_inputs.require(encoded(derived) == encoded(plan["accepted"]), "Source catalog generation differs")
        project = Path(config["project"])
        snapshot = state_inputs.source_snapshot(project)
        state_inputs.require(encoded(snapshot) == encoded(config["accepted_sources"]), "Source catalog sources changed")
        for name, row in snapshot.items():
            reference = state_inputs.reference(project / name)
            state_inputs.require(reference["sha256"] == row["sha256"], "Source catalog source bytes changed")
            self.files[reference["path"]] = reference["sha256"]
        for reference in config["generation_receipts"].values():
            _, current = self.read(Path(reference["path"]))
            state_inputs.require(encoded(current) == encoded(reference), "Source catalog generation receipt changed")
        producer = state_inputs.reference(Path(state_inputs.generation.observer.adapter.__file__))
        state_inputs.require(
            producer["sha256"] == config["helper_sha256"]["vendor/mixed/adapter/mixed_adapter.py"],
            "Source catalog producer changed",
        )
        self.files[producer["path"]] = producer["sha256"]
        original, reference = self.read(path)
        project_catalog(original)
        expected = state_inputs.generation.observer.adapter.source_catalog(project, derived["contexts"])
        state_inputs.require(
            encoded(original) == encoded(expected), "Source catalog differs from accepted source declarations"
        )
        self.catalog_sources.append((project, snapshot))
        self.catalogs[relative] = original
        self.catalog_bindings.append(dict(
            artifact=relative, original_raw_sha256=reference["sha256"],
            original_catalog_content_sha256=digest(original),
            original_engine_receipt_sha256=binding["original_raw_sha256"], original_input_sha256=config_ref["sha256"],
            original_plan_sha256=plan_ref["sha256"], accepted_generation_sha256=derived["accepted_generation_sha256"],
            accepted_source_snapshot_sha256=digest(snapshot), producer_sha256=producer["sha256"],
        ))

    def collect(self):
        for label in ["integration", "runtime"]:
            folder = self.raw / "setup/contracts" / label
            if (folder / "runtime-result.json").exists():
                phase, _ = self.read(folder / "process.json")
                self.bind(
                    self.raw / "setup/contracts/runtime.json",
                    folder / "runtime-result.json",
                    ROOT / "contract_suite.py",
                    ["--suite", label, "--output", str(folder / "summary.json")],
                    self.phase_code(phase),
                    phase["command"],
                    self.environment(self.raw / "private-contracts" / label),
                )
        config_path = self.raw / "setup/runtime.json"
        report = self.raw / "setup/state-runtime/runtime-result.json"
        if report.exists():
            phase, _ = self.read(self.raw / "setup/whole-state.json")
            plan, plan_ref = self.read(self.raw / "setup/plan.json")
            _, config_ref = self.read(config_path)
            args = [
                "--plan",
                plan_ref["path"],
                "--plan-sha256",
                plan_ref["sha256"],
                "--runtime",
                str(config_path),
                "--runtime-sha256",
                config_ref["sha256"],
                "--output",
                str(self.raw),
            ]
            self.bind(
                config_path,
                report,
                ROOT / "state_worker.py",
                args,
                self.phase_code(phase),
                phase["command"],
                self.environment(self.raw / "private-state", plan["engine_config"]["developer_directory"]),
            )
        plan_path = self.raw / "setup/plan.json"
        plan, _ = self.read(plan_path) if plan_path.exists() else ({}, None)
        if "calibration" in plan:
            for item in calibration_inventory(self.raw, plan):
                self.collect_calibration(item, config_path, plan)
            return self
        for arm in ["baseline", "cartograph"]:
            folder = self.raw / "runs/restored_rebuilt" / arm
            observer_report = folder / "observer-runtime/runtime-result.json"
            engine_report = folder / "engine-runtime/runtime-result.json"
            if observer_report.exists():
                observer, _ = self.read(folder / "whole-arm.observer.json")
                config, _ = self.read(config_path)
                if config.get("schema_version") == 3:
                    state_inputs.require(isinstance(observer.get("command"), list), "Observer launch argv is missing")
                self.bind(
                    config_path,
                    observer_report,
                    isolated_measure.HELPER,
                    ["--worker"],
                    observer["observed_helper_returncode"],
                    command=observer.get("command"),
                    environment=self.arm_environment(arm, "observer"),
                )
            if engine_report.exists():
                measured, _ = self.read(folder / "whole-arm.json")
                state_inputs.require(
                    measured.get("helper_sha256") == isolated_measure.HELPER_SHA256
                    and measured.get("measurement_mode") == "timing"
                    and measured.get("sampling_during_timing") is False,
                    "Engine projection measurement binding differs",
                )
                request, _ = self.read(folder / "whole-arm.command.json")
                _, inputs = self.read(folder / "input.json")
                self.bind(
                    config_path,
                    engine_report,
                    ROOT / "engine_worker.py",
                    ["--input", inputs["path"], "--sha256", inputs["sha256"]],
                    measured["root_returncode"],
                    request["command"],
                    self.arm_environment(arm, "engine"),
                )
            self.bind_catalog(arm)
        return self

    def collect_calibration(self, item, config_path, plan):
        """각 호출의 원래 요청과 모드에 묶인 영수증만 기존 변환기로 전달한다."""
        folder = self.raw / "runs/calibration" / item["folder"]
        if not folder.exists():
            return
        config, _ = self.read(config_path)
        observer_path = folder / (
            "whole-arm.direct.json" if item["observer"] == "direct" else "whole-arm.observer.json"
        )
        observer = self.read(observer_path)[0] if observer_path.exists() else None
        arm_path, row_path = folder / "arm-result.json", folder / "calibration-result.json"
        arm, arm_ref = self.read(arm_path) if arm_path.exists() else (None, None)
        if arm is not None and observer is not None:
            state_inputs.require(encoded(arm.get("observer")) == encoded(observer), "Calibration observer copy differs")
        if row_path.exists():
            row, _ = self.read(row_path)
            state_inputs.require(
                set(row) == {"invocation", "evaluation", "arm_result"}
                and encoded(row.get("invocation")) == encoded(item)
                and encoded(row.get("arm_result")) == encoded(arm_ref), "Calibration arm reference differs",
            )
        environment = lambda role: self.arm_environment(item["folder"], role)
        observer_report = folder / "observer-runtime/runtime-result.json"
        if item["observer"] == "direct":
            state_inputs.require(not observer_report.exists(), "Direct invocation contains observer runtime")
        elif observer_report.exists():
            state_inputs.require(
                observer is not None and observer.get("mode") == item["observer"]
                and isinstance(observer.get("command"), list)
                and observer.get("periodic_sampling") is (item["observer"] == "memory"),
                "Calibration observer mode differs",
            )
            self.bind(config_path, observer_report, isolated_measure.HELPER, ["--worker"],
                      observer["observed_helper_returncode"], observer.get("command"), environment("observer"))
        engine_report = folder / "engine-runtime/runtime-result.json"
        if engine_report.exists():
            state_inputs.require(observer is not None, "Calibration measurement receipt is missing")
            request, _ = self.read(folder / "whole-arm.command.json")
            inputs, input_ref = self.read(folder / "input.json")
            state_inputs.require(
                encoded(inputs) == encoded(dict(plan["engine_config"], arm=item["engine"], output=str(folder))),
                "Calibration engine input differs",
            )
            measured = observer["measurement"]
            if item["observer"] == "direct":
                state_inputs.require(
                    observer.get("mode") == "direct" and request.get("mode") == "direct"
                    and measured.get("measurement_mode") == "direct"
                    and encoded(observer.get("command")) == encoded(request.get("command"))
                    and encoded(observer.get("workload_returncode")) == encoded(measured.get("root_returncode")),
                    "Direct calibration measurement binding differs",
                )
            else:
                original, _ = self.read(folder / "whole-arm.json")
                state_inputs.require(encoded(measured) == encoded(original), "Calibration measurement copy differs")
                isolated_measure.verify_measurement(folder / "whole-arm", measured, item["observer"], request)
            self.bind(config_path, engine_report, ROOT / "engine_worker.py",
                      ["--input", input_ref["path"], "--sha256", input_ref["sha256"]],
                      measured["root_returncode"], request["command"], environment("engine"))
            original, _ = self.read(engine_report)
            state_inputs.require(
                encoded(observer.get("engine_runtime")) == encoded(original), "Calibration engine runtime copy differs"
            )
        if observer_report.exists():
            original, _ = self.read(observer_report)
            state_inputs.require(
                encoded(observer.get("runtime")) == encoded(original), "Calibration runtime copy differs"
            )
        self.bind_catalog(item["engine"], folder)

    def unchanged(self):
        for project, snapshot in self.catalog_sources:
            state_inputs.require(
                encoded(state_inputs.source_snapshot(project)) == encoded(snapshot),
                "Source catalog source inventory changed"
            )
        for path, expected in self.files.items():
            state_inputs.require(
                state_inputs.reference(Path(path))["sha256"] == expected, "Runtime projection source changed"
            )

    def transform(self, data, relative):
        if not relative.endswith(".json"):
            return data
        original = bootstrap.strict_json(data)
        if relative in self.catalogs:
            state_inputs.require(encoded(original) == encoded(self.catalogs[relative]), "Bound source catalog changed")
            result = project_catalog(original)
            self.catalog_applied.append(dict(
                artifact=relative, location=[], original_catalog_content_sha256=digest(original)
            ))
            return json.dumps(result, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False).encode() + b"\n"
        applied = []

        def visit(value, location):
            if isinstance(value, dict):
                key = digest(value)
                if key in self.accepted:
                    result = project(value)
                    state_inputs.require(
                        encoded(restore(result)) == encoded(self.accepted[key]), "Bound runtime copy differs"
                    )
                    applied.append(dict(location=location, original_receipt_content_sha256=key))
                    return result
                return {name: visit(item, location + [name]) for name, item in value.items()}
            if isinstance(value, list):
                return [visit(item, location + [index]) for index, item in enumerate(value)]
            return value

        result = visit(original, [])
        if not applied:
            return data
        self.applied.append(dict(artifact=relative, receipts=applied))
        return json.dumps(result, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False).encode() + b"\n"


def package(normalizer, args):
    projection = Projection(args.input).collect()

    class BoundNormalizer(normalizer.Normalizer):
        def transform_input(self, data, relative):
            return projection.transform(data, relative)

    manifest = normalizer.package(args, normalizer_type=BoundNormalizer)
    projection.unchanged()
    manifest["runtime_module_projection"] = dict(
        format=FORMAT,
        binding_scope="Original request/runtime verification only; public entries are not execution authority",
        original_receipts=projection.bindings,
        transformed_artifacts=projection.applied,
        hash_policy="Raw file/map hashes retain their original meaning. Reconstruct named entries before map verification; normalized paths still use normalized manifest hashes.",
    )
    normalizer.check_sensitive(json.dumps(manifest["runtime_module_projection"]), "runtime-module-projection")
    if projection.catalog_bindings:
        manifest["source_catalog_projection"] = dict(
            format=CATALOG_FORMAT,
            binding_scope="Exact source-derived catalogs for the original engine inputs; no execution outcome changes",
            field_mapping=dict(original_field="token", public_field="declaration_lexeme"),
            original_catalogs=projection.catalog_bindings,
            transformed_artifacts=projection.catalog_applied,
            hash_policy=(
                "Raw file/content hashes retain their original meaning. Restore the declaration field before "
                "content verification; normalized bytes use manifest hashes."
            ),
        )
        normalizer.check_sensitive(json.dumps(manifest["source_catalog_projection"]), "source-catalog-projection")
    target = Path(args.output) / "manifest.json"
    target.write_text(json.dumps(manifest, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    return manifest
