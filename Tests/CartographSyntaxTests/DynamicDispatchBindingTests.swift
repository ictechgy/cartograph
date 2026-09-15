import CartographCore
import CartographSyntax
import Foundation
import Testing

@Suite("컴파일러 선언과 일치하는 동적 보존 근거")
struct DynamicDispatchBindingTests {
    private let path = "/p/Dispatch.swift"

    @Test("일반 익스텐션 메서드의 인덱스 dynamic 역할은 보존 제어자가 아니다")
    func removesIndexDispatchRoleForExactOrdinaryMethod() {
        let source = "struct Box {}\nextension Box {\n    func idle() {}\n}"
        let result = enrich(source, name: "idle()", line: 3, column: 10)
        #expect(!result.attributes.contains(.dynamicDispatch))
    }

    @Test("앞줄의 속성이 있어도 실제 식별자 위치로 일반 메서드를 구분한다")
    func bindsTheNameAfterAttributes() {
        let source = "struct Box {\n    @discardableResult\n    func idle() -> Int { 1 }\n}"
        #expect(!enrich(source, name: "idle()", line: 3, column: 10).attributes.contains(.dynamicDispatch))
    }

    @Test("알 수 없는 선언 속성은 정확히 일치해도 인덱스 dynamic을 보존한다")
    func preservesIndexDispatchRoleForUnknownDeclarationAttribute() {
        let source = "@CustomDeclarationMacro\nfunc idle() {}"
        let facts = SwiftSyntaxAnalyzer().analyze(source: source, path: path)
        #expect(facts.declaration(named: "idle")?.hasUnresolvedAttributes == true)
        #expect(enrich(source, name: "idle()", line: 2, column: 6).attributes.contains(.dynamicDispatch))
    }

    @Test("알 수 없는 부모 멤버 속성은 자식의 인덱스 dynamic을 보존한다")
    func preservesIndexDispatchRoleForUnknownMemberAttributeMacro() {
        let source = "@MemberAttributeMacro\nstruct Box {\n    func idle() {}\n}"
        let facts = SwiftSyntaxAnalyzer().analyze(source: source, path: path)
        #expect(facts.declaration(named: "idle")?.hasUnresolvedAttributes == true)
        #expect(enrich(source, name: "idle()", line: 3, column: 10).attributes.contains(.dynamicDispatch))
    }

    @Test("컴파일러 예약 속성은 정확한 일반 메서드의 인덱스 dynamic을 정규화한다")
    func normalizesIndexDispatchRoleWithKnownCompilerAttributes() {
        let source = "@available(macOS 14, *)\n@discardableResult\nfunc idle() -> Int { 1 }"
        let facts = SwiftSyntaxAnalyzer().analyze(source: source, path: path)
        #expect(facts.declaration(named: "idle")?.hasUnresolvedAttributes == false)
        #expect(!enrich(source, name: "idle()", line: 3, column: 6).attributes.contains(.dynamicDispatch))
    }

    @Test("수식 속성·프로퍼티 래퍼·전역 액터는 인덱스 dynamic을 보수적으로 보존한다")
    func preservesIndexDispatchRoleForQualifiedWrapperAndActorAttributes() {
        let cases: [(source: String, name: String, kind: SymbolKind, line: Int, column: Int)] = [
            ("@Feature.MemberMacro\nfunc qualified() {}", "qualified()", .method, 2, 6),
            ("@PropertyWrapper\nvar wrapped = 0", "wrapped", .property, 2, 5),
            ("@SomeGlobalActor\nfunc actorBound() {}", "actorBound()", .method, 2, 6),
        ]
        for candidate in cases {
            let facts = SwiftSyntaxAnalyzer().analyze(source: candidate.source, path: path)
            #expect(facts.declaration(named: GraphNode.baseName(ofIndexName: candidate.name))?
                .hasUnresolvedAttributes == true)
            #expect(enrich(
                candidate.source, name: candidate.name, kind: candidate.kind,
                line: candidate.line, column: candidate.column
            ).attributes.contains(.dynamicDispatch))
        }
    }

    @Test("조건부 속성 블록은 조건이 알려지지 않아 인덱스 dynamic을 보존한다")
    func preservesIndexDispatchRoleForConditionalAttributeBlock() {
        let source = "#if DEBUG\n@discardableResult\n#endif\nfunc conditional() {}"
        let facts = SwiftSyntaxAnalyzer().analyze(source: source, path: path)
        #expect(facts.declaration(named: "conditional")?.hasUnresolvedAttributes == true)
        #expect(enrich(source, name: "conditional()", line: 4, column: 6)
            .attributes.contains(.dynamicDispatch))
    }

    @Test("한 줄의 동명 오버로드는 실제 이름 열로 dynamic 제어자를 구분한다")
    func distinguishesSameLineOverloads() {
        let source = "class Box { dynamic func pick() {} ; func pick(_ value: Int) {} }"
        let first = source.range(of: "pick")!.lowerBound
        let last = source.range(of: "pick", options: .backwards)!.lowerBound
        #expect(enrich(source, name: "pick()", line: 1,
            column: source[..<first].utf8.count + 1).attributes.contains(.dynamicDispatch))
        #expect(!enrich(source, name: "pick(_:)", line: 1,
            column: source[..<last].utf8.count + 1).attributes.contains(.dynamicDispatch))
    }

    @Test("여러 변수 바인딩은 각각의 식별자 위치를 사용한다")
    func bindsIndividualVariableNames() {
        let source = "class Box { var first = 0, second = 0 }"
        let start = source.range(of: "second")!.lowerBound
        #expect(!enrich(source, name: "second", kind: .property, line: 1,
            column: source[..<start].utf8.count + 1).attributes.contains(.dynamicDispatch))
    }

    @Test("다른 줄이나 다른 파일에서 이름만 일치하면 인덱스 보존을 좁히지 않는다")
    func keepsFallbackEvidenceWhenLocationDoesNotMatch() {
        let source = "func idle() {}"
        #expect(enrich(source, name: "idle()", line: 99, column: 6).attributes.contains(.dynamicDispatch))
        let facts = SwiftSyntaxAnalyzer().analyze(source: source, path: "/other/Dispatch.swift")
        #expect(enrich(facts: facts, name: "idle()", line: 1, column: 6).attributes.contains(.dynamicDispatch))
    }

    @Test("위치가 없는 예전 구문 자료와 중복된 동일 위치는 보수적으로 유지한다")
    func preservesLegacyAndAmbiguousEvidence() {
        let legacy = SourceFileFacts(path: path, declarations: [
            DeclarationFacts(name: "idle", line: 1, accessibility: .internalLevel, attributes: [])
        ])
        #expect(legacy.declarations.first?.hasUnresolvedAttributes == nil)
        #expect(enrich(facts: legacy, name: "idle()", line: 1, column: 6).attributes.contains(.dynamicDispatch))
        let legacyExact = SourceFileFacts(path: path, declarations: [
            DeclarationFacts(
                name: "idle", line: 1, accessibility: .internalLevel, attributes: [],
                nameLocation: SourceLocation(path: path, line: 1, column: 6)
            )
        ])
        #expect(enrich(facts: legacyExact, name: "idle()", line: 1, column: 6)
            .attributes.contains(.dynamicDispatch))
        let analyzed = SwiftSyntaxAnalyzer().analyze(source: "func idle() {}", path: path)
        #expect(analyzed.declarations.first?.hasUnresolvedAttributes == false)
        let duplicate = SourceFileFacts(path: path, declarations: analyzed.declarations + analyzed.declarations)
        #expect(enrich(facts: duplicate, name: "idle()", line: 1, column: 6).attributes.contains(.dynamicDispatch))
    }

    @Test("명시적 dynamic과 런타임 치환 근거는 계속 남긴다")
    func preservesExplicitRuntimeModifiers() {
        let source = "class Box {\n    dynamic func live() {}\n}"
        #expect(enrich(source, name: "live()", line: 2, column: 18).attributes.contains(.dynamicDispatch))
    }

    @Test("동일한 이름과 위치에 여러 인덱스 USR이 남으면 보존을 좁히지 않는다")
    func preservesConflictingIndexedDeclarations() {
        let location = SourceLocation(path: path, line: 1, column: 6)
        let symbols = ["old", "new"].map {
            IndexedSymbol(usr: $0, name: "idle()", kind: .function, module: "App",
                location: location, attributes: [.dynamicDispatch])
        }
        let facts = SwiftSyntaxAnalyzer().analyze(source: "func idle() {}", path: path)
        let result = SnapshotEnricher.enrich(IndexSnapshot(symbols: symbols), with: [path: facts])
        #expect(result.symbols.allSatisfy { $0.attributes.contains(.dynamicDispatch) })
    }

    @Test("식별자 앞의 유니코드와 탭도 UTF8 열로 대조한다")
    func usesPhysicalUTF8Columns() {
        let source = "struct 이름 {\tfunc idle() {} }"
        let position = source.range(of: "idle")!.lowerBound
        #expect(!enrich(source, name: "idle()", line: 1,
            column: source[..<position].utf8.count + 1).attributes.contains(.dynamicDispatch))
    }

    private func enrich(
        _ source: String, name: String, kind: SymbolKind = .method, line: Int, column: Int
    ) -> IndexedSymbol {
        enrich(facts: SwiftSyntaxAnalyzer().analyze(source: source, path: path),
            name: name, kind: kind, line: line, column: column)
    }

    private func enrich(
        facts: SourceFileFacts, name: String, kind: SymbolKind = .method, line: Int, column: Int
    ) -> IndexedSymbol {
        let symbol = IndexedSymbol(usr: "target", name: name, kind: kind, module: "App",
            location: SourceLocation(path: path, line: line, column: column), attributes: [.dynamicDispatch])
        return SnapshotEnricher.enrich(IndexSnapshot(symbols: [symbol]), with: [path: facts]).symbols[0]
    }
}
