import CartographCore
@testable import CartographSyntax
import Testing

@Suite("파라미터 사용 구문 스캔")
struct ParameterUsageScannerTests {
    private func analyze(_ source: String) -> [ParameterUsageFacts] {
        SwiftSyntaxAnalyzer().analyze(source: source, path: "/p/Test.swift").parameterUsages ?? []
    }

    private func usage(_ facts: [ParameterUsageFacts], named name: String, line: Int? = nil) -> ParameterUsageFacts? {
        facts.first { $0.name == name && (line == nil || $0.location.line == line) }
    }

    @Test("본문에서 읽힌 파라미터는 사용됨으로 표시한다")
    func usedParameterIsMarkedUsed() {
        let facts = analyze("""
            func decode(_ data: Data) -> Int {
                return data.count
            }
            """)
        #expect(usage(facts, named: "data")?.isUsedInBody == true)
    }

    @Test("본문에 한 번도 나오지 않는 파라미터는 미사용으로 표시한다")
    func unusedParameterIsMarkedUnused() {
        let facts = analyze("""
            func greet(name: String) -> String {
                return "hello"
            }
            """)
        #expect(usage(facts, named: "name")?.isUsedInBody == false)
    }

    @Test("이름 없는 파라미터는 기록하지 않는다")
    func anonymousParametersAreNotRecorded() {
        let facts = analyze("""
            func f(_ : Int, _ named: Int) { _ = named }
            """)
        #expect(facts.map(\.name) == ["named"])
    }

    @Test("외부 라벨과 다른 내부 이름을 쓴다")
    func usesInternalName() {
        let facts = analyze("""
            func move(from source: Int, to target: Int) { print(target) }
            """)
        let source = usage(facts, named: "source")
        #expect(source?.isUsedInBody == false)
        #expect(usage(facts, named: "target")?.isUsedInBody == true)
        // 인덱스는 내부 이름 토큰의 위치를 기록한다. `source` 는 16번째 열이다.
        #expect(source?.location.column == 16)
    }

    @Test("다른 파라미터의 기본값에서의 참조도 사용으로 센다")
    func defaultValueReferenceCounts() {
        let facts = analyze("""
            func f(a: Int, b: Int = a) {}
            """)
        #expect(usage(facts, named: "a")?.isUsedInBody == true)
        #expect(usage(facts, named: "b")?.isUsedInBody == false)
    }

    @Test("본문 없는 프로토콜 요구사항은 기록하지 않는다")
    func protocolRequirementsHaveNoFacts() {
        let facts = analyze("""
            protocol P {
                func f(x: Int)
                init(y: Int)
            }
            """)
        #expect(facts.isEmpty)
    }

    @Test("중첩 클로저가 바깥 파라미터를 캡처하면 사용으로 센다")
    func closureCaptureMarksOuterParameterUsed() {
        let facts = analyze("""
            func f(x: Int) -> () -> Int {
                return { x + 1 }
            }
            """)
        #expect(usage(facts, named: "x")?.isUsedInBody == true)
    }

    @Test("같은 이름의 안쪽 파라미터가 바깥 것을 가리면 바깥은 미사용이다")
    func shadowedOuterParameterStaysUnused() {
        let facts = analyze("""
            func f(x: Int) -> (Int) -> Int {
                return { (x: Int) in x * 2 }
            }
            """)
        let outer = facts.filter { $0.name == "x" }
        #expect(outer.count == 2)
        // 먼저 선언된 바깥 파라미터는 미사용, 클로저의 파라미터는 사용.
        #expect(outer[0].isUsedInBody == false)
        #expect(outer[1].isUsedInBody == true)
    }

    @Test("중첩 함수의 파라미터는 독립 스코프로 판정한다")
    func nestedFunctionHasOwnScope() {
        let facts = analyze("""
            func outer(x: Int) {
                func inner(y: Int) { print(y) }
                inner(y: 0)
            }
            """)
        #expect(usage(facts, named: "x")?.isUsedInBody == false)
        #expect(usage(facts, named: "y")?.isUsedInBody == true)
    }

    @Test("클로저 캡처 목록의 이름은 바깥 파라미터의 사용이다")
    func captureListMarksOuterParameter() {
        let facts = analyze("""
            func f(x: Int) -> () -> Int {
                let bound = { [x] in x }
                return bound
            }
            """)
        #expect(usage(facts, named: "x")?.isUsedInBody == true)
    }

    @Test("캡처 초기화 식은 바깥 스코프에서 평가된다")
    func captureInitializerReadsOuterScope() {
        let facts = analyze("""
            func f(x: Int) -> () -> Int {
                let bound = { [y = x + 1] in y }
                return bound
            }
            """)
        #expect(usage(facts, named: "x")?.isUsedInBody == true)
    }

    @Test("멤버 접근의 이름은 파라미터 사용이 아니다")
    func memberAccessNameIsNotAParameterUse() {
        let facts = analyze("""
            struct Box { var count: Int }
            func f(box: Box, count: Int) -> Int {
                return box.count
            }
            """)
        #expect(usage(facts, named: "box")?.isUsedInBody == true)
        #expect(usage(facts, named: "count")?.isUsedInBody == false)
    }

    @Test("이니셜라이저와 서브스크립트의 파라미터도 판정한다")
    func initializerAndSubscriptParameters() {
        let facts = analyze("""
            struct S {
                init(value: Int, unused: Int) { _ = value }
                subscript(index: Int, other: Int) -> Int { index }
            }
            """)
        #expect(usage(facts, named: "value")?.isUsedInBody == true)
        #expect(usage(facts, named: "unused")?.isUsedInBody == false)
        #expect(usage(facts, named: "index")?.isUsedInBody == true)
        #expect(usage(facts, named: "other")?.isUsedInBody == false)
    }

    @Test("inout 파라미터에의 대입도 사용이다")
    func inoutWriteCountsAsUse() {
        let facts = analyze("""
            func bump(_ value: inout Int) {
                value += 1
            }
            """)
        #expect(usage(facts, named: "value")?.isUsedInBody == true)
    }

    @Test("백틱 이름은 벗겨서 비교한다")
    func backtickNamesAreUnescaped() {
        let facts = analyze("""
            func f(`repeat`: Int) -> Int {
                return `repeat`
            }
            """)
        #expect(usage(facts, named: "repeat")?.isUsedInBody == true)
    }

    @Test("문자열 보간 속 참조도 사용이다")
    func interpolationCounts() {
        let facts = analyze("""
            func f(name: String) -> String {
                return "hi \\(name)"
            }
            """)
        #expect(usage(facts, named: "name")?.isUsedInBody == true)
    }

    @Test("연산자 구현의 파라미터도 판정한다")
    func operatorParameters() {
        let facts = analyze("""
            struct V: Equatable {
                var n: Int
                static func == (lhs: V, rhs: V) -> Bool { lhs.n == rhs.n }
            }
            """)
        #expect(usage(facts, named: "lhs")?.isUsedInBody == true)
        #expect(usage(facts, named: "rhs")?.isUsedInBody == true)
    }

    @Test("지역 타입 안의 메서드 파라미터도 판정한다")
    func localTypeMethodsAreScanned() {
        let facts = analyze("""
            func outer() {
                struct S {
                    func g(x: Int) { print(x) }
                    func h(y: Int) {}
                }
            }
            """)
        #expect(usage(facts, named: "x")?.isUsedInBody == true)
        #expect(usage(facts, named: "y")?.isUsedInBody == false)
    }
}
