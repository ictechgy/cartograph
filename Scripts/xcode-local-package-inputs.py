#!/usr/bin/env python3
"""Non-executing preflight for the intentionally finite local Swift package contract."""
from __future__ import annotations

import hashlib
import os
import copy
from pathlib import Path
import re


class UnsupportedPackage(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise UnsupportedPackage(reason)


def tokens(data: bytes) -> list[str]:
    """Read comments and literal strings without evaluating Swift or accepting leftovers."""
    require(len(data) <= 64 * 1024, "Package manifest exceeds 64 KiB")
    text = data.decode("utf-8")
    first = re.split(r"[\r\n]", text, maxsplit=1)[0]
    require(re.fullmatch(r"//[ \t]*swift-tools-version:[ \t]*(?:5\.9|6\.[0-3])[ \t]*", first) is not None,
            "Unsupported or missing first-line Swift tools version")
    result, i = [], 0
    while i < len(text):
        if text[i] in " \t\r\n":
            i += 1
        elif text.startswith("//", i):
            i += 2
            while i < len(text) and text[i] not in "\r\n":
                i += 1
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < len(text) and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                    require(depth <= 16, "Manifest comment nesting exceeds budget")
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            require(depth == 0, "Unterminated manifest comment")
        elif text[i] == '"':
            start, i = i, i + 1
            while i < len(text) and text[i] != '"':
                require(text[i].isascii() and text[i].isalnum() or text[i] in "_-",
                        "Manifest strings must be plain identifier literals; escapes/interpolation are unsupported")
                i += 1
            require(i < len(text), "Unterminated manifest string")
            result.append(text[start:i + 1])
            i += 1
        elif text[i].isascii() and (text[i].isalpha() or text[i] == "_"):
            start, i = i, i + 1
            while i < len(text) and text[i].isascii() and (text[i].isalnum() or text[i] == "_"):
                i += 1
            result.append(text[start:i])
        elif text[i] in "().,:[]=":
            result.append(text[i])
            i += 1
        else:
            raise UnsupportedPackage("Unsupported manifest syntax")
        require(len(result) <= 256, "Manifest token budget exceeded")
    return result


def manifest(data: bytes) -> dict:
    stream, position = tokens(data), 0

    def take(expected):
        nonlocal position
        require(position < len(stream) and stream[position] == expected,
                "Only one literal Package/library/Swift-target declaration is supported")
        position += 1

    def optional_comma():
        nonlocal position
        if position < len(stream) and stream[position] == ",":
            position += 1

    def literal(module=False):
        nonlocal position
        require(position < len(stream), "Missing manifest literal")
        value = stream[position]
        require(value.startswith('"') and value.endswith('"'), "Computed manifest names are unsupported")
        value = value[1:-1]
        pattern = r"[A-Za-z_][A-Za-z0-9_]{0,127}" if module else r"[A-Za-z_][A-Za-z0-9_-]{0,127}"
        require(re.fullmatch(pattern, value) is not None, "Unsupported package/product/module identifier")
        position += 1
        return value

    for item in ["import", "PackageDescription", "let", "package", "=", "Package", "(", "name", ":"]:
        take(item)
    name = literal()
    for item in [",", "products", ":", "[", ".", "library", "(", "name", ":"]:
        take(item)
    product = literal()
    for item in [",", "targets", ":", "["]:
        take(item)
    product_target = literal(module=True)
    optional_comma()
    take("]")
    optional_comma()
    take(")")
    optional_comma()
    for item in ["]", ",", "targets", ":", "[", ".", "target", "(", "name", ":"]:
        take(item)
    module = literal(module=True)
    optional_comma()
    take(")")
    optional_comma()
    take("]")
    optional_comma()
    take(")")
    require(position == len(stream) and module == product_target, "Unconsumed manifest syntax or product target mismatch")
    return {"name": name, "product": product, "module": module}


def read_manifest(path: Path) -> dict:
    require(path.is_file() and not path.is_symlink() and path.resolve() == path,
            "Manifest must be a canonical regular file")
    with path.open("rb") as stream:
        data = stream.read(64 * 1024 + 1)
    return manifest(data)


def diagnostic_path(relative: str) -> str:
    """A bounded escaped relative path, never terminal control bytes or full roots."""
    return ascii(relative[:256]) + ("..." if len(relative) > 256 else "")


EMPTY_XCODE_METADATA = {".swiftpm": "directory", ".swiftpm/xcode": "directory"}


def metadata_present(entries: dict[str, str]) -> bool:
    metadata = {p: value for p, value in entries.items() if p == ".swiftpm" or p.startswith(".swiftpm/")}
    require(not metadata or metadata == EMPTY_XCODE_METADATA,
            "Only the exact empty .swiftpm/xcode directory pair is supported")
    return bool(metadata)


def captured_spec(before: dict, after: dict) -> dict:
    """Permit only the observed empty directory creation, binding the entire result."""
    before_metadata, after_metadata = metadata_present(before["inventory"]), metadata_present(after["inventory"])
    require(not before_metadata or after_metadata, "Preexisting package metadata disappeared during capture")
    def inputs(spec):
        return {**spec, "inventory": {p: value for p, value in spec["inventory"].items() if p not in EMPTY_XCODE_METADATA}}
    require(inputs(before) == inputs(after), "Entire package source/configuration subtree changed during capture")
    origin = "absent" if not after_metadata else "preexisting" if before_metadata else "capture-created"
    return {**after, "generatedMetadataOrigin": origin}


def inventory(package: Path, module: str) -> dict[str, str]:
    """Bind every subtree entry; never hide unsupported inputs by their extension."""
    require(package.is_dir() and not package.is_symlink() and package.resolve() == package,
            "Package root must be a canonical local directory")
    result, pending, total, entries = {}, [(package, 0)], 0, 0
    source_prefix = "Sources/" + module + "/"
    while pending:
        children = []
        directory, depth = pending.pop()
        require(depth <= 128, "Package subtree depth budget exceeded")
        with os.scandir(directory) as scan:
            for entry in scan:
                entries += 1
                require(entries <= 4096, "Package subtree entry budget exceeded")
                children.append(Path(entry.path))
        for item in sorted(children):
            relative = item.relative_to(package).as_posix()
            require(not item.is_symlink() and item.resolve() == item and item.resolve().is_relative_to(package),
                    "Package subtree canonical path or symlink boundary exceeded")
            if item.is_dir():
                require(relative in ("Sources", "Sources/" + module) or relative.startswith(source_prefix)
                        or relative in EMPTY_XCODE_METADATA,
                        "Unexpected package directory: " + diagnostic_path(relative))
                result[relative] = "directory"
                pending.append((item, depth + 1))
            else:
                require(item.is_file(), "Package contains a nonregular entry")
                allowed = relative in ("Package.swift", "README.md", "LICENSE") or (
                    relative.startswith(source_prefix) and item.suffix == ".swift")
                require(allowed, "Unexpected package source/resource/configuration file: " + diagnostic_path(relative))
                with item.open("rb") as stream:
                    data = stream.read(4 * 1024 * 1024 + 1)
                total += len(data)
                require(len(data) <= 4 * 1024 * 1024 and total <= 64 * 1024 * 1024,
                        "Package subtree byte budget exceeded")
                result[relative] = hashlib.sha256(data).hexdigest()
    metadata_present(result)
    sources = [p for p, v in result.items() if p.startswith(source_prefix) and v != "directory"]
    require("Package.swift" in result and 0 < len(sources) <= 256, "Package requires 1...256 explicit Swift source files")
    return dict(sorted(result.items()))


def project(root: Path, plist: dict) -> tuple[dict, dict]:
    """Separate only validated package declarations before the existing PBX safety preflight."""
    objects = plist.get("objects", {})
    main = objects.get(plist.get("rootObject"), {})
    references = main.get("packageReferences", [])
    require(isinstance(references, list) and len(references) == 1, "Exactly one explicit local package is supported")
    reference = objects.get(references[0], {})
    require(set(reference) == {"isa", "relativePath"}, "Unsupported package reference metadata")
    path = reference.get("relativePath", "")
    require(reference.get("isa") == "XCLocalSwiftPackageReference" and isinstance(path, str)
            and path and not any(c in path for c in ("\\", ":", "$"))
            and all(p not in ("", ".", "..") for p in path.split("/")), "Package path must remain inside the project")
    package = root / path
    require(package.resolve() == package and package.resolve().is_relative_to(root), "Package path is noncanonical or external")
    spec = read_manifest(package / "Package.swift")
    spec.update({"path": path, "referenceID": references[0], "inventory": inventory(package, spec["module"])})
    dependencies = [(key, value) for key, value in objects.items() if value.get("isa") == "XCSwiftPackageProductDependency"]
    require(len(dependencies) == 1, "Exactly one local package product is supported")
    product_id, product = dependencies[0]
    require(set(product) == {"isa", "package", "productName"}, "Unsupported package product metadata")
    require(product.get("package") == references[0] and product.get("productName") == spec["product"],
            "Package product reference disagrees with literal manifest")
    for key, value in objects.items():
        if "Package" in value.get("isa", ""):
            require(key in (references[0], product_id), "Additional or external package objects are unsupported")
    consumers, linked_files = [], set()
    for target_id in main.get("targets", []):
        target = objects[target_id]
        uses = target.get("packageProductDependencies", [])
        require(uses in ([], [product_id]), "Unexpected package product dependency")
        links = []
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            for file_id in phase.get("files", []):
                build_file = objects[file_id]
                if "productRef" in build_file:
                    require(phase.get("isa") == "PBXFrameworksBuildPhase" and build_file.get("productRef") == product_id
                            and build_file.get("isa") == "PBXBuildFile" and set(build_file) == {"isa", "productRef"},
                            "Unsupported or conditional package build file")
                    links.append(file_id)
        require(bool(uses) == bool(links) and len(links) <= 1, "Package declaration and framework product link disagree")
        if links:
            require(not linked_files.intersection(links), "Shared package build file is ambiguous")
            consumers.append(target_id)
            linked_files.update(links)
    require(consumers and len(consumers) <= 64, "Expected bounded native package consumers")
    require({key for key, obj in objects.items() if "productRef" in obj} == linked_files,
            "Unowned package product build files are unsupported")
    sanitized = copy.deepcopy(plist)
    safe = sanitized["objects"]
    safe[sanitized["rootObject"]]["packageReferences"] = []
    for ident in consumers:
        safe[ident]["packageProductDependencies"] = []
        for phase_id in safe[ident].get("buildPhases", []):
            phase = safe[phase_id]
            phase["files"] = [f for f in phase.get("files", []) if f not in linked_files]
    for ident in linked_files | {references[0], product_id}:
        del safe[ident]
    spec.update({"productReferenceID": product_id, "consumers": sorted(consumers)})
    return spec, sanitized


def workspace_package_path(project_path: str, reference: str) -> str:
    """Normalize literal parent components without ever walking above the workspace root."""
    require(isinstance(reference, str) and 0 < len(reference.encode()) <= 4096
            and not reference.startswith("/") and not any(c in reference for c in ("\\", ":", "$"))
            and all(ord(c) >= 32 for c in reference), "Workspace package path must be a literal relative path")
    components = list(Path(project_path).parent.parts)
    for component in reference.split("/"):
        require(component, "Empty workspace package path component")
        if component == "..":
            require(components, "Package path escapes the workspace root")
            components.pop()
        elif component != ".":
            components.append(component)
        require(len(components) <= 128, "Package path depth budget exceeded")
    require(components, "The workspace root cannot be a package subtree")
    return "/".join(components)


def workspace_project(root: Path, project_path: str, plist: dict) -> tuple[list[dict], dict]:
    """Bind every local product/consumer once, allowing shared workspace-local package roots."""
    objects = plist.get("objects", {})
    main = objects.get(plist.get("rootObject"), {})
    references = main.get("packageReferences", [])
    require(isinstance(references, list) and 1 <= len(references) <= 16 and len(set(references)) == len(references),
            "Workspace project requires 1...16 unique explicit local package references")
    specs, by_product, paths = {}, {}, set()
    for ident in references:
        ref = objects.get(ident, {})
        require(set(ref) == {"isa", "relativePath"} and ref.get("isa") == "XCLocalSwiftPackageReference",
                "Only exact local workspace package references are supported")
        path = workspace_package_path(project_path, ref.get("relativePath", ""))
        package = root / path
        require(package.resolve() == package and package.is_relative_to(root) and path not in paths,
                "Package path is symlinked, duplicate or outside the workspace")
        paths.add(path)
        spec = read_manifest(package / "Package.swift")
        products = [(key, value) for key, value in objects.items()
                    if value.get("isa") == "XCSwiftPackageProductDependency" and value.get("package") == ident]
        require(len(products) == 1, "Each local package requires its exact literal product dependency")
        product_id, product = products[0]
        require(set(product) == {"isa", "package", "productName"} and product.get("productName") == spec["product"],
                "Workspace package product differs from its literal manifest")
        require(product_id not in by_product, "Shared package product identity")
        spec.update({"path": path, "referenceID": ident, "productReferenceID": product_id,
                     "inventory": inventory(package, spec["module"]), "consumers": []})
        specs[ident] = spec
        by_product[product_id] = spec
    allowed = set(references) | set(by_product)
    require(all(key in allowed or "Package" not in value.get("isa", "") for key, value in objects.items()),
            "Additional or remote package declarations are unsupported")
    linked_files = set()
    for target_id in main.get("targets", []):
        target = objects[target_id]
        uses = target.get("packageProductDependencies", [])
        require(isinstance(uses, list) and len(set(uses)) == len(uses) and set(uses) <= set(by_product),
                "Unexpected or duplicate native package product dependency")
        linked = set()
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            for file_id in phase.get("files", []):
                file = objects[file_id]
                if "productRef" not in file:
                    continue
                product_id = file["productRef"]
                require(phase.get("isa") == "PBXFrameworksBuildPhase" and set(file) == {"isa", "productRef"}
                        and file.get("isa") == "PBXBuildFile" and product_id in by_product
                        and product_id not in linked and file_id not in linked_files,
                        "Unknown, duplicate, shared or conditional workspace package link")
                linked.add(product_id)
                linked_files.add(file_id)
        require(set(uses) == linked, "Workspace package declarations and actual framework product links disagree")
        for product_id in linked:
            by_product[product_id]["consumers"].append(target_id)
    require({key for key, value in objects.items() if "productRef" in value} == linked_files,
            "Unowned workspace package product build files")
    require(all(0 < len(spec["consumers"]) <= 1000 for spec in specs.values()), "Missing native workspace package consumers")
    sanitized = copy.deepcopy(plist)
    safe = sanitized["objects"]
    safe[sanitized["rootObject"]]["packageReferences"] = []
    for target_id in main.get("targets", []):
        safe[target_id]["packageProductDependencies"] = []
        for phase_id in safe[target_id].get("buildPhases", []):
            phase = safe[phase_id]
            phase["files"] = [f for f in phase.get("files", []) if f not in linked_files]
    for ident in allowed | linked_files:
        del safe[ident]
    for spec in specs.values():
        spec["consumers"].sort()
    return sorted(specs.values(), key=lambda s: s["path"]), sanitized
