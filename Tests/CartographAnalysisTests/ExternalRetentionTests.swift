@testable import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("외부 보존 근거")
struct ExternalRetentionTests {
    static let validDocument = """
        {
          "format": "external-retentions",
          "version": 0,
          "producedBy": { "name": "isthmus", "version": "0.1.0" },
          "generatedAt": "2026-09-04T12:00:00Z",
          "retentions": [
            {
              "symbol": { "usr": "s:handle", "qualifiedName": "App.CameraPlugin.handle" },
              "reason": "bridge",
              "evidence": {
                "channel": "com.example/camera",
                "method": "takePhoto",
                "caller": { "platform": "dart", "path": "lib/camera.dart", "line": 42 }
              }
            }
          ]
        }
        """

    private func makeStore(_ contents: String, at path: String = "/p/retentions.json") -> ExternalRetentionStore {
        ExternalRetentionStore(fileSystem: InMemoryFileSystem(files: [path: contents]))
    }

    @Test("계약대로 쓰인 파일을 읽는다")
    func loadsValidDocument() throws {
        let document = try makeStore(Self.validDocument).load(from: "/p/retentions.json")
        #expect(document.retentions.count == 1)
        #expect(document.retentions.first?.symbol.usr == "s:handle")
        #expect(document.retentions.first?.evidence?.caller?.line == 42)
        #expect(document.provenanceDescription == "isthmus 0.1.0, generated 2026-09-04T12:00:00Z")
    }

    @Test("근거 문장은 플랫폼·위치·메서드·채널을 담는다")
    func describesEvidence() throws {
        let document = try makeStore(Self.validDocument).load(from: "/p/retentions.json")
        #expect(
            document.retentions.first?.evidenceDescription
                == "dart lib/camera.dart:42 invokes 'takePhoto' on channel 'com.example/camera'"
        )
    }

    @Test("근거가 없으면 이유만 적고 지어내지 않는다")
    func describesMissingEvidence() {
        let retention = ExternalRetention(symbol: .init(usr: "s:x", qualifiedName: nil), reason: "bridge", evidence: nil)
        #expect(retention.evidenceDescription == "reason 'bridge' with no evidence attached")
    }

    @Test("없는 파일을 지정하면 조용히 넘어가지 않고 실패한다")
    func missingFileIsAnError() {
        let store = ExternalRetentionStore(fileSystem: InMemoryFileSystem())
        #expect(throws: CartographError.invalidExternalRetentions(path: "/p/none.json", reason: "file not found")) {
            try store.loadIfConfigured(at: "/p/none.json")
        }
    }

    @Test("경로를 주지 않으면 아무것도 읽지 않는다")
    func noPathLoadsNothing() throws {
        #expect(try ExternalRetentionStore(fileSystem: InMemoryFileSystem()).loadIfConfigured(at: nil) == nil)
    }

    @Test("다른 형식 이름과 지원하지 않는 버전은 거부한다")
    func rejectsWrongFormatAndVersion() {
        let wrongFormat = Self.validDocument.replacingOccurrences(of: "external-retentions", with: "bridge-facts")
        #expect(throws: CartographError.self) { try makeStore(wrongFormat).load(from: "/p/retentions.json") }

        let wrongVersion = Self.validDocument.replacingOccurrences(of: "\"version\": 0", with: "\"version\": 7")
        #expect(throws: CartographError.self) { try makeStore(wrongVersion).load(from: "/p/retentions.json") }

        #expect(throws: CartographError.self) { try makeStore("{ not json").load(from: "/p/retentions.json") }
    }

    @Test("USR 이 맞는 정점을 externalBridge 로 보존한다")
    func retainsMatchingNode() {
        var builder = SnapshotBuilder()
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method)
        builder.symbol("s:other", name: "other()", kind: .method)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let retention = ExternalRetention(symbol: .init(usr: "s:handle", qualifiedName: nil), reason: "bridge", evidence: nil)
        let policy = RetentionPolicy(externalRetentions: ExternalRetentionIndex([retention]))
        let retained = policy.retainedNodes(in: graph, snapshot: snapshot)
        #expect(retained[NodeID("s:handle")] == .externalBridge)
        #expect(retained[NodeID("s:other")] == nil)
    }

    @Test("USR 이 없으면 정규화된 이름으로 맞춘다")
    func fallsBackToQualifiedName() {
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let retention = ExternalRetention(
            symbol: .init(usr: nil, qualifiedName: "App.handle(_:result:)"), reason: "bridge", evidence: nil
        )
        let policy = RetentionPolicy(externalRetentions: ExternalRetentionIndex([retention]))
        #expect(policy.retainedNodes(in: graph, snapshot: snapshot)[NodeID("s:handle")] == .externalBridge)
    }

    @Test("근거에 USR 이 있으면 이름이 같아도 다른 USR 의 선언은 살리지 않는다")
    func usrVetoesNameMatch() {
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:vendorCopy", name: "handle(_:result:)", kind: .method)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let retention = ExternalRetention(
            symbol: .init(usr: "s:handle", qualifiedName: "App.handle(_:result:)"), reason: "bridge", evidence: nil
        )
        let policy = RetentionPolicy(externalRetentions: ExternalRetentionIndex([retention]))
        #expect(policy.retainedNodes(in: graph, snapshot: snapshot).isEmpty)
    }

    @Test("계약 표기의 이름(Type.member)으로도 맞는다")
    func matchesSyntaxQualifiedName() {
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType)
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, parent: "s:CameraPlugin")
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        #expect(ExternalRetentionIndex.syntaxQualifiedName(of: graph.node(NodeID("s:handle"))!, in: graph) == "CameraPlugin.handle")

        let retention = ExternalRetention(
            symbol: .init(usr: nil, qualifiedName: "CameraPlugin.handle"), reason: "bridge", evidence: nil
        )
        let index = ExternalRetentionIndex([retention])
        let policy = RetentionPolicy(externalRetentions: index)
        #expect(policy.retainedNodes(in: graph, snapshot: snapshot)[NodeID("s:handle")] == .externalBridge)
        #expect(index.unmatchedCount(in: graph) == 0)
    }

    @Test("외부 근거가 없으면 보존 결과가 그대로다")
    func emptyIndexChangesNothing() {
        var builder = SnapshotBuilder()
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        #expect(RetentionPolicy().retainedNodes(in: graph, snapshot: snapshot).isEmpty)
    }

    @Test("그래프에 없는 근거의 수를 센다")
    func countsUnmatchedRetentions() {
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: builder.build())

        let index = ExternalRetentionIndex([
            ExternalRetention(symbol: .init(usr: "s:handle", qualifiedName: nil), reason: "bridge", evidence: nil),
            ExternalRetention(symbol: .init(usr: "s:renamed", qualifiedName: "App.gone()"), reason: "bridge", evidence: nil),
            ExternalRetention(symbol: .init(usr: nil, qualifiedName: "App.handle(_:result:)"), reason: "bridge", evidence: nil),
        ])
        #expect(index.unmatchedCount(in: graph) == 1)
        #expect(index.count == 3)
    }
}
