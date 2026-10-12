"""Source transformations and compiler command plans; independent of either product."""

from __future__ import annotations
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent
HEADER = "Sources/BridgeKit/include/CGCore.h"
RENAMED_HEADER = HEADER.replace("CGCore.h", "RenamedCore.h")
LEGACY = "Sources/AppFlow/Legacy.swift"
RELOCATED = LEGACY.replace("Legacy.swift", "Relocated.swift")
QUERY_KEYS = [
    "base",
    "alternate",
    "header",
    "cpp_bridge",
    "objc_quote",
    "alpha_int",
    "beta_int",
    "alpha_extension",
    "alpha_string",
    "checkout",
]
STAGES = [
    ("initial", None, "success", "initial"),
    ("header_edit_unbuilt", "edit_header", None, None),
    ("header_edit_rebuilt", None, "success", "header_edit"),
    ("header_rename_unbuilt", "rename_header", None, None),
    ("header_rename_rebuilt", None, "success", "header_rename"),
    ("header_delete_unbuilt", "delete_header", None, None),
    ("header_delete_build_failed", None, "failure", None),
    ("header_restored_rebuilt", "restore", "success", "initial"),
    ("swift_rename_unbuilt", "rename_swift", None, None),
    ("swift_rename_rebuilt", None, "success", "swift_rename"),
    ("swift_delete_unbuilt", "delete_swift", None, None),
    ("swift_delete_rebuilt", None, "success", "swift_delete"),
    ("restored_rebuilt", "restore", "success", "initial"),
]


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(root: Path) -> dict:
    if not root.exists():
        return {}
    return {str(p.relative_to(root)): digest(p) for p in sorted(root.rglob("*")) if p.is_file()}


def source_manifest(project: Path) -> dict:
    result = {}
    for directory in ["Sources", "Tests"]:
        result.update({f"{directory}/{p}": d for p, d in manifest(project / directory).items()})
    result[".cartograph.yml"] = digest(project / ".cartograph.yml")
    return result


def replace_exact(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise ValueError(f"Expected one mutation anchor in {path}: {old!r}")
    path.write_text(text.replace(old, new))


def mutate(project: Path, operation: str) -> None:
    if operation == "edit_header":
        for name in ["CGHeaderRoute", "CGHeaderCppRoute"]:
            replace_exact(
                project / HEADER,
                f"{name}(int value) {{\n    return CGBase(value);",
                f"{name}(int value) {{\n    return CGAlternate(value);",
            )
    elif operation == "rename_header":
        (project / HEADER).rename(project / RENAMED_HEADER)
        for name in [
            "Sources/BridgeKit/Core.m",
            "Sources/BridgeKit/CppBridge.mm",
            "Sources/BridgeKit/ObjCQuote.m",
            "Sources/BridgeKit/include/BridgeKit.h",
        ]:
            replace_exact(project / name, '"CGCore.h"', '"RenamedCore.h"')
    elif operation == "delete_header":
        (project / RENAMED_HEADER).unlink()
    elif operation == "rename_swift":
        (project / LEGACY).rename(project / RELOCATED)
    elif operation == "delete_swift":
        (project / RELOCATED).unlink()
    elif operation == "restore":
        for name in ["Sources", "Tests"]:
            shutil.rmtree(project / name)
            shutil.copytree(ROOT / "fixture" / name, project / name)
    else:
        raise ValueError(f"Unknown source mutation: {operation}")


def command_plan(
    project: Path,
    store: Path,
    build: Path,
    sdk: str,
    triple: str,
    swiftc: str,
    clang: str,
    platform: str,
    with_tests: bool = False,
) -> list[dict]:
    include = project / "Sources/BridgeKit/include"
    modules = build / "modules"
    common = ["-target", triple, "-isysroot", sdk, "-I", str(include), "-O0", "-g", "-index-store-path", str(store)]
    result = []
    for filename in ["Core.m", "CppBridge.mm", "ObjCQuote.m"]:
        source = project / "Sources/BridgeKit" / filename
        obj = build / "BridgeKit" / (filename + ".o")
        args = [clang, *common]
        if filename.endswith(".mm"):
            args += ["-std=c++17"]
        if filename == "ObjCQuote.m":
            args += ["-fobjc-arc"]
        args += ["-MD", "-MF", str(obj.with_suffix(".d")), "-c", str(source), "-o", str(obj)]
        result.append(dict(name="clang-" + filename, args=args, outputs=[str(obj)], source_paths=[str(source)]))
    groups = [
        ("FeatureAlpha", [project / "Sources/Shared/SharedCalls.swift"]),
        ("FeatureBeta", [project / "Sources/Shared/SharedCalls.swift"]),
        ("AppFlow", sorted((project / "Sources/AppFlow").glob("*.swift"))),
    ]
    if with_tests:
        groups.append(("FixtureTests", [project / "Tests/FixtureTests.swift"]))
    for module, sources in groups:
        output_map = {str(s): {"object": str(build / module / (s.name + ".o"))} for s in sources}
        mapping_path = build / module / "output-file-map.json"
        args = [
            swiftc,
            "-target",
            triple,
            "-sdk",
            sdk,
            "-parse-as-library",
            "-Onone",
            "-g",
            "-module-name",
            module,
            "-I",
            str(include),
            "-I",
            str(modules),
            "-module-cache-path",
            str(build / "module-cache"),
            "-index-store-path",
            str(store),
            "-emit-object",
            "-emit-module",
            "-emit-module-path",
            str(modules / (module + ".swiftmodule")),
            "-output-file-map",
            str(mapping_path),
        ]
        if module == "FixtureTests":
            args += [
                "-F",
                str(Path(platform) / "Developer/Library/Frameworks"),
                "-I",
                str(Path(platform) / "Developer/usr/lib"),
            ]
        args += [str(s) for s in sources]
        result.append(
            dict(
                name="swift-" + module,
                args=args,
                output_file_map=output_map,
                output_map_path=str(mapping_path),
                source_paths=[str(s) for s in sources],
                outputs=[v["object"] for v in output_map.values()],
            )
        )
    return result
