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
                fileSystem: InMemoryFileSystem(files: Dictionary(uniqueKeysWithValues:
                    snapshot.filePaths.map { ($0, "") })),
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

    /// 실행 형태가 알려진 양성 픽스처에만 원시 상속과 컴파일러 표식을 명시한다.
    private func provedSnapshot(
        _ builder: SnapshotBuilder, classes: Set<String>, methods: Set<String>
    ) -> IndexSnapshot {
        var snapshot = builder.build()
        snapshot.references += classes.map {
            .init(sourceUSR: $0, targetUSR: "c:objc(cs)XCTestCase", kind: .inheritance, origin: .compiler)
        }
        for index in snapshot.symbols.indices where methods.contains(snapshot.symbols[index].usr) {
            snapshot.symbols[index].compilerUnitTest = true
        }
        return snapshot
    }

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
        return provedSnapshot(builder, classes: ["C"], methods: ["C.test"])
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


    @Test("프로덕션 이름과 옛 표식은 후보를 유지하되 가짜 클래스 선택자를 만들지 않는다",
          arguments: [false, true])
    func preservesUnverifiedCandidates(compilerObserved: Bool) throws {
        var builder = SnapshotBuilder(module: "Production", path: "/p/Sources/Runner.swift")
        builder.symbol("P", kind: .function)
        builder.symbol("Runner", kind: .classType, attributes: [.unitTest])
        builder.symbol("Runner.test", name: "testConnection()", kind: .method,
            parent: "Runner", attributes: [.unitTest])
        builder.reference(from: "Runner.test", to: "P", kind: .call)
        var snapshot = builder.build()
        if compilerObserved {
            for index in snapshot.symbols.indices { snapshot.symbols[index].compilerUnitTest = false }
        }
        let document = try service(snapshot).affectedDocument(symbols: ["P"])
        #expect(document.tests.map(\.symbol.usr) == ["Runner.test"])
        #expect(document.tests.allSatisfy { $0.xcodebuildIdentifier == nil })
        #expect(document.xcodebuildSelection().output == "-only-testing:Production\n")
        #expect(document.limitations.contains { $0.hasPrefix("uncertain-test-identity:") })
        #expect(document.limitations.contains { $0.hasPrefix("test-target-assumption:") })
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
        let service = service(provedSnapshot(builder, classes: ["C"], methods: ["C.test"]))
        let document = try service.affectedDocument(symbols: ["P"])
        #expect(document.tests.first { $0.symbol.usr == "C.test" }?.xcodebuildIdentifier
            == "App/ProcessTests/testProcess")
        let outcome = try service.affected(symbols: ["P"], format: "xcodebuild")
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

    @Test("선택과 변경 범위 잘림도 테스트 수와 무관하게 명시한다")
    func reportsSelectionTruncation() throws {
        let document = try document(service(snapshot(includeTest: false)), symbols: ["P", "M"], limit: 1)
        #expect(document.summary.changeScopeSymbols == 2)
        #expect(document.summary.testCount == 0)
        #expect(document.selected.count == 1)
        #expect(document.changeScope.count == 1)
        #expect(document.requestedSymbols.count == 1)
        #expect(document.truncated.sections == ["changeScope", "requestedSymbols", "selected"])
        #expect(document.renderAffectedText().contains("Truncated sections: changeScope, requestedSymbols, selected"))
        #expect(document.xcodebuildSelection().refusal?.contains("truncated") == true)
    }

    @Test("미해결 입력과 모호한 후보도 문서 전체 한도로 제한하며 전체 개수는 보존한다")
    func boundsUnresolvedInputsAndCandidates() throws {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        for index in 1...3 {
            builder.symbol("P\(index)", name: "process()", kind: .function, module: "M\(index)")
        }
        let document = try document(service(builder.build()), symbols: ["process", "process", "missing"], limit: 2)
        #expect(document.summary.unresolvedInputs == 3)
        #expect(document.selectionIssues.count == 2)
        #expect(document.selectionIssues.first?.candidates?.count == 2)
        #expect(document.selectionIssues.first?.candidatesOmitted == 1)
        #expect(document.selectionIssues.last?.candidates?.isEmpty == true)
        #expect(document.selectionIssues.last?.candidatesOmitted == 3)
        #expect(document.truncated.sections == ["candidates", "requestedSymbols", "selectionIssues"])
        #expect(document.xcodebuildSelection().output.isEmpty)
    }

    @Test("파일과 모듈 요약의 잘림도 전체 개수와 함께 명시한다")
    func reportsFileAndModuleTruncation() throws {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("P", kind: .function)
        for index in 1...3 {
            builder.symbol("T\(index)", name: "testProcess()", kind: .method,
                module: "Tests\(index)", path: "/p/Tests/T\(index).swift", attributes: [.unitTest])
            builder.reference(from: "T\(index)", to: "P", kind: .call)
        }
        let document = try document(service(builder.build()), symbols: ["P"], limit: 1)
        #expect(document.summary.testCount == 3)
        #expect(document.summary.testFileCount == 3)
        #expect(document.summary.moduleCount == 3)
        #expect(document.summary.testFiles.count == 1)
        #expect(document.summary.modules.count == 1)
        #expect(document.truncated.sections == ["modules", "testFiles", "tests"])
    }

    @Test("동일 위치와 한정 이름의 테스트도 USR로 순서를 고정한다")
    func sortsCollidingTestIdentities() throws {
        var builder = SnapshotBuilder(path: "/p/Sources/P.swift")
        builder.symbol("P", kind: .function)
        for id in ["z", "a", "m"] {
            builder.symbol(id, name: "testProcess()", kind: .method,
                path: "/p/Tests/T.swift", line: 1, attributes: [.unitTest])
            builder.reference(from: id, to: "P", kind: .call)
        }
        let document = try document(service(builder.build()), symbols: ["P"])
        #expect(document.tests.map(\.symbol.usr) == ["a", "m", "z"])
    }

    @Test("일반 간선 응답은 선택적 런타임 필드를 생략하고 기존 v1 응답도 읽는다")
    func preservesVersionOneCompatibility() throws {
        let outcome = try service(snapshot()).affected(symbols: ["P"], format: "json")
        #expect(!outcome.output.contains("runtimeEvidence"))
        let decoded = try JSONDecoder().decode(AffectedDocument.self, from: Data(outcome.output.utf8))
        #expect(decoded.version == 1)
        #expect(decoded.tests.first?.runtimeEvidence == nil)
    }


    /// B의 런타임 조회에는 타입으로 향하는 컴파일러 간선이 없다.
    private func skippedRuntimeSourceSnapshot(suffix: String = "swift") -> IndexSnapshot {
        var builder = SnapshotBuilder(path: "/p/Sources/Screen.swift")
        builder.symbol("Screen", kind: .classType)
        builder.symbol("A", name: "testScreen()", kind: .method,
            path: "/p/Tests/A.swift", attributes: [.unitTest])
        builder.symbol("B", name: "testLookup()", kind: .method,
            path: "/p/Tests/B.\(suffix)", attributes: [.unitTest])
        builder.reference(from: "A", to: "Screen", kind: .reference)
        builder.reference(from: "B", to: "c:@F@NSClassFromString", kind: .call, path: "/p/Tests/B.\(suffix)")
        return builder.build()
    }

    @Test("런타임 사실을 만들지 못한 누락·읽기 실패 소스도 테스트 축소를 막는다", arguments: [false, true])
    func skippedSourceWithoutRuntimeFactsRefusesSelection(unreadable: Bool) throws {
        let snapshot = skippedRuntimeSourceSnapshot()
        let hidden = "/p/Tests/B.swift"
        let context = AnalysisContext(snapshot: snapshot,
            missingSourcePaths: unreadable ? [] : [hidden],
            unreadableSourcePaths: unreadable ? [hidden] : [], runtimeFiles: [])
        let document = try service(snapshot).affectedDocument(symbols: ["Screen"], in: context)
        #expect(document.tests.map(\.symbol.usr) == ["A"])
        #expect(context.runtimeDiscovery()?.findings.isEmpty == true)
        #expect(!document.limitations.contains { $0.hasPrefix("unresolved-runtime-boundaries:") })
        let prefix = unreadable ? "unreadable-sources:" : "missing-sources:"
        #expect(document.limitations.contains { $0.hasPrefix(prefix) })
        #expect(document.xcodebuildSelection().output.isEmpty)
        #expect(document.xcodebuildSelection().refusal?.contains("Source/index coverage is incomplete") == true)
    }

    @Test("모든 인덱스 언어의 읽기 실패가 명령의 불완전 분석 종료 결과까지 전달된다",
          arguments: ["swift", "m", "mm", "h"])
    func unreadableRuntimeSourceRefusesCommandSelection(suffix: String) throws {
        let snapshot = skippedRuntimeSourceSnapshot(suffix: suffix)
        let fileSystem = InMemoryFileSystem(files: Dictionary(uniqueKeysWithValues:
            snapshot.filePaths.map { ($0, "") }))
        fileSystem.setReadError(.fileReadNoPermission, for: "/p/Tests/B.\(suffix)")
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot), usesSyntaxCache: false))
        let outcome = try service.affected(symbols: ["Screen"], format: "xcodebuild")
        #expect(outcome.output.isEmpty)
        #expect(!outcome.subjectNotFound)
        #expect(outcome.incompleteAnalysis?.contains("Source/index coverage is incomplete") == true)
        #expect(outcome.notes.contains { $0.hasPrefix("unreadable-sources:") })
    }

    @Test("런타임 경계가 없어도 낡거나 인덱스가 없는 소스가 테스트 축소를 막는다", arguments: [false, true], ["swift", "m", "mm", "h"])
    func incompleteIndexRefusesSelection(stale: Bool, suffix: String) throws {
        let hidden = "/p/Tests/Unseen.\(suffix)"
        let indexed = Date(timeIntervalSince1970: 1_000)
        let fileSystem = InMemoryFileSystem(files: [hidden: ""])
        fileSystem.setModificationDate(indexed.addingTimeInterval(10), for: hidden)
        var snapshot = snapshot()
        snapshot.indexedFileDates = stale ? [hidden: indexed] : [:]
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot)))
        let context = AnalysisContext(snapshot: snapshot, runtimeFiles: [])
        let document = try service.affectedDocument(symbols: ["P"], in: context)
        #expect(document.tests.map(\.symbol.usr) == ["T"])
        let prefix = stale ? "index-staleness:" : "unindexed-sources:"
        #expect(document.limitations.contains { $0.hasPrefix(prefix) })
        #expect(document.xcodebuildSelection().output.isEmpty)
        #expect(document.xcodebuildSelection().refusal?.contains("Source/index coverage is incomplete") == true)
    }

    @Test("헤더의 날짜가 최신이어도 선언·호출 투영 한계가 있으면 테스트를 축소하지 않는다")
    func indexedHeaderProjectionStillRefusesSelection() throws {
        let header = "/p/Sources/API.h"
        let indexed = Date(timeIntervalSince1970: 1_000)
        let fileSystem = InMemoryFileSystem(files: [header: "int hidden(void);"])
        fileSystem.setModificationDate(indexed.addingTimeInterval(-10), for: header)
        var snapshot = snapshot()
        snapshot.indexedFileDates = [header: indexed]
        snapshot.oldestIndexedFileDates = [header: indexed]
        let configuration = CartographConfiguration(projectPath: "/p")
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot)))
        let document = try service.affectedDocument(symbols: ["P"], in: AnalysisContext(snapshot: snapshot))
        #expect(document.tests.map(\.symbol.usr) == ["T"])
        #expect(document.limitations.contains { $0.hasPrefix("header-projection:") })
        #expect(!document.limitations.contains {
            $0.hasPrefix("unindexed-sources:") || $0.hasPrefix("index-staleness:")
        })
        #expect(document.xcodebuildSelection().output.isEmpty)
        #expect(document.xcodebuildSelection().refusal?.contains("Source/index coverage is incomplete") == true)
    }

    @Test("분석 범위를 좁힌 필터가 숨긴 테스트를 모듈 확대만으로 덮었다고 주장하지 않는다", arguments: [false, true])
    func filteredGraphRefusesSelection(pathFilter: Bool) throws {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        if pathFilter { configuration.include = ["Sources/**"] } else { configuration.edgeKinds = [.call] }
        let snapshot = snapshot()
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(snapshot)))
        let context = AnalysisContext(snapshot: snapshot, pathFilter: configuration.pathFilter,
            edgeKinds: configuration.edgeKinds, runtimeFiles: [])
        let document = try service.affectedDocument(symbols: ["P"], in: context)
        let prefix = pathFilter ? "configured-path-filter:" : "configured-edge-kinds:"
        #expect(document.limitations.contains { $0.hasPrefix(prefix) })
        #expect(document.xcodebuildSelection().output.isEmpty)
        #expect(document.xcodebuildSelection().refusal?.contains("Source/index coverage is incomplete") == true)
    }

    @Test("모델 밖 변경과 Swift 변경이 섞이면 부분 테스트 선택을 거부한다")
    func mixedUnmodeledChangesRefuseSelection() throws {
        let outcome = try service(xctestSnapshot()).affected(
            files: ["Sources/P.swift"], format: "xcodebuild", fileSelectionIsDerived: true,
            selectionLimitations: ["unmodeled-changed-files: 1 change(s): Fixtures/expected.json"])
        #expect(outcome.output.isEmpty)
        #expect(!outcome.subjectNotFound)
        #expect(outcome.incompleteAnalysis?.contains("outside the dependency model") == true)
    }

    @Test("모델 밖 변경만 있으면 모든 테스트 실행을 뜻하는 빈 선택자 계약을 유지한다")
    func onlyUnmodeledChangesKeepAllTestsFallback() throws {
        let outcome = try service(xctestSnapshot()).affected(
            format: "xcodebuild", fileSelectionIsDerived: true,
            selectionLimitations: ["unmodeled-changed-files: 1 change(s): Fixtures/expected.json"])
        #expect(outcome.output.isEmpty)
        #expect(!outcome.subjectNotFound)
        #expect(outcome.incompleteAnalysis == nil)
        #expect(outcome.notes.contains { $0.hasPrefix("unmodeled-changed-files:") })
    }

    @Test("생명주기 의존성과 직접 호출 테스트를 모두 선택하고 구문 근거를 구분한다",
          arguments: ["setUp()", "setUpWithError()", "tearDown()", "tearDownWithError()", "setUp"])
    func lifecycleDependencySelectsOwningClass(hook: String) throws {
        var builder = SnapshotBuilder(module: "AppTests", path: "/p/Tests/Checks.swift")
        builder.symbol("P", name: "process()", kind: .function, path: "/p/Sources/P.swift")
        builder.symbol("A", name: "ATests", kind: .classType, attributes: [.unitTest])
        builder.symbol("A.hook", name: hook, kind: .method, line: 2, parent: "A")
        builder.symbol("B", name: "BTests", kind: .classType, line: 3, attributes: [.unitTest])
        builder.symbol("B.test", name: "testDirect()", kind: .method, line: 4,
            parent: "B", attributes: [.unitTest])
        builder.reference(from: "A.hook", to: "P", kind: .call)
        builder.reference(from: "B.test", to: "P", kind: .call)
        builder.symbol("A.test", name: "testOwned()", kind: .method, line: 5,
            parent: "A", attributes: [.unitTest])
        let service = service(provedSnapshot(builder, classes: ["A", "B"], methods: ["A.test", "B.test"]))
        let document = try service.affectedDocument(symbols: ["P"])
        #expect(Set(document.tests.compactMap(\.symbol.usr)) == ["A", "B.test"])
        let owner = try #require(document.tests.first { $0.symbol.usr == "A" })
        #expect(owner.depth == 2)
        #expect(owner.via?.usr == "A.hook")
        #expect(owner.relationship == "automaticRuntime")
        #expect(owner.edges.isEmpty)
        #expect(owner.runtimeEvidence?.first?.origin == .automatic)
        #expect(owner.runtimeEvidence?.first?.id.hasPrefix("xctest-lifecycle:") == true)
        #expect(document.xcodebuildSelection().output
            == "-only-testing:AppTests/ATests\n-only-testing:AppTests/BTests/testDirect\n")
        let impact = try service.impactDocument(symbols: ["P"])
        #expect(Set(impact.tests.compactMap(\.usr)) == ["A", "B.test"])
        let traversal = try service.languageTraversalDocument(symbols: ["P"])
        #expect(Set(traversal.reached.map(\.symbol.usr)) == ["A.hook", "A", "B.test"])
        let traversedOwner = try #require(traversal.reached.first { $0.symbol.usr == "A" })
        #expect(traversedOwner.relationships == ["automaticRuntime"])
        #expect(traversedOwner.evidence == "candidate")
        #expect(traversedOwner.via == "A.hook")
        let bounded = try service.affectedDocument(symbols: ["P"], maxDepth: 1)
        #expect(bounded.truncated.depth)
        #expect(bounded.xcodebuildSelection().output.isEmpty)
        let changed = try service.affectedDocument(symbols: ["A.hook"])
        #expect(changed.tests.map(\.symbol.usr) == ["A"])
    }

    @Test("상속된 생명주기와 테스트는 다른 모듈의 표식 없는 하위 클래스 실행도 포함한다",
          arguments: [false, true])
    func inheritedExecutionIncludesOtherModules(testMethod: Bool) throws {
        var builder = SnapshotBuilder(module: "BaseTests", path: "/p/Tests/Checks.swift")
        builder.symbol("P", kind: .function, path: "/p/Sources/P.swift")
        builder.symbol("Base", kind: .classType, attributes: [.unitTest])
        builder.symbol("Base.run", name: testMethod ? "testInherited()" : "setUp()", kind: .method,
            line: 2, parent: "Base", attributes: testMethod ? [.unitTest] : [])
        builder.symbol("Child", kind: .classType, module: "ChildTests", path: "/p/Tests/Child.swift")
        builder.reference(from: "Child", to: "Base", kind: .inheritance)
        builder.reference(from: "Base.run", to: "P", kind: .call)
        let service = service(builder.build())
        let document = try service.affectedDocument(symbols: ["P"])
        #expect(Set(document.tests.compactMap(\.symbol.usr)) == [testMethod ? "Base.run" : "Base", "Child"])
        #expect(document.xcodebuildSelection().output == "-only-testing:BaseTests\n-only-testing:ChildTests\n")
        #expect(Set(try service.impactDocument(symbols: ["P"]).tests.compactMap(\.usr))
            == Set(document.tests.compactMap(\.symbol.usr)))
    }

}
