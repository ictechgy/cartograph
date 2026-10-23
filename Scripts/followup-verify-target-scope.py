#!/usr/bin/env python3
"""Native source/target scope controls against frozen fae3 and the candidate."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import time


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = output / "package"
    shutil.copytree(repo / "Fixtures/TargetScopeFeedback", root)
    spec = importlib.util.spec_from_file_location("scope_capture", repo / "Scripts/cartograph-swiftpm-scope.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.run(["git", "-c", "core.hooksPath=/dev/null", "init", "-q"], root, output, "git-init", 30)
    (root / ".gitignore").write_text(".build/\nSources/Tool/Ignored.swift\n", encoding="utf-8")
    config = root / "scope.yml"
    config.write_text('exclude:\n  - "Sources/Tool/Tool.swift"\n', encoding="utf-8")
    started = time.monotonic()
    receipt = module.capture(argparse.Namespace(project=str(root), cartograph=args.candidate,
        output=str(output / "capture"), test_target=["AppTests"], timeout=600, config=str(config)))
    metadata = json.loads((output / "capture/capture.json").read_text())
    common = ["--project", str(root), "--index-store", metadata["indexStore"], "--config", str(config)]

    def invoke(binary, label, extra, expected=0):
        command = [str(Path(binary).resolve()), "affected", "changedValue", *extra, *common]
        result = subprocess.run(command, capture_output=True, timeout=120)
        (output / (label + ".stdout")).write_bytes(result.stdout)
        (output / (label + ".stderr")).write_bytes(result.stderr)
        save(output / (label + ".process.json"), {"argv": command, "exit": result.returncode})
        assert result.returncode == expected, (label, result.returncode, result.stderr.decode(errors="replace"))
        return json.loads(result.stdout) if "json" in extra else result.stdout

    baseline = invoke(args.baseline, "baseline", ["--format", "json"])
    assert "targetScope" not in baseline
    invoke(args.baseline, "baseline-refusal", ["--format", "xcodebuild"], 2)
    actual = invoke(args.candidate, "candidate", ["--format", "json", "--target-scope", str(receipt)])
    scope = actual["targetScope"]
    assert scope["evidenceStatus"] == "matched-capture", scope
    assert scope["dependencyTargets"] == ["App", "AppTests"]
    rows = {row["path"]: row for row in scope["paths"]}
    for source in ("Sources/Tool/Tool.swift", "Sources/Tool/Ignored.swift"):
        assert rows[source]["classification"] == "outside-selected-targets", rows
    assert scope["schemeIdentity"] == "unverified"
    assert invoke(args.candidate, "candidate-refusal", ["--format", "xcodebuild", "--target-scope", str(receipt)], 2) == b""
    assert any(note.startswith("configured-path-filter:") for note in actual["limitations"])
    assert any(note.startswith("source-discovery-exclusions:") for note in actual["limitations"])
    before = (root / "Package.swift").read_bytes()
    for name, path, content in [("new-source", root / "New.swift", b"func newCaller() {}\n"),
                                ("manifest", root / "Package.swift", before + b"\n// edited\n"),
                                ("lock", root / "Package.resolved", b"{}\n")]:
        old = path.read_bytes() if path.exists() else None
        path.write_bytes(content)
        changed = invoke(args.candidate, name, ["--format", "json", "--target-scope", str(receipt)])
        assert changed["targetScope"]["evidenceStatus"] == "unknown", changed["targetScope"]
        if old is None:
            path.unlink()
        else:
            path.write_bytes(old)
    save(output / "results.json", {"status": "passed", "baselineCommit": "fae3c24b1776af8d75151663821f8ff221d928f8",
        "candidateCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "baselineSHA256": hashlib.sha256(Path(args.baseline).read_bytes()).hexdigest(),
        "candidateSHA256": hashlib.sha256(Path(args.candidate).read_bytes()).hexdigest(),
        "secondsIncludingPreparation": time.monotonic() - started,
        "outsidePaths": ["Sources/Tool/Tool.swift", "Sources/Tool/Ignored.swift"],
        "negativeControls": ["new-source", "manifest", "lock", "unverified-Xcode-scheme"],
        "limits": "Synthetic local SwiftPM scope only; no private workspace or Xcode scheme membership claim"})


if __name__ == "__main__":
    main()
