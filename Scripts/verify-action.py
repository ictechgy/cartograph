#!/usr/bin/env python3
"""Execute the committed composite action's steps with a stub CLI and a fake gh, without network access."""

import hashlib
import io
import os
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap


ROOT = Path(__file__).resolve().parents[1]
# 개발자 셸이나 CI 단계의 토큰이 섞이면 토큰이 어느 단계에 닿는지 확인할 수 없다.
INHERITED = {key: value for key, value in os.environ.items() if key not in {"GH_TOKEN", "GITHUB_TOKEN"}}
RELEASE = "0.28.0"
ARCHIVE = f"cartograph-{RELEASE}-macos-universal.tar.gz"
# 실행되면 받은 인자를 남기고, 토큰을 받았으면 따로 표시한다. 내려받기 단계에서는 실행되면 안 된다.
STUB_CLI = b'#!/bin/bash\nprintf \'%s\\0\' "$@" > "$STUB_RAN"\n[ -z "$GH_TOKEN" ] || : > "$STUB_RAN.token"\n'
# 실제 릴리스처럼 문서를 함께 넣고, 바깥을 가리키는 링크와 상위 경로 멤버도 넣어 실행 파일 하나만 풀리는지 본다.
RELEASE_MEMBERS = [("cartograph/cartograph", None, STUB_CLI), ("cartograph/README.md", None, b"readme\n"),
                   ("cartograph/docs/QUERY-EVIDENCE.md", None, b"evidence\n"), ("cartograph/root", "/", b""),
                   ("../outside.txt", None, b"outside\n")]
LINK_MEMBERS = [("cartograph/cartograph", "/bin/sh", b"")]
# 액션이 부르는 gh 호출 세 가지만 흉내 낸다. --jq 필터는 진짜 jq로 평가해 액션의 필터 문자열까지 검증한다.
FAKE_GH = textwrap.dedent('''\
    import json, os, shutil, subprocess, sys
    arguments = sys.argv[1:]
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps({"argv": arguments, "token": bool(os.environ.get("GH_TOKEN"))}) + "\\n")
    if not os.environ.get("GH_TOKEN"):
        sys.exit("gh: set the GH_TOKEN environment variable")
    with open(os.environ["FAKE_GH_RELEASE"]) as source:
        release = json.load(source)
    prefix = "repos/ictechgy/cartograph/releases/"
    documents = {prefix + "latest": {"tag_name": release["latest"]},
                 prefix + "tags/" + release["tag"]: release["document"]}
    if arguments[:1] == ["api"] and arguments[2:3] == ["--jq"] and len(arguments) == 4:
        if arguments[1] not in documents:
            sys.exit("gh: Not Found (HTTP 404)")
        result = subprocess.run(["jq", "-r", arguments[3]], input=json.dumps(documents[arguments[1]]),
                                capture_output=True, text=True)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
    if arguments[:3] == ["release", "download", release["tag"]] and "--clobber" in arguments:
        option = lambda name: arguments[arguments.index(name) + 1]
        if option("--repo") != "ictechgy/cartograph" or option("--pattern") not in release["files"]:
            sys.exit("gh: no assets match the file pattern")
        shutil.copyfile(release["files"][option("--pattern")], os.path.join(option("--dir"), option("--pattern")))
        sys.exit(0)
    sys.exit(f"gh: unexpected call {arguments}")
''')
ACTUAL, BINARY = "<archive sha256>", "<own binary>"
# 입력·릴리스 기록·압축 파일 구성마다 종료 코드, gh 호출 순서, 오류 원인을 고정한다.
# 형식이 틀린 입력은 gh를 부르기 전에 64로 끝난다.
DOWNLOAD_CASES = [
    {"name": "latest", "inputs": {}, "exit": 0, "calls": ["latest", "tag", "download"]},
    {"name": "empty version", "inputs": {"version": ""}, "exit": 0, "calls": ["latest", "tag", "download"]},
    {"name": "pinned", "inputs": {"version": RELEASE, "sha256": ACTUAL}, "exit": 0, "calls": ["tag", "download"]},
    {"name": "digest differs", "inputs": {"version": RELEASE}, "recorded": "other", "exit": 2,
     "calls": ["tag", "download"], "error": "does not match the SHA-256 that GitHub recorded"},
    {"name": "no digest", "inputs": {"version": RELEASE}, "recorded": "none", "exit": 2, "calls": ["tag"],
     "error": "has no SHA-256 digest"},
    {"name": "no asset", "inputs": {"version": RELEASE}, "recorded": "absent", "exit": 2, "calls": ["tag"],
     "error": "has no SHA-256 digest"},
    {"name": "malformed digest", "inputs": {"version": RELEASE}, "recorded": "malformed", "exit": 2, "calls": ["tag"],
     "error": "has no SHA-256 digest"},
    {"name": "unknown release", "inputs": {"version": "0.27.0"}, "exit": 2, "calls": ["tag"],
     "error": "Could not read release 0.27.0"},
    {"name": "sha256 differs", "inputs": {"version": RELEASE, "sha256": "0" * 64}, "exit": 2,
     "calls": ["tag", "download"], "error": "does not match the sha256 input"},
    {"name": "linked executable", "inputs": {"version": RELEASE}, "members": LINK_MEMBERS, "exit": 2,
     "calls": ["tag", "download"], "error": "regular file cartograph/cartograph"},
    {"name": "latest is not a CLI release", "inputs": {}, "latest": "action-v1.0.0", "exit": 2, "calls": ["latest"],
     "error": "(action-v1.0.0) is not a CLI release"},
    *[{"name": f"version {value!r}", "inputs": {"version": value}, "exit": 64, "calls": [],
       "error": "version must be latest"} for value in ("v0.28.0", "0.28", '0.28.0" or "', "../0.28.0", "0.28.0\n")],
    *[{"name": f"sha256 {value!r}", "inputs": {"sha256": value}, "exit": 64, "calls": [], "error": "sha256 must be"}
      for value in ("A" * 64, "a" * 63, "sha256:" + "a" * 64)],
    {"name": "binary input", "inputs": {"binary": BINARY}, "exit": 0, "calls": []},
    {"name": "binary with sha256", "inputs": {"binary": BINARY, "sha256": "a" * 64}, "exit": 64, "calls": [],
     "error": "but binary skips the download"},
]


def step(name):
    # 실제 YAML의 지정 단계 블록(env·if·run)을 그대로 자른다.
    block = (ROOT / "action.yml").read_text().split(f"    - name: {name}\n", 1)[1]
    return block.split("\n    - name:", 1)[0]


def script(name):
    # 실제 YAML의 지정 단계만 추출한다. 셸을 사본으로 검증하면 액션의 회귀를 놓친다.
    return textwrap.dedent(step(name).split("      run: |\n", 1)[1])


def step_environment(name, context):
    # GitHub처럼 단계가 env에 선언한 값만 넘긴다. 토큰이 어느 단계에 닿는지가 YAML 그대로 드러난다.
    environment = {}
    for line in step(name).split("      env:\n", 1)[1].splitlines():
        if not line.startswith("        "):
            break
        if not line.strip().startswith("#"):
            key, value = line.strip().split(": ", 1)
            environment[key] = context[value.removeprefix("${{ ").removesuffix(" }}")]
    return environment


def execute(source, environment, cwd=None):
    # Actions는 단계를 분석 대상 체크아웃에서 실행한다. cwd를 생략하면 이 스크립트의 작업 디렉터리를 물려받는다.
    return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", source],
                          env={**INHERITED, **environment}, cwd=cwd, capture_output=True, text=True)


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


def write_archive(path, members):
    # (이름, 링크 대상, 내용) 목록으로 릴리스 압축 파일을 만들고 SHA-256을 돌려준다.
    with tarfile.open(path, "w:gz") as archive:
        for name, target, content in members:
            info = tarfile.TarInfo(name)
            if target:
                info.type, info.linkname = tarfile.SYMTYPE, target
            else:
                info.size, info.mode = len(content), 0o755
            archive.addfile(info, None if target else io.BytesIO(content))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_release(case, scenario):
    # GitHub가 자산마다 기록하는 digest를 흉내 낸다. recorded가 없으면 압축 파일의 실제 SHA-256을 기록한다.
    archive = case / ARCHIVE
    actual = write_archive(archive, scenario.get("members", RELEASE_MEMBERS))
    recorded = scenario.get("recorded", "match")
    digest = {"match": "sha256:" + actual, "other": "sha256:" + hashlib.sha256(b"other").hexdigest(),
              "malformed": "sha256:" + actual.upper()}.get(recorded)
    assets = [] if recorded == "absent" else [{"name": ARCHIVE, **({"digest": digest} if digest else {})}]
    document = {"tag_name": RELEASE, "assets": [*assets, {"name": "notes.txt", "digest": "sha256:" + "0" * 64}]}
    files = {} if recorded == "absent" else {ARCHIVE: str(archive)}
    release = {"latest": scenario.get("latest", RELEASE), "tag": RELEASE, "document": document, "files": files}
    (case / "release.json").write_text(json.dumps(release))
    return actual


def call_kind(call):
    # gh 호출을 순서 비교용 이름으로 줄인다.
    argv = call["argv"]
    if argv[:2] == ["release", "download"]:
        return "download"
    return "latest" if argv[1].endswith("/releases/latest") else "tag"


def extracted(runner):
    # 링크는 따라가지 않고 RUNNER_TEMP 아래에 생긴 경로를 모두 센다.
    names = []
    for directory, subdirectories, files in os.walk(runner):
        names += [os.path.relpath(os.path.join(directory, name), runner) for name in subdirectories + files]
    return sorted(names)


def resolve(case, fakebin, scenario):
    # GitHub처럼 단계가 선언한 env만 넘기고, PATH 맨 앞의 가짜 gh가 네트워크 대신 릴리스를 내준다.
    actual, runner, own = write_release(case, scenario), case / "runner", case / "own-cartograph"
    runner.mkdir()
    own.write_bytes(STUB_CLI)
    own.chmod(0o700)
    inputs = {"binary": "", "version": "latest", "sha256": "", **scenario["inputs"]}
    inputs = {key: {ACTUAL: actual, BINARY: str(own)}.get(value, value) for key, value in inputs.items()}
    context = {**{f"inputs.{key}": value for key, value in inputs.items()}, "github.token": "token-for-gh"}
    environment = {**step_environment("Resolve the binary", context), "RUNNER_TEMP": str(runner),
                   "PATH": f"{fakebin}{os.pathsep}{INHERITED['PATH']}", "GITHUB_OUTPUT": str(case / "outputs"),
                   "FAKE_GH_LOG": str(case / "gh.log"), "FAKE_GH_RELEASE": str(case / "release.json"),
                   "STUB_RAN": str(case / "ran")}
    (case / "outputs").write_text("")
    result = execute(script("Resolve the binary"), environment)
    outputs = dict(line.split("=", 1) for line in (case / "outputs").read_text().splitlines())
    log = case / "gh.log"
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return result, outputs, calls, str(own)


def check_first_run(case, binary):
    # 내려받은 바이너리의 첫 실행은 토큰 없는 단계에서 일어난다.
    ran = case / "ran"
    context = {"steps.resolve.outputs.binary": binary, "github.token": "token-for-gh"}
    environment = {**step_environment("Check the downloaded binary", context), "STUB_RAN": str(ran)}
    result = execute(script("Check the downloaded binary"), environment)
    assert result.returncode == 0, result.stderr
    assert ran.read_bytes().split(b"\0")[:-1] == [b"--version"], ran.read_bytes()
    assert not Path(f"{ran}.token").exists(), "the downloaded binary received GH_TOKEN"


def check_download_success(case, scenario, result, outputs, own):
    # 검증을 통과하면 실행 파일 하나만 풀리고, 아직 실행되지 않으며, latest일 때만 고정을 권하는 notice가 남는다.
    runner = case / "runner"
    assert not (case / "ran").exists(), "the resolve step ran the binary"
    if scenario["inputs"].get("binary"):
        assert outputs.get("binary") == own and extracted(runner) == [], (outputs, extracted(runner))
        return
    directory = Path(outputs["binary"]).relative_to(runner).parts[0]
    expected = [directory, f"{directory}/{ARCHIVE}", f"{directory}/cartograph", f"{directory}/cartograph/cartograph"]
    assert outputs["binary"] == str(runner / directory / "cartograph/cartograph"), outputs
    assert extracted(runner) == sorted(expected), extracted(runner)
    assert ("::notice" in result.stdout) == ("latest" in scenario["calls"]), result.stdout
    assert "latest" not in scenario["calls"] or f"release {RELEASE}" in result.stdout, result.stdout
    check_first_run(case, outputs["binary"])


def check_download_failure(case, scenario, result, outputs):
    # 거부한 경우에는 그 원인을 알리고, 바이너리를 내놓지도 실행하지도 않으며 정규 파일로 풀어 두지도 않는다.
    assert "::error::" in result.stdout and scenario["error"] in result.stdout, (scenario["name"], result.stdout)
    assert "binary" not in outputs, outputs
    assert not (case / "ran").exists(), "a rejected binary was run"
    runner = case / "runner"
    unpacked = [name for name in extracted(runner) if name.endswith("cartograph/cartograph")]
    assert all((runner / name).is_symlink() for name in unpacked), unpacked


def check_downloads(root):
    # 다운로드 경로를 네트워크 없이 검증한다. 토큰은 gh를 부르는 단계에만 있어야 한다.
    if not shutil.which("jq"):
        raise SystemExit("verify-action.py needs jq to evaluate the action's gh --jq filters; install jq")
    holders = [name for name in step_names() if "github.token" in step(name)]
    assert holders == ["Resolve the binary"], holders
    fakebin = root / "fakebin"
    fakebin.mkdir()
    (fakebin / "fake_gh.py").write_text(FAKE_GH)
    gh, implementation = fakebin / "gh", shlex.quote(str(fakebin / "fake_gh.py"))
    gh.write_text(f'#!/bin/bash\nexec {shlex.quote(sys.executable)} -I {implementation} "$@"\n')
    gh.chmod(0o700)
    for index, scenario in enumerate(DOWNLOAD_CASES):
        case = root / f"download-{index}"
        case.mkdir()
        result, outputs, calls, own = resolve(case, fakebin, scenario)
        assert result.returncode == scenario["exit"], (scenario["name"], result)
        assert [call_kind(call) for call in calls] == scenario["calls"], (scenario["name"], calls)
        assert all(call["token"] for call in calls), calls
        if scenario["exit"] == 0:
            check_download_success(case, scenario, result, outputs, own)
        else:
            check_download_failure(case, scenario, result, outputs)
    return len(DOWNLOAD_CASES)


def step_names():
    # 액션의 단계 이름을 선언 순서대로 돌려준다.
    return [line.split("    - name: ", 1)[1] for line in (ROOT / "action.yml").read_text().splitlines()
            if line.startswith("    - name: ")]


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
        downloads = check_downloads(root)
    print(f"PASS: {count} action outcomes plus unsupported-command, planted-module and literal-glob checks, "
          f"and {downloads} download and token-scope cases")


if __name__ == "__main__":
    main()
