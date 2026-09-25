import CartographAnalysis
import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("테스트 영향 질의")
struct AffectedDocumentTests {
    private func service(_ snapshot: IndexSnapshot) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return CartographService(
            configuration: configuration,
            environment: .init(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(snapshot),
                usesSyntaxCache: false
            )
        )
    }

    /// 프로덕션 함수 P를 가운데 M이 부르고, 테스트 T가 M을 부른다.
    private func snapshot(includeTest: Bool = true, includeType: Bool = false) -> IndexSnapshot {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("P", name: "process()", kind: .function, path: "/p/Sources/P.swift", line: 1)
        builder.symbol("M", name: "middle()", kind: .function, path: "/p/Sources/M.swift", line: 1)
        builder.reference(from: "M", to: "P", kind: .call, path: "/p/Sources/M.swift")
        if includeTest {
            builder.symbol("T", name: "testProcess()", kind: .method, path: "/p/Tests/ATests.swift",
                line: 1, attributes: [.unitTest])
            builder.reference(from: "T", to: "M", kind: .call, path: "/p/Tests/ATests.swift")
        }
        if includeType {
            builder.symbol("S", name: "Service", kind: .structType, path: "/p/Sources/S.swift", line: 1)
            builder.symbol("S.run", name: "run()", kind: .method, path: "/p/Sources/S.swift",
                line: 2, parent: "S")
            builder.reference(from: "M", to: "S.run", kind: .call, path: "/p/Sources/M.swift")
        }
        return builder.build()
    }

    private func document(
        _ service: CartographService,
        symbols: [String] = [], files: [String] = [], depth: Int? = nil, limit: Int = 200
    ) throws -> AffectedDocument {
        try service.affectedDocument(symbols: symbols, files: files, maxDepth: depth, limit: limit)
    }

    @Test("변경에 도달하는 테스트를 거리와 경유와 함께 답한다")
    func reportsTestsWithDistance() throws {
        let document = try document(service(snapshot()), symbols: ["P"])
        #expect(document.status == "found")
        #expect(document.summary.testCount == 1)
        #expect(document.summary.changedTestCount == 0)
        #expect(document.summary.affectedSymbols == 2)
        #expect(document.summary.testFiles == ["/p/Tests/ATests.swift"])
        #expect(document.summary.modules == ["App"])
        let test = try #require(document.tests.first)
        #expect(test.symbol.usr == "T")
        #expect(test.depth == 2)
        #expect(test.via?.usr == "M")
        #expect(test.relationship == "dependent")
        #expect(test.edges == ["call"])
    }

    @Test("테스트 자신을 고친 변경은 depth 0 changed 로 보고한다")
    func reportsChangedTestAtDepthZero() throws {
        let document = try document(service(snapshot()), symbols: ["T"])
        #expect(document.summary.testCount == 1)
        #expect(document.summary.changedTestCount == 1)
        let test = try #require(document.tests.first)
        #expect(test.depth == 0)
        #expect(test.via == nil)
        #expect(test.relationship == "changed")
    }

    @Test("컨테이너 시드 확장이 멤버를 통해 테스트에 닿는다")
    func expandsContainerSeed() throws {
        // S를 고르면 그 멤버 S.run이 변경 범위에 들어가고, M → T로 이어진다.
        let document = try document(service(snapshot(includeType: true)), symbols: ["S"])
        #expect(document.summary.testCount == 1)
        #expect(document.tests.first?.symbol.usr == "T")
    }

    @Test("프로토콜 요구사항 경유 호출도 테스트에 투영된다")
    func projectsThroughProtocolRequirement() throws {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("Proto", kind: .protocolType, path: "/p/Sources/P.swift", line: 1)
        builder.symbol("Proto.req", name: "req()", kind: .method, path: "/p/Sources/P.swift",
            line: 2, parent: "Proto")
        builder.symbol("Impl", kind: .structType, path: "/p/Sources/Impl.swift", line: 1)
        builder.symbol("Impl.req", name: "req()", kind: .method, path: "/p/Sources/Impl.swift",
            line: 2, parent: "Impl")
        builder.symbol("M", name: "middle()", kind: .function, path: "/p/Sources/M.swift", line: 1)
        builder.symbol("T", name: "testReq()", kind: .method, path: "/p/Tests/ATests.swift",
            line: 1, attributes: [.unitTest])
        builder.reference(from: "Impl.req", to: "Proto.req", kind: .overrides,
            path: "/p/Sources/Impl.swift")
        builder.reference(from: "M", to: "Proto.req", kind: .call, path: "/p/Sources/M.swift")
        builder.reference(from: "T", to: "M", kind: .call, path: "/p/Tests/ATests.swift")

        // witness 변경에서 요구사항 호출자 M(dispatchCaller)을 거쳐 테스트에 닿는다.
        let document = try document(service(builder.build()), symbols: ["Impl.req"])
        #expect(document.summary.testCount == 1)
        #expect(document.tests.first?.symbol.usr == "T")
        #expect(document.tests.first?.via?.usr == "M")
        #expect(document.tests.first?.depth == 2)
    }

    @Test("테스트가 닿지 않으면 빈 목록과 그 사실을 함께 남긴다")
    func reportsNoTestReach() throws {
        let document = try document(service(snapshot(includeTest: false)), symbols: ["P"])
        #expect(document.status == "found")
        #expect(document.tests.isEmpty)
        #expect(document.summary.testCount == 0)
        let outcome = try service(snapshot(includeTest: false)).affected(symbols: ["P"], format: "text")
        #expect(outcome.output.contains("no test declaration reaches this change"))
        #expect(outcome.output.contains("does not prove existing tests cover this change"))
    }

    @Test("목록이 한도를 넘으면 전체 개수를 남기고 잘림을 표시한다")
    func truncationKeepsCounts() throws {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("P", name: "process()", kind: .function, path: "/p/Sources/P.swift", line: 1)
        for index in 1...3 {
            builder.symbol("T\(index)", name: "test\(index)()", kind: .method,
                path: "/p/Tests/ATests.swift", line: index, attributes: [.unitTest])
            builder.reference(from: "T\(index)", to: "P", kind: .call,
                path: "/p/Tests/ATests.swift")
        }
        let document = try document(service(builder.build()), symbols: ["P"], limit: 1)
        #expect(document.tests.count == 1)
        #expect(document.summary.testCount == 3)
        #expect(document.truncated.output)
        #expect(document.truncated.sections == ["tests"])
    }

    @Test("JSON 문서가 디코딩 왕복을 견딘다")
    func jsonRoundTrips() throws {
        let outcome = try service(snapshot()).affected(symbols: ["P"], format: "json")
        let decoded = try JSONDecoder().decode(AffectedDocument.self, from: Data(outcome.output.utf8))
        #expect(decoded.format == "change-affected")
        #expect(decoded.version == 1)
        #expect(decoded.tests.map(\.symbol.usr) == ["T"])
    }

    @Test("선택이 해소되지 않으면 사용 오류로 알린다")
    func unresolvedSelectionIsUsageError() throws {
        let outcome = try service(snapshot()).affected(symbols: ["NoSuchSymbol"], format: "json")
        #expect(outcome.subjectNotFound)
        #expect(outcome.incompleteAnalysis == nil)
    }

    /// P를 XCTest 메서드 두 개가 부른다: 최상위 클래스 안의 것과 클래스 밖의 것.
    private func xctestSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("P", name: "process()", kind: .function, path: "/p/Sources/P.swift", line: 1)
        builder.symbol("C", name: "ProcessTests", kind: .classType, module: "AppTests",
            path: "/p/Tests/ProcessTests.swift", line: 1, attributes: [.unitTest])
        builder.symbol("C.test", name: "testProcess()", kind: .method, module: "AppTests",
            path: "/p/Tests/ProcessTests.swift", line: 2, parent: "C", attributes: [.unitTest])
        builder.reference(from: "C.test", to: "P", kind: .call, path: "/p/Tests/ProcessTests.swift")
        builder.symbol("S", name: "processes()", kind: .function, module: "SuiteTests",
            path: "/p/Tests/Suite.swift", line: 1, attributes: [.unitTest])
        builder.reference(from: "S", to: "P", kind: .call, path: "/p/Tests/Suite.swift")
        return builder.build()
    }

    @Test("xcodebuild 형식은 증명한 식별자만 좁히고 나머지는 모듈 전체로 넓힌다")
    func xcodebuildNarrowsOnlyProvableIdentifiers() throws {
        let outcome = try service(xctestSnapshot()).affected(symbols: ["P"], format: "xcodebuild")
        #expect(outcome.output == "-only-testing:AppTests/ProcessTests/testProcess\n-only-testing:SuiteTests\n")
        #expect(outcome.incompleteAnalysis == nil)
        #expect(outcome.notes.first?.hasPrefix("1 test declaration(s) are selected by their whole test module") == true)
        let document = try document(service(xctestSnapshot()), symbols: ["P"])
        #expect(document.tests.first { $0.symbol.usr == "C.test" }?.xcodebuildIdentifier
            == "AppTests/ProcessTests/testProcess")
        #expect(document.tests.first { $0.symbol.usr == "S" }?.xcodebuildIdentifier == nil)
    }

    @Test("같은 모듈을 통째로 고르면 그 모듈의 개별 식별자는 싣지 않는다")
    func xcodebuildDropsIdentifiersCoveredByWholeModule() throws {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("P", name: "process()", kind: .function, path: "/p/Sources/P.swift", line: 1)
        builder.symbol("C", name: "ProcessTests", kind: .classType, path: "/p/Tests/A.swift", line: 1,
            attributes: [.unitTest])
        builder.symbol("C.test", name: "testProcess()", kind: .method, path: "/p/Tests/A.swift", line: 2,
            parent: "C", attributes: [.unitTest])
        builder.symbol("F", name: "free()", kind: .function, path: "/p/Tests/B.swift", line: 1,
            attributes: [.unitTest])
        builder.reference(from: "C.test", to: "P", kind: .call, path: "/p/Tests/A.swift")
        builder.reference(from: "F", to: "P", kind: .call, path: "/p/Tests/B.swift")
        let outcome = try service(builder.build()).affected(symbols: ["P"], format: "xcodebuild")
        #expect(outcome.output == "-only-testing:App\n")
    }

    @Test("xcodebuild 형식은 잘린 목록 대신 인자를 비우고 불완전한 분석으로 끝낸다")
    func xcodebuildRefusesTruncatedList() throws {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("P", name: "process()", kind: .function, path: "/p/Sources/P.swift", line: 1)
        for index in 1...2 {
            builder.symbol("T\(index)", name: "test\(index)()", kind: .method,
                path: "/p/Tests/ATests.swift", line: index, attributes: [.unitTest])
            builder.reference(from: "T\(index)", to: "P", kind: .call, path: "/p/Tests/ATests.swift")
        }
        let outcome = try service(builder.build()).affected(symbols: ["P"], limit: 1, format: "xcodebuild")
        #expect(outcome.output.isEmpty)
        #expect(outcome.incompleteAnalysis?.contains("xcodebuild would run every test") == true)
    }

    @Test("모듈 이름이 비어 있는 테스트가 닿으면 빈 선택자 대신 인자 없이 거부한다")
    func xcodebuildRefusesEmptyModule() throws {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("P", name: "process()", kind: .function, path: "/p/Sources/P.swift", line: 1)
        builder.symbol("T", name: "checks()", kind: .function, module: "", path: "/p/Tests/T.swift", line: 1,
            attributes: [.unitTest])
        builder.reference(from: "T", to: "P", kind: .call, path: "/p/Tests/T.swift")
        let outcome = try service(builder.build()).affected(symbols: ["P"], format: "xcodebuild")
        #expect(outcome.output.isEmpty)
        #expect(outcome.incompleteAnalysis?.contains("no module to select") == true)
    }

    @Test("xcodebuild 형식도 없는 이름은 인자 없이 사용 오류로 알린다")
    func xcodebuildUnresolvedSelectionIsUsageError() throws {
        let outcome = try service(snapshot()).affected(symbols: ["NoSuchSymbol"], format: "xcodebuild")
        #expect(outcome.output.isEmpty)
        #expect(outcome.subjectNotFound)
        #expect(outcome.incompleteAnalysis == nil)
    }

    @Test("테스트가 닿지 않으면 xcodebuild 인자도 없고 경고 없이 끝난다")
    func xcodebuildEmptyWhenNoTestReaches() throws {
        let outcome = try service(snapshot(includeTest: false)).affected(symbols: ["P"], format: "xcodebuild")
        #expect(outcome.output.isEmpty)
        #expect(outcome.incompleteAnalysis == nil)
        #expect(!outcome.subjectNotFound)
    }
}
