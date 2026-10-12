"""이름 없는 Apple 모듈 의존성을 실제 유닛 간선으로 꾸미지 않는다."""

import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mixed_adapter as adapter
from test_contracts import unit


class OptionalUnitNames(unittest.TestCase):
    def test_exact_retained_apple_dependency_lines_keep_absent_name(self):
        # CI 38203029381의 정규화된 경로 접두사만 합성 절대 경로로 바꾼다.
        for module in ["FeatureAlpha", "FeatureBeta"]:
            line = f"Unit | user | {module} | /evidence/Build/modules/{module}.swiftmodule"
            dependency = unit(deps=line)["dependencies"][0]
            self.assertEqual(
                dependency,
                dict(
                    kind="Unit",
                    scope="user",
                    module=module,
                    path=f"/evidence/Build/modules/{module}.swiftmodule",
                    name=None,
                ),
            )

    def test_named_unit_and_empty_module_are_distinct(self):
        for line, module in [
            ("Unit | user | FeatureAlpha | /build/A.swiftmodule | actual-unit", "FeatureAlpha"),
            ("Unit | user | /build/A.swiftmodule | actual-unit", ""),
        ]:
            dependency = unit(deps=line)["dependencies"][0]
            self.assertEqual(dependency["name"], "actual-unit")
            self.assertEqual(dependency["module"], module)
            self.assertEqual(dependency["path"], "/build/A.swiftmodule")

    def test_actual_swift_system_submodule_keeps_dotted_name(self):
        for module in ["Swift.Assert", "Swift.Collection.Lazy Views"]:
            dependency = unit(deps=f"Record | system | {module} | /sdk/Swift.private.swiftinterface | system-record")
            self.assertEqual(dependency["dependencies"][0]["module"], module)

    def test_ambiguous_malformed_or_relative_layouts_fail_closed(self):
        for line in [
            "Unit | user | Module | maybe-unit",
            "Unit | user | /build/A.swiftmodule | /build/another.swiftmodule",
            "Unit | user | Module | relative/A.swiftmodule",
            "Unit | user | Module | /build/A.swiftmodule | /invalid/unit-name",
            "Record | user | Module | /source/File.swift",
            "File | user | /source/File.swift | unexpected-name",
            "Unit | user |  | /build/A.swiftmodule",
        ]:
            with self.subTest(line=line), self.assertRaises(ValueError):
                unit(deps=line)

    def setup_units(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        module_path = Path(temporary.name).resolve() / "FeatureAlpha.swiftmodule"
        module_path.write_bytes(b"accepted module bytes")
        artifact = dict(
            path=str(module_path),
            sha256=hashlib.sha256(module_path.read_bytes()).hexdigest(),
            module="FeatureAlpha",
            provider="swift",
            target="x86_64-unknown-linux-gnu",
            sysroot="/",
            sources=["/project/Sources/Shared.swift"],
            outputs=["/build/alpha.o"],
        )
        units = {
            "app": unit(
                "app",
                "/build/app.o",
                "/project/Sources/App.swift",
                "AppFlow",
                f"Unit | user | FeatureAlpha | {module_path}",
            ),
            "alpha": unit(
                "alpha",
                "/build/alpha.o",
                "/project/Sources/Shared.swift",
                "FeatureAlpha",
                "Record | user | /project/Sources/Shared.swift | source-record",
            ),
        }
        expected = [
            dict(
                output=output,
                source=source,
                module=module,
                provider="swift",
                target="x86_64-unknown-linux-gnu",
                sysroot="/",
            )
            for output, source, module in [
                ("/build/app.o", "/project/Sources/App.swift", "AppFlow"),
                ("/build/alpha.o", "/project/Sources/Shared.swift", "FeatureAlpha"),
            ]
        ]
        expected[1]["module_artifact"] = artifact
        return units, expected, module_path

    def test_artifact_association_does_not_invent_cli_reachability(self):
        units, expected, _ = self.setup_units()
        result = adapter.select_units(units, expected)
        association = result["module_artifact_dependencies"][0]
        self.assertIsNone(association["name"])
        self.assertEqual(association["source_roots"], ["alpha"])
        self.assertEqual(association["root_units"], ["app"])
        self.assertEqual(result["records"][0]["root_units"], ["alpha"])
        self.assertEqual(result["reachable_units"], ["alpha", "app"])

    def test_missing_replaced_or_ambiguous_module_evidence_fails(self):
        units, expected, path = self.setup_units()
        for change in [
            "missing",
            "different-path",
            "different-target",
            "different-sdk",
            "different-provider",
            "source-inventory",
            "output-inventory",
            "duplicate",
            "hash",
        ]:
            altered = copy.deepcopy(expected)
            artifact = altered[1]["module_artifact"]
            if change == "missing":
                del altered[1]["module_artifact"]
            elif change == "different-path":
                artifact["path"] += ".different"
            elif change == "different-target":
                artifact["target"] = "arm64-apple-ios16.0-simulator"
            elif change == "different-sdk":
                artifact["sysroot"] = "/different-sdk"
            elif change == "different-provider":
                artifact["provider"] = "clang"
            elif change == "source-inventory":
                artifact["sources"] = ["/project/Sources/Other.swift"]
            elif change == "output-inventory":
                artifact["outputs"] = ["/build/old.o"]
            elif change == "duplicate":
                altered[0]["module_artifact"] = dict(artifact, outputs=["/build/app.o"])
            elif change == "hash":
                artifact["sha256"] = "0" * 64
            with self.subTest(change=change), self.assertRaises(ValueError):
                adapter.select_units(units, altered)
        path.write_bytes(b"replaced module bytes")
        with self.assertRaises(ValueError):
            adapter.select_units(units, expected)
