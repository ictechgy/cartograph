#!/usr/bin/env python3
"""Inspect managed reader DBs; optionally prune idle entries by age and allocated bytes."""

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import time


NAME = re.compile(r"[0-9a-f]{1,16}-(?:[0-9a-f]{16}|unverified(?:-[0-9A-Fa-f-]{36})?)\Z")
LOCK = ".cartograph-reader.lock"
MARKER = ".cartograph-last-used"


def inventory(root, now):
    entries = []
    for path in sorted(root.iterdir()):
        if path.name == LOCK:
            continue
        item = {"name": path.name, "allocatedBytes": 0, "logicalBytes": 0, "managed": False}
        entries.append(item)
        if not NAME.fullmatch(path.name) or path.is_symlink() or not path.is_dir():
            item["reason"] = "unrecognized-entry"
            continue
        marker = path / MARKER
        try:
            stamp = marker.lstat()
            if not stat.S_ISREG(stamp.st_mode):
                raise ValueError("marker is not a regular file")
            latest = stamp.st_mtime
            database_found = False
            for directory, children, files in os.walk(path, followlinks=False):
                for name in children + files:
                    child = Path(directory) / name
                    info = child.lstat()
                    if stat.S_ISLNK(info.st_mode):
                        raise ValueError("symbolic link in cache")
                    relative = child.relative_to(path).as_posix()
                    if stat.S_ISDIR(info.st_mode):
                        if not re.fullmatch(r"v[0-9]+(?:/saved)?", relative):
                            raise ValueError("unrecognized cache directory")
                    elif stat.S_ISREG(info.st_mode):
                        if relative != MARKER and not re.fullmatch(r"v[0-9]+/saved/(?:data|lock)\.mdb", relative):
                            raise ValueError("unrecognized cache file")
                        database_found |= relative.endswith("/data.mdb")
                        item["logicalBytes"] += info.st_size
                        item["allocatedBytes"] += info.st_blocks * 512
                    else:
                        raise ValueError("special file in cache")
                    latest = max(latest, info.st_mtime)
            if not database_found:
                raise ValueError("no reader database")
            item.update(managed=True, lastUsed=latest, ageDays=max(0, now - latest) / 86400)
        except (OSError, ValueError) as error:
            item["reason"] = "unmarked-or-unrecognized-cache"
            item["detail"] = type(error).__name__
    return entries


def plan(entries, max_age_days, max_bytes):
    managed = sorted((item for item in entries if item["managed"]),
                     key=lambda item: (item["lastUsed"], item["name"]))
    retained_bytes = sum(item["allocatedBytes"] for item in managed)
    for item in managed:
        # 최근 독자가 방금 놓은 캐시를 예산만으로 즉시 버리지 않는다.
        eligible = item["ageDays"] >= 300 / 86400
        expired = item["ageDays"] >= max_age_days
        item["selected"] = eligible and (expired or retained_bytes > max_bytes)
        if item["selected"]:
            item["reason"] = "expired" if expired else "over-budget"
            retained_bytes -= item["allocatedBytes"]
    return retained_bytes


def maintain(root, apply, max_age_days, max_bytes, now=None):
    if root.is_symlink():
        raise ValueError("cache root must not be a symbolic link")
    if not root.exists():
        return {"applied": False, "entries": [], "retainedManagedBytes": 0}
    # 독자가 하나라도 있으면 기다리며 삭제하지 않고 재실행을 요구한다.
    descriptor = os.open(root / LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        entries = inventory(root, time.time() if now is None else now)
        retained = plan(entries, max_age_days, max_bytes)
        if apply:
            for item in entries:
                if item.get("selected"):
                    shutil.rmtree(root / item["name"])
                    item["removed"] = True
        return {"applied": apply, "entries": entries, "retainedManagedBytes": retained,
                "limits": {"maxAgeDays": max_age_days, "maxBytes": max_bytes},
                "limitations": ["Unmarked/unknown entries are preserved and excluded from the byte budget.",
                                "Stop older Cartograph versions that do not participate in reader locking.",
                                "Recently used entries have a five-minute grace period; the budget is soft."]}
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path,
                        default=Path(os.environ.get("TMPDIR", "/tmp")) / "cartograph-index-db")
    parser.add_argument("--max-age-days", type=float, default=30)
    parser.add_argument("--max-bytes", type=int, default=2 * 1024**3)
    parser.add_argument("--apply", action="store_true", help="Delete selected idle, marked databases.")
    args = parser.parse_args()
    if not math.isfinite(args.max_age_days) or args.max_age_days <= 0 or args.max_bytes < 0:
        parser.error("age must be finite and positive; bytes must be nonnegative")
    try:
        report = maintain(args.cache_root, args.apply, args.max_age_days, args.max_bytes)
    except BlockingIOError:
        parser.exit(2, "Reader cache is in use. Retry after the current analysis completes.\n")
    except (OSError, ValueError) as error:
        parser.exit(2, f"Cache maintenance failed ({type(error).__name__}). Check root and permissions.\n")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
