import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("로컬 package v2의 실제 바이트와 유한 소속 계약")
struct XcodeLocalPackageEvidenceTests {
    struct Fixture {
        var base: XcodeTargetScopeTests.Fixture
        let source: String
        let object: String
        let record: String
        let aggregate: String
        let map: String
        let response: String
        func scope() -> TargetScopeDocument { base.scope() }
        var package: XcodeLocalPackageEvidence {
            get throws {
                try JSONDecoder().decode(XcodeLocalPackageEvidence.self,
                    from: JSONSerialization.data(withJSONObject: base.receipt["localPackage"]!))
            }
        }
        mutating func changePackage(_ change: (inout [String: Any]) -> Void) throws {
            var value = base.receipt["localPackage"] as! [String: Any]
            change(&value); base.receipt["localPackage"] = value; try base.write()
        }
    }

    func fixture() throws -> Fixture {
        var base = try XcodeTargetScopeTests().fixture()
        let fs = base.fs, root = "/p/Packages/LocalMath", build = "/capture/DerivedData/Build"
        let intermediates = build + "/Intermediates.noindex", productsRoot = build + "/Products/Debug"
        let store = "/capture/DerivedData/Index.noindex/DataStore"
        let source = root + "/Sources/ArithmeticCore/Math.swift", object = intermediates + "/Math.o"
        let unitIdentity = "/virtual/Math.o", triple = "arm64-apple-macos10.13"
        let record = store + "/v5/records/ab/Math-record", aggregate = productsRoot + "/ArithmeticCore.o"
        let map = intermediates + "/OutputFileMap.json", sourceList = intermediates + "/Sources.SwiftFileList"
        let aggregateList = intermediates + "/Package.LinkFileList", aggregateMap = intermediates + "/Package.map"
        let linkList = intermediates + "/Core.LinkFileList", linkMap = intermediates + "/Core.map"
        let response = intermediates + "/linker-args.resp"
        let consumer = base.targets.first { $0.value.name == "CoreBlueprint" }!.key
        let executable = productsRoot + "/CoreKit.framework/Contents/MacOS/CoreKit"
        let nativeObject = intermediates + "/Core.o"

        var plist = try PropertyListSerialization.propertyList(from: fs.readData(at: "/p/Scope.xcodeproj/project.pbxproj"), format: nil) as! [String: Any]
        var objects = plist["objects"] as! [String: [String: Any]]
        let projectID = plist["rootObject"] as! String
        objects[projectID]?["packageReferences"] = ["package-ref"]
        objects["package-ref"] = ["isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/LocalMath"]
        objects["package-product"] = ["isa": "XCSwiftPackageProductDependency", "package": "package-ref", "productName": "ArithmeticProduct"]
        objects["package-file"] = ["isa": "PBXBuildFile", "productRef": "package-product"]
        objects[consumer]?["packageProductDependencies"] = ["package-product"]
        let phases = objects[consumer]!["buildPhases"] as! [String]
        let frameworks = phases.first { objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase" }!
        objects[frameworks]?["files"] = (objects[frameworks]?["files"] as? [String] ?? []) + ["package-file"]
        plist["objects"] = objects
        try fs.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: "/p/Scope.xcodeproj/project.pbxproj")
        try fs.write(text: """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "LocalMath", products: [.library(name: "ArithmeticProduct", targets: ["ArithmeticCore"])], targets: [.target(name: "ArithmeticCore")])
        """, to: root + "/Package.swift")
        try fs.write(text: "public func packageValue() -> Int { 1 }", to: source)
        fs.setModificationDate(Date(timeIntervalSince1970: 1), for: source)
        base.snapshot.indexedFileDates?[source] = .distantFuture
        base.snapshot.sourceRecordAdmissions?.append(.init(path: source, module: "ArithmeticCore", unit: "Math-unit",
            record: "Math-record", timestamp: .distantFuture, unitOutputIdentity: unitIdentity, unitTargetTriple: triple))

        var proofFiles: [String: Any] = [:]
        func put(_ path: String, _ bytes: Data, kind: String) throws {
            try fs.write(bytes, to: path)
            proofFiles[path] = ["sha256": TargetScopeStore.digest(bytes), "bytes": bytes.count, "kind": kind]
        }
        for path in [object, aggregate, nativeObject] { try put(path, Data(("compiled:" + path).utf8), kind: "object") }
        try put(record, Data("synthetic record bytes, not a native index".utf8), kind: "record")
        try put(executable, fs.readData(at: executable), kind: "object")
        try put(sourceList, Data((source + "\n").utf8), kind: "document")
        try put(map, JSONSerialization.data(withJSONObject: [source: ["object": object, "index-unit-output-path": unitIdentity]]), kind: "document")
        try put(aggregateList, Data((object + "\n").utf8), kind: "document")
        try put(linkList, Data((nativeObject + "\n" + aggregate + "\n").utf8), kind: "document")
        try put(response, Data("-lswiftCore -Xlinker -rpath -Xlinker @loader_path/../Frameworks".utf8), kind: "document")
        try put(aggregateMap, Self.linkMap(output: aggregate, owners: [object]), kind: "document")
        try put(linkMap, Self.linkMap(output: executable, owners: [nativeObject, aggregate]), kind: "document")
        func link(output: String, list: String, map: String, relocatable: Bool) -> [String: Any] {
            ["argv": ["/Xcode/clang", "-target", triple] + (relocatable ? ["-r"] : ["-dynamiclib"])
                + ["-filelist", list, "-Xlinker", "-map", "-Xlinker", map, "@" + response, "-o", output],
             "fileList": list, "output": output, "linkMap": map]
        }
        let compilation: [String: Any] = ["source": source, "argv": ["builtin-SwiftDriver", "--", "/Xcode/swiftc",
            "-module-name", "ArithmeticCore", "@" + sourceList, "-target", triple, "-index-store-path", store,
            "-output-file-map", map], "outputMap": map, "sourceFileList": sourceList, "object": object,
            "unitOutputIdentity": unitIdentity, "targetTriple": triple]
        base.receipt["localPackage"] = ["path": "Packages/LocalMath", "referenceID": "package-ref",
            "productReferenceID": "package-product", "name": "LocalMath", "product": "ArithmeticProduct", "module": "ArithmeticCore",
            "inventory": try XcodeLocalPackageInputs.inventory(root: root, module: "ArithmeticCore", fileSystem: fs),
            "consumers": [consumer], "indexStore": store, "files": proofFiles, "compilations": [compilation],
            "records": [["source": source, "unit": "Math-unit", "record": "Math-record", "unitOutputIdentity": unitIdentity,
                "targetTriple": triple, "path": record]],
            "aggregate": link(output: aggregate, list: aggregateList, map: aggregateMap, relocatable: true),
            "links": [["targetID": consumer, "link": link(output: executable, list: linkList, map: linkMap, relocatable: false)]]]
        var products = base.receipt["products"] as! [String: String]
        products[aggregate] = TargetScopeStore.digest(try fs.readData(at: aggregate))
        base.receipt["products"] = products
        let inventory = try XcodeTargetScopeStore(fileSystem: fs).inventory(root: "/p")
        base.receipt["before"] = inventory; base.receipt["after"] = inventory
        base.receipt["inputFingerprint"] = try base.service.sessionInputFingerprint()
        base.receipt["version"] = 2
        try base.write()
        return .init(base: base, source: source, object: object, record: record, aggregate: aggregate, map: map, response: response)
    }

    static func linkMap(output: String, owners: [String]) -> Data {
        let objects = owners.enumerated().map { "[ \($0.offset + 1)] \($0.element)" }.joined(separator: "\n")
        let symbols = owners.enumerated().map { "0x00000000\t0x00000008\t[ \($0.offset + 1)] symbol\($0.offset)" }.joined(separator: "\n")
        return Data("# Path: \(output)\n# Arch: arm64\n# Object files:\n\(objects)\n# Sections:\n# Address Size Segment Section\n0x0 0x8 __TEXT __text\n# Symbols:\n# Address Size File Name\n\(symbols)\n".utf8)
    }

    @Test("정적 합성 proof의 source-unit-object-live owner 연결만 선택 범위에 추가한다")
    func completeSyntheticProof() throws {
        let fixture = try fixture(), scope = fixture.scope()
        #expect(scope.evidenceStatus == "matched-capture")
        #expect(scope.xcode?.selectionStatus == "review-candidates")
        #expect(scope.xcode?.selectedSourcePaths.contains("Packages/LocalMath/Sources/ArithmeticCore/Math.swift") == true)
        #expect(scope.paths.contains { $0.path == "Packages/LocalMath/Package.swift" && $0.classification == "configuration-input" })
        // 이 메모리 provider는 native fresh read 경로를 대신하지 못한다.
        let document = try fixture.base.service.affectedDocument(files: [fixture.source], targetScopeEvidencePath: "/p/scope.json")
        #expect(document.targetScope?.evidenceStatus == "unknown")
        #expect(document.xcodebuildSelection().output.isEmpty)
    }

    @Test("기존 v1은 package가 없는 입력을 유지하고 v2 package 누락 및 v1 package 추가는 거부한다", arguments: [1, 2, 99])
    func versionBoundary(version: Int) throws {
        var fixture = try fixture()
        fixture.base.receipt["version"] = version
        if version == 2 { fixture.base.receipt.removeValue(forKey: "localPackage") }
        try fixture.base.write()
        #expect(fixture.scope().evidenceStatus == "unknown")
    }

    @Test("mtime을 바꾸지 않는 source manifest object record map response 편집도 거부한다",
        arguments: ["source", "manifest", "object", "record", "map", "response", "new-source", "new-c", "delete-record", "duplicate-record"])
    func rejectsByteOrMembershipChanges(kind: String) throws {
        let fixture = try fixture(), fs = fixture.base.fs
        let paths = ["source": fixture.source, "manifest": "/p/Packages/LocalMath/Package.swift",
            "object": fixture.object, "record": fixture.record, "map": fixture.map, "response": fixture.response,
            "new-source": "/p/Packages/LocalMath/Sources/ArithmeticCore/New.swift",
            "new-c": "/p/Packages/LocalMath/Sources/ArithmeticCore/New.c"]
        if kind == "delete-record" { try fs.removeItem(at: fixture.record) }
        else if kind == "duplicate-record" { try fs.write(try fs.readData(at: fixture.record), to: "/capture/DerivedData/Index.noindex/DataStore/v5/records/zz/Math-record") }
        else { try fs.write(Data("changed bytes".utf8), to: paths[kind]!) }
        #expect(fixture.scope().evidenceStatus == "unknown")
    }

    @Test("record의 시간만으로 package module unit output 및 target 일치를 대신하지 않는다",
        arguments: ["missing", "module", "unit", "output", "triple", "old"])
    func admissionMismatch(kind: String) throws {
        var fixture = try fixture()
        fixture.base.snapshot.sourceRecordAdmissions?.removeAll { $0.path == fixture.source }
        if kind != "missing" {
            fixture.base.snapshot.sourceRecordAdmissions?.append(.init(path: fixture.source,
                module: kind == "module" ? "Other" : "ArithmeticCore", unit: kind == "unit" ? "Other-unit" : "Math-unit",
                record: "Math-record", timestamp: kind == "old" ? .distantPast : .distantFuture,
                unitOutputIdentity: kind == "output" ? "/other" : "/virtual/Math.o",
                unitTargetTriple: kind == "triple" ? "x86_64-apple-macos10.13" : "arm64-apple-macos10.13"))
        }
        #expect(fixture.scope().evidenceStatus == "unknown")
    }

    @Test("공유 또는 누락된 compiler mapping과 소비자 closure 및 증거 예산은 거부한다",
        arguments: ["module-collision", "unknown-consumer", "missing-link", "duplicate-source", "extra-file", "object-budget", "wrong-index"])
    func refusesInconsistentProof(kind: String) throws {
        var fixture = try fixture()
        let object = fixture.object
        try fixture.changePackage { value in
            switch kind {
            case "module-collision": value["module"] = "CoreKit"
            case "unknown-consumer": value["consumers"] = ["unknown"]
            case "missing-link": value["links"] = [[String: Any]]()
            case "duplicate-source": value["compilations"] = (value["compilations"] as! [[String: Any]]) + (value["compilations"] as! [[String: Any]])
            case "wrong-index": value["indexStore"] = "/outside/Index/DataStore"
            default:
                var files = value["files"] as! [String: [String: Any]]
                if kind == "extra-file" { files["/capture/DerivedData/Build/unused"] = ["kind": "document", "bytes": 0, "sha256": String(repeating: "0", count: 64)] }
                else { files[object]?["bytes"] = 64 * 1_024 * 1_024 + 1 }
                value["files"] = files
            }
        }
        #expect(fixture.scope().evidenceStatus == "unknown")
    }

    @Test("Package PBX objects reject extra metadata and a non-build-file product reference",
        arguments: ["reference-extra", "product-extra", "build-extra", "build-isa"])
    func strictPackageObjects(kind: String) throws {
        let fixture = try fixture()
        var plist = try PropertyListSerialization.propertyList(
            from: fixture.base.fs.readData(at: "/p/Scope.xcodeproj/project.pbxproj"), format: nil) as! [String: Any]
        var objects = plist["objects"] as! [String: [String: Any]]
        switch kind {
        case "reference-extra": objects["package-ref"]?["unknown"] = "value"
        case "product-extra": objects["package-product"]?["unknown"] = "value"
        case "build-extra": objects["package-file"]?["unknown"] = "value"
        default: objects["package-file"]?["isa"] = "PBXShellScriptBuildPhase"
        }
        plist["objects"] = objects
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let declaration = try fixture.package.declaration
        #expect(throws: (any Error).self) {
            try XcodeProjectMembership(data: data, root: "/p", localPackage: declaration)
        }
    }

    @Test("An unrelated unbuilt target may use fallback build settings; an actual package consumer may not",
        arguments: ["UnbuiltBlueprint", "CoreBlueprint"])
    func capturedProductsApplyToActualConsumers(target: String) throws {
        var fixture = try fixture()
        var settings = try JSONSerialization.jsonObject(
            with: Data((fixture.base.receipt["buildSettingsJSON"] as! String).utf8)) as! [[String: Any]]
        let index = settings.firstIndex { $0["target"] as? String == target }!
        var values = settings[index]["buildSettings"] as! [String: String]
        values["TARGET_BUILD_DIR"] = "/p/build/Debug"
        settings[index]["buildSettings"] = values
        fixture.base.receipt["buildSettingsJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        try fixture.base.write()
        #expect(fixture.scope().evidenceStatus == (target == "UnbuiltBlueprint" ? "matched-capture" : "unknown"))
    }

    @Test("A package source shared with an unrelated unbuilt native target remains unsupported")
    func refusesSharedNativePackageSource() throws {
        let fixture = try fixture(), package = try fixture.package
        var plist = try PropertyListSerialization.propertyList(
            from: fixture.base.fs.readData(at: "/p/Scope.xcodeproj/project.pbxproj"), format: nil) as! [String: Any]
        var objects = plist["objects"] as! [String: [String: Any]]
        let unbuiltID = fixture.base.targets.first { $0.value.name == "UnbuiltBlueprint" }!.key
        let mainID = objects[plist["rootObject"] as! String]!["mainGroup"] as! String
        objects["shared-source"] = ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT",
            "path": "Packages/LocalMath/Sources/ArithmeticCore/Math.swift"]
        objects["shared-build-file"] = ["isa": "PBXBuildFile", "fileRef": "shared-source"]
        objects[mainID]?["children"] = (objects[mainID]?["children"] as! [String]) + ["shared-source"]
        let phases = objects[unbuiltID]!["buildPhases"] as! [String]
        let sourcePhase = phases.first { objects[$0]?["isa"] as? String == "PBXSourcesBuildPhase" }!
        objects[sourcePhase]?["files"] = (objects[sourcePhase]?["files"] as! [String]) + ["shared-build-file"]
        plist["objects"] = objects
        let project = try XcodeProjectMembership(data: PropertyListSerialization.data(fromPropertyList: plist,
            format: .xml, options: 0), root: "/p", localPackage: package.declaration)
        let nativeProducts = Dictionary(uniqueKeysWithValues: package.links.map { ($0.targetID, $0.link.output) })
        #expect(throws: (any Error).self) {
            try package.validate(root: "/p", buildRoot: "/capture/DerivedData/Build", architecture: "arm64",
                project: project, closure: Set(fixture.base.targets.keys), products: fixture.base.receipt["products"] as! [String: String],
                nativeProducts: nativeProducts, nativeModules: ["CoreKit", "ChecksModule", "OtherModule", "UnbuiltModule"],
                fileSystem: fixture.base.fs)
        }
    }

    @Test("MCP의 주입 provider는 준비됐어도 v2 native 신선도로 인증되지 않고 실패 후 ready를 폐기한다")
    func injectedSessionRefusesNativeClaim() throws {
        let fixture = try fixture()
        let session = try AnalysisSession(service: fixture.base.service, freshnessCheckInterval: .seconds(60))
        #expect(session.metadata != nil)
        #expect(throws: (any Error).self) {
            try session.affected(files: [fixture.source], targetScopeEvidencePath: "scope.json")
        }
        #expect(session.metadata == nil && session.querySession == nil)
    }
}
