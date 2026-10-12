#!/usr/bin/env python3
"""식별 정보 없이 허용한 하드웨어 필드와 실제 도구 버전만 기록한다."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import sys
import time
from typing import Callable

import psutil
import process_tree_measure as measurement

SYSCTL_KEYS = frozenset({
    "hw.machine", "hw.physicalcpu", "hw.logicalcpu", "hw.memsize", "machdep.cpu.brand_string",
    "kern.osrelease", "kern.osproductversion",
})
MACOS_SETUP_COMMANDS = {
    "xcode_version": ["/usr/bin/xcodebuild", "-version"],
    "swift_version": ["/usr/bin/xcrun", "swift", "--version"],
    "macos_sdk_version": ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
    "iphoneos_sdk_version": ["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-version"],
    "iphonesimulator_sdk_version": ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
}


def read_sysctl(key: str, runner: Callable[[list[str]], dict]) -> dict:
    """명시적으로 허용한 키만 조회하여 전체 sysctl 덤프나 호스트 식별을 막는다."""
    if key not in SYSCTL_KEYS:
        raise ValueError("This sysctl key is not permitted for nonidentifying machine evidence")
    return runner(["/usr/sbin/sysctl", "-n", key])


def macos_fields(runner: Callable[[list[str]], dict]) -> tuple[dict, list[dict]]:
    """네이티브 조회 실패를 임의의 플랫폼 추정값으로 대체하지 않는다."""
    fields, failures = {"os": "macOS"}, []
    mapping = {
        "architecture": "hw.machine", "physical_core_count": "hw.physicalcpu",
        "logical_core_count": "hw.logicalcpu", "ram_bytes": "hw.memsize",
        "cpu_model": "machdep.cpu.brand_string", "kernel_release": "kern.osrelease",
        "os_version": "kern.osproductversion",
    }
    for field, key in mapping.items():
        result = read_sysctl(key, runner)
        value = result.get("stdout", "").strip()
        if result.get("status") != "ok" or not value:
            fields[field] = None
            failures.append({"field": field, "reason": "whitelisted_sysctl_query_failed"})
            continue
        if field in ("physical_core_count", "logical_core_count", "ram_bytes"):
            try:
                value = int(value)
                if value <= 0:
                    raise ValueError("Nonpositive hardware count")
            except ValueError:
                fields[field] = None
                failures.append({"field": field, "reason": "invalid_positive_integer"})
                continue
        fields[field] = value
    return fields, failures


def linux_cpu_model(cpuinfo: Path) -> str | None:
    """CPU 모델 행만 추출하며 전체 cpuinfo나 Serial 행은 출력하지 않는다."""
    with cpuinfo.open(encoding="utf-8") as stream:
        for line in stream:
            key, separator, value = line.partition(":")
            if separator and key.strip() == "model name":
                return value.strip() or None
    return None


def linux_fields() -> tuple[dict, list[dict]]:
    """현재 Linux 호스트의 비식별 필드만 읽고 없는 CPU 모델은 명확히 남긴다."""
    fields = {"os": "Linux", "architecture": platform.machine(),
              "kernel_release": Path("/proc/sys/kernel/osrelease").read_text().strip(),
              "physical_core_count": psutil.cpu_count(logical=False),
              "logical_core_count": psutil.cpu_count(logical=True),
              "ram_bytes": psutil.virtual_memory().total,
              "cpu_model": linux_cpu_model(Path("/proc/cpuinfo"))}
    release = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator and key in ("ID", "VERSION_ID"):
            release[key] = value.strip('"')
    fields["os_distribution"] = release.get("ID")
    fields["os_version"] = release.get("VERSION_ID")
    failures = [{"field": field, "reason": "not_available_without_broader_probe"}
                for field, value in fields.items() if value is None or value == ""]
    return fields, failures


def collect(output: Path, concurrency_policy: str, cache_policy: str, runner_regime: str,
            collect_toolchain: bool = False) -> dict:
    """동시성·캐시 정책은 선언으로 구분하고 네이티브 도구는 읽기 전용 명령으로만 측정한다."""
    if not all(value.strip() for value in (concurrency_policy, cache_policy, runner_regime)):
        raise ValueError("Explicit concurrency, cache and runner/toolchain regime declarations are required")
    output.mkdir(exist_ok=False)
    measurements = {}

    def measured(command):
        key = command[-1].replace(".", "_") if command[0].endswith("sysctl") else "setup"
        stem = output / f"query-{key}"
        result = measurement.run(command, output, stem, timeout=15, mode="timing")
        stdout = (output / result["artifacts"]["stdout"]["name"]).read_text(encoding="utf-8").strip()
        measurements[key] = result
        return {"status": result["status"], "stdout": stdout}

    if sys.platform == "darwin":
        fields, failures = macos_fields(measured)
    elif sys.platform == "linux":
        fields, failures = linux_fields()
    else:
        raise ValueError("Only Linux and native macOS machine collection are supported")
    observed_at = datetime.now(timezone.utc).isoformat()
    load = list(os.getloadavg())
    toolchain = {}
    if collect_toolchain:
        if sys.platform != "darwin":
            raise ValueError("Native Xcode/SDK setup collection requires macOS; no platform substitutions")
        for label, command in MACOS_SETUP_COMMANDS.items():
            result = measurement.run(command, output, output / label, timeout=30, mode="timing")
            stdout = (output / result["artifacts"]["stdout"]["name"]).read_text(encoding="utf-8").strip()
            toolchain[label] = {"status": result["status"], "version_output": stdout, "measurement": result}
            if result["status"] != "ok" or not stdout:
                failures.append({"field": label, "reason": "existing_setup_command_failed"})
    result = {
        "schema_version": 1,
        "observed_at_utc": observed_at,
        "machine": fields,
        "load_average": {"one_minute": load[0], "five_minutes": load[1], "fifteen_minutes": load[2]},
        "declared_concurrency_policy": concurrency_policy,
        "declared_cache_policy": cache_policy,
        "declared_runner_toolchain_regime": runner_regime,
        "policy_enforcement_verified": False,
        "hardware_queries": measurements,
        "toolchain_versions": toolchain,
        "toolchain_collection_requested": collect_toolchain,
        "failures": failures,
        "helper_sha256": measurement.file_sha256(Path(__file__)),
        "limitations": [
            "Point-in-time load averages do not prove exclusive access or controlled background activity.",
            "Declared runner/cache/concurrency policies need independent enforcement and freeze verification.",
            "No hostname, username, serial, environment dump, process-command inventory or sysctl -a is collected.",
            "macos-latest/newest-Xcode remains a diagnostic pilot; a declared label alone does not pin a runner.",
            "Missing SDK/toolchain or CPU fields remain unresolved; do not guess or substitute another platform.",
        ],
    }
    measurement.write_json(output / "machine-manifest.json", result)
    return result


def main() -> None:
    """명시된 비식별 정책과 출력 위치를 받아 별도 설정 증거를 만든다."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--concurrency-policy", required=True)
    parser.add_argument("--cache-policy", required=True)
    parser.add_argument("--runner-regime", required=True)
    parser.add_argument("--collect-toolchain", action="store_true")
    args = parser.parse_args()
    result = collect(args.output_dir, args.concurrency_policy, args.cache_policy, args.runner_regime,
                     args.collect_toolchain)
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(1 if result["failures"] else 0)


if __name__ == "__main__":
    main()
