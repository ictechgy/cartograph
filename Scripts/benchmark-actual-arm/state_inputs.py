"""한 복구 상태와 동결한 질의·도구 영수증만 검증용 작업으로 선택한다."""

from __future__ import annotations

import hashlib
import json
import math
import statistics
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


def calibration_plan():
    """결과를 보기 전에 고정한 네 비교별 순서와 정확한 32개 호출을 반환한다."""
    groups = [
        ("baseline", "timing", "AB", "BA", "BA", "AB"),
        ("cartograph", "memory", "BA", "AB", "AB", "BA"),
        ("cartograph", "timing", "BA", "AB", "BA", "AB"),
        ("baseline", "memory", "AB", "BA", "AB", "BA"),
    ]
    jobs = []
    for pair in range(1, 5):
        for engine, mode, *orders in groups:
            for side in orders[pair - 1]:
                jobs.append(dict(
                    number=len(jobs) + 1, engine=engine, mode=mode, pair=pair,
                    order=orders[pair - 1], side=side,
                    folder=f"invocation-{len(jobs) + 1:02d}",
                    observer="direct" if side == "A" else mode,
                ))
    return dict(
        version="native-observer-v1", invocations=jobs, engine_invocation_count=32,
        pairs_per_engine_mode=4, interval_seconds=0.01, calibration_timeout_seconds=900,
        engine_timeout_seconds=240, timing_median_ratio_max=1.05, timing_any_ratio_max=1.10,
        statistic="median and maximum of four within-pair observed/direct engine-wall ratios",
        eligibility_scope="timing mode only; empirical diagnostic screen, not a population confidence bound",
        memory_scope="separate verified sampled observation; no primary timing or continuous-peak claim",
        order_policy="literal balanced schedule frozen before execution; no replacement or reseeding",
        final_evidence=False,
    )


def require(value, reason):
    if not value:
        raise ValueError(reason)



def calibration_groups(rows):
    """같은 엔진·모드의 네 쌍만 해석하며 메모리 구간을 주 시간으로 바꾸지 않는다."""
    expected = calibration_plan()["invocations"]
    require(
        len(rows) == len(expected) and [row["invocation"] for row in rows] == expected,
        "Calibration invocation inventory differs",
    )
    groups = []
    for engine in ("baseline", "cartograph"):
        reference = None
        for mode in ("timing", "memory"):
            ratios, pairs = [], []
            for pair in range(1, 5):
                selected = [row for row in rows if all(
                    row["invocation"][key] == value for key, value in
                    [("engine", engine), ("mode", mode), ("pair", pair)]
                )]
                require(len(selected) == 2, "Calibration pair differs")
                values = {row["invocation"]["side"]: row for row in selected}
                require(set(values) == {"A", "B"}, "Calibration pair sides differ")
                walls = {}
                for side, row in values.items():
                    require(
                        row["status"] == "passed" and type(row["exit_code"]) is int and row["exit_code"] == 0
                        and row["evaluation"]["status"] == "passed"
                        and row["arm"] == row["worker"]["arm"] == engine
                        and row["observer"]["mode"] == row["observer"]["measurement"]["measurement_mode"]
                        == row["invocation"]["observer"],
                        "Calibration invocation did not pass",
                    )
                    observed = json.dumps(
                        {key: row["worker"][key] for key in ("graph", "observation")},
                        sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False,
                    ).encode()
                    if reference is None:
                        reference = observed
                    require(observed == reference, "Same-engine calibration output differs")
                    wall = row["observer"]["measurement"]["wall_seconds"]
                    require(
                        type(wall) in (int, float) and math.isfinite(wall) and wall > 0,
                        "Invalid calibration wall",
                    )
                    walls[side] = wall
                ratio = walls["B"] / walls["A"]
                require(math.isfinite(ratio) and ratio > 0, "Invalid calibration ratio")
                ratios.append(ratio)
                pairs.append(dict(pair=pair, order=selected[0]["invocation"]["order"],
                                  direct_wall_seconds=walls["A"], observed_wall_seconds=walls["B"], ratio=ratio))
            median, maximum = statistics.median(ratios), max(ratios)
            groups.append(dict(
                engine=engine, mode=mode, pairs=pairs, median_ratio=median, maximum_ratio=maximum,
                timing_eligible=(median <= 1.05 and maximum <= 1.10) if mode == "timing" else None,
                scope=("matched Popen through root wait" if mode == "timing" else
                       "memory setup/polling/descendant interval; descriptive, excluded from primary timing"),
            ))
    return groups


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
        if plan.get("prepared_tools") is not None:
            retained = plan["prepared_tools"]
            prepared = prepared_module(plan["inputs"])
            value = prepared.read_admission(Path(plan["inputs"]["prepared:admission"]["path"]),
                                            retained_binding=retained["binding"])
            require(value == document(plan["inputs"]["prepared:admission"]), "Retained admission changed")
            row["prepared_tools"] = dict(status="revalidated", binding=retained["binding"],
                                         scope="Original sealed Actions attestation; no new run/attempt observation")
        row["generation"] = generation.verify(plan["engine_config"])
        if plan.get("prepared_tools") is not None:
            for name, ref in plan["inputs"].items():
                if name.startswith("prepared:"):
                    reference_bytes(ref)
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


def original_setup_succeeded(native, baseline):
    setup = native.get("setup", {})
    return (
        setup.get("build_cost_measured") is True
        and successful_setup(setup.get("build"))
        and isinstance(baseline.get("commands"), list)
        and bool(baseline["commands"])
        and all(successful_setup(row) for row in baseline["commands"])
        and successful_setup(baseline.get("help"))
        and baseline.get("untracked_build_inputs", {}).get("passed") is True
    )


def prepared_module(inputs):
    # 원래 runtime 코드 목록 밖의 두 helper는 별도 봉인한 실제 소스에서만 실행한다.
    # loader의 기존 pyc나 생산자 경로를 가져오지 않고 각 guard에서 다시 읽는다.
    import types
    modules = {}
    for role in ("benchmark", "helper"):
        ref = inputs["prepared:" + role]
        path = Path(ref["path"])
        require(path.is_absolute() and path.resolve(strict=True) == path, "Prepared helper path is aliased")
        module = types.ModuleType("sealed_prepared_" + role)
        module.__file__ = str(path)
        exec(compile(reference_bytes(ref), str(path), "exec"), module.__dict__)
        modules[role] = module
    modules["helper"]._BASE = modules["benchmark"]
    return modules["helper"]


def bind_prepared_setup(repository, inputs, tools, lifecycle_setup):
    native, baseline = tools["cartograph"], tools["comparator_setup"]
    require(tools.get("status") == "passed"
            and native["setup"].get("mode") == baseline.get("mode") == "verified-prepared-artifact",
            "Prepared tools require a passed actual comparison and matching modes")
    admission_path = Path(native["setup"]["admission_path"])
    require(admission_path.is_absolute() and admission_path.resolve(strict=True) == admission_path
            and baseline.get("admission_path") == str(admission_path), "Prepared admission path differs")
    inputs["prepared:admission"] = reference(admission_path)
    inputs["prepared:helper"] = reference(repository / "Scripts/prepared-comparison-tools.py")
    inputs["prepared:benchmark"] = reference(repository / "Scripts/benchmark-indexstore-cli.py")
    recorded = document(inputs["prepared:admission"])
    for role in ("candidate", "comparator", "baseline"):
        item = recorded["tools"][role]
        ref = reference(item["manifest"])
        require(ref["sha256"] == item["manifest_sha256"], "Retained manifest changed")
        inputs["prepared:manifest:" + role] = ref
    prepared = prepared_module(inputs)
    value = prepared.read_admission(admission_path, retained_binding=recorded["binding"])
    require(value == recorded, "Prepared admission changed during binding")
    expected_native = prepared.prepared_product(value, "candidate")
    expected_cli = prepared.prepared_product(value, "comparator")
    require(all(native.get(key) == item for key, item in expected_native.items() if key != "setup")
            and all(native["setup"].get(key) == item for key, item in expected_native["setup"].items()),
            "Passed native result differs from retained producer/consumer identity")
    cli_setup = expected_cli["setup"]
    original_cli = cli_setup["producer_evidence"]
    expected_baseline = dict(
        binary=expected_cli["binary"], binary_sha256=expected_cli["binary_sha256"],
        checkout=cli_setup["consumer_source"], source=cli_setup["source"],
        build_evidence=original_cli, commands=original_cli["commands"],
        producer=cli_setup["producer"], admission=cli_setup["admission"],
        toolchain_identity=value["toolchain"]["identity"],
    )
    require(all(baseline.get(key) == item for key, item in expected_baseline.items()),
            "Passed comparator result differs from retained producer/consumer identity")
    require(original_setup_succeeded(expected_native["setup"]["producer_evidence"], original_cli),
            "Original producer setup prerequisites failed")
    identity, paths = value["toolchain"]["identity"], value["toolchain"]["paths"]
    compiler = tools["toolchain"]
    require(tools.get("toolchain_identity") == identity and compiler["version"] == identity["swift_version"]
            and compiler["library_sha256"] == identity["tools_sha256"]["libIndexStore"],
            "Original comparison toolchain differs from admission")
    for key, name in (("swiftc", "swiftc"), ("clang", "clang"), ("library", "libIndexStore")):
        path = Path(lifecycle_setup[key]).resolve(strict=True)
        require(path == Path(paths[name]).resolve(strict=True)
                and generation.digest(path) == identity["tools_sha256"][name],
                "Restored generation toolchain differs from admission")
        if key != "clang":
            require(Path(compiler[key]).resolve(strict=True) == path, "Comparison compiler path differs")
    return dict(
        binding=value["binding"],
        scope="Original sealed Actions attestation; current checkout/source/runtime revalidated without a new run claim",
        roots=[str(admission_path.parent), *[str(Path(item["manifest"]).parent) for item in value["tools"].values()],
               *[item["consumer_source"] for item in value["tools"].values()]],
        producer_costs={role: item["producer"] for role, item in value["tools"].items()},
        consumer_admission=value["consumer"],
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
        and baseline.get("revision") == "64aa0b26913249c4e7c21d351a215fba02702003",
        "Original native/tool setup prerequisites failed",
    )
    prepared = None
    if native["setup"].get("mode") == "verified-prepared-artifact" or baseline.get("mode") == "verified-prepared-artifact":
        prepared = bind_prepared_setup(repository, inputs, tools, lifecycle["setup"])
    else:
        require(original_setup_succeeded(native, baseline), "Original native/tool setup prerequisites failed")
    require(generation.digest(native["binary"]) == native["binary_sha256"], "Native binary changed")
    require(generation.digest(baseline["binary"]) == baseline["binary_sha256"], "Pinned CLI binary changed")
    setup = lifecycle["setup"]
    developer = generation.developer_context(setup)
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
        developer_directory=developer["developer_directory"],
        developer_context=developer,
        queries=queries,
        limit=10000,
        timeout=240,
    )
    # 양쪽 엔진에 전달할 수 있는 기존 필드만 허용한다. 정답 참조는 여기에 넣지 않는다.
    derived = generation.verify(config)
    roots = [ROOT, repository, root, Path(measurement_path).resolve().parent, Path(setup_path).resolve().parent]
    roots.extend(Path(v["path"]) for v in inputs.values())
    roots += [Path(setup["sdk_path"]), Path(developer["developer_directory"])]
    roots += [Path(v) for v in (native["binary"], baseline["binary"], setup["library"], sys.executable)]
    roots += [p for p in Path(setup["clang"]).resolve().parents if p.name.endswith(".xctoolchain")]
    if prepared is not None:
        roots.extend(Path(value) for value in prepared["roots"])
    plan = dict(
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
    if prepared is not None:
        plan["prepared_tools"] = prepared
        plan["prior_costs"]["prepared_tools"] = dict(
            producer=prepared["producer_costs"], consumer_admission=prepared["consumer_admission"],
            scope="Separate retained producer and consumer costs; no local build or composed endpoint total",
        )
    return plan


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


CALIBRATION_INPUT_HELPERS = (
    "Scripts/validate-native-calibration-inputs.py",
    "Scripts/benchmark-inputs/native_calibration_inputs.py",
    "Scripts/benchmark-inputs/native_calibration_expectation.json",
    "Scripts/benchmark-inputs/native_calibration_publication.py",
    "Scripts/benchmark-inputs/sdk_content_seal.py",
    "Scripts/benchmark-inputs/select_sdk_roots.py",
    "Scripts/normalize-indexstore-evidence.py",
    ".github/workflows/native-calibration.yml",
)


def bind_calibration_sdk(plan, scratch):
    """불변 사전·세대 후 영수증과 실제 단계 호출 비용만 엔진 계획에 연결한다."""
    repository, scratch = Path(plan["repository"]), Path(scratch)
    source_refs = {name: reference(repository / name) for name in CALIBRATION_INPUT_HELPERS}
    hashes = {name: ref["sha256"] for name, ref in source_refs.items()}
    refs, phases, costs = {}, {}, {}
    for name, status in (("before-compilation", "captured-candidate"), ("after-generation", "verified-candidate")):
        ref = reference(scratch / "native-calibration-sdk-raw/setup/phases" / (name + ".json"))
        call_ref = reference(scratch / "native-calibration-sdk-calls" / name / "results.json")
        phase, call = document(ref), document(call_ref)
        observation, command = phase["observation"], call["command"]
        require(phase["stage"] == call["stage"] == name
                and phase["status"] == call["status"] == "passed"
                and type(phase["exit_code"]) is int and phase["exit_code"] == 0
                and type(call["exit_code"]) is int and call["exit_code"] == 0
                and phase["helper_sha256"] == call["helper_sha256"] == hashes
                and call["original_phase"] == ref
                and observation["status"] == status and observation["boundary"] == name
                and observation["accepted"] is False and observation["final_protocol_ready"] is False
                and phase["accepted"] is False and call["accepted"] is False
                and phase["final_protocol_ready"] is False and call["final_protocol_ready"] is False,
                "Calibration SDK phase relation differs")
        argv = command["command"]
        require(isinstance(argv, list) and len(argv) == 10
                and Path(argv[0]).resolve(strict=True) == Path(sys.executable).resolve(strict=True)
                and argv[1:] == ["-I", "-S", "-B", str(repository / CALIBRATION_INPUT_HELPERS[0]),
                                "--stage", name, "--scratch-root", str(scratch), "--execute-stage"]
                and command["cwd"] == str(repository)
                and command["completed"] is True and command["passed"] is True
                and type(command["returncode"]) is int and command["returncode"] == 0
                and type(command["observed_returncode"]) is int and command["observed_returncode"] == 0
                and command["failure"] is None and command["cleanup_signals"] == []
                and command["cleanup_root_unfinished"] is False,
                "Calibration SDK actual caller differs")
        wall, outer = command["wall_seconds"], call["full_call_wall_seconds_before_receipt"]
        require(type(wall) in (int, float) and math.isfinite(wall) and wall >= 0
                and type(outer) in (int, float) and math.isfinite(outer) and outer >= wall,
                "Invalid calibration SDK cost")
        refs[name], refs[name + "-caller"] = ref, call_ref
        phases[name] = phase
        costs[name] = dict(reference=call_ref, child_process_wall_seconds=wall,
                           supervisor_wall_seconds_before_receipt=outer,
                           charged_child_wall_seconds_by_arm=dict(baseline=wall, cartograph=wall))
    before, after = phases["before-compilation"]["observation"], phases["after-generation"]["observation"]
    content = before["content_sha256"]
    require(isinstance(content, str) and len(content) == 64 and all(c in "0123456789abcdef" for c in content)
            and before["expectation_sha256"] == hashes[CALIBRATION_INPUT_HELPERS[2]]
            and all(after["native"][key] == before["native"][key]
                    for key in ("platform", "runner", "machine", "versions", "selected", "layout"))
            and after["verification"]["matches"] is True
            and after["verification"]["expected_sha256"] == after["verification"]["actual_sha256"] == content
            and phases["after-generation"]["discovery_binding"]["status"] == "bound-candidate"
            and phases["after-generation"]["discovery_binding"]["precompilation_content_sha256"] == content,
            "Calibration SDK content relation differs")
    for label, ref in {**refs, **source_refs}.items():
        plan["inputs"]["calibration-sdk:" + label] = ref
    plan["calibration_sdk"] = dict(content_sha256=content, phases=refs, source_sha256=hashes,
                                    accepted=False, final_protocol_ready=False)
    plan["prior_costs"]["calibration_sdk"] = dict(
        phases=costs, scope="Each child interval includes phase serialization and child teardown; charged fully to each engine. "
        "Supervisor final receipt and interpreter teardown remain outside these intervals; no composed endpoint claim.")
    return plan["calibration_sdk"]
