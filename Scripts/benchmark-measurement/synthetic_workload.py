#!/usr/bin/env python3
"""메모리와 프로세스 종료만 검증하며 제품 소스나 정답 집합을 만들지 않는다."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

HERE = str(Path(__file__).resolve())


def spawn(mode, *args):
    """BASE.run과 같은 별도 세션 자손을 실제로 만든다."""
    return subprocess.Popen([sys.executable, HERE, mode, *map(str, args)], start_new_session=True)


def main():
    """페이지를 실제로 만지고 부모 종료, 중첩 세션 분리, TERM 무시를 재현한다."""
    mode = sys.argv[1]
    if mode == "allocate":
        size, seconds = int(sys.argv[2]), float(sys.argv[3])
        data = bytearray(size * 1024 * 1024)
        for i in range(0, len(data), 4096):
            data[i] = 1
        time.sleep(seconds)
        print(len(data), flush=True)
    elif mode == "simultaneous":
        data = bytearray(24 * 1024 * 1024)
        child = spawn("allocate", 40, 0.4)
        child.wait()
        print(len(data), flush=True)
    elif mode == "sequential":
        for _ in range(2):
            spawn("allocate", 56, 0.25).wait()
    elif mode == "stubborn":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        Path(sys.argv[2]).write_text(str(os.getpid()))
        while True:
            time.sleep(0.02)
    elif mode == "middle":
        spawn("stubborn", sys.argv[2])
        time.sleep(float(sys.argv[3]))
    elif mode == "orphan":
        spawn("middle", sys.argv[2], sys.argv[3])
        time.sleep(float(sys.argv[4]))
    elif mode == "cpu":
        value = 1
        for index in range(int(sys.argv[2])):
            value = (value * 1664525 + index + 1013904223) & 0xFFFFFFFF
        print(value, flush=True)
    elif mode == "repeated_cpu":
        for _ in range(int(sys.argv[2])):
            child = spawn("cpu", int(sys.argv[3]))
            if child.wait() != 0:
                raise SystemExit(9)
    elif mode == "nonzero":
        print("synthetic stdout", flush=True)
        print("synthetic stderr", file=sys.stderr, flush=True)
        raise SystemExit(7)
    else:
        raise ValueError("Unknown synthetic workload")


if __name__ == "__main__":
    main()
