#!/usr/bin/env python3
"""Offline oracle checks; never substitutes for the native compiler fixture."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("extension_architecture", Path(__file__).with_name("verify-extension-architecture.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def graph(pairs):
    nodes = sorted({value for pair in pairs for value in pair})
    edges = [{"source": source, "target": target, "kind": "reference"} for source, target in sorted(pairs)]
    return {"nodes": [{"id": node, "module": node.split(".")[0], "name": node.split(".")[-1]} for node in nodes],
            "edges": edges, "nodeCount": len(nodes), "edgeCount": len(edges)}


class ArchitectureOracleTests(unittest.TestCase):
    def documents(self, project):
        result = {"module": graph(MODULE.MODULE_PAIRS),
                  "file": graph({(str(project / a), str(project / b)) for a, b in MODULE.FILE_PAIRS}),
                  "type": graph({("Domain.DomainType", "Presentation.AppProtocol"),
                                 ("Presentation.AppProtocol", "Domain.DomainType"),
                                 ("CycleControl.Left", "CycleControl.Right"),
                                 ("CycleControl.Right", "CycleControl.Left")}),
                  "rules": {"suppressedCount": 0, "diagnostics": [{"ruleIdentifier": "layer-violation",
                            "message": "Presentation depends on Data"}]}}
        for level in ["file", "module"]:
            evidence = copy.deepcopy(result[level])
            evidence.update(evidence=copy.deepcopy(evidence["edges"]), evidenceCount=len(evidence["edges"]))
            result[level + "-evidence"] = evidence
        return result

    def test_complete_expected_graph_and_controls_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            MODULE.validate_candidate(self.documents(project), project)

    def test_reverse_edge_or_lost_real_dependency_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            for pairs in [MODULE.MODULE_PAIRS | {("Domain", "Presentation")},
                          MODULE.MODULE_PAIRS - {("Presentation", "Data")}]:
                result = self.documents(project)
                result["module"] = graph(pairs)
                with self.assertRaises(ValueError):
                    MODULE.validate_candidate(result, project)

    def test_lost_type_cycle_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            result = self.documents(project)
            result["type"]["edges"].pop()
            result["type"]["edgeCount"] -= 1
            with self.assertRaises(ValueError):
                MODULE.validate_candidate(result, project)

    def test_missing_or_misattributed_evidence_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            for missing in [True, False]:
                result = self.documents(project)
                evidence = result["module-evidence"]
                if missing:
                    evidence["evidence"].pop()
                    evidence["evidenceCount"] -= 1
                else:
                    evidence["evidence"][0]["source"] = "wrong-owner"
                with self.assertRaises(ValueError):
                    MODULE.validate_candidate(result, project)

    def test_suppressed_or_missing_real_violation_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            for rules in [{"suppressedCount": 1, "diagnostics": []},
                          {"suppressedCount": 0, "diagnostics": []}]:
                result = self.documents(project)
                result["rules"] = rules
                with self.assertRaises(ValueError):
                    MODULE.validate_candidate(result, project)

    def test_truncated_graph_is_not_a_pass(self):
        document = graph(MODULE.MODULE_PAIRS)
        document["edgeCount"] += 1
        with self.assertRaises(ValueError):
            MODULE.pairs(document)


if __name__ == "__main__":
    unittest.main()
