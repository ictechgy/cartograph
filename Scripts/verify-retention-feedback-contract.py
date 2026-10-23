#!/usr/bin/env python3
"""Offline control-flow tests; these do not execute Swift or count as public deltas."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("retention_feedback", Path(__file__).with_name("verify-retention-feedback.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RetentionMeasurementContractTests(unittest.TestCase):
    def complete(self, new=True):
        return {"corpus": {"passed": True}, "measurementsComplete": True, "projects": [
            {"name": name, "revision": revision, "newlyReported": ([{"reviewKey": name}] if new else [])}
            for name, _, revision, _, _ in MODULE.PROJECTS]}

    def test_baseline_restores_only_two_flags_and_refuses_unknown_shape(self):
        source = (Path(__file__).resolve().parents[1] / MODULE.REASON).read_text(encoding="utf-8")
        result = MODULE.restore_unconditional(source)
        for current, old in MODULE.REVERSALS:
            self.assertNotIn(current, result)
            self.assertIn(old, result)
        with self.assertRaises(ValueError):
            MODULE.restore_unconditional(result)
        with self.assertRaises(ValueError):
            MODULE.restore_unconditional(source + source)

    def test_no_manual_review_never_passes_nonempty_delta(self):
        gate = MODULE.review_status(self.complete(), {})
        self.assertEqual("pending", gate["status"])
        self.assertEqual(3, gate["required"])

    def test_zero_delta_requires_three_distinct_complete_pins(self):
        results = self.complete(new=False)
        self.assertEqual("passed", MODULE.review_status(results, {})["status"])
        results["projects"][2] = results["projects"][0]
        self.assertEqual("pending", MODULE.review_status(results, {})["status"])
        results = self.complete(new=False)
        results["measurementsComplete"] = False
        self.assertEqual("pending", MODULE.review_status(results, {})["status"])
        results = self.complete(new=False)
        results["projects"].pop()
        self.assertEqual("pending", MODULE.review_status(results, {})["status"])

    def test_reviews_require_exact_keys_reviewer_and_evidence(self):
        results = self.complete()
        review = {"reviews": [{"reviewKey": name, "reviewer": "reviewer", "decision": "confirmed",
                               "evidence": "Reviewed declaration and all name occurrences."}
                              for name, _, _, _, _ in MODULE.PROJECTS]}
        self.assertEqual("passed", MODULE.review_status(results, review)["status"])
        review["reviews"][0]["evidence"] = ""
        with self.assertRaises(ValueError):
            MODULE.review_status(results, review)
        with self.assertRaises(ValueError):
            MODULE.review_status(results, {"reviews": [{"reviewKey": "stale"}]})

    def test_source_search_counts_mentions_but_does_not_approve(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Source.swift").write_text("struct Dead {}\n// Dead Dead\nstruct NotDead {}\n")
            result = MODULE.source_mentions(root, {"message": "struct 'Module.Dead' is never used"})
            self.assertEqual(3, result["occurrenceCount"])
            self.assertEqual(2, len(result["matches"]))
            self.assertEqual("searched-not-reviewed", result["status"])
            self.assertEqual(0, result["omittedMatchingLines"])

    def test_suppression_empty_index_and_oversize_reports_are_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            for report in [{"diagnostics": [], "suppressedCount": 1},
                           {"diagnostics": [], "suppressedCount": 0, "limitations": ["empty-index: skipped"]}]:
                path.write_text(json.dumps(report))
                with self.assertRaises(ValueError):
                    MODULE.read_document(path)
            original = MODULE.MAX_JSON
            try:
                MODULE.MAX_JSON = 8
                path.write_bytes(b" " * 9)
                with self.assertRaises(ValueError):
                    MODULE.read_document(path)
            finally:
                MODULE.MAX_JSON = original

    def test_missing_and_ambiguous_index_are_not_empty_measurements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                MODULE.select_index(root)
            (root / ".build/out/v5/units").mkdir(parents=True)
            self.assertEqual((root / ".build/out").resolve(), MODULE.select_index(root))
            (root / ".build/debug/index/store/v5/units").mkdir(parents=True)
            with self.assertRaises(ValueError):
                MODULE.select_index(root)


if __name__ == "__main__":
    unittest.main()
