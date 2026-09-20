#!/usr/bin/env python3
"""Exercise maintenance against isolated LMDB-shaped directories and a real reader lock."""

import fcntl
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


spec = importlib.util.spec_from_file_location("index_cache", Path(__file__).with_name("manage-index-cache.py"))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


def database(root, number, age_days, marked=True):
    path = root / f"{number:016x}-aaaaaaaaaaaaaaaa"
    saved = path / "v13/saved"
    saved.mkdir(parents=True)
    (saved / "data.mdb").write_bytes(b"x" * 8192)
    (saved / "lock.mdb").write_bytes(b"x" * 4096)
    if marked:
        (path / cache.MARKER).touch()
    stamp = time.time() - age_days * 86400
    for child in [*path.rglob("*"), path]:
        os.utime(child, (stamp, stamp))
    return path


def main():
    with tempfile.TemporaryDirectory(prefix="cartograph-cache-tests-") as directory:
        root = Path(directory)
        expired = database(root, 1, 40)
        idle = database(root, 2, 2)
        young = database(root, 3, 0)
        legacy = database(root, 4, 40, marked=False)
        unknown = database(root, 5, 40)
        (unknown / "personal-backup").write_text("preserve")
        linked = root / "0000000000000006-aaaaaaaaaaaaaaaa"
        linked.symlink_to(expired, target_is_directory=True)
        report = cache.maintain(root, False, 30, 2 * 1024**3)
        assert [item["name"] for item in report["entries"] if item.get("selected")] == [expired.name]
        assert expired.exists(), "dry run deleted a cache"
        cache.maintain(root, True, 30, 2 * 1024**3)
        assert not expired.exists()
        assert all(path.exists() for path in (idle, young, legacy, unknown))
        assert linked.is_symlink()
        cache.maintain(root, True, 30, 0)
        assert not idle.exists(), "oldest idle DB should meet the byte budget"
        assert young.exists(), "five-minute grace must preserve a recently used DB"
        with (root / cache.LOCK).open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
            result = subprocess.run([sys.executable, str(Path(cache.__file__)), "--cache-root", str(root),
                                     "--apply"], capture_output=True, text=True)
            assert result.returncode == 2 and "in use" in result.stderr, result
            assert young.exists()
    print("PASS: dry run, age, byte budget, grace, unknown/symlink preservation and active-reader exclusion")


if __name__ == "__main__":
    main()
