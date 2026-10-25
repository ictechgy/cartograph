#!/usr/bin/env python3
"""Bind finite local-package compiler, record and positive linker contribution evidence.

These readers execute no manifest, compiler, linker, response file or project code.
They refuse incomplete joins instead of treating missing contribution as outside scope.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import stat


class EvidenceError(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise EvidenceError(reason)


def runtime_path(token, previous=None):
    return token.startswith(("@loader_path/", "@executable_path/", "@rpath/")) or (
        previous == "-rpath" and token in ("@loader_path", "@executable_path", "@rpath"))


def operand(argv, option):
    require(argv.count(option) == 1, "Missing or ambiguous compiler/link option: " + option)
    tail = argv[argv.index(option) + 1:]
    while tail and tail[0] in ("-Xlinker", "-Xclang-linker"):
        tail = tail[1:]
    require(tail and not tail[0].startswith("-"), "Missing compiler/link operand: " + option)
    return tail[0]


def command_rows(log):
    result = []
    require(len(log.encode()) <= 32 * 1024 * 1024, "Build log exceeds proof budget")
    for line in log.splitlines():
        if not any(marker in line for marker in (" -output-file-map ", " -filelist ", " -map ")):
            continue
        require(len(line.encode()) <= 256 * 1024, "Build command byte budget exceeded")
        argv = shlex.split(line.strip())
        require(0 < len(argv) <= 1000 and (argv[0].startswith("/") or argv[0].startswith("builtin-")),
                "Unrecognized or oversized build command")
        result.append(argv)
        require(len(result) <= 256, "Build command count budget exceeded")
    return result


def canonical(value, root):
    require(isinstance(value, str) and 0 < len(value.encode()) <= 4096, "Invalid proof path")
    path = Path(physical_temporary_alias(value))
    require(path.is_absolute() and not path.is_symlink() and path.resolve() == path
            and path.is_relative_to(root), "Proof path escapes its canonical capture root")
    return path


def physical_temporary_alias(value):
    if isinstance(value, str) and value.startswith(("/tmp/", "/var/folders/")):
        path = Path(value)
        if path.exists() and str(path.resolve()) == "/private" + value:
            return str(path.resolve())
    return value


class Files:
    CAPS = {"document": (8, 32), "object": (64, 256), "record": (16, 64)}

    def __init__(self, build, store):
        self.build, self.store = build, store
        self.items, self.totals = {}, dict.fromkeys(self.CAPS, 0)

    def read(self, value, kind="document"):
        path = canonical(value, self.store if kind == "record" else self.build)
        require(path.is_file(), "Missing regular proof file: " + str(path))
        maximum, total_maximum = (n * 1024 * 1024 for n in self.CAPS[kind])
        flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
        with os.fdopen(os.open(path, flags), "rb") as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "Proof descriptor is not a regular file: " + str(path))
            data = stream.read(maximum + 1)
        require(len(data) <= maximum, "Proof file byte budget exceeded")
        identity = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "kind": kind}
        if str(path) in self.items:
            require(self.items[str(path)] == identity, "Proof bytes or role changed during capture")
        else:
            self.items[str(path)] = identity
            self.totals[kind] += len(data)
        require(len(self.items) <= 1024 and self.totals[kind] <= total_maximum,
                "Aggregate proof budget exceeded")
        return data

    def responses(self, argv):
        argv = [x for x in argv if x not in ("-Xlinker", "-Xclang-linker")]
        for index, arg in enumerate(argv):
            if not arg.startswith("@") or runtime_path(arg, argv[index - 1] if index else None):
                continue
            content = self.read(arg[1:]).decode("utf-8")
            tokens = [x for x in shlex.split(content) if x not in ("-Xlinker", "-Xclang-linker")]
            require(len(tokens) <= 1000 and not any(x.startswith("@") and not runtime_path(x, tokens[i - 1] if i else None)
                    for i, x in enumerate(tokens)),
                    "Nested or oversized compiler/link response is unsupported")

    def finish(self):
        # Recheck every proof after all joins; callers also repeat around a fresh raw read.
        before = dict(self.items)
        for path, identity in before.items():
            self.read(path, identity["kind"])
        require(self.items == before, "Proof changed at capture completion")
        return dict(sorted(self.items.items()))


def file_list(files, path, root):
    result = []
    for line in files.read(path).decode("utf-8").splitlines():
        values = shlex.split(line)
        require(len(values) == 1, "Unsupported file-list row")
        result.append(str(canonical(values[0], root)))
        require(len(result) <= 256, "File-list count budget exceeded")
    require(result and len(set(result)) == len(result), "Empty or duplicate file-list inputs")
    return result


def live_owners(files, path, output, architecture):
    text = files.read(path).decode("utf-8")
    section, objects, live, headers = "", {}, set(), []
    for line in text.splitlines():
        if line.startswith("# Path: "):
            line = "# Path: " + physical_temporary_alias(line[len("# Path: "):])
        if line.startswith("# "):
            require(len(headers) < 128 and len(line.encode()) <= 1024, "Link-map header budget exceeded")
            headers.append(line)
            if re.fullmatch(r"#\s+Address\s+Size\s+(?:File\s+Name|Segment\s+Section)\s*", line):
                continue
            section = line
        elif section == "# Object files:" and line.strip():
            match = re.fullmatch(r"\[\s*(\d+)\]\s+(.+)", line)
            require(match is not None and match[1] not in objects and len(objects) < 256,
                    "Unparsed, duplicate or excessive link-map owner")
            objects[match[1]] = physical_temporary_alias(match[2])
        elif section in ("# Symbols:", "# Dead Stripped Symbols:") and line.strip():
            match = re.fullmatch(r"(?:0x[0-9A-Fa-f]+|<<dead>>)\s+0x[0-9A-Fa-f]+\s+\[\s*(\d+)\]\s+.+", line)
            require(match is not None and match[1] in objects, "Unparsed or unresolved link-map symbol owner")
            if section == "# Symbols:":
                live.add(match[1])
        elif line.strip() and section not in ("# Sections:",):
            raise EvidenceError("Unrecognized link-map section data")
    require(headers.count("# Path: " + output) == 1 and headers.count("# Arch: " + architecture) == 1
            and headers.count("# Object files:") == 1 and headers.count("# Symbols:") == 1,
            "Link-map output/architecture/section identity mismatch")
    return {objects[key] for key in live}


def link_list(argv):
    if "-filelist" in argv:
        return operand(argv, "-filelist"), "operand"
    lists = [x[1:] for x in argv if x.startswith("@/") and x.endswith(".LinkFileList")]
    require("-emit-library" in argv and len(lists) == 1, "Missing or ambiguous observed linker file list")
    return lists[0], "response"


def link(files, argv, architecture, required=()):
    files.responses(argv)
    path, mode = link_list(argv)
    result = {"argv": argv, "fileList": str(canonical(path, files.build)), "fileListMode": mode,
              "output": str(canonical(operand(argv, "-o"), files.build)), "linkMap": str(canonical(operand(argv, "-map"), files.build))}
    require(operand(argv, "-target").split("-", 1)[0] == architecture, "Link target architecture differs")
    inputs = file_list(files, result["fileList"], files.build)
    for value in set(required) - set(inputs):
        require("-r" not in argv and any(physical_temporary_alias(token) == value for token in argv),
                "Required package contribution is absent from actual linker operands")
        inputs.append(value)
    for path in inputs:
        files.read(path, "object")
    files.read(result["output"], "object")
    live = live_owners(files, result["linkMap"], result["output"], architecture)
    return result, set(inputs), live


def dynamic_product(files, argv, aggregate, architecture):
    observed, inputs, live = link(files, argv, architecture, required={aggregate["output"]})
    require(inputs == {aggregate["output"]} and aggregate["output"] in live and "-emit-library" in argv,
            "Dynamic package product lacks exact positive aggregate contribution")
    output = Path(observed["output"])
    bundles = [p for p in output.parents if p.name.endswith(".framework")]
    require(len(bundles) == 1 and bundles[0].is_relative_to(files.build / "Products") and bundles[0].resolve() == bundles[0],
            "Dynamic package product bundle is outside captured products")
    bundle = bundles[0]
    name = bundle.name.removesuffix(".framework")
    require(output in (bundle / name, bundle / "Versions/A" / name), "Unsupported dynamic package executable layout")
    info_paths = {p.resolve() for p in (bundle / "Info.plist", bundle / "Resources/Info.plist", bundle / "Versions/A/Resources/Info.plist") if p.is_file()}
    require(len(info_paths) == 1, "Missing or ambiguous dynamic package product metadata")
    info_path = info_paths.pop()
    require(info_path in (bundle / "Info.plist", bundle / "Versions/A/Resources/Info.plist"), "Dynamic product metadata leaves its bundle")
    info = plistlib.loads(files.read(str(info_path)))
    install = operand(argv, "-install_name")
    require(info.get("CFBundleExecutable") == name and info.get("CFBundlePackageType") == "FMWK"
            and install == "@rpath/" + output.relative_to(bundle.parent).as_posix(), "Dynamic product bundle/executable/install identity differs")
    return {"link": observed, "bundle": str(bundle), "infoPlist": str(info_path), "installName": install}


def record_paths(store, names):
    root = canonical(str(store / "v5/records"), store)
    require(root.is_dir(), "Missing current index record directory")
    found, pending, count = {}, [(root, 0)], 0
    while pending:
        directory, depth = pending.pop()
        require(depth <= 8, "Index record directory depth exceeded")
        with os.scandir(directory) as entries:
            for item in entries:
                count += 1
                require(count <= 50000, "Index record entry budget exceeded")
                path = canonical(item.path, root)
                if path.is_dir():
                    pending.append((path, depth + 1))
                else:
                    require(path.is_file(), "Nonregular index record entry")
                    if path.name in names:
                        require(path.name not in found, "Ambiguous index record basename")
                        found[path.name] = str(path)
    require(set(found) == names, "An admitted index record is absent")
    return found


def compiler_records(files, commands, sources, module, store, snapshot, source_root, architecture):
    """Bind a finite explicit Swift source set to actual compiler objects and current raw records."""
    compilations = {}
    for argv in commands:
        if "-output-file-map" not in argv or operand(argv, "-module-name") != module:
            continue
        files.responses(argv)
        output_map = str(canonical(operand(argv, "-output-file-map"), files.build))
        lists = [str(canonical(x[1:], files.build)) for x in argv if x.startswith("@") and x.endswith(".SwiftFileList")]
        require(len(lists) == 1 and set(file_list(files, lists[0], source_root)) == sources,
                "Compiler source list differs from finite package inventory")
        value = json.loads(files.read(output_map))
        require(isinstance(value, dict), "Compiler output map is not an object")
        pairs = [(physical_temporary_alias(k), v) for k, v in value.items()]
        require(len({k for k, _ in pairs}) == len(pairs), "Compiler output map has duplicate physical source identities")
        value = dict(pairs)
        require(set(value) - {""} == sources, "Compiler output map source set differs")
        target = operand(argv, "-target")
        require(target.split("-", 1)[0] == architecture and str(canonical(operand(argv, "-index-store-path"), store)) == str(store),
                "Compiler target or index store differs")
        for source in sorted(sources):
            output = value[source]
            require(isinstance(output, dict) and isinstance(output.get("index-unit-output-path"), str)
                    and output["index-unit-output-path"], "Missing actual compiler unit output identity")
            object_path = str(canonical(output.get("object"), files.build))
            files.read(object_path, "object")
            row = {"source": source, "argv": argv, "outputMap": output_map, "sourceFileList": lists[0],
                   "object": object_path, "unitOutputIdentity": output["index-unit-output-path"], "targetTriple": target}
            if source in compilations:
                previous = compilations[source]
                # Xcode logs three wrappers around an identical underlying compiler invocation.
                def normalized(args):
                    return args[2:] if len(args) > 2 and args[0].startswith("builtin-") and args[1] == "--" else args
                require({k: v for k, v in previous.items() if k != "argv"} == {k: v for k, v in row.items() if k != "argv"}
                        and normalized(previous["argv"]) == normalized(argv), "Conflicting package compiler observations")
            else:
                compilations[source] = row
    require(set(compilations) == sources, "Missing package compiler observations")
    require(len({row["object"] for row in compilations.values()}) == len(sources),
            "Shared whole-module object mappings are unsupported")
    observed = snapshot.get("snapshot", {}).get("sourceRecordAdmissions", [])
    admissions = [{**row, "path": physical_temporary_alias(row.get("path"))} for row in observed
                  if physical_temporary_alias(row.get("path")) in sources]
    require(0 < len(admissions) <= 256 and {r.get("path") for r in admissions} == sources,
            "Every package source needs a successful current record admission")
    names = {r.get("record") for r in admissions}
    require(all(isinstance(n, str) and Path(n).name == n and n not in ("", ".", "..") for n in names),
            "Invalid admitted record identity")
    paths, records = record_paths(store, names), []
    for row in admissions:
        comp = compilations[row["path"]]
        require(row.get("module") == module and row.get("unitOutputIdentity") == comp["unitOutputIdentity"]
                and row.get("unitTargetTriple") == comp["targetTriple"] and isinstance(row.get("unit"), str)
                and row["unit"], "Raw record source/module/unit-output/target join failed")
        path = paths[row["record"]]
        files.read(path, "record")
        record = {"source": row["path"], "unit": row["unit"], "record": row["record"],
                  "unitOutputIdentity": row["unitOutputIdentity"], "targetTriple": row["unitTargetTriple"], "path": path}
        if record not in records:
            records.append(record)
    require(len(admissions) == len(sources) and len(records) == len(sources) and len(names) == len(sources),
            "Package source record contexts are shared or ambiguous")
    return compilations, records


def assemble(spec, root, derived, store, log, snapshot, targets, settings, selected, architecture, native_outputs=None):
    """Join actual bytes and positive owners; this is never an absence classifier."""
    files, commands = Files(derived / "Build", store), command_rows(log)
    package_root = root / spec["path"]
    sources = {str(package_root / path) for path, value in spec["inventory"].items()
               if path.startswith("Sources/" + spec["module"] + "/") and value != "directory"}
    require(sources and spec["module"] not in {t["module"] for t in targets.values()},
            "Package and native compiler modules are ambiguous")
    compilations, records = compiler_records(files, commands, sources, spec["module"], store, snapshot, package_root, architecture)
    aggregate_candidates = [argv for argv in commands if "-r" in argv and "-filelist" in argv and "-map" in argv]
    wrapper_candidates = [argv for argv in commands if "-emit-library" in argv and "-map" in argv]
    # 여러 package의 relocatable link 중 이 package의 완전한 object 집합만 고른다.
    # 선택 전 읽기도 동일한 경로·바이트·토큰 경계를 적용하며 실행하지 않는다.
    objects = {r["object"] for r in compilations.values()}
    aggregate_lists = sorted({str(canonical(link_list(argv)[0], files.build)) for argv in aggregate_candidates + wrapper_candidates})
    # Every candidate participates in the same bounded IO/accounting, including nonselected wrappers.
    list_inputs = {path: set(file_list(files, path, files.build)) for path in aggregate_lists}
    def aggregate_matches(argv):
        return set(file_list(files, operand(argv, "-filelist"), files.build)) == objects
    aggregate_candidates = [argv for argv in aggregate_candidates if aggregate_matches(argv)]
    require(len(aggregate_candidates) == 1, "Ambiguous or absent package relocatable link")
    aggregate, inputs, live = link(files, aggregate_candidates[0], architecture)
    require(inputs == objects and objects <= live, "Package objects lack complete positive aggregate contribution")
    require(operand(aggregate["argv"], "-target") in {c["targetTriple"] for c in compilations.values()}
            and len({c["targetTriple"] for c in compilations.values()}) == 1, "Aggregate target triple differs")
    wrappers = [argv for argv in wrapper_candidates if list_inputs[str(canonical(link_list(argv)[0], files.build))] == {aggregate["output"]}]
    require(len(wrappers) <= 1, "Ambiguous dynamic package product wrapper")
    wrapper = dynamic_product(files, wrappers[0], aggregate, architecture) if wrappers else None
    closure, pending = set(), list(selected)
    while pending:
        ident = pending.pop()
        if ident not in closure:
            require(ident in targets, "Unknown selected native target")
            closure.add(ident)
            pending.extend(targets[ident]["dependencies"])
    require(set(spec["consumers"]) & closure, "No positively linked package consumer belongs to the selected universe")
    links = []
    for ident in spec["consumers"]:
        rows = [s["buildSettings"] for s in settings if s.get("target") == targets[ident]["name"]]
        require(len(rows) == 1, "Ambiguous package consumer settings")
        executable = str(canonical((native_outputs or {}).get(ident, str(Path(rows[0]["TARGET_BUILD_DIR"]) / rows[0]["EXECUTABLE_PATH"])), files.build))
        argv_rows = [a for a in commands if "-map" in a and "-o" in a and str(canonical(operand(a, "-o"), files.build)) == executable]
        require(len(argv_rows) == 1, "Absent or ambiguous actual native package consumer link")
        required = wrapper["link"]["output"] if wrapper else aggregate["output"]
        native, inputs, live = link(files, argv_rows[0], architecture, required={required})
        require(required in inputs and required in live,
                "Package aggregate has no positive selected native link contribution")
        links.append({"targetID": ident, "link": native, "packageInput": required})
    result = {**spec, "indexStore": str(store), "files": files.finish(), "aggregateCandidateFileLists": aggregate_lists,
            "compilations": [compilations[s] for s in sorted(compilations)],
            "records": sorted(records, key=lambda r: (r["source"], r["unit"], r["record"])),
            "aggregate": aggregate, "links": links}
    if wrapper:
        result["dynamicProduct"] = wrapper
    return result
