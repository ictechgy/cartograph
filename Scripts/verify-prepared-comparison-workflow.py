#!/usr/bin/env python3
"""Keep preparation failures and every original comparison gate in the split CI graph."""
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import textwrap
import unittest
from unittest.mock import patch

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"
CONTRACT_COMMANDS = [
    "python3 Scripts/verify-indexstore-benchmark.py",
    "python3 Scripts/verify-indexstore-project.py",
    "python3 Scripts/verify-prepared-indexstore-sessions.py",
    "python3 Scripts/verify-query-phases.py",
    "python3 Scripts/verify-indexstore-evidence.py",
    "python3 Scripts/verify-indexstore-bundles.py",
    "python3 Scripts/verify-indexstore-mixed.py",
    "python3 Scripts/verify-indexstore-pilot-evidence.py",
    "python3 Scripts/verify-module-refresh-diagnostic.py",
    "python3 Scripts/verify-native-measurement-contract.py",
    "python3 Scripts/verify-native-calibration-contract.py",
    "python3 Scripts/verify-native-generation-contract.py",
    "python3 -m unittest discover -s Scripts/benchmark-inputs -v",
    "python3 Scripts/verify-sdk-discovery-contract.py",
]
ROLES = ("candidate", "comparator", "baseline")


def jobs(text):
    headers = list(re.finditer(r"^  ([a-z][a-z0-9-]*):\n", text, re.M))
    return {row[1]: text[row.start():headers[index + 1].start() if index + 1 < len(headers) else len(text)]
            for index, row in enumerate(headers)}


class PreparedComparisonWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.jobs = jobs(self.text)

    def test_original_contracts_run_once_in_required_prerequisite(self):
        contract = self.jobs["comparison-contracts"]
        commands = [line.strip() for line in contract.splitlines() if line.strip().startswith("python3 ")]
        self.assertEqual(commands[:len(CONTRACT_COMMANDS)], CONTRACT_COMMANDS)
        self.assertIn("python3 Scripts/verify-prepared-comparison-workflow.py", commands)
        for command in CONTRACT_COMMANDS:
            self.assertEqual(self.text.count(command), 1, command)
        self.assertIn("runs-on: macos-latest", contract)
        self.assertIn("timeout-minutes: 35", contract)

    def test_preparation_has_exact_roles_bounded_cold_build_budgets_and_scoped_upload(self):
        self.assertNotIn("prepare-comparison-tools", self.jobs)
        for role, command_budget, step_minutes in (("candidate", 1500, 35), ("comparator", 1500, 35), ("baseline", 1500, 35)):
            producer = self.jobs[f"prepare-comparison-{role}"]
            self.assertIn("    timeout-minutes: 35\n", producer)
            self.assertIn(f"        timeout-minutes: {step_minutes}\n", producer)
            self.assertIn(f'--jobs 3 --setup-timeout {command_budget}', producer)
            self.assertIn(f'--role {role} --checkout "$GITHUB_WORKSPACE"', producer)
            self.assertIn("ref: ${{ github.sha }}", producer)
            self.assertIn("persist-credentials: false", producer)
            self.assertIn("CARTOGRAPH_CI_PR_HEAD: ${{ github.event.pull_request.head.sha || github.sha }}", producer)
            self.assertIn("CARTOGRAPH_CI_PR_BASE: ${{ github.event.pull_request.base.sha || '' }}", producer)
            self.assertIn("manifest_sha256: ${{ steps.prepare.outputs.manifest_sha256 }}", producer)
            self.assertIn("artifact_id: ${{ steps.upload.outputs.artifact-id }}", producer)
            self.assertEqual(producer.count("        id: prepare\n"), 1)
            self.assertEqual(producer.count("        id: upload\n"), 1)
            self.assertEqual(producer.count("uses: actions/upload-artifact@v7"), 1)
            self.assertIn(f"name: prepared-{role}-" + "${{ github.run_attempt }}", producer)
            self.assertIn("path: ${{ runner.temp }}/prepared-" + role + "/", producer)
            self.assertIn("if-no-files-found: error", producer)
            self.assertNotIn("include-hidden-files: true", producer)
            self.assertNotIn("-evidence", producer.split("uses: actions/upload-artifact@v7")[1])
            self.assertNotIn("continue-on-error", producer)
            self.assertNotIn("matrix", producer)

    def test_actual_required_gate_rejects_failed_cancelled_skipped_missing_and_extra_needs(self):
        consumer = self.jobs["indexstore-comparison"]
        self.assertIn("name: Compare the pinned IndexStoreDB CLI", consumer)
        self.assertIn("needs: [comparison-contracts, prepare-comparison-candidate, prepare-comparison-comparator, prepare-comparison-baseline]", consumer)
        self.assertIn("    if: always()\n", consumer)
        self.assertIn("timeout-minutes: 35", consumer)
        self.assertIn("PREPARATION_RESULTS: ${{ toJSON(needs) }}", consumer)
        guard = consumer.split("      - name: Require every preparation gate\n", 1)[1].split("      - uses:", 1)[0]
        code = textwrap.dedent(guard.split("          python3 - <<'PY'\n", 1)[1].rsplit("          PY", 1)[0])
        compiled = compile(code, "<actual-ci-preparation-guard>", "exec")
        expected = {role: {"manifest_sha256": str(index + 1) * 64, "artifact_id": str(index + 1)}
                    for index, role in enumerate(ROLES)}
        good = {"comparison-contracts": {"result": "success"}, **{
            f"prepare-comparison-{role}": {"result": "success", "outputs": value} for role, value in expected.items()}}
        with tempfile.TemporaryDirectory() as temp:
            with patch.dict(os.environ, {"PREPARATION_RESULTS": json.dumps(good), "RUNNER_TEMP": temp}):
                exec(compiled, {})
            self.assertEqual(json.loads((Path(temp) / "prepared-expected.json").read_text()), expected)
        bad = [{}, {**good, "unexpected": {"result": "success"}}]
        for key in good:
            bad.extend({**good, key: {"result": result}} for result in ("failure", "cancelled", "skipped", None))
            bad.append({other: value for other, value in good.items() if other != key})
        for role in ROLES:
            key = f"prepare-comparison-{role}"
            bad.append({**good, key: {"result": "success"}})
            for field, wrong_values in (("manifest_sha256", ("", "a" * 63, "g" * 64, None, 10)),
                                        ("artifact_id", ("", "0", "-1", "1,2", "not-an-id", None, 10))):
                for value in wrong_values:
                    bad.append({**good, key: {"result": "success", "outputs": {**expected[role], field: value}}})
        for value in bad:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temp:
                with patch.dict(os.environ, {"PREPARATION_RESULTS": json.dumps(value), "RUNNER_TEMP": temp}):
                    with self.assertRaises(SystemExit):
                        exec(compiled, {})
                self.assertFalse((Path(temp) / "prepared-expected.json").exists())

    def test_consumer_downloads_only_this_runs_three_artifacts_before_admission(self):
        consumer = self.jobs["indexstore-comparison"]
        chunks = consumer.split("      - uses: actions/download-artifact@v8\n")
        self.assertEqual(len(chunks), 4)
        for role, chunk in zip(("candidate", "comparator", "baseline"), chunks[1:]):
            inputs = chunk.split("      - ", 1)[0]
            self.assertIn("artifact-ids: ${{ needs.prepare-comparison-" + role + ".outputs.artifact_id }}", inputs)
            self.assertIn("path: ${{ runner.temp }}/prepared-tools/" + role, inputs)
            self.assertIn("digest-mismatch: error", inputs)
            for override in ("github-token:", "repository:", "run-id:", "pattern:", "merge-multiple:", "name:"):
                self.assertNotIn(override, inputs)
        self.assertLess(consumer.index("Require every preparation gate"), consumer.index("actions/download-artifact"))
        self.assertLess(consumer.rindex("actions/download-artifact"), consumer.index("prepared-comparison-tools.py admit"))
        self.assertLess(consumer.index("prepared-comparison-tools.py admit"), consumer.index("benchmark-indexstore-cli.py"))
        self.assertIn('--prepared-tools "$RUNNER_TEMP/prepared-admission/admission.json"', consumer)
        self.assertIn('--expected "$RUNNER_TEMP/prepared-expected.json"', consumer)
        self.assertIn("--repetitions 5 --jobs 3 --setup-timeout 1500", consumer)
        self.assertIn("--repetitions 4 --jobs 3", consumer)
        self.assertNotIn("--cartograph-package", consumer)
        baseline = consumer.split("      - name: Admit the exact pre-query release baseline\n", 1)[1].split(
            "      - name: Compare paired query phases", 1)[0]
        self.assertIn("prepared-comparison-tools.py baseline", baseline)
        self.assertIn('--admission "$RUNNER_TEMP/prepared-admission/admission.json"', baseline)
        self.assertIn('--output "$RUNNER_TEMP/indexstore-project-validation/setup/query-baseline.json"', baseline)

    def test_existing_native_query_and_other_jobs_are_byte_identical(self):
        # f71ff0d에서 검증한 원래 비교 게이트와 다른 세 작업은 이동하거나 완화하지 않는다.
        consumer_tail = self.text[self.text.index("      - name: Compare paired query phases"):
                                  self.text.index("\n  test:")]
        other_jobs = self.text[self.text.index("\n  test:"):]
        self.assertEqual(hashlib.sha256(consumer_tail.encode()).hexdigest(),
                         "33dfced6bfb34e25f03474c0b707a6a14b701c356416e8d170b957e5b3ed9197")
        self.assertEqual(hashlib.sha256(other_jobs.encode()).hexdigest(),
                         "6951a3b05e2e4902f0ee1fa954af098cfcfb5ecc71870236b8207d3d8201af30")


if __name__ == "__main__":
    unittest.main()
