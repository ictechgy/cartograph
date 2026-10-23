#!/usr/bin/env python3
"""Run the existing native gates with bounded, owned-process receipts."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys


def gate_spec(kind):
    if kind == "raw":
        return (["swift", "test", "--skip-build", "--enable-code-coverage", "--filter",
                 "AssociatedTypeWitnessCompilerTests"], 270, 8 * 1024 * 1024)
    if kind == "receiver":
        return (["swift", "test", "--skip-build", "--enable-code-coverage", "--filter",
                 "DispatchReceiverCompilerTests"], 270, 8 * 1024 * 1024)
    if kind == "coverage":
        return (["bash", "Scripts/coverage.sh"], 840, 64 * 1024 * 1024)
    raise ValueError("Unknown native gate")


def run_gate(kind, output, runner, save):
    command, timeout, stream_limit = gate_spec(kind)
    output.mkdir(parents=True, exist_ok=False)
    result = {"status": "started", "gate": kind, "command": command,
              "timeoutSeconds": timeout, "streamLimitBytes": stream_limit}
    save(output / "gate.json", result)
    receiver = kind == "receiver"
    variable = "CARTOGRAPH_DISPATCH_RECEIVER_EVIDENCE" if receiver else "CARTOGRAPH_ASSOCIATED_WITNESS_EVIDENCE"
    prefix = "cartograph-dispatch-receiver" if receiver else "cartograph-associated-witness"
    assertion = "receiver-assertions-complete" if receiver else "witness-assertions-complete"
    previous = os.environ.get(variable)
    os.environ[variable] = str(output / "raw-occurrences.json")
    try:
        receipt = runner(command, Path.cwd(), output / "process", timeout=timeout, stream_limit=stream_limit)
        if (receipt.get("returncode") != 0 or receipt.get("timed_out") is not False
                or receipt.get("owned_root_reaped") is not True or receipt.get("ownership_lost") is not False
                or receipt.get("cleanup_errors") != [] or receipt.get("output_limit_exceeded") is not None
                or receipt.get("exception_type") is not None):
            raise RuntimeError("Native gate did not establish successful completion and owned cleanup")
        if kind in ("raw", "receiver"):
            occurrences = output / "raw-occurrences.json"
            phases = list(output.glob(f"{prefix}-*/phases.jsonl"))
            if not occurrences.is_file() or occurrences.stat().st_size == 0 or not phases:
                raise RuntimeError("Native gate produced no raw compiler evidence")
            completed = False
            for path in phases:
                if path.stat().st_size > 1024 * 1024:
                    raise RuntimeError("Native phase evidence exceeded 1 MiB")
                completed |= any(json.loads(line).get("name") == assertion
                                 for line in path.read_text(encoding="utf-8").splitlines())
            if not completed:
                raise RuntimeError("Raw compiler assertions did not complete")
        result["status"] = "passed"
        return 0
    except Exception as error:
        result.update(status="failed", exceptionType=type(error).__name__, error=str(error)[:2048])
        print(f"Native {kind} gate failed; evidence: {output}: {error}", file=sys.stderr)
        return 1
    finally:
        save(output / "gate.json", result)
        if previous is None:
            os.environ.pop(variable, None)
        else:
            os.environ[variable] = previous
        # 전체 원문은 artifact에 두고 CI 로그에는 마지막 64KiB만 남긴다.
        for name in ("process.stdout", "process.stderr"):
            path = output / name
            if path.is_file():
                with path.open("rb") as stream:
                    stream.seek(max(0, path.stat().st_size - 65536))
                    print(stream.read(65536).decode("utf-8", errors="replace"), file=sys.stderr)
        print(json.dumps(result, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("raw", "receiver", "coverage"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("native_gate_base",
                                                Path(__file__).with_name("benchmark-indexstore-cli.py"))
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    return run_gate(args.kind, args.output.resolve(), base.run, base.save)


if __name__ == "__main__":
    raise SystemExit(main())
