import CartographAnalysis
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("실제 Isthmus 출력의 보존 출처 합성")
struct RetentionProvenanceCompositionTests {
    private let staleWarning = "index-freshness: source changed after index capture"

    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Fixtures/RetentionProvenance/cartograph-\(name).json"))
    }

    private func fileSystem(_ name: String) throws -> InMemoryFileSystem {
        InMemoryFileSystem(files: ["/fixture/retentions.json": String(decoding: try fixture(name), as: UTF8.self)])
    }

    private func load(_ name: String) throws -> ExternalRetentionsDocument {
        try ExternalRetentionStore(fileSystem: fileSystem(name)).load(from: "/fixture/retentions.json")
    }

    private func service(_ name: String, includeHandler: Bool = true) throws -> CartographService {
        var builder = SnapshotBuilder(module: "App", path: "/fixture/ios/Handler.swift")
        builder.symbol("s:Main", name: "Main", kind: .structType, attributes: [.entryPoint])
        if includeHandler {
            builder.symbol("s:Handler", name: "Handler", kind: .classType, line: 2)
            builder.symbol("s:handler", name: "handle", kind: .method, line: 4, parent: "s:Handler")
        }
        builder.symbol("s:Unused", name: "Unused", kind: .classType, line: 8)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/fixture"
        configuration.externalRetentionsPath = "/fixture/retentions.json"
        return CartographService(configuration: configuration, environment: CartographEnvironment(
            fileSystem: try fileSystem(name), indexProviderOverride: StaticIndexProvider(builder.build())))
    }

    @Test("실제 생산자의 오래된 경고와 미지원 출처는 원래 루트·호출 근거를 바꾸지 않는다",
          arguments: ["stale-matched", "unknown-version", "current-stale-matched"])
    func matchedRootsAndEvidence(_ name: String) throws {
        let baseline = try load(name.hasPrefix("current-") ? "current-baseline" : "baseline")
        let document = try load(name)
        #expect(document.retentions == baseline.retentions)
        #expect(document.retentions.map(\.symbol.usr) == ["s:handler"])
        let evidence = try #require(document.retentions.first?.evidence)
        #expect(evidence.channel == "camera")
        #expect(evidence.method == "photo")
        #expect(evidence.caller == .init(platform: "dart", path: "lib/bridge.dart", line: 4))
        let service = try service(name)
        let query = try service.queryDocument(symbol: "s:handler")
        #expect(query.result?.reachability.state == "retained")
        #expect(query.result?.reachability.reason == .externalBridge)
        #expect(try service.queryDocument(symbol: "s:Unused").result?.reachability.state == "unreachable")
        let dead = try service.detectUnusedCode()
        #expect(dead.findingCount == 1)
        #expect(dead.output.contains("'App.Unused' is never used"))
        let explain = try service.explainRetention(of: "s:handler")
        #expect(explain.output.contains("dart lib/bridge.dart:4 invokes 'photo' on channel 'camera'"))
        let caveat = name == "unknown-version" ? "external-retentions-provenance-unsupported" : staleWarning
        #expect(query.limitations.contains { $0.contains(caveat) })
        #expect(explain.notes.contains { $0.contains(caveat) })
        #expect(try service.queryDocument(symbol: "missing").limitations.contains { $0.contains(caveat) })
        if name.hasSuffix("stale-matched") {
            #expect(document.provenance?.sources?.count == 2)
            #expect(query.limitations.filter { $0.hasPrefix("external-retentions-source:") }.count == 2)
        }
    }

    @Test("실제 생산자 루트가 전혀 매치되지 않아도 문서 출처 경고는 사라지지 않는다",
          arguments: ["stale-matched", "unknown-version", "current-stale-matched"])
    func unmatchedRootsKeepContext(_ name: String) throws {
        let query = try service(name, includeHandler: false).queryDocument(symbol: "missing")
        let caveat = name == "unknown-version" ? "external-retentions-provenance-unsupported" : staleWarning
        #expect(query.limitations.contains { $0.contains(caveat) })
        #expect(query.limitations.contains { $0.hasPrefix("external-retentions-unmatched: 1 of 1") })
    }

    @Test("실제 생산자의 빈 보존 결과에도 두 캡처와 오래된 경고를 서비스가 전한다",
          arguments: ["zero-retentions", "current-zero-retentions"])
    func zeroRetentionsKeepContext(_ name: String) throws {
        let document = try load(name)
        #expect(document.retentions.isEmpty)
        #expect(document.provenance?.sources?.count == 2)
        let service = try service(name)
        #expect(try service.queryDocument(symbol: "s:handler").result?.reachability.state == "unreachable")
        let missing = try service.queryDocument(symbol: "missing")
        #expect(missing.limitations.contains { $0.contains(staleWarning) })
        #expect(missing.limitations.filter { $0.hasPrefix("external-retentions-source:") }.count == 2)
        #expect(try service.explainRetention(of: "missing").notes.contains { $0.contains(staleWarning) })
        // Unreachable is an analysis result, not deletion permission under incomplete capture context.
    }

    @Test("실제 서비스 캡처·복원·rebase는 빈 문서와 미지원 Unicode 출처까지 보존한다",
          arguments: ["stale-matched", "zero-retentions", "unknown-version",
                      "current-baseline", "current-stale-matched", "current-zero-retentions"])
    func captureRestoreAndRebase(_ name: String) throws {
        let original = try load(name)
        let captured = try service(name).captureSnapshot()
        #expect(captured.externalRetentions == original)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(captured)
        let restored = try AnalysisSnapshotDocument.decode(from: encoded)
        #expect(restored.externalRetentions == original)
        #expect(restored.rebased(to: "/moved").externalRetentions == original)
        #expect(restored.externalRetentions?.provenance?.value.canonicalJSON
            == original.provenance?.value.canonicalJSON)
        if name == "unknown-version" {
            let raw = try #require(restored.externalRetentions?.provenance?.value.canonicalJSON)
            #expect(raw.contains("\"é\":\"composed\""))
            #expect(raw.contains("\"e\u{0301}\":\"decomposed\""))
        }
    }
}
