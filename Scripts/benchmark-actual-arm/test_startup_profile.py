"""프로필 수집은 값을 노출하지 않고 실제 새 프로세스와 고정 요청을 결합해야 한다."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import startup_profile as profile


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.env = dict(profile.FIXED)
        for key, name in [("HOME", "home"), ("TMPDIR", "tmp"), ("XDG_CACHE_HOME", "cache")]:
            path = self.root / name
            path.mkdir()
            self.env[key] = str(path)
        self.expected = profile.environment_request(self.env)
        self.target = self.root / "correctness_controller.py"
        self.target.write_text("value = 1\n")
        self.script = Path(profile.__file__).resolve()

    def observation(self, additions=None, platform="darwin"):
        return profile.observe_request(self.expected, {**self.env, **(additions or {})}, platform=platform)

    def native_request(self):
        return profile.request(self.env, Path(sys.executable), self.target, [self.script, self.target])

    def run_child(self, request=None, env=None):
        request = request or self.native_request()
        path = self.root / "request.json"
        path.write_bytes(profile.encoded(request))
        report = self.root / "report.json"
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                "-S",
                "-B",
                str(self.script),
                "--request",
                str(path),
                "--sha256",
                profile.sha(path.read_bytes()),
                "--report",
                str(report),
            ],
            env=self.env if env is None else env,
            capture_output=True,
            timeout=15,
        )
        return result, json.loads(report.read_text()) if report.exists() else None

    def test_exact_environment_has_no_native_addition(self):
        self.assertIsNone(self.observation(platform="linux")["addition"])

    def test_darwin_one_key_is_digest_only(self):
        row = self.observation({profile.KEY: "synthetic-private-value"})
        self.assertNotIn("synthetic-private-value", json.dumps(row))
        self.assertEqual(row["addition"]["sha256"], profile.sha(b"synthetic-private-value"))
        self.assertEqual(row["addition"]["identifier"], profile.IDENTIFIER)

    def test_unknown_key_is_not_admitted(self):
        with self.assertRaisesRegex(ValueError, "observed-key-inventory"):
            self.observation({"UNACCEPTED": "anything"})

    def test_known_key_cannot_hide_another_extra(self):
        with self.assertRaises(ValueError):
            self.observation({profile.KEY: "synthetic", "UNACCEPTED": "anything"})

    def test_changed_fixed_value_fails(self):
        with self.assertRaisesRegex(ValueError, "observed-requested-values-differ"):
            self.observation({"LANG": "not-C"})

    def test_missing_requested_key_fails(self):
        actual = dict(self.env)
        del actual["HOME"]
        with self.assertRaises(ValueError):
            profile.observe_request(self.expected, actual)

    def test_linux_cannot_accept_synthetic_cf_key(self):
        with self.assertRaisesRegex(ValueError, "unexpected-nondarwin-addition"):
            self.observation({profile.KEY: "synthetic"}, platform="linux")

    def test_value_byte_bound_precedes_hashing(self):
        with self.assertRaisesRegex(ValueError, "startup-value-limit"):
            self.observation({profile.KEY: "한" * 86})

    def test_exact_multibyte_bound_is_preserved(self):
        row = self.observation({profile.KEY: "é" * 128})
        self.assertEqual(row["addition"]["utf8_bytes"], 256)

    def test_profile_digest_must_match(self):
        accepted = profile.profile(self.observation({profile.KEY: "one"}))
        with self.assertRaisesRegex(ValueError, "different-startup-profile"):
            profile.verify_observation(self.observation({profile.KEY: "two"}), self.expected, accepted)

    def test_expected_request_digest_must_match(self):
        row = self.observation()
        with self.assertRaisesRegex(ValueError, "different-launch-request"):
            profile.verify_observation(row, dict(self.expected, sha256="0" * 64), profile.profile(row))

    def test_boolean_schema_and_counts_are_rejected(self):
        row = self.observation({profile.KEY: "x"})
        for field in ["schema_version", "addition.utf8_bytes"]:
            changed = copy.deepcopy(row)
            if field.startswith("addition"):
                changed["addition"]["utf8_bytes"] = True
            else:
                changed[field] = True
            with self.subTest(field=field), self.assertRaises(ValueError):
                profile.validate_observation(changed)

    def test_requested_environment_never_accepts_cf_key(self):
        with self.assertRaisesRegex(ValueError, "launch-key-inventory"):
            profile.environment_request({**self.env, profile.KEY: "synthetic"})

    def test_request_source_replacement_refuses(self):
        request = self.native_request()
        self.target.write_text("value = 2\n")
        with self.assertRaisesRegex(ValueError, "source-inputs-changed"):
            profile.guard(request)

    def test_private_directory_same_path_replacement_refuses(self):
        request = self.native_request()
        old = Path(self.env["HOME"])
        old.rename(self.root / "old-home")
        old.mkdir()
        with self.assertRaisesRegex(ValueError, "private-directory-changed"):
            profile.guard(request)

    def test_clean_parent_real_child_preserves_exact_profile(self):
        result, row = self.run_child()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(row["status"], "passed")
        self.assertEqual(profile.profile(row["early"]), profile.profile(row["after_import"]))
        self.assertEqual(row["terminal_guard"], {"status": "passed"})
        self.assertNotIn(profile.KEY, self.env)

    def test_real_child_added_key_is_observed_as_linux_refusal(self):
        self.target.write_text("import os\nos.environ['__CF_USER_TEXT_ENCODING'] = 'synthetic-only'\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(row["status"], "failed")
        self.assertEqual(row["terminal_guard"], {"status": "passed"})
        self.assertNotIn("synthetic-only", json.dumps(row))
        self.assertNotIn(profile.KEY, self.env)

    def test_real_child_unknown_key_and_private_value_never_leak(self):
        self.target.write_text("import os\nos.environ['UNRELATED_PRIVATE_NAME'] = 'synthetic-secret-value'\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 1)
        for value in ["UNRELATED_PRIVATE_NAME", "synthetic-secret-value"]:
            self.assertNotIn(value, json.dumps(row))
            self.assertNotIn(value.encode(), result.stderr)

    def test_valid_looking_cached_bytecode_cannot_replace_admitted_source(self):
        import py_compile
        import os

        legitimate = "value = 1\n" + "#" * 200 + "\n"
        substituted = "raise ValueError('synthetic-cache-substitution')\n"
        substituted += "#" * (len(legitimate) - len(substituted) - 1) + "\n"
        self.target.write_text(substituted)
        os.utime(self.target, (1700000000, 1700000000))
        py_compile.compile(
            str(self.target),
            cfile=str(
                self.target.parent / "__pycache__" / (self.target.stem + "." + sys.implementation.cache_tag + ".pyc")
            ),
            doraise=True,
        )
        self.target.write_text(legitimate)
        os.utime(self.target, (1700000000, 1700000000))
        result, row = self.run_child()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(row["status"], "passed")

    def test_admitted_transitive_source_ignores_valid_looking_cached_bytecode(self):
        import py_compile

        imported = self.root / "bound_helper.py"
        good = "value = 1\n" + "#" * 200 + "\n"
        bad = "raise ValueError('synthetic-cache-substitution')\n"
        bad += "#" * (len(good) - len(bad) - 1) + "\n"
        imported.write_text(bad)
        os.utime(imported, (1700000000, 1700000000))
        py_compile.compile(
            str(imported),
            cfile=str(imported.parent / "__pycache__" / (imported.stem + "." + sys.implementation.cache_tag + ".pyc")),
            doraise=True,
        )
        imported.write_text(good)
        os.utime(imported, (1700000000, 1700000000))
        self.target.write_text("import sys\nsys.path.insert(0, " + repr(str(self.root)) + ")\nimport bound_helper\n")
        request = profile.request(self.env, Path(sys.executable), self.target, [self.script, self.target, imported])
        result, row = self.run_child(request)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(row["status"], "passed")

    def test_unbound_local_source_refuses_even_when_importable(self):
        imported = self.root / "unbound_helper.py"
        imported.write_text("value = 1\n")
        self.target.write_text("import sys\nsys.path.insert(0, " + repr(str(self.root)) + ")\nimport unbound_helper\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(row["status"], "failed")

    def test_local_extension_cannot_bypass_admitted_probe_sources(self):
        import importlib.machinery

        extension = self.root / "unexpected.so"
        extension.write_bytes(b"not-a-native-binary")
        self.target.write_text(
            "import importlib.machinery\nloader = importlib.machinery.ExtensionFileLoader('synthetic', "
            + repr(str(extension))
            + ")\nloader.create_module(importlib.machinery.ModuleSpec('synthetic', loader))\n"
        )
        request = self.native_request()
        with mock.patch.object(importlib.machinery.ExtensionFileLoader, "create_module", return_value=None) as original:
            with self.assertRaises(ValueError):
                profile.import_admitted_controller(request)
            original.assert_not_called()

    def test_local_symlink_cannot_import_unbound_outside_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            outside = Path(temporary) / "outside.py"
            outside.write_text("value = 1\n")
            (self.root / "unbound_helper.py").symlink_to(outside)
            self.target.write_text(
                "import sys\nsys.path.insert(0, " + repr(str(self.root)) + ")\nimport unbound_helper\n"
            )
            result, row = self.run_child()
            self.assertEqual(result.returncode, 1)
            self.assertEqual(row["status"], "failed")

    def test_local_symlink_cannot_import_unbound_outside_bytecode(self):
        import py_compile

        with tempfile.TemporaryDirectory() as temporary:
            outside = Path(temporary) / "outside.py"
            outside.write_text("value = 1\n")
            bytecode = Path(temporary) / "outside.pyc"
            py_compile.compile(str(outside), cfile=str(bytecode), doraise=True)
            (self.root / "unbound_helper.pyc").symlink_to(bytecode)
            self.target.write_text(
                "import sys\nsys.path.insert(0, " + repr(str(self.root)) + ")\nimport unbound_helper\n"
            )
            result, row = self.run_child()
            self.assertEqual(result.returncode, 1)
            self.assertEqual(row["status"], "failed")

    def test_unbound_sourceless_bytecode_refuses(self):
        import py_compile

        imported = self.root / "unbound_helper.py"
        imported.write_text("value = 1\n")
        py_compile.compile(str(imported), cfile=str(self.root / "unbound_helper.pyc"), doraise=True)
        imported.unlink()
        self.target.write_text("import sys\nsys.path.insert(0, " + repr(str(self.root)) + ")\nimport unbound_helper\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(row["status"], "failed")

    def test_import_exception_keeps_terminal_guard_and_hash_only_failure(self):
        self.target.write_text("raise ValueError('synthetic-private-message')\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(row["terminal_guard"]["status"], "passed")
        self.assertNotIn("synthetic-private-message", json.dumps(row))

    def test_import_system_exit_zero_cannot_substitute_for_completion(self):
        self.target.write_text("raise SystemExit(0)\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(row["observed_import_exit"], 0)
        self.assertEqual(row["terminal_guard"]["status"], "passed")

    def test_nested_125_stays_incomplete(self):
        self.target.write_text("raise SystemExit(125)\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 125)
        self.assertEqual(row["terminal_guard"]["status"], "unavailable")
        self.assertIsNone(row["after_import"])

    def test_interrupt_stays_incomplete(self):
        self.target.write_text("raise KeyboardInterrupt\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 125)
        self.assertEqual(row["failure_category"], "interrupt")

    def test_changed_input_during_import_refuses_terminal_guard(self):
        self.target.write_text("from pathlib import Path\nPath(__file__).write_text('replacement')\n")
        result, row = self.run_child()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(row["terminal_guard"]["status"], "failed")

    def test_duplicate_request_fields_refuse(self):
        with self.assertRaisesRegex(ValueError, "duplicate-field"):
            profile.strict(b'{"version":1,"version":1}')

    def test_fifo_refuses_without_waiting(self):
        path = self.root / "fifo"
        os.mkfifo(path)
        with self.assertRaises(ValueError):
            profile.read_file(path, 1024)

    def test_symlink_input_refuses(self):
        path = self.root / "alias"
        path.symlink_to(self.target)
        with self.assertRaises(OSError):
            profile.read_file(path, 1024)

    def test_physical_identity_does_not_coerce_float_metadata(self):
        original = profile.interpreter(sys.executable)
        changed = copy.deepcopy(original)
        changed["metadata"][0] = float(changed["metadata"][0])
        self.assertFalse(profile.same_physical(original, changed))

    def test_same_physical_alias_is_separate_spelling(self):
        path = self.root / "python-alias"
        path.symlink_to(sys.executable)
        left, right = profile.interpreter(path), profile.interpreter(sys.executable)
        self.assertTrue(profile.same_physical(left, right))
        self.assertNotEqual(left["selected_path"], right["selected_path"])


if __name__ == "__main__":
    unittest.main()
