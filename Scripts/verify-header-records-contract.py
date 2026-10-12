#!/usr/bin/env python3
"""헤더 CLI 하네스는 누락·추가 간선과 모호한 선언을 성공으로 읽지 않는다."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("harness", Path(__file__).with_name("verify-header-records.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
FIXTURE = Path(__file__).resolve().parents[1] / "Fixtures/HeaderRecordCorpus"
ORACLE = json.loads((FIXTURE / "oracle.json").read_text())


def graph():
    return {
        "nodes": [
            {
                "id": key,
                "usr": key,
                "name": s["name"],
                "kind": "function",
                "location": {"path": s["path"], "line": s["line"], "column": s["column"]},
            }
            for key, s in ORACLE["symbols"].items()
        ],
        "edges": [{"source": a, "target": b, "kind": "call", "weight": 1} for a, b in ORACLE["calls"]],
    }


class Contracts(unittest.TestCase):
    def test_authored_anchors_and_exact_graph(self):
        m.verify_source(ORACLE, FIXTURE)
        self.assertEqual(len(m.verify_graph(graph(), ORACLE, FIXTURE)), 9)

    def test_original_two_missing_header_definitions_fail(self):
        g = graph()
        g["nodes"] = [n for n in g["nodes"] if n["id"] not in ("headerC", "headerCpp")]
        with self.assertRaises(RuntimeError):
            m.verify_graph(g, ORACLE, FIXTURE)

    def test_each_original_missing_header_edge_fails(self):
        for pair in ORACLE["calls"]:
            if pair == ["cppBridge", "cppHelper"]:
                continue
            with self.subTest(pair=pair):
                g = graph()
                g["edges"] = [e for e in g["edges"] if [e["source"], e["target"]] != pair]
                with self.assertRaises(RuntimeError):
                    m.verify_graph(g, ORACLE, FIXTURE)

    def test_extra_edge_or_duplicate_definition_fails(self):
        for duplicate in (False, True):
            g = graph()
            if duplicate:
                g["nodes"].append(copy.deepcopy(g["nodes"][0]))
            else:
                g["edges"].append({"source": "unused", "target": "base", "kind": "call", "weight": 1})
            with self.assertRaises(RuntimeError):
                m.verify_graph(g, ORACLE, FIXTURE)

    def test_changed_source_anchor_fails(self):
        o = copy.deepcopy(ORACLE)
        o["symbols"]["headerC"]["line"] = 18
        with self.assertRaises(RuntimeError):
            m.verify_source(o, FIXTURE)

    def test_symlink_project_has_same_source_identity(self):
        with tempfile.TemporaryDirectory() as root:
            alias = Path(root) / "Alias"
            alias.symlink_to(FIXTURE, target_is_directory=True)
            g = graph()
            for n in g["nodes"]:
                n["location"]["path"] = str(FIXTURE / n["location"]["path"])
            self.assertEqual(len(m.verify_graph(g, ORACLE, alias)), 9)


if __name__ == "__main__":
    unittest.main()
