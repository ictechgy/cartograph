#!/usr/bin/env python3
"""Check actual component artifacts before a Catalog release can run."""

import json
from pathlib import Path


def main():
    root = Path.cwd()
    raw = json.loads((root / "cartograph-report.json").read_text())
    findings = json.loads((root / "gl-code-quality-report.json").read_text())
    status = json.loads((root / "cartograph-status.json").read_text())
    assert raw["tool"] == "cartograph" and raw["version"] == "0.20.0"
    assert status["cli_exit_code"] == 1, "The fixture must produce real strict findings"
    assert findings and len(findings) == len(raw["diagnostics"])
    unused = {item["description"] for item in findings if item["check_name"] == "unused-symbol"}
    assert any("unusedHelper" in item for item in unused), unused
    assert any("UnusedService" in item for item in unused), unused
    assert not any("Probe.main" in item for item in unused), "The entry point must remain retained"
    expected = sorted((item["ruleIdentifier"], item["message"], item["location"]["line"])
                      for item in raw["diagnostics"])
    actual = sorted((item["check_name"], item["description"], item["location"]["lines"]["begin"])
                    for item in findings)
    assert actual == expected, "Conversion changed a finding"
    for finding in findings:
        path = finding["location"]["path"]
        assert path.startswith("fixtures/Smoke/") and (root / path).is_file(), path
        assert len(finding["fingerprint"]) == 64
        assert finding["severity"] in {"info", "minor", "major"}
    print(f"PASS: {len(findings)} real findings, retained entry point, and repository-relative source paths")


if __name__ == "__main__":
    main()
