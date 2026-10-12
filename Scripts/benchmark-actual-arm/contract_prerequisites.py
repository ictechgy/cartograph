"""제품 실행 전에 같은 설치의 별도 런타임으로 전체 계약과 완료 영수증을 검증한다."""

from __future__ import annotations

import json
import math
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "runtime"))
import runtime_identity as identity
import isolated_measure
import state_inputs
import contract_suite

COST_SCOPE = (
    "Both complete suite processes and receipt verification, nested in controller preparation and outer child wall"
)


class Failed(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__("Required bound contract suite failed")


def same(left, right):
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)


def source_paths(engine_paths):
    tests = [name + ".py" for name in contract_suite.SUITES["integration"][0]]
    tests += ["runtime/" + name + ".py" for name in contract_suite.SUITES["runtime"][0]]
    fixtures = [
        "installer-original.py",
        "installer-successor.py",
        "selector-runner-original.py",
        "selector-runner-successor.py",
    ]
    return sorted(
        set(
            engine_paths
            + tests
            + fixtures
            + ["contract_suite.py", "contract_prerequisites.py", "runtime_publication.py"]
        )
    )


def validate_suite(summary, label):
    count = contract_suite.SUITES[label][1]
    state_inputs.require(
        isinstance(summary, dict)
        and type(summary.get("schema_version")) is int
        and summary["schema_version"] == 1
        and summary.get("role") == "bound-contract-suite"
        and summary.get("suite") == label
        and summary.get("status") == "passed"
        and type(summary.get("exit_code")) is int
        and summary["exit_code"] == 0
        and summary.get("final_evidence") is False,
        "Contract suite did not complete successfully",
    )
    state_inputs.require(
        all(
            type(summary.get(key)) is int and summary[key] == count
            for key in ["expected_tests", "discovered_tests", "tests_run"]
        )
        and isinstance(summary.get("test_ids"), list)
        and len(summary["test_ids"]) == count
        and all(isinstance(value, str) for value in summary["test_ids"])
        and len(set(summary["test_ids"])) == count
        and {value.split(".")[0] for value in summary["test_ids"]} == set(contract_suite.SUITES[label][0])
        and all(
            summary.get(key) == []
            for key in ["failures", "errors", "skipped", "expected_failures", "unexpected_successes"]
        ),
        "Contract suite count, module inventory or skip contract failed",
    )


def verify(root, expected=None, engine_runtime=None):
    """검사 결과를 실제 명령·런타임·전체 테스트 영수증과 다시 결합한다."""
    root = Path(root)
    summary_ref = state_inputs.reference(root / "results.json")
    summary = state_inputs.document(summary_ref)
    if expected is not None:
        state_inputs.require(same(summary, expected), "Embedded contract results differ")
    state_inputs.require(
        set(summary)
        == {
            "schema_version",
            "role",
            "status",
            "exit_code",
            "final_evidence",
            "suites",
            "wall_seconds_before_receipt",
            "cost_scope",
        }
        and type(summary.get("schema_version")) is int
        and summary["schema_version"] == 1
        and summary.get("role") == "bound-contract-prerequisites"
        and summary.get("final_evidence") is False
        and type(summary.get("wall_seconds_before_receipt")) in (int, float)
        and math.isfinite(summary["wall_seconds_before_receipt"])
        and summary["wall_seconds_before_receipt"] >= 0
        and summary.get("cost_scope") == COST_SCOPE
        and summary.get("status") == "passed"
        and type(summary.get("exit_code")) is int
        and summary["exit_code"] == 0,
        "Contracts prerequisite failed",
    )
    runtime_ref = state_inputs.reference(root / "runtime.json")
    runtime = state_inputs.document(runtime_ref)
    if engine_runtime is not None:
        state_inputs.require(
            same(runtime["package"], engine_runtime["package"])
            and same(runtime["python"], engine_runtime["python"])
            and all(runtime["code_files"].get(path) == digest for path, digest in engine_runtime["code_files"].items()),
            "Contract prerequisites use different installed/runtime inputs",
        )
    refs = {"contracts_results": summary_ref, "contracts_inputs": runtime_ref}
    state_inputs.require(
        [row.get("suite") for row in summary.get("suites", [])] == ["integration", "runtime"], "Missing contract suite"
    )
    for row in summary["suites"]:
        state_inputs.require(
            set(row) == {"suite", "process", "runtime", "summary"}, "Contract suite receipt shape differs"
        )
        label = row["suite"]
        folder = root / label
        phase_ref = state_inputs.reference(folder / "process.json")
        phase = state_inputs.document(phase_ref)
        state_inputs.require(same(phase, row["process"]), "Embedded contract phase differs")
        import installation_binding

        installation_binding.completed(phase)
        args = ["--suite", label, "--output", str(folder / "summary.json")]
        command = isolated_measure.bootstrap_command(
            Path(runtime_ref["path"]),
            runtime_ref["sha256"],
            ROOT / "contract_suite.py",
            folder / "runtime-result.json",
            args,
        )
        state_inputs.require(phase["command"] == command, "Contract bootstrap request differs")
        receipt = isolated_measure.verify_runtime_receipt(
            folder / "runtime-result.json", runtime, runtime_ref["sha256"], ROOT / "contract_suite.py", args, 0
        )
        state_inputs.require(same(receipt, row["runtime"]), "Embedded contract runtime differs")
        result_ref = state_inputs.reference(folder / "summary.json")
        result = state_inputs.document(result_ref)
        state_inputs.require(same(result, row["summary"]), "Embedded contract suite differs")
        validate_suite(result, label)
        refs["contracts_" + label + "_process"] = phase_ref
        refs["contracts_" + label + "_runtime"] = state_inputs.reference(folder / "runtime-result.json")
        refs["contracts_" + label + "_summary"] = result_ref
    return refs


def run(binding, output, engine_paths, command_runner, save):
    started = time.perf_counter()
    root = Path(output) / "setup/contracts"
    root.mkdir()
    sources = {str(ROOT / name): identity.file_identity(ROOT / name)["sha256"] for name in source_paths(engine_paths)}
    runtime = dict(schema_version=1, package=binding["package"], python=binding["python"], code_files=sources)
    save(root / "runtime.json", runtime)
    runtime_ref = state_inputs.reference(root / "runtime.json")
    result = dict(
        schema_version=1,
        role="bound-contract-prerequisites",
        status="failed",
        exit_code=1,
        final_evidence=False,
        suites=[],
    )
    try:
        for label in ["integration", "runtime"]:
            folder = root / label
            folder.mkdir()
            arguments = ["--suite", label, "--output", str(folder / "summary.json")]
            command = isolated_measure.bootstrap_command(
                root / "runtime.json",
                runtime_ref["sha256"],
                ROOT / "contract_suite.py",
                folder / "runtime-result.json",
                arguments,
            )
            env = identity.private_environment(Path(output) / "private-contracts" / label)
            phase = command_runner.command(command, ROOT, folder / "process", env, 180)
            row = dict(suite=label, process=phase)
            result["suites"].append(row)
            if not phase["completed"] or phase["returncode"] == 125:
                result.update(status="incomplete", exit_code=125)
                break
            row["runtime"] = isolated_measure.verify_runtime_receipt(
                folder / "runtime-result.json",
                runtime,
                runtime_ref["sha256"],
                ROOT / "contract_suite.py",
                arguments,
                phase["returncode"],
            )
            row["summary"] = state_inputs.document(state_inputs.reference(folder / "summary.json"))
            if not phase["passed"]:
                break
            validate_suite(row["summary"], label)
        else:
            result.update(status="passed", exit_code=0)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        result.update(status="incomplete", exit_code=125, failure=type(error).__name__)
    result["wall_seconds_before_receipt"] = time.perf_counter() - started
    result["cost_scope"] = COST_SCOPE
    save(root / "results.json", result)
    if result["status"] == "passed":
        verify(root, result)
    return result
