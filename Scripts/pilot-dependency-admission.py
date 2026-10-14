#!/usr/bin/env python3
"""고정 공개 입력과 두 새 release 빌드로 의존성 입장 변경만 한 번 비교한다."""

import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import statistics
import time

SPEC = importlib.util.spec_from_file_location(
    "dependency_phases", Path(__file__).with_name("diagnose-query-phases.py"))
D = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(D)
PREP, PROJECT, BASE, require = D.PREP, D.PROJECT, D.BASE, D.require
REVISION = "7a638355dee84ef01a2b6d7e4e60eea850554abf"
UPSTREAM = "https://github.com/ictechgy/cartograph.git"
CHANGED = "Sources/CartographIndexStore/RawIndexStoreReader.swift"
ARMS = ["baseline", "candidate", "candidate", "baseline"] * 2
SETUP_SECONDS, CAPTURE_SECONDS = 1500, 300


def source_hashes(package):
    paths = [*package.glob("Package*.swift"), package / "Package.resolved"]
    for name in ("Sources", "Plugins"):
        root = package / name
        require(not root.is_symlink(), "Symlink product directory")
        for path in sorted(root.rglob("*")):
            require(not path.is_symlink(), "Symlink product input")
            if path.is_file() and path.name != "AGENTS.md":
                paths.append(path)
    require(all(path.is_file() and not path.is_symlink() for path in paths), "Missing product input")
    return {str(path.relative_to(package)): BASE.sha256(path) for path in sorted(paths)}


def verify_source(package, revision, out):
    head, head_measure = BASE.capture(["git", "rev-parse", "HEAD"], package, out / "head", 30)
    status, status_measure = BASE.capture(["git", "status", "--porcelain"], package, out / "status", 30)
    require(head.strip() == revision and not status, "Wrong source revision or dirty checkout")
    untracked = BASE.verify_untracked_build_inputs(package, out)
    return {"revision": revision, "input_sha256": source_hashes(package),
            "measurements": [head_measure, status_measure], "untracked": untracked}


def build_command(package, scratch, swiftc, jobs):
    return [str(swiftc.parent / "swift"), "build", "--package-path", str(package),
            "--scratch-path", str(scratch), "-c", "release", "--product", "cartograph",
            "--force-resolved-versions", "-j", str(jobs)]


def verify_build(receipt, package, revision, swiftc, jobs, snapshot):
    setup = receipt["setup"]
    require(setup["mode"] == "fresh-release-package-build", "Fresh release package build required")
    require(setup["source"]["revision"] == revision and not setup["source"]["working_tree_status"],
            "Build source revision or status mismatch")
    expected = {name: digest for name, digest in snapshot.items()
                if name in {"Package.swift", "Package.resolved"}
                or name.startswith("Sources/") and name.endswith(".swift")}
    require(setup["source"]["input_sha256"] == expected, "Build source hashes mismatch")
    build, discovery = setup["build"], setup["binary_discovery"]
    require(build["command"] == build_command(package, Path(setup["scratch"]), swiftc, jobs),
            "Release build arguments/compiler mismatch")
    for measurement in (build, discovery, receipt["measurement"]):
        require(measurement["returncode"] == 0 and not measurement["timed_out"], "Unsuccessful build receipt")
    require(Path(build["cwd"]) == package, "Build package mismatch")
    discovered = Path(Path(discovery["stdout"]).read_text().strip()) / "cartograph"
    binary = Path(receipt["binary"])
    within_scratch = binary.resolve().is_relative_to(Path(setup["scratch"]).resolve())
    require(binary == discovered and binary.is_file() and within_scratch,
            "Wrong binary or build scratch")
    require(BASE.sha256(binary) == receipt["binary_sha256"], "Binary bytes changed")
    require(receipt["measurement"]["command"] == [str(binary), "--version"], "Wrong version binary")


def unchanged(state):
    checked = PREP.verify_bytes(state["config"])
    if state.get("receipt_link"):
        link, target = state["receipt_link"]
        require(link.is_symlink() and link.readlink() == target and link.resolve() == target,
                "Baseline receipt link changed")
    for arm, source in state["sources"].items():
        require(source_hashes(Path(source["package"])) == source["input_sha256"], f"{arm} source bytes changed")
    return checked


def prepare(args, out, report, state):
    config, graph = PREP.admit(args.project_results, out, D.COMMAND_SECONDS)
    state.update(config=config, graph=graph, sources={})
    prior = PROJECT.read_json(args.project_results)["reused_tools"]
    setup = PROJECT.read_json(Path(prior["setup_results"]))
    swiftc = Path(prior["swiftc"])
    require(setup["toolchain"]["swiftc"] == str(swiftc), "Compiler path mismatch")
    require(BASE.sha256(swiftc) == prior["swiftc_sha256"], "Compiler bytes changed")
    require(not os.environ.get("SWIFT_EXEC") or Path(os.environ["SWIFT_EXEC"]).resolve() == swiftc.resolve(),
            "SWIFT_EXEC overrides the selected compiler")
    candidate = setup["cartograph"]
    command = candidate["setup"]["build"]["command"]
    jobs = int(command[-1])
    require(jobs > 0, "Invalid build job count")
    report.update(toolchain=setup["toolchain"], arms={"candidate": candidate}, sources=state["sources"],
                  compiler_sha256=prior["swiftc_sha256"])
    config["hashes"][str(swiftc.parent / "swift")] = BASE.sha256(swiftc.parent / "swift")
    source = verify_source(args.candidate_package, args.candidate_revision, out / "candidate-source")
    state["sources"]["candidate"] = {"package": str(args.candidate_package), **source}
    verify_build(candidate, args.candidate_package, args.candidate_revision, swiftc, jobs, source["input_sha256"])
    require(candidate["binary"] == config["cartograph"], "Wrong admitted candidate binary")
    require(not args.workspace.exists(), "Baseline workspace already exists; never reuse")
    args.workspace.mkdir(parents=True)
    (out / "setup").mkdir()
    # 빌드 트리는 공개 스캐너 밖에 두고 생산자의 원문 영수증만 공개 트리에 둔다.
    (args.workspace / "setup").symlink_to(out / "setup", target_is_directory=True)
    state["receipt_link"] = (args.workspace / "setup", out / "setup")
    package = args.workspace / "source"
    package.mkdir()
    git = ["git", "-c", "credential.helper=", "-c", "core.askPass="]
    report["source_acquisition"] = []
    previous = os.environ.get("GIT_TERMINAL_PROMPT")
    try:
        os.environ["GIT_TERMINAL_PROMPT"] = "0"
        for name, options in (("init", ["init"]),
                              ("fetch", ["fetch", "--depth", "1", UPSTREAM, REVISION]),
                              ("checkout", ["checkout", "--detach", "FETCH_HEAD"])):
            report["source_acquisition"].append(BASE.run(git + options, package, out / "setup" / name, 120))
    finally:
        if previous is None:
            os.environ.pop("GIT_TERMINAL_PROMPT", None)
        else:
            os.environ["GIT_TERMINAL_PROMPT"] = previous
    baseline_source = verify_source(package, REVISION, out / "baseline-source")
    state["sources"]["baseline"] = {"package": str(package), **baseline_source}
    left, right = baseline_source["input_sha256"], source["input_sha256"]
    require(left.keys() == right.keys() and {name for name in left if left[name] != right[name]} == {CHANGED},
            "Product source changes must be exactly RawIndexStoreReader.swift")
    require(not (args.workspace / "cartograph-release-build").exists(), "Baseline scratch must be fresh")
    report["baseline_setup_status"] = "running"
    BASE.save(out / "results.json", report)
    baseline = BASE.prepare_cartograph(argparse.Namespace(cartograph_package=package, jobs=jobs,
                                       setup_timeout=SETUP_SECONDS), swiftc, args.workspace)
    report["arms"]["baseline"] = baseline
    report["baseline_setup_status"] = "built"
    verify_build(baseline, package, REVISION, swiftc, jobs, left)
    report["sources_after_build"] = {}
    for arm, source in state["sources"].items():
        current = verify_source(Path(source["package"]), source["revision"], out / f"{arm}-source-after-build")
        require(current["input_sha256"] == source["input_sha256"], "Source changed during setup")
        report["sources_after_build"][arm] = current
    require(baseline["binary_sha256"] != candidate["binary_sha256"], "Identical baseline/candidate binary")
    require(Path(baseline["setup"]["scratch"]).resolve() != Path(candidate["setup"]["scratch"]).resolve(),
            "Baseline and candidate scratch overlap")
    config["hashes"].update({baseline["binary"]: baseline["binary_sha256"],
                             str(Path(D.__file__)): BASE.sha256(Path(D.__file__)),
                             str(Path(__file__).resolve()): BASE.sha256(Path(__file__))})
    report["input_hashes"] = config["hashes"]
    report["byte_checks"].append(unchanged(state))


def capture(args, out, report, state, deadline):
    config, graph = state["config"], state["graph"]
    request = max(config["requests"], key=lambda item: item["max_depth"])
    found, ambiguous, missing = graph["bindings"][request["seed"]], "fullMessage", "CartographPhaseMissing_7c460af8"
    cases = [("ambiguous", [ambiguous], ["ambiguous"], True, ["baseline", "candidate"]),
             ("missing", [missing], ["notFound"], True, ["baseline", "candidate"]),
             ("mixed-duplicate", [found, ambiguous, missing, found],
              ["found", "ambiguous", "notFound", "found"], True, ["baseline", "candidate"]),
             ("found", [found], ["found"], True, ARMS),
             ("found", [found], ["found"], False, ARMS)]
    BASE.save(out / "plan.json", {"cases": cases, "depth": request["max_depth"], "limit": 100000,
                                "command_timeout_seconds": D.COMMAND_SECONDS, "stream_cap_bytes": D.MAX_BYTES})
    expected = {}
    for name, names, statuses, enabled, schedule in cases:
        request_file = out / f"{name}-request.json"
        BASE.save(request_file, names)
        config["hashes"][str(request_file)] = BASE.sha256(request_file)
        for arm in schedule:
            require(time.monotonic() < deadline, "Shared capture deadline exceeded")
            report["byte_checks"].append(unchanged(state))
            command = [report["arms"][arm]["binary"], "query", "--batch", str(request_file),
                       "--depth", str(request["max_depth"]), "--limit", "100000",
                       *PROJECT.cg_options(Path(config["project"]), Path(config["store"]), Path(config["cg_config"]))]
            record = {"case": name, "arm": arm, "enabled": enabled, "ordinal": len(report["runs"])}
            stem = out / f"{record['ordinal']:02d}-{name}-{arm}-{int(enabled)}"
            report["runs"].append({**record, "measurement_path": str(stem) + ".json", "status": "running"})
            BASE.save(out / "results.json", report)
            try:
                measured, raw = D.capture(command, Path(config["project"]), stem, enabled)
            except (Exception, KeyboardInterrupt) as error:
                row = report["runs"][-1]
                row.update(status="failed", error=f"{type(error).__name__}: {error}")
                if Path(str(stem) + ".json").is_file():
                    row["measurement"] = PROJECT.read_json(Path(str(stem) + ".json"))
                raise
            report["runs"][-1].update(**measured, status="captured")
            BASE.save(out / "results.json", report)
            D.check_answer(raw, names, statuses, config, graph, request)
            expected.setdefault(name, raw)
            require(raw == expected[name], "stdout, exit, or ordinary-stderr parity failed")
            if enabled:
                phases = measured["phases"]
                require(set(phases) == set(D.PHASES), "Unknown or missing phase")
                require(all(value is not None for key, value in phases.items() if key != "found_facts"),
                        "Required query phase did not run")
                require((phases["found_facts"] is not None) == ("found" in statuses), "Found-only phase mismatch")
            require(time.monotonic() < deadline, "Shared capture deadline exceeded")
    report["byte_checks"].append(unchanged(state))
    # 양쪽 출력·오라클·입력 검증을 끝낸 뒤에만 수치를 해석한다.
    totals = []
    for record in report["runs"]:
        total = None
        wall = record["measurement"]["wall_seconds"]
        require(type(wall) in (int, float) and math.isfinite(wall) and wall >= 0, "Invalid process wall")
        if record["enabled"]:
            values = [value for value in record["phases"].values() if value is not None]
            require(all(type(value) in (int, float) and math.isfinite(value) and value >= 0 for value in values),
                    "Invalid phase duration")
            total = sum(values)
            require(math.isfinite(total) and total <= wall + D.ROUNDING_SECONDS, "Phase sum exceeds process wall")
        totals.append(total)
    for record, total in zip(report["runs"], totals):
        if total is not None:
            record["instrumented_phase_sum_seconds"] = total
    report["found_medians"] = {
        str(enabled): {arm: {key: statistics.median(record["measurement"][key] for record in report["runs"]
            if record["case"] == "found" and record["enabled"] == enabled and record["arm"] == arm)
            for key in ("wall_seconds", "user_seconds", "system_seconds", "wait4_maxrss_bytes")}
            for arm in ("baseline", "candidate")} for enabled in (True, False)}
    report["found_phase_medians_seconds"] = {arm: {phase: statistics.median(
        record["phases"][phase] for record in report["runs"]
        if record["case"] == "found" and record["enabled"] and record["arm"] == arm)
        for phase in D.PHASES} for arm in ("baseline", "candidate")}
    require(time.monotonic() < deadline, "Shared capture deadline exceeded")
    report.update(status="passed", output_parity_verified=True, frozen_answer_oracle_verified=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-results", type=Path, required=True)
    parser.add_argument("--candidate-package", type=Path, required=True)
    parser.add_argument("--candidate-revision", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.candidate_revision) is not None, "Exact candidate revision required")
    for key in ("project_results", "candidate_package", "workspace"):
        setattr(args, key, getattr(args, key).resolve())
    out = args.project_results.parent / "runs" / "dependency-admission-pilot"
    require(not out.exists(), "Pilot evidence already exists; never overwrite")
    out.mkdir(parents=True)
    report = {"schema_version": 1, "status": "running", "runs": [], "byte_checks": [],
              "baseline_revision": REVISION, "candidate_revision": args.candidate_revision,
              "superiority_claim": None, "role": "One fixed descriptive native comparison; no cold-cache claim",
              "schedule": ARMS, "setup_deadline_seconds": SETUP_SECONDS,
              "shared_capture_deadline_seconds": CAPTURE_SECONDS,
              "phase_sum_rounding_tolerance_seconds": D.ROUNDING_SECONDS,
              "cache": "Fresh release scratch per arm; global compiler/SDK/SwiftPM caches are not flushed",
              "phase_clock": "Instrumented wall estimates; observer overhead and residual gaps are not isolated",
              "outer_clock": "All original process wall, user/system CPU and wait4 max RSS retained"}
    state, stage = {}, "setup"
    driver_started = started = time.perf_counter()
    previous = {sig: signal.signal(sig, PREP.terminate_driver) for sig in (signal.SIGTERM, signal.SIGALRM)}
    stage_deadline = time.monotonic() + SETUP_SECONDS
    signal.alarm(SETUP_SECONDS)
    try:
        prepare(args, out, report, state)
        require(time.monotonic() < stage_deadline, "Shared setup deadline exceeded")
        report["setup_elapsed_seconds"] = time.perf_counter() - started
        stage, started = "capture", time.perf_counter()
        stage_deadline = time.monotonic() + CAPTURE_SECONDS
        signal.alarm(CAPTURE_SECONDS)
        capture(args, out, report, state, stage_deadline)
    except (Exception, KeyboardInterrupt) as error:
        report.update(status="failed", failed_stage=stage, error=f"{type(error).__name__}: {error}")
    finally:
        final_started = time.perf_counter()
        signal.alarm(0)
        report[f"{stage}_elapsed_seconds"] = time.perf_counter() - started
        try:
            if state.get("config"):
                report["final_byte_check"] = unchanged(state)
            require(time.monotonic() < stage_deadline, f"Shared {stage} deadline exceeded during final checks")
        except (Exception, KeyboardInterrupt) as error:
            report.update(status="failed", final_check_error=f"{type(error).__name__}: {error}")
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        report["final_check_elapsed_seconds"] = time.perf_counter() - final_started
        report["driver_elapsed_seconds"] = time.perf_counter() - driver_started
        BASE.save(out / "results.json", report)
    print(json.dumps({"status": report["status"], "results": str(out / "results.json")}, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
