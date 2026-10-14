#!/usr/bin/env python3
"""동결된 공개 입력으로 opt-in 단계 계측의 출력 동등성과 비용만 진단한다."""

import argparse
import importlib.util
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


def run(path, out, report, deadline=None):
    config, graph = PREP.admit(path, out, COMMAND_SECONDS)
    setup = PROJECT.read_json(Path(PROJECT.read_json(path)["reused_tools"]["setup_results"]))
    require(setup["cartograph"]["mode"] == "fresh-release-package-build", "Existing release package build required")
    config["hashes"][str(Path(__file__).resolve())] = BASE.sha256(Path(__file__))
    report.update(source=setup["cartograph"]["source"], toolchain=setup["toolchain"],
                  runner_sha256=BASE.sha256(Path(__file__)), runs=[], byte_checks=[])
    request = max(config["requests"], key=lambda item: item["max_depth"])
    found, ambiguous, missing = graph["bindings"][request["seed"]], "fullMessage", "CartographPhaseMissing_7c460af8"
    cases = [("ambiguous", [ambiguous], ["ambiguous"], [False, True]),
             ("missing", [missing], ["notFound"], [False, True]),
             ("mixed", [found, ambiguous, missing, found], ["found", "ambiguous", "notFound", "found"], [False, True]),
             ("found", [found], ["found"], SCHEDULE)]
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
            report["byte_checks"].append(PREP.verify_bytes(config))
            measured, raw = capture(command, Path(config["project"]), out / f"{name}-{number}", enabled)
            report["runs"].append({"case": name, **measured})
            BASE.save(out / "results.json", report)
            check_answer(raw, names, statuses, config, graph, request)
            expected = raw if expected is None else expected
            require(raw == expected, "stdout, exit, or stderr-with-only-phase-line-removed parity failed")
            if enabled:
                require(all(value is not None for key, value in measured["phases"].items() if key != "found_facts"),
                        "A required query phase did not run")
                require((measured["phases"]["found_facts"] is not None) == ("found" in statuses),
                        "Found-only phase ran or was skipped incorrectly")
    report["byte_checks"].append(PREP.verify_bytes(config))
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
               if record["case"] == "found" and record["enabled"] == enabled) for enabled in (False, True)}
    require(deadline is None or time.monotonic() < deadline, "Shared driver deadline exceeded")
    report.update(status="passed", output_parity_verified=True, found_wall_medians_seconds=medians,
                  enabled_minus_disabled_median_seconds=medians["True"] - medians["False"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-results", type=Path, required=True)
    path = parser.parse_args().project_results.resolve()
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
    previous = {sig: signal.signal(sig, PREP.terminate_driver) for sig in (signal.SIGTERM, signal.SIGALRM)}
    signal.alarm(DRIVER_SECONDS)
    started = time.perf_counter()
    deadline = time.monotonic() + DRIVER_SECONDS
    try:
        run(path, out, report, deadline)
    except (Exception, KeyboardInterrupt) as error:
        report.update(status="failed", error=f"{type(error).__name__}: {error}")
    finally:
        signal.alarm(0)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    report["diagnostic_elapsed_seconds"] = time.perf_counter() - started
    BASE.save(out / "results.json", report)
    print(json.dumps({"status": report["status"], "results": str(out / "results.json")}, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
