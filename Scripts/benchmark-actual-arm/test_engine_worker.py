"""독립 선택자 계약과 중단 코드를 엔진 진입점 경계에서 확인한다."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import engine_worker as worker


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.queries = [dict(id=f"q{i}", context="module", signature=f"f{i}()", max_depth=5) for i in range(10)]

    def test_distinct_semantic_queries_pass(self):
        worker.selectors(self.queries)

    def test_duplicate_semantic_seed_is_not_hidden_by_distinct_id(self):
        self.queries[1]["signature"] = self.queries[0]["signature"]
        with self.assertRaises(ValueError):
            worker.selectors(self.queries)

    def test_gold_and_oracle_query_fields_refuse(self):
        for key in ("expected", "oracle", "answers"):
            queries = json.loads(json.dumps(self.queries))
            queries[0][key] = []
            with self.assertRaises(ValueError):
                worker.selectors(queries)

    def test_boolean_depth_and_mixed_depth_refuse(self):
        for value in (True, 3):
            queries = json.loads(json.dumps(self.queries))
            queries[0]["max_depth"] = value
            with self.assertRaises(ValueError):
                worker.selectors(queries)

    def test_input_hash_refusal_happens_before_guard_or_engine(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "input.json"
            path.write_text(json.dumps(dict(queries=self.queries)))
            with mock.patch.object(worker.primitive.generation, "verify") as guard:
                with self.assertRaises(ValueError):
                    worker.execute(path, "0" * 64)
                guard.assert_not_called()

    def test_incomplete_worker_preserves125(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "input.json"
            path.write_text(json.dumps(dict(queries=self.queries)))
            with mock.patch.object(worker.primitive.generation, "verify"), mock.patch.object(
                worker.primitive, "execute_worker", return_value=dict(status="incomplete")
            ):
                self.assertEqual(worker.execute(path, hashlib.sha256(path.read_bytes()).hexdigest()), 125)


if __name__ == "__main__":
    unittest.main(verbosity=2)
