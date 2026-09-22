"""Exercise the actual Python payload shipped inside the GitLab component."""

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def runner_source():
    template = ROOT / "templates/cartograph.yml"
    if not template.is_file():
        raise AssertionError("The distributable GitLab component is not implemented")
    text = template.read_text()
    payload = text.split("      # CARTOGRAPH_RUNNER_BEGIN\n", 1)[1]
    payload = payload.split("      # CARTOGRAPH_RUNNER_END", 1)[0]
    return textwrap.dedent(payload)


def diagnostic(path="Sources/Unused.swift", severity="warning", line=7):
    return {
        "ruleIdentifier": "unused-symbol", "severity": severity,
        "message": "Example.unused()", "subject": "s:Example.unused",
        "location": {"path": path, "line": line, "column": 5}, "details": [],
    }


def document(diagnostics=None):
    return {
        "tool": "cartograph", "version": "0.20.0", "command": "dead",
        "subject": ".", "suppressedCount": 0,
        "diagnostics": [diagnostic()] if diagnostics is None else diagnostics,
    }


class ComponentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = runner_source()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cartograph-gitlab-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "apps/Swift App"
        (self.project / "Sources").mkdir(parents=True)
        (self.project / "Sources/Unused.swift").write_text("func unused() {}\n")
        self.binary = self.root / "stub-cartograph"
        self.binary.write_text(textwrap.dedent('''\
            #!/usr/bin/env python3
            import json, os, pathlib, sys
            args = sys.argv[1:]
            pathlib.Path(os.environ["STUB_ARGV"]).write_text(json.dumps(args))
            if os.environ.get("STUB_WRITE", "true") == "true":
                target = args[args.index("--output") + 1]
                pathlib.Path(target).write_text(os.environ["STUB_REPORT"])
            sys.exit(int(os.environ.get("STUB_CODE", "0")))
            '''))
        self.binary.chmod(0o700)
        self.report = self.root / "gl-code-quality-report.json"
        self.raw = self.root / "cartograph-report.json"
        self.status = self.root / "cartograph-status.json"
        self.env = {
            **os.environ, "CI_PROJECT_DIR": str(self.root),
            "CARTOGRAPH_PROJECT": "apps/Swift App", "CARTOGRAPH_BINARY": str(self.binary),
            "CARTOGRAPH_COMMAND": "dead", "CARTOGRAPH_BUILD": "none",
            "CARTOGRAPH_ARGS": "", "CARTOGRAPH_FAIL_ON_FINDINGS": "true",
            "CARTOGRAPH_VERSION": "0.20.0",
            "CARTOGRAPH_SHA256": "833eb3c86deffc8e7c845297df57d41e35bb644bd5a943b09843e52075c6f072",
            "STUB_REPORT": json.dumps(document()), "STUB_ARGV": str(self.root / "argv.json"),
            "STUB_CODE": "0", "STUB_WRITE": "true",
        }

    def run_component(self, *, system="Darwin", **environment):
        # Linux CI에서도 동일 payload의 macOS 이후 계약을 검증한다. 실제 Mac 검증은 별도다.
        prefix = f'import platform\nplatform.system = lambda: {system!r}\n'
        return subprocess.run(
            [sys.executable, "-c", prefix + self.source], cwd=self.root,
            env={**self.env, **environment}, capture_output=True, text=True,
        )

    def test_nested_project_paths_and_limitations_are_preserved(self):
        payload = document()
        payload["limitations"] = ["objective-c-sources: 2 files are outside this analysis"]
        result = self.run_component(STUB_REPORT=json.dumps(payload))
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.report.read_text())
        self.assertEqual(len(report), 1)
        self.assertEqual(report[0]["location"], {"path": "apps/Swift App/Sources/Unused.swift", "lines": {"begin": 7}})
        self.assertEqual(report[0]["check_name"], "unused-symbol")
        self.assertEqual(report[0]["description"], "Example.unused()")
        self.assertEqual(report[0]["severity"], "minor")
        self.assertEqual(json.loads(self.raw.read_text()), payload)
        self.assertIn("limitation", result.stdout.lower())

    def test_findings_fail_unless_report_only_is_requested(self):
        for report_only, expected in [("true", 1), ("false", 0)]:
            with self.subTest(fail_on_findings=report_only):
                result = self.run_component(STUB_CODE="1", CARTOGRAPH_FAIL_ON_FINDINGS=report_only)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(len(json.loads(self.report.read_text())), 1)
                self.assertEqual(json.loads(self.status.read_text())["cli_exit_code"], 1)

    def test_tool_and_usage_failures_never_leave_a_quality_report(self):
        for code in ["2", "64", "127"]:
            for writes in ["true", "false"]:
                with self.subTest(code=code, writes=writes):
                    self.report.write_text("STALE QUALITY REPORT")
                    self.raw.write_text("STALE RAW REPORT")
                    result = self.run_component(STUB_CODE=code, STUB_WRITE=writes, CARTOGRAPH_FAIL_ON_FINDINGS="false")
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertFalse(self.report.exists())
                    self.assertFalse(self.raw.exists())

    def test_missing_and_malformed_reports_fail(self):
        for extra in [{"STUB_WRITE": "false"}, {"STUB_REPORT": "not json"}, {"STUB_REPORT": "{}"}]:
            with self.subTest(extra=extra):
                self.report.write_text("STALE")
                result = self.run_component(**extra)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(self.report.exists())

    def test_subject_fingerprint_survives_line_shifts_and_absolute_paths(self):
        result = self.run_component()
        self.assertEqual(result.returncode, 0, result.stderr)
        first = json.loads(self.report.read_text())[0]
        payload = document([diagnostic(str(self.project / "Sources/Unused.swift"), line=42)])
        result = self.run_component(STUB_REPORT=json.dumps(payload))
        self.assertEqual(result.returncode, 0, result.stderr)
        second = json.loads(self.report.read_text())[0]
        self.assertEqual(first["fingerprint"], second["fingerprint"])
        self.assertEqual(second["location"]["lines"]["begin"], 42)
        self.assertEqual(len(second["fingerprint"]), 64)

    def test_severity_mapping_and_empty_report(self):
        payload = document([diagnostic(severity=value) for value in ["info", "warning", "error"]])
        result = self.run_component(STUB_REPORT=json.dumps(payload))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({item["severity"] for item in json.loads(self.report.read_text())}, {"info", "minor", "major"})
        result = self.run_component(STUB_REPORT=json.dumps(document([])))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.report.read_text()), [])

    def test_unlocated_diagnostics_are_counted_without_fabricating_a_file(self):
        item = diagnostic()
        del item["location"]
        result = self.run_component(STUB_REPORT=json.dumps(document([item])), STUB_CODE="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(self.report.read_text()), [])
        self.assertEqual(json.loads(self.status.read_text())["unlocated_diagnostics"], 1)
        self.assertEqual(json.loads(self.raw.read_text())["diagnostics"], [item])

    def test_outside_repository_and_symlink_locations_are_rejected(self):
        (self.project / "outside").symlink_to(self.root.parent, target_is_directory=True)
        for path in ["../../../outside.swift", "/etc/passwd", "outside/escaped.swift"]:
            with self.subTest(path=path):
                result = self.run_component(STUB_REPORT=json.dumps(document([diagnostic(path)])))
                self.assertEqual(result.returncode, 2)
                self.assertFalse(self.report.exists())

    def test_invalid_diagnostic_shape_is_not_silently_dropped(self):
        mutations = [("severity", "fatal"), ("message", 42), ("ruleIdentifier", "")]
        for key, value in mutations:
            payload = document()
            payload["diagnostics"][0][key] = value
            result = self.run_component(STUB_REPORT=json.dumps(payload))
            self.assertEqual(result.returncode, 2, (key, result.stdout, result.stderr))
            self.assertFalse(self.report.exists())
        payload = document()
        payload["diagnostics"][0]["location"]["line"] = True
        self.assertEqual(self.run_component(STUB_REPORT=json.dumps(payload)).returncode, 2)

    def test_quoted_arguments_are_argv_and_never_shell_code(self):
        marker = self.root / "unexpected-shell-file"
        value = f'--exclude "Sources/With Space/**" --exclude "$(touch {marker})"'
        result = self.run_component(CARTOGRAPH_ARGS=value)
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = json.loads((self.root / "argv.json").read_text())
        self.assertIn("Sources/With Space/**", argv)
        self.assertIn(f"$(touch {marker})", argv)
        self.assertFalse(marker.exists())

    def test_managed_arguments_cannot_replace_reports_or_project(self):
        overrides = ["--output elsewhere", "--output=elsewhere", "-oelsewhere",
                     "--project /tmp", "--report-format text"]
        for args in overrides:
            with self.subTest(args=args):
                result = self.run_component(CARTOGRAPH_ARGS=args)
                self.assertEqual(result.returncode, 2)
                self.assertFalse((self.root / "argv.json").exists())

    def test_invalid_configuration_fails_before_running_the_cli(self):
        for extra in [
            {"CARTOGRAPH_COMMAND": "shell"}, {"CARTOGRAPH_PROJECT": "../"},
            {"CARTOGRAPH_FAIL_ON_FINDINGS": "maybe"}, {"CARTOGRAPH_BUILD": "custom"},
            {"CARTOGRAPH_BINARY": str(self.root / "missing")},
        ]:
            with self.subTest(extra=extra):
                self.assertEqual(self.run_component(**extra).returncode, 2)

    def test_non_macos_runner_has_actionable_failure(self):
        result = self.run_component(system="Linux")
        self.assertEqual(result.returncode, 2)
        self.assertIn("macOS", result.stderr)

    def test_failed_build_does_not_run_analysis_or_keep_old_reports(self):
        swift = self.root / "swift"
        swift.write_text("#!/bin/sh\nexit 13\n")
        swift.chmod(0o700)
        self.report.write_text("STALE")
        result = self.run_component(CARTOGRAPH_BUILD="swift", PATH=f"{self.root}:{os.environ['PATH']}")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(self.report.exists())
        self.assertFalse((self.root / "argv.json").exists())

    def test_download_requires_the_pinned_checksum_and_regular_executable(self):
        namespace = {"__name__": "component_test"}
        exec(compile(self.source, "component_payload", "exec"), namespace)
        data = b"#!/bin/sh\nexit 0\n"
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as package:
            member = tarfile.TarInfo("cartograph/cartograph")
            member.size = len(data)
            package.addfile(member, io.BytesIO(data))
        payload = archive.getvalue()
        environment = {"CARTOGRAPH_BINARY": "", "CARTOGRAPH_VERSION": "0.20.0",
                       "CARTOGRAPH_SHA256": hashlib.sha256(payload).hexdigest()}
        with patch.dict(os.environ, environment), \
                patch("urllib.request.urlopen", return_value=io.BytesIO(payload)) as fetch:
            binary = namespace["resolve_binary"](self.root, self.root)
            self.assertEqual(binary.read_bytes(), data)
            self.assertTrue(os.access(binary, os.X_OK))
            self.assertIn("/0.20.0/cartograph-0.20.0-macos-universal.tar.gz", fetch.call_args.args[0])
        environment["CARTOGRAPH_SHA256"] = "0" * 64
        with patch.dict(os.environ, environment), patch("urllib.request.urlopen", return_value=io.BytesIO(payload)):
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                namespace["resolve_binary"](self.root, self.root)
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as package:
            member = tarfile.TarInfo("cartograph/cartograph")
            member.type = tarfile.SYMTYPE
            member.linkname = "../../outside"
            package.addfile(member)
        payload = archive.getvalue()
        environment["CARTOGRAPH_SHA256"] = hashlib.sha256(payload).hexdigest()
        with patch.dict(os.environ, environment), patch("urllib.request.urlopen", return_value=io.BytesIO(payload)):
            with self.assertRaisesRegex(ValueError, "regular file"):
                namespace["resolve_binary"](self.root, self.root)


if __name__ == "__main__":
    unittest.main()
