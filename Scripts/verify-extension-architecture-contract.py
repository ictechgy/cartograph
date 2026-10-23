#!/usr/bin/env python3
"""Offline oracle checks; never substitutes for the native compiler fixture."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

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

    def variant_documents(self, project):
        result = self.documents(project)
        result["file"] = graph({(str(project / a), str(project / b)) for a, b in MODULE.VARIANT_FILE_CONTROLS})
        result["type"] = graph(MODULE.VARIANT_TYPE_PAIRS)
        for level in ["file", "module"]:
            evidence = copy.deepcopy(result[level])
            evidence.update(evidence=copy.deepcopy(evidence["edges"]), evidenceCount=len(evidence["edges"]))
            result[level + "-evidence"] = evidence
        return result

    def test_variants_keep_conformances_and_true_cycles(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            MODULE.validate_variants_candidate(self.variant_documents(project), project)

    def test_variants_reject_reverse_domain_file_without_a_module_reverse(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            result = self.variant_documents(project)
            result["file"] = graph({(str(project / a), str(project / b)) for a, b in
                MODULE.VARIANT_FILE_CONTROLS | {("Sources/Domain/DomainTypes.swift",
                    "Sources/Presentation/DefaultAliasConformance.swift")}})
            with self.assertRaisesRegex(ValueError, "original domain file"):
                MODULE.validate_variants_candidate(result, project)

    def test_variants_reject_lost_semantic_witness_and_real_file_cycle(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            for level in ["file", "type"]:
                result = self.variant_documents(project)
                result[level]["edges"].pop()
                result[level]["edgeCount"] -= 1
                with self.assertRaises(ValueError):
                    MODULE.validate_variants_candidate(result, project)

    def test_exhausted_budget_starts_no_native_process(self):
        base = SimpleNamespace(run=mock.Mock())
        runner = MODULE.corpus_runner(base, Path("unused"), {"measurements": []}, deadline=0)
        with self.assertRaises(TimeoutError):
            runner(["unused"], Path("unused"), "unused")
        base.run.assert_not_called()

    def test_variant_failure_keeps_both_receipts_without_starting_a_python_wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            results = {"status": "candidate-controls-passed"}
            base = SimpleNamespace(run=mock.Mock())

            def incomplete(_args, _repo, actual_base, corpus, destination, deadline):
                self.assertIs(actual_base, base)
                self.assertEqual(corpus, "variants")
                self.assertGreater(deadline, time.monotonic())
                MODULE.save(destination / "results.json", {"status": "incomplete", "error": "native-timeout"})
                MODULE.save(destination / "logs" / "native.json", {"timed_out": True, "owned_root_reaped": True})
                raise RuntimeError("native-timeout")

            with mock.patch.object(MODULE, "verify_corpus", side_effect=incomplete) as verify:
                with self.assertRaisesRegex(RuntimeError, "native-timeout"):
                    MODULE.verify_additional_corpus(SimpleNamespace(), output, base, output, results)
            self.assertEqual(verify.call_count, 1)
            base.run.assert_not_called()
            self.assertEqual(MODULE.load(output / "results.json")["status"], "incomplete")
            receipts = output / "logs/extension-variants-evidence"
            self.assertEqual(MODULE.load(receipts / "results.json")["error"], "native-timeout")
            self.assertTrue(MODULE.load(receipts / "logs/native.json")["owned_root_reaped"])

    @unittest.skipUnless(hasattr(os, "killpg") and hasattr(os, "wait4"),
                         "native process-group regression requires POSIX wait4/killpg")
    def test_direct_supervisor_reaps_native_child_where_nested_wrapper_loses_it(self):
        # 이전 구조만 짧게 재현한다. 새 session의 synthetic child는 3초 후 스스로 종료한다.
        # 숫자 PID를 임의 kill하지 않고, 실제 공통 supervisor가 소유한 직접 자식만 정리한다.
        helper = Path(__file__).with_name("benchmark-indexstore-cli.py").resolve()
        spec = importlib.util.spec_from_file_location("extension_timeout_supervisor", helper)
        supervisor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(supervisor)
        supervisor.STREAM_TERM_SECONDS = 0.02
        supervisor.STREAM_KILL_SECONDS = 0.5
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "finite-child.py"
            child.write_text("from pathlib import Path\nimport json, os, sys, time\n"
                "Path(sys.argv[1]).write_text(json.dumps({'pid': os.getpid(), 'group': os.getpgrp()}))\n"
                "time.sleep(3)\nPath(sys.argv[2]).write_text('completed')\n", encoding="utf-8")
            wrapper = root / "legacy-wrapper.py"
            wrapper.write_text("import importlib.util, sys\nfrom pathlib import Path\n"
                "spec = importlib.util.spec_from_file_location('legacy_nested', sys.argv[1])\n"
                "base = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(base)\n"
                "root = Path(sys.argv[2])\n"
                "base.run([sys.executable, str(root/'finite-child.py'), str(root/'legacy-started.json'), "
                "str(root/'legacy-finished')], root, root/'legacy-native', 6, stream_limit=4096)\n",
                encoding="utf-8")
            with self.assertRaises(RuntimeError):
                supervisor.run([sys.executable, str(wrapper), str(helper), str(root)], root,
                               root / "legacy-wrapper", timeout=1, stream_limit=4096)
            until = time.monotonic() + 5
            while not (root / "legacy-finished").exists() and time.monotonic() < until:
                time.sleep(0.01)
            legacy = MODULE.load(root / "legacy-wrapper.json")
            started = MODULE.load(root / "legacy-started.json")
            self.assertTrue(legacy["timed_out"] and legacy["owned_root_reaped"])
            self.assertNotEqual(started["group"], legacy["pid"])
            self.assertTrue((root / "legacy-finished").exists())
            self.assertFalse((root / "legacy-native.json").exists())

            runner = MODULE.corpus_runner(supervisor, root / "direct", {"measurements": []},
                                          deadline=time.monotonic() + 1)
            with self.assertRaises(RuntimeError):
                runner([sys.executable, child, root / "direct-started.json", root / "direct-finished"],
                       root, "native")
            direct = MODULE.load(root / "direct/logs/native.json")
            self.assertTrue((root / "direct-started.json").is_file())
            self.assertTrue(direct["timed_out"] and direct["owned_root_reaped"])
            self.assertFalse(direct["ownership_lost"])
            self.assertEqual(direct["cleanup_errors"], [])
            time.sleep(2.1)
            self.assertFalse((root / "direct-finished").exists())
            print("native-extension-timeout-control: " + json.dumps({
                "legacyWrapperReaped": legacy["owned_root_reaped"], "legacyNativeSurvived": True,
                "legacyNativeReceiptMissing": True, "directNativeReaped": direct["owned_root_reaped"],
                "directNativeSurvived": False, "directTimeoutReceiptPreserved": direct["timed_out"],
            }, sort_keys=True))

    def test_variants_reject_missing_evidence_and_hidden_real_violation(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            for changed in ["module-evidence", "rules"]:
                result = self.variant_documents(project)
                if changed == "rules":
                    result["rules"]["diagnostics"] = []
                else:
                    result[changed]["evidence"] = []
                    result[changed]["evidenceCount"] = 0
                with self.assertRaises(ValueError):
                    MODULE.validate_variants_candidate(result, project)


if __name__ == "__main__":
    unittest.main()
