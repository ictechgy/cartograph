#!/usr/bin/env python3
"""benchmark-codeql.py가 사용자가 지정한 CodeQL 실행 파일만 실행하는지 CodeQL 없이 검증한다."""

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
# 파일 이름에 하이픈이 있어 import 문으로는 불러올 수 없다.
SPEC = importlib.util.spec_from_file_location("benchmark_codeql", ROOT / "Scripts/benchmark-codeql.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
# 이 스크립트를 부르는 곳은 두 문서뿐이다. 문서의 호출은 고치지 않은 채로 동작해야 한다.
DOCUMENTS = (ROOT / "Fixtures/ValueFlowBenchmark/README.md", ROOT / "docs/scans/2026-09-value-flow-comparison.md")
PLACEHOLDER = "/path/to/codeql/codeql"


def write_executable(path, mode=0o700):
    """CodeQL 자리에 둘 파일을 만든다. 테스트는 run_command를 가로채므로 실제로 실행되지 않는다."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(mode)
    return path


def documented_arguments(document):
    """문서의 benchmark-codeql.py 호출마다 스크립트 뒤의 인자를 꺼낸다. 역슬래시로 이은 줄은 합친다."""
    lines = document.read_text().replace("\\\n", " ").splitlines()
    return [shlex.split(line)[2:] for line in lines if line.startswith("python3 Scripts/benchmark-codeql.py")]


class CodeQLArgumentTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="cartograph-codeql-arguments-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.codeql = write_executable(self.root / "bundle/codeql/codeql")

    def parse(self, *arguments):
        """해석 결과나 argparse 종료 코드를 stderr와 함께 돌려준다."""
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            try:
                return M.parse_arguments(list(arguments)), stderr.getvalue()
            except SystemExit as error:
                return error.code, stderr.getvalue()

    def test_codeql_is_required(self):
        status, stderr = self.parse()
        self.assertEqual(status, 2)
        self.assertIn("--codeql", stderr)

    def test_executable_path_is_used_as_given(self):
        arguments, stderr = self.parse("--codeql", str(self.codeql))
        self.assertIsInstance(arguments, argparse.Namespace, stderr)
        self.assertEqual(arguments.codeql, self.codeql)

    def test_relative_and_home_paths_become_absolute(self):
        # CodeQL 명령마다 cwd가 다르다. 상대 경로를 그대로 두면 각 명령의 cwd 기준으로 해석된다.
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.root)
        self.assertEqual(self.parse("--codeql", "bundle/codeql/codeql")[0].codeql, self.codeql)
        with mock.patch.dict(os.environ, {"HOME": str(self.root)}):
            self.assertEqual(self.parse("--codeql", "~/bundle/codeql/codeql")[0].codeql, self.codeql)

    def test_unusable_paths_are_refused_with_cause_and_direction(self):
        cases = (("is not executable", write_executable(self.root / "plain/codeql", mode=0o600)),
                 ("is not a file", self.root / "bundle"),
                 ("does not exist", self.root / "missing/codeql"))
        for cause, path in cases:
            with self.subTest(cause=cause):
                status, stderr = self.parse("--codeql", str(path))
                self.assertEqual(status, 2)
                self.assertIn(cause, stderr)
                self.assertIn(PLACEHOLDER, stderr)

    def test_existing_run_and_timeout_limits_are_kept(self):
        for arguments in (("--runs", "2"), ("--timeout", "0")):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.parse("--codeql", str(self.codeql), *arguments)[0], 2)

    def test_documented_invocations_parse_unchanged(self):
        for document in DOCUMENTS:
            with self.subTest(document=document.name):
                invocations = documented_arguments(document)
                self.assertEqual(len(invocations), 1)
                self.assertIn(PLACEHOLDER, invocations[0])
                substituted = [str(self.codeql) if value == PLACEHOLDER else value for value in invocations[0]]
                arguments, stderr = self.parse(*substituted)
                self.assertIsInstance(arguments, argparse.Namespace, stderr)
                self.assertEqual(arguments.codeql, self.codeql)


class EntryPointTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="cartograph-codeql-main-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.corpus = self.root / "corpus"
        (self.corpus / "codeql").mkdir(parents=True)
        (self.corpus / "expected.json").write_text(json.dumps(
            {"runtime": [{"label": "a", "value": "b"}], "flow_oracle": [{"label": "a"}]}))
        self.codeql = write_executable(self.root / "bundle/codeql/codeql")

    def main(self, *arguments):
        """첫 명령(pack install)이 실패한 것으로 꾸며 main()을 돌리고 종료 코드와 실행 요청을 돌려준다."""
        commands = []

        def refuse(command, *_):
            commands.append(command)
            return {"command": command, "returncode": 1, "wall_ms": 0.0, "timed_out": False, "timeout_cleanup": {}}

        argv = ["benchmark-codeql.py", "--corpus", str(self.corpus), "--output-dir", str(self.root / "out"), *arguments]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(M, "run_command", side_effect=refuse), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                return M.main(), commands
            except SystemExit as error:
                return error.code, commands

    def test_given_executable_is_the_program_that_runs(self):
        status, commands = self.main("--codeql", str(self.codeql))
        self.assertEqual(status, 1)
        self.assertEqual(commands[0][:3], [str(self.codeql), "pack", "install"])

    def test_missing_codeql_runs_nothing(self):
        # 예전 기본값은 공유 /tmp의 고정 이름 포인터였다. 그 이름을 먼저 만든 계정이 실행 파일을 골랐다.
        self.assertEqual(self.main(), (2, []))

    def test_pointer_file_is_not_followed(self):
        # 포인터 내용이 가리키는 디렉터리 아래 codeql/codeql을 실행하던 경로가 남아 있으면 안 된다.
        pointer = self.root / "pointer"
        pointer.write_text(str(self.root / "bundle") + "\n")
        self.assertEqual(self.main("--codeql", str(pointer)), (2, []))


if __name__ == "__main__":
    unittest.main()
