import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("외부 보존 근거를 반영한 파이프라인")
struct ExternalRetentionServiceTests {
    private static let retentions = """
        {
          "format": "external-retentions",
          "version": 0,
          "producedBy": { "name": "isthmus", "version": "0.1.0" },
          "generatedAt": "2026-09-04T12:00:00Z",
          "retentions": [
            {
              "symbol": { "usr": "s:handle", "qualifiedName": "App.handle(_:result:)" },
              "reason": "bridge",
              "evidence": {
                "channel": "com.example/camera",
                "method": "takePhoto",
                "caller": { "platform": "dart", "path": "lib/camera.dart", "line": 42 }
              }
            },
            {
              "symbol": { "usr": "s:renamed", "qualifiedName": "App.renamed()" },
              "reason": "bridge",
              "evidence": null
            }
          ]
        }
        """

    /// 진입점에서 닿지 않는 핸들러가 하나 있는 프로젝트. 인덱스만 보면 죽은 코드다.
    private func makeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/CameraPlugin.swift")
        builder.symbol("s:Main", name: "Main", kind: .structType, attributes: [.entryPoint])
        builder.symbol("s:CameraPlugin", name: "CameraPlugin", kind: .classType, line: 2)
        builder.symbol("s:handle", name: "handle(_:result:)", kind: .method, line: 7, parent: "s:CameraPlugin")
        builder.symbol("s:helper", name: "helper()", kind: .method, line: 12, parent: "s:CameraPlugin")
        builder.reference(from: "s:handle", to: "s:helper", kind: .call)
        return builder.build()
    }

    private func makeService(retentionsPath: String? = "/p/retentions.json") -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.externalRetentionsPath = retentionsPath
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(files: ["/p/retentions.json": Self.retentions]),
                indexProviderOverride: StaticIndexProvider(makeSnapshot())
            )
        )
    }

    @Test("외부 근거가 없으면 핸들러와 그 호출 대상이 미사용으로 보고된다")
    func withoutRetentionsHandlerIsUnused() throws {
        let outcome = try makeService(retentionsPath: nil).detectUnusedCode()
        #expect(outcome.output.contains("'App.CameraPlugin' is never used"))
        #expect(outcome.findingCount == 1)
    }

    @Test("외부 근거가 있으면 핸들러가 살고 그것이 부르는 것도 함께 산다")
    func retentionsKeepHandlerAndItsCallees() throws {
        let outcome = try makeService().detectUnusedCode()
        #expect(outcome.findingCount == 0)
        #expect(!outcome.output.contains("never used"))
    }

    @Test("--explain 은 근거를 문장으로 만든다")
    func explainQuotesEvidence() throws {
        let output = try makeService().explainRetention(of: "s:handle").output
        #expect(output.contains("is retained because it is called from another platform across a bridge"))
        #expect(output.contains("evidence: dart lib/camera.dart:42 invokes 'takePhoto' on channel 'com.example/camera'"))

        // 멤버 때문에 살아난 타입에도 그 멤버의 근거가 붙는다.
        let parent = try makeService().explainRetention(of: "CameraPlugin").output
        #expect(parent.contains("its member App.handle(_:result:)"))
        #expect(parent.contains("evidence: dart lib/camera.dart:42"))
    }

    @Test("query 는 이유를 값으로 주고 한계에 파일의 출처와 맞지 않는 수를 싣는다")
    func queryReportsReasonAndLimitations() throws {
        let document = try makeService().queryDocument(symbol: "s:handle")
        #expect(document.result?.reachability.state == "retained")
        #expect(document.result?.reachability.reason == .externalBridge)
        #expect(document.limitations.contains {
            $0.hasPrefix("external-retentions: 2 retention(s) from isthmus 0.1.0, generated 2026-09-04T12:00:00Z")
        })
        #expect(document.limitations.contains { $0.hasPrefix("external-retentions-unmatched: 1 of 2") })
    }

    @Test("근거 파일이 인덱스보다 오래됐으면 그렇다고 알린다")
    func reportsStaleFile() throws {
        let service = makeService()
        let context = try service.loadContext()
        let stale = service.analysisLimitations(
            storeDate: Date(timeIntervalSince1970: 1_800_000_000), context: context
        )
        #expect(stale.contains { $0.hasPrefix("external-retentions-stale: the retentions file (2026-09-04T12:00:00Z) predates") })

        let fresh = service.analysisLimitations(storeDate: Date(timeIntervalSince1970: 1_700_000_000), context: context)
        #expect(!fresh.contains { $0.hasPrefix("external-retentions-stale") })
    }

    @Test("dead 의 JSON 리포트에도 한계가 실린다")
    func deadJSONCarriesLimitations() throws {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.externalRetentionsPath = "/p/retentions.json"
        configuration.reportFormat = .json
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(files: ["/p/retentions.json": Self.retentions]),
                indexProviderOverride: StaticIndexProvider(makeSnapshot())
            )
        )
        struct Document: Decodable { let limitations: [String]? }
        let output = try service.detectUnusedCode().output
        let limitations = try JSONDecoder().decode(Document.self, from: Data(output.utf8)).limitations ?? []
        #expect(limitations.contains { $0.hasPrefix("external-retentions: 2 retention(s) from isthmus 0.1.0") })
        // 단일 구성 한계는 언제나 실리므로 `dead` 에서 이 키는 비지 않는다.
        #expect(limitations.contains { $0.hasPrefix("single-configuration") })

        // 다른 명령의 리포트에는 붙지 않는다. 순환에는 보존 규칙이 없다.
        #expect(!(try service.detectCycles().output.contains("\"limitations\"")))
    }

    @Test("외부 근거를 걸지 않으면 한계에도 등장하지 않는다")
    func noRetentionsNoLimitation() throws {
        let document = try makeService(retentionsPath: nil).queryDocument(symbol: "s:handle")
        #expect(!document.limitations.contains { $0.hasPrefix("external-retentions") })
    }

    @Test("지정한 파일이 없으면 도구 실패로 끝난다")
    func missingFileFails() {
        #expect(throws: CartographError.self) {
            try makeService(retentionsPath: "/p/missing.json").detectUnusedCode()
        }
    }
}
