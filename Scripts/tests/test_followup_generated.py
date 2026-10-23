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


if __name__ == "__main__":
    unittest.main()
