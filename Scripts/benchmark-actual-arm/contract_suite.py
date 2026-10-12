#!/usr/bin/env python3
"""봉인된 설치로 고정된 두 계약 모음을 실행하며 누락·건너뜀을 성공으로 숨기지 않는다."""

from __future__ import annotations

import argparse
import importlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parent
SUITES = {
    "integration": (
        [
            "test_bound_arm_process",
            "test_completion_binding",
            "test_controller_execution",
            "test_correctness_controller",
            "test_engine_worker",
            "test_installation_binding",
            "test_installer_identity",
            "test_publication",
            "test_runner_pin",
            "test_sdk_reference",
            "test_state_inputs",
            "test_state_worker",
            "test_contract_prerequisites",
            "test_runtime_publication",
        ],
        139,
    ),
    "runtime": (["test_runtime_bootstrap", "test_runtime_identity"], 43),
}


def cases(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from cases(item)
        else:
            yield item


def execute_suite(suite, expected_count, output, label):
    ids = [item.id() for item in cases(suite)]
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    passed = (
        type(expected_count) is int
        and expected_count > 0
        and len(ids) == expected_count == result.testsRun
        and len(ids) == len(set(ids))
        and result.wasSuccessful()
        and not result.skipped
        and not result.expectedFailures
        and not result.unexpectedSuccesses
    )
    receipt = dict(
        schema_version=1,
        role="bound-contract-suite",
        suite=label,
        status="passed" if passed else "failed",
        exit_code=0 if passed else 1,
        expected_tests=expected_count,
        discovered_tests=len(ids),
        tests_run=result.testsRun,
        test_ids=ids,
        failures=[test.id() for test, _ in result.failures],
        errors=[test.id() for test, _ in result.errors],
        skipped=[test.id() for test, _ in result.skipped],
        expected_failures=[test.id() for test, _ in result.expectedFailures],
        unexpected_successes=[test.id() for test in result.unexpectedSuccesses],
        final_evidence=False,
    )
    with Path(output).open("x") as stream:
        json.dump(receipt, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write("\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=sorted(SUITES), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not (sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode):
        raise ValueError("Contract suite requires the verified isolated runtime bootstrap")
    # 두 모음은 서로 다른 새 프로세스에서 같은 정확한 설치를 사용한다.
    sys.path.insert(0, str(ROOT))
    sys.path.insert(0, str(ROOT / "runtime"))
    modules, count = SUITES[args.suite]
    suite = unittest.TestSuite()
    for name in modules:
        module = importlib.import_module(name)
        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
    raise SystemExit(execute_suite(suite, count, args.output, args.suite)["exit_code"])


if __name__ == "__main__":
    main()
