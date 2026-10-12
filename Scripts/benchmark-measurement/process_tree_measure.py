#!/usr/bin/env python3
"""시점별 워크로드 RSS와 종료 결과를 보존하는 독립 측정 도우미."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import time
import threading
from typing import Any

import psutil

SCHEMA_VERSION = 2
SAMPLE_CHUNK_LIMIT_BYTES = 6 * 1024 * 1024
LIMITATIONS = [
    "Observed maximum of sampled near-simultaneous process-tree RSS sums; never a sum of per-process peaks.",
    "Finite sampling misses peaks and short-lived descendants: treat the observed peak as a lower-bound estimate.",
    "RSS reads in a sweep are sequential, not an atomic snapshot; sweep skew can also bias the sum upward.",
    "Shared pages are counted once per resident process; RSS is not unique physical-memory usage.",
    "Sampler overhead and scheduler delay remain in workload wall time; requested resolution is not guaranteed.",
    "Only launched workload descendants are recorded; no host, user, environment or unrelated command-line inventory.",
]


def file_sha256(path: Path) -> str:
    """원문 출력이 바뀌지 않았는지 확인할 수 있게 바이트 해시를 남긴다."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    """기존 실패 결과를 덮어쓰지 않도록 새 파일만 생성한다."""
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


class SampleWriter:
    """완전한 샘플 행을 유지하면서 공개 파일 한도를 넘기지 않도록 회전한다."""

    def __init__(self, stem: Path, limit_bytes: int = SAMPLE_CHUNK_LIMIT_BYTES):
        if type(limit_bytes) is not int or limit_bytes <= 0:
            raise ValueError("Sample chunk limit must be a positive integer")
        self.stem = stem
        self.limit_bytes = limit_bytes
        self.chunks = []
        self.stream = None
        self.path = None
        self.bytes = 0
        self.samples = 0

    def __enter__(self):
        return self

    def _close_chunk(self):
        if self.stream is not None:
            self.stream.close()
            self.chunks.append({"name": self.path.name, "sha256": file_sha256(self.path),
                                "bytes": self.bytes, "sample_count": self.samples})
            self.stream = None

    def write(self, sample: dict) -> None:
        """행 분할이나 표본 생략 없이 새 청크를 생성하고 초대형 단일 행은 실패시킨다."""
        encoded = (json.dumps(sample, sort_keys=True) + "\n").encode()
        if len(encoded) > self.limit_bytes:
            raise ValueError("One complete sample exceeds chunk limit; preserve failure and revise before freeze")
        if self.stream is not None and self.bytes + len(encoded) > self.limit_bytes:
            self._close_chunk()
        if self.stream is None:
            self.path = Path(str(self.stem) + f".samples.{len(self.chunks) + 1:04d}.jsonl")
            self.stream = self.path.open("xb")
            self.bytes = 0
            self.samples = 0
        self.stream.write(encoded)
        self.stream.flush()
        self.bytes += len(encoded)
        self.samples += 1

    def __exit__(self, exc_type, exc_value, traceback):
        self._close_chunk()


def _positive(value: float, name: str) -> float:
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be finite and positive")
    return value


def _subreaper() -> bool:
    if sys.platform != "linux":
        return False
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        number = ctypes.get_errno()
        raise OSError(number, "Cannot establish isolated workload subreaper; measurement aborted")
    return True


class TreeTracker:
    """부모 종료와 세션 분리 뒤에도 같은 프로세스 인스턴스만 추적한다."""

    def __init__(self, supervisor: int, root: int, subreaper: bool):
        self.supervisor = psutil.Process(supervisor)
        self.subreaper = subreaper
        self.processes: dict[tuple[int, float], psutil.Process] = {}
        self.ids: dict[tuple[int, float], int] = {}
        self.errors: set[str] = set()
        try:
            self._add(psutil.Process(root))
        except psutil.NoSuchProcess:
            # 매우 짧은 루트는 이미 종료될 수 있고 Linux 고아는 supervisor에서 발견한다.
            self.errors.add("root_exited_before_first_identity_read")

    def _add(self, process: psutil.Process) -> None:
        try:
            key = (process.pid, process.create_time())
            if key not in self.processes:
                self.processes[key] = process
                self.ids[key] = len(self.ids) + 1
        except psutil.NoSuchProcess:
            return
        except psutil.AccessDenied:
            self.errors.add("access_denied_during_identity_read")

    def discover(self) -> None:
        """새 세션도 부모 관계로 발견하고 이미 발견한 고아는 계속 추적한다."""
        anchors = [self.supervisor] if self.subreaper else list(self.processes.values())
        for process in anchors:
            try:
                if process.is_running():
                    for child in process.children(recursive=True):
                        self._add(child)
            except psutil.NoSuchProcess:
                continue
            except psutil.AccessDenied:
                self.errors.add("access_denied_during_descendant_discovery")

    def live(self) -> list[psutil.Process]:
        """PID 재사용과 좀비를 살아 있는 워크로드로 오인하지 않는다."""
        result = []
        for process in self.processes.values():
            try:
                if process.is_running() and process.status() != psutil.STATUS_ZOMBIE:
                    result.append(process)
            except psutil.NoSuchProcess:
                continue
            except psutil.AccessDenied:
                self.errors.add("access_denied_during_liveness_check")
                result.append(process)
        return result

    def sample(self, started: float) -> dict:
        """피크 합산 대신 한 짧은 읽기 구간의 RSS 합계와 구간 폭을 남긴다."""
        begin = time.perf_counter()
        self.discover()
        members = []
        for key, process in list(self.processes.items()):
            try:
                if process.is_running() and process.status() != psutil.STATUS_ZOMBIE:
                    rss = process.memory_info().rss
                    members.append({"process_id": self.ids[key], "pid": process.pid, "create_time": key[1], "rss_bytes": rss})
            except psutil.NoSuchProcess:
                continue
            except psutil.AccessDenied:
                self.errors.add("access_denied_during_rss_read")
        end = time.perf_counter()
        return {
            "start_seconds": begin - started,
            "end_seconds": end - started,
            "rss_bytes": sum(member["rss_bytes"] for member in members),
            "process_count": len(members),
            "processes": members,
        }

    def signal(self, process: psutil.Process, sig: int) -> None:
        """psutil의 생성 시각 검사를 사용하여 재사용된 PID에는 신호를 보내지 않는다."""
        try:
            process.send_signal(sig)
        except psutil.NoSuchProcess:
            return
        except psutil.AccessDenied:
            self.errors.add(f"access_denied_sending_signal_{sig}")


def _reap_orphans(root: subprocess.Popen, subreaper: bool) -> None:
    root.poll()
    if not subreaper or root.returncode is None:
        return
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
            if not pid:
                return
        except ChildProcessError:
            return


def _cleanup(tracker: TreeTracker, root: subprocess.Popen, grace: float) -> dict:
    started = time.perf_counter()
    tracker.discover()
    for process in tracker.live():
        tracker.signal(process, signal.SIGTERM)
    until = time.perf_counter() + grace
    while tracker.live() and time.perf_counter() < until:
        tracker.discover()
        _reap_orphans(root, tracker.subreaper)
        time.sleep(min(0.01, grace))
    # 부모부터 멈추고 다시 발견하여 종료 도중 생성된 별도 세션도 제거한다.
    freeze_deadline = time.perf_counter() + 2
    frozen: set[int] = set()
    while time.perf_counter() < freeze_deadline:
        tracker.discover()
        newly_live = [process for process in tracker.live() if hash(process) not in frozen]
        if not newly_live:
            break
        for process in newly_live:
            tracker.signal(process, signal.SIGSTOP)
            frozen.add(hash(process))
    for process in tracker.live():
        tracker.signal(process, signal.SIGKILL)
    until = time.perf_counter() + 2
    while time.perf_counter() < until:
        tracker.discover()
        for process in tracker.live():
            tracker.signal(process, signal.SIGKILL)
        _reap_orphans(root, tracker.subreaper)
        if not tracker.live() and root.poll() is not None:
            break
        time.sleep(0.01)
    return {
        "seconds": time.perf_counter() - started,
        "remaining_observed_pids": sorted(process.pid for process in tracker.live()),
        "method": "identity_checked_individual_TERM_then_STOP_discover_KILL; process-group independent",
    }


def _timing_worker(config: dict) -> dict:
    """정상 실행 동안 RSS 조회나 트리 순회 없이 커널의 자식 종료를 기다린다."""
    subreaper = _subreaper()
    stem = Path(config["stem"])
    paths = {kind: Path(str(stem) + suffix) for kind, suffix in (
        ("stdout", ".stdout"), ("stderr", ".stderr"), ("command", ".command.json"), ("result", ".json")
    )}
    cancelled = []
    state = {"failure": None, "timed_out": False, "cleanup": None}

    def cancel(signum, frame):
        cancelled.append(signum)
        raise InterruptedError("Workload cancelled")

    def deadline(signum, frame):
        state["timed_out"] = True
        raise TimeoutError("Workload deadline reached")

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, cancel)
    signal.signal(signal.SIGALRM, deadline)
    root = None
    tracker = None
    started = time.perf_counter()
    root_elapsed = None
    try:
        with paths["stdout"].open("xb") as out, paths["stderr"].open("xb") as err:
            started = time.perf_counter()
            root = subprocess.Popen(config["command"], cwd=config["cwd"], stdout=out, stderr=err,
                                    start_new_session=True, env=config.get("environment"))
            tracker = TreeTracker(os.getpid(), root.pid, subreaper)
            remaining = max(0.000001, config["timeout"] - (time.perf_counter() - started))
            signal.setitimer(signal.ITIMER_REAL, remaining)
            try:
                root.wait()
                root_elapsed = time.perf_counter() - started
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
            # 정상 구간 밖에서만 고아를 검사한다. 남은 작업을 빠른 완료로 채점하지 않는다.
            tracker.discover()
            _reap_orphans(root, subreaper)
            if tracker.live():
                state["failure"] = "unexpected_descendants_after_root_exit"
                state["cleanup"] = _cleanup(tracker, root, config["grace"])
    except BaseException as exc:
        signal.setitimer(signal.ITIMER_REAL, 0)
        state["failure"] = ("cancelled" if cancelled else "timeout" if state["timed_out"]
                            else type(exc).__name__)
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, lambda signum, frame: cancelled.append(signum))
        if root is not None and tracker is not None:
            state["cleanup"] = _cleanup(tracker, root, config["grace"])
    if root is not None:
        root.poll()
    root_code = root.returncode if root else None
    if state["failure"] is None and root_code != 0:
        state["failure"] = "nonzero_exit"
    errors = sorted(tracker.errors - {"root_exited_before_first_identity_read"}) if tracker else []
    if errors and state["failure"] is None:
        state["failure"] = "incomplete_cleanup_inspection"
    if state["cleanup"] and state["cleanup"]["remaining_observed_pids"]:
        state["failure"] = "cleanup_incomplete"
    result = {
        "schema_version": SCHEMA_VERSION,
        "measurement_mode": "timing",
        "primary_timing_eligible": state["failure"] is None,
        "status": "ok" if state["failure"] is None else "failed",
        "failure": state["failure"],
        "returncode": 124 if state["timed_out"] else (128 + cancelled[0] if cancelled else root_code),
        "root_returncode": root_code,
        "timed_out": state["timed_out"],
        "wall_seconds": root_elapsed if root_elapsed is not None else time.perf_counter() - started,
        "root_exit_observed_seconds": root_elapsed,
        "supervision_total_seconds": time.perf_counter() - started,
        "cleanup": state["cleanup"],
        "rss": None,
        "sampling_during_timing": False,
        "periodic_tree_discovery_during_timing": False,
        "wait_method": "blocking_Popen_wait_with_one_POSIX_ITIMER_REAL_deadline",
        "containment": {
            "linux_subreaper": subreaper,
            "unobserved_reparenting_gap": not subreaper,
            "discovery": "only_after_root_exit_or_on_timeout_or_cancellation",
            "read_errors": errors,
            "qualification": "Timing requires the workload root to wait for all children. Linux adopts orphans. "
                             "macOS may miss independently reparented children; no complete containment claim.",
        },
        "limitations": [
            "No RSS collection and no periodic process-tree scan in the timed interval.",
            "One root identity read and one deadline timer remain; calibrate their residual overhead.",
            "Post-exit cleanup inspection is outside successful wall_seconds; any live descendant fails the run.",
            "Memory must be measured in separately randomized matched runs; never reuse memory-run timings as primary.",
        ],
        "platform": sys.platform,
        "psutil_version": psutil.__version__,
        "helper_sha256": file_sha256(Path(__file__)),
        "artifacts": {kind: {"name": path.name, "sha256": file_sha256(path)}
                      for kind, path in paths.items() if kind != "result" and path.exists()},
    }
    write_json(paths["result"], result)
    return result


def _worker(config: dict) -> dict:
    if sys.platform not in ("darwin", "linux"):
        raise ValueError("Only macOS and Linux are supported")
    if config["mode"] == "timing":
        return _timing_worker(config)
    subreaper = _subreaper()
    stem = Path(config["stem"])
    paths = {kind: Path(str(stem) + suffix) for kind, suffix in (
        ("stdout", ".stdout"), ("stderr", ".stderr"), ("command", ".command.json"), ("result", ".json")
    )}
    cancelled = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda signum, frame: cancelled.append(signum))
    root = None
    tracker = None
    samples = []
    failure = None
    timed_out = False
    cleanup = None
    root_exit_seconds = None
    sample_writer = SampleWriter(stem)
    started = time.perf_counter()
    try:
        with paths["stdout"].open("xb") as out, paths["stderr"].open("xb") as err, \
                sample_writer:
            root = subprocess.Popen(config["command"], cwd=config["cwd"], stdout=out, stderr=err,
                                    start_new_session=True, env=config.get("environment"))
            tracker = TreeTracker(os.getpid(), root.pid, subreaper)
            next_sample = started
            while True:
                now = time.perf_counter()
                if now >= next_sample:
                    sample = tracker.sample(started)
                    samples.append({key: value for key, value in sample.items() if key != "processes"})
                    sample_writer.write(sample)
                    next_sample = now + config["interval"]
                tracker.discover()
                root.poll()
                if root.returncode is not None and root_exit_seconds is None:
                    root_exit_seconds = time.perf_counter() - started
                _reap_orphans(root, subreaper)
                tracker.discover()
                if root.returncode is not None and not tracker.live():
                    break
                if cancelled or time.perf_counter() - started >= config["timeout"]:
                    timed_out = not cancelled
                    failure = "cancelled" if cancelled else "timeout"
                    cleanup = _cleanup(tracker, root, config["grace"])
                    break
                time.sleep(min(0.002, max(0, next_sample - time.perf_counter())))
    except BaseException as exc:
        failure = type(exc).__name__
        # 원문 예외 문자열은 로컬 사용자명이나 환경 값을 포함할 수 있어 기록하지 않는다.
        if root is not None and tracker is not None:
            cleanup = _cleanup(tracker, root, config["grace"])
    elapsed = time.perf_counter() - started
    if root is not None:
        root.poll()
    observed_errors = sorted(tracker.errors) if tracker else []
    root_code = root.returncode if root else None
    if failure is None and root_code != 0:
        failure = "nonzero_exit"
    if observed_errors and failure is None:
        failure = "incomplete_process_observation"
    if cleanup and cleanup["remaining_observed_pids"]:
        failure = "cleanup_incomplete"
    gaps = [b["start_seconds"] - a["start_seconds"] for a, b in zip(samples, samples[1:])]
    result = {
        "schema_version": SCHEMA_VERSION,
        "status": "ok" if failure is None else "failed",
        "failure": failure,
        "returncode": 124 if timed_out else (128 + cancelled[0] if cancelled else root_code),
        "root_returncode": root_code,
        "timed_out": timed_out,
        "wall_seconds": elapsed,
        "measurement_mode": "memory",
        "primary_timing_eligible": False,
        "timing_qualification": "RSS-observed memory-run timing only; excluded from primary endpoint",
        "root_exit_observed_seconds": root_exit_seconds,
        "cleanup": cleanup,
        "rss": {
            "metric": "observed_sampled_near_simultaneous_process_tree_rss_bytes",
            "sample_chunks": sample_writer.chunks,
            "sample_total_bytes": sum(chunk["bytes"] for chunk in sample_writer.chunks),
            "sample_chunk_limit_bytes": SAMPLE_CHUNK_LIMIT_BYTES,
            "observed_peak_bytes": max((sample["rss_bytes"] for sample in samples), default=0),
            "sample_count": len(samples),
            "requested_interval_seconds": config["interval"],
            "actual_interval_median_seconds": statistics.median(gaps) if gaps else None,
            "actual_interval_max_seconds": max(gaps) if gaps else None,
            "sweep_max_seconds": max((s["end_seconds"] - s["start_seconds"] for s in samples), default=0),
            "observed_process_count": len(tracker.processes) if tracker else 0,
            "read_errors": observed_errors,
            "limitations": LIMITATIONS,
        },
        "containment": {
            "linux_subreaper": subreaper,
            "discovery": "isolated_subreaper_descendants" if subreaper else "observed_ancestry_retained_by_identity",
            "unobserved_reparenting_gap": not subreaper,
            "qualification": (
                "Linux adopts orphaned workload descendants in this dedicated helper process."
                if subreaper else
                "macOS polling cannot discover a descendant whose entire ancestry disappears between polls. "
                "Adapters must wait for descendants or register them cooperatively; this is not a sandbox."
            ),
        },
        "platform": sys.platform,
        "psutil_version": psutil.__version__,
        "helper_sha256": file_sha256(Path(__file__)),
        "artifacts": {kind: {"name": path.name, "sha256": file_sha256(path)}
                      for kind, path in paths.items() if kind != "result" and path.exists()},
    }
    write_json(paths["result"], result)
    return result


def run(command: list[str], cwd: Path, stem: Path, timeout: float = 300,
        interval: float = 0.01, grace: float = 0.25, mode: str = "timing",
        environment: dict[str, str] | None = None) -> dict:
    """측정자를 별도 프로세스로 격리하여 호출자의 자식 수거 정책을 바꾸지 않는다.

    명시적으로 전달한 워크로드 명령과 원문 출력은 보존한다. 호출자는 자격증명이나
    개인 식별 경로가 없는 합성/벤치마크 명령만 전달해야 한다.
    """
    if not command or not all(isinstance(item, str) for item in command):
        raise ValueError("command must be a nonempty list of strings")
    if mode not in ("timing", "memory"):
        raise ValueError("mode must be timing or memory")
    stem = Path(stem).resolve()
    stem.parent.mkdir(parents=True, exist_ok=True)
    config = {"command": command, "cwd": str(Path(cwd).resolve()), "stem": str(stem),
              "timeout": _positive(timeout, "timeout"), "interval": _positive(interval, "interval"),
              "grace": _positive(grace, "grace"), "mode": mode, "environment": environment}
    if list(stem.parent.glob(stem.name + ".samples.*.jsonl")):
        raise FileExistsError("Preserve existing rotated sample evidence; choose a new stem")
    for suffix in (".json", ".stdout", ".stderr", ".samples.jsonl", ".command.json"):
        if Path(str(stem) + suffix).exists():
            raise FileExistsError(f"Preserve existing evidence; choose a new stem: {stem.name}{suffix}")
    write_json(Path(str(stem) + ".command.json"), {"command": command, "cwd": config["cwd"],
                                                  "timeout_seconds": timeout, "interval_seconds": interval,
                                                  "measurement_mode": mode})
    began = time.perf_counter()
    worker = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--worker"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, start_new_session=True)
    previous_handlers = {}
    if threading.current_thread() is threading.main_thread():
        def forward(signum, frame):
            try:
                worker.send_signal(signum)
            except ProcessLookupError:
                return
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[signum] = signal.signal(signum, forward)
    try:
        out, err = worker.communicate(json.dumps(config))
    except BaseException:
        worker.send_signal(signal.SIGTERM)
        worker.communicate()
        raise
    finally:
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)
    if worker.returncode != 0 or not Path(str(stem) + ".json").exists():
        raise RuntimeError("Measurement helper failed before result creation; preserve command evidence and investigate")
    result = json.loads(Path(str(stem) + ".json").read_text())
    result["caller_elapsed_seconds"] = time.perf_counter() - began
    return result


def main() -> None:
    """도우미 실행과 측정 실행을 분리해 프로세스 트리 경계를 고정한다."""
    if sys.argv[1:] == ["--worker"]:
        _worker(json.load(sys.stdin))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stem", type=Path, required=True)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--interval", type=float, default=0.01)
    parser.add_argument("--mode", choices=("timing", "memory"), default="timing")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    result = run(command, args.cwd, args.stem, args.timeout, args.interval, mode=args.mode)
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["status"] == "ok" else 1)


if __name__ == "__main__":
    main()
