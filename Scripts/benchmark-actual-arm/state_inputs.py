"""한 복구 상태와 동결한 질의·도구 영수증만 검증용 작업으로 선택한다."""

from __future__ import annotations

import hashlib
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "runtime"))
sys.path.insert(0, str(ROOT / "primitive"))
import runtime_bootstrap as bootstrap
import generation_inputs as generation
from selector_contract import selectors

QUERY_SHA256 = "1bf4ecb41dc751bc9ce8b3c5872d135121614e53eccd4482e312efea39b90b91"
ORACLE_SHA256 = "ca71acc4d669e8aa04f7c0e7400417f9f20b78063289c9b76c4a4f4564e7beec"
STATES = [row[0] for row in generation.common.STAGES]
FIXTURE = Path("Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation")


def require(value, reason):
    if not value:
        raise ValueError(reason)


def reference(path):
    path = Path(path).absolute()
    data = bootstrap.read_regular(path)
    return dict(path=str(path), sha256=hashlib.sha256(data).hexdigest())


def reference_bytes(ref):
    require(isinstance(ref, dict) and set(ref) == {"path", "sha256"}, "Invalid sealed input")
    data = bootstrap.read_regular(Path(ref["path"]))
    require(hashlib.sha256(data).hexdigest() == ref["sha256"], "Sealed input changed")
    return data


def document(ref):
    return bootstrap.strict_json(reference_bytes(ref))


def disjoint(destination, candidates):
    """새 디렉터리 생성 전 문자열 경계와 물리 경계를 각각 비교한다."""
    destination = Path(destination)
    require(destination.is_absolute() and ".." not in destination.parts, "Output must be absolute without parents")
    for value in candidates:
        path = Path(value)
        for dst, src in [(destination.absolute(), path.absolute()), (destination.resolve(), path.resolve())]:
            require(not dst.is_relative_to(src) and not src.is_relative_to(dst), "Evidence/input overlap")
    require(not destination.exists() and not destination.is_symlink(), "Evidence must be new")


def source_snapshot(project):
    # 동결된 엔진과 같은 Sources/config 의미이며 사전 설치 확인에서 psutil을 가져오지 않는다.
    root = Path(project)
    paths = sorted((root / "Sources").rglob("*"))
    config = root / ".cartograph.yml"
    if config.exists():
        paths.append(config)
    return {
        str(p.relative_to(root)): dict(sha256=generation.digest(p), mtime_ns=p.stat().st_mtime_ns)
        for p in paths
        if p.is_file()
    }


def guard(plan):
    import time

    started = time.perf_counter()
    row = dict(status="failed")
    try:
        for reference in plan["inputs"].values():
            reference_bytes(reference)
        row["generation"] = generation.verify(plan["engine_config"])
        row["status"] = "passed"
    except KeyboardInterrupt:
        row.update(status="incomplete", failure="KeyboardInterrupt")
    except (ValueError, OSError, RuntimeError, KeyError, TypeError) as error:
        row["failure"] = type(error).__name__
    row["wall_seconds"] = time.perf_counter() - started
    return row


def successful_setup(row):
    return (
        isinstance(row, dict)
        and type(row.get("returncode")) is int
        and row["returncode"] == 0
        and row.get("timed_out") is False
        and type(row.get("wall_seconds")) in (int, float)
        and math.isfinite(row["wall_seconds"])
        and row["wall_seconds"] >= 0
    )


def prepare(repository, lifecycle_path, setup_path, measurement_path):
    """아직 출력을 만들지 않고 요청·원래 성공 상태·현재 실행 파일만 연결한다."""
    repository = Path(repository).resolve(strict=True)
    inputs = dict(
        lifecycle=reference(lifecycle_path),
        state=reference(Path(lifecycle_path).parent / "runs/restored_rebuilt/state.json"),
        commands=reference(Path(lifecycle_path).parent / "runs/restored_rebuilt/commands.json"),
        tools=reference(setup_path),
        measurement=reference(measurement_path),
        queries=reference(repository / FIXTURE / "adapter/query-spec.json"),
        oracle=reference(repository / FIXTURE / "oracle.json"),
    )
    lifecycle, state, tools = (document(inputs[k]) for k in ("lifecycle", "state", "tools"))
    require(
        lifecycle.get("status") == "passed"
        and lifecycle.get("compiler_index_policy") == "fresh-shared-v2"
        and lifecycle.get("observation_failures") == []
        and [s.get("name") for s in lifecycle.get("states", [])] == STATES
        and all(s.get("status") == "passed" for s in lifecycle["states"]),
        "All thirteen fresh-shared validation states must pass",
    )
    require(state == lifecycle["states"][-1] and state["name"] == "restored_rebuilt", "Restored state differs")
    require(
        state["oracle_variant"] == "initial" and state["expected_fresh"] is True, "Restored generation is not fresh"
    )
    require(inputs["queries"]["sha256"] == QUERY_SHA256, "Frozen source selector file changed")
    require(inputs["oracle"]["sha256"] == ORACLE_SHA256, "Frozen independent oracle file changed")
    queries = document(inputs["queries"])
    selectors(queries)
    native, baseline = tools["cartograph"], tools["comparator_setup"]
    require(
        tools.get("correctness_and_freshness_passed") is True
        and baseline.get("repository") == "https://github.com/swiftlang/indexstore-db.git"
        and baseline.get("revision") == "64aa0b26913249c4e7c21d351a215fba02702003"
        and native["setup"]["build_cost_measured"] is True
        and successful_setup(native["setup"]["build"])
        and isinstance(baseline.get("commands"), list)
        and bool(baseline["commands"])
        and all(successful_setup(row) for row in baseline["commands"])
        and successful_setup(baseline.get("help"))
        and baseline.get("untracked_build_inputs", {}).get("passed") is True,
        "Original native/tool setup prerequisites failed",
    )
    require(generation.digest(native["binary"]) == native["binary_sha256"], "Native binary changed")
    require(generation.digest(baseline["binary"]) == baseline["binary_sha256"], "Pinned CLI binary changed")
    setup = lifecycle["setup"]
    root = Path(lifecycle_path).resolve().parent
    config = dict(
        project=str(root / "Project"),
        store=str(root / "Generations/restored_rebuilt/IndexStore"),
        library=setup["library"],
        library_sha256=generation.digest(setup["library"]),
        native_binary=native["binary"],
        index_dump=baseline["binary"],
        generation_receipts={k: inputs[k] for k in ("lifecycle", "state", "commands")},
        executable_sha256=dict(native_binary=native["binary_sha256"], index_dump=baseline["binary_sha256"]),
        helper_sha256=generation.helper_hashes(),
        state_id="restored_rebuilt",
        accepted_sources=source_snapshot(root / "Project"),
        developer_directory=setup["developer_dir"],
        queries=queries,
        limit=10000,
        timeout=240,
    )
    # 양쪽 엔진에 전달할 수 있는 기존 필드만 허용한다. 정답 참조는 여기에 넣지 않는다.
    derived = generation.verify(config)
    roots = [ROOT, repository, root, Path(measurement_path).resolve().parent, Path(setup_path).resolve().parent]
    roots.extend(Path(v["path"]) for v in inputs.values())
    roots += [Path(setup["sdk_path"]), Path(setup["developer_dir"])]
    roots += [Path(v) for v in (native["binary"], baseline["binary"], setup["library"], sys.executable)]
    roots += [p for p in Path(setup["clang"]).resolve().parents if p.name.endswith(".xctoolchain")]
    return dict(
        schema_version=1,
        state_id="restored_rebuilt",
        final_evidence=False,
        repository=str(repository),
        inputs=inputs,
        engine_config=config,
        input_roots=[str(v) for v in roots],
        accepted=derived,
        baseline_checkout=baseline["checkout"],
        prior_costs=dict(
            original_setup_reference=inputs["tools"],
            original_measurement_reference=inputs["measurement"],
            shared_build=state["shared_input_cost"],
            shared_preflight=state["shared_preflight_integrity_wall_seconds_by_arm"],
            scope="Retained shared/prior costs; no endpoint totals or zero-cost reuse claim",
        ),
    )


def bind_sdk_discovery(plan, sdk_path):
    """완료된 SDK 진단의 세대와 비용만 묶으며 루트 승인을 추론하지 않는다."""
    sdk_ref = reference(sdk_path)
    sdk = document(sdk_ref)
    require(
        sdk.get("accepted") is False
        and sdk.get("final_protocol_ready") is False
        and sdk.get("phase", {}).get("completed") is True
        and type(sdk.get("phase", {}).get("returncode")) is int
        and sdk["phase"]["returncode"] >= 0
        and sdk["phase"]["returncode"] != 125
        and type(sdk["phase"].get("observed_returncode")) is int
        and sdk["phase"]["returncode"] == sdk["phase"]["observed_returncode"]
        and sdk["phase"].get("failure") is None
        and sdk["phase"].get("cleanup_root_unfinished") is False
        and sdk.get("generation_guard_before", {}).get("status") == "passed"
        and sdk.get("generation_guard_after", {}).get("status") == "passed",
        "SDK diagnostic must be terminal with accepted generation guards; no root acceptance inferred",
    )
    sdk_cost = sdk["total_wall_seconds"]
    require(type(sdk_cost) in (int, float) and math.isfinite(sdk_cost) and sdk_cost >= 0, "Invalid SDK cost")
    require(
        sdk["charged_wall_seconds_by_arm"] == dict(cartograph=sdk_cost, index_dump_assembly=sdk_cost)
        and all(type(value) in (int, float) for value in sdk["charged_wall_seconds_by_arm"].values()),
        "SDK shared cost differs",
    )
    require(
        sdk["input_files"]["results.json"]["sha256"] == plan["inputs"]["lifecycle"]["sha256"],
        "SDK diagnostic used another lifecycle",
    )
    plan["inputs"]["sdk_discovery"] = sdk_ref
    plan["prior_costs"]["sdk_discovery"] = dict(
        reference=sdk_ref, full_wall_seconds=sdk_cost, charged_wall_seconds_by_arm=sdk["charged_wall_seconds_by_arm"]
    )
