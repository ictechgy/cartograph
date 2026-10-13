"""실제 Xcode 선택의 null override 와 명시된 컴파일러 경계를 함께 검증한다."""

import copy
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import state_inputs

generation = state_inputs.generation


class DeveloperContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.toolchain = self.developer / "Toolchains/XcodeDefault.xctoolchain"
        self.platform = self.developer / "Platforms/iPhoneSimulator.platform"
        self.sdk = self.platform / "Developer/SDKs/iPhoneSimulator26.5.sdk"
        self.sdk.mkdir(parents=True)
        self.setup = dict(developer_dir=None, sdk_path=str(self.sdk), platform_path=str(self.platform))
        for key, relative in [
            ("clang", "usr/bin/clang"),
            ("swiftc", "usr/bin/swiftc"),
            ("library", "usr/lib/libIndexStore.dylib"),
        ]:
            path = self.toolchain / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"bound compiler bytes")
            self.setup[key] = str(path)

    def select(self):
        return generation.developer_context(self.setup)

    def test_native_null_override_derives_one_explicit_context(self):
        result = self.select()
        self.assertIsNone(result["requested_override"])
        self.assertEqual(result["developer_directory"], str(self.developer))
        self.assertEqual(result["toolchain"], str(self.toolchain))
        self.assertEqual(result["sdk"], str(self.sdk))
        self.assertIn(str(self.developer), result["directory_identities"])
        self.assertIn(str(self.sdk), result["directory_identities"])

    def test_matching_override_is_retained_and_disagreement_refuses(self):
        self.setup["developer_dir"] = str(self.developer)
        self.assertEqual(self.select()["requested_override"], str(self.developer))
        self.setup["developer_dir"] = str(self.root)
        with self.assertRaises(ValueError):
            self.select()

    def test_mixed_compiler_toolchains_refuse(self):
        other = self.developer / "Toolchains/Other.xctoolchain/usr/bin/clang"
        other.parent.mkdir(parents=True)
        other.write_bytes(b"bound compiler bytes")
        self.setup["clang"] = str(other)
        with self.assertRaises(ValueError):
            self.select()

    def test_library_outside_selected_toolchain_refuses(self):
        library = self.root / "libIndexStore.dylib"
        library.write_bytes(b"bound compiler bytes")
        self.setup["library"] = str(library)
        with self.assertRaises(ValueError):
            self.select()

    def test_sdk_in_another_developer_tree_refuses(self):
        other = self.root / "Other/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        other.mkdir(parents=True)
        self.setup["sdk_path"] = str(other)
        with self.assertRaises(ValueError):
            self.select()

    def test_selected_sdk_alias_retains_lexical_and_physical_identities(self):
        alias = self.sdk.with_name("iPhoneSimulator.sdk")
        alias.symlink_to(self.sdk, target_is_directory=True)
        self.setup["sdk_path"] = str(alias)
        selected = self.select()
        self.assertIn(str(alias), selected["directory_identities"])
        self.assertIn(str(self.sdk), selected["directory_identities"])
        self.assertEqual(selected["sdk"], str(self.sdk))

    def test_sdk_alias_escape_refuses(self):
        outside = self.root / "outside.sdk"
        outside.mkdir()
        alias = self.sdk.with_name("alias.sdk")
        alias.symlink_to(outside, target_is_directory=True)
        self.setup["sdk_path"] = str(alias)
        with self.assertRaises(ValueError):
            self.select()

    def test_same_spelling_sdk_replacement_changes_identity(self):
        before = self.select()
        self.sdk.rename(self.sdk.with_name("retained-original.sdk"))
        self.sdk.mkdir()
        self.assertNotEqual(before, self.select())

    def test_parent_spelling_and_invalid_override_types_refuse(self):
        original = copy.deepcopy(self.setup)
        for value in [False, 4, "", str(self.developer / "../Developer")]:
            self.setup = dict(original, developer_dir=value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.select()

    def test_missing_platform_and_tool_identity_paths_refuse(self):
        for key in ["platform_path", "swiftc"]:
            original = self.setup[key]
            self.setup[key] = str(self.root / "missing")
            with self.subTest(key=key), self.assertRaises((ValueError, OSError)):
                self.select()
            self.setup[key] = original

    def test_xcode_bundle_alias_uses_only_the_same_physical_developer(self):
        alias = self.root / "SelectedXcode.app"
        alias.symlink_to(self.root / "Xcode.app", target_is_directory=True)
        for key in ["clang", "swiftc", "library", "platform_path", "sdk_path"]:
            self.setup[key] = str(alias / Path(self.setup[key]).relative_to(self.root / "Xcode.app"))
        self.setup["developer_dir"] = str(alias / "Contents/Developer")
        context = self.select()
        self.assertEqual(context["developer_directory"], str(self.developer))
        self.assertIn(str(alias), context["directory_identities"])
        self.assertIn(str(self.developer), context["directory_identities"])
        config = dict(developer_directory=str(self.developer), developer_context=context)
        generation.verify_developer_context(config, self.setup)
        alias.unlink()
        alias.symlink_to(self.root / "Xcode.app", target_is_directory=True)
        with self.assertRaises(ValueError):
            generation.verify_developer_context(config, self.setup)

    def test_one_tool_alias_cannot_retarget_another_xcode_context(self):
        alias = self.root / "SelectedXcode.app"
        alias.symlink_to(self.root / "Xcode.app", target_is_directory=True)
        self.setup["clang"] = str(alias / "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        self.select()
        other = self.root / "Other.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        other.parent.mkdir(parents=True)
        other.write_bytes(b"bound compiler bytes")
        alias.unlink()
        alias.symlink_to(self.root / "Other.app", target_is_directory=True)
        with self.assertRaises(ValueError):
            self.select()

    def test_context_is_rechecked_and_changed_receipt_refuses(self):
        config = dict(developer_directory=str(self.developer), developer_context=self.select())
        generation.verify_developer_context(config, self.setup)
        config["developer_context"]["sdk"] = str(self.root)
        with self.assertRaises(ValueError):
            generation.verify_developer_context(config, self.setup)

    def test_absent_context_or_wrong_selected_developer_refuses(self):
        for config in [{}, dict(developer_directory=str(self.root), developer_context=self.select())]:
            with self.subTest(config=config), self.assertRaises(ValueError):
                generation.verify_developer_context(config, self.setup)


if __name__ == "__main__":
    unittest.main(verbosity=2)
