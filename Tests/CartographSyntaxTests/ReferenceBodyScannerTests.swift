import CartographCore
@testable import CartographSyntax
import CartographTestSupport
import Testing

@Suite("참조 자리 분류")
struct ReferenceBodyScannerTests {
    private func facts(_ source: String, path: String = "/p/Test.swift") -> SourceFileFacts {
        SwiftSyntaxAnalyzer().analyze(source: source, path: path)
    }

    private func location(_ line: Int, _ column: Int, path: String = "/p/Test.swift") -> CartographCore.SourceLocation {
        SourceLocation(path: path, line: line, column: column)
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
