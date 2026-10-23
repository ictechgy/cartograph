import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("캡처에 묶인 target 소속")
struct TargetScopeTests {
    @Test("The legacy v1 SDK relative receipt path remains a matched capture")
    func legacyRelativeReceiptPath() throws {
        let (fs, service, _, _) = try fixture()
        try fs.write(fs.readData(at: "/scope.json"), to: "scope.json")
        let document = try service.affectedDocument(files: ["Sources/App/App.swift"], targetScopeEvidencePath: "scope.json")
        #expect(document.targetScope?.evidenceStatus == "matched-capture")
    }

    private let description = """
    {"path":"/p","dependencies":[],"targets":[
      {"name":"App","c99name":"App","module_type":"SwiftTarget","type":"library",
       "path":"Sources/App","sources":["App.swift"]},
      {"name":"Tool","c99name":"Tool","module_type":"SwiftTarget","type":"library",
       "path":"Sources/Tool","sources":["Tool.swift"]},
      {"name":"AppTests","c99name":"AppTests","module_type":"SwiftTarget","type":"test",
       "path":"Tests/AppTests","sources":["Test.swift"],"target_dependencies":["App"]}
    ]}
    """

    private func fixture() throws -> (InMemoryFileSystem, CartographService, AnalysisContext, TargetScopeReceipt) {
        let fs = InMemoryFileSystem(currentDirectoryPath: "/p", files: [
            "/p/Package.swift": "// manifest", "/p/Sources/App/App.swift": "func leaf() {}",
            "/p/Sources/Tool/Tool.swift": "func tool() {}", "/p/Tests/AppTests/Test.swift": "func test() {}",
        ])
        var builder = SnapshotBuilder(path: "/p/Sources/App/App.swift")
        builder.symbol("leaf", name: "leaf()", kind: .function)
        builder.symbol("test", name: "test()", kind: .function, path: "/p/Tests/AppTests/Test.swift",
                       attributes: [.testFunction])
        builder.reference(from: "test", to: "leaf", kind: .call, path: "/p/Tests/AppTests/Test.swift")
        var snapshot = builder.build()
        snapshot.indexedFileDates = ["/p/Sources/App/App.swift": .distantFuture,
                                     "/p/Tests/AppTests/Test.swift": .distantFuture]
        var config = CartographConfiguration.default
        config.projectPath = "/p"
        let service = CartographService(configuration: config, environment: .init(fileSystem: fs,
            indexProviderOverride: StaticIndexProvider(snapshot), usesSyntaxCache: false))
        let inputs = try TargetScopeStore(fileSystem: fs).inventory(root: "/p")
        let receipt = TargetScopeReceipt(format: "cartograph-swiftpm-target-scope", version: 1,
            projectRoot: "/p", inputFingerprint: try service.sessionInputFingerprint(), descriptionJSON: description,
            descriptionSHA256: TargetScopeStore.digest(Data(description.utf8)),
            selectedTargets: ["AppTests"], before: inputs, after: inputs, buildExitCode: 0)
        try fs.write(JSONEncoder().encode(receipt), to: "/scope.json")
        return (fs, service, AnalysisContext(snapshot: snapshot), receipt)
    }

    @Test("명시 test target의 closure 밖 소스를 분리하지만 원래 경고와 scheme 거부는 보존한다")
    func classifiesWithoutAuthorizingOmission() throws {
        let (_, service, _, _) = try fixture()
        let document = try service.affectedDocument(symbols: ["leaf"], targetScopeEvidencePath: "/scope.json")
        let scope = try #require(document.targetScope)
        #expect(scope.evidenceStatus == "matched-capture")
        #expect(scope.dependencyTargets == ["App", "AppTests"])
        #expect(scope.paths.contains { $0.path == "Sources/Tool/Tool.swift"
            && $0.classification == "outside-selected-targets" && $0.blockers.contains("no-observed-index-unit") })
        #expect(document.limitations.contains { $0.hasPrefix("unindexed-sources:") })
        #expect(scope.schemeIdentity == "unverified")
        #expect(document.xcodebuildSelection().output.isEmpty)
        #expect(document.xcodebuildSelection().refusal?.contains("scheme") == true)
    }

    @Test("옛 문서와 기본 full 출력에는 선택 필드가 없고 외부 문맥에는 현재 지문을 붙이지 않는다")
    func compatibilityAndExternalContext() throws {
        let (_, service, context, _) = try fixture()
        let normal = try service.affectedDocument(symbols: ["leaf"])
        let bytes = try JSONEncoder().encode(normal)
        #expect(try JSONSerialization.jsonObject(with: bytes) as? [String: Any] != nil)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("targetScope"))
        #expect(try JSONDecoder().decode(AffectedDocument.self, from: bytes) == normal)
        let old = try service.affectedDocument(symbols: ["leaf"], in: context, targetScopeEvidencePath: "/scope.json")
        #expect(old.targetScope?.evidenceStatus == "unknown")
    }

    @Test("새 소스와 manifest 및 lock 변경은 목록 바깥이라도 소속을 무효화한다",
          arguments: ["New.swift", "Package.swift", "Package.resolved", "Sources/Tool/Tool.swift"])
    func currentInputsAreRequired(path: String) throws {
        let (fs, service, _, _) = try fixture()
        try fs.write(Data("changed".utf8), to: "/p/" + path)
        let result = try service.affectedDocument(symbols: ["leaf"], targetScopeEvidencePath: "/scope.json")
        #expect(result.targetScope?.evidenceStatus == "unknown")
        #expect(result.targetScope?.paths.allSatisfy { $0.classification == "unknown" } == true)
        #expect(result.xcodebuildSelection().output.isEmpty)
    }

    @Test("다른 캡처, 불완전 빌드, 외부 의존성, 중복 소속과 선택 변경은 unknown이다",
          arguments: ["fingerprint", "build", "external", "shared", "selection", "module", "escape", "kind", "dependency", "resource"])
    func rejectsUnsupportedProofs(kind: String) throws {
        let (fs, _, _, receipt) = try fixture()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        var description = try #require(JSONSerialization.jsonObject(with: Data(receipt.descriptionJSON.utf8)) as? [String: Any])
        var targets = try #require(description["targets"] as? [[String: Any]])
        switch kind {
        case "fingerprint": object["inputFingerprint"] = "another capture"
        case "build": object["buildExitCode"] = 1
        case "external": description["dependencies"] = [["identity": "external"]]
        case "shared": targets[1]["path"] = "Sources/App"; targets[1]["sources"] = ["App.swift"]
        case "selection": object["selectedTargets"] = ["OtherSchemeTests"]
        case "module": targets[1]["c99name"] = "App"
        case "escape": targets[0]["path"] = "../outside"
        case "kind": targets[0]["module_type"] = "ClangTarget"
        case "resource": targets[0]["resources"] = [["path": "Data.json"]]
        default: targets[2]["target_dependencies"] = ["NotCaptured"]
        }
        description["targets"] = targets
        object["descriptionJSON"] = String(decoding: try JSONSerialization.data(withJSONObject: description), as: UTF8.self)
        object["descriptionSHA256"] = TargetScopeStore.digest(Data((object["descriptionJSON"] as! String).utf8))
        try fs.write(JSONSerialization.data(withJSONObject: object), to: "/scope.json")
        #expect(throws: (any Error).self) {
            try TargetScopeStore(fileSystem: fs).read(path: "/scope.json", projectPath: "/p",
                                                     fingerprint: receipt.inputFingerprint)
        }
    }

    @Test("읽기 실패와 source 상한 및 출력 행 제한을 숨기지 않는다")
    func boundedInputsAndRows() throws {
        let (fs, service, context, receipt) = try fixture()
        let scope = service.targetScope(path: "/scope.json", fingerprint: receipt.inputFingerprint,
                                        context: context, limit: 1)
        #expect(scope.paths.count == 1)
        #expect(scope.omittedPaths == scope.pathCount - 1)
        fs.setReadError(.fileReadNoPermission, for: "/p/Sources/Tool/Tool.swift")
        #expect(throws: (any Error).self) { try TargetScopeStore(fileSystem: fs).inventory(root: "/p") }
        fs.setReadError(nil, for: "/p/Sources/Tool/Tool.swift")
        try fs.write(Data(repeating: 65, count: TargetScopeStore.sourceBytes + 1), to: "/p/Sources/Tool/Tool.swift")
        #expect(throws: (any Error).self) { try TargetScopeStore(fileSystem: fs).inventory(root: "/p") }
    }

    @Test("소속 검증 후 최종 지문 읽기가 실패하면 부분 분류를 게시하지 않는다")
    func finalFingerprintFailureDiscardsMembership() throws {
        let (fs, service, context, receipt) = try fixture()
        // receipt 검증 자체는 성공한다. 마지막 지문 단계만 민감한 설정 경로 때문에 실패한다.
        let verified = try TargetScopeStore(fileSystem: fs).read(path: "/scope.json", projectPath: "/p",
                                                                 fingerprint: receipt.inputFingerprint)
        #expect(verified.closure == ["App", "AppTests"])
        var configuration = service.configuration
        configuration.baselinePath = "auth.json"
        let failing = CartographService(configuration: configuration, environment: service.environment)
        #expect(throws: AnalysisSessionError.sensitiveInput) { try failing.sessionInputFingerprint() }
        let scope = failing.targetScope(path: "/scope.json", fingerprint: receipt.inputFingerprint,
                                         context: context, limit: 200)
        #expect(scope.evidenceStatus == "unknown")
        #expect(scope.selectedTargets.isEmpty && scope.dependencyTargets.isEmpty)
        #expect(!scope.paths.isEmpty)
        #expect(scope.paths.allSatisfy { $0.classification == "unknown" && $0.targets.isEmpty })
        #expect(scope.limitations.contains { $0.hasPrefix("target-scope-unknown:") })
    }
}
