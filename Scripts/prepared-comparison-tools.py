#!/usr/bin/env python3
"""Same-run prepared executables; never an index transfer or a passed comparison."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
BASELINE = "54b1b41c06efe42ac20704c1ea373d4b6c3a444b"
COMPARATOR = "64aa0b26913249c4e7c21d351a215fba02702003"
ROLES = ("candidate", "comparator", "baseline")
MAX_MANIFEST = 8 * 1024 * 1024
MAX_FILE = 256 * 1024 * 1024
_BASE = None
# SDK discovery의 유한 override 목록과 같은 입력/driver 경계. DEVELOPER_DIR은 아래에서
# 선택된 Xcode와의 동일성을 확인한다. 환경 값은 로그/manifest로 복사하지 않는다.
COMPILER_OVERRIDES = {"CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH",
                      "OBJCPLUS_INCLUDE_PATH", "SDKROOT", "TOOLCHAINS", "SWIFT_EXEC", "CCC_OVERRIDE_OPTIONS",
                      "CLANG_MODULE_CACHE_PATH", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC", "SWIFT_DRIVER_CLANG_EXEC",
                      "LD_PRELOAD", "CC", "CXX"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def read_json(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_MANIFEST,
            "Missing, linked or oversized manifest")
    return json.loads(path.read_bytes())


def save(path, value):
    data = (json.dumps(value, sort_keys=True, ensure_ascii=True, allow_nan=False, indent=2) + "\n").encode()
    require(len(data) <= MAX_MANIFEST, "Manifest output budget exceeded")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as out:
        out.write(data)


def capture(argv, cwd=None):
    if os.name == "posix":
        # 실제 macOS admission은 기존 유한 pipe/소유 process-group supervisor를 쓴다.
        with tempfile.TemporaryDirectory(prefix="prepared-identity-") as directory:
            row = base_module()._run_stream_capped(list(argv), Path(cwd or os.getcwd()),
                                                   Path(directory) / "identity", 60, 8 * 1024 * 1024)
            require(row.get("returncode") == 0 and not row.get("timed_out") and not row.get("output_limit_exceeded")
                    and row.get("owned_root_reaped") is True and not row.get("ownership_lost")
                    and not row.get("cleanup_errors"), "Identity command did not finish within bounds")
            require(Path(row["stderr"]).stat().st_size <= 1024 * 1024, "Identity stderr output budget exceeded")
            return Path(row["stdout"]).read_bytes().decode("utf-8").strip()
    # Windows에서는 Git byte-identity의 portable fixture만 실행한다. native prepare/admit은 거부한다.
    result = subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=True)
    require(len(result.stdout) <= 8 * 1024 * 1024 and len(result.stderr) <= 1024 * 1024,
            "Identity command output budget exceeded")
    return result.stdout.decode("utf-8").strip()


def git(root, *args):
    return capture(["git", *args], root)


def base_module():
    global _BASE
    if _BASE is not None:
        return _BASE
    spec = importlib.util.spec_from_file_location("prepared_base", ROOT / "Scripts/benchmark-indexstore-cli.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _BASE = module
    return module


def phase_progress(base, evidence):
    """Keep original command limits/receipts and expose bounded phase failures."""
    original = base.run
    spec = importlib.util.spec_from_file_location("prepared_failure", ROOT / "Scripts/observe-xcode-local-package.py")
    observer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(observer)
    receipts = []

    def measured(command, cwd, stem, *args, **kwargs):
        require(Path(stem).resolve().is_relative_to(evidence.resolve()), "Process evidence escapes owned directory")
        label = Path(stem).name
        require(re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", label), "Invalid preparation phase")
        print("PREPARED_PHASE " + json.dumps({"phase": label, "status": "started"}), flush=True)
        try:
            receipt = original(command, cwd, stem, *args, **kwargs)
        except BaseException:
            observer.record_process_failure(Path(stem))
            raise
        print("PREPARED_PHASE " + json.dumps({"phase": label, "status": "completed",
              "returncode": receipt["returncode"], "wall_seconds": receipt["wall_seconds"]}, allow_nan=False), flush=True)
        receipts.append(receipt)
        return receipt

    base.run = measured
    return receipts


def source_links(root, tracked, links):
    """A tracked source link is identity, not permission to read arbitrary files."""
    result, active = {}, set()

    def resolve(name):
        parts, components, seen = name.split("/"), [], set()
        while parts:
            part = parts.pop(0)
            if part in ("", "."):
                continue
            if part == "..":
                require(components, "Source link escapes checkout")
                components.pop()
                continue
            candidate = root.joinpath(*components, part)
            relative = "/".join([*components, part])
            if candidate.is_symlink():
                require(relative in links, "Untracked source link in referent path")
                require(relative not in seen and len(seen) < 64, "Cyclic or excessive source link chain")
                seen.add(relative)
                target = links[relative]
                require(os.readlink(candidate) == target, "Source link changed during inventory")
                require(not Path(target).is_absolute() and "\\" not in target and ":" not in target,
                        "Absolute or unsupported source link")
                parts = target.split("/") + parts
            else:
                require(candidate.exists(), "Dangling source link")
                components.append(part)
        return root.joinpath(*components)

    def visit(name):
        require(name not in active, "Cyclic tracked source link")
        if name in result:
            return result[name]
        active.add(name)
        target = links[name]
        require(not Path(target).is_absolute() and "\\" not in target and ":" not in target,
                "Absolute or unsupported source link")
        resolved = resolve(name)
        require(resolved.is_relative_to(root.resolve()), "Source link escapes checkout")
        relative = resolved.relative_to(root.resolve()).as_posix()
        if resolved.is_dir():
            referents = {path for path in tracked if path.startswith(relative + "/")}
            require(referents, "Source directory link has no tracked referents")
            permitted_directories = {str(parent).replace("\\", "/") for path in referents
                                     for parent in Path(path).parents}
            observed, count = set(), 0
            for directory, directories, files in os.walk(resolved, followlinks=False):
                for child in [*directories, *files]:
                    count += 1
                    require(count <= 20000, "Source link directory budget exceeded")
                    path = Path(directory) / child
                    entry = path.relative_to(root.resolve()).as_posix()
                    if path.is_symlink() or not path.is_dir():
                        require(entry in tracked, "Untracked or ignored source link referent")
                        observed.add(entry)
                    else:
                        require(entry in permitted_directories, "Untracked source link directory")
            require(observed == referents, "Source link referent inventory differs")
            for entry in sorted(referents):
                if entry in links:
                    visit(entry)
        else:
            require(relative in tracked and tracked[relative][0] in ("100644", "100755"),
                    "Source link does not resolve to tracked regular input")
            referents = {relative}
        result[name] = {"target_encoding": "slash-components-v1", "target_components": target.split("/"),
                        "target_sha256": hashlib.sha256(os.fsencode(target)).hexdigest(),
                        "resolved": relative, "referent_inputs": sorted(referents)}
        active.remove(name)
        return result[name]

    for name in sorted(links):
        visit(name)
    return result


def checked_relative(value):
    require(type(value) is str and value and len(value) <= 1024 and "\\" not in value,
            "Invalid artifact relative path")
    path = Path(value)
    require(not path.is_absolute() and ":" not in value and path.as_posix() == value
            and all(part not in ("", ".", "..") for part in value.split("/")), "Escaping artifact path")
    return path


def regular(root, relative):
    path = root / checked_relative(relative)
    require(path.resolve().is_relative_to(root.resolve()) and not path.is_symlink()
            and stat.S_ISREG(path.stat().st_mode) and path.stat().st_size <= MAX_FILE,
            "Artifact file is missing, linked, escaping or oversized")
    current = path.parent
    while current != root:
        require(not current.is_symlink(), "Linked artifact directory")
        current = current.parent
    return path


def source_identity(root, expected, *, extra_lock=None):
    require(re.fullmatch(r"[a-f0-9]{40}", expected or "") is not None, "Exact source commit required")
    require(git(root, "rev-parse", "HEAD") == expected, "Source commit differs")
    status = git(root, "status", "--porcelain", "--untracked-files=all")
    allowed = "?? Package.resolved" if extra_lock else ""
    require(status in ("", allowed), "Clean source checkout required")
    untracked = git(root, "ls-files", "--others", "-z", "--", ":(top,glob)Package*.swift", "Sources", "Tests", "Plugins")
    require(not untracked, "Untracked or ignored build inputs")
    entries = [row for row in git(root, "ls-files", "-s", "-z").split("\0") if row]
    tracked = {}
    for row in entries:
        header, name = row.split("\t", 1)
        mode, blob, stage = header.split()
        require(mode in ("100644", "100755", "120000") and stage == "0", "Unsupported source mode or conflict")
        tracked[name] = (mode, blob)
    names = list(tracked)
    if extra_lock and "Package.resolved" not in names:
        names.append("Package.resolved")
    require(len(names) <= 20000 and len(names) == len(set(names)), "Source inventory budget or duplicate")
    files, links, size = {}, {}, 0
    for name in sorted(names):
        if name in tracked and tracked[name][0] == "120000":
            path = root / checked_relative(name)
            require(path.is_symlink() and path.parent.resolve().is_relative_to(root.resolve()), "Tracked source link missing")
            target = os.readlink(path)
            data = os.fsencode(target)
            require(0 < len(data) <= 4096, "Source link text budget exceeded")
            require(hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() == tracked[name][1],
                    "Source link text differs from committed Git object")
            links[name] = target
            size += len(data)
            continue
        path = regular(root, name)
        if os.name == "posix" and name in tracked:
            require(bool(path.stat().st_mode & 0o111) == (tracked[name][0] == "100755"),
                    "Source executable mode differs from committed Git object")
        size += path.stat().st_size
        require(size <= 512 * 1024 * 1024, "Source byte inventory budget exceeded")
        files[name] = digest(path)
        if name in tracked:
            blob = hashlib.sha1(b"blob " + str(path.stat().st_size).encode() + b"\0")
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    blob.update(chunk)
            require(blob.hexdigest() == tracked[name][1], "Source bytes differ from committed Git object")
    if extra_lock:
        require(files.get("Package.resolved") == extra_lock, "Frozen comparator lock differs")
    return {"revision": expected, "tree": git(root, "rev-parse", "HEAD^{tree}"),
            "working_tree_status": "", "input_sha256": files,
            "symlinks": source_links(root, tracked, links), "extra_frozen_lock": extra_lock, "bytes": size}


def verify_source_link_shape(source):
    """링크 원문 바이트를 복원하면서 공개 정규화가 절대 경로 조각으로 오인하지 않게 한다."""
    require(type(source) is dict and type(source.get("input_sha256")) is dict, "Invalid source link input identity")
    links = source.get("symlinks", {})
    require(type(links) is dict and len(links) <= 20000, "Invalid source link inventory")
    fields = {"target_encoding", "target_components", "target_sha256", "resolved", "referent_inputs"}
    for name, row in links.items():
        checked_relative(name)
        require(type(row) is dict and set(row) == fields and row["target_encoding"] == "slash-components-v1",
                "Incompatible source link target encoding")
        parts = row["target_components"]
        require(type(parts) is list and 1 <= len(parts) <= 4096
                and all(type(part) is str and not any(char in part for char in ("/", "\\", ":", "\0")) for part in parts),
                "Invalid source link target components")
        target = "/".join(parts)
        require(parts[0] != "" and 0 < len(os.fsencode(target)) <= 4096,
                "Absolute or oversized source link target")
        require(row["target_sha256"] == hashlib.sha256(os.fsencode(target)).hexdigest(),
                "Source link target bytes differ")
        # ..의 의미는 중간 symlink를 확장한 뒤에만 알 수 있다. 경계 판정은
        # 생산자/소비자의 실제 source_links 재검증에 맡기고 여기서는 인코딩만 확인한다.
        checked_relative(row["resolved"])
        referents = row["referent_inputs"]
        require(type(referents) is list and 1 <= len(referents) <= 20000
                and all(type(item) is str for item in referents)
                and referents == sorted(set(referents)), "Invalid source link referent inventory")
        for referent in referents:
            checked_relative(referent)
            require(referent in source["input_sha256"] or referent in links,
                    "Source link referent lacks tracked identity")


def verify_source_links(root, source):
    """Recheck link identity without treating link text as regular file bytes."""
    verify_source_link_shape(source)
    links = source.get("symlinks", {})
    tracked = {name: ("100644", None) for name in source["input_sha256"]}
    for name in source["input_sha256"]:
        regular(root, name)
    observed = {}
    for name in links:
        path = root / checked_relative(name)
        require(path.is_symlink(), "Admitted source link missing")
        observed[name] = os.readlink(path)
        tracked[name] = ("120000", None)
    require(source_links(root, tracked, observed) == links, "Admitted source link identity changed")


def binding(checkout):
    expected = os.environ.get("GITHUB_SHA", "")
    require(git(checkout, "rev-parse", "HEAD") == expected, "Actual Actions checkout differs")
    value = {"run": os.environ.get("GITHUB_RUN_ID"), "attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
             "checkout_commit": expected, "checkout_tree": git(checkout, "rev-parse", "HEAD^{tree}"),
             "pr_head": os.environ.get("CARTOGRAPH_CI_PR_HEAD"),
             "pr_base": os.environ.get("CARTOGRAPH_CI_PR_BASE") or None}
    verify_checkout_binding(checkout, value, checkout_observed=True)
    return value


def verify_checkout_binding(checkout, value, *, checkout_observed=False):
    # 격리 child의 run 값은 sealed-plan의 과거 attestation이다. 현재 Git 신원은 다시 읽는다.
    if not checkout_observed:
        require(git(checkout, "rev-parse", "HEAD") == value.get("checkout_commit")
                and git(checkout, "rev-parse", "HEAD^{tree}") == value.get("checkout_tree"),
                "Actual checkout differs from retained Actions binding")
    require(all(type(value[key]) is str and value[key].isdigit() for key in ("run", "attempt")),
            "Current Actions run/attempt required")
    for key in ("checkout_commit", "checkout_tree", "pr_head"):
        require(re.fullmatch(r"[a-f0-9]{40}", value[key] or "") is not None, "Incomplete Actions source binding")
    if value["pr_base"]:
        require(re.fullmatch(r"[a-f0-9]{40}", value["pr_base"]) is not None, "Invalid PR base")
        # depth-1 checkout의 log 부모 목록은 잘릴 수 있으므로 실제 commit object를 읽는다.
        parents = [line.split()[1] for line in git(checkout, "cat-file", "-p", "HEAD").split("\n\n", 1)[0].splitlines()
                   if line.startswith("parent ")]
        require(value["pr_head"] in parents and value["pr_base"] in parents, "Checkout is not the expected PR merge")
    else:
        require(value["pr_head"] == value["checkout_commit"], "Push source identity differs")


def toolchain_identity():
    require(platform.system() == "Darwin", "Prepared comparison requires macOS")
    require(not any(key.startswith("DYLD_") or key in COMPILER_OVERRIDES
                    for key in os.environ), "Compiler/runtime environment override is unsupported")
    developer = Path(capture(["xcode-select", "-p"])).resolve()
    if os.environ.get("DEVELOPER_DIR"):
        require(Path(os.environ["DEVELOPER_DIR"]).resolve() == developer, "Developer selection override differs")
    swiftc = Path(capture(["xcrun", "--find", "swiftc"]))
    paths = {name: swiftc.parent / name for name in ("swift", "swiftc", "swift-frontend")}
    paths.update({name: Path(capture(["xcrun", "--find", name])) for name in ("clang", "ld", "otool", "lipo")})
    library = developer / "Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
    paths["libIndexStore"] = library
    require(all(path.resolve().is_relative_to(developer) and path.is_file() for path in paths.values()),
            "Toolchain tools must belong to selected Xcode")
    sdk = Path(capture(["xcrun", "--sdk", "macosx", "--show-sdk-path"])).resolve()
    settings = {name: digest(sdk / name) for name in ("SDKSettings.json", "SDKSettings.plist") if (sdk / name).is_file()}
    require(settings, "SDK metadata absent")
    semantic = {"architecture": platform.machine(), "os_build": capture(["sw_vers", "-buildVersion"]),
                "swift_version": capture([str(paths["swiftc"]), "--version"]),
                "tools_sha256": {name: digest(path) for name, path in paths.items()},
                "sdk_version": capture(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
                "sdk_build": capture(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
                "sdk_settings_sha256": settings,
                "scope": "Named tool bytes, SDK metadata and OS build; not a whole-SDK byte seal"}
    return {"identity": semantic, "paths": {name: str(path) for name, path in paths.items()},
            "developer": str(developer), "sdk": str(sdk)}


MACHO_DEPENDENCY = re.compile(r"\s+(.+) \(compatibility version [^,]+, current version [^)]+\)")
MACHO_DIAGNOSTIC_LIMIT = 32 * 1024
MACHO_DYLIB_COMMANDS = {"LC_ID_DYLIB", "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
                        "LC_LAZY_LOAD_DYLIB", "LC_LOAD_UPWARD_DYLIB"}
MACHO_VERSION = r"(?:n/a|[0-9]+\.[0-9]+\.[0-9]+)"


class MachOParseError(ValueError):
    def __init__(self, message, line=None):
        super().__init__(message)
        self.line = line


def macho_require(condition, message, line=None):
    if not condition:
        raise MachOParseError(message, line)


def macho_lines(text, path, architecture):
    # 단일 명시 slice의 실제 입력 이름만 허용한다. 다른 fat header를 건너뛰지 않는다.
    macho_require(len(text.encode("utf-8")) <= 8 * 1024 * 1024, "Mach-O text budget exceeded")
    lines = text.split("\n")
    for line in lines:
        macho_require(all(ord(char) >= 32 or char == "\t" for char in line),
                      "Control character in Mach-O output", line)
    macho_require(lines[0] in (str(path) + ":", f"{path} (architecture {architecture}):"),
                  "Unexpected selected Mach-O header", lines[0])
    return lines[1:]


def parse_macho_dependencies(text, path, architecture):
    dependencies = []
    for line in macho_lines(text, path, architecture):
        match = MACHO_DEPENDENCY.fullmatch(line)
        macho_require(match is not None, "Unparsed Mach-O dependency", line)
        dependencies.append(match[1])
    macho_require(len(dependencies) <= 128, "Mach-O dependency budget exceeded")
    return dependencies


def parse_macho_commands(text, path, architecture):
    commands = macho_lines(text, path, architecture)
    blocks = []
    for line in commands:
        match = re.fullmatch(r"Load command (\d+)", line)
        if match:
            macho_require(int(match[1]) == len(blocks), "Unexpected load command sequence", line)
            blocks.append([])
        else:
            command = blocks[-1][0].strip().removeprefix("cmd ") if blocks and blocks[-1] else None
            # 이 두 필드는 Apple/LLVM이 들여쓰기 없이 출력한다. 명령과 위치까지 고정한다.
            compatibility = (command in MACHO_DYLIB_COMMANDS and len(blocks[-1]) == 5
                             and re.fullmatch("compatibility version " + MACHO_VERSION, line))
            note_owner = (command == "LC_NOTE" and len(blocks[-1]) == 2 and line.startswith("data_owner ")
                          and len(line[len("data_owner "):].encode("utf-8")) <= 16)
            macho_require(blocks and (line.startswith((" ", "\t")) or line == "Section"
                                     or compatibility or note_owner),
                          "Unparsed Mach-O load command line", line)
            blocks[-1].append(line)
    macho_require(blocks, "Missing Mach-O load commands")
    rpaths, install_id = [], None
    for block in blocks:
        macho_require(len(block) >= 2 and re.fullmatch(r"\s+cmd (?:LC_[A-Z0-9_]+|0x[0-9a-fA-F]+)", block[0])
                      and re.fullmatch(r"\s+cmdsize [1-9][0-9]*", block[1]),
                      "Truncated or unparsed Mach-O load command", block[-1] if block else None)
        if block[0].strip() == "cmd LC_RPATH":
            macho_require(len(block) == 3, "Truncated or unparsed LC_RPATH", block[-1])
            match = re.fullmatch(r"\s+path (.+) \(offset \d+\)", block[2])
            macho_require(match is not None, "Unparsed LC_RPATH", block[2])
            rpaths.append(match[1])
        elif block[0].strip().removeprefix("cmd ") in MACHO_DYLIB_COMMANDS:
            macho_require(len(block) == 6, "Truncated or unparsed Mach-O dylib command", block[-1])
            match = re.fullmatch(r"\s+name (.+) \(offset \d+\)", block[2])
            macho_require(match is not None, "Unparsed dylib name", block[2])
            timestamp = re.fullmatch(r"\s+time stamp [0-9]+ (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) "
                                     r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [ 0-9][0-9] "
                                     r"[0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}", block[3])
            options = re.fullmatch(r"\s+options (?:weak )?(?:re-export )?(?:upward )?(?:delay-init )?", block[3])
            macho_require(timestamp or options, "Unparsed dylib timestamp or use options", block[3])
            macho_require(re.fullmatch(r"\s+current version " + MACHO_VERSION, block[4]),
                          "Unparsed dylib current version", block[4])
            macho_require(re.fullmatch("compatibility version " + MACHO_VERSION, block[5]),
                          "Unparsed dylib compatibility version", block[5])
            if block[0].strip() == "cmd LC_ID_DYLIB":
                macho_require(install_id is None, "Duplicate dylib identity", block[2])
                install_id = match[1]
        elif block[0].strip() == "cmd LC_NOTE":
            macho_require(len(block) == 5 and block[2].startswith("data_owner ")
                          and len(block[2][len("data_owner "):].encode("utf-8")) <= 16,
                          "Truncated or unparsed LC_NOTE", block[-1])
            for line, field in zip(block[3:], ("offset", "size")):
                macho_require(re.fullmatch(r"\s+" + field + r" [0-9]+", line), "Unparsed LC_NOTE " + field, line)
    macho_require(len(blocks) <= 1024 and len(rpaths) <= 64, "Mach-O load command budget exceeded")
    return rpaths, install_id


def observed_text(text, limit=512):
    data = text.encode("utf-8", errors="replace")
    return {"prefix": data[:limit].decode("utf-8", errors="replace"), "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(), "truncated": len(data) > limit}


def otool_version(tools):
    # Apple classic은 --version을 stderr에 쓴다. 진단만 추가하며 실패를 admission으로 바꾸지 않는다.
    with tempfile.TemporaryDirectory(prefix="prepared-otool-version-") as directory:
        row = base_module()._run_stream_capped([tools["paths"]["otool"], "--version"], Path.cwd(),
                                               Path(directory) / "version", 10, 32768)
        require(row.get("returncode") == 0 and not row.get("timed_out") and not row.get("output_limit_exceeded")
                and row.get("owned_root_reaped") is True and not row.get("ownership_lost")
                and not row.get("cleanup_errors"), "otool version unavailable within diagnostic bounds")
        value = {}
        for stream in ("stdout", "stderr"):
            with Path(row[stream]).open("rb") as source:
                body = source.read(32769)
            require(len(body) <= 32768, "otool version output budget exceeded")
            value[stream] = observed_text(body.decode("utf-8", errors="replace"))
        return value


def emit_macho_observation(path, tools, option, text, error=None):
    # 출력 실패가 원래 제품 거부를 덮지 않도록 독립적으로 닫는다. 전체 행도 byte cap을 포함한다.
    try:
        try:
            version = {"status": "observed", **otool_version(tools)}
        except Exception as version_error:
            version = {"status": "unavailable", "error_type": type(version_error).__name__}
        lines = text.splitlines()
        headers = []
        for observed in lines:
            if observed and not observed[0].isspace():
                headers.append(observed_text(observed, 256))
                if len(headers) == 4:
                    break
        offending = getattr(error, "line", None)
        if error is None:
            offending = next((line for line in lines[1:] if MACHO_DEPENDENCY.fullmatch(line) is None), None)
        row = {"scope": "parser-diagnostic-only-not-runtime-admission", "option": option,
               "path": observed_text(str(path)), "architecture": observed_text(tools["identity"]["architecture"], 32),
               "otool_sha256": tools["identity"].get("tools_sha256", {}).get("otool"), "otool_version": version,
               "output": {"bytes": len(text.encode("utf-8")), "sha256": hashlib.sha256(text.encode()).hexdigest()},
               "headers": headers, "first_unparsed_line": observed_text(offending) if offending is not None else None,
               "error_type": type(error).__name__ if error else None,
               "reason": observed_text(str(error)) if error else None}
        line = "PREPARED_MACHO " + json.dumps(row, sort_keys=True, ensure_ascii=True, allow_nan=False) + "\n"
        require(len(line.encode("ascii")) <= MACHO_DIAGNOSTIC_LIMIT, "Mach-O diagnostic budget exceeded")
        print(line, end="", flush=True)
    except Exception:
        # 진단만 거부되었음을 고정 문자열로 남기고 호출자의 원래 오류는 그대로 재전파한다.
        try:
            print('PREPARED_MACHO {"status":"diagnostic-refused"}', flush=True)
        except Exception:
            pass


def macho_loads(path, tools):
    architecture = tools["identity"]["architecture"]
    require(architecture in ("arm64", "x86_64"), "Unsupported selected Mach-O architecture")
    text, option = "", "-L"
    try:
        text = capture([tools["paths"]["otool"], "-arch", architecture, option, str(path)])
        dependencies = parse_macho_dependencies(text, path, architecture)
        option = "-l"
        text = ""
        text = capture([tools["paths"]["otool"], "-arch", architecture, option, str(path)])
        rpaths, install_id = parse_macho_commands(text, path, architecture)
    except Exception as error:
        emit_macho_observation(path, tools, option, text, error)
        raise
    return [name for name in dependencies if name != install_id], rpaths


def preflight_macho(tools):
    path = Path(tools["paths"]["libIndexStore"])
    try:
        default = capture([tools["paths"]["otool"], "-L", str(path)])
        emit_macho_observation(path, tools, "default-L", default)
    except Exception as error:
        emit_macho_observation(path, tools, "default-L", "", error)
    # 기본 호출 관측은 성공 증거가 아니다. 명시 slice 파싱이 실패하면 빌드 전에 멈춘다.
    macho_loads(path, tools)


def runtime_closure(binary, tools):
    """Resolve recursive linked libraries; dlopen libIndexStore is also an explicit root."""
    binary = Path(binary)
    local, developer = binary.parent.resolve(), Path(tools["developer"]).resolve()
    require(capture([tools["paths"]["lipo"], "-archs", str(binary)]).split() == [tools["identity"]["architecture"]],
            "Executable architecture differs or is ambiguous")
    _, executable_rpaths = macho_loads(binary, tools)
    pending = [(binary, "artifact:bin/tool"), (Path(tools["paths"]["libIndexStore"]), "developer:" +
                str(Path(tools["paths"]["libIndexStore"]).resolve().relative_to(developer)))]
    nodes, copies = {}, {"bin/tool": binary}

    def expand(value, loader):
        return value.replace("@loader_path", str(loader.parent)).replace("@executable_path", str(local))

    while pending:
        path, key = pending.pop()
        if key in nodes:
            continue
        require(len(nodes) < 256, "Runtime closure budget exceeded")
        require(tools["identity"]["architecture"] in capture([tools["paths"]["lipo"], "-archs", str(path)]).split(),
                "Runtime library architecture differs")
        dependencies, rpaths = macho_loads(path, tools)
        rows = []
        for name in dependencies:
            if name.startswith(("/usr/lib/", "/System/Library/Frameworks/")):
                require(".." not in name.split("/"), "Escaping system dependency")
                rows.append({"install_name": name, "resolved": "system:" + name,
                             "identity": "OS build/architecture; dyld-cache file bytes not claimed"})
                continue
            search = [expand(root, path) for root in rpaths] + [expand(root, binary) for root in executable_rpaths]
            candidates = ([root + "/" + name[len("@rpath/"):] for root in search]
                          if name.startswith("@rpath/") else [expand(name, path)])
            candidates = [Path(item) for item in candidates if not item.startswith("@") and Path(item).is_file()]
            unique = {str(item.resolve()): item for item in candidates}
            require(len(unique) == 1, "Missing or ambiguous runtime library")
            resolved, lexical = next(iter(unique.items()))
            resolved = Path(resolved)
            if resolved.is_relative_to(local):
                relative = "bin/" + lexical.relative_to(local).as_posix()
                checked_relative(relative)
                target = "artifact:" + relative
                copies[relative] = lexical
            elif resolved.is_relative_to(developer):
                target = "developer:" + resolved.relative_to(developer).as_posix()
            else:
                raise ValueError("Runtime library escapes artifact and selected Xcode")
            # 외부 절대 scratch 경로를 설치 이름으로 남긴 바이너리는 재배치하지 않는다.
            require(not name.startswith("/") or resolved.is_relative_to(developer), "Producer-absolute runtime library")
            rows.append({"install_name": name, "resolved": target})
            pending.append((lexical, target))
        nodes[key] = {"sha256": digest(path), "dependencies": rows}
    return {"nodes": nodes, "os_build": tools["identity"]["os_build"],
            "architecture": tools["identity"]["architecture"]}, copies


def dependency_identity(package, scratch):
    lock = read_json(package / "Package.resolved")
    pins = lock.get("pins", lock.get("object", {}).get("pins", []))
    require(type(pins) is list and len(pins) <= 32, "Dependency pin budget exceeded")
    checkouts = scratch / "checkouts"
    result = {}
    for pin in pins:
        identity = pin.get("identity", pin.get("package", "").lower())
        revision = pin.get("state", {}).get("revision")
        require(identity and identity not in result, "Duplicate dependency pin")
        candidates = [path for path in checkouts.iterdir() if path.is_dir() and git(path, "rev-parse", "HEAD") == revision]
        require(len(candidates) == 1, "Resolved dependency checkout is missing or ambiguous")
        result[identity] = source_identity(candidates[0], revision)
    return result


def verify_preparation(value):
    role = value.get("role")
    require(role in ROLES and value.get("source_verified_before_after") is True
            and value.get("dependencies_verified_before_after") is True, "Pre/post build identities absent")
    require(value.get("limits") == {"jobs": 3, "setup_timeout_seconds": 600 if role == "baseline" else 1500},
            "Frozen build limits differ")
    original = value.get("build_evidence", {})
    if role == "comparator":
        builds = [row for row in original.get("commands", [])
                  if "build" in row.get("command", []) and "--product" in row.get("command", [])]
        require(len(builds) == 1 and original.get("revision") == COMPARATOR, "Exact comparator build receipt required")
        build, product = builds[0], "index-dump"
    else:
        setup = original.get("setup", {})
        require(setup.get("mode") == "fresh-release-package-build" and setup.get("build_cost_measured") is True,
                "Actual producer release build required")
        build, product = setup.get("build", {}), "cartograph"
    require(type(build.get("returncode")) is int and build["returncode"] == 0 and build.get("timed_out") is False,
            "Failed or incomplete producer build")
    argv = build.get("command")
    require(type(argv) is list and all(type(item) is str for item in argv), "Invalid build argv")
    for flag, expected in (("-c", "release"), ("--product", product), ("-j", "3")):
        require(argv.count(flag) == 1 and argv.index(flag) + 1 < len(argv)
                and argv[argv.index(flag) + 1] == expected, "Producer build mode differs")
    require(argv.count("--force-resolved-versions") == 1, "Pinned dependency build required")
    require(type(build.get("wall_seconds")) in (int, float) and math.isfinite(build["wall_seconds"])
            and build["wall_seconds"] > 0, "Measured producer build cost absent")
    require(type(value.get("dependencies")) is dict and len(value["dependencies"]) <= 32,
            "Dependency identity absent")
    verify_source_link_shape(value.get("source"))
    for dep in value["dependencies"].values():
        require(type(dep) is dict and re.fullmatch(r"[a-f0-9]{40}", dep.get("revision", ""))
                and re.fullmatch(r"[a-f0-9]{40}", dep.get("tree", ""))
                and dep.get("working_tree_status") == "" and type(dep.get("input_sha256")) is dict,
                "Invalid dependency source identity")
        verify_source_link_shape(dep)


def verify_dependency_pins(package, manifest):
    lock = read_json(package / "Package.resolved")
    pins = lock.get("pins", lock.get("object", {}).get("pins", []))
    expected = {pin.get("identity", pin.get("package", "").lower()): pin.get("state", {}).get("revision") for pin in pins}
    require(len(expected) == len(pins) and expected == {name: row["revision"] for name, row in manifest["dependencies"].items()},
            "Dependency manifests differ from actual frozen lock")


def acquire(base, revision, destination, evidence, timeout=60):
    destination.mkdir()
    for label, command in (("init", ["git", "init", "-q"]),
                           ("remote", ["git", "remote", "add", "origin", base]),
                           ("fetch", ["git", "fetch", "--depth", "1", "origin", revision]),
                           ("checkout", ["git", "checkout", "--detach", "FETCH_HEAD"])):
        base_module().run(command, destination, evidence / label, timeout)


def prepare(args):
    started = time.monotonic()
    base = base_module()
    checkout, out, evidence = args.checkout.resolve(), args.output.resolve(), args.evidence.resolve()
    require(not out.exists() and not evidence.exists(), "Preparation output must be new")
    out.mkdir(parents=True)
    evidence.mkdir(parents=True)
    preparation_receipts = phase_progress(base, evidence)
    action = binding(checkout)
    tools = toolchain_identity()
    require(args.setup_timeout == (600 if args.role == "baseline" else 1500) and args.jobs == 3,
            "Frozen preparation budget/jobs differ")
    preflight_macho(tools)
    package = checkout
    revision = action["checkout_commit"]
    extra_lock = None
    if args.role != "candidate":
        revision = COMPARATOR if args.role == "comparator" else BASELINE
        package = evidence / "source"
        acquire(base.UPSTREAM if args.role == "comparator" else "https://github.com/ictechgy/cartograph.git",
                revision, package, evidence / "acquisition")
    if args.role == "comparator":
        lock = checkout / "Fixtures/IndexStoreCLIBenchmark/indexstore-Package.resolved"
        extra_lock = digest(lock)
        shutil.copyfile(lock, package / "Package.resolved")
    before = source_identity(package, revision, extra_lock=extra_lock)
    scratch = package / ".build" if args.role == "comparator" else evidence / "build/cartograph-release-build"
    base.run([tools["paths"]["swift"], "package", "--package-path", str(package), "--scratch-path", str(scratch),
              "resolve"], package, evidence / "resolve", args.setup_timeout)
    require(source_identity(package, revision, extra_lock=extra_lock) == before, "Resolve changed pinned source/lock")
    deps = dependency_identity(package, scratch)
    if args.role == "comparator":
        product, build = base.prepare_cli(argparse.Namespace(indexstore_checkout=package, jobs=3,
                    setup_timeout=args.setup_timeout, fixtures=checkout / "Fixtures/IndexStoreCLIBenchmark"),
                    Path(tools["paths"]["swiftc"]), evidence / "build")
        product_evidence = build
    else:
        product_evidence = base.prepare_cartograph(argparse.Namespace(cartograph_package=package, cartograph=None,
                    jobs=3, setup_timeout=args.setup_timeout), Path(tools["paths"]["swiftc"]), evidence / "build")
        product = Path(product_evidence["binary"])
    require(source_identity(package, revision, extra_lock=extra_lock) == before
            and dependency_identity(package, scratch) == deps, "Build changed source/dependency bytes")
    require(toolchain_identity()["identity"] == tools["identity"], "Build toolchain changed")
    closure, copies = runtime_closure(product, tools)
    files = {}
    for relative, source in copies.items():
        target = out / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        files[relative] = {"sha256": digest(target), "bytes": target.stat().st_size,
                           "executable": relative == "bin/tool"}
    manifest = {"version": 1, "status": "prepared-only", "role": args.role, "binding": action,
                "source": before, "dependencies": deps, "toolchain": tools, "runtime_closure": closure,
                "source_verified_before_after": True, "dependencies_verified_before_after": True,
                "limits": {"jobs": 3, "setup_timeout_seconds": args.setup_timeout},
                "files": files, "build_evidence": product_evidence,
                "preparation_receipts": preparation_receipts,
                "producer": {"runner": os.environ.get("RUNNER_NAME"), "architecture": platform.machine(),
                             "preparation_seconds": time.monotonic() - started},
                "cost_scope": "Total producer preparation including acquisition, resolve, build, identities, closure and copy; not consumer or end-to-end timing"}
    verify_preparation(manifest)
    verify_dependency_pins(package, manifest)
    save(out / "manifest.json", manifest)
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write("manifest_sha256=" + digest(out / "manifest.json") + "\n")
    print(json.dumps({"status": "prepared-only", "role": args.role, "seconds": manifest["producer"]["preparation_seconds"]}, sort_keys=True))


def verify_files(root, manifest):
    files = manifest.get("files")
    require(type(files) is dict and 1 <= len(files) <= 256 and "bin/tool" in files, "Invalid artifact inventory")
    require(not root.is_symlink(), "Linked artifact root")
    actual, entries = set(), 0
    directories = {str(Path(name).parent) for name in files} | {"."}
    directories |= {str(parent) for name in files for parent in Path(name).parents}
    for path in root.rglob("*"):
        entries += 1
        require(entries <= 1024, "Artifact entry budget exceeded")
        require(not path.is_symlink(), "Artifact contains symlink")
        if path.is_dir():
            require(path.relative_to(root).as_posix() in directories, "Artifact contains extra directory")
        if path.is_file():
            actual.add(path.relative_to(root).as_posix())
    require(actual == set(files) | {"manifest.json"}, "Artifact has missing or extra files")
    for name, expected in files.items():
        path = regular(root, name)
        require(path.stat().st_size == expected["bytes"] and digest(path) == expected["sha256"], "Artifact bytes differ")
        require(expected["executable"] == (name == "bin/tool"), "Unexpected executable allowance")
    if "build_evidence" in manifest:
        require(manifest["build_evidence"].get("binary_sha256") == files["bin/tool"]["sha256"],
                "Transferred executable differs from producer build receipt")
    return root / "bin/tool"


def admit_comparator_dependencies(package, manifest, evidence):
    # 기존 mixed 검증은 실제 checkout을 읽는다. producer 경로를 위조하지 않고
    # 동일한 공개 pin을 소비자에서 다시 받아 전 파일 바이트를 대조한다.
    locations = {"swift-argument-parser": "https://github.com/apple/swift-argument-parser.git",
                 "swift-lmdb": "https://github.com/swiftlang/swift-lmdb.git"}
    pins = read_json(package / "Package.resolved")["pins"]
    require({pin["identity"]: pin["location"] for pin in pins} == locations, "Comparator dependency locations differ")
    checkouts = package / ".build/checkouts"
    checkouts.mkdir(parents=True)
    for pin in pins:
        name, revision = pin["identity"], pin["state"]["revision"]
        target = checkouts / name
        acquire(locations[name], revision, target, evidence / name)
        require(source_identity(target, revision) == manifest["dependencies"][name], "Consumer dependency bytes differ")


def admit(args):
    started = time.monotonic()
    checkout, root = args.checkout.resolve(), args.output.resolve()
    require(not root.exists(), "Consumer admission output must be new")
    root.mkdir(parents=True)
    phase_progress(base_module(), root)
    action, tools = binding(checkout), toolchain_identity()
    expected = read_json(args.expected)
    require(type(expected) is dict and set(expected) == set(ROLES), "Exact producer output roles required")
    result = {"version": 1, "status": "admitted-preparation-only", "binding": action,
              "toolchain": tools, "tools": {}, "consumer": {"runner": os.environ.get("RUNNER_NAME")}}
    for role in ROLES:
        artifact = args.artifacts.resolve() / role
        trust = expected[role]
        require(type(trust) is dict and re.fullmatch(r"[a-f0-9]{64}", trust.get("manifest_sha256", ""))
                and type(trust.get("artifact_id")) is str and trust["artifact_id"].isdigit(), "Producer trust anchor absent")
        require(digest(regular(artifact, "manifest.json")) == trust["manifest_sha256"], "Producer manifest digest differs")
        manifest = read_json(artifact / "manifest.json")
        require(manifest.get("version") == 1 and manifest.get("status") == "prepared-only"
                and manifest.get("role") == role and manifest.get("binding") == action, "Artifact role/run/source binding differs")
        require(manifest.get("toolchain", {}).get("identity") == tools["identity"], "Consumer toolchain/SDK/OS identity differs")
        verify_preparation(manifest)
        binary = verify_files(artifact, manifest)
        closure, _ = runtime_closure(binary, tools)
        require(closure == manifest["runtime_closure"], "Relocated runtime closure differs")
        package = checkout
        revision = action["checkout_commit"] if role == "candidate" else COMPARATOR if role == "comparator" else BASELINE
        if role != "candidate":
            package = root / (role + "-source")
            acquire(base_module().UPSTREAM if role == "comparator" else "https://github.com/ictechgy/cartograph.git",
                    revision, package, root / (role + "-acquisition"))
        extra_lock = None
        if role == "comparator":
            lock = checkout / "Fixtures/IndexStoreCLIBenchmark/indexstore-Package.resolved"
            extra_lock = digest(lock)
            shutil.copyfile(lock, package / "Package.resolved")
        require(source_identity(package, revision, extra_lock=extra_lock) == manifest["source"], "Consumer source/lock bytes differ")
        verify_dependency_pins(package, manifest)
        if role == "comparator":
            admit_comparator_dependencies(package, manifest, root / "comparator-dependencies")
        # 다운로드는 mode를 보존하지 않는다. 전체 바이트 검증 뒤 유일한 실행 파일만 복구한다.
        binary.chmod(0o755)
        result["tools"][role] = {"manifest": str(artifact / "manifest.json"),
                                  "manifest_sha256": digest(artifact / "manifest.json"),
                                  "artifact_id": trust["artifact_id"],
                                  "binary": str(binary), "binary_sha256": digest(binary),
                                  "consumer_source": str(package), "source": manifest["source"],
                                  "producer": manifest["producer"]}
    result["consumer"]["admission_seconds"] = time.monotonic() - started
    result["cost_scope"] = "Producer builds remain separate; transfer time is workflow evidence, admission is consumer-only"
    save(root / "admission.json", result)


def read_admission(path, *, retained_binding=None):
    value = read_json(path)
    require(value.get("version") == 1 and value.get("status") == "admitted-preparation-only", "Prepared admission required")
    if retained_binding is None:
        require(value["binding"] == binding(ROOT), "Current consumer Actions binding differs")
    else:
        require(value["binding"] == retained_binding, "Sealed Actions attestation differs")
        verify_checkout_binding(ROOT, retained_binding)
    require(value["toolchain"]["identity"] == toolchain_identity()["identity"], "Consumer toolchain changed")
    for role in ROLES:
        item = value["tools"][role]
        manifest_path = Path(item["manifest"])
        require(digest(manifest_path) == item["manifest_sha256"], "Prepared manifest changed")
        manifest = read_json(manifest_path)
        require(manifest.get("version") == 1 and manifest.get("status") == "prepared-only"
                and manifest.get("role") == role and manifest.get("binding") == value["binding"],
                "Admitted artifact binding changed")
        require(manifest["toolchain"]["identity"] == value["toolchain"]["identity"], "Admitted toolchain changed")
        verify_preparation(manifest)
        binary = verify_files(manifest_path.parent, manifest)
        require(str(binary) == item["binary"] and digest(binary) == item["binary_sha256"], "Admitted binary changed")
        require(runtime_closure(binary, value["toolchain"])[0] == manifest["runtime_closure"], "Runtime library bytes changed")
        require(source_identity(Path(item["consumer_source"]), item["source"]["revision"],
                    extra_lock=item["source"].get("extra_frozen_lock")) == item["source"], "Admitted source changed")
        verify_dependency_pins(Path(item["consumer_source"]), manifest)
        if role == "comparator":
            require(dependency_identity(Path(item["consumer_source"]), Path(item["consumer_source"]) / ".build")
                    == manifest["dependencies"], "Admitted comparator dependencies changed")
    return value


def prepared_product(value, role):
    item = value["tools"][role]
    manifest = read_json(item["manifest"])
    return {"binary": item["binary"], "binary_sha256": item["binary_sha256"],
            "version": manifest["build_evidence"].get("version"),
            "setup": {"mode": "verified-prepared-artifact", "source": item["source"],
                      "producer_evidence": manifest["build_evidence"], "producer": manifest["producer"],
                      "consumer_source": item["consumer_source"], "build_cost_measured": "producer-only",
                      "admission": item, "toolchain_identity": value["toolchain"]["identity"],
                      "limitation": "No single-host end-to-end setup cost; producer argv/timings are unchanged"}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    producer = commands.add_parser("prepare")
    producer.add_argument("--role", choices=ROLES, required=True)
    for name in ("checkout", "output", "evidence"):
        producer.add_argument("--" + name, type=Path, required=True)
    producer.add_argument("--jobs", type=int, required=True)
    producer.add_argument("--setup-timeout", type=int, required=True)
    consumer = commands.add_parser("admit")
    for name in ("checkout", "output", "artifacts", "expected"):
        consumer.add_argument("--" + name, type=Path, required=True)
    baseline = commands.add_parser("baseline")
    baseline.add_argument("--admission", type=Path, required=True)
    baseline.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args)
    elif args.command == "admit":
        admit(args)
    else:
        value = read_admission(args.admission)
        save(args.output, {"status": "admitted-preparation-only", "cartograph": prepared_product(value, "baseline"),
                           "toolchain_identity": value["toolchain"]["identity"], "admission": str(args.admission)})


if __name__ == "__main__":
    main()
