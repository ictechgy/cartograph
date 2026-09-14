#!/usr/bin/env python3
"""Verify Core Data build evidence with momc, Swift compiler metadata and an actual app bundle."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--cartograph", type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    corpus = repository / "Fixtures/CoreDataBuildEvidenceCorpus"
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="cartograph-coredata-build-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    project = output / "corpus"
    shutil.copytree(corpus, project)
    result = {"status": "failed"}

    def run(command, label, expected=0, environment=None):
        process = subprocess.run(
            [str(item) for item in command], cwd=project, capture_output=True, text=True,
            timeout=180, env=environment,
        )
        (output / f"{label}.stdout.log").write_text(process.stdout)
        (output / f"{label}.stderr.log").write_text(process.stderr)
        if process.returncode != expected:
            raise RuntimeError(f"{label}: expected exit {expected}, got {process.returncode}; see {output}")
        return process

    try:
        model = project / "Models/Store.xcdatamodeld"
        generated = output / "Generated"
        generated.mkdir()
        run([
            "xcrun", "momc", "--action", "generate", "--swift-version", "5.0",
            "--module", "CoreDataBuildEvidenceProbe", model / "V2.xcdatamodel", generated,
        ], "generate-swift")
        class_source = generated / "GeneratedRecord+CoreDataClass.swift"
        generated_sources = sorted(generated.glob("*.swift"))
        if not class_source.is_file() or len(generated_sources) < 2:
            raise RuntimeError("momc did not produce the expected generated class and properties sources")

        app = output / "CoreDataBuildEvidenceProbe.app"
        executable = app / "Contents/MacOS/CoreDataBuildEvidenceProbe"
        resources = app / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        modules = output / "AppModules"
        modules.mkdir()
        index_store = output / "IndexStore"
        run([
            "xcrun", "swiftc", "-swift-version", "5", "-module-name", "CoreDataBuildEvidenceProbe",
            "-emit-executable", "-emit-module", "-emit-module-path", modules / "CoreDataBuildEvidenceProbe.swiftmodule",
            "-index-store-path", index_store,
            *generated_sources, project / "Sources/main.swift", "-framework", "CoreData", "-o", executable,
        ], "build-app")
        info_path = app / "Contents/Info.plist"
        info = {
            "CFBundleIdentifier": "dev.cartograph.CoreDataBuildEvidenceProbe",
            "CFBundleExecutable": "CoreDataBuildEvidenceProbe",
            "CFBundlePackageType": "APPL",
        }
        info_path.write_bytes(plistlib.dumps(info))
        compiled = resources / "Store.momd"
        run([
            "xcrun", "momc", "--module", "CoreDataBuildEvidenceProbe", model, compiled,
        ], "compile-model")
        actual = run([executable], "run-app").stdout.strip()
        if "loaded=GeneratedRecord;fetched=1;separate=1" not in actual:
            raise RuntimeError(f"NSPersistentContainer did not instantiate GeneratedRecord: {actual}")

        symbols = output / "SymbolGraphs"
        symbols.mkdir()
        target = run(["xcrun", "swiftc", "-print-target-info"], "target-info")
        target_info = json.loads(target.stdout)
        triple = target_info["target"]["triple"]
        sdk = run(["xcrun", "--show-sdk-path"], "sdk-path").stdout.strip()
        run([
            "xcrun", "swift-symbolgraph-extract", "-module-name", "CoreDataBuildEvidenceProbe",
            "-I", modules, "-target", triple, "-sdk", sdk, "-minimum-access-level", "public",
            "-output-dir", symbols,
        ], "extract-symbols")
        symbol_documents = [json.loads(path.read_text()) for path in symbols.glob("*.symbols.json")]
        class_symbols = [
            symbol for document in symbol_documents for symbol in document["symbols"]
            if symbol["kind"]["identifier"] == "swift.class"
            and symbol["names"]["title"] == "GeneratedRecord"
        ]
        if len(class_symbols) != 1:
            raise RuntimeError(f"expected one generated class symbol, found {len(class_symbols)}")
        generated_usr = class_symbols[0]["identifier"]["precise"]

        module_dir = output / "EvidenceModules"
        module_dir.mkdir()
        core_sources = sorted((repository / "Sources/CartographCore").rglob("*.swift"))
        core_library = module_dir / "libCartographCore.dylib"
        run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-emit-library", "-emit-module",
            "-module-name", "CartographCore", "-emit-module-path", module_dir / "CartographCore.swiftmodule",
            *core_sources, "-o", core_library,
        ], "build-core-module")
        kit_library = module_dir / "libCartographKit.dylib"
        run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-emit-library", "-emit-module",
            "-module-name", "CartographKit", "-emit-module-path", module_dir / "CartographKit.swiftmodule",
            "-I", module_dir, "-L", module_dir, "-lCartographCore", "-framework", "CoreData",
            repository / "Sources/CartographKit/CoreDataVersionSelection.swift",
            repository / "Sources/CartographKit/CoreDataLinkedClassInspector.swift",
            repository / "Sources/CartographKit/CoreDataBuildEvidenceStore.swift", "-o", kit_library,
        ], "build-kit-module")
        driver = output / "evidence-driver"
        run([
            "xcrun", "swiftc", "-swift-version", "6", "-I", module_dir, "-L", module_dir,
            "-lCartographKit", "-lCartographCore", "-framework", "CoreData",
            project / "Sources/EvidenceDriver.swift", "-o", driver,
        ], "build-driver")
        environment = dict(os.environ)
        environment["DYLD_LIBRARY_PATH"] = str(module_dir)
        evidence = output / "build-evidence.json"
        driver_arguments = [
            driver, "create", evidence, executable, model, class_source,
            "CoreDataBuildEvidenceProbe", generated_usr,
        ]
        run(driver_arguments, "create-evidence", environment=environment)
        document = json.loads(evidence.read_text())
        if document["format"] != "coredata-build-evidence" or document["version"] != 1:
            raise RuntimeError("producer wrote the wrong build-evidence schema")
        if document["bundle"]["compiledModelRelativePath"] != "Store.momd":
            raise RuntimeError("persistent container was not bound to the exact main-bundle model")
        if document["declaredGeneratedMappings"][0]["declarationUSRs"] != [generated_usr]:
            raise RuntimeError("the extracted compiler USR was not preserved")
        linked_symbols = set(document["declaredGeneratedMappings"][0]["linkedBinarySymbols"])
        if linked_symbols != {
            "_$s26CoreDataBuildEvidenceProbe15GeneratedRecordCMn",
            "_$s26CoreDataBuildEvidenceProbe15GeneratedRecordCN",
            "_OBJC_CLASS_$_GeneratedRecord",
        }:
            raise RuntimeError("the generated class was not proven in the app executable symbol table")
        verify_arguments = [driver, "verify", evidence, executable, model, class_source,
                            "CoreDataBuildEvidenceProbe", generated_usr]
        run(verify_arguments, "verify-evidence", environment=environment)

        def rejects_mutation(path, replacement, label):
            original = path.read_bytes()
            original_stat = path.stat()
            try:
                path.write_bytes(replacement(original))
                run(verify_arguments, label, expected=1, environment=environment)
            finally:
                path.write_bytes(original)
                os.utime(path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))

        rejects_mutation(class_source, lambda data: data + b"\n// changed\n", "reject-generated-change")
        rejects_mutation(executable, lambda data: data + b"changed", "reject-executable-change")
        rejects_mutation(
            model / "V2.xcdatamodel/contents", lambda data: data + b"\n<!-- changed -->\n",
            "reject-source-model-change",
        )
        rejects_mutation(
            model / ".xccurrentversion",
            lambda _: plistlib.dumps({"_XCCurrentVersionName": "V1.xcdatamodel"}),
            "reject-marker-change",
        )
        compiled_member = compiled / "V2.mom"
        rejects_mutation(compiled_member, lambda data: data + b"changed", "reject-compiled-model-change")

        marker = model / ".xccurrentversion"
        saved_marker = marker.read_bytes()
        try:
            marker.write_bytes(plistlib.dumps({"_XCCurrentVersionName": "V1.xcdatamodel"}))
            run(driver_arguments, "reject-current-version-mismatch", expected=1, environment=environment)
        finally:
            marker.write_bytes(saved_marker)

        duplicate = resources / "Store.mom"
        duplicate.write_bytes(b"duplicate")
        try:
            run(driver_arguments, "reject-duplicate-resource", expected=1, environment=environment)
        finally:
            duplicate.unlink()

        external = output / "ExternalStore.momd"
        compiled.rename(external)
        compiled.symlink_to(external, target_is_directory=True)
        try:
            run(driver_arguments, "reject-resource-symlink", expected=1, environment=environment)
        finally:
            compiled.unlink()
            external.rename(compiled)

        saved_info = info_path.read_bytes()
        try:
            bad_info = dict(info, CFBundleIdentifier="invalid bundle id")
            info_path.write_bytes(plistlib.dumps(bad_info))
            run(driver_arguments, "reject-bundle-identifier", expected=1, environment=environment)
        finally:
            info_path.write_bytes(saved_info)

        cli_verified = True
        if args.cartograph is not None:
            binary = args.cartograph.resolve()
            common = ["--project", project, "--index-store", index_store]
            cli_evidence = output / "cli-build-evidence.json"
            prepare = [
                binary, "runtime", "prepare-coredata",
                "--model", model,
                "--container", "Store",
                "--executable", executable,
                "--generated-source", class_source,
                "--module", "CoreDataBuildEvidenceProbe",
                "-o", cli_evidence,
                *common,
            ]
            run(prepare, "cli-prepare")
            cli_document = json.loads(cli_evidence.read_text())
            if cli_document["declaredGeneratedMappings"][0]["declarationUSRs"] != [generated_usr]:
                raise RuntimeError("prepare-coredata did not select the exact generated class USR")
            if set(cli_document["declaredGeneratedMappings"][0]["linkedBinarySymbols"]) != linked_symbols:
                raise RuntimeError("prepare-coredata did not bind the class to the supplied executable")

            unlinked_app = output / "UnlinkedProbe.app"
            unlinked_executable = unlinked_app / "Contents/MacOS/UnlinkedProbe"
            unlinked_resources = unlinked_app / "Contents/Resources"
            unlinked_executable.parent.mkdir(parents=True)
            unlinked_resources.mkdir(parents=True)
            unlinked_main = output / "UnlinkedSources/main.swift"
            unlinked_main.parent.mkdir()
            unlinked_main.write_text("print(\"unlinked\")\n")
            run([
                "xcrun", "swiftc", "-swift-version", "5", unlinked_main, "-o", unlinked_executable,
            ], "build-unlinked-app")
            (unlinked_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "dev.cartograph.UnlinkedProbe",
                "CFBundleExecutable": "UnlinkedProbe",
                "CFBundlePackageType": "APPL",
            }))
            shutil.copytree(compiled, unlinked_resources / "Store.momd")
            unlinked_evidence = output / "unlinked-evidence.json"
            unlinked_prepare = list(prepare)
            unlinked_prepare[unlinked_prepare.index("--executable") + 1] = unlinked_executable
            unlinked_prepare[unlinked_prepare.index("-o") + 1] = unlinked_evidence
            run(unlinked_prepare, "cli-reject-unlinked-generated-class", expected=2)
            if unlinked_evidence.exists():
                raise RuntimeError("prepare-coredata accepted a generated class absent from the app executable")

            plain = json.loads(run([
                binary, "runtime", "discover", "--limit", "100", *common,
            ], "cli-discover-without-evidence").stdout)
            plain_core_data = [row for row in plain["findings"] if row["kind"] == "coreDataEntityClass"]
            if any(row["status"] == "resolved" for row in plain_core_data):
                raise RuntimeError("default runtime discovery unexpectedly included generated build output")
            plain_source_bindings = [
                row for row in plain["findings"]
                if row["kind"] in {"coreDataContainer", "coreDataFetch"}
            ]
            if len(plain_source_bindings) != 7 or any(row["status"] == "resolved" for row in plain_source_bindings):
                raise RuntimeError("Core Data source boundaries resolved without explicit build evidence")
            query = json.loads(run([
                binary, "query", "GeneratedRecord", *common,
            ], "cli-query-default-scope", expected=64).stdout)
            if query["status"] != "notFound":
                raise RuntimeError("default query unexpectedly included the supplemental generated class")
            dead = run([binary, "dead", *common], "cli-dead-default-scope").stdout
            if "GeneratedRecord" in dead:
                raise RuntimeError("default dead analysis unexpectedly included the supplemental generated class")

            augmented = json.loads(run([
                binary, "runtime", "discover", "--limit", "100",
                "--coredata-build-evidence", cli_evidence, *common,
            ], "cli-discover-with-evidence").stdout)
            generated_findings = [
                row for row in augmented["findings"]
                if row["kind"] == "coreDataEntityClass" and row["status"] == "resolved"
            ]
            if len(generated_findings) != 1:
                raise RuntimeError(f"expected one resolved generated Core Data class: {generated_findings}")
            targets = generated_findings[0].get("targets", [])
            if len(targets) != 1 or targets[0]["name"] != "GeneratedRecord":
                raise RuntimeError(f"runtime discovery selected the wrong generated target: {targets}")
            containers = [row for row in augmented["findings"] if row["kind"] == "coreDataContainer"]
            fetches = [row for row in augmented["findings"] if row["kind"] == "coreDataFetch"]
            if len(containers) != 3 or any(row["status"] != "resolved" for row in containers):
                raise RuntimeError("the proven local persistent container did not bind to model metadata")
            if [row["status"] for row in fetches].count("resolved") != 1 or len(fetches) != 4:
                raise RuntimeError("fetch from an unrelated context was accepted or the proven fetch was lost")
            if any(
                row["status"] == "resolved" and [target["name"] for target in row["targets"]] != ["GeneratedRecord"]
                for row in containers + fetches
            ):
                raise RuntimeError("a Core Data source boundary selected the wrong model class")

            selected_contents = model / "V2.xcdatamodel/contents"
            impact = json.loads(run([
                binary, "impact", "--file", selected_contents, "--format", "json",
                "--coredata-build-evidence", cli_evidence, *common,
            ], "cli-impact").stdout)
            if impact["status"] != "found" or [item["name"] for item in impact["selected"]] != ["GeneratedRecord"]:
                raise RuntimeError("impact did not seed the verified generated class from the model resource")
            affected_names = {item["symbol"]["name"] for item in impact["affected"]}
            if (
                "exerciseVerifiedContainer()" not in affected_names
                or "sameEntityFromUnprovenContext(_:)" in affected_names
            ):
                raise RuntimeError("impact did not preserve the proven source-to-class boundary")

            mcp_spec = importlib.util.spec_from_file_location(
                "cartograph_verify_mcp", repository / "Scripts/verify-mcp.py"
            )
            if mcp_spec is None or mcp_spec.loader is None:
                raise RuntimeError("could not load the MCP verification helper")
            mcp_module = importlib.util.module_from_spec(mcp_spec)
            mcp_spec.loader.exec_module(mcp_module)
            manifest = project / ".cartograph/coredata.json"
            manifest.parent.mkdir()
            shutil.copy2(cli_evidence, manifest)
            mcp = mcp_module.MCPProcess(
                binary,
                project,
                output / "coredata-mcp.stderr.log",
                extra_arguments=[
                    "--index-store", str(index_store),
                    "--coredata-build-evidence", str(manifest),
                ],
            )
            try:
                discovered = mcp.request(1, "server/discover", mcp_module.modern_params())
                if discovered["result"]["resultType"] != "complete":
                    raise RuntimeError("Core Data MCP server discovery was incomplete")

                def mcp_call(request_id, name, arguments):
                    return mcp.request(
                        request_id,
                        "tools/call",
                        mcp_module.modern_params(name=name, arguments=arguments),
                    )

                runtime_response = mcp_call(2, "cartograph_runtime_discover", {"limit": 100})
                runtime_payload = runtime_response["result"]["structuredContent"]
                metadata = runtime_payload.get("coreDataBuildEvidence")
                if metadata != {"status": "verifiedCurrent", "supplementalSources": 1}:
                    raise RuntimeError(f"MCP runtime metadata does not identify current evidence: {metadata}")
                mcp_findings = runtime_payload["result"]["findings"]
                if not any(
                    row["kind"] == "coreDataFetch"
                    and row["status"] == "resolved"
                    and [target["name"] for target in row["targets"]] == ["GeneratedRecord"]
                    for row in mcp_findings
                ):
                    raise RuntimeError("MCP runtime discovery lost the verified fetch binding")

                impact_response = mcp_call(3, "cartograph_impact", {"files": [str(selected_contents)]})
                impact_payload = impact_response["result"]["structuredContent"]
                if impact_payload.get("coreDataBuildEvidence") != metadata:
                    raise RuntimeError("MCP impact did not report its separate evidence metadata")
                if [item["name"] for item in impact_payload["result"]["selected"]] != ["GeneratedRecord"]:
                    raise RuntimeError("MCP impact lost the verified generated class")

                query_response = mcp_call(4, "cartograph_query", {"symbols": ["GeneratedRecord"]})
                query_payload = query_response["result"]["structuredContent"]
                if query_payload["result"]["results"][0]["status"] != "notFound":
                    raise RuntimeError("MCP query unexpectedly widened its base session scope")
                if query_payload.get("coreDataBuildEvidence") is not None:
                    raise RuntimeError("MCP query incorrectly claimed Core Data augmentation")

                def mcp_rejects_mutation(path, replacement, request_id, label):
                    original = path.read_bytes()
                    original_stat = path.stat()
                    try:
                        path.write_bytes(replacement(original))
                        response = mcp_call(request_id, "cartograph_runtime_discover", {"limit": 100})
                        if not response["result"]["isError"]:
                            raise RuntimeError(f"MCP reused stale evidence after {label}")
                    finally:
                        path.write_bytes(original)
                        os.utime(path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))

                mcp_rejects_mutation(
                    class_source,
                    lambda data: data + b"\n// stale MCP source\n",
                    5,
                    "generated source change",
                )
                mcp_rejects_mutation(
                    compiled / "V2.mom",
                    lambda data: data + b"stale-mcp-model",
                    6,
                    "compiled model change",
                )
                mcp_rejects_mutation(
                    manifest,
                    lambda data: data.replace(b'"version" : 1', b'"version" : 99', 1),
                    7,
                    "manifest change",
                )
                recovered = mcp_call(8, "cartograph_runtime_discover", {"limit": 100})
                if recovered["result"]["isError"]:
                    raise RuntimeError("MCP server did not recover after restoring valid evidence")
            finally:
                if mcp.close() != 0:
                    raise RuntimeError("Core Data MCP server did not exit cleanly")

            plain_snapshot = json.loads(run([binary, "snapshot", *common], "cli-snapshot-plain").stdout)
            augmented_snapshot_process = run([
                binary, "snapshot", "--coredata-build-evidence", cli_evidence, *common,
            ], "cli-snapshot-augmented")
            augmented_snapshot = json.loads(augmented_snapshot_process.stdout)
            generated_path = str(class_source.resolve())
            plain_paths = {row["location"]["path"] for row in plain_snapshot["snapshot"]["symbols"]}
            augmented_paths = {row["location"]["path"] for row in augmented_snapshot["snapshot"]["symbols"]}
            if generated_path in plain_paths or generated_path not in augmented_paths:
                raise RuntimeError("snapshot augmentation did not stay behind the explicit evidence option")
            before_path = output / "cli-before.json"
            before_path.write_text(augmented_snapshot_process.stdout)
            comparison = json.loads(run([
                binary, "impact", "--file", selected_contents, "--before", before_path,
                "--format", "json", "--coredata-build-evidence", cli_evidence, *common,
            ], "cli-impact-before").stdout)
            if comparison["status"] != "found":
                raise RuntimeError("historical snapshot comparison lost verified generated-class facts")

            outside_model = output / "OutsideStore.xcdatamodeld"
            shutil.copytree(model, outside_model)
            scope_failure = output / "scope-failure-evidence.json"
            outside_prepare = list(prepare)
            outside_prepare[outside_prepare.index("--model") + 1] = outside_model
            outside_prepare[outside_prepare.index("-o") + 1] = scope_failure
            run(outside_prepare, "cli-reject-model-outside-scope", expected=2)
            if scope_failure.exists():
                raise RuntimeError("prepare-coredata wrote evidence before rejecting source model scope")

            original_class = class_source.read_bytes()
            try:
                class_source.write_bytes(original_class + b"\n// stale\n")
                run([
                    binary, "runtime", "discover", "--coredata-build-evidence", cli_evidence, *common,
                ], "cli-reject-stale-evidence", expected=2)
            finally:
                class_source.write_bytes(original_class)

            collision_source = project / "Sources/Collision.swift"
            collision_source.write_text(
                "import CoreData\n"
                "@objc(GeneratedRecord) public final class OtherRecord: NSManagedObject {}\n"
            )
            try:
                run([
                    "xcrun", "swiftc", "-swift-version", "5", "-typecheck",
                    "-module-name", "CollisionProbe", "-index-store-path", index_store,
                    collision_source,
                ], "compile-runtime-alias-collision")
                collision_prepare = list(prepare)
                collision_prepare[collision_prepare.index("-o") + 1] = output / "collision-evidence.json"
                run(collision_prepare, "cli-reject-runtime-alias-collision", expected=2)
            finally:
                collision_source.unlink(missing_ok=True)

            duplicate_source = project / "Sources/Duplicate.swift"
            duplicate_source.write_text(
                "import CoreData\n"
                "@objc(GeneratedRecord) public class GeneratedRecord: NSManagedObject {}\n"
            )
            try:
                run([
                    "xcrun", "swiftc", "-swift-version", "5", "-typecheck",
                    "-module-name", "CoreDataBuildEvidenceProbe", "-index-store-path", index_store,
                    duplicate_source,
                ], "compile-usr-collision")
                duplicate_prepare = list(prepare)
                duplicate_prepare[duplicate_prepare.index("-o") + 1] = output / "duplicate-usr-evidence.json"
                run(duplicate_prepare, "cli-reject-usr-collision", expected=2)
            finally:
                duplicate_source.unlink(missing_ok=True)

            manual_model = project / "Models/ManualStore.xcdatamodel"
            manual_model.mkdir()
            (manual_model / "contents").write_text(
                "<model>"
                "<entity name=\"Parent\" representedClassName=\"ParentRecord\" "
                "codeGenerationType=\"category\"/>"
                "<entity name=\"Child\" representedClassName=\"ChildRecord\" "
                "parentEntity=\"Parent\" codeGenerationType=\"category\"/>"
                "</model>\n"
            )
            manual_source = project / "Sources/ManualRecord.swift"
            manual_source.write_text(
                "import CoreData\n"
                "@objc(ParentRecord) public class ParentRecord: NSManagedObject {}\n"
                "@objc(ChildRecord) public final class ChildRecord: ParentRecord {}\n"
                "public func prepareManualContainer() throws {\n"
                "    let container = NSPersistentContainer(name: \"ManualStore\")\n"
                "    let context = container.viewContext\n"
                "    let request = NSFetchRequest<NSManagedObject>(entityName: \"Parent\")\n"
                "    _ = try context.fetch(request)\n"
                "}\n"
                "public func parentOnlyManualFetch() throws {\n"
                "    let container = NSPersistentContainer(name: \"ManualStore\")\n"
                "    let context = container.viewContext\n"
                "    let request = NSFetchRequest<NSManagedObject>(entityName: \"Parent\")\n"
                "    request.includesSubentities = false\n"
                "    _ = try context.fetch(request)\n"
                "}\n"
            )
            manual_app = output / "ManualProbe.app"
            manual_executable = manual_app / "Contents/MacOS/ManualProbe"
            manual_resources = manual_app / "Contents/Resources"
            manual_executable.parent.mkdir(parents=True)
            manual_resources.mkdir(parents=True)
            manual_main = output / "ManualSources/main.swift"
            manual_main.parent.mkdir()
            manual_main.write_text("print(\"manual\")\n")
            run([
                "xcrun", "swiftc", "-swift-version", "5", "-module-name", "ManualProbe",
                "-index-store-path", index_store, manual_source, manual_main,
                "-framework", "CoreData", "-o", manual_executable,
            ], "build-manual-app")
            (manual_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "dev.cartograph.ManualProbe",
                "CFBundleExecutable": "ManualProbe",
                "CFBundlePackageType": "APPL",
            }))
            run([
                "xcrun", "momc", "--module", "ManualProbe", manual_model,
                manual_resources / "ManualStore.mom",
            ], "compile-manual-model")
            manual_evidence = output / "manual-evidence.json"
            run([
                binary, "runtime", "prepare-coredata",
                "--model", manual_model,
                "--container", "ManualStore",
                "--executable", manual_executable,
                "-o", manual_evidence,
                *common,
            ], "cli-prepare-manual-category")
            manual_document = json.loads(manual_evidence.read_text())
            if manual_document["declaredGeneratedMappings"]:
                raise RuntimeError("manual/category model unexpectedly required a generated class mapping")
            manual_discovery = json.loads(run([
                binary, "runtime", "discover", "--coredata-build-evidence", manual_evidence, *common,
            ], "cli-discover-manual-category").stdout)
            manual_containers = [
                row for row in manual_discovery["findings"]
                if row["kind"] == "coreDataContainer" and row["status"] == "resolved"
            ]
            if len(manual_containers) != 2 or any(
                {target["name"] for target in row["targets"]} != {"ParentRecord", "ChildRecord"}
                for row in manual_containers
            ):
                raise RuntimeError("manual/category container did not bind to its indexed class")
            manual_fetches = [
                row for row in manual_discovery["findings"]
                if row["kind"] == "coreDataFetch"
                and row.get("source", {}).get("name")
                in {"prepareManualContainer()", "parentOnlyManualFetch()"}
            ]
            resolved_manual_fetches = [row for row in manual_fetches if row["status"] == "resolved"]
            if len(resolved_manual_fetches) != 1 or {
                target["name"] for target in resolved_manual_fetches[0]["targets"]
            } != {"ParentRecord", "ChildRecord"}:
                raise RuntimeError("default parent fetch did not include the verified child entity class")
            if len(manual_fetches) != 2 or not any(row["status"] == "unresolved" for row in manual_fetches):
                raise RuntimeError("includesSubentities mutation was not kept unresolved")

        result = {
            "status": "passed",
            "mainBundleContainerLoaded": True,
            "compilerUSRPreservedAsDeclaredMapping": True,
            "sourceMarkerBinaryCompiledAndGeneratedChangesRejected": True,
            "generatedClassLinkedInExecutable": True,
            "currentVersionMismatchRejected": True,
            "duplicateResourceRejected": True,
            "resourceSymlinkRejected": True,
            "malformedBundleIdentifierRejected": True,
            "actualCLIWorkflowVerified": cli_verified,
            "defaultQueryAndDeadScopeUnchanged": cli_verified,
            "runtimeAliasAndUSRCollisionsRejected": cli_verified,
            "scopeFailureLeavesNoEvidenceFile": cli_verified,
            "manualCategoryEvidenceNeedsNoGeneratedSources": cli_verified,
            "sourceContainerAndFetchBindingsVerified": cli_verified,
            "fixedMCPWorkflowVerified": cli_verified,
            "defaultParentFetchIncludesDescendants": cli_verified,
        }
    finally:
        (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))
    print(f"Evidence: {output}")


if __name__ == "__main__":
    main()
