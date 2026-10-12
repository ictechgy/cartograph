"""기존 승인 세대의 명령·출력·도구 계약을 그대로 재사용하는 검증 전용 입력 경계."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "vendor/mixed"))
sys.path.insert(0, str(ROOT / "vendor/mixed/adapter"))
import compiler_generations as generations
import validation_common as common
import observe_mixed as observer


def digest(path):
    return generations.tool_digest(Path(path))


def helper_hashes():
    paths = [ROOT / "arm_sessions.py", ROOT / "generation_inputs.py", *sorted((ROOT / "vendor").rglob("*.py"))]
    return {str(p.relative_to(ROOT)): digest(p) for p in paths}


def read_reference(reference):
    if not isinstance(reference, dict) or set(reference) != {"path", "sha256"}:
        raise ValueError("Expected sealed receipt reference")
    path = Path(reference["path"])
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 4 * 1024**2:
        raise ValueError("Invalid bounded receipt file")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != reference["sha256"]:
        raise ValueError("Accepted receipt changed")

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate receipt key")
            result[key] = value
        return result

    value = json.loads(data, object_pairs_hook=unique)
    if not isinstance(value, (dict, list)):
        raise ValueError("Invalid receipt shape")
    return value


def verify(config):
    """정답 목록을 읽지 않고 승인 명령과 소스 인벤토리로 관측 문맥을 만든다."""
    allowed = {
        "project",
        "store",
        "library",
        "library_sha256",
        "native_binary",
        "index_dump",
        "generation_receipts",
        "executable_sha256",
        "helper_sha256",
        "arm",
        "state_id",
        "output",
        "accepted_sources",
        "developer_directory",
        "queries",
        "limit",
        "timeout",
    }
    if set(config) - allowed:
        raise ValueError("Engine config contains undeclared fields; gold is not an engine input")
    if "queries" in config and (
        not isinstance(config["queries"], list)
        or any(
            not isinstance(q, dict) or set(q) != {"id", "context", "signature", "max_depth"} for q in config["queries"]
        )
    ):
        raise ValueError("Expected source selectors only")
    refs = config["generation_receipts"]
    if set(refs) != {"lifecycle", "state", "commands"}:
        raise ValueError("Incomplete generation references")
    lifecycle = Path(refs["lifecycle"]["path"]).resolve().parent
    state_path = Path(refs["state"]["path"]).resolve()
    if not state_path.is_relative_to(lifecycle / "runs") or state_path.name != "state.json":
        raise ValueError("State receipt outside owned lifecycle")
    if Path(refs["commands"]["path"]).resolve() != state_path.with_name("commands.json"):
        raise ValueError("Command receipt outside accepted state")
    data, state, commands = (read_reference(refs[k]) for k in ("lifecycle", "state", "commands"))
    if (
        data.get("status") != "passed"
        or data.get("compiler_index_policy") != "fresh-shared-v2"
        or data.get("observation_failures") != []
    ):
        raise ValueError("Lifecycle is not accepted fresh-shared validation")
    if state.get("status") != "passed" or state.get("compiler_index_policy") != "fresh-shared-v2":
        raise ValueError("State is not accepted fresh-shared validation")
    accepted = state.get("accepted_generation", {})
    identifier = accepted.get("id")
    if (
        accepted.get("status") != "accepted"
        or not isinstance(identifier, str)
        or Path(identifier).name != identifier
        or identifier in ("", ".", "..")
    ):
        raise ValueError("Invalid accepted generation identity")
    if state.get("name") != identifier or state_path.parent != lifecycle / "runs" / identifier:
        raise ValueError("State identity mismatch")
    project = lifecycle / "Project"
    store = lifecycle / "Generations" / identifier / "IndexStore"
    build = store.with_name("Build")
    paths = [
        (config["project"], project),
        (state["project"], project),
        (config["store"], store),
        (accepted["store"], store),
        (accepted["build"], build),
    ]
    if any(
        Path(actual).resolve() != expected.resolve() or not expected.resolve().is_relative_to(lifecycle)
        for actual, expected in paths
    ):
        raise ValueError("Generation path boundary mismatch")
    setup = data["setup"]
    if accepted["toolchain_files"] != setup["compiler_toolchain_files"]:
        raise ValueError("Toolchain acceptance mismatch")
    expected_tools = {str(Path(setup[k]).absolute()) for k in ("swiftc", "clang", "library")}
    expected_tools.add(str(Path(setup["swiftc"]).with_name("swift-frontend").absolute()))
    if set(accepted["toolchain_files"]) != expected_tools:
        raise ValueError("Unexpected compiler identities")
    if (
        Path(config["library"]).resolve() != Path(setup["library"]).resolve()
        or digest(config["library"]) != config["library_sha256"]
    ):
        raise ValueError("Reader/compiler library mismatch")
    if helper_hashes() != config["helper_sha256"]:
        raise ValueError("Execution helper changed")
    if set(config["executable_sha256"]) != {"native_binary", "index_dump"}:
        raise ValueError("Missing actual engine identities")
    for key, expected in config["executable_sha256"].items():
        if digest(config[key]) != expected:
            raise ValueError("Actual engine bytes changed")
    generations.guard(accepted)
    generations.verify_inputs(accepted, project)
    expected_outputs, contexts = observer.compile_manifest(commands, state, setup)
    return dict(
        expected_outputs=expected_outputs,
        contexts=contexts,
        accepted_generation_sha256=generations.content_digest(accepted),
        sdk_content_identity=accepted.get("sdk_content_identity"),
        final_evidence=False,
    )
