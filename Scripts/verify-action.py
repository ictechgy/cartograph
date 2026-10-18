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


def execute(source, environment, cwd=None):
    # Actions는 단계를 분석 대상 체크아웃에서 실행한다. cwd를 생략하면 이 스크립트의 작업 디렉터리를 물려받는다.
    return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", source],
                          env={**os.environ, **environment}, cwd=cwd, capture_output=True, text=True)


def artifact_uris(sarif):
    locations = json.loads(sarif.read_text())["runs"][0]["results"][0]["locations"]
    return [item["physicalLocation"]["artifactLocation"]["uri"] for item in locations]


def converted_uris(root):
    # 상대 경로만 프로젝트 기준 file URI가 되고, 스킴이나 uriBaseId가 있는 위치는 그대로 남는다.
    return [(root / "Sources/Space #Thing.swift").as_uri(), "file:///already/absolute.swift", "Other.swift"]


def check_planted_module(gate, environment, root):
    # 체크아웃 루트의 json.py가 SARIF 경로 변환의 표준 모듈을 가리면 그 코드가 샌드박스 밖에서 실행된다.
    marker = root / "planted-json-imported"
    (root / "json.py").write_text(f"open({str(marker)!r}, 'w').close()\nraise SystemExit(3)\n")
    result = execute(gate, {**environment, "STUB_CODE": "0", "WRITE_REPORT": "true"}, cwd=root)
    assert not marker.exists(), "json.py in the analyzed checkout replaced the standard library module"
    assert result.returncode == 0, result.stderr
    assert artifact_uris(Path(environment["INPUT_SARIF"])) == converted_uris(root)


def check_literal_globs(gate, environment, root):
    # args는 단어로만 나뉜다. globstar가 꺼진 bash는 `Tests/**`를 `*`처럼 펼쳐 `Tests/UI Tests/Unit`으로 바꾸고,
    # 그러면 그 아래 파일을 못 거른다. CLI의 `*`도 `/`를 넘지 않아 `Tests/*`는 펼치든 말든 하위 디렉터리의 파일을 거르지 않는다.
    for directory in ("Tests/UI", "Tests/Unit"):
        (root / directory).mkdir(parents=True)
    argv = root / "argv"
    result = execute(gate, {**environment, "INPUT_ARGS": "--exclude Tests/**", "INPUT_FAIL_ON_FINDINGS": "false",
                            "STUB_ARGV": str(argv)}, cwd=root)
    assert result.returncode == 0, result.stderr
    received = argv.read_text().split("\0")[:-1]
    assert received == ["check", "--project", environment["INPUT_PROJECT"], "--report-format", "sarif",
                        "--output", environment["INPUT_SARIF"], "--quiet", "--exclude", "Tests/**"], received


def main():
    gate, report = script("Run the gate"), script("Report the result")
    with tempfile.TemporaryDirectory(prefix="cartograph-action-test-") as directory:
        root = Path(directory).resolve()
        binary = root / "cartograph"
        # STUB_ARGV가 있으면 스텁이 받은 인자를 NUL로 구분해 남긴다.
        binary.write_text('#!/bin/bash\n'
                          '[ -z "$STUB_ARGV" ] || printf \'%s\\0\' "$@" > "$STUB_ARGV"\n'
                          'if [ "$WRITE_REPORT" = true ]; then printf \'%s\\n\' "$STUB_REPORT" > "$INPUT_SARIF"; fi\n'
                          'exit "$STUB_CODE"\n')
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
                uris = artifact_uris(sarif)
                assert uris == converted_uris(root), uris
            if not writes:
                assert not sarif.exists(), "stale SARIF survived a failed invocation"
            result = execute(report, {"EXIT_CODE": values["exit-code"],
                                     "FAIL_ON_FINDINGS": str(strict).lower(),
                                     "SARIF": values.get("sarif-file", "")})
            assert result.returncode == expected, (code, writes, strict, result)
            count += 1
        result = execute(gate, {**env, "INPUT_COMMAND": "unsupported"})
        assert result.returncode == 2
        check_planted_module(gate, env, root)
        check_literal_globs(gate, env, root)
    print(f"PASS: {count} action outcomes plus unsupported-command, planted-module and literal-glob checks")


if __name__ == "__main__":
    main()
