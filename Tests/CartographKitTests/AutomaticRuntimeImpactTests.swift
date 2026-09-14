import CartographCore
import CartographAnalysis
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("자동 런타임 영향 통합")
struct AutomaticRuntimeImpactTests {
    private let path = "/p/App.swift"

    private func fixture() -> (CartographService, AnalysisContext) {
        let typeLocation = CartographCore.SourceLocation(path: path, line: 10, column: 7)
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "load", name: "load()", kind: .function, module: "App",
                location: .init(path: path, line: 1, column: 6)),
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
            ]),
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
            runtimeFreshness: [path: .fresh, "/p/Tests/Load.swift": .fresh])
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
}
