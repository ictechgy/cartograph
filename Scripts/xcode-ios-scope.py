#!/usr/bin/env python3
"""Read finite iOS build evidence without creating devices or executing test bundles."""
from pathlib import Path
import re


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def local(path, root, maximum=64 * 1024):
    require(path.is_relative_to(root) and path.resolve() == path and path.is_file() and not path.is_symlink(),
            "iOS auxiliary input must be a canonical local regular file")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, "iOS auxiliary input exceeds its byte budget")
    return data


def validate_configurations(objects, paths, root):
    """Only literal compilation definitions and bounded local includes may enter an xcconfig."""
    seen, active, total = set(), set(), 0

    def read(relative, depth=0):
        nonlocal total
        require(isinstance(relative, str) and relative and not any(x in relative for x in ("\\", "$", ":"))
                and all(x not in ("", ".", "..") for x in relative.split("/"))
                and not relative.startswith("/") and depth <= 16 and relative not in active,
                "Unsupported xcconfig include path, depth or cycle")
        if relative in seen:
            return
        require(len(seen) < 64, "xcconfig include budget exceeded")
        data = local(root / relative, root)
        total += len(data)
        require(total <= 1024 * 1024 and b"\0" not in data, "xcconfig total byte or encoding budget exceeded")
        active.add(relative)
        for raw in data.decode("utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("//"):
                continue
            match = re.fullmatch(r'#include "([^"\r\n]+)"', line)
            if match:
                read((Path(relative).parent / match[1]).as_posix(), depth + 1)
                continue
            require("=" in line, "Unsupported xcconfig directive")
            key, value = (x.strip() for x in line.split("=", 1))
            require(key in ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "GCC_PREPROCESSOR_DEFINITIONS")
                    and value and re.fullmatch(r"[A-Za-z0-9_ =\t]*", value.replace("$(inherited)", "")) is not None,
                    "Only literal compilation definitions are supported in iOS xcconfig inputs")
        active.remove(relative)
        seen.add(relative)

    for obj in objects.values():
        if "baseConfigurationReference" in obj:
            path = paths.get(obj["baseConfigurationReference"])
            require(isinstance(path, str) and path.endswith(".xcconfig"), "xcconfig reference is not a local group member")
            read(path)


def closure(targets, selected):
    found, pending = set(), list(selected)
    while pending:
        ident = pending.pop()
        require(ident in targets, "Unknown native target in selected dependency closure")
        if ident not in found:
            found.add(ident)
            pending.extend(targets[ident]["dependencies"])
    return found


def native_outputs(targets, settings, selected):
    """The app's actual code image can differ from its generated debug-dylib host stub."""
    result = {}
    for ident in sorted(closure(targets, selected)):
        target = targets[ident]
        rows = [r["buildSettings"] for r in settings if r.get("target") == target["name"]]
        require(len(rows) == 1, "Ambiguous iOS native settings")
        values = rows[0]
        output = str(Path(values["TARGET_BUILD_DIR"]) / values["EXECUTABLE_PATH"])
        if target["productType"] == "com.apple.product-type.application" and values.get("ENABLE_DEBUG_DYLIB") == "YES":
            output += ".debug.dylib"
        result[ident] = output
    return result


def host_stub_link(commands, executable, code_output, proof):
    """Bind exactly one observed code-image operand using only verified OS temporary aliases."""
    rows = [a for a in commands if "-map" in a and "-o" in a
            and proof.physical_temporary_alias(proof.operand(a, "-o")) == executable]
    require(len(rows) == 1 and sum(proof.physical_temporary_alias(token) == code_output for token in rows[0]) == 1,
            "Missing unique actual app-stub link")
    return rows[0]


def assemble(root, derived, store, log, snapshot, targets, settings, selected, architecture, proof):
    """Join native Swift records, actual code objects, image links, bundle metadata and resource copies."""
    files, commands = proof.Files(derived / "Build", store), proof.command_rows(log)
    outputs = native_outputs(targets, settings, selected)
    native, resources = [], []
    for ident, code_output in sorted(outputs.items()):
        target = targets[ident]
        values = next(r["buildSettings"] for r in settings if r.get("target") == target["name"])
        sources = {str(root / path) for path in target["sources"]}
        compilations, records = proof.compiler_records(files, commands, sources, target["module"], store,
                                                       snapshot, root, architecture)
        rows = [a for a in commands if "-map" in a and "-o" in a
                and proof.physical_temporary_alias(proof.operand(a, "-o")) == code_output]
        require(len(rows) == 1, "Missing or ambiguous iOS native code-image link")
        linked, inputs, live = proof.link(files, rows[0], architecture,
                                         required={x["object"] for x in compilations.values()})
        require({x["object"] for x in compilations.values()} <= inputs & live,
                "Native Swift objects lack positive code-image link contribution")
        directory = Path(values["TARGET_BUILD_DIR"])
        executable = str(directory / values["EXECUTABLE_PATH"])
        info = str(directory / values["FULL_PRODUCT_NAME"] / "Info.plist")
        files.read(info)
        item = {"targetID": ident, "compilations": [compilations[x] for x in sorted(compilations)],
                "records": sorted(records, key=lambda r: (r["source"], r["unit"], r["record"])),
                "link": linked, "executable": executable, "infoPlist": info}
        if executable != code_output:
            argv = host_stub_link(commands, executable, code_output, proof)
            files.responses(argv)
            file_list = str(proof.canonical(proof.operand(argv, "-filelist"), files.build))
            files.read(file_list)
            files.read(executable, "object")
            map_path = str(proof.canonical(proof.operand(argv, "-map"), files.build))
            proof.live_owners(files, map_path, executable, architecture)
            item["hostLink"] = {"argv": argv, "fileList": file_list, "output": executable, "linkMap": map_path}
        native.append(item)
        for source in target.get("resources", []):
            output = str(directory / values["FULL_PRODUCT_NAME"] / Path(source).name)
            require(local(root / source, root, 4 * 1024 * 1024) == local(Path(output), derived / "Build", 4 * 1024 * 1024),
                    "Plain resource input and bundle copy bytes differ")
            resources.append({"targetID": ident, "source": source, "output": output})
    return {"platform": "ios-simulator", "indexStore": str(store), "files": files.finish(),
            "targets": native, "resources": sorted(resources, key=lambda r: (r["targetID"], r["source"]))}
