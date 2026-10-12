#!/usr/bin/env python3
"""정답 파일 없이 동결한 엔진 조립기를 한 번 실행하는 선택된 진입점."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "runtime"))
sys.path.insert(0, str(ROOT / "primitive"))
import runtime_bootstrap as bootstrap
import arm_sessions as primitive
from selector_contract import selectors


def execute(path, expected):
    data = bootstrap.read_regular(path)
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Engine input changed")
    config = bootstrap.strict_json(data)
    selectors(config["queries"])
    # 승인 세대·도구·소스 검증과 골드 필드 거부는 동결된 원래 구현을 그대로 쓴다.
    primitive.generation.verify(config)
    result = primitive.execute_worker(config)
    return 0 if result["status"] == "ok" else 125 if result["status"] == "incomplete" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()
    raise SystemExit(execute(args.input, args.sha256))


if __name__ == "__main__":
    main()
