#!/usr/bin/env python3
"""Verify current Core Data version selection against momc and actual model object creation."""

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cartograph", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    binary = args.cartograph.resolve()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-model-versions-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "project"
    corpus = Path(__file__).resolve().parents[1] / "Fixtures/CoreDataVersionCorpus"
    shutil.copytree(corpus, project, ignore=shutil.ignore_patterns(".build"))
    source = project / "Sources/CoreDataVersionProbe"
    model = source / "Resources/Store.xcdatamodeld"
    marker = model / ".xccurrentversion"
    result = {"status": "failed"}

    def run(command, label, expected=0, cwd=project):
        process = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=180)
        (output / f"{label}.stdout.log").write_text(process.stdout)
        (output / f"{label}.stderr.log").write_text(process.stderr)
        if expected is not None and process.returncode != expected:
            raise RuntimeError(f"{label}: expected exit {expected}, got {process.returncode}; see {output}")
        return process

    def choose(name):
        marker.write_bytes(plistlib.dumps({"_XCCurrentVersionName": name}))

    try:
        generated = source / "Generated"
        generated.mkdir()
        run(["xcrun", "momc", "--action", "generate", "--swift-version", "5.0", "--module", "CoreDataVersionProbe",
             str(model / "V2.xcdatamodel"), str(generated)], "generate-category")
        assert list(generated.glob("*+CoreDataProperties.swift"))
        assert not list(generated.glob("*+CoreDataClass.swift"))
        scratch = output / "build"
        build = ["swift", "build", "--package-path", str(project), "--scratch-path", str(scratch)]
        run(build, "build")
        bin_path = Path(run(build + ["--show-bin-path"], "bin-path").stdout.strip())
        store = next(p for p in [scratch / "out", scratch / "index/store", bin_path / "index/store"]
                     if (p / "v5/units").is_dir() or (p / "units").is_dir())
        executable = bin_path / "CoreDataVersionProbe"
        common = ["--project", str(project), "--index-store", str(store)]

        def document(command, label):
            return json.loads(run([str(binary)] + command + common, label).stdout)

        def check_selection(label, class_name):
            compiled = output / f"{label}.momd"
            run(["xcrun", "momc", "--module", "CoreDataVersionProbe", str(model), str(compiled)], label + "-momc")
            actual = run([str(executable), str(compiled)], label + "-runtime").stdout
            assert actual.strip() == "loaded=" + class_name, actual
            report = document(["runtime", "discover"], label + "-discover")
            classes = [target["name"] for finding in report["findings"]
                       if finding["kind"] == "coreDataEntityClass" and finding["status"] == "resolved"
                       for target in finding["targets"]]
            assert classes == [class_name], classes
            assert any("migration" in (finding.get("reason") or "") for finding in report["findings"])
            impact = document(["impact", "--file", str(marker), "--format", "json"], label + "-impact")
            assert impact["status"] == "found" and [s["name"] for s in impact["selected"]] == [class_name], impact

        check_selection("v2", "CurrentRecord")
        before = document(["snapshot"], "before-snapshot")
        before_path = output / "before.json"
        before_path.write_text(json.dumps(before, sort_keys=True) + "\n")
        assert any(item["path"].endswith(".xccurrentversion") for item in before["runtimeFiles"])
        run(["git", "init", "--quiet", "--initial-branch=fixture"], "git-init")
        run(["git", "add", "Sources", "Package.swift"], "git-add")
        run(["git", "-c", "user.name=Cartograph Fixture", "-c", "user.email=fixture@example.invalid",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
             "commit", "-m", "test: Core Data fixture baseline", "--quiet"], "git-commit")
        choose("V1.xcdatamodel")
        check_selection("v1", "LegacyRecord")
        comparison = document(["impact", "--file", str(marker), "--before", str(before_path), "--format", "json"],
                              "compare")
        assert [s["name"] for s in comparison["before"]["selected"]] == ["CurrentRecord"]
        assert [s["name"] for s in comparison["current"]["selected"]] == ["LegacyRecord"]
        since = document(["impact", "--since", "HEAD", "--format", "json"], "since")
        assert since["status"] == "found" and [s["name"] for s in since["selected"]] == ["LegacyRecord"]
        for label, value in [("missing-version", "Missing.xcdatamodel"), ("traversal", "../V1.xcdatamodel")]:
            choose(value)
            report = document(["runtime", "discover"], label)
            assert report["connectionCount"] == 0, report
            assert any("current version" in x for x in report["limitations"])
        choose("V2.xcdatamodel")
        filtered_config = output / "filtered.yml"
        filtered_config.write_text(
            "include:\n  - Sources/**/*.swift\n"
            "  - Sources/CoreDataVersionProbe/Resources/Store.xcdatamodeld/V1.xcdatamodel/contents\n"
        )
        filtered = document(["runtime", "discover", "--config", str(filtered_config)], "excluded-marker")
        assert filtered["connectionCount"] == 0, filtered
        assert any("current version" in (f.get("reason") or "") for f in filtered["findings"]), filtered
        with filtered_config.open("a") as config:
            config.write("  - Sources/CoreDataVersionProbe/Resources/Store.xcdatamodeld/.xccurrentversion\n")
        excluded = document(["runtime", "discover", "--config", str(filtered_config)], "excluded-selected-version")
        assert excluded["connectionCount"] == 0, excluded
        assert any("excluded" in value for value in excluded["limitations"]), excluded
        saved_marker = marker.read_bytes()
        external_marker = output / "external-current-version.plist"
        external_marker.write_bytes(saved_marker)
        marker.unlink()
        marker.symlink_to(external_marker)
        linked = document(["runtime", "discover"], "symlink-marker")
        assert linked["connectionCount"] == 0, linked
        assert len(linked["findings"]) == 2 and all(
            f["status"] == "unresolved" and "current version" in (f.get("reason") or "")
            for f in linked["findings"]
        ), linked
        marker.unlink()
        marker.write_bytes(saved_marker)
        negatives = source / "Resources/Negatives"
        negatives.mkdir()

        def write_model(name, attributes):
            path = negatives / (name + ".xcdatamodel")
            path.mkdir()
            (path / "contents").write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" sourceLanguage="Swift">'
                '<entity name="Record" ' + attributes + '/></model>\n'
            )
            return path

        invalid_manual = write_model("InvalidManual", 'representedClassName="CurrentRecord" codeGenerationType="manual"')
        rejected = run(["xcrun", "momc", str(invalid_manual), str(output / "manual.mom")],
                       "manual-attribute", expected=None)
        manual_rejected = rejected.returncode != 0
        result.update(manualAttributeMomcExitCode=rejected.returncode,
                      manualAttributeMomcProducedModel=(output / "manual.mom").is_file())
        custom_only = write_model("CustomOnly", 'customClass="CurrentRecord"')
        custom_mom = output / "custom-only.mom"
        run(["xcrun", "momc", str(custom_only), str(custom_mom)], "custom-only-momc")
        custom_actual = run([str(executable), str(custom_mom)], "custom-only-runtime")
        assert custom_actual.stdout.strip() == "loaded=NSManagedObject", custom_actual.stdout

        manual_source = output / "ManualAlias.swift"
        manual_source.write_text('import CoreData\n@objc(AliasRecord) public final class SwiftNamedRecord: NSManagedObject {}\n')
        for name, generation, expected_error in [
            ("CategoryAliasMismatch", "category", "cannot find type 'AliasRecord'"),
            ("GeneratedClassCollision", "class", "duplicate symbol"),
        ]:
            path = write_model(name, 'representedClassName="AliasRecord" codeGenerationType="' + generation + '"')
            generated_negative = output / name
            generated_negative.mkdir()
            run(["xcrun", "momc", "--action", "generate", "--swift-version", "5.0", "--module", "CoreDataVersionProbe",
                 str(path), str(generated_negative)], name + "-generate")
            compiled = run(["xcrun", "swiftc", "-emit-library", "-module-name", "CoreDataVersionProbe",
                            str(manual_source)] + [str(p) for p in sorted(generated_negative.glob("*.swift"))]
                           + ["-o", str(output / (name + ".dylib"))], name + "-compile", expected=None)
            assert compiled.returncode != 0 and expected_error in compiled.stderr, compiled.stderr
        negative_report = document(["runtime", "discover"], "negative-models")
        negative_findings = [f for f in negative_report["findings"] if "/Negatives/" in f["location"]["path"]]
        assert {Path(f["location"]["path"]).parent.stem for f in negative_findings} == {
            "InvalidManual", "CustomOnly", "CategoryAliasMismatch", "GeneratedClassCollision",
        }, negative_findings
        assert len(negative_findings) == 4, negative_findings
        for finding in negative_findings:
            assert finding["status"] in ["unresolved", "unindexed"] and not finding["targets"], finding
        invalid_manual_findings = [
            finding for finding in negative_findings
            if Path(finding["location"]["path"]).parent.stem == "InvalidManual"
        ]
        assert len(invalid_manual_findings) == 1, invalid_manual_findings
        invalid_manual_finding = invalid_manual_findings[0]
        assert invalid_manual_finding["status"] == "unresolved"
        assert "unsupported code generation" in (invalid_manual_finding.get("reason") or "")
        result.update(status="passed", selectedClasses=["CurrentRecord", "LegacyRecord"],
                      generatedCategoryCompiled=True, snapshotAndSincePassed=True,
                      excludedSelectionsRejected=True, symlinkMarkerRejected=True,
                      inactiveMigrationReviewPreserved=True, invalidSelectionsRejected=True,
                      manualAttributeRejectedByMomc=manual_rejected,
                      unsupportedManualKeptUnresolved=True, customClassIgnoredByRuntime=True,
                      generatedAliasMismatchRejected=True, generatedClassCollisionRejected=True)
    finally:
        (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
