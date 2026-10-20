import CartographCore
@testable import CartographSyntax
import CartographTestSupport
import SwiftParser
import SwiftSyntax
import Testing

@Suite("참조 자리 분류")
struct ReferenceBodyScannerTests {
    private func facts(_ source: String, path: String = "/p/Test.swift") -> SourceFileFacts {
        SwiftSyntaxAnalyzer().analyze(source: source, path: path)
    }

    private func location(_ line: Int, _ column: Int, path: String = "/p/Test.swift") -> CartographCore.SourceLocation {
        CartographCore.SourceLocation(path: path, line: line, column: column)
    }

    @Test("함수 본문을 본문 구간으로 기록한다")
    func recordsFunctionBody() throws {
        let ranges = try #require(facts("""
            public func f() {
                let x = 1
            }
            """).bodyRanges)
        #expect(ranges.count == 1)
        #expect(ranges[0].contains(location(2, 5)))
        #expect(!ranges[0].contains(location(1, 13)))
    }

    @Test("접근자 본문과 중첩 블록도 기록한다")
    func recordsAccessorsAndNestedBlocks() throws {
        let ranges = try #require(facts("""
            public var value: Int {
                get { 1 }
                set { _ = newValue }
            }
            public func f() {
                if true {
                    print(1)
                }
            }
            """).bodyRanges)
        #expect(ranges.contains { $0.contains(location(2, 5)) })
        #expect(ranges.contains { $0.contains(location(3, 5)) })
        #expect(ranges.contains { $0.contains(location(6, 9)) })
        // 타입 표기는 본문이 아니다.
        #expect(!ranges.contains { $0.contains(location(1, 20)) })
    }

    @Test("클라이언트로 전개되는 본문은 본문으로 기록하지 않는다")
    func doesNotRecordClientEmittedBodies() throws {
        let ranges = try #require(facts("""
            @inlinable
            public func f() { print(1) }
            @usableFromInline
            func g() { print(2) }
            public func h() { print(3) }
            """).bodyRanges)
        #expect(!ranges.contains { $0.contains(location(2, 22)) })
        #expect(!ranges.contains { $0.contains(location(4, 20)) })
        #expect(ranges.contains { $0.contains(location(5, 22)) })
    }

    @Test("저장 프로퍼티 초기화 식과 기본값 클로저는 본문이 아니다")
    func doesNotRecordInitializerExpressions() throws {
        let ranges = try #require(facts("""
            public var value = { 1 }()
            public func f(completion: () -> Void = {}) {}
            """).bodyRanges)
        // 함수의 빈 본문만 본문이다. 초기화 식과 기본값 클로저는 인터페이스로 남는다.
        #expect(ranges.count == 1)
        #expect(ranges[0].contains(location(2, 44)))
    }

    @Test("구문 분석이 본문 구간을 채운다")
    func analyzerProducesRanges() {
        #expect(facts("public func f() {}").bodyRanges?.isEmpty == false)
    }

    @Test("이미 기록한 본문 안의 중첩 블록·접근자는 따로 기록하지 않는다")
    func doesNotRecordBlocksInsideARecordedBody() throws {
        let ranges = try #require(facts("""
            public var value: Int {
                get { 1 }
                set { _ = newValue }
            }
            public func f() {
                if true {
                    var local: Int { get { 2 } }
                    print(local)
                }
            }
            public func g() { do { print(3) } }
            """).bodyRanges)
        // 바깥 구간이 안쪽 구간을 모두 덮어 판정이 같다. 안쪽까지 남기면 캐시만 커진다.
        #expect(ranges.map(\.start.line) == [1, 5, 11])
        #expect(ranges.map(\.end.line) == [4, 10, 11])
    }

    @Test("중첩 블록을 빼도 본문 판정은 모든 블록을 기록하던 때와 같다")
    func matchesRecordingEveryBlock() {
        let sources = [
            """
            public struct S {
                public var value: Int {
                    get { if true { return 1 } else { return 2 } }
                    set { _ = newValue }
                }
                public subscript(i: Int) -> Int { get { i } set { _ = newValue } }
                public init() { for _ in 0..<1 { while false {} } }
                public func f(_ x: Int = { 1 }()) -> Int {
                    func local() -> Int { guard x > 0 else { return 0 }; return x }
                    let closure = { (y: Int) -> Int in if y > 0 { return y }; return 0 }
                    return local() + closure(x)
                }
            }
            """,
            """
            @inlinable public func emitted() { if true { print(1) } }
            public func outer() {
                @inlinable func inner() { print(2) }
                @usableFromInline var computed: Int { get { 3 } }
                inner(); print(computed)
            }
            public func f() {}{}
            """,
            // 괄호가 빠진 소스도 같은 판정이어야 한다. 마지막 소스의 `if` 본문은 토큰이 모두 빠진 블록이라
            // 바깥 본문의 끝(`x`) 뒤 공백 너머에 폭 없이 자리 잡는다(포함 확인 없이 건너뛰면 여기서 틀린다).
            "func f() { if x { print(1) \nfunc g() { do {",
            "var v: Int { get { 1 } set",
            "func f() { if x ",
        ]
        for source in sources {
            let mismatches = bodyClassificationMismatches(source)
            #expect(Array(mismatches.prefix(3)) == [], "source: \(source.prefix(40))")
        }
    }

    /// 모든 (줄, 열) 위치에서 이 스캐너와 모든 블록을 기록하는 기준의 본문 판정이 다른 곳.
    private func bodyClassificationMismatches(_ source: String) -> [String] {
        let path = "/p/Test.swift"
        let scanned = facts(source, path: path)
        let oracle = SourceFileFacts(
            path: path, declarations: [], bodyRanges: EveryBodyBlockOracle.ranges(source, path)
        )
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let references = (1...(lines.count + 1)).flatMap { line in
            (1...((lines.map(\.utf8.count).max() ?? 0) + 2)).map { column in
                IndexedReference(sourceUSR: "s", targetUSR: "t", kind: .reference,
                    location: location(line, column, path: path))
            }
        }
        let actual = SnapshotEnricher.markingReferencePositions(references, with: [path: scanned])
        let expected = SnapshotEnricher.markingReferencePositions(references, with: [path: oracle])
        return zip(actual, expected).compactMap { pair in
            pair.0 == pair.1 ? nil : "\(pair.0.location.map(\.description) ?? "-"): \(pair.0.position)"
        }
    }
}

/// 중첩 블록까지 모두 기록하던 방식. 줄인 구간이 같은 판정을 내는지 대조하는 기준이다.
///
/// 클라이언트 전개 속성 목록과 조상 검사는 제품 코드와 같은 규칙을 따로 적는다. 같은 함수를 부르면
/// 기준이 대상과 함께 틀려도 통과한다.
private final class EveryBodyBlockOracle: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private var ranges: [CartographSyntax.SourceRange] = []

    static func ranges(_ source: String, _ path: String) -> [CartographSyntax.SourceRange] {
        let tree = Parser.parse(source: source)
        let oracle = EveryBodyBlockOracle(path: path, converter: SourceLocationConverter(fileName: path, tree: tree))
        oracle.walk(tree)
        return oracle.ranges
    }

    private init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }

    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }

    private func record(_ node: some SyntaxProtocol) {
        let emitted: Set<String> = ["inlinable", "usableFromInline", "_transparent", "_alwaysEmitIntoClient"]
        var current: Syntax? = Syntax(node)
        while let syntax = current {
            let names: [String] = syntax.asProtocol(WithAttributesSyntax.self)?.attributes.compactMap { element in
                guard case let .attribute(attribute) = element else { return nil }
                return attribute.attributeName.trimmedDescription
            } ?? []
            if names.contains(where: { emitted.contains($0) }) { return }
            current = syntax.parent
        }
        ranges.append(CartographSyntax.SourceRange(start: location(node.positionAfterSkippingLeadingTrivia),
            end: location(node.endPositionBeforeTrailingTrivia)))
    }

    private func location(_ position: AbsolutePosition) -> CartographCore.SourceLocation {
        let point = converter.location(for: position)
        return CartographCore.SourceLocation(path: path, line: point.line, column: point.column)
    }
}

@Suite("참조 자리 보강")
struct ReferencePositionEnrichmentTests {
    private func reference(
        from source: String, to target: String, line: Int, column: Int,
        path: String = "/p/Test.swift"
    ) -> IndexedReference {
        IndexedReference(
            sourceUSR: source, targetUSR: target, kind: .reference,
            location: CartographCore.SourceLocation(path: path, line: line, column: column)
        )
    }

    @Test("본문 안의 참조는 body, 인터페이스의 참조는 signature 로 표시한다")
    func marksBodyAndSignature() {
        let fileFacts = SwiftSyntaxAnalyzer().analyze(source: """
            public struct Holder {
                public var api: Api
                public func f() {
                    use(api)
                }
            }
            """, path: "/p/Test.swift")
        let facts = ["/p/Test.swift": fileFacts]
        let references = [
            reference(from: "Holder", to: "Api", line: 2, column: 20),
            reference(from: "Holder.f", to: "use", line: 4, column: 9),
        ]
        let marked = SnapshotEnricher.markingReferencePositions(references, with: facts)
        #expect(marked[0].position == .signature)
        #expect(marked[1].position == .body)
    }

    @Test("구문 사실이 없는 파일의 참조는 unknown 으로 남긴다")
    func leavesUnknownWithoutFacts() {
        let references = [reference(from: "A", to: "B", line: 1, column: 1)]
        #expect(SnapshotEnricher.markingReferencePositions(references, with: [:]) == references)
    }

    @Test("본문 구간을 수집하지 않은 사실은 참조를 바꾸지 않는다")
    func leavesUnknownWithoutBodyRanges() {
        let facts = ["/p/Test.swift": SourceFileFacts(path: "/p/Test.swift", declarations: [])]
        let references = [reference(from: "A", to: "B", line: 1, column: 1)]
        #expect(SnapshotEnricher.markingReferencePositions(references, with: facts) == references)
    }

    @Test("다른 파일의 본문이 알려져 있어도 미수집 구간은 보존하고 빈 구간만 signature로 분류한다")
    func preservesUnknownBesideKnownEmptyRanges() {
        let unknown = reference(from: "A", to: "B", line: 1, column: 1, path: "/p/Unknown.swift")
            .withPosition(.body)
        let empty = reference(from: "C", to: "D", line: 1, column: 1, path: "/p/Empty.swift")
            .withPosition(.body)
        let facts = [
            "/p/Unknown.swift": SourceFileFacts(path: "/p/Unknown.swift", declarations: []),
            "/p/Empty.swift": SourceFileFacts(path: "/p/Empty.swift", declarations: [], bodyRanges: []),
        ]
        let result = SnapshotEnricher.markingReferencePositions([unknown, empty], with: facts)
        #expect(result[0] == unknown)
        #expect(result[1].position == .signature)
    }

    @Test("보강이 기존 자리 표시를 덮어쓰지 않는다")
    func enrichmentKeepsExplicitPositionWhenFactsAbsent() {
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType)
        builder.symbol("B", kind: .structType)
        builder.reference(from: "A", to: "B", kind: .reference, position: .body)
        let enriched = SnapshotEnricher.enrich(builder.build(), with: [:])
        #expect(enriched.references[0].position == .body)
    }
}
