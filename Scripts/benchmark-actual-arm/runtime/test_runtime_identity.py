"""설치 대상과 실제 가져온 코드가 바뀌면 검증 전용 실행도 거부한다."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

import runtime_identity as runtime


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.target = self.root / "dependencies"
        package = self.target / "psutil"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text('__version__ = "7.2.2"\n')
        metadata = self.target / "psutil-7.2.2.dist-info"
        metadata.mkdir()
        (metadata / "METADATA").write_text("Metadata-Version: 2.4\nName: psutil\nVersion: 7.2.2\n")
        (metadata / "RECORD").write_text("synthetic fixture; not an installed official wheel\n")
        self.projection = {
            "schema_version": 1,
            "source_format": "pip-install-report-v1",
            "distributions": [
                {
                    "name": "psutil",
                    "version": "7.2.2",
                    "url": "https://files.pythonhosted.org/packages/aa/bb/"
                    + "c" * 60
                    + "/psutil-7.2.2-cp36-abi3-macosx_11_0_arm64.whl",
                    "sha256": "a" * 64,
                    "is_direct": False,
                    "is_yanked": False,
                    "requested": True,
                }
            ],
        }

    def test_private_environment_uses_no_inherited_values(self):
        environment = runtime.private_environment(self.root / "private")
        self.assertEqual(
            set(environment),
            {"PATH", "LANG", "LC_ALL", "TZ", "PYTHONDONTWRITEBYTECODE", "HOME", "TMPDIR", "XDG_CACHE_HOME"},
        )
        self.assertEqual(len({environment[k] for k in ["HOME", "TMPDIR", "XDG_CACHE_HOME"]}), 3)
        self.assertTrue(all(list(Path(environment[k]).iterdir()) == [] for k in ["HOME", "TMPDIR", "XDG_CACHE_HOME"]))
        with self.assertRaises(ValueError):
            runtime.private_environment(self.root / "private")

    def test_exact_target_is_sealed_and_verified(self):
        seal = runtime.package_snapshot(self.target, self.projection)
        self.assertEqual(seal["version"], "7.2.2")
        self.assertTrue(runtime.verify_package(self.target, seal)["matches"])

    def test_changed_source_invalidates_inventory(self):
        seal = runtime.package_snapshot(self.target, self.projection)
        (self.target / "psutil/__init__.py").write_text("changed")
        with self.assertRaises(ValueError):
            runtime.verify_package(self.target, seal)

    def test_unexpected_distribution_is_not_silently_dropped(self):
        (self.target / "other").mkdir()
        with self.assertRaises(ValueError):
            runtime.package_snapshot(self.target, self.projection)

    def test_link_inside_package_is_refused_even_when_internal(self):
        (self.target / "psutil/alias.py").symlink_to("__init__.py")
        with self.assertRaises(ValueError):
            runtime.package_snapshot(self.target, self.projection)

    def test_wrong_version_or_unsigned_url_shape_is_refused(self):
        for field, value in [("version", "7.2.1"), ("url", "https://example.com/psutil.whl")]:
            projection = json.loads(json.dumps(self.projection))
            projection["distributions"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.package_snapshot(self.target, projection)

    def test_changed_metadata_version_refuses(self):
        (self.target / "psutil-7.2.2.dist-info/METADATA").write_text("Name: psutil\nVersion: 7.2.1\n")
        with self.assertRaises(ValueError):
            runtime.package_snapshot(self.target, self.projection)

    def test_duplicate_metadata_version_refuses(self):
        with (self.target / "psutil-7.2.2.dist-info/METADATA").open("a") as f:
            f.write("Version: 7.2.2\n")
        with self.assertRaises(ValueError):
            runtime.package_snapshot(self.target, self.projection)

    def test_builtin_and_frozen_are_explicit(self):
        modules = {}
        for name, origin in [("builtin_control", "built-in"), ("frozen_control", "frozen")]:
            modules[name] = types.SimpleNamespace(__spec__=types.SimpleNamespace(origin=origin))
        result = runtime.module_snapshot(modules, self.target, {})
        self.assertEqual({v["kind"] for v in result["modules"].values()}, {"built-in", "frozen"})

    def test_named_typing_namespace_without_actual_parent_is_refused(self):
        modules = {"typing.io": types.SimpleNamespace(__spec__=None, __module__="typing")}
        with self.assertRaises(ValueError):
            runtime.module_snapshot(modules, self.target, {})

    def test_unbound_module_origin_is_refused(self):
        path = self.root / "unexpected.py"
        path.write_text("value=1")
        modules = {
            "unexpected": types.SimpleNamespace(__spec__=types.SimpleNamespace(origin=str(path)), __file__=str(path))
        }
        with self.assertRaises(ValueError):
            runtime.module_snapshot(modules, self.target, {})

    def test_selected_package_origin_is_bound(self):
        path = self.target / "psutil/__init__.py"
        modules = {
            "psutil": types.SimpleNamespace(__spec__=types.SimpleNamespace(origin=str(path)), __file__=str(path))
        }
        result = runtime.module_snapshot(modules, self.target, {})
        self.assertEqual(result["modules"]["psutil"]["kind"], "private-package")
        self.assertEqual(result["modules"]["psutil"]["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())

    def cache_fixture(self):
        source = self.target / "psutil/__init__.py"
        cache = source.parent / "__pycache__/__init__.fixture.pyc"
        cache.parent.mkdir()
        cache.write_bytes(b"observed bytecode fixture\n")
        module = types.SimpleNamespace(
            __spec__=types.SimpleNamespace(origin=str(source), cached=str(cache)), __file__=str(source)
        )
        return source, cache, module

    def test_spec_only_bytecode_cache_metadata_is_bound(self):
        source, cache, module = self.cache_fixture()
        # Python 3.15는 __cached__를 설정하지 않는다. 실제 spec과 파일 바이트를 함께 검증한다.
        # https://docs.python.org/3/reference/datamodel.html#module.__file__
        # https://docs.python.org/3/library/importlib.html#importlib.machinery.ModuleSpec.cached
        module.__spec__ = importlib.util.spec_from_file_location("psutil", source)
        module.__spec__.cached = str(cache)
        self.assertFalse(hasattr(module, "__cached__"))
        result = runtime.module_snapshot({"psutil": module}, self.target, {})
        row = result["modules"]["psutil"]
        self.assertIn("bytecode_cache", row)
        self.assertEqual(
            row,
            dict(
                kind="private-package", path=str(source),
                sha256=hashlib.sha256(source.read_bytes()).hexdigest(), bytes=source.stat().st_size,
                bytecode_cache=dict(
                    path=str(cache), exists=True,
                    sha256=hashlib.sha256(cache.read_bytes()).hexdigest(), bytes=cache.stat().st_size,
                ),
            ),
        )
        self.assertEqual(result["bytes"], source.stat().st_size + cache.stat().st_size)

    def test_legacy_and_matching_modern_cache_metadata_are_bound(self):
        source, cache, module = self.cache_fixture()
        for modern, legacy in [
            (None, str(cache)), ({}, str(cache)), ({"cached": None}, str(cache)),
            ({"cached": str(cache)}, str(cache)), ({"cached": str(cache)}, None),
            ({"cached": str(cache.parent / ".." / "__pycache__" / cache.name)}, str(cache)),
        ]:
            with self.subTest(modern=modern, legacy=legacy):
                module.__spec__ = None if modern is None else types.SimpleNamespace(origin=str(source), **modern)
                module.__cached__ = legacy
                result = runtime.module_snapshot({"psutil": module}, self.target, {})
                self.assertEqual(
                    result["modules"]["psutil"]["bytecode_cache"],
                    dict(path=str(cache), exists=True, **runtime.file_identity(cache)),
                )
                self.assertEqual(result["bytes"], source.stat().st_size + cache.stat().st_size)

    def test_declared_absent_bytecode_cache_is_reported(self):
        source, cache, module = self.cache_fixture()
        cache.unlink()
        result = runtime.module_snapshot({"psutil": module}, self.target, {})
        self.assertEqual(result["modules"]["psutil"]["bytecode_cache"], dict(path=str(cache), exists=False))
        self.assertEqual(result["bytes"], source.stat().st_size)

    def test_missing_bytecode_cache_metadata_is_not_invented(self):
        source = self.target / "psutil/__init__.py"
        for spec in [
            None, types.SimpleNamespace(origin=str(source)), types.SimpleNamespace(origin=str(source), cached=None),
        ]:
            for legacy in [{}, {"__cached__": None}]:
                with self.subTest(spec=spec, legacy=legacy):
                    module = types.SimpleNamespace(__spec__=spec, __file__=str(source), **legacy)
                    result = runtime.module_snapshot({"psutil": module}, self.target, {})
                    self.assertNotIn("bytecode_cache", result["modules"]["psutil"])
                    self.assertEqual(result["bytes"], source.stat().st_size)

    def test_malformed_bytecode_cache_metadata_refuses(self):
        source, cache, module = self.cache_fixture()
        for value in [False, 0, [], {}, cache, "", b"cache.pyc", "bad\x00cache.pyc"]:
            for field in ["modern", "legacy"]:
                with self.subTest(value=value, field=field):
                    module.__spec__.cached = value if field == "modern" else str(cache)
                    module.__cached__ = value if field == "legacy" else str(cache)
                    with self.assertRaisesRegex(ValueError, "Invalid module bytecode cache metadata"):
                        runtime.module_snapshot({"psutil": module}, self.target, {})

    def test_conflicting_bytecode_cache_metadata_refuses(self):
        source, cache, module = self.cache_fixture()
        module.__cached__ = str(cache.with_name("other.pyc"))
        with self.assertRaisesRegex(ValueError, "Conflicting module bytecode cache metadata"):
            runtime.module_snapshot({"psutil": module}, self.target, {})

    def test_modern_and_legacy_cache_paths_cannot_escape(self):
        source, cache, module = self.cache_fixture()
        outside = self.root / "outside.pyc"
        outside.write_bytes(b"outside bytecode fixture\n")
        alias = cache.with_name("outside-link.pyc")
        alias.symlink_to(outside)
        for path in [outside, alias]:
            for field in ["modern", "legacy"]:
                with self.subTest(path=path, field=field):
                    module.__spec__.cached = str(path) if field == "modern" else None
                    module.__cached__ = str(path) if field == "legacy" else None
                    with self.assertRaisesRegex(ValueError, "Module bytecode cache escapes selected origin"):
                        runtime.module_snapshot({"psutil": module}, self.target, {})

    def test_private_bytecode_cache_root_is_accepted(self):
        source, cache, module = self.cache_fixture()
        private = self.root / "private-bytecode"
        private.mkdir()
        moved = private / cache.name
        cache.rename(moved)
        module.__spec__.cached = str(moved)
        result = runtime.module_snapshot({"psutil": module}, self.target, {}, private)
        self.assertEqual(
            result["modules"]["psutil"]["bytecode_cache"],
            dict(path=str(moved), exists=True, **runtime.file_identity(moved)),
        )
        self.assertEqual(result["bytes"], source.stat().st_size + moved.stat().st_size)

    def test_bytecode_cache_bytes_remain_bounded(self):
        source, cache, module = self.cache_fixture()
        for limit, message in [
            (source.stat().st_size + cache.stat().st_size - 1, "Observed module bytes exceed limit"),
            (cache.stat().st_size - 1, "Invalid bounded runtime input"),
        ]:
            with self.subTest(limit=limit), mock.patch.object(runtime, "MAX_MODULE_BYTES", limit):
                with self.assertRaisesRegex(ValueError, message):
                    runtime.module_snapshot({"psutil": module}, self.target, {})

    def test_missing_file_and_namespace_are_not_falsely_complete(self):
        for origin in [str(self.target / "psutil/missing.py"), None]:
            modules = {"psutil": types.SimpleNamespace(__spec__=types.SimpleNamespace(origin=origin), __file__=origin)}
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                runtime.module_snapshot(modules, self.target, {})

    def test_code_origin_requires_exact_hash(self):
        path = self.root / "selected.py"
        path.write_text("value=1")
        modules = {
            "selected": types.SimpleNamespace(__spec__=types.SimpleNamespace(origin=str(path)), __file__=str(path))
        }
        expected = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()}
        self.assertEqual(
            runtime.module_snapshot(modules, self.target, expected)["modules"]["selected"]["kind"], "selected-script"
        )
        path.write_text("changed")
        with self.assertRaises(ValueError):
            runtime.module_snapshot(modules, self.target, expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
