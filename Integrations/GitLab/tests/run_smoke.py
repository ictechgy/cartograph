#!/usr/bin/env python3
"""Exercise the published binary download and actual consumer fixture on macOS."""

import os
from pathlib import Path
import subprocess
import sys

from test_component import runner_source
from verify_pipeline import main as verify_pipeline


def main():
    root = Path(__file__).resolve().parents[1]
    environment = {
        **os.environ, "CI_PROJECT_DIR": str(root), "CARTOGRAPH_PROJECT": "fixtures/Smoke",
        "CARTOGRAPH_COMMAND": "dead", "CARTOGRAPH_BUILD": "swift", "CARTOGRAPH_ARGS": "",
        "CARTOGRAPH_FAIL_ON_FINDINGS": "false", "CARTOGRAPH_BINARY": "",
        "CARTOGRAPH_VERSION": "0.20.0",
        "CARTOGRAPH_SHA256": "833eb3c86deffc8e7c845297df57d41e35bb644bd5a943b09843e52075c6f072",
    }
    subprocess.run([sys.executable, "-c", runner_source()], cwd=root, env=environment, check=True)
    os.chdir(root)
    verify_pipeline()


if __name__ == "__main__":
    main()
