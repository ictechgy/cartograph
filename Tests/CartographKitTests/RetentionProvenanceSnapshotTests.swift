import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("보존 출처의 snapshot과 표시 경계")
struct RetentionProvenanceSnapshotTests {
    private func provenance(_ raw: String) throws -> ExternalRetentionProvenance {
        try RetentionProvenanceAdmission.parseEnvelope(Data(raw.utf8))
    }
    private func snapshot(_ context: ExternalRetentionProvenance?) -> AnalysisSnapshotDocument {
        AnalysisSnapshotDocument(projectRoot: "/p", snapshot: SnapshotBuilder(module: "App", path: "/p/App.swift").build(),
            externalRetentions: ExternalRetentionsDocument(retentions: [], provenance: context))
    }
    private func encode(_ document: AnalysisSnapshotDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    @Test("알 수 없는 Unicode 키 문맥은 별도 compact 필드로 손실 없이 왕복·rebase된다")
    func roundtripsOpaqueContext() throws {
        let context = try provenance(#"{"version":2,"é":"é","e\u0301":"e\u0301"}"#)
        let encoded = try encode(snapshot(context))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["externalRetentionProvenanceJSON"] as? String == context.value.canonicalJSON)
        #expect((object["externalRetentions"] as? [String: Any])?["provenance"] == nil)
        let decoded = try AnalysisSnapshotDocument.decode(from: encoded)
        #expect(decoded.externalRetentions?.provenance == context)
        #expect(decoded.rebased(to: "/moved").externalRetentions?.provenance == context)
        #expect(decoded.externalRetentions?.retentions == [])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AnalysisSnapshotDocument.self, from: encoded) }
    }

    @Test("옛 snapshot은 출처 미상으로 유지하며 저장된 원본 출처를 다시 검증한다")
    func legacyAndMalformedSnapshot() throws {
        let data = try encode(snapshot(nil))
        let decoded = try JSONDecoder().decode(AnalysisSnapshotDocument.self, from: data)
        #expect(decoded.externalRetentions?.provenance == nil)
        for raw in [#"{"version":2,"n":1e-400}"#, #"{"version":2,"a":1,"a":2}"#, "null"] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["externalRetentionProvenanceJSON"] = raw
            let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            #expect(throws: (any Error).self) { try AnalysisSnapshotDocument.decode(from: malformed) }
        }
    }

    @Test("inline과 raw 출처가 함께 있으면 같은 의미만 허용하고 충돌은 실패한다")
    func detectsConflictingRepresentations() throws {
        let context = try provenance(#"{"version":2,"note":"one"}"#)
        var object = try #require(JSONSerialization.jsonObject(with: encode(snapshot(context))) as? [String: Any])
        var external = try #require(object["externalRetentions"] as? [String: Any])
        external["provenance"] = ["version": 2, "note": "one"]
        object["externalRetentions"] = external
        let equalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(try AnalysisSnapshotDocument.decode(from: equalData).externalRetentions?.provenance == context)
        object["externalRetentionProvenanceJSON"] = #"{"version":2,"note":"different"}"#
        let differentData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: (any Error).self) { try AnalysisSnapshotDocument.decode(from: differentData) }
    }

    @Test("빈 근거에도 legacy·미상·상류 한계를 표시하고 제어문자 escape 후 예산을 센다")
    func boundedDiagnostics() throws {
        #expect(ExternalRetentionProvenanceDiagnostics.limitations(nil).contains { $0.contains("unavailable") })
        #expect(ExternalRetentionProvenanceDiagnostics.limitations(try provenance(#"{"version":2}"#)).contains { $0.contains("unsupported") })
        let record = #"{"platform":"swift","target":null,"tool":"future","message":"stale\n\u001b[31m","origin":"future-origin"}"#
        let context = try provenance("{\"version\":1,\"sources\":[],\"limitations\":[" + Array(repeating: record, count: 100).joined(separator: ",") + "]}")
        let diagnostics = ExternalRetentionProvenanceDiagnostics.limitations(context)
        #expect(diagnostics.contains { $0.contains("source-context-unavailable") })
        let rendered = diagnostics.filter { $0.hasPrefix("external-retentions-upstream:") }
        #expect(rendered.count <= 64)
        #expect(rendered.reduce(0) { $0 + $1.utf8.count } <= 8192)
        #expect(rendered.allSatisfy { !$0.contains("\n") && !$0.contains("\u{1b}") })
        #expect(diagnostics.contains { $0.contains("\(100 - rendered.count) omitted") })
        #expect(context.limitations?.count == 100)
    }
}
