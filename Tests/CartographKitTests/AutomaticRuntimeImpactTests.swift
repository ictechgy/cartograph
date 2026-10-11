import CartographCore
import CartographAnalysis
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("자동 런타임 영향 통합")
struct AutomaticRuntimeImpactTests {
    private let path = "/p/App.swift"

    private func fixture(
        freshness: RuntimeFreshness = .fresh, sourceIsTest: Bool = false, scannerLimitations: [String] = []
    ) -> (CartographService, AnalysisContext) {
        let typeLocation = CartographCore.SourceLocation(path: path, line: 10, column: 7)
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "load", name: "load()", kind: .function, module: "App",
                location: .init(path: path, line: 1, column: 6), attributes: sourceIsTest ? [.unitTest] : []),
            .init(usr: "screen", name: "Screen", kind: .classType, module: "App", location: typeLocation),
            .init(usr: "test", name: "testLoad()", kind: .function, module: "Tests",
                location: .init(path: "/p/Tests/Load.swift", line: 1, column: 6), attributes: [.unitTest]),
        ], references: [
            .init(sourceUSR: "load", targetUSR: "c:@F@NSClassFromString", kind: .call,
                location: .init(path: path, line: 2, column: 5)),
            .init(sourceUSR: "test", targetUSR: "load", kind: .call),
        ])
        let runtimeFiles: [RuntimeFileFacts] = [
            .init(path: path, declarations: [
                .init(name: "Screen", indexName: "Screen", qualifiedName: "Screen", kind: .classType,
                    location: typeLocation, endLocation: .init(path: path, line: 12, column: 1),
                    objectiveCName: "RuntimeScreen"),
            ], boundaries: [
                .init(kind: .classLookup, api: "NSClassFromString",
                    location: .init(path: path, line: 2, column: 23),
                    calleeLocation: .init(path: path, line: 2, column: 5),
                    name: "RuntimeScreen", nameOrigin: .literal),
            ], limitations: scannerLimitations),
            .init(path: "/p/Main.xib", boundaries: [
                .init(kind: .interfaceBuilderClass, api: "customClass",
                    location: .init(path: "/p/Main.xib", line: 1, column: 1),
                    name: "Screen", nameOrigin: .resource, receiverTypeName: "App.Screen"),
            ]),
        ]
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration,
            environment: .init(fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(snapshot)))
        let context = AnalysisContext(snapshot: snapshot, runtimeFiles: runtimeFiles,
            runtimeFreshness: [path: freshness, "/p/Tests/Load.swift": .fresh])
        return (service, context)
    }

    @Test("계약 파일 없이 문자열 조회 호출자와 전이 테스트를 영향으로 찾는다")
    func followsAutomaticConnections() throws {
        let (service, context) = fixture()
        let before = context.buildGraph(level: .symbol).graph
        let document = try service.impactDocument(symbols: ["Screen"], in: context)
        #expect(document.affected.compactMap(\.symbol.usr) == ["load", "test"])
        #expect(document.affected.first?.relationship == "automaticRuntime")
        #expect(document.affected.first?.runtimeContracts == nil)
        #expect(document.affected.first?.runtimeEvidence?.first?.origin == .automatic)
        #expect(document.automaticRuntime?.connectionCount == 2)
        #expect(document.tests.contains { $0.usr == "test" })
        #expect(before.outgoingEdges(from: NodeID("load")).isEmpty)
        #expect(context.buildGraph(level: .symbol).graph.outgoingEdges(from: NodeID("load")).isEmpty)
    }

    @Test("리소스 파일 선택은 연결된 Swift 선언과 코드 밖 소비자를 찾는다")
    func selectsResourceConnections() throws {
        let (service, context) = fixture()
        let document = try service.impactDocument(files: ["Main.xib"], in: context)
        #expect(document.status == "found")
        #expect(document.selected.compactMap(\.usr) == ["screen"])
        #expect(document.affected.compactMap(\.symbol.usr) == ["load", "test"])
    }

    @Test("텍스트도 자동 근거와 잘린 결과 및 편집 후 검증 필요를 전달한다")
    func rendersEvidenceAndLimits() throws {
        let (service, context) = fixture()
        let document = try service.impactDocument(symbols: ["Screen"], limit: 1, in: context)
        let text = document.renderText()
        #expect(text.contains("Automatic runtime:"))
        #expect(text.contains("automaticRuntime"))
        #expect(text.contains("Truncated sections:"))
        #expect(text.contains("Rebuild and run relevant tests"))
        #expect(!text.contains("safe to delete"))
    }

    @Test("affected도 자동 런타임 연결 뒤의 전이 테스트를 impact와 동일하게 찾는다")
    func affectedFollowsAutomaticConnections() throws {
        let (service, context) = fixture()
        let impact = try service.impactDocument(symbols: ["Screen"], in: context)
        let affected = try service.affectedDocument(symbols: ["Screen"], in: context)
        #expect(affected.tests.map(\.symbol.usr) == ["test"])
        #expect(affected.tests.map(\.symbol.usr) == impact.tests.map(\.usr))
        #expect(affected.tests.first?.depth == 2)
        #expect(affected.tests.first?.via?.usr == "load")
        #expect(affected.summary.affectedSymbols == impact.summary.affectedSymbols)
        #expect(affected.xcodebuildSelection().output == "-only-testing:Tests\n")
        #expect(affected.xcodebuildSelection().refusal == nil)
    }

    @Test("affected 리소스 선택이 Swift 선언과 런타임 소비자 테스트를 함께 찾는다")
    func affectedSelectsResourceConnections() throws {
        let (service, context) = fixture()
        let affected = try service.affectedDocument(files: ["Main.xib"], in: context)
        #expect(affected.status == "found")
        #expect(affected.selectionIssues.isEmpty)
        #expect(affected.selected.map(\.usr) == ["screen"])
        #expect(affected.tests.map(\.symbol.usr) == ["test"])
    }

    @Test("테스트가 직접 쓰는 자동 런타임 연결은 컴파일러 간선으로 위장하지 않는다")
    func affectedPreservesRuntimeProvenance() throws {
        let (service, context) = fixture(sourceIsTest: true)
        let affected = try service.affectedDocument(symbols: ["Screen"], in: context)
        let direct = try #require(affected.tests.first { $0.symbol.usr == "load" })
        #expect(direct.relationship == "automaticRuntime")
        #expect(direct.edges.isEmpty)
        #expect(direct.depth == 1)
        #expect(direct.runtimeEvidence?.count == 1)
        #expect(direct.runtimeEvidence?.first?.origin == .automatic)
        #expect(direct.runtimeEvidence?.first?.kind == .classLookup)
        let encoded = try JSONEncoder().encode(affected)
        #expect(try JSONDecoder().decode(AffectedDocument.self, from: encoded) == affected)
    }

    @Test("낡은 자동 런타임 근거는 연결하지 않고 테스트 축소도 거부한다")
    func affectedRejectsStaleRuntimeSelection() throws {
        let (service, context) = fixture(freshness: .sourceNewerThanIndex)
        let affected = try service.affectedDocument(symbols: ["Screen"], in: context)
        #expect(affected.tests.isEmpty)
        #expect(affected.limitations.contains { $0.hasPrefix("unresolved-runtime-boundaries:") })
        #expect(affected.xcodebuildSelection().output.isEmpty)
        #expect(affected.xcodebuildSelection().refusal?.contains("Runtime analysis is incomplete") == true)
    }

    @Test("해석하지 못한 런타임 채널이 있으면 발견한 테스트를 보여 주되 축소 실행하지 않는다")
    func affectedRejectsUnsupportedRuntimeSelection() throws {
        let limitation = "Notification stream registration calls not yet modeled: 1."
        let (service, context) = fixture(scannerLimitations: [limitation])
        let affected = try service.affectedDocument(symbols: ["Screen"], in: context)
        #expect(affected.tests.map(\.symbol.usr) == ["test"])
        #expect(affected.limitations.contains(limitation))
        #expect(affected.limitations.contains { $0.hasPrefix("incomplete-runtime-analysis:") })
        #expect(affected.xcodebuildSelection().output.isEmpty)
        #expect(affected.xcodebuildSelection().refusal != nil)
    }

    @Test("자동 런타임 단계도 깊이 상한을 지키고 잘림 때문에 테스트 축소를 거부한다")
    func affectedRuntimeHonorsDepthLimit() throws {
        let (service, context) = fixture()
        let affected = try service.affectedDocument(symbols: ["Screen"], maxDepth: 1, in: context)
        #expect(affected.tests.isEmpty)
        #expect(affected.summary.affectedSymbols == 1)
        #expect(affected.truncated.depth)
        #expect(affected.xcodebuildSelection().refusal?.contains("truncated") == true)
    }

}
