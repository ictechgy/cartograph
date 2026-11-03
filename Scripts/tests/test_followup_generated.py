"""Mutation controls for the native CLI comparison oracle, not product Swift execution."""

import copy
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "followup_generated", pathlib.Path(__file__).resolve().parents[1] / "followup-verify-generated.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GeneratedOracleTests(unittest.TestCase):
    def documents(self):
        plain = {"diagnostics": [1, 2, 3], "limitations": ["unknown-scope"], "suppressedCount": 4}
        files = [{"path": path, "findingCount": 1} for path in
                 ("Generated.swift", "DesignTokens.swift", "NeedleGenerated.swift")]
        summary = copy.deepcopy(plain)
        summary["findingReview"] = {"findingCount": 3, "files": files, "totalFileCount": 3,
                                    "omittedFileCount": 0, "markerReviewRequested": False, "markerBytesRead": 0}
        generated = copy.deepcopy(summary)
        generated["findingReview"]["markerReviewRequested"] = True
        for file in generated["findingReview"]["files"]:
            file["generatedMarker"] = {"status": "noMarkerInHeader"}
        generated["findingReview"]["files"][0]["generatedMarker"] = {
            "status": "markerObserved", "evidence": {"line": 1, "text": "// @generated"},
            "fileStableDuringRead": True, "suggestion": "review retention.retained_files"}
        return plain, summary, generated

    def test_accepts_additive_review(self):
        module.verify_documents(*self.documents())

    def test_rejects_deleted_finding(self):
        documents = self.documents()
        documents[2]["diagnostics"].pop()
        with self.assertRaises(AssertionError):
            module.verify_documents(*documents)

    def test_rejects_lost_limitation(self):
        documents = self.documents()
        documents[1].pop("limitations")
        with self.assertRaises(AssertionError):
            module.verify_documents(*documents)

    def test_rejects_filename_inference(self):
        documents = self.documents()
        documents[2]["findingReview"]["files"][2]["generatedMarker"]["status"] = "markerObserved"
        with self.assertRaises(AssertionError):
            module.verify_documents(*documents)

    def test_rejects_lost_baseline_count(self):
        documents = self.documents()
        documents[2]["suppressedCount"] = 0
        with self.assertRaises(AssertionError):
            module.verify_documents(*documents)

    def test_review_still_requires_the_same_embedded_version(self):
        documents = self.documents()
        for document in documents:
            document["version"] = "0.30.0"
        documents[1]["version"] = "0.29.0"
        with self.assertRaises(AssertionError):
            module.verify_documents(*documents)

    def baseline_documents(self):
        baseline = {"tool": "cartograph", "version": "0.29.0", "command": "dead",
                    "diagnostics": [{"message": "unused", "version": "fact-version"}],
                    "limitations": ["unknown-scope"], "suppressedCount": 4}
        candidate = copy.deepcopy(baseline)
        candidate["version"] = "0.30.0"
        return baseline, candidate

    def test_accepts_only_observed_tool_version_difference(self):
        baseline, candidate = self.baseline_documents()
        module.verify_baseline(baseline, candidate, "0.29.0", "0.30.0")
        self.assertEqual(baseline["version"], "0.29.0")
        self.assertEqual(candidate["version"], "0.30.0")

    def test_rejects_unobserved_or_missing_embedded_version(self):
        for version in ["0.31.0", None]:
            with self.subTest(version=version):
                baseline, candidate = self.baseline_documents()
                if version is None:
                    candidate.pop("version")
                else:
                    candidate["version"] = version
                with self.assertRaises(AssertionError):
                    module.verify_baseline(baseline, candidate, "0.29.0", "0.30.0")

    def test_rejects_any_non_version_baseline_difference(self):
        for change in ["finding", "nested-version", "limitation", "suppression", "tool", "extra"]:
            with self.subTest(change=change):
                baseline, candidate = self.baseline_documents()
                if change == "finding":
                    candidate["diagnostics"] = []
                elif change == "nested-version":
                    candidate["diagnostics"][0]["version"] = "changed-fact"
                elif change == "limitation":
                    candidate["limitations"] = []
                elif change == "suppression":
                    candidate["suppressedCount"] = 0
                elif change == "tool":
                    candidate["tool"] = "other"
                else:
                    candidate["unknown"] = True
                with self.assertRaises(AssertionError):
                    module.verify_baseline(baseline, candidate, "0.29.0", "0.30.0")

    def test_rejects_wrong_baseline_tool_identity_and_version(self):
        for field, value in [("tool", "other"), ("version", "0.28.0")]:
            with self.subTest(field=field):
                baseline, candidate = self.baseline_documents()
                baseline[field] = value
                with self.assertRaises(AssertionError):
                    module.verify_baseline(baseline, candidate, "0.29.0", "0.30.0")


if __name__ == "__main__":
    unittest.main()
