#!/usr/bin/env python3
"""신선도 하네스가 성공·실패 양방향과 진단 경로의 정확한 집합을 검사하는지 검증한다."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("freshness", Path(__file__).with_name("verify-index-freshness.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class FreshnessContract(unittest.TestCase):
    def test_clean_result_has_no_freshness_warning(self):
        harness.check_limitations({"status": "found", "limitations": ["objective-c-sources: 1 file(s)"]}, {})

    def test_exact_relative_path_set_passes(self):
        harness.check_limitations(
            {"status": "found", "limitations": ['missing-sources: 1; paths: ["Sources/API.h"]']},
            {"missing-sources": {"Sources/API.h"}},
        )

    def test_missing_warning_and_graph_location_fail(self):
        with self.assertRaises(RuntimeError):
            harness.check_limitations(
                {"status": "found", "limitations": [], "location": {"path": "Sources/API.h"}},
                {"missing-sources": {"Sources/API.h"}},
            )

    def test_wrong_extra_or_unscoped_path_fails(self):
        for paths in ('["Sources/Other.h"]', '["Sources/API.h","Sources/Other.h"]', '["/private/API.h"]'):
            with self.subTest(paths=paths), self.assertRaises(RuntimeError):
                harness.check_limitations(
                    {"status": "found", "limitations": ["missing-sources: paths; paths: " + paths]},
                    {"missing-sources": {"Sources/API.h"}},
                )

    def test_stale_warning_in_clean_control_fails(self):
        with self.assertRaises(RuntimeError):
            harness.check_limitations(
                {"status": "found", "limitations": ['index-staleness: 1; paths: ["Sources/API.h"]']},
                {},
            )

    def test_unknown_query_and_count_only_warning_fail(self):
        for document in (
            {"status": "notFound", "limitations": []},
            {"status": "found", "limitations": ["missing-sources: 1 source file"]},
            {"status": "found"},
        ):
            with self.subTest(document=document), self.assertRaises(RuntimeError):
                harness.check_limitations(document, {})


if __name__ == "__main__":
    unittest.main()
