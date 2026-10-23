#!/usr/bin/env python3
"""Offline evidence-classification tests, not Swift compiler validation."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("associated_witness", Path(__file__).with_name("verify-associated-witness-feedback.py"))
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)
FIXTURE = Path(__file__).resolve().parents[1] / "Fixtures/FalsePositiveCorpus/AssociatedWitness/Sources/WitnessApp"
SOURCES = {path.name: path.read_text(encoding="utf-8") for path in FIXTURE.glob("*.swift")}


def diagnostic(name, line, rule="unused-symbol"):
    return {"ruleIdentifier": rule, "location": {"path": "/fixture/" + name, "line": line}}


class EvidenceTests(unittest.TestCase):
    def report(self, extra=()):
        entries = [diagnostic("DeadPublisher.swift", 3)]
        entries += [diagnostic("Unrelated.swift", line) for line in subject.alias_lines(SOURCES["Unrelated.swift"])]
        return {"diagnostics": entries + list(extra), "suppressedCount": 0, "limitations": ["unresolved-dynamic: retained"]}

    def test_same_named_unrelated_aliases_remain_candidates(self):
        result = subject.classify(self.report(), SOURCES)
        self.assertTrue(result["unrelatedAliasesStillReported"])
        self.assertTrue(result["deadOwnerStillReported"])
        self.assertEqual(result["requiredAliasFalsePositives"], [])
        self.assertEqual(result["limitations"], ["unresolved-dynamic: retained"])

    def test_missing_live_witness_identifies_exact_file_and_line(self):
        result = subject.classify(self.report([diagnostic("NestedPublisher.swift", 5)]), SOURCES)
        self.assertEqual(result["requiredAliasFalsePositives"], [["NestedPublisher.swift", 5]])

    def test_different_rule_does_not_claim_dead_alias(self):
        result = subject.classify(self.report([diagnostic("NestedPublisher.swift", 5, "redundant-public")]), SOURCES)
        self.assertEqual(result["requiredAliasFalsePositives"], [])

    def test_suppressed_or_empty_reports_do_not_pass(self):
        report = self.report()
        report["suppressedCount"] = 1
        with self.assertRaises(ValueError):
            subject.classify(report, SOURCES)
        report = self.report()
        report["limitations"].append("empty-index: no index")
        with self.assertRaises(ValueError):
            subject.classify(report, SOURCES)

    def test_only_completed_compiler_failure_counts_as_mutation(self):
        receipt = {"returncode": 1, "owned_root_reaped": True}
        self.assertEqual(subject.completed_exit(receipt, None), 1)
        for field, value in [("timed_out", True), ("output_limit_exceeded", "stderr"),
                             ("cleanup_errors", ["root-reap-unresolved"]), ("ownership_lost", True),
                             ("exception_type", "OSError"), ("owned_root_reaped", False),
                             ("returncode", None), ("returncode", -9)]:
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    subject.completed_exit({**receipt, field: value}, None)

    def test_incomplete_public_or_candidate_cannot_satisfy_enforcing_gate(self):
        candidate = subject.classify(self.report(), SOURCES)
        candidate["limitations"] = []
        public = {**candidate, "requiredAliasFalsePositives": [[name, line] for name in subject.LIVE
                   for line in subject.alias_lines(SOURCES[name])]}
        self.assertTrue(subject.behavior_satisfied(public, candidate))
        for note in ["index-staleness: source newer", "unindexed-sources: 1", "unknown future limitation"]:
            for side in ["public", "candidate"]:
                with self.subTest(note=note, side=side):
                    before, after = dict(public), dict(candidate)
                    (before if side == "public" else after)["limitations"] = [note]
                    self.assertFalse(subject.behavior_satisfied(before, after))
        for field, value in [("unrelatedAliasesStillReported", False), ("deadOwnerStillReported", False),
                             ("requiredAliasFalsePositives", [["TopLevelPublisher.swift", 4]])]:
            self.assertFalse(subject.behavior_satisfied(public, {**candidate, field: value}))

    def test_malformed_limitations_cannot_be_missing_evidence(self):
        for limits in [None, "index-staleness", [None]]:
            with self.subTest(limits=limits), self.assertRaises(ValueError):
                subject.classify({**self.report(), "limitations": limits}, SOURCES)
if __name__ == "__main__":
    unittest.main()
