"""혼합 언어 관측 정규화. 기대 간선/호출자 오라클을 읽지 않는다."""

from __future__ import annotations

from collections import defaultdict, deque
import hashlib
from pathlib import Path
import re

UNIT_FIELDS = {
    "Module",
    "Has Main File",
    "Main File",
    "Output File",
    "Target",
    "Sysroot",
    "Working Directory",
    "Is System",
    "Is Module",
    "Is Debug",
    "Provider Identifier",
    "Provider Version",
    "Modification Date",
}
CALLABLE_KINDS = {
    "function",
    "instance-method",
    "class-method",
    "static-method",
    "constructor",
    "destructor",
    "conversion-function",
    "method",
    "initializer",
    "deinitializer",
    "init",
    "deinit",
    "subscript",
    "instanceMethod",
    "classMethod",
    "staticMethod",
    "conversionFunction",
}


def kind_base(value: str) -> str:
    return re.split(r"[.(]", value, maxsplit=1)[0]


def parse_dependency(line: str) -> dict:
    """고정 CLI가 빈 필드를 생략하므로 절대 경로 위치로만 선택 필드를 구분한다."""
    fields = line.split(" | ")
    if len(fields) < 3 or fields[0] not in {"Unit", "Record", "File"} or fields[1] not in {"user", "system"}:
        raise ValueError(f"Unsupported pinned dependency: {line}")
    kind, scope, *tail = fields
    paths = [index for index, field in enumerate(tail) if Path(field).is_absolute()]
    if len(paths) != 1 or paths[0] not in {0, 1} or any(not value for value in tail):
        raise ValueError(f"Ambiguous pinned dependency: {line}")
    index = paths[0]
    module = tail[0] if index else ""
    # 시스템 레코드의 모듈 표시는 Swift.Collection.Lazy Views처럼 공백도 포함한다.
    if module and (any(character in module for character in "/\\|") or any(ord(c) < 32 for c in module)):
        raise ValueError(f"Unsupported dependency module: {line}")
    rest = tail[index + 1 :]
    if len(rest) > 1 or (rest and ("/" in rest[0] or "\\" in rest[0])):
        raise ValueError(f"Ambiguous pinned dependency name: {line}")
    name = rest[0] if rest else None
    if (kind == "Record" and name is None) or (kind == "File" and name is not None):
        raise ValueError(f"Missing or unexpected pinned dependency name: {line}")
    return dict(kind=kind, scope=scope, module=module, path=tail[index], name=name)


def parse_unit(name: str, text: str) -> dict:
    metadata, dependencies, includes = {}, [], []
    section = "metadata"
    for line in text.splitlines():
        if not line:
            continue
        if line in {"Dependencies:", "Includes:"}:
            section = line[:-1].lower()
            continue
        if section == "metadata":
            key, sep, value = line.partition(": ")
            if not sep or key not in UNIT_FIELDS or key in metadata:
                raise ValueError(f"Unsupported/duplicate pinned unit metadata: {line}")
            metadata[key] = value
        elif section == "dependencies":
            dependencies.append(parse_dependency(line))
        else:
            source, sep, target = line.partition(" | ")
            path, colon, row = source.rpartition(":")
            if not sep or not colon or not row.isdigit() or int(row) < 1:
                raise ValueError(f"Unsupported pinned include: {line}")
            includes.append(dict(path=path, line=int(row), target=target))
    if set(metadata) != UNIT_FIELDS:
        raise ValueError(f"Missing pinned unit metadata: {sorted(UNIT_FIELDS - set(metadata))}")
    for key in ["Has Main File", "Is System", "Is Module", "Is Debug"]:
        if metadata[key] not in {"true", "false"}:
            raise ValueError(f"Invalid unit boolean: {key}")
    return dict(name=name, metadata=metadata, dependencies=dependencies, includes=includes)


def parse_record(text: str) -> dict:
    symbols, occurrences = [], []
    section, current = None, None
    seen_sections = set()
    for line in text.splitlines():
        if not line:
            continue
        if line in {"Symbols:", "Occurrences:"}:
            if line in seen_sections:
                raise ValueError("Duplicate record section")
            section = line
            seen_sections.add(line)
            current = None
            continue
        fields = line.split(" | ")
        if section == "Symbols:":
            if len(fields) != 4:
                raise ValueError(f"Unsupported pinned symbol: {line}")
            symbols.append(dict(name=fields[0], kind=fields[1], usr=fields[2], roles=fields[3].split(", ")))
        elif section == "Occurrences:":
            if line.startswith("  "):
                if len(fields) != 2 or current is None:
                    raise ValueError(f"Orphan/unsupported relation: {line}")
                current["relations"].append(dict(roles=fields[0].strip().split(", "), usr=fields[1]))
            else:
                if len(fields) != 5 or not re.fullmatch(r"[1-9]\d*:[1-9]\d*", fields[0]):
                    raise ValueError(f"Unsupported pinned occurrence: {line}")
                row, column = map(int, fields[0].split(":"))
                current = dict(
                    line=row,
                    column=column,
                    name=fields[1],
                    kind=fields[2],
                    usr=fields[3],
                    printed_symbol_roles=fields[4].split(", "),
                    relations=[],
                )
                occurrences.append(current)
        else:
            raise ValueError(f"Unknown record preamble: {line}")
    if seen_sections != {"Symbols:", "Occurrences:"}:
        raise ValueError("Missing record sections")
    return dict(symbols=symbols, occurrences=occurrences)


def record_edges(record: dict) -> set[tuple[str, str]]:
    return {
        (relation["usr"], occurrence["usr"])
        for occurrence in record["occurrences"]
        for relation in occurrence["relations"]
        if "calledBy" in relation["roles"]
    }


def absolute(path: str, cwd: str) -> str:
    value = Path(path)
    return str((value if value.is_absolute() else Path(cwd) / value).resolve())


def target_key(value: str) -> str:
    match = re.fullmatch(r"(.+-apple-ios)([0-9]+(?:\.[0-9]+)*)(-simulator)?", value)
    if not match:
        return value
    parts = match.group(2).split(".")
    while len(parts) > 1 and parts[-1] == "0":
        parts.pop()
    return match.group(1) + ".".join(parts) + (match.group(3) or "")


def module_artifact_association(dependency: dict, unit: dict, roots: list[str], units: dict, expected: list) -> dict:
    """빌드 산출물 연관은 CLI 유닛 도달성과 별개이며 독립 선택된 소스 루트만 확인한다."""
    meta = unit["metadata"]
    path = absolute(dependency["path"], meta["Working Directory"])
    candidates = [entry for entry in expected if entry.get("module_artifact", {}).get("path") == path]
    if not candidates or dependency["scope"] != "user" or not dependency["module"]:
        raise ValueError(f"Nameless unit dependency lacks accepted project module evidence: {path}")
    artifact = candidates[0]["module_artifact"]
    if any(entry["module_artifact"] != artifact for entry in candidates):
        raise ValueError(f"Conflicting accepted module artifacts: {path}")
    if (
        artifact["module"] != dependency["module"]
        or artifact["provider"] != "swift"
        or meta["Provider Identifier"] != "swift"
        or target_key(artifact["target"]) != target_key(meta["Target"])
        or artifact["sysroot"] != absolute(meta["Sysroot"], meta["Working Directory"])
        or sorted(artifact["sources"]) != sorted(entry["source"] for entry in candidates)
        or sorted(artifact["outputs"]) != sorted(entry["output"] for entry in candidates)
        or len(set(artifact["outputs"])) != len(artifact["outputs"])
    ):
        raise ValueError(f"Nameless module build context/inventory mismatch: {path}")
    source_roots = []
    for entry in candidates:
        if (
            entry["module"] != artifact["module"]
            or entry["provider"] != artifact["provider"]
            or target_key(entry["target"]) != target_key(artifact["target"])
            or entry.get("sysroot") != artifact["sysroot"]
        ):
            raise ValueError(f"Module source root context mismatch: {path}")
        found = [
            name
            for name in roots
            if absolute(units[name]["metadata"]["Output File"], units[name]["metadata"]["Working Directory"])
            == entry["output"]
        ]
        if len(found) != 1:
            raise ValueError(f"Module source is not an independently selected current root: {path}")
        source_roots.extend(found)
    if not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]) or not Path(path).is_file():
        raise ValueError(f"Accepted module artifact unavailable: {path}")
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != artifact["sha256"]:
        raise ValueError(f"Accepted module artifact bytes changed: {path}")
    return dict(
        **dependency,
        absolute_path=path,
        source_roots=sorted(source_roots),
        artifact_sha256=artifact["sha256"],
        association="accepted-build-artifact-not-cli-unit-reachability",
    )


def select_units(units: dict, expected_outputs: list[dict]) -> dict:
    """활성 산출물에서만 시작하며, 남은 레코드 디렉터리를 입력으로 쓰지 않는다."""
    by_output = defaultdict(list)
    for name, unit in units.items():
        meta = unit["metadata"]
        if meta["Output File"]:
            by_output[absolute(meta["Output File"], meta["Working Directory"])].append(name)
    roots = []
    if not expected_outputs or len({e["output"] for e in expected_outputs}) != len(expected_outputs):
        raise ValueError("Expected output manifest is empty or duplicated")
    for expected in expected_outputs:
        found = by_output.get(str(Path(expected["output"]).resolve()), [])
        if len(found) != 1:
            raise ValueError(f'Expected one current unit for output {expected["output"]}: {found}')
        name = found[0]
        meta = units[name]["metadata"]
        if (
            meta["Has Main File"] != "true"
            or absolute(meta["Main File"], meta["Working Directory"]) != str(Path(expected["source"]).resolve())
            or meta["Module"] != expected["module"]
            or meta["Provider Identifier"] != expected["provider"]
            or target_key(meta["Target"]) != target_key(expected["target"])
        ):
            raise ValueError(f"Current unit source/module/provider/target mismatch: {name}")
        if expected.get("sysroot") and absolute(meta["Sysroot"], meta["Working Directory"]) != str(
            Path(expected["sysroot"]).resolve()
        ):
            raise ValueError(f"Current unit SDK mismatch: {name}")
        roots.append(name)
    selected, provenance, files, module_artifacts = set(), {}, {}, {}
    pending = deque((root, root) for root in sorted(roots))
    visits = set()
    while pending:
        name, root = pending.popleft()
        if (name, root) in visits:
            continue
        visits.add((name, root))
        selected.add(name)
        unit = units[name]
        for dependency in unit["dependencies"]:
            if dependency["kind"] == "Unit":
                child = dependency["name"]
                if child is None:
                    association = module_artifact_association(dependency, unit, roots, units, expected_outputs)
                    entry = module_artifacts.setdefault(
                        (name, association["absolute_path"]), dict(**association, unit=name, root_units=[])
                    )
                    entry["root_units"].append(root)
                    continue
                if child not in units:
                    raise ValueError(f"Missing reachable unit dependency: {name} -> {child}")
                if dependency["module"] and units[child]["metadata"]["Module"] != dependency["module"]:
                    raise ValueError(f"Dependency module mismatch: {name} -> {child}")
                pending.append((child, root))
                continue
            path = absolute(dependency["path"], unit["metadata"]["Working Directory"])
            key = (name, dependency["kind"], dependency["name"], path, dependency["module"])
            target = provenance if dependency["kind"] == "Record" else files
            entry = target.setdefault(
                key,
                dict(
                    **dependency, unit=name, root_units=[], absolute_path=path, unit_module=unit["metadata"]["Module"]
                ),
            )
            entry["root_units"].append(root)
    for entry in [*provenance.values(), *files.values(), *module_artifacts.values()]:
        entry["root_units"] = sorted(set(entry["root_units"]))
    return dict(
        roots=sorted(roots),
        reachable_units=sorted(selected),
        excluded_units=sorted(set(units) - selected),
        records=list(provenance.values()),
        files=list(files.values()),
        module_artifact_dependencies=list(module_artifacts.values()),
    )


def relative_path(project: Path, path: str) -> str | None:
    value = Path(path)
    try:
        return str((value if value.is_absolute() else project / value).resolve().relative_to(project.resolve()))
    except ValueError:
        return None


def source_catalog(project: Path, contexts: dict[str, list[str]]) -> list[dict]:
    """한 줄 선언 문법만 지원한다. 미지원 선언은 관측 단계에서 미해결로 남긴다."""
    entries = []
    for path, modules in sorted(contexts.items()):
        suffix = Path(path).suffix
        if suffix not in {".swift", ".m", ".mm", ".h", ".c", ".cpp"}:
            continue
        owner, scopes, depth = "", [], 0
        for row, line in enumerate((project / path).read_text().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith(("//", "#")):
                continue
            token, position, signature, definition = None, None, None, False
            if suffix == ".swift":
                while scopes and scopes[-1][1] > depth:
                    scopes.pop()
                container = re.search(r"\b(?:struct|class|enum|protocol|extension)\s+(\w+)", line)
                if container and "{" in line:
                    scopes.append((container.group(1), depth + 1))
                owner = scopes[-1][0] if scopes else ""
                match = re.search(r"\bfunc\s+(`?\w+`?)\s*\(([^)]*)\)", line)
                if match:
                    token, position = match.group(1).strip("`"), match.start(1)
                    parameters = ",".join(
                        part.split(":", 1)[1].strip().split("=")[0].strip()
                        for part in match.group(2).split(",")
                        if part.strip() and ":" in part
                    )
                    signature = f'{owner + "." if owner else ""}{token}({parameters})'
                else:
                    match = re.search(r"\b(init|deinit|subscript)\s*\(([^)]*)\)", line)
                    if match:
                        token, position = match.group(1), match.start(1)
                        signature = f'{owner + "." if owner else ""}{token}({match.group(2)})'
                definition = bool(token and "{" in line)
                depth += line.count("{") - line.count("}")
            else:
                match = re.search(r"@(implementation|interface)\s+(\w+)", line)
                if match:
                    owner = match.group(2)
                if stripped == "@end":
                    owner = ""
                method = re.match(r"\s*([+-])\s*\([^)]*\)\s*(\w+)\s*:", line)
                function = re.match(
                    r'\s*(?:(?:static|inline|extern\s+"C")\s+)*(?:int|long|void|double|float|char)\s+(\w+)\s*\(([^)]*)\)',
                    line,
                )
                if method:
                    token, position = method.group(2), method.start(2)
                    selectors = re.findall(r"\b(\w+)\s*:\s*\(", line)
                    signature = f'{method.group(1)}[{owner} {":".join(selectors)}:]'
                    definition = "{" in line
                elif function:
                    token, position = function.group(1), function.start(1)
                    params = [
                        re.sub(r"\s+\w+\s*$", "", item.strip()) for item in function.group(2).split(",") if item.strip()
                    ]
                    signature = f'{token}({",".join(params)})'
                    definition = "{" in line
            if token is not None:
                column = len(line[:position].encode("utf-8")) + 1
                for context in sorted(set(modules)):
                    entries.append(
                        dict(
                            id=f"{context}::{path}:{row}:{column}",
                            context=context,
                            path=path,
                            line=row,
                            column=column,
                            token=token,
                            signature=signature,
                            anchor=line,
                            definition=definition,
                            language="swift" if suffix == ".swift" else "clang",
                        )
                    )
    definitions = defaultdict(list)
    for entry in entries:
        if entry["definition"]:
            definitions[(entry["context"], entry["signature"])].append(entry["id"])
    for entry in entries:
        if not entry["definition"]:
            matches = definitions.get((entry["context"], entry["signature"]), [])
            if len(matches) == 1:
                entry["alias_of"] = matches[0]
    return entries


def bind_graph(
    catalog: list[dict], sightings: list[tuple[str, str]], raw_edges: set[tuple[str, str]], owned: set[str]
) -> dict:
    anchors = {entry["id"]: entry for entry in catalog}
    candidates, aliases = defaultdict(set), defaultdict(set)
    unresolved = []
    for usr, anchor_id in sightings:
        entry = anchors.get(anchor_id)
        if entry is None:
            unresolved.append(f"Unrecognized callable source anchor: {anchor_id} ({usr})")
            continue
        canonical = entry["id"] if entry["definition"] else entry.get("alias_of")
        if canonical is None:
            unresolved.append(f"In-universe declaration has no unique source definition: {anchor_id} ({usr})")
            continue
        candidates[usr].add(canonical)
        if entry["id"] != canonical:
            aliases[usr].add(entry["id"])
    symbols, bindings = {}, {}
    for usr, locations in candidates.items():
        if len(locations) != 1:
            raise ValueError(f"Compiler identity maps to multiple source definitions: {usr}: {sorted(locations)}")
        identity = next(iter(locations))
        if identity in bindings and bindings[identity] != usr:
            raise ValueError(f"Multiple compiler identities at one source definition: {identity}")
        symbols[usr], bindings[identity] = identity, usr
    for usr in sorted(owned - set(symbols)):
        unresolved.append(f"Unbound in-universe callable compiler identity: {usr}")
    for entry in catalog:
        if entry["definition"] and entry["id"] not in bindings:
            unresolved.append(f'Missing compiled definition: {entry["id"]}')
    edges, external_edges = set(), set()
    for caller, callee in raw_edges:
        # 외부 SDK 호출은 소스 선언 증거로만 제외하며, 오라클 정답은 사용하지 않는다.
        if callee not in owned:
            external_edges.add((caller, callee))
            continue
        a, b = symbols.get(caller, f"unmapped:{caller}"), symbols.get(callee, f"unmapped:{callee}")
        edges.add((a, b))
        if caller not in symbols or callee not in symbols:
            unresolved.append(f"Unmapped in-universe call edge: {caller} -> {callee}")
    return dict(
        symbols=symbols,
        bindings=bindings,
        aliases={k: sorted(v) for k, v in aliases.items()},
        edges=[list(e) for e in sorted(edges)],
        external_edges=[list(e) for e in sorted(external_edges)],
        unresolved=sorted(set(unresolved)),
    )


def baseline_graph(project: Path, catalog: list[dict], records: list[dict], texts: dict[str, str]) -> dict:
    anchors = {entry["id"]: entry for entry in catalog}
    contexts = defaultdict(set)
    for entry in catalog:
        contexts[entry["path"]].add(entry["context"])
    parsed = {name: parse_record(text) for name, text in texts.items()}
    sightings, raw_edges, owned = [], set(), set()
    for provenance in records:
        path = relative_path(project, provenance["absolute_path"])
        if path not in contexts:
            raise ValueError(f"Record absent from independently declared source universe: {path}")
        if path.endswith(".swift"):
            context = provenance["module"] or provenance["unit_module"]
            if context not in contexts[path]:
                raise ValueError(f"Swift record module absent from compile manifest: {path}: {context}")
        else:
            if contexts[path] != {"BridgeKit"}:
                raise ValueError(f"Ambiguous C-family build namespace: {path}")
            context = "BridgeKit"
        record = parsed[provenance["name"]]
        for symbol in record["symbols"]:
            if kind_base(symbol["kind"]) in CALLABLE_KINDS and {"definition", "declaration"} & set(symbol["roles"]):
                owned.add(symbol["usr"])
        for occurrence in record["occurrences"]:
            if kind_base(occurrence["kind"]) not in CALLABLE_KINDS:
                continue
            identity = f'{context}::{path}:{occurrence["line"]}:{occurrence["column"]}'
            if identity in anchors:
                token = anchors[identity]["token"]
                if re.split(r"[(:?!]", occurrence["name"], maxsplit=1)[0] != token:
                    raise ValueError(f"Compiler occurrence name disagrees with source anchor: {identity}")
                sightings.append((occurrence["usr"], identity))
                owned.add(occurrence["usr"])
        raw_edges.update(record_edges(record))
    return bind_graph(catalog, sightings, raw_edges, owned)


def reverse_depths(edges: list, seed: str, maximum: int) -> dict[str, int]:
    if type(maximum) is not int or maximum < 1:
        raise ValueError("Invalid depth")
    reverse = defaultdict(set)
    for caller, callee in edges:
        reverse[callee].add(caller)
    distances, queue = {seed: 0}, deque([seed])
    while queue:
        current = queue.popleft()
        if distances[current] == maximum:
            continue
        for caller in sorted(reverse[current]):
            if caller not in distances:
                distances[caller] = distances[current] + 1
                queue.append(caller)
    del distances[seed]
    return dict(sorted(distances.items()))


def query_item(request: dict, depths: dict) -> dict:
    return dict(
        **request,
        direct=sorted(key for key, depth in depths.items() if depth == 1),
        transitive=[dict(id=key, minimum_depth=depth) for key, depth in sorted(depths.items())],
    )


def graph_observation(graph: dict, requests: list[dict], arm: str) -> dict:
    missing = [f'Missing query seed: {r["seed"]}' for r in requests if r["seed"] not in graph["bindings"]]
    unresolved = sorted(set(graph["unresolved"] + missing))
    return dict(
        arm=arm,
        operation="compiler-callers",
        capability="supported",
        fresh=True,
        complete=not unresolved,
        unresolved=unresolved,
        queries=[query_item(r, reverse_depths(graph["edges"], r["seed"], r["max_depth"])) for r in requests],
    )


def cartograph_graph(document: dict, project: Path, catalog: list[dict]) -> dict:
    if (
        document.get("level") != "symbol"
        or not isinstance(document.get("nodes"), list)
        or not isinstance(document.get("edges"), list)
    ):
        raise ValueError("Expected native Cartograph symbol-level graph")
    by_path = defaultdict(set)
    for entry in catalog:
        by_path[entry["path"]].add(entry["context"])
    ids, sightings, raw_edges, owned = {}, [], set(), set()
    for node in document["nodes"]:
        identifier, usr = node.get("id"), node.get("usr") or node.get("id")
        if not isinstance(identifier, str) or not isinstance(usr, str) or identifier in ids:
            raise ValueError("Invalid/duplicate native graph identity")
        ids[identifier] = usr
        location = node.get("location")
        if not location:
            continue
        path = relative_path(project, location["path"])
        if not path or not path.startswith("Sources/"):
            continue
        if kind_base(node.get("kind", "")) not in CALLABLE_KINDS:
            continue
        owned.add(usr)
        if path not in by_path:
            sightings.append((usr, f'unexpected-source::{path}:{location["line"]}:{location["column"]}'))
            continue
        context = node.get("module") if path.endswith(".swift") else "BridgeKit"
        if context not in by_path[path]:
            raise ValueError(f"Native module missing/conflicting with compile manifest: {path}: {context}")
        if (
            type(location["line"]) is not int
            or type(location["column"]) is not int
            or min(location["line"], location["column"]) < 1
        ):
            raise ValueError("Invalid native source coordinates")
        sightings.append((usr, f'{context}::{path}:{location["line"]}:{location["column"]}'))
    for edge in document["edges"]:
        if edge.get("kind") != "call":
            continue
        if edge.get("source") not in ids or edge.get("target") not in ids:
            raise ValueError("Dangling native call edge")
        raw_edges.add((ids[edge["source"]], ids[edge["target"]]))
    return bind_graph(catalog, sightings, raw_edges, owned)


def cartograph_batch(document: dict, requests: list[dict], graph: dict) -> dict:
    if (
        document.get("format") != "symbol-query-batch"
        or document.get("version") != 1
        or not isinstance(document.get("results"), list)
        or len(document["results"]) != len(requests)
    ):
        raise ValueError("Native batch format/result count mismatch")
    queries, limitations, unresolved = [], {}, list(graph["unresolved"])
    for request, result in zip(requests, document["results"]):
        usr = graph["bindings"].get(request["seed"])
        if (
            usr is None
            or result.get("requested") != usr
            or result.get("status") != "found"
            or result.get("level") != "symbol"
        ):
            raise ValueError(f'Missing/ambiguous/wrong native query subject: {request["id"]}')
        answer = result.get("result", {})
        if answer.get("subject", {}).get("usr") != usr or any(
            type(answer.get("truncated", {}).get(key)) is not bool or answer["truncated"][key]
            for key in ["usedBy", "dependsOn", "members"]
        ):
            raise ValueError("Native subject/truncation contract failed")
        if not isinstance(result.get("limitations"), list) or not all(
            isinstance(s, str) for s in result["limitations"]
        ):
            raise ValueError("Native limitations missing")
        if not isinstance(answer.get("usedBy"), list):
            raise ValueError("Native usedBy list missing")
        limitations[request["id"]] = result["limitations"]
        if any(s.startswith("index-staleness:") for s in result["limitations"]):
            unresolved.append(f'Native stale warning in fresh state: {request["id"]}')
        depths = {}
        for neighbor in answer["usedBy"]:
            depth, neighbor_usr = neighbor.get("depth"), neighbor.get("usr")
            if type(depth) is not int or not 1 <= depth <= request["max_depth"] or neighbor.get("edges") != ["call"]:
                raise ValueError("Invalid native call-only depth/edge")
            identity = graph["symbols"].get(neighbor_usr, f"unmapped:{neighbor_usr}")
            if identity in depths:
                raise ValueError("Native duplicate caller source identity")
            depths[identity] = depth
            if neighbor_usr not in graph["symbols"]:
                unresolved.append(f"Unmapped native caller: {neighbor_usr}")
        queries.append(query_item(request, depths))
    return dict(
        arm="native-cartograph-query",
        operation="compiler-callers",
        capability="supported",
        fresh=True,
        complete=not unresolved,
        unresolved=sorted(set(unresolved)),
        queries=queries,
        limitations=limitations,
    )
