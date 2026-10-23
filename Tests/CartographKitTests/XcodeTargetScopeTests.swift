import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("Xcode 캡처 범위와 실제 record 증거")
struct XcodeTargetScopeTests {
    private struct Fixture {
        let fs: InMemoryFileSystem
        let service: CartographService
        var snapshot: IndexSnapshot
        var receipt: [String: Any]
        let targets: [String: XcodeProjectMembership.Target]
        func write() throws { try fs.write(JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys), to: "/p/scope.json") }
        var fingerprint: String { receipt["inputFingerprint"] as! String }
        func scope(limit: Int = 200) -> TargetScopeDocument {
            service.targetScope(path: "/p/scope.json", fingerprint: fingerprint,
                context: AnalysisContext(snapshot: snapshot), limit: limit)
        }
    }

    private func fixture() throws -> Fixture {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/xcode-scope-project.json")))
        let projectData = try PropertyListSerialization.data(fromPropertyList: project, format: .xml, options: 0)
        let membership = try XcodeProjectMembership(data: projectData, root: "/p")
        let fs = InMemoryFileSystem(currentDirectoryPath: "/p", files: [:])
        try fs.write(projectData, to: "/p/Scope.xcodeproj/project.pbxproj")
        for scheme in ["Scope", "PlannedScope"] {
            let path = "Scope.xcodeproj/xcshareddata/xcschemes/" + scheme + ".xcscheme"
            try fs.write(Data(contentsOf: repository.appendingPathComponent("Fixtures/XcodeAffectedScope/" + path)), to: "/p/" + path)
        }
        try fs.write(Data(contentsOf: repository.appendingPathComponent("Fixtures/XcodeAffectedScope/Scope.xctestplan")), to: "/p/Scope.xctestplan")
        let modules = ["CoreBlueprint": "CoreKit", "ChecksBlueprint": "ChecksModule", "OtherBlueprint": "OtherModule", "UnbuiltBlueprint": "UnbuiltModule"]
        let products = ["CoreBlueprint": "CoreKit.framework", "ChecksBlueprint": "RunnableChecks.xctest", "OtherBlueprint": "OtherRunnable.xctest", "UnbuiltBlueprint": "libUnbuilt.a"]
        let productRoot = "/capture/DerivedData/Build/Products"
        var settings: [[String: Any]] = [], targetRows: [[String: Any]] = [], testRows: [[String: Any]] = []
        var snapshot = IndexSnapshot(indexedFileDates: [:], sourceRecordAdmissions: [])
        var productHashes: [String: String] = [:], selected: [String] = []
        for (id, target) in membership.targets {
            let module = modules[target.name]!, product = products[target.name]!
            let executable = product + "/Contents/MacOS/" + (product as NSString).deletingPathExtension
            settings.append(["target": target.name, "buildSettings": ["PRODUCT_MODULE_NAME": module,
                "PROJECT_FILE_PATH": "/p/Scope.xcodeproj", "CONFIGURATION": "Debug", "ARCHS": "arm64",
                "TARGET_BUILD_DIR": productRoot + "/Debug", "FULL_PRODUCT_NAME": product, "EXECUTABLE_PATH": executable]])
            targetRows.append(["id": id, "name": target.name, "module": module, "productType": target.productType,
                "sources": target.sources, "dependencies": target.dependencies])
            if target.productType.hasSuffix("unit-test") {
                selected.append(id)
                testRows.append(["BlueprintName": target.name, "TestBundlePath": "__TESTROOT__/Debug/" + product])
            }
            if target.name != "UnbuiltBlueprint" {
                let path = productRoot + "/Debug/" + executable
                try fs.write(Data("compiled".utf8), to: path)
                productHashes[path] = TargetScopeStore.digest(Data("compiled".utf8))
            }
            for source in target.sources {
                let path = "/p/" + source
                try fs.write(Data("// source".utf8), to: path)
                fs.setModificationDate(Date(timeIntervalSince1970: 1), for: path)
                if target.name != "UnbuiltBlueprint" {
                    snapshot.symbols.append(.init(usr: id, name: target.name, kind: .function, module: module,
                        location: .init(path: path, line: 1, column: 1)))
                    snapshot.indexedFileDates?[path] = .distantFuture
                    snapshot.sourceRecordAdmissions?.append(.init(path: path, module: module, unit: id, record: source, timestamp: .distantFuture))
                }
            }
        }
        let testRun = productRoot + "/Scope.xctestrun"
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["TestConfigurations": [["TestTargets": testRows]]], format: .xml, options: 0)
        try fs.write(bytes, to: testRun)
        productHashes[testRun] = TargetScopeStore.digest(bytes)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(fileSystem: fs,
            indexProviderOverride: StaticIndexProvider(snapshot), usesSyntaxCache: false))
        let inventory = try XcodeTargetScopeStore(fileSystem: fs).inventory(root: "/p")
        let receipt: [String: Any] = ["format": "cartograph-xcode-target-scope", "version": 1, "projectRoot": "/p",
            "project": "Scope.xcodeproj", "scheme": "Scope", "schemePath": "Scope.xcodeproj/xcshareddata/xcschemes/Scope.xcscheme",
            "configuration": "Debug", "destination": "platform=macOS,arch=arm64", "architecture": "arm64",
            "inputFingerprint": try service.sessionInputFingerprint(), "before": inventory, "after": inventory,
            "buildSettingsJSON": String(decoding: try JSONSerialization.data(withJSONObject: settings, options: .sortedKeys), as: UTF8.self),
            "testRunPath": testRun, "testRunSHA256": productHashes[testRun]!, "products": productHashes,
            "productLinks": [String: String](), "targets": targetRows, "selectedTargetIDs": selected,
            "frameworks": [[String: Any]](), "testHosts": [String: String](), "buildExitCode": 0]
        let fixture = Fixture(fs: fs, service: service, snapshot: snapshot, receipt: receipt, targets: membership.targets)
        try fixture.write()
        return fixture
    }


    private func addSDKFramework(to fixture: inout Fixture) throws -> String {
        var project = try PropertyListSerialization.propertyList(from: fixture.fs.readData(at: "/p/Scope.xcodeproj/project.pbxproj"), format: nil) as! [String: Any]
        var objects = project["objects"] as! [String: [String: Any]]
        let phaseID = objects.first { $0.value["isa"] as? String == "PBXFrameworksBuildPhase" }!.key
        objects["sdk-ref"] = ["isa": "PBXFileReference", "sourceTree": "SDKROOT", "path": "System/Library/Frameworks/Foundation.framework"]
        objects["sdk-file"] = ["isa": "PBXBuildFile", "fileRef": "sdk-ref"]
        var phase = objects[phaseID]!
        phase["files"] = (phase["files"] as? [String] ?? []) + ["sdk-file"]
        objects[phaseID] = phase; project["objects"] = objects
        try fixture.fs.write(PropertyListSerialization.data(fromPropertyList: project, format: .xml, options: 0), to: "/p/Scope.xcodeproj/project.pbxproj")
        let developer = "/Xcode/Contents/Developer"
        let sdk = developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        let framework = sdk + "/System/Library/Frameworks/Foundation.framework"
        let file = framework + "/Foundation.tbd"
        let bytes = Data("synthetic system stub".utf8)
        try fixture.fs.write(bytes, to: file)
        var settings = try JSONSerialization.jsonObject(with: Data((fixture.receipt["buildSettingsJSON"] as! String).utf8)) as! [[String: Any]]
        for i in settings.indices {
            var values = settings[i]["buildSettings"] as! [String: String]
            values["SDKROOT"] = sdk; values["DEVELOPER_DIR"] = developer
            settings[i]["buildSettings"] = values
        }
        fixture.receipt["buildSettingsJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        fixture.receipt["frameworks"] = [["sourceTree": "SDKROOT", "path": "System/Library/Frameworks/Foundation.framework",
            "root": sdk, "developerRoot": developer, "resolvedPath": framework,
            "files": [file: TargetScopeStore.digest(bytes)], "links": [String: String]()]]
        let inventory = try XcodeTargetScopeStore(fileSystem: fixture.fs).inventory(root: "/p")
        fixture.receipt["before"] = inventory; fixture.receipt["after"] = inventory
        try fixture.write()
        return file
    }

    @Test("SDK 이름만으로 framework를 인증하지 않고 실제 경계와 stub 바이트를 재검증한다")
    func systemFrameworkBoundaryAndBytes() throws {
        var fixture = try fixture()
        let file = try addSDKFramework(to: &fixture)
        #expect(fixture.scope().xcode?.selectionStatus == "review-candidates")
        try fixture.fs.write(Data("changed system stub".utf8), to: file)
        #expect(fixture.scope().evidenceStatus == "unknown")
    }

    @Test("SDK framework의 절대 탈출 macro 경로는 원문에서 거부한다",
        arguments: ["/tmp/Unbound.framework", "../../../../tmp/Unbound.framework", "$(OUTSIDE)/Unbound.framework", "System/Library/Frameworks/../Unbound.framework"])
    func rejectsEscapingSystemFramework(path: String) throws {
        var fixture = try fixture()
        _ = try addSDKFramework(to: &fixture)
        var project = try PropertyListSerialization.propertyList(from: fixture.fs.readData(at: "/p/Scope.xcodeproj/project.pbxproj"), format: nil) as! [String: Any]
        var objects = project["objects"] as! [String: [String: Any]]
        objects["sdk-ref"]?["path"] = path; project["objects"] = objects
        let bytes = try PropertyListSerialization.data(fromPropertyList: project, format: .xml, options: 0)
        #expect(throws: (any Error).self) { try XcodeProjectMembership(data: bytes, root: "/p") }
    }

    @Test("SDK symlink의 실제 해석이 외부 bundle로 바뀌면 소비를 거부한다")
    func rejectsRedirectedSystemFramework() throws {
        var fixture = try fixture()
        let file = try addSDKFramework(to: &fixture)
        let redirected = FrameworkRedirectFileSystem(base: fixture.fs,
            from: (file as NSString).deletingLastPathComponent, to: "/outside/Foundation.framework")
        #expect(throws: (any Error).self) {
            try XcodeTargetScopeStore(fileSystem: redirected).read(path: "/p/scope.json", root: "/p", fingerprint: fixture.fingerprint)
        }
    }

    private func rewriteTestRun(_ fixture: inout Fixture, change: (inout [[String: Any]]) -> Void) throws {
        let path = fixture.receipt["testRunPath"] as! String
        var plist = try PropertyListSerialization.propertyList(from: fixture.fs.readData(at: path), format: nil) as! [String: Any]
        var configurations = plist["TestConfigurations"] as! [[String: Any]]
        var rows = configurations[0]["TestTargets"] as! [[String: Any]]
        change(&rows)
        configurations[0]["TestTargets"] = rows; plist["TestConfigurations"] = configurations
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try fixture.fs.write(data, to: path)
        var products = fixture.receipt["products"] as! [String: String]
        products[path] = TargetScopeStore.digest(data)
        fixture.receipt["products"] = products; fixture.receipt["testRunSHA256"] = products[path]
        try fixture.write()
    }

    @Test("closure 밖 모듈 충돌과 의존 산출물 또는 host의 외부 경로를 거부한다",
        arguments: ["module-collision", "dependency-product", "xctestrun-dependency", "host", "hosted"])
    func refusesUnboundDependencyOrHost(kind: String) throws {
        var fixture = try fixture()
        if kind == "module-collision" || kind == "dependency-product" {
            var settings = try JSONSerialization.jsonObject(with: Data((fixture.receipt["buildSettingsJSON"] as! String).utf8)) as! [[String: Any]]
            if kind == "module-collision" {
                var targets = fixture.receipt["targets"] as! [[String: Any]]
                let i = targets.firstIndex { $0["name"] as? String == "UnbuiltBlueprint" }!
                targets[i]["module"] = "ChecksModule"; fixture.receipt["targets"] = targets
                let j = settings.firstIndex { $0["target"] as? String == "UnbuiltBlueprint" }!
                var values = settings[j]["buildSettings"] as! [String: String]
                values["PRODUCT_MODULE_NAME"] = "ChecksModule"; settings[j]["buildSettings"] = values
            } else {
                let i = settings.firstIndex { $0["target"] as? String == "CoreBlueprint" }!
                var values = settings[i]["buildSettings"] as! [String: String]
                values["TARGET_BUILD_DIR"] = "/outside"; settings[i]["buildSettings"] = values
            }
            fixture.receipt["buildSettingsJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
            try fixture.write()
        } else {
            try rewriteTestRun(&fixture) { rows in
                if kind == "xctestrun-dependency" { rows[0]["DependentProductPaths"] = ["/outside/CoreKit.framework"] }
                else if kind == "host" { rows[0]["TestHostPath"] = "/outside/Host.app/Contents/MacOS/Host" }
                else { rows[0]["IsAppHostedTestBundle"] = true }
            }
        }
        #expect(fixture.scope().evidenceStatus == "unknown")
    }

    @Test("표준 XCTest host macro와 바이트만 허용하고 host 변경을 거부한다")
    func standardHostAndProductDependencies() throws {
        var fixture = try fixture()
        let developer = "/Xcode/Contents/Developer"
        let host = developer + "/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"
        let data = Data("system XCTest host".utf8)
        try fixture.fs.write(data, to: host)
        fixture.receipt["testHosts"] = [host: TargetScopeStore.digest(data)]
        var settings = try JSONSerialization.jsonObject(with: Data((fixture.receipt["buildSettingsJSON"] as! String).utf8)) as! [[String: Any]]
        for i in settings.indices {
            var values = settings[i]["buildSettings"] as! [String: String]
            values["DEVELOPER_DIR"] = developer; settings[i]["buildSettings"] = values
        }
        fixture.receipt["buildSettingsJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        try rewriteTestRun(&fixture) { rows in
            for i in rows.indices {
                rows[i]["TestHostPath"] = "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"
                rows[i]["DependentProductPaths"] = ["__TESTROOT__/Debug/CoreKit.framework", rows[i]["TestBundlePath"]!]
            }
        }
        #expect(fixture.scope().xcode?.selectionStatus == "review-candidates")
        try fixture.fs.write(Data("modified host".utf8), to: host)
        #expect(fixture.scope().evidenceStatus == "unknown")
    }

    @Test("산출물 재배치와 앱 host는 build 전에 원문 preflight에서 거부한다",
        arguments: ["CONFIGURATION_BUILD_DIR", "TEST_HOST", "BUNDLE_LOADER", "LD_RUNPATH_SEARCH_PATHS", "INFOPLIST_FILE"])
    func rejectsExternalSettings(key: String) throws {
        let fixture = try fixture()
        var project = try PropertyListSerialization.propertyList(from: fixture.fs.readData(at: "/p/Scope.xcodeproj/project.pbxproj"), format: nil) as! [String: Any]
        var objects = project["objects"] as! [String: [String: Any]]
        let id = objects.first { $0.value["isa"] as? String == "XCBuildConfiguration" }!.key
        var object = objects[id]!, settings = object["buildSettings"] as! [String: Any]
        settings[key] = "/outside/input"; object["buildSettings"] = settings; objects[id] = object; project["objects"] = objects
        let data = try PropertyListSerialization.data(fromPropertyList: project, format: .xml, options: 0)
        #expect(throws: (any Error).self) { try XcodeProjectMembership(data: data, root: "/p") }
    }

    @Test("모듈과 blueprint가 다른 실제 bundle 이름으로 범위를 연결한다")
    func validCapture() throws {
        let fixture = try fixture()
        let result = fixture.scope()
        #expect(result.evidenceStatus == "matched-capture")
        #expect(result.xcode?.selectionStatus == "review-candidates")
        #expect(result.xcode?.selectorTargetByModule["ChecksModule"] == "ChecksBlueprint")
        #expect(result.xcode?.testBundleByModule?["ChecksModule"] == "RunnableChecks.xctest")
        #expect(result.xcode?.selectorIdentity == "xctestrun-blueprint-name")
        #expect(result.paths.contains { $0.path == "Unbuilt/Tool.swift" && $0.classification == "outside-selected-targets" })
        #expect(result.xcode?.selectedSourcePaths.count == 3)
        #expect(result.xcode?.coveredBlockerCodes.contains("unindexed-sources") == true)
        #expect(fixture.scope(limit: 1).xcode?.blockers.contains("membership-output-truncated") == true)
    }

    @Test("날짜만 있거나 다른 모듈의 record 또는 오래된 record는 선택 근거가 아니다",
        arguments: ["legacy", "file-only", "deferred", "other-module", "old-record", "missing-date"])
    func requiresConsumedSourceRecords(kind: String) throws {
        var fixture = try fixture()
        switch kind {
        case "legacy": fixture.snapshot.sourceRecordAdmissions = nil
        case "file-only", "deferred": fixture.snapshot.sourceRecordAdmissions = []
        case "missing-date": fixture.snapshot.indexedFileDates = [:]
        default:
            fixture.snapshot.sourceRecordAdmissions = fixture.snapshot.sourceRecordAdmissions?.map {
                .init(path: $0.path, module: kind == "other-module" ? "Wrong" : $0.module,
                    unit: $0.unit, record: $0.record, timestamp: kind == "old-record" ? .distantPast : $0.timestamp)
            }
        }
        #expect(fixture.scope().xcode?.selectionStatus == "refused")
        #expect(fixture.scope().xcode?.coveredBlockerCodes.isEmpty == true)
    }

    @Test("검증된 scheme 범위도 질의 중 바뀐 수신자 소스의 거부를 덮지 않는다")
    func receiverFreshnessStillBlocksVerifiedScope() throws {
        let fixture = try fixture()
        let scope = fixture.scope()
        #expect(scope.xcode?.selectionStatus == "review-candidates")
        let subject = SymbolQuery.Subject(name: "testCore", qualifiedName: "Checks.testCore",
            kind: "method", module: "ChecksModule", usr: "s:testCore", accessibility: "internal",
            location: .init(path: "Checks/Checks.swift", line: 1, column: 1))
        func document(_ extra: [String]) -> AffectedDocument {
            .init(status: "ok", requestedSymbols: [], requestedFiles: [], selected: [], changeScope: [],
                tests: [.init(symbol: subject, depth: 1, via: nil, relationship: "dependent", edges: ["call"],
                    dispatchContract: nil, runtimeEvidence: nil, runtimeEvidenceOmitted: nil,
                    xcodebuildIdentifier: "ChecksModule/Checks/testCore")],
                summary: .init(testCount: 1, changedTestCount: 0, changeScopeSymbols: 1, affectedSymbols: 1,
                    testFileCount: 1, testFiles: ["Checks/Checks.swift"], moduleCount: 1,
                    modules: ["ChecksModule"], unresolvedInputs: 0), selectionIssues: [],
                limitations: ["unindexed-sources: outside selected targets"] + extra,
                truncated: .init(depth: false, sections: []), targetScope: scope)
        }
        let current = document([]).xcodebuildSelection()
        #expect(current.refusal == nil)
        #expect(current.output == "-only-testing:ChecksBlueprint/Checks/testCore\n")
        let changed = document(["receiver-source-changed-during-query: rebuild the source"])
            .xcodebuildSelection()
        #expect(changed.output.isEmpty)
        #expect(changed.refusal?.contains("Source/index coverage is incomplete") == true)
        #expect(changed.notes.contains { $0.hasPrefix("receiver-source-changed-during-query:") })
    }

    @Test("저장 snapshot은 record 근거를 남기고 현재 수신자 소스 증명은 버린다")
    func sourceEvidenceLifetimesRemainDistinct() throws {
        var fixture = try fixture()
        fixture.snapshot.dispatchReceiverFiles = [.init(path: "/p/Core/Core.swift", finalClassUSRs: ["s:Core"],
            selfCalls: [], sourceDigest: "current-only")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let restored = try JSONDecoder().decode(IndexSnapshot.self, from: encoder.encode(fixture.snapshot))
        #expect(restored.sourceRecordAdmissions == fixture.snapshot.sourceRecordAdmissions)
        #expect(restored.dispatchReceiverFiles == nil)
        let merged = fixture.snapshot.merging(restored)
        #expect(merged.sourceRecordAdmissions?.isEmpty == false)
        #expect(merged.dispatchReceiverFiles == nil)
        #expect(fixture.snapshot.merging(IndexSnapshot()).sourceRecordAdmissions == nil)
    }

    @Test("소스 구성 목적지 산출물 바이트와 bundle 경로 변조를 거부한다",
        arguments: ["source", "project", "scheme", "plan", "destination", "architecture", "fingerprint", "build", "product", "added-product", "bundle", "module", "partial", "duplicate", "outside"])
    func refusesStaleOrUnsupported(kind: String) throws {
        var fixture = try fixture()
        switch kind {
        case "source": try fixture.fs.write(Data("changed".utf8), to: "/p/Core/Core.swift")
        case "project": try fixture.fs.write(Data("changed".utf8), to: "/p/Scope.xcodeproj/project.pbxproj")
        case "scheme": try fixture.fs.write(Data("changed".utf8), to: "/p/Scope.xcodeproj/xcshareddata/xcschemes/Scope.xcscheme")
        case "plan": fixture.receipt["testPlan"] = "Scope.xctestplan"
        case "destination": fixture.receipt["destination"] = "platform=iOS Simulator"
        case "architecture": fixture.receipt["architecture"] = "x86_64"
        case "fingerprint": fixture.receipt["inputFingerprint"] = "different"
        case "build": fixture.receipt["buildExitCode"] = 1
        case "product", "added-product":
            let products = fixture.receipt["products"] as! [String: String]
            let path = kind == "product" ? products.keys.first { !$0.hasSuffix(".xctestrun") }! : "/capture/DerivedData/Build/Products/added"
            try fixture.fs.write(Data("mutated".utf8), to: path)
        case "bundle", "partial":
            let path = fixture.receipt["testRunPath"] as! String
            let row: [String: Any] = ["BlueprintName": "ChecksBlueprint", "TestBundlePath": "__TESTROOT__/wrong.xctest", "SkipTestIdentifiers": ["a"]]
            let bytes = try PropertyListSerialization.data(fromPropertyList: ["TestConfigurations": [["TestTargets": [row]]]], format: .xml, options: 0)
            try fixture.fs.write(bytes, to: path)
            var products = fixture.receipt["products"] as! [String: String]
            products[path] = TargetScopeStore.digest(bytes)
            fixture.receipt["products"] = products; fixture.receipt["testRunSHA256"] = products[path]
        case "duplicate": fixture.receipt["selectedTargetIDs"] = ["same", "same"]
        case "outside": fixture.receipt["project"] = "../Scope.xcodeproj"
        default:
            var targets = fixture.receipt["targets"] as! [[String: Any]]
            for i in targets.indices { targets[i]["module"] = "Wrong" }
            fixture.receipt["targets"] = targets
        }
        try fixture.write()
        #expect(fixture.scope().evidenceStatus == "unknown")
    }

    @Test("명시 plan도 같은 target universe와 바이트를 요구한다")
    func explicitPlan() throws {
        var fixture = try fixture()
        fixture.receipt["scheme"] = "PlannedScope"
        fixture.receipt["schemePath"] = "Scope.xcodeproj/xcshareddata/xcschemes/PlannedScope.xcscheme"
        fixture.receipt["testPlan"] = "Scope.xctestplan"
        try fixture.write()
        #expect(fixture.scope().xcode?.selectionStatus == "review-candidates")
        try fixture.fs.write(Data("{}".utf8), to: "/p/Scope.xctestplan")
        #expect(fixture.scope().evidenceStatus == "unknown")
    }
    @Test("기본 cached 세션 지문과 CLI capture 지문이 달라도 같은 준비 세대에 연결한다")
    func defaultCachedSessionBindsCanonicalCapture() throws {
        let fixture = try fixture()
        let session = try AnalysisSession(service: fixture.service, freshnessCheckInterval: .seconds(60))
        #expect(session.metadata?.fingerprint != fixture.fingerprint)
        let result = try session.affected(files: ["Core/Core.swift"], targetScopeEvidencePath: "scope.json")
        #expect(result.targetScope?.evidenceStatus == "matched-capture")
        #expect(result.targetScope?.xcode?.selectionStatus == "review-candidates")
        // 창 안에서 소스가 바뀌어도 scope opt-in은 이전 세대를 현재 capture로 인증하지 않는다.
        try fixture.fs.write(Data("// changed".utf8), to: "/p/Core/Core.swift")
        #expect(throws: (any Error).self) {
            try session.affected(files: ["Core/Core.swift"], targetScopeEvidencePath: "scope.json")
        }
        #expect(session.metadata == nil)
    }

    @Test("MCP 준비 세대 지문을 사용하고 마지막 읽기 오류는 ready 문맥을 폐기한다",
        arguments: [false, true])
    func sessionGenerationAndFinalFailure(throwsInsteadOfChanging: Bool) throws {
        let fixture = try fixture()
        var calls = 0
        var failAt: Int?
        let now = ContinuousClock().now
        let session = try AnalysisSession(serviceFactory: { fixture.service }, inputFingerprintProvider: {
            calls += 1
            if calls == failAt {
                if throwsInsteadOfChanging { throw AnalysisSessionError.unavailable }
                return "changed-generation"
            }
            return fixture.fingerprint
        }, freshnessCheckInterval: .seconds(60), now: { now })
        let result = try session.affected(files: ["Core/Core.swift"], targetScopeEvidencePath: "scope.json")
        #expect(result.targetScope?.evidenceStatus == "matched-capture")
        #expect(result.targetScope?.xcode?.selectionStatus == "review-candidates")
        _ = try session.query(symbols: ["CoreBlueprint"])
        #expect(session.querySession != nil)
        failAt = calls + 2 // 첫 세대 확인은 성공하고 소비 후 마지막 확인만 실패한다.
        #expect(throws: (any Error).self) {
            try session.affected(files: ["Core/Core.swift"], targetScopeEvidencePath: "scope.json")
        }
        #expect(session.metadata == nil && session.querySession == nil)
        #expect(session.runtimeBuildEvidenceMetadata == nil)
        #expect(calls == failAt)
        failAt = nil
        #expect(try session.status().generation == 2)
        #expect(throws: (any Error).self) {
            try session.affected(files: ["Core/Core.swift"], targetScopeEvidencePath: "../outside.json")
        }
        #expect(session.metadata?.generation == 2)
    }

    @Test("민감한 receipt 이름은 형식 판별 전에 거부한다")
    func sensitiveReceiptIsRefusedBeforeProbe() throws {
        let fixture = try fixture()
        let result = fixture.service.targetScope(path: "/p/auth.json", fingerprint: fixture.fingerprint,
            context: AnalysisContext(snapshot: fixture.snapshot), limit: 200)
        #expect(result.evidenceStatus == "unknown")
        #expect(result.limitations.first?.contains("credential-like") == true)
    }

}

/// SDK link의 realpath 변화만 주입한다. 일반 파일 내용은 원래 fixture에서 읽는다.
private struct FrameworkRedirectFileSystem: FileSystem {
    let base: InMemoryFileSystem
    let from: String
    let to: String
    func realPath(at path: String) throws -> String { path == from ? to : try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func removeItem(at path: String) throws { try base.removeItem(at: path) }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}
