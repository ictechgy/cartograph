#!/usr/bin/env python3
"""동결된 공개 입력으로 opt-in 단계 계측의 출력 동등성과 비용만 진단한다."""

import argparse
import importlib.util
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import signal
import statistics
import time

SPEC = importlib.util.spec_from_file_location(
    "phase_prepared", Path(__file__).with_name("benchmark-prepared-indexstore-sessions.py"))
PREP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREP)
PROJECT, BASE, require = PREP.PROJECT, PREP.BASE, PREP.require
FLAG, PREFIX = "CARTOGRAPH_DIAGNOSTIC_QUERY_PHASES", b"cartograph-query-phases-v1 "
PHASES = ("cli_setup input_preparation raw_snapshot syntax_context graph_query_setup "
          "found_facts answer serialization cli_output").split()
SCHEDULE = [False, True, True, False] * 2
MAX_BYTES, DRIVER_SECONDS, COMMAND_SECONDS = 1024 * 1024, 300, 45
ROUNDING_SECONDS = 0.000001


FAILURE_STAGES = {
    "input_admission", "candidate_setup", "baseline_admission", "plan",
    "input_identity", "capture", "answer_contract", "parity", "phase_contract",
    "final_input_identity", "timing_contract", "summary",
}
FAILURE_GUARDS = {
    "Baseline toolchain differs": "baseline_toolchain_differs",
    "Exact baseline revision required": "baseline_revision_shape",
    "Baseline revision differs": "baseline_revision_differs",
    "Successful baseline release build required": "baseline_build_status",
    "Fresh release builds required": "release_build_mode",
    "Clean product source required": "product_source_dirty",
    "Product release build failed": "product_build_failed",
    "Product source membership changed": "product_source_membership",
    "Existing release package build required": "candidate_build_mode",
    "A successful full raw project validation is required": "project_validation",
    "Project revision changed": "project_revision",
    "Tool setup evidence changed": "tool_setup_identity",
    "Successful pinned comparator setup is required": "comparator_setup",
    "Project registration changed": "project_registration",
    "Index bytes changed": "index_identity",
    "Native discovery failed": "native_discovery",
    "Native graph no longer matches source oracle": "graph_oracle",
    "Query timed out": "query_timeout",
    "Shared driver deadline exceeded": "driver_timeout",
    "Query reached the output cap": "query_output_cap",
    "Expected one enabled diagnostic and none when disabled": "phase_record_count",
    "Malformed phase record": "phase_record_shape",
    "Non-finite or negative phase duration": "phase_record_value",
    "Query exit contract changed": "query_exit",
    "Invalid batch envelope": "batch_envelope",
    "Request order or duplicates changed": "request_order",
    "Unexpected found/ambiguous/missing result": "result_status",
    "Found answer failed frozen oracle": "found_oracle",
    "Ambiguity omitted the two source-authored fullMessage overloads": "ambiguity_oracle",
    "stdout, exit, or stderr-with-only-phase-line-removed parity failed": "answer_parity",
    "A required query phase did not run": "phase_missing",
    "Found-only phase ran or was skipped incorrectly": "found_phase",
    "Invalid process wall duration": "process_wall",
    "Phase sum exceeds process wall": "phase_sum",
    "Incomplete query pairs": "pair_membership",
    "Invalid paired wall or RSS": "paired_measurement",
}


def answer_identity(raw):
    return {
        "exit": raw[0],
        "stdout_bytes": len(raw[1]), "stdout_sha256": hashlib.sha256(raw[1]).hexdigest(),
        "clean_stderr_bytes": len(raw[2]), "clean_stderr_sha256": hashlib.sha256(raw[2]).hexdigest(),
    }


def failure_diagnostic(report, error):
    # 원문과 경로는 기존 결과 파일에만 남기고 공개 로그에는 고정 분류와 해시만 낸다.
    message = str(error)
    encoded = message.encode("utf-8", errors="replace")
    stage = report.get("diagnostic_stage")
    stage = stage if stage in FAILURE_STAGES else "unknown"
    code = FAILURE_GUARDS.get(message, "unknown")
    if message.startswith("Admitted file changed: "):
        code = "admitted_file_identity"
    category = ("timeout" if isinstance(error, TimeoutError) or code in {"query_timeout", "driver_timeout"}
                else "interrupted" if isinstance(error, KeyboardInterrupt)
                else "parity" if code == "answer_parity"
                else "execution" if stage == "capture"
                else "input" if stage in {"input_admission", "candidate_setup", "baseline_admission",
                                         "input_identity", "final_input_identity"}
                else "contract")
    kind = type(error).__name__
    result = {
        "schema_version": 1, "status": "failed", "stage": stage, "category": category,
        "error_type": kind if kind in {"ValueError", "KeyError", "TypeError", "RuntimeError",
            "TimeoutError", "FileNotFoundError", "PermissionError", "OSError",
            "JSONDecodeError", "KeyboardInterrupt"} else "Other",
        "error_code": code, "error_text_bytes": len(encoded),
        "error_sha256": hashlib.sha256(encoded).hexdigest(),
        "completed_runs": len(report.get("runs", [])),
    }
    workload = report.get("active_workload", {})
    if (workload.get("case") in {"ambiguous", "missing", "mixed", "found"}
            and workload.get("arm") in {"baseline", "candidate"}
            and type(workload.get("pair")) is int and 0 <= workload["pair"] < 8
            and type(workload.get("enabled")) is bool):
        result["workload"] = {key: workload[key] for key in ("case", "arm", "pair", "enabled")}
    runs = report.get("runs", [])
    if runs and "answer_identity" in runs[-1]:
        result["last_capture"] = runs[-1]["answer_identity"]
    if code == "answer_parity" and "parity_components" in report:
        result["parity_components"] = report["parity_components"]
    return result


def split_stderr(raw, enabled):
    lines = raw.splitlines(keepends=True)
    records = [line for line in lines if line.startswith(PREFIX)]
    require(len(records) == int(enabled), "Expected one enabled diagnostic and none when disabled")
    if not enabled:
        return raw, None
    pattern = PREFIX + b" ".join(name.encode() + rb"=(not_run|[0-9]+\.[0-9]{9})" for name in PHASES) + b"\n"
    matched = re.fullmatch(pattern, records[0])
    require(matched is not None, "Malformed phase record")
    phases = {name: None if value == b"not_run" else float(value) for name, value in zip(PHASES, matched.groups())}
    require(all(value is None or (math.isfinite(value) and value >= 0) for value in phases.values()),
            "Non-finite or negative phase duration")
    return b"".join(line for line in lines if not line.startswith(PREFIX)), phases


def capture(command, project, stem, enabled):
    previous, limits = os.environ.pop(FLAG, None), resource.getrlimit(resource.RLIMIT_FSIZE)
    try:
        if enabled:
            os.environ[FLAG] = "1"
        soft = min(MAX_BYTES, limits[0]) if limits[0] >= 0 else MAX_BYTES
        resource.setrlimit(resource.RLIMIT_FSIZE, (soft, limits[1]))
        try:
            measurement = BASE.run(command, project, stem, COMMAND_SECONDS)
        except KeyboardInterrupt:
            BASE.save(Path(str(stem) + ".json"), {"command": command, "cwd": str(project), "interrupted": True,
                      "stdout": str(stem) + ".stdout", "stderr": str(stem) + ".stderr"})
            raise
        except RuntimeError:
            measurement = PROJECT.read_json(Path(str(stem) + ".json"))
        require(not measurement["timed_out"], "Query timed out")
        stdout, stderr = (Path(measurement[name]).read_bytes() for name in ("stdout", "stderr"))
        require(max(len(stdout), len(stderr)) < soft, "Query reached the output cap")
        clean, phases = split_stderr(stderr, enabled)
        return {"measurement": measurement, "enabled": enabled, "phases": phases}, (measurement["returncode"], stdout, clean)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, limits)
        os.environ.pop(FLAG, None)
        if previous is not None:
            os.environ[FLAG] = previous


def check_answer(raw, names, statuses, config, graph, request):
    code, stdout, _ = raw
    require(type(code) is int and code == (64 if "notFound" in statuses else 0), "Query exit contract changed")
    document = json.loads(stdout)
    require(document.get("format") == "symbol-query-batch" and document.get("version") == 1, "Invalid batch envelope")
    results = document.get("results", [])
    require([item.get("requested") for item in results] == names, "Request order or duplicates changed")
    require([item.get("status") for item in results] == statuses, "Unexpected found/ambiguous/missing result")
    for item in results:
        if item["status"] == "found":
            parsed = PROJECT.parse_cg_query({**document, "results": [item]}, request, graph)
            require(PROJECT.grade(PROJECT.combined_answers(parsed["answer"], config["requests"]),
                                  config["oracle"])["passed"], "Found answer failed frozen oracle")
        elif item["status"] == "ambiguous":
            expected = {graph["bindings"][node["source_id"]] for node in config["oracle"]["nodes"]
                        if node["name"] == "fullMessage"}
            require(len(expected) == 2 and expected <= {node["usr"] for node in item.get("candidates", [])},
                    "Ambiguity omitted the two source-authored fullMessage overloads")


def admit_baseline(path, revision, setup, config, out):
    require(re.fullmatch(r"[0-9a-f]{40}", revision or "") is not None, "Exact baseline revision required")
    baseline = PROJECT.read_json(path)
    require(baseline.get("status") == "passed", "Successful baseline release build required")
    require(baseline["toolchain"] == setup["toolchain"], "Baseline toolchain differs")
    hashes = {str(path): BASE.sha256(path)}
    for label, evidence in (("baseline", baseline), ("candidate", setup)):
        product = evidence["cartograph"]
        build = product["setup"]
        require(build["mode"] == "fresh-release-package-build", "Fresh release builds required")
        source = build["source"]
        require(source["working_tree_status"] == "", "Clean product source required")
        if label == "baseline":
            require(source["revision"] == revision, "Baseline revision differs")
        require(build["build"]["returncode"] == 0 and not build["build"]["timed_out"],
                "Product release build failed")
        command = build["build"]["command"]
        package = Path(command[command.index("--package-path") + 1]).resolve()
        expected = source["input_sha256"]
        actual = [package / "Package.swift", package / "Package.resolved",
                  *sorted((package / "Sources").rglob("*.swift"))]
        require({str(item.relative_to(package)) for item in actual} == set(expected),
                "Product source membership changed")
        hashes.update({str(package / name): digest for name, digest in expected.items()})
        hashes[product["binary"]] = product["binary_sha256"]
    config["hashes"].update(hashes)
    PREP.verify_bytes(config)
    BASE.save(out / "baseline-admission.json", baseline)
    return baseline


def paired_summary(report):
    # 각 쌍의 비율과 각 팔의 절대 중앙값을 별도로 보존한다.
    rows = []
    for case in ("ambiguous", "missing", "mixed", "found"):
        for enabled in (False, True):
            arms = {arm: [row for row in report["runs"] if row["case"] == case
                         and row["enabled"] == enabled and row["arm"] == arm]
                    for arm in ("baseline", "candidate")}
            for records in arms.values():
                records.sort(key=lambda row: row["pair"])
            slots = [row["pair"] for row in arms["baseline"]]
            require(slots and len(slots) == len(set(slots))
                    and slots == [row["pair"] for row in arms["candidate"]], "Incomplete query pairs")
            result = {"case": case, "enabled": enabled, "pairs": len(arms["baseline"])}
            for arm, records in arms.items():
                values = {}
                for key in ("wall_seconds", "wait4_maxrss_bytes"):
                    samples = [row["measurement"][key] for row in records]
                    require(all(type(value) in (int, float) and math.isfinite(value) and value > 0
                                for value in samples), "Invalid paired wall or RSS")
                    values[key] = statistics.median(samples)
                if enabled:
                    values["phases_seconds"] = {
                        phase: (None if records[0]["phases"][phase] is None else
                                statistics.median(row["phases"][phase] for row in records))
                        for phase in PHASES}
                result[arm] = values
            result["median_paired_baseline_over_candidate_wall"] = statistics.median(
                left["measurement"]["wall_seconds"] / right["measurement"]["wall_seconds"]
                for left, right in zip(arms["baseline"], arms["candidate"]))
            rows.append(result)
    return {"cases": rows, "final_evidence": False,
            "scope": "One frozen project, fresh processes, fixed paired order, no cold-cache claim",
            "rss_scope": "wait4 process-lifetime high-water RSS, not process-tree or phase memory",
            "phase_scope": "Instrumented wall estimates; observer overhead is not isolated"}


def run(path, out, report, deadline=None, baseline_path=None, baseline_revision=None):
    report["diagnostic_stage"] = "input_admission"
    config, graph = PREP.admit(path, out, COMMAND_SECONDS)
    report["diagnostic_stage"] = "candidate_setup"
    setup = PROJECT.read_json(Path(PROJECT.read_json(path)["reused_tools"]["setup_results"]))
    require(setup["cartograph"]["setup"]["mode"] == "fresh-release-package-build", "Existing release package build required")
    config["hashes"][str(Path(__file__).resolve())] = BASE.sha256(Path(__file__))
    report.update(source=setup["cartograph"]["setup"]["source"], toolchain=setup["toolchain"],
                  runner_sha256=BASE.sha256(Path(__file__)), runs=[], byte_checks=[])
    baseline = None
    if baseline_path is not None:
        report["diagnostic_stage"] = "baseline_admission"
        baseline = admit_baseline(baseline_path, baseline_revision, setup, config, out)
        report["baseline_source"] = baseline["cartograph"]["setup"]["source"]
        report["baseline_binary_sha256"] = baseline["cartograph"]["binary_sha256"]
        report["candidate_binary_sha256"] = setup["cartograph"]["binary_sha256"]
    report["diagnostic_stage"] = "plan"
    request = max(config["requests"], key=lambda item: item["max_depth"])
    found, ambiguous, missing = graph["bindings"][request["seed"]], "fullMessage", "CartographPhaseMissing_7c460af8"
    cases = [("ambiguous", [ambiguous], ["ambiguous"], [False, True]),
             ("missing", [missing], ["notFound"], [False, True]),
             ("mixed", [found, ambiguous, missing, found], ["found", "ambiguous", "notFound", "found"], [False, True]),
             ("found", [found], ["found"], SCHEDULE)]
    if baseline is not None:
        report["paired_workload"] = {"project_revision": PROJECT.PROJECT_REVISION,
                                     "depth": request["max_depth"], "limit": 100000,
                                     "index_fingerprint": config["index_fingerprint"],
                                     "frozen_input_sha256": PROJECT.FROZEN_HASHES}
    BASE.save(out / "plan.json", {"cases": cases, "depth": request["max_depth"], "limit": 100000,
                                "command_timeout_seconds": COMMAND_SECONDS, "stream_cap_bytes": MAX_BYTES})
    for name, names, statuses, schedule in cases:
        request_file = out / f"{name}-request.json"
        BASE.save(request_file, names)
        config["hashes"][str(request_file)] = BASE.sha256(request_file)
        command = [config["cartograph"], "query", "--batch", str(request_file), "--depth", str(request["max_depth"]),
                   "--limit", "100000", *PROJECT.cg_options(Path(config["project"]), Path(config["store"]),
                                                            Path(config["cg_config"]))]
        expected = None
        for number, enabled in enumerate(schedule):
            order = ["candidate"] if baseline is None else (
                ["baseline", "candidate"] if number % 2 == 0 else ["candidate", "baseline"])
            for arm in order:
                arm_command = command if arm == "candidate" else [baseline["cartograph"]["binary"], *command[1:]]
                stem = f"{name}-{number}" if baseline is None else f"{name}-{number}-{arm}"
                report["active_workload"] = {"case": name, "arm": arm, "pair": number, "enabled": enabled}
                report["diagnostic_stage"] = "input_identity"
                report["byte_checks"].append(PREP.verify_bytes(config))
                report["diagnostic_stage"] = "capture"
                measured, raw = capture(arm_command, Path(config["project"]), out / stem, enabled)
                report["runs"].append({"case": name, **({"arm": arm, "pair": number} if baseline else {}),
                                       **measured, "answer_identity": answer_identity(raw)})
                BASE.save(out / "results.json", report)
                report["diagnostic_stage"] = "answer_contract"
                check_answer(raw, names, statuses, config, graph, request)
                expected = raw if expected is None else expected
                report["diagnostic_stage"] = "parity"
                if raw != expected:
                    report["parity_components"] = {
                        "exitEqual": raw[0] == expected[0], "stdoutEqual": raw[1] == expected[1],
                        "cleanStderrEqual": raw[2] == expected[2]}
                require(raw == expected, "stdout, exit, or stderr-with-only-phase-line-removed parity failed")
                report["diagnostic_stage"] = "phase_contract"
                if enabled:
                    require(all(value is not None for key, value in measured["phases"].items() if key != "found_facts"),
                            "A required query phase did not run")
                    require((measured["phases"]["found_facts"] is not None) == ("found" in statuses),
                            "Found-only phase ran or was skipped incorrectly")
    report["diagnostic_stage"] = "final_input_identity"
    report["byte_checks"].append(PREP.verify_bytes(config))
    report["diagnostic_stage"] = "timing_contract"
    require(deadline is None or time.monotonic() < deadline, "Shared driver deadline exceeded")
    # 동등성과 입력 검사를 모두 통과한 뒤에만 내부 시간을 해석한다.
    totals = []
    for record in report["runs"]:
        wall = record["measurement"]["wall_seconds"]
        require(type(wall) in (int, float) and math.isfinite(wall) and wall >= 0, "Invalid process wall duration")
        total = None
        if record["enabled"]:
            total = sum(value for value in record["phases"].values() if value is not None)
            require(math.isfinite(total) and total <= wall + ROUNDING_SECONDS, "Phase sum exceeds process wall")
        totals.append(total)
    for record, total in zip(report["runs"], totals):
        if total is not None:
            record["instrumented_phase_sum_seconds"] = total
            record["startup_residual_observer_seconds"] = max(0.0, record["measurement"]["wall_seconds"] - total)
    medians = {str(enabled): statistics.median(record["measurement"]["wall_seconds"] for record in report["runs"]
               if record["case"] == "found" and record["enabled"] == enabled
               and record.get("arm", "candidate") == "candidate") for enabled in (False, True)}
    require(deadline is None or time.monotonic() < deadline, "Shared driver deadline exceeded")
    if baseline is not None:
        report["diagnostic_stage"] = "summary"
        report["paired_summary"] = paired_summary(report)
    report.update(status="passed", output_parity_verified=True, found_wall_medians_seconds=medians,
                  enabled_minus_disabled_median_seconds=medians["True"] - medians["False"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-results", type=Path, required=True)
    parser.add_argument("--baseline-setup-results", type=Path)
    parser.add_argument("--baseline-revision")
    args = parser.parse_args()
    require((args.baseline_setup_results is None) == (args.baseline_revision is None),
            "Baseline setup results and exact revision must be supplied together")
    path = args.project_results.resolve()
    out = path.parent / "runs" / "query-phases"
    require(not out.exists(), "Diagnostic evidence already exists; never overwrite")
    out.mkdir(parents=True)
    report = {"schema_version": 1, "status": "running", "superiority_claim": None,
              "role": "Same-input opt-in diagnostic; no baseline comparison or cold-cache claim",
              "phase_clock": "Instrumented wall estimates; startup, residual gaps and observer overhead are not isolated",
              "outer_clock": "Full process wall, user/system CPU and wait4 max RSS retained",
              "overhead": "Fixed AB/BA absent/1 found schedule; difference includes noise, not isolated observer cost",
              "phase_sum_rounding_tolerance_seconds": ROUNDING_SECONDS,
              "schedule": SCHEDULE, "shared_driver_deadline_seconds": DRIVER_SECONDS}
    if args.baseline_setup_results:
        report["role"] = "Exact-revision same-input paired diagnostic; no final superiority claim"
        report["arm_schedule"] = "Baseline/candidate then candidate/baseline, repeated per case slot"
    previous = {sig: signal.signal(sig, PREP.terminate_driver) for sig in (signal.SIGTERM, signal.SIGALRM)}
    signal.alarm(DRIVER_SECONDS)
    started = time.perf_counter()
    deadline = time.monotonic() + DRIVER_SECONDS
    try:
        run(path, out, report, deadline,
            args.baseline_setup_results.resolve() if args.baseline_setup_results else None, args.baseline_revision)
    except (Exception, KeyboardInterrupt) as error:
        report.update(status="failed", error=f"{type(error).__name__}: {error}")
        report["failure_diagnostic"] = failure_diagnostic(report, error)
    finally:
        signal.alarm(0)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    report["diagnostic_elapsed_seconds"] = time.perf_counter() - started
    BASE.save(out / "results.json", report)
    if report["status"] == "passed" and "paired_summary" in report:
        print("QueryProjectionTiming " + json.dumps({
            **report["paired_summary"], "workload": report["paired_workload"],
            "baseline_revision": report["baseline_source"]["revision"],
            "candidate_revision": report["source"]["revision"],
            "baseline_binary_sha256": report["baseline_binary_sha256"],
            "candidate_binary_sha256": report["candidate_binary_sha256"],
            "clean_fresh_release_builds": True,
            "output_and_input_identity_verified": report["output_parity_verified"]}, sort_keys=True))
    if report["status"] == "failed":
        print("QueryProjectionFailure " + json.dumps(report["failure_diagnostic"], sort_keys=True))
    print(json.dumps({"status": report["status"], "results": str(out / "results.json")}, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
