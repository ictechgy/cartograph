import CartographAnalysis
import CartographCore
import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("파일 요약의 공개 명령 API 호환성과 종료 사실")
struct GeneratedFindingOutcomeTests {
    @Test("원래 JSON 루트와 진단·한계·임계값은 그대로 두고 제안만 덧붙인다")
    func originalJSONAndOutcomeArePreserved() throws {
        let service = makeService()
        let legacy: (Bool) throws -> CommandOutcome = service.detectUnusedCode
        let plain = try legacy(false)
        let explicitNil = try service.detectUnusedCode(findingReviewOptions: nil)
        #expect(plain == explicitNil)
        let reviewed = try service.detectUnusedCode(findingReviewOptions: .init(inspectGeneratedHeaders: true))
        var root = try object(reviewed.output)
        let annotation = try #require(root.removeValue(forKey: "findingReview") as? [String: Any])
        #expect(NSDictionary(dictionary: root).isEqual(to: try object(plain.output)))
        #expect(annotation["diagnostics"] == nil)
        #expect(annotation["findingCount"] as? Int == 2)
        #expect(reviewed.findingCount == plain.findingCount && plain.findingCount == 2)
        #expect(reviewed.suppressedCount == plain.suppressedCount)
        #expect(reviewed.thresholdFailure == plain.thresholdFailure && plain.thresholdFailure != nil)
        #expect(reviewed.incompleteAnalysis == plain.incompleteAnalysis)
        #expect(reviewed.notes == plain.notes)
        #expect(root["limitations"] != nil)
    }

    @Test("기존 baseline 억제를 요약에서 되살리지 않는다")
    func baselineIsNotUndone() throws {
        let fs = fileSystem()
        try BaselineStore(fileSystem: fs).write(Baseline(fingerprints: ["unused-symbol|generated"]), to: "/p/base.json")
        let service = makeService(fs: fs, baseline: "/p/base.json")
        let plain = try service.detectUnusedCode()
        let annotated = try service.detectUnusedCode(findingReviewOptions: .init(inspectGeneratedHeaders: true))
        let root = try object(annotated.output)
        let annotation = try #require(root["findingReview"] as? [String: Any])
        #expect(annotated.suppressedCount == 1 && annotated.suppressedCount == plain.suppressedCount)
        #expect(annotated.findingCount == 1)
        #expect(annotation["findingCount"] as? Int == 1)
        let files = try #require(annotation["files"] as? [[String: Any]])
        #expect(files.map { $0["path"] as? String } == ["Tokens.swift"])
    }

    @Test("공개 API도 JSON 형식과 예산을 인덱스 준비 전에 검사한다")
    func invalidFormatBeforeLoading() {
        let service = CartographService(configuration: .init(projectPath: "/no-project"),
            environment: .init(fileSystem: InMemoryFileSystem()))
        do {
            _ = try service.detectUnusedCode(findingReviewOptions: .init())
            Issue.record("JSON 전용 옵션은 거부되어야 한다")
        } catch let error as CartographError {
            #expect(error.localizedDescription.contains("require JSON report format"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    private func makeService(fs: InMemoryFileSystem? = nil, baseline: String? = nil) -> CartographService {
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("generated", name: "generatedUnused()", kind: .function, path: "/p/Generated.swift", line: 2)
        builder.symbol("token", name: "manualToken()", kind: .function, path: "/p/Tokens.swift", line: 2)
        return .init(configuration: .init(projectPath: "/p", thresholds: .init(maxUnusedSymbols: 0),
            baselinePath: baseline, reportFormat: .json), environment: .init(fileSystem: fs ?? fileSystem(),
            indexProviderOverride: StaticIndexProvider(builder.build()), usesSyntaxCache: false))
    }

    private func fileSystem() -> InMemoryFileSystem {
        .init(currentDirectoryPath: "/p", files: [
            "/p/Generated.swift": "// @generated\nfunc generatedUnused() {}",
            "/p/Tokens.swift": "// Human-managed\nfunc manualToken() {}",
            "/p/Unindexed.swift": "func notInSnapshot() {}"
        ])
    }

    private func object(_ value: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
}
