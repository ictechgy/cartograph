#!/usr/bin/env python3
"""Check native gate failure propagation without claiming a native execution."""

import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("gate", Path(__file__).with_name("run-feedback-native-gate.py"))
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class NativeGateTests(unittest.TestCase):
    def test_commands_preserve_full_coverage_and_bounded_raw_gate(self):
        raw, raw_time, raw_limit = GATE.gate_spec("raw")
        self.assertEqual(raw[-1], "AssociatedTypeWitnessCompilerTests")
        self.assertIn("--enable-code-coverage", raw)
        self.assertEqual(raw_time, 270)
        self.assertEqual(raw_limit, 8 * 1024 * 1024)
        self.assertEqual(GATE.gate_spec("coverage"), (["bash", "Scripts/coverage.sh"], 840, 64 * 1024 * 1024))

    def test_failure_unknown_cleanup_and_exceptions_remain_failures(self):
        good = {"returncode": 0, "timed_out": False, "owned_root_reaped": True, "ownership_lost": False,
                "cleanup_errors": [], "output_limit_exceeded": None, "exception_type": None}
        variants = [(good, 0)]
        for key, value in (("returncode", 1), ("timed_out", True), ("owned_root_reaped", False),
                           ("ownership_lost", True), ("cleanup_errors", ["unknown"]),
                           ("output_limit_exceeded", "stdout"), ("exception_type", "OSError")):
            broken = copy.deepcopy(good)
            broken[key] = value
            variants.append((broken, 1))
        variants.extend((({}, 1), (RuntimeError("startup failure"), 1)))
        with tempfile.TemporaryDirectory(prefix="native-gate-contract-") as temporary:
            root = Path(temporary)
            previous = os.environ.get("CARTOGRAPH_ASSOCIATED_WITNESS_EVIDENCE")
            for number, (receipt, expected) in enumerate(variants):
                output = root / str(number)

                def runner(command, cwd, stem, **kwargs):
                    self.assertEqual(json.loads((output / "gate.json").read_text())["status"], "started")
                    self.assertEqual(os.environ["CARTOGRAPH_ASSOCIATED_WITNESS_EVIDENCE"],
                                     str(output / "raw-occurrences.json"))
                    if isinstance(receipt, Exception):
                        raise receipt
                    (output / "raw-occurrences.json").write_text("[{}]", encoding="utf-8")
                    phases = output / "cartograph-associated-witness-controlled"
                    phases.mkdir()
                    (phases / "phases.jsonl").write_text(
                        '{"name":"witness-assertions-complete"}\n', encoding="utf-8")
                    return receipt

                def save(path, value):
                    path.write_text(json.dumps(value), encoding="utf-8")

                with self.subTest(receipt=receipt), contextlib.redirect_stdout(io.StringIO()), \
                        contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(GATE.run_gate("raw", output, runner, save), expected)
                    self.assertEqual(json.loads((output / "gate.json").read_text())["status"],
                                     "passed" if expected == 0 else "failed")
                self.assertEqual(os.environ.get("CARTOGRAPH_ASSOCIATED_WITNESS_EVIDENCE"), previous)

    def test_success_without_executed_raw_assertions_is_rejected(self):
        good = {"returncode": 0, "timed_out": False, "owned_root_reaped": True, "ownership_lost": False,
                "cleanup_errors": [], "output_limit_exceeded": None, "exception_type": None}
        with tempfile.TemporaryDirectory(prefix="native-no-assertions-") as temporary:
            for variant in ("missing", "incomplete", "oversize"):
                output = Path(temporary) / variant

                def runner(*args, **kwargs):
                    if variant != "missing":
                        (output / "raw-occurrences.json").write_text("[{}]", encoding="utf-8")
                        phases = output / "cartograph-associated-witness-controlled"
                        phases.mkdir()
                        text = '{"name":"raw-index-read-start"}\n' if variant == "incomplete" else "x" * 1048577
                        (phases / "phases.jsonl").write_text(text, encoding="utf-8")
                    return good

                def save(path, value):
                    path.write_text(json.dumps(value), encoding="utf-8")

                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(GATE.run_gate("raw", output, runner, save), 1)


if __name__ == "__main__":
    unittest.main()
