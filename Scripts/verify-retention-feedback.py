#!/usr/bin/env python3
"""Measure C-P1-3 on one native corpus and three pinned public projects.

Raw findings and missing coverage survive. Measurement is separate from the
required manual review; pending reviews exit 3, never a narrowing-gate pass.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import zipfile

REASON = "Sources/CartographCore/Retention/RetentionReason.swift"
REVERSALS = (
    ("case .externalConformance, .externalOverride, .equatableProperty, .hashableProperty: true",
     "case .externalConformance, .externalOverride: true"),
    ("case .compilerSynthesized, .compileTimeReference, .externalConformance, .externalOverride,\n"
     "             .equatableProperty, .hashableProperty: false",
     "case .compilerSynthesized, .compileTimeReference, .externalConformance, .externalOverride: false"),
)
# The public revisions/scopes already used in docs/evaluation/2026-09-15-comparison.md.
PROJECTS = (
    ("alamofire", "Alamofire/Alamofire", "bda9ed57d72988a3a2ada33d824583541f86eac6", ["Source/**"], True),
    ("kingfisher", "onevcat/Kingfisher", "ab1c1de54a1ce1adfe1733c7195056a153029d3a", ["Sources/**"], False),
    ("argument-parser", "apple/swift-argument-parser", "93c68882a28d9c82cd87be0acb7d76e35494b9b5",
     ["Sources/ArgumentParser/**", "Sources/ArgumentParserToolInfo/**"], True),
)
MAX_JSON = 64 * 1024 * 1024


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def restore_unconditional(source):
    for current, old in REVERSALS:
        if source.count(current) != 1:
            raise ValueError("Candidate retention rule changed; review the paired baseline adapter")
        source = source.replace(current, old)
    return source


def source_identity(root):
    paths = [root / "Package.swift", root / "Package.resolved", *sorted((root / "Sources").rglob("*.swift"))]
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def select_index(root):
    candidates = [root / ".build/out", root / ".build/debug/index/store"]
    candidates += sorted((root / ".build").glob("*/debug/index/store"))
    present = [p.resolve() for p in candidates if (p / "v5/units").is_dir() or (p / "units").is_dir()]
    unique = sorted(set(present))
    if len(unique) != 1:
        raise ValueError(f"Expected one fresh compiler index, found {unique}")
    return unique[0]


def read_document(path):
    with path.open("rb") as stream:
        data = stream.read(MAX_JSON + 1)
    if len(data) > MAX_JSON:
        raise ValueError("Report exceeds 64 MiB evidence budget")
    document = json.loads(data)
    if not isinstance(document.get("diagnostics"), list) or document.get("suppressedCount") != 0:
        raise ValueError("Expected unsuppressed diagnostic report")
    if any(str(item).startswith("empty-index:") for item in document.get("limitations", [])):
        raise ValueError("An empty index is not a successful comparison")
    return document


def findings(document):
    result = {}
    for item in document["diagnostics"]:
        key = item["ruleIdentifier"] + "|" + (item.get("subject") or item["message"])
        if key in result:
            raise ValueError("Duplicate diagnostic identity")
        result[key] = item
    return result


def source_mentions(root, diagnostic):
    """Bounded name search is review evidence, never automatic deletion approval."""
    match = re.search(r"'([^']+)'", diagnostic["message"])
    name = match[1].split("(", 1)[0].rsplit(".", 1)[-1] if match else None
    if not name or not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", name):
        return {"name": name, "status": "manual-search-required", "matches": []}
    pattern = re.compile(r"(?<![A-Za-z_0-9])" + re.escape(name) + r"(?![A-Za-z_0-9])")
    matches, count, matching_lines, scanned_bytes = [], 0, 0, 0
    for path in sorted(root.rglob("*.swift")):
        if ".build" in path.relative_to(root).parts or path.is_symlink():
            continue
        size = path.stat().st_size
        scanned_bytes += size
        if size > 8 * 1024 * 1024 or scanned_bytes > 256 * 1024 * 1024:
            raise ValueError("Source-name audit exceeded its byte budget")
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            hits = len(pattern.findall(line))
            count += hits
            matching_lines += bool(hits)
            if hits and len(matches) < 200:
                matches.append({"path": str(path.relative_to(root)), "line": number, "text": line[:2000]})
    return {"name": name, "status": "searched-not-reviewed", "occurrenceCount": count,
            "matches": matches, "omittedMatchingLines": max(0, matching_lines - 200)}


def review_status(results, review):
    required = {item["reviewKey"] for project in results["projects"] for item in project["newlyReported"]}
    accepted = {}
    for item in review.get("reviews", []):
        key = item.get("reviewKey")
        if key in accepted or key not in required:
            raise ValueError("Duplicate or stale manual review key")
        if item.get("decision") != "confirmed" or not item.get("reviewer", "").strip() or not item.get("evidence", "").strip():
            raise ValueError("Each new finding requires named manual review and source evidence")
        accepted[key] = item
    pending = sorted(required - accepted.keys())
    pins = {(name, revision) for name, _, revision, _, _ in PROJECTS}
    observed = {(project.get("name"), project.get("revision")) for project in results["projects"]}
    complete = (len(results["projects"]) == len(PROJECTS) and observed == pins
                and results.get("corpus", {}).get("passed") is True
                and results.get("measurementsComplete") is True)
    return {"status": "passed" if complete and not pending else "pending", "pendingReviewKeys": pending,
            "required": len(required), "reviewed": len(accepted), "measurementsComplete": complete}


class Native:
    def __init__(self, repo, output):
        # Reuse the repository's bounded subprocess / wait4 evidence machinery.
        spec = importlib.util.spec_from_file_location("retention_measurement_base", repo / "Scripts/benchmark-indexstore-cli.py")
        self.base = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.base)
        self.output = output
        self.measurements = []

    def run(self, command, cwd, label, timeout=600):
        meta = self.base.run(list(map(str, command)), cwd, self.output / "logs" / label,
                             timeout, stream_limit=MAX_JSON)
        self.measurements.append({"label": label, "wallSeconds": meta["wall_seconds"],
                                  "processMaxRSSBytes": meta["wait4_maxrss_bytes"],
                                  "metadata": "logs/" + label + ".json"})
        return Path(meta["stdout"])

    def text(self, command, cwd, label, timeout=600):
        return self.run(command, cwd, label, timeout).read_text(encoding="utf-8").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory; never overwritten")
    parser.add_argument("--review", type=Path, help="Manual reviews bound to source and finding identities")
    parser.add_argument("--validate-only", action="store_true", help="Validate an existing results.json without rebuilding")
    args = parser.parse_args()
    output = args.output.resolve()
    review = json.loads(args.review.read_text()) if args.review else {}
    if args.validate_only:
        results = json.loads((output / "results.json").read_text())
        gate = review_status(results, review)
        save(output / "review-gate.json", gate)
        print(json.dumps(gate))
        return 0 if gate["status"] == "passed" else 3
    if sys.platform != "darwin":
        parser.error("Native Swift/macOS gate required; do not substitute source-only results")
    repo = Path(__file__).resolve().parents[1]
    output.mkdir(parents=True, exist_ok=False)
    native = Native(repo, output)
    results = {"scope": "synthetic corpus plus three public macOS library captures; not company-app accuracy",
               "costScope": "Acquisition, both tool builds, fixture/public builds, and analysis receipts are retained. "
                            "The before tool build includes dependency preparation; after reuses that isolated scratch. "
                            "These unequal tool build costs are not a product speed comparison. Process RSS is not process-tree RSS.",
               "projects": [], "status": "incomplete"}
    try:
        head = native.text(["git", "rev-parse", "HEAD"], repo, "candidate-head")
        if native.text(["git", "status", "--porcelain", "--untracked-files=no"], repo, "candidate-status"):
            raise ValueError("Commit the candidate before measuring it")
        results["candidateCommit"] = head
        results["toolchain"] = native.text(["swift", "--version"], repo, "toolchain")
        archive = output / "candidate.zip"
        native.run(["git", "archive", "--format=zip", f"--output={archive}", head], repo, "candidate-archive")
        baseline = output / "baseline-source"
        baseline.mkdir()
        with zipfile.ZipFile(archive) as zipped:
            if sum(info.file_size for info in zipped.infolist()) > 512 * 1024 * 1024:
                raise ValueError("Candidate source archive exceeds 512 MiB")
            for info in zipped.infolist():
                if not (baseline / info.filename).resolve().is_relative_to(baseline):
                    raise ValueError("Candidate archive contains an escaping path")
            zipped.extractall(baseline)
        original = source_identity(repo)
        target = baseline / REASON
        target.write_text(restore_unconditional(target.read_text(encoding="utf-8")), encoding="utf-8")
        restored = source_identity(baseline)
        if {path for path in original if original[path] != restored[path]} != {REASON}:
            raise ValueError("Paired baseline must differ only in RetentionReason.swift")
        results["sourceIdentity"] = {"candidate": original, "pairedPreNarrowing": restored}
        binaries = {}
        # Build the paired source first, then change only the owned file in that same
        # isolated scratch. This avoids recompiling dependencies and never touches repo sources.
        for label, source in [("before", restore_unconditional((repo / REASON).read_text())),
                              ("after", (repo / REASON).read_text())]:
            target.write_text(source, encoding="utf-8")
            native.run(["swift", "build", "--package-path", baseline, "-c", "release", "--product", "cartograph",
                        "--force-resolved-versions", "--jobs", "3"], baseline, label + "-tool-build", 1500)
            directory = native.text(["swift", "build", "--package-path", baseline, "-c", "release", "--show-bin-path"],
                                    baseline, label + "-tool-bin", 120)
            binaries[label] = output / ("cartograph-" + label)
            shutil.copy2(Path(directory) / "cartograph", binaries[label])
        results["binarySHA256"] = {label: native.base.sha256(path) for label, path in binaries.items()}
        for key in [key for key in os.environ if key.startswith("GIT_")]:
            del os.environ[key]
        os.environ.update(GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1")
        fixture = output / "corpus"
        # The archive contains only the reviewed commit, excluding a developer's
        # untracked .build artifacts or edits made after the cleanliness check.
        shutil.copytree(baseline / "Fixtures/FalsePositiveCorpus/FeedbackRetention", fixture)
        native.run(["swift", "build", "--jobs", "3"], fixture, "corpus-build")
        bindir = native.text(["swift", "build", "--show-bin-path"], fixture, "corpus-bin")
        native.run([Path(bindir) / "FeedbackRetention"], fixture, "corpus-run")
        index = select_index(fixture)
        fixture_index = native.base.fingerprint(index)
        fixture_docs = {label: read_document(native.run([binary, "dead", "--project", fixture, "--index-store", index,
                                                       "--report-format", "json"], fixture, "corpus-" + label))
                        for label, binary in binaries.items()}
        if native.base.fingerprint(index) != fixture_index:
            raise ValueError("Compiler corpus index changed between paired reports")
        unused = lambda doc: sorted(d["message"] for d in doc["diagnostics"] if d["ruleIdentifier"] == "unused-symbol")
        expected = sorted((fixture / "expected-unused.txt").read_text().splitlines())
        if unused(fixture_docs["after"]) != expected:
            raise ValueError("Native corpus differs from the complete frozen unused-symbol list")
        before = unused(fixture_docs["before"])
        if "class 'FeedbackRetention.NeverMadeStore' is never used" in before or \
                "class 'FeedbackRetention.NeverMadePlain' is never used" not in before:
            raise ValueError("Paired baseline did not reproduce nested Equatable retention")
        results["corpus"] = {"passed": True, "before": before, "after": expected, "sameIndex": fixture_index,
                             "limitations": {key: value.get("limitations", []) for key, value in fixture_docs.items()}}
        for name, repository, revision, includes, build_tests in PROJECTS:
            project = output / "projects" / name
            project.mkdir(parents=True)
            for suffix, command in [("init", ["git", "init", "-q"]),
                                    ("remote", ["git", "remote", "add", "origin", f"https://github.com/{repository}.git"]),
                                    ("fetch", ["git", "-c", "core.hooksPath=/dev/null", "fetch", "--depth", "1", "origin", revision]),
                                    ("checkout", ["git", "-c", "core.hooksPath=/dev/null", "checkout", "--detach", "FETCH_HEAD"])]:
                native.run(command, project, name + "-" + suffix, 120)
            if native.text(["git", "rev-parse", "HEAD"], project, name + "-head") != revision:
                raise ValueError("Public project pin mismatch")
            native.run(["swift", "build", "--jobs", "3"] + (["--build-tests"] if build_tests else []),
                       project, name + "-build", 900)
            index = select_index(project)
            captured = native.base.fingerprint(index)
            config = output / (name + "-scope.yml")
            config.write_text("include:\n" + "".join(f'  - "{p}"\n' for p in includes) +
                              "retention:\n  retain_public: true\n  retain_objc_accessible: true\n", encoding="utf-8")
            reports = {}
            for label, binary in binaries.items():
                reports[label] = read_document(native.run([binary, "dead", "--project", project, "--index-store", index,
                    "--config", config, "--report-format", "json"], project, name + "-" + label))
            if native.base.fingerprint(index) != captured:
                raise ValueError("Compiler index changed between paired reports")
            old, new = (findings(reports[label]) for label in ["before", "after"])
            added = []
            for key in sorted(new.keys() - old.keys()):
                item = new[key]
                added.append({"diagnostic": item, "sourceMentions": source_mentions(project, item),
                              "reviewKey": digest([revision, original, restored, includes, item])})
            results["projects"].append({"name": name, "repository": repository, "revision": revision,
                "include": includes, "sameIndex": captured, "beforeCount": len(old), "afterCount": len(new),
                "newlyReported": added, "noLongerReported": [old[key] for key in sorted(old.keys() - new.keys())],
                "limitations": {label: doc.get("limitations", []) for label, doc in reports.items()}})
            save(output / "results.json", results)
        results["measurementsComplete"] = True
        gate = review_status(results, review)
        results["status"] = "passed" if gate["status"] == "passed" else "manual-review-pending"
        results["reviewGate"] = gate
        save(output / "manual-review-template.json", {"reviews": [
            {"reviewKey": key, "reviewer": "", "decision": "pending", "evidence": ""}
            for key in gate["pendingReviewKeys"]]})
        print(json.dumps({"status": results["status"], "projects": len(results["projects"]), "reviewGate": gate}))
        return 0 if gate["status"] == "passed" else 3
    finally:
        results["measurements"] = native.measurements
        save(output / "results.json", results)
        lines = ["# C-P1-3 paired native measurement", "", "Status: " + results["status"], "",
                 "| Public project | Before | After | Newly reported | No longer reported |", "|---|---:|---:|---:|---:|"]
        lines += [f'| {p["name"]} @ {p["revision"]} | {p["beforeCount"]} | {p["afterCount"]} | '
                  f'{len(p["newlyReported"])} | {len(p["noLongerReported"])} |' for p in results["projects"]]
        lines += ["", "Full limitations, source-name occurrences and exact input identities are in results.json.",
                  "Native measurements do not replace the mandatory manual review of newly reported declarations."]
        (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
