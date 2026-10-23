import CartographAnalysis
import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("C-P1-6 테스트 신원과 dispatch 후보")
struct TestClassificationFeedbackTests {
    private func service(_ snapshot: IndexSnapshot) -> CartographService {
        CartographService(configuration: .init(projectPath: "/p"), environment: .init(
            fileSystem: InMemoryFileSystem(files: Dictionary(uniqueKeysWithValues: snapshot.filePaths.map { ($0, "") })),
            indexProviderOverride: StaticIndexProvider(snapshot), usesSyntaxCache: false))
    }

    private func snapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder(module: "Production", path: "/p/Sources/App.swift")
        builder.symbol("work", name: "work()", kind: .function)
        builder.symbol("debug", name: "DebugPanel", kind: .classType)
        for index in 1...5 {
            builder.symbol("debug.\(index)", name: "test_debug\(index)()", kind: .method,
                line: index + 2, parent: "debug", attributes: [.unitTest])
            builder.reference(from: "debug.\(index)", to: "work", kind: .call)
        }
        builder.symbol("ordinary", name: "test_named_only()", kind: .function)
        builder.reference(from: "ordinary", to: "work", kind: .call)
        builder.symbol("actual", name: "ActualTests", kind: .classType, module: "AppTests", path: "/p/Tests/Actual.swift")
        builder.symbol("actual.test", name: "testWork()", kind: .method, module: "AppTests",
            path: "/p/Tests/Actual.swift", parent: "actual", attributes: [.unitTest])
        builder.reference(from: "actual.test", to: "work", kind: .call)
        builder.symbol("swiftTest", name: "workIsAvailable()", kind: .function, module: "AppTests",
            path: "/p/Tests/Actual.swift", line: 10, attributes: [.testFunction])
        builder.reference(from: "swiftTest", to: "work", kind: .call)
        var result = builder.build()
        result.references.append(.init(sourceUSR: "actual", targetUSR: "c:objc(cs)XCTestCase",
            kind: .inheritance, origin: .compiler))
        for index in result.symbols.indices where result.symbols[index].attributes.contains(.unitTest) {
            result.symbols[index].compilerUnitTest = true
        }
        return result
    }

    @Test("실제 컴파일러 unitTest 비트가 있어도 앱 debug 다섯 개를 확인한 테스트와 섞지 않는다")
    func separatesDebugMarkersFromFrameworkEvidence() throws {
        let input = snapshot()
        let service = service(input)
        let result = try service.affectedDocument(symbols: ["work"])
        #expect(Set(result.tests.compactMap(\.symbol.usr)) == ["actual.test", "swiftTest"])
        #expect(result.summary.testCount == 2)
        #expect(Set(result.uncertainTestCandidates?.compactMap(\.symbol.usr) ?? []) == Set((1...5).map { "debug.\($0)" }))
        #expect(result.uncertainTestCandidates?.allSatisfy { $0.depth == 1 && $0.via?.usr == "work" && $0.symbol.location != nil } == true)
        #expect(result.limitations.contains { $0.hasPrefix("unverified-test-markers: 5") })
        #expect(result.xcodebuildSelection().output.isEmpty)
        #expect(result.xcodebuildSelection().refusal != nil)
        let impact = try service.impactDocument(symbols: ["work"])
        #expect(Set(impact.tests.compactMap(\.usr)) == ["actual.test", "swiftTest"])
        #expect(impact.affected.contains { $0.symbol.usr == "ordinary" })
        #expect(impact.affected.filter { $0.symbol.usr?.hasPrefix("debug.") == true }.count == 5)
        let roundTrip = try JSONDecoder().decode(AffectedDocument.self, from: JSONEncoder().encode(result))
        #expect(roundTrip == result)
        let bounded = try service.affectedDocument(symbols: ["work"], limit: 1)
        #expect(bounded.uncertainTestCandidates?.count == 1)
        #expect(bounded.truncated.sections.contains("uncertainTestCandidates"))
        #expect(bounded.limitations.contains { $0.hasPrefix("unverified-test-markers: 5") })
    }

    @Test("이름이 테스트인 앱 클래스의 setUp을 XCTest 실행으로 발명하지 않는다")
    func appLifecycleHasNoImplicitClassEdge() throws {
        var input = snapshot()
        input.symbols.append(.init(usr: "debug.setup", name: "setUp()", kind: .method,
            module: "Production", location: .init(path: "/p/Sources/App.swift", line: 20, column: 1), parentUSR: "debug"))
        input.references.append(.init(sourceUSR: "debug.setup", targetUSR: "work", kind: .call))
        let context = AnalysisContext(snapshot: input)
        #expect(!context.impactLifecycle().testClasses.contains("debug"))
        #expect(!context.impactLifecycle().dependencies.contains { $0.source == "debug" })
        let result = try service(input).languageTraversalDocument(symbols: ["work"], in: context)
        #expect(result.reached.contains { $0.symbol.usr == "debug.setup" })
        #expect(!result.reached.contains { $0.symbol.usr == "debug" })
    }

    @Test("구문만의 XCTest 상속은 실행 계약을 만들지 않는다")
    func syntaxOnlyAncestryDoesNotProveLifecycle() {
        var input = snapshot()
        input.references.append(.init(sourceUSR: "debug", targetUSR: "actual", kind: .inheritance, origin: .syntax))
        let context = AnalysisContext(snapshot: input)
        #expect(!context.impactLifecycle().testClasses.contains("debug"))
        #expect(!context.impactTestIdentity().confirmed.contains("debug"))
    }

    @Test("형제 구현 수신자를 증명하지 못한 일곱 호출자는 삭제하지 않고 dispatch 한계를 남긴다")
    func retainsDispatchCandidatesWithUnknownReceiver() throws {
        var builder = SnapshotBuilder(module: "PackageTests", path: "/p/Tests/Dispatch.swift")
        builder.symbol("P", kind: .protocolType)
        builder.symbol("P.run", name: "run()", kind: .method, parent: "P")
        builder.symbol("A", kind: .classType)
        builder.symbol("A.run", name: "run()", kind: .method, parent: "A")
        builder.symbol("B", kind: .classType)
        builder.symbol("B.run", name: "run()", kind: .method, parent: "B")
        builder.reference(from: "A.run", to: "P.run", kind: .overrides)
        builder.reference(from: "B.run", to: "P.run", kind: .overrides)
        for index in 1...7 {
            builder.symbol("test\(index)", kind: .function, line: index, attributes: [.testFunction])
            builder.reference(from: "test\(index)", to: "P.run", kind: .call)
        }
        builder.symbol("directB", kind: .function, attributes: [.testFunction])
        builder.reference(from: "directB", to: "B.run", kind: .call)
        let result = try service(builder.build()).affectedDocument(symbols: ["A.run"])
        #expect(Set(result.tests.compactMap(\.symbol.usr)) == Set((1...7).map { "test\($0)" }))
        #expect(result.tests.allSatisfy { $0.relationship == "dispatchCaller" && $0.dispatchContract?.usr == "P.run" })
        #expect(result.limitations.contains { $0.hasPrefix("dispatch-receiver-uncertainty: 7") })
    }
}
