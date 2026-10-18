import CartographAnalysis
import CartographCore
import Testing

@Suite("보존 표식과 XCTest 신원 분리")
struct XCTestIdentityFactsTests {
    private let sdk = "c:objc(cs)XCTestCase"

    @Test("SDK 정점 없이 직접·간접 상속과 실제 비동기 메서드 신원을 확인한다")
    func compilerAncestry() {
        let base = symbol("Base", kind: .classType)
        let child = symbol("Child", kind: .classType)
        let method = symbol("c:@M@Tests@objc(cs)Child(im)testAsyncWithCompletionHandler:",
                            name: "testAsync()", owner: "Child", bit: true)
        let snapshot = IndexSnapshot(symbols: [base, child, method], references: [
            inherits("Base", sdk), inherits("Child", "Base"),
        ])
        let facts = XCTestIdentityFacts(snapshot: snapshot)
        #expect(facts.classUSRs == ["Base", "Child"])
        #expect(facts.methodUSRs == [method.usr])
        #expect(facts.uncertainUSRs.isEmpty)
        #expect(snapshot.symbolsByUSR()[sdk] == nil)
    }

    @Test("옛 표식과 비트 부재는 확인된 소유자 안에서도 메서드 증명으로 승격하지 않는다",
          arguments: [nil, false, true] as [Bool?])
    func provenance(bit: Bool?) {
        let snapshot = IndexSnapshot(symbols: [
            symbol("Case", kind: .classType),
            symbol("method", owner: "Case", bit: bit, attributes: [.unitTest]),
        ], references: [inherits("Case", sdk, origin: .unknown)])
        let facts = XCTestIdentityFacts(snapshot: snapshot)
        #expect(facts.classUSRs == ["Case"])
        #expect(facts.methodUSRs == (bit == true ? ["method"] : []))
        #expect(facts.uncertainUSRs == (bit == true ? [] : ["method"]))
    }

    @Test("프로덕션 test 이름과 컴파일러 표식만으로 XCTest 프레임워크를 만들지 않는다")
    func unprovedFramework() {
        let snapshot = IndexSnapshot(symbols: [
            symbol("Runner", kind: .classType),
            symbol("ordinary", owner: "Runner", bit: false, attributes: [.unitTest]),
            symbol("marked", owner: "Runner", bit: true),
            symbol("MissingBaseCase", kind: .classType, bit: true),
            symbol("externalOwnerMethod", owner: "MissingBaseCase", bit: true),
        ], references: [inherits("MissingBaseCase", "UnavailableCustomTestBase")])
        let facts = XCTestIdentityFacts(snapshot: snapshot)
        #expect(facts.classUSRs.isEmpty && facts.methodUSRs.isEmpty)
        #expect(facts.uncertainUSRs == ["ordinary", "marked", "MissingBaseCase", "externalOwnerMethod"])
    }

    @Test("동명이인 SDK 타입과 구문·추론 관계는 정확한 컴파일러 상속을 대신하지 않는다")
    func identityAndOrigin() {
        for origin in [ReferenceOrigin.syntax, .inferred, .graph] {
            let facts = XCTestIdentityFacts(snapshot: IndexSnapshot(
                symbols: [symbol("Case", kind: .classType, bit: true)],
                references: [inherits("Case", sdk, origin: origin)]))
            #expect(facts.classUSRs.isEmpty)
            #expect(facts.uncertainUSRs == ["Case"])
        }
        let facts = XCTestIdentityFacts(snapshot: IndexSnapshot(symbols: [
            symbol("Case", kind: .classType, bit: true),
            symbol("user:XCTestCase", name: "XCTestCase", kind: .classType),
        ], references: [inherits("Case", "user:XCTestCase")]))
        #expect(facts.classUSRs.isEmpty)
        #expect(facts.uncertainUSRs == ["Case"])
    }

    @Test("형태나 소유자가 불명확한 선언과 Swift Testing은 XCTest 메서드로 바꾸지 않는다")
    func methodBoundaries() {
        let snapshot = IndexSnapshot(symbols: [
            symbol("Case", kind: .classType),
            symbol("argument", name: "testValue(_:)", owner: "Case", bit: true),
            symbol("helper", name: "helper()", owner: "Case", bit: true),
            symbol("generic", owner: "Case", bit: true, attributes: [.generic]),
            symbol("ownerless", bit: true),
            symbol("function", kind: .function, owner: "Case", bit: true),
            symbol("modern", name: "modern()", kind: .function, bit: false, attributes: [.testFunction]),
            symbol("suite", name: "Suite", kind: .structType, attributes: [.testSuite]),
        ], references: [inherits("Case", sdk)])
        let facts = XCTestIdentityFacts(snapshot: snapshot)
        #expect(facts.methodUSRs.isEmpty)
        #expect(facts.uncertainUSRs == ["argument", "helper", "generic", "ownerless", "function"])
        #expect(facts.classUSRs == ["Case"])
    }

    @Test("참조 순서·중복과 순환이 결과를 바꾸지 않으며 외부 선언을 실행 대상으로 내지 않는다")
    func deterministicClosure() {
        let snapshot = IndexSnapshot(symbols: [
            symbol("Base", kind: .classType),
            symbol("Child", kind: .classType),
            symbol("External", kind: .classType, external: true),
            symbol("CycleA", kind: .classType), symbol("CycleB", kind: .classType),
        ], references: [
            inherits("Base", sdk), inherits("Child", "Base"), inherits("Base", "Child"),
            inherits("External", sdk), inherits("Child", "External"),
            inherits("CycleA", "CycleB"), inherits("CycleB", "CycleA"),
        ])
        let facts = XCTestIdentityFacts(snapshot: snapshot)
        var reversed = snapshot
        reversed.symbols.reverse()
        reversed.references = Array(snapshot.references.reversed()) + snapshot.references
        #expect(facts == XCTestIdentityFacts(snapshot: reversed))
        #expect(facts.classUSRs == ["Base", "Child"])
        #expect(facts.methodUSRs.isEmpty && facts.uncertainUSRs.isEmpty)
    }

    @Test("깊은 상속 사슬을 재귀와 시작점별 전수 탐색 없이 처리한다")
    func deepHierarchy() {
        let count = 10_000
        let snapshot = IndexSnapshot(
            symbols: (0..<count).map { symbol("Case\($0)", kind: .classType) },
            references: (0..<count).map { inherits("Case\($0)", $0 == 0 ? sdk : "Case\($0 - 1)") })
        let facts = XCTestIdentityFacts(snapshot: snapshot)
        #expect(facts.classUSRs.count == count)
        #expect(facts.classUSRs.contains("Case9999"))
    }

    private func symbol(
        _ usr: String, name: String = "testValue()", kind: SymbolKind = .method,
        owner: String? = nil, bit: Bool? = nil, attributes: Set<SymbolAttribute> = [],
        external: Bool = false
    ) -> IndexedSymbol {
        IndexedSymbol(usr: usr, name: name, kind: kind, module: "Tests",
                      location: .init(path: "/p/Tests.swift", line: 1, column: 1), parentUSR: owner,
                      isExternal: external, attributes: attributes, compilerUnitTest: bit)
    }

    private func inherits(
        _ source: String, _ target: String, origin: ReferenceOrigin = .compiler
    ) -> IndexedReference {
        IndexedReference(sourceUSR: source, targetUSR: target, kind: .inheritance, origin: origin)
    }
}
