#!/usr/bin/env python3
"""Execute the committed composite action's gate/result scripts with controlled CLI outcomes."""

import os
import json
from pathlib import Path
import subprocess
import tempfile
import textwrap


ROOT = Path(__file__).resolve().parents[1]


def script(name):
    # 실제 YAML의 지정 단계만 추출한다. 셸을 사본으로 검증하면 액션의 회귀를 놓친다.
    step = (ROOT / "action.yml").read_text().split(f"    - name: {name}\n", 1)[1]
    step = step.split("\n    - name:", 1)[0]
    return textwrap.dedent(step.split("      run: |\n", 1)[1])


def execute(source, environment):
    return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", source],
                          env={**os.environ, **environment}, capture_output=True, text=True)


def main():
    gate, report = script("Run the gate"), script("Report the result")
    with tempfile.TemporaryDirectory(prefix="cartograph-action-test-") as directory:
        root = Path(directory).resolve()
        binary = root / "cartograph"
        binary.write_text('#!/bin/bash\nif [ "$WRITE_REPORT" = true ]; then printf \'%s\\n\' "$STUB_REPORT" > "$INPUT_SARIF"; fi\nexit "$STUB_CODE"\n')
        binary.chmod(0o700)
        count = 0
        for code, writes, strict, expected in [
            (0, True, True, 0), (1, True, True, 1), (1, True, False, 0),
            (2, False, False, 2), (64, False, False, 2), (127, False, True, 2),
            (64, True, False, 2), (0, False, False, 2),
        ]:
            output, sarif = root / "outputs", root / "report.sarif"
            output.write_text("")
            sarif.write_text("STALE REPORT")
            env = {"CARTOGRAPH_BINARY": str(binary), "INPUT_COMMAND": "check", "INPUT_ARGS": "",
                   "INPUT_PROJECT": str(root), "INPUT_SARIF": str(sarif),
                   "INPUT_FAIL_ON_FINDINGS": str(strict).lower(), "GITHUB_OUTPUT": str(output),
                   "STUB_CODE": str(code), "WRITE_REPORT": str(writes).lower(),
                   "STUB_REPORT": json.dumps({"version": "2.1.0", "runs": [{"results": [{"locations": [
                       {"physicalLocation": {"artifactLocation": {"uri": "Sources/Space%20%23Thing.swift"}}},
                       {"physicalLocation": {"artifactLocation": {"uri": "file:///already/absolute.swift"}}},
                       {"physicalLocation": {"artifactLocation": {"uri": "Other.swift", "uriBaseId": "BASE"}}},
                   ]}]}]})}
            result = execute(gate, env)
            assert result.returncode == 0, result.stderr
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            assert values["exit-code"] == str(code)
            assert bool(values.get("sarif-file")) == (writes and code in (0, 1)), values
            if values.get("sarif-file"):
                locations = json.loads(sarif.read_text())["runs"][0]["results"][0]["locations"]
                uris = [item["physicalLocation"]["artifactLocation"]["uri"] for item in locations]
                assert uris == [(root / "Sources/Space #Thing.swift").as_uri(),
                                "file:///already/absolute.swift", "Other.swift"], uris
            if not writes:
                assert not sarif.exists(), "stale SARIF survived a failed invocation"
            result = execute(report, {"EXIT_CODE": values["exit-code"],
                                     "FAIL_ON_FINDINGS": str(strict).lower(),
                                     "SARIF": values.get("sarif-file", "")})
            assert result.returncode == expected, (code, writes, strict, result)
            count += 1
        result = execute(gate, {**env, "INPUT_COMMAND": "unsupported"})
        assert result.returncode == 2
    print(f"PASS: {count} action outcomes plus unsupported-command rejection")


if __name__ == "__main__":
    main()
