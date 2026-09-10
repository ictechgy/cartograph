@testable import CartographAnalysis
import CartographCore
import CartographTestSupport
import Foundation
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
              "symbol": { "usr": "s:handle", "qualifiedName": "CameraPlugin.handle" },
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

    /// isthmus v0 additive 확장: 전체 호출 목록과 상한 초과 계수. 대표 caller 는 그대로다.
    static let multiCallerDocument = """
        {
          "format": "external-retentions",
          "version": 0,
          "retentions": [
            {
              "symbol": { "usr": "s:handle", "qualifiedName": "CameraPlugin.handle" },
              "reason": "bridge",
              "evidence": {
                "channel": "com.example/camera",
                "method": "takePhoto",
                "caller": { "platform": "dart", "path": "lib/camera.dart", "line": 42 },
                "callers": [
                  { "platform": "dart", "path": "lib/camera.dart", "line": 42 },
                  { "platform": "dart", "path": "lib/photo.dart", "line": 17 },
                  { "platform": "kotlin", "path": "Camera.kt", "line": 9 }
                ],
                "callersOmitted": 3
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

    @Test("그래프 밖 ObjC 핸들러 수는 선택적이며 음수는 거부한다")
    func validatesOmittedObjectiveCCount() throws {
        let old = try makeStore(Self.validDocument).load(from: "/p/retentions.json")
        #expect(old.omittedObjectiveCHandlers == nil)
        let counted = #"{"format":"external-retentions","version":0,"retentions":[],"omittedObjectiveCHandlers":3}"#
        #expect(try makeStore(counted).load(from: "/p/retentions.json").omittedObjectiveCHandlers == 3)
        let invalid = counted.replacingOccurrences(of: ":3", with: ":-1")
        #expect(throws: CartographError.self) { try makeStore(invalid).load(from: "/p/retentions.json") }
    }

    @Test("근거 문장은 플랫폼·위치·메서드·채널을 담는다")
    func describesEvidence() throws {
        let document = try makeStore(Self.validDocument).load(from: "/p/retentions.json")
        #expect(
            document.retentions.first?.evidenceDescription
                == "dart lib/camera.dart:42 invokes 'takePhoto' on channel 'com.example/camera'"
        )
    }

    @Test("여러 호출자를 나열하고 상한을 넘은 수는 +N more 로만 알린다")
    func describesMultipleCallers() throws {
        let document = try makeStore(Self.multiCallerDocument).load(from: "/p/retentions.json")
        #expect(document.retentions.first?.evidence?.callers?.count == 3)
        #expect(document.retentions.first?.evidence?.callersOmitted == 3)
        #expect(
            document.retentions.first?.evidenceDescription
                == "dart lib/camera.dart:42, dart lib/photo.dart:17, kotlin Camera.kt:9, +3 more "
                    + "invokes 'takePhoto' on channel 'com.example/camera'"
        )
    }

    @Test("표시 상한을 넘는 호출자도 나머지 수에 합쳐 세고 문장은 짧게 유지한다")
    func truncatesLongCallerLists() {
        func caller(_ line: Int) -> ExternalRetention.Caller {
            .init(platform: "dart", path: "lib/c\(line).dart", line: line)
        }
        let retention = ExternalRetention(
            symbol: .init(usr: "s:x", qualifiedName: nil),
            reason: "bridge",
            evidence: .init(channel: "c", method: "m", caller: caller(1),
                            callers: (1...5).map { caller($0) }, callersOmitted: 2)
        )
        #expect(
            retention.evidenceDescription
                == "dart lib/c1.dart:1, dart lib/c2.dart:2, dart lib/c3.dart:3, +4 more invokes 'm' on channel 'c'"
        )
    }

    @Test("호출자가 하나뿐인 callers 문서는 기존 문장과 바이트가 같다")
    func singleCallerListRendersAsBefore() throws {
        let evidence = ExternalRetention.Evidence(
            channel: "com.example/camera",
            method: "takePhoto",
            caller: .init(platform: "dart", path: "lib/camera.dart", line: 42),
            callers: [.init(platform: "dart", path: "lib/camera.dart", line: 42)]
        )
        let retention = ExternalRetention(symbol: .init(usr: "s:handle", qualifiedName: nil), reason: "bridge", evidence: evidence)
        #expect(retention.evidenceDescription == "dart lib/camera.dart:42 invokes 'takePhoto' on channel 'com.example/camera'")
    }

    @Test("callers 가 비어 있으면 대표 호출로 돌아가고 옛 문서의 필드는 nil 이다")
    func emptyCallersFallBackToRepresentative() throws {
        let evidence = ExternalRetention.Evidence(
            channel: "c", method: "m",
            caller: .init(platform: "dart", path: "lib/a.dart", line: 1),
            callers: []
        )
        #expect(
            ExternalRetention(symbol: .init(usr: "s:x", qualifiedName: nil), reason: "bridge", evidence: evidence)
                .evidenceDescription == "dart lib/a.dart:1 invokes 'm' on channel 'c'"
        )
        let old = try makeStore(Self.validDocument).load(from: "/p/retentions.json")
        #expect(old.retentions.first?.evidence?.callers == nil)
        #expect(old.retentions.first?.evidence?.callersOmitted == nil)
    }

    @Test("호출 위치를 못 실었으면 남은 수라도 문장에서 지우지 않는다")
    func orphanOmittedCountStaysVisible() {
        let evidence = ExternalRetention.Evidence(channel: "c", method: "m", caller: nil, callers: [], callersOmitted: 5)
        #expect(
            ExternalRetention(symbol: .init(usr: "s:x", qualifiedName: nil), reason: "bridge", evidence: evidence)
                .evidenceDescription == "+5 more invokes 'm' on channel 'c'"
        )
    }

    @Test("음수 callersOmitted 는 거부한다")
    func rejectsNegativeCallersOmitted() {
        let invalid = Self.multiCallerDocument.replacingOccurrences(of: "\"callersOmitted\": 3", with: "\"callersOmitted\": -1")
        #expect(throws: CartographError.self) { try makeStore(invalid).load(from: "/p/retentions.json") }
    }

    @Test("callers 를 넣은 근거는 인코딩과 디코딩을 왕복한다")
    func roundTripsCallers() throws {
        let evidence = ExternalRetention.Evidence(
            channel: "c", method: "m",
            caller: .init(platform: "dart", path: "lib/a.dart", line: 1),
            callers: [.init(platform: "dart", path: "lib/a.dart", line: 1), .init(platform: "kotlin", path: "A.kt", line: nil)],
            callersOmitted: 0
        )
        let retention = ExternalRetention(symbol: .init(usr: "s:x", qualifiedName: nil), reason: "bridge", evidence: evidence)
        let data = try JSONEncoder().encode([retention])
        #expect(try JSONDecoder().decode([ExternalRetention].self, from: data) == [retention])
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

    @Test("같은 이름의 USR 근거가 이름만 있는 근거를 가리지 않는다")
    func usrEntryDoesNotShadowNameOnlyEntry() {
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType)
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, parent: "s:CameraPlugin")
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let index = ExternalRetentionIndex([
            ExternalRetention(symbol: .init(usr: "s:stale", qualifiedName: "CameraPlugin.handle"), reason: "bridge", evidence: nil),
            ExternalRetention(symbol: .init(usr: nil, qualifiedName: "CameraPlugin.handle"), reason: "bridge", evidence: nil),
        ])
        #expect(RetentionPolicy(externalRetentions: index).retainedNodes(in: graph, snapshot: snapshot)[NodeID("s:handle")] == .externalBridge)
    }

    @Test("이름만 있는 근거가 여러 선언에 맞으면 전부 살리되 그 수를 센다")
    func countsAmbiguousNameMatches() {
        var builder = SnapshotBuilder(module: "App")
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType)
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, parent: "s:CameraPlugin")
        builder.symbol("v:CameraPlugin", name: "CameraPlugin", kind: .classType, module: "VendorKit")
        builder.symbol("v:handle", name: "handle(_:result:)", kind: .method, module: "VendorKit", parent: "v:CameraPlugin")
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)

        let index = ExternalRetentionIndex([
            ExternalRetention(symbol: .init(usr: nil, qualifiedName: "CameraPlugin.handle"), reason: "bridge", evidence: nil),
        ])
        let retained = RetentionPolicy(externalRetentions: index).retainedNodes(in: graph, snapshot: snapshot)
        #expect(retained[NodeID("s:handle")] == .externalBridge)
        #expect(retained[NodeID("v:handle")] == .externalBridge)
        #expect(index.ambiguousNameMatchCount(in: graph) == 1)
        #expect(index.unmatchedCount(in: graph) == 0)
    }

    @Test("이름으로 맞은 근거는 USR 이 없다는 사실을 남긴다")
    func nameOnlyRetentionHasNoUSR() {
        let retention = ExternalRetention(symbol: .init(usr: nil, qualifiedName: "CameraPlugin.handle"), reason: "bridge", evidence: nil)
        #expect(retention.symbol.usr == nil)
    }

    @Test("근거 문장의 제어 문자는 지운다")
    func stripsControlCharactersFromEvidence() {
        let retention = ExternalRetention(
            symbol: .init(usr: "s:x", qualifiedName: nil), reason: "bridge",
            evidence: .init(channel: "c\u{1B}[31m", method: "m\nfake: line", caller: nil)
        )
        #expect(retention.evidenceDescription == "invokes 'mfake: line' on channel 'c[31m'")
        // 양방향 재정의(U+202E) 같은 형식 문자도 터미널을 속인다.
        #expect(ExternalRetention.printable("a\u{202E}b") == "ab")
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
