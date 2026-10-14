#!/usr/bin/env python3
"""고정 합성 배우만으로 미수거 waitid 관측 기능을 확인하며 엔진 적격성을 주장하지 않는다."""
from __future__ import annotations

import argparse
import hashlib
import json
import inspect
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

CASES = (
    ("native-api-admission", 0), ("normal-zero", 1), ("normal-seven", 1),
    ("signal-exit", 1), ("timeout-then-term", 1), ("term-ignore-then-kill", 1),
    ("owned-pair-complete", 2), ("root-exit-member-live", 2),
    ("owned-member-escape", 2), ("synchronized-fast-exits", 2),
    ("injected-observation-refusals", 0), ("invalid-ledger-refusals", 0),
)
OBSERVATION_NEGATIVES = ("ENOSYS", "EINVAL", "ECHILD", "EPERM", "unreadable-member", "unexpected-member")
LEDGER_NEGATIVES = ("missing-terminal", "boolean-exit", "normal-killed-mismatch", "wrong-signal",
                    "status-mismatch", "early-reap", "signal-after-reap", "duplicate-reap")
WATCHDOG_SECONDS, CASE_SECONDS, SUITE_SECONDS, OUTER_SECONDS = 5, 10, 120, 150
MAX_LAUNCHES = 13


class CapabilityFailure(ValueError):
    """원래 실패를 보존하고 남은 고정 사례를 시작하지 않는다."""


class ObservationTimeout(TimeoutError):
    pass


class Cancelled(BaseException):
    pass


def require(value, reason):
    if not value:
        raise CapabilityFailure(reason)


def api_admission():
    require(sys.platform == "darwin", "native-macos-required")
    names = ("waitid", "P_PID", "WEXITED", "WNOWAIT", "WNOHANG", "CLD_EXITED", "CLD_KILLED", "CLD_DUMPED")
    require(all(hasattr(os, name) for name in names) and callable(os.waitid), "native-waitid-unavailable")
    require(hasattr(subprocess.Popen, "wait") and "process_group" in inspect.signature(subprocess.Popen).parameters
            and hasattr(signal, "setitimer") and signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0),
            "native-supervision-unavailable")
    return dict(platform=sys.platform, python=sys.version, waitid="native-os.waitid", constants={
        name: getattr(os, name) for name in names if name != "waitid"}, supported=True)


def terminal(pid, row):
    require(row is not None and type(row.si_pid) is int and row.si_pid == pid
            and type(row.si_status) is int and type(row.si_code) is int
            and row.si_signo == signal.SIGCHLD, "invalid-terminal-observation")
    require(row.si_code in (os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED), "nonterminal-waitid-status")
    require(0 <= row.si_status <= 255 and (row.si_code == os.CLD_EXITED or row.si_status > 0), "invalid-terminal-status")
    return dict(pid=pid, code=row.si_code, status=row.si_status, signo=row.si_signo,
                expected_wait_returncode=row.si_status if row.si_code == os.CLD_EXITED else -row.si_status)


def verify_ledger(row):
    require(type(row) is dict and row.get("terminal") is not None, "missing-terminal")
    observed = row["terminal"]
    require(type(row.get("wait_returncode")) is int and type(observed.get("expected_wait_returncode")) is int,
            "untyped-final-exit")
    expected = observed["status"] if observed["code"] == os.CLD_EXITED else -observed["status"]
    require(type(observed["code"]) is int and observed["code"] in (os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED)
            and type(observed["status"]) is int and 0 <= observed["status"] <= 255
            and (observed["code"] == os.CLD_EXITED or observed["status"] > 0)
            and expected == observed["expected_wait_returncode"] == row["wait_returncode"], "final-exit-disagrees")
    require(row.get("audit_finished_before_reap") is True and row.get("signal_after_reap") is False
            and type(row.get("reap_count")) is int and row["reap_count"] == 1, "invalid-reap-order")
    return True


def observe_terminal(pid, options, waitid):
    """테스트 주입도 동일한 호출 경계에서 실패하며 대체 관측기로 우회하지 않는다."""
    found = waitid(os.P_PID, pid, options)
    return None if found is None else terminal(pid, found)


def enumerated_census(pids, getpgid, getsid):
    return [dict(pid=pid, process_group=getpgid(pid), session=getsid(pid)) for pid in pids]


def actor_main(control, ready, ignore_term):
    # 자식 자신의 타이머는 부모의 wait/census 주입과 독립적이며 TERM 무시에도 유지한다.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(WATCHDOG_SECONDS)
    if ignore_term:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.write(ready, b"R")
    while True:
        command = os.read(control, 1)
        if command in (b"0", b"7"):
            os._exit(int(command))
        if command == b"E":
            os.setsid()
            os.write(ready, b"E")
        elif command == b"":
            os._exit(91)


class OwnedCase:
    """모든 배우의 직접 Popen 참조를 보유하고 감사 종료 전에는 한 번도 회수하지 않는다."""
    def __init__(self, root, name, suite_deadline, launch_counter):
        self.root, self.name = root, name
        self.start = time.monotonic()
        self.deadline = min(self.start + CASE_SECONDS, suite_deadline)
        self.actors, self.launch_counter = [], launch_counter
        self.audit_finished = False
        self.creating = False
        self.pending = None
        self.cleanup_errors = []

    def remaining(self, limit):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "case-deadline-expired")
        return min(limit, remaining)

    def cancel(self, signum, _frame):
        if self.creating:
            self.pending = signum
        else:
            raise Cancelled(f"signal-{signum}")

    def launch(self, *, group=0, ignore_term=False):
        require(not self.audit_finished and len(self.actors) < 2 and self.launch_counter[0] < MAX_LAUNCHES,
                "launch-schedule-exceeded")
        self.remaining(1)
        c_read, c_write = os.pipe()
        try:
            r_read, r_write = os.pipe()
        except BaseException:
            os.close(c_read); os.close(c_write)
            raise
        number = len(self.actors)
        stdout = stderr = row = None
        argv = [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), "--actor",
                str(c_read), str(r_write), "1" if ignore_term else "0"]
        try:
            stdout = (self.root / f"{self.name}-{number}.stdout").open("xb")
            stderr = (self.root / f"{self.name}-{number}.stderr").open("xb")
            started = time.monotonic()
            self.creating = True
            process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                pass_fds=(c_read, r_write), process_group=group, close_fds=True)
            row = dict(process=process, pid=process.pid, control=c_write, ready=r_read,
                       started=started, argv=argv, terminal=None, reap_count=0,
                       audit_finished_before_reap=False, signal_after_reap=False)
            self.actors.append(row); self.launch_counter[0] += 1
        finally:
            self.creating = False
            os.close(c_read); os.close(r_write)
            if stdout is not None: stdout.close()
            if stderr is not None: stderr.close()
            if row is None:
                os.close(c_write); os.close(r_read)
        if self.pending is not None:
            raise Cancelled(f"signal-{self.pending}")
        self.ack(row, b"R")
        return row

    def ack(self, row, expected):
        readable, _, _ = select.select([row["ready"]], [], [], self.remaining(1.0))
        require(bool(readable) and os.read(row["ready"], 1) == expected, "actor-not-ready")

    def send(self, row, command):
        require(not self.audit_finished and row["reap_count"] == 0, "command-after-reap")
        os.write(row["control"], command)

    def observe(self, row, timeout=5.5, *, nonblocking=False):
        require(not self.audit_finished and row["reap_count"] == 0, "observation-after-reap")
        options = os.WEXITED | os.WNOWAIT | (os.WNOHANG if nonblocking else 0)
        def expired(_signum, _frame):
            raise ObservationTimeout("terminal-observation-timeout")
        allowance = self.remaining(timeout)
        require(signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0), "existing-observation-timer")
        previous = signal.signal(signal.SIGALRM, expired)
        try:
            signal.setitimer(signal.ITIMER_REAL, allowance)
            result = observe_terminal(row["pid"], options, os.waitid)
            if result is None:
                require(nonblocking, "missing-blocking-observation")
                return None
            row["terminal"] = result
            row["popen_start_to_exit_observed_seconds"] = time.monotonic() - row["started"]
            return result
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)

    def census(self):
        require(not self.audit_finished and all(row["reap_count"] == 0 for row in self.actors), "census-after-reap")
        # 명시적으로 열거된 직접 소유 배우만 확인한다. 전체 후손이나 숨은 그룹원 증명이 아니다.
        return enumerated_census([row["pid"] for row in self.actors], os.getpgid, os.getsid)

    def signal_group(self, signum):
        require(not self.audit_finished and self.actors and all(row["reap_count"] == 0 for row in self.actors),
                "group-signal-after-reap")
        require(os.getpgid(self.actors[0]["pid"]) == self.actors[0]["pid"], "owned-leader-group-changed")
        os.killpg(self.actors[0]["pid"], signum)

    def finish(self):
        started = time.monotonic()
        previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            # 감사 오류/탈출이어도 개별 소유 핸들로 회복한다. 여기서부터 그룹 신호는 영구 금지한다.
            self.audit_finished = True
            for row in self.actors:
                if row["terminal"] is None:
                    try:
                        os.kill(row["pid"], signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    except BaseException as error:
                        self.cleanup_errors.append(dict(step="individual-kill", type=type(error).__name__))
            for row in self.actors:
                try:
                    row["audit_finished_before_reap"] = self.audit_finished
                    row["wait_returncode"] = row["process"].wait(timeout=max(0.001, min(2.0, self.deadline-time.monotonic())))
                    row["reap_count"] += 1
                except BaseException as error:
                    self.cleanup_errors.append(dict(step="individual-reap", type=type(error).__name__))
                finally:
                    for key in ("control", "ready"):
                        try: os.close(row[key])
                        except OSError: pass
            return dict(cleanup_wall_seconds=time.monotonic()-started, errors=self.cleanup_errors,
                        unfinished=[row["pid"] for row in self.actors if row["reap_count"] != 1])
        finally:
            for sig, handler in previous.items(): signal.signal(sig, handler)

    def receipts(self):
        return [{key: value for key, value in row.items() if key not in ("process", "control", "ready", "started")}
                for row in self.actors]


def require_owned_census(rows, actors):
    require(type(rows) is list and {row["pid"] for row in rows} == set(actors) and len(rows) == len(actors),
            "unexpected-member")


def injected_refusals():
    import errno
    observed = []
    for name in OBSERVATION_NEGATIVES:
        caught = None
        try:
            if name in ("ENOSYS", "EINVAL", "ECHILD", "EPERM"):
                def failed_wait(*_args):
                    raise OSError(getattr(errno, name), name)
                observe_terminal(101, os.WEXITED | os.WNOWAIT, failed_wait)
            elif name == "unreadable-member":
                def failed_census(_pid):
                    raise ProcessLookupError("unreadable-member")
                enumerated_census([101], failed_census, lambda _pid: 101)
            else:
                require_owned_census([dict(pid=1), dict(pid=2)], [1])
        except OSError as error:
            require((name in ("ENOSYS", "EINVAL", "ECHILD", "EPERM") and error.errno == getattr(errno, name))
                    or (name == "unreadable-member" and type(error) is ProcessLookupError
                        and str(error) == "unreadable-member"), "wrong-injected-os-refusal")
            caught = dict(name=name, exception=type(error).__name__, errno=error.errno)
        except CapabilityFailure as error:
            require(name == "unexpected-member" and str(error) == "unexpected-member", "wrong-injected-scope-refusal")
            caught = dict(name=name, exception=type(error).__name__, reason=str(error))
        require(caught is not None, "injected-refusal-missing")
        observed.append(caught)
    require(tuple(row["name"] for row in observed) == OBSERVATION_NEGATIVES, "injected-refusal-missing")
    return observed


def invalid_ledgers():
    import copy
    good = dict(terminal=dict(code=os.CLD_EXITED, status=0, expected_wait_returncode=0), wait_returncode=0,
                audit_finished_before_reap=True, signal_after_reap=False, reap_count=1)
    mutations = (lambda r: r.update(terminal=None), lambda r: r.update(wait_returncode=False),
        lambda r: r["terminal"].update(code=os.CLD_KILLED, status=9),
        lambda r: r["terminal"].update(code=os.CLD_KILLED, status=15, expected_wait_returncode=-9),
        lambda r: r["terminal"].update(status=7), lambda r: r.update(audit_finished_before_reap=False),
        lambda r: r.update(signal_after_reap=True), lambda r: r.update(reap_count=2))
    observed = []
    for name, change in zip(LEDGER_NEGATIVES, mutations):
        row = copy.deepcopy(good); change(row)
        try: verify_ledger(row)
        except CapabilityFailure: observed.append(name)
    require(tuple(observed) == LEDGER_NEGATIVES, "ledger-refusal-missing")
    return observed


def execute_case(case):
    name = case.name
    if name == "native-api-admission": return dict(admission=api_admission())
    if name == "injected-observation-refusals": return dict(subcases=injected_refusals())
    if name == "invalid-ledger-refusals": return dict(subcases=invalid_ledgers())
    root = case.launch(ignore_term=name == "term-ignore-then-kill")
    peer = case.launch(group=root["pid"]) if dict(CASES)[name] == 2 else None
    initial = case.census()
    require_owned_census(initial, [row["pid"] for row in case.actors])
    require(all(row["process_group"] == root["pid"] for row in initial), "initial-group-mismatch")
    outcome = dict(initial_enumerated_actors=initial, observed_tree_status="enumerated-actors-complete")
    peer_result = None
    if name == "owned-member-escape":
        case.send(peer, b"E"); case.ack(peer, b"E")
    if name == "timeout-then-term":
        try: case.observe(root, 0.25)
        except ObservationTimeout:
            outcome.update(expected_observation_timeout=True, observed_tree_status="incomplete-observation-timeout")
        else: raise CapabilityFailure("expected-timeout-missing")
        case.signal_group(signal.SIGTERM)
    elif name == "term-ignore-then-kill":
        case.signal_group(signal.SIGTERM)
        try: case.observe(root, 0.25)
        except ObservationTimeout:
            outcome.update(expected_term_resistance=True, observed_tree_status="incomplete-term-resistant")
        else: raise CapabilityFailure("expected-term-resistance-missing")
        case.signal_group(signal.SIGKILL)
    elif name == "signal-exit": case.signal_group(signal.SIGTERM)
    else:
        if peer and name not in ("root-exit-member-live", "owned-member-escape"):
            case.send(peer, b"0")
            if name == "owned-pair-complete":
                # Sequential completion: observe the member while its leader is still held ready.
                peer_result = case.observe(peer)
                require(peer_result["expected_wait_returncode"] == 0, "unexpected-peer-exit")
        # The fast pair releases both actors before observing either terminal status.
        case.send(root, b"7" if name == "normal-seven" else b"0")
    result = case.observe(root)
    expected = 7 if name == "normal-seven" else -signal.SIGTERM if name in ("signal-exit", "timeout-then-term") else -signal.SIGKILL if name == "term-ignore-then-kill" else 0
    require(result["expected_wait_returncode"] == expected, "unexpected-root-exit")
    final = case.census(); outcome["post_exit_enumerated_actors"] = final
    if peer:
        if name in ("root-exit-member-live", "owned-member-escape"):
            require(case.observe(peer, nonblocking=True) is None, "expected-live-peer-missing")
            escaped = final[1]["process_group"] != root["pid"]
            require(escaped == (name == "owned-member-escape"), "unexpected-group-state")
            outcome["observed_tree_status"] = "scope-violation" if escaped else "incomplete-live-member"
            # Recovery uses the retained unreaped individual handle, including the escaped actor.
            os.kill(peer["pid"], signal.SIGTERM)
        peer_terminal = peer_result if peer_result is not None else case.observe(peer)
        expected_peer = -signal.SIGTERM if name in ("root-exit-member-live", "owned-member-escape") else 0
        require(peer_terminal["expected_wait_returncode"] == expected_peer, "unexpected-peer-exit")
    return outcome


def run(output):
    output.mkdir(exist_ok=False)
    started = time.monotonic(); deadline = started + SUITE_SECONDS
    source = Path(__file__).read_bytes()
    result = dict(schema_version=1, profile="native-waitid-capability-v1", capability_only=True,
        descendant_closure_eligible=False, timing_eligible=False, final_protocol_ready=False, actual_engine_calls=0,
        source_sha256=hashlib.sha256(source).hexdigest(), schedule=[dict(name=n, max_launches=c) for n,c in CASES],
        bounds=dict(watchdog=5, case=10, suite=120, outer=150), cases=[], status="incomplete")
    counter = [0]; failed = False
    for name, maximum in CASES:
        if failed or time.monotonic() >= deadline:
            result["cases"].append(dict(name=name, status="not-started", reason="prior-failure-or-suite-deadline"));failed=True;continue
        case = OwnedCase(output, name, deadline, counter); primary = None; row = dict(name=name, status="incomplete")
        previous = {sig: signal.signal(sig, case.cancel) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            row.update(execute_case(case))
        except BaseException as error:
            primary = dict(type=type(error).__name__, reason=str(error)); row["failure"] = primary
        finally:
            cleanup = case.finish()
            for sig, handler in previous.items(): signal.signal(sig, handler)
        row.update(actors=case.receipts(), cleanup=cleanup, full_case_wall_seconds=time.monotonic()-case.start)
        try:
            require(primary is None and not cleanup["errors"] and not cleanup["unfinished"], "case-incomplete")
            require(len(case.actors) == maximum and row["full_case_wall_seconds"] <= CASE_SECONDS, "case-schedule-or-budget")
            for actor in row["actors"]: verify_ledger(actor)
            row["status"] = "capability-case-passed"
        except BaseException as error:
            row.setdefault("failure", dict(type=type(error).__name__, reason=str(error)));failed=True
        result["cases"].append(row)
        if cleanup["unfinished"]:
            failed=True
    result.update(status="incomplete" if failed else "capability-only-complete", actual_launches=counter[0],
                  full_suite_wall_seconds_before_receipt=time.monotonic()-started)
    if result["full_suite_wall_seconds_before_receipt"] > SUITE_SECONDS or counter[0] > MAX_LAUNCHES:
        result["status"] = "incomplete"
    with (output/"results.json").open("x") as stream: json.dump(result, stream, sort_keys=True, indent=2);stream.write("\n")
    return result


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--actor":
        actor_main(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1")
        return 91
    parser = argparse.ArgumentParser();parser.add_argument("--output",type=Path,required=True);args=parser.parse_args()
    result=run(args.output)
    return 0 if result["status"] == "capability-only-complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
