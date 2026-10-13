"""SDK 실패 진단을 루트 승인 없이 같은 세대와 전체 비용에 연결한다."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import state_inputs


class SDKReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "results.json"
        self.plan = {"inputs": {"lifecycle": {"sha256": "a" * 64}}, "prior_costs": {}}
        self.row = dict(
            accepted=False,
            final_protocol_ready=False,
            phase=dict(
                completed=True, returncode=1, observed_returncode=1, failure=None, cleanup_root_unfinished=False
            ),
            generation_guard_before={"status": "passed"},
            generation_guard_after={"status": "passed"},
            total_wall_seconds=3.25,
            charged_wall_seconds_by_arm=dict(cartograph=3.25, index_dump_assembly=3.25),
            input_files={"results.json": {"sha256": "a" * 64}},
        )

    def bind(self):
        self.path.write_text(json.dumps(self.row))
        state_inputs.bind_sdk_discovery(self.plan, self.path)

    def test_completed_red_discovery_is_retained_without_acceptance(self):
        self.bind()
        self.assertEqual(
            self.plan["inputs"]["sdk_discovery"]["sha256"], hashlib.sha256(self.path.read_bytes()).hexdigest()
        )
        self.assertEqual(self.plan["prior_costs"]["sdk_discovery"]["full_wall_seconds"], 3.25)
        self.assertFalse(self.row["accepted"])

    def test_incomplete_signal_timeout_or_unproved_cleanup_is_refused(self):
        original = copy.deepcopy(self.row["phase"])
        for changes in [
            dict(returncode=125, observed_returncode=125),
            dict(returncode=125, observed_returncode=-15),
            dict(completed=False, failure="timeout"),
            dict(cleanup_root_unfinished=True),
            dict(failure="launch"),
            dict(returncode=0, observed_returncode=1),
            dict(returncode=False, observed_returncode=0),
        ]:
            with self.subTest(changes=changes):
                self.row["phase"] = dict(original, **changes)
                with self.assertRaises(ValueError):
                    self.bind()
                self.assertNotIn("sdk_discovery", self.plan["inputs"])

    def test_generation_cost_and_lifecycle_mismatch_are_refused(self):
        original = copy.deepcopy(self.row)
        for key, value in [
            ("accepted", True),
            ("final_protocol_ready", True),
            ("total_wall_seconds", True),
            ("generation_guard_after", {"status": "failed"}),
            ("input_files", {"results.json": {"sha256": "b" * 64}}),
            ("charged_wall_seconds_by_arm", dict(cartograph=3.25, index_dump_assembly=0)),
        ]:
            with self.subTest(key=key):
                self.row = dict(original, **{key: value})
                with self.assertRaises(ValueError):
                    self.bind()
                self.assertNotIn("sdk_discovery", self.plan["inputs"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
