import CartographCore
@testable import CartographSyntax
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@Suite("열거형 결정 구문의 정확한 근거")
struct EnumDecisionScannerTests {
    private let path = "/p/Decisions.swift"

    private func scan(_ source: String) throws -> EnumDecisionScanFacts {
        try #require(SwiftSyntaxAnalyzer().analyze(source: source, path: path).enumDecisionFacts)
    }

    private func location(
        in source: String, line: Int, matching text: String, offset: Int = 0
    ) throws -> CartographCore.SourceLocation {
        let row = String(source.split(separator: "\n", omittingEmptySubsequences: false)[line - 1])
        let match = try #require(row.range(of: text))
        return CartographCore.SourceLocation(
            path: path, line: line,
            column: row[..<match.lowerBound].utf8.count + offset + 1
        )
    }

    @Test("한 줄의 여러 케이스와 UTF-8 이름 위치를 정확히 보존한다")
    func inventoryTokenLocations() throws {
        let source = """
        enum 상태 {
            case 값, `default`
            enum Nested { case child }
        }
        """
        let result = try scan(source)
        #expect(result.inventories.map(\.name) == ["상태", "Nested"])
        let outer = try #require(result.inventories.first)
        #expect(outer.isComplete)
        #expect(outer.nameLocation == CartographCore.SourceLocation(path: path, line: 1, column: 6))
        #expect(outer.cases.map(\.name) == ["값", "default"])
        #expect(outer.cases.map(\.location) == [
            CartographCore.SourceLocation(path: path, line: 2, column: 10),
            CartographCore.SourceLocation(path: path, line: 2, column: 15),
        ])
        #expect(result.inventories[1].cases.map(\.name) == ["child"])
        #expect(result.limitations.isEmpty)
    }

    @Test("조건부 컴파일의 모든 케이스를 남기되 완전한 목록으로 표시하지 않는다")
    func conditionalInventories() throws {
        let result = try scan("""
        #if FLAG
        enum Conditional { case first }
        #endif
        enum E {
            case a
            #if FLAG
            case b
            #else
            case c
            #endif
            enum Nested { case d }
        }
        """)
        #expect(result.inventories.map(\.name) == ["Conditional", "E", "Nested"])
        #expect(!result.inventories[0].isComplete)
        #expect(!result.inventories[1].isComplete)
        #expect(result.inventories[1].cases.map(\.name) == ["a", "b", "c"])
        #expect(result.inventories[2].isComplete)
    }

    @Test("매크로와 파싱 오류가 있으면 케이스 목록을 완전하다고 주장하지 않는다")
    func incompleteInventories() throws {
        let macro = try scan("""
        @Cases
        enum E {
            case a
            #moreCases()
        }
        """)
        #expect(macro.inventories.first?.isComplete == false)
        #expect(macro.limitations.contains("enum-decision-unexpanded-macro"))
        #expect(macro.limitations.contains("enum-decision-unresolved-attribute"))
        let broken = try scan("enum E { case a")
        #expect(broken.inventories.first?.isComplete == false)
        #expect(broken.limitations.contains("enum-decision-source-parse-errors"))
    }

    @Test("default 결정에는 자신의 패턴만 귀속하고 본문과 중첩 switch를 섞지 않는다")
    func ignoresBranchBodyAndNearbyReferences() throws {
        let source = """
        func f(_ status: Status) {
            let nearby = Other.nearby
            switch status {
            case .a:
                use(Other.bodyOnly)
                switch other { case .inner: break; default: use(Other.leak) }
            default: use(Other.fallbackOnly)
            }
        }
        """
        let result = try scan(source)
        #expect(result.decisions.count == 2)
        let outer = result.decisions[0]
        #expect(outer.kind == .switchDefault)
        #expect(outer.explicitCases.map(\.name) == ["a"])
        #expect(try outer.explicitCases[0].location == location(in: source, line: 4, matching: ".a", offset: 1))
        #expect(outer.fallbackLocations == [try location(in: source, line: 7, matching: "default")])
        #expect(try outer.subjectRange?.start == location(in: source, line: 3, matching: "status"))
        #expect(outer.limitations.isEmpty)
        #expect(result.decisions[1].explicitCases.map(\.name) == ["inner"])
    }

    @Test("where와 부분 페이로드 패턴을 전체 케이스 처리와 구분한다")
    func separatesGuardedPatterns() throws {
        let result = try scan("""
        func f(_ status: Status) {
            switch status {
            case .a, .b where allowed: break
            case let .payload(value): use(value)
            case .literal(7): break
            case .nested(.inner): break
            @unknown default: break
            }
        }
        """)
        let decision = try #require(result.decisions.first)
        #expect(decision.kind == .switchUnknownDefault)
        #expect(decision.explicitCases.map(\.name) == ["a", "payload"])
        #expect(decision.guardedCases.map(\.name) == ["b", "literal", "nested"])
        #expect(decision.limitations.isEmpty)
        #expect(decision.operationLocation == nil)
        #expect(decision.negationLocation == nil)
    }

    @Test("와일드카드와 지역 바인딩 페이로드만 전체 케이스로 읽는다")
    func recognizesIrrefutablePayloads() throws {
        let result = try scan("""
        func f(_ status: Status) {
            switch status {
            case .a(_), .b(let value), let .c(left, right): break
            default: break
            }
        }
        """)
        let decision = try #require(result.decisions.first)
        #expect(decision.explicitCases.map(\.name) == ["a", "b", "c"])
        #expect(decision.guardedCases.isEmpty)
        #expect(decision.limitations.isEmpty)
    }

    @Test("튜플과 선택 패턴을 지원한 것으로 위장하지 않는다")
    func rejectsUnsupportedSwitchPatterns() throws {
        let result = try scan("""
        switch pair {
        case (.a, .b): break
        default: break
        }
        switch optional {
        case .a?: break
        default: break
        }
        """)
        #expect(result.decisions.count == 2)
        for decision in result.decisions {
            #expect(decision.explicitCases.isEmpty)
            #expect(decision.guardedCases.isEmpty)
            #expect(decision.limitations.contains("enum-decision-unsupported-switch-pattern"))
        }
    }

    @Test("default만 있는 switch는 본문의 enum 참조로 대상을 추측하지 않는다")
    func defaultOnlyIsUnresolved() throws {
        let result = try scan("switch value { default: use(Status.a) }")
        let decision = try #require(result.decisions.first)
        #expect(decision.explicitCases.isEmpty)
        #expect(decision.limitations.contains("enum-decision-no-case-tokens"))
    }

    @Test("조건부 case와 default가 있으면 결정의 제한을 기록한다")
    func conditionalSwitchIsPartial() throws {
        let result = try scan("""
        switch status {
        #if FLAG
        case .a: break
        #else
        case .b: break
        #endif
        default: break
        }
        """)
        let decision = try #require(result.decisions.first)
        #expect(decision.explicitCases.map(\.name) == ["a", "b"])
        #expect(decision.limitations.contains("enum-decision-conditional-compilation"))
    }

    @Test("리터럴 멤버십과 직접 부정의 토큰 및 명시적 파라미터 타입을 기록한다")
    func literalMembershipAndTypedSubject() throws {
        let source = """
        func f(_ status: Status) {
            _ = [Status.a, .b, Status.a].contains(status)
            _ = !([Status.a].contains((status)))
        }
        """
        let result = try scan(source)
        #expect(result.decisions.count == 2)
        let positive = result.decisions[0]
        #expect(positive.kind == .literalMembership)
        #expect(positive.explicitCases.map(\.name) == ["a", "b", "a"])
        #expect(try positive.operationLocation == location(in: source, line: 2, matching: "contains"))
        #expect(try positive.subjectRange?.start == location(in: source, line: 2, matching: "status)"))
        let typed = try #require(positive.subjectParameter)
        #expect(typed.parameterName == "status")
        #expect(try typed.parameterNameLocation == location(in: source, line: 1, matching: "status:"))
        #expect(try typed.typeNameLocation == location(in: source, line: 1, matching: "Status"))
        #expect(typed.subjectLocation == positive.subjectRange?.start)
        #expect(typed.functionRange.start == CartographCore.SourceLocation(path: path, line: 1, column: 1))
        let negative = result.decisions[1]
        #expect(negative.kind == .negatedLiteralMembership)
        #expect(try negative.negationLocation == location(in: source, line: 3, matching: "!"))
        #expect(negative.range.start == negative.negationLocation)
        #expect(negative.subjectParameter?.parameterNameLocation == typed.parameterNameLocation)
        #expect(result.decisions.allSatisfy { $0.limitations.isEmpty })
    }

    @Test("이전 단순 참조는 가림이 아니며 한정된 타입 이름의 마지막 토큰을 넘긴다")
    func priorReadsAndQualifiedType() throws {
        let source = """
        func f(label status: Model.Status) {
            let previous = status
            print(status)
            _ = [.a].contains(status)
        }
        """
        let result = try scan(source)
        let typed = try #require(result.decisions.first?.subjectParameter)
        #expect(try typed.typeNameLocation == location(in: source, line: 1, matching: "Status"))
        #expect(result.decisions.first?.limitations.isEmpty == true)
    }

    @Test("동적 컬렉션과 클로저 contains 및 비직접 원소는 제한된 후보로 남긴다")
    func unsupportedMembershipShapes() throws {
        let result = try scan("""
        func f(_ status: Status) {
            _ = values.contains(status)
            _ = Status.allCases.contains(status)
            _ = [.a].filter { true }.contains(status)
            _ = [.a].contains(where: { _ in true })
            _ = [].contains(status)
            _ = [.a, factory(.b)].contains(status)
        }
        """)
        #expect(result.decisions.count == 6)
        for decision in result.decisions.prefix(3) {
            #expect(decision.explicitCases.isEmpty)
            #expect(decision.limitations.contains("enum-decision-nonliteral-membership-receiver"))
        }
        #expect(result.decisions[3].limitations.contains("enum-decision-unsupported-membership-call"))
        #expect(result.decisions[3].subjectRange == nil)
        #expect(result.decisions[4].limitations.contains("enum-decision-empty-literal"))
        #expect(result.decisions[5].explicitCases.map(\.name) == ["a"])
        #expect(result.decisions[5].limitations.contains("enum-decision-unsupported-literal-element"))
        #expect(result.limitations.isEmpty)
    }

    @Test("추가 연산자를 직접 부정 하나와 같은 의미로 해석하지 않는다")
    func unsupportedPrefixOperators() throws {
        let result = try scan("""
        func f(_ status: Status) {
            _ = ~~~[.a].contains(status)
            _ = !(![.a].contains(status))
        }
        """)
        #expect(result.decisions.count == 2)
        #expect(result.decisions[0].limitations.contains("enum-decision-unsupported-prefix-operator"))
        #expect(result.decisions[1].limitations.contains("enum-decision-multiple-prefix-operators"))
    }

    @Test("지역 바인딩과 중첩 파라미터가 이름을 가릴 수 있으면 타입을 추측하지 않는다", arguments: [
        "let status = other; _ = [.a].contains(status)",
        "if let status = other { _ = [.a].contains(status) }",
        "guard let status = other else { return }; _ = [.a].contains(status)",
        "do { try work() } catch let status { _ = [.a].contains(status) }",
        "for status in values { _ = [.a].contains(status) }",
        "switch other { case let .payload(status): _ = [.a].contains(status); default: break }",
        "let unused = { (status: Other) in status }; _ = [.a].contains(status)",
        "let unused = { status in status }; _ = [.a].contains(status)",
        "func nested(_ status: Other) {}; _ = [.a].contains(status)",
    ])
    func rejectsPotentialShadows(body: String) throws {
        let result = try scan("func f(_ status: Status) { \(body) }")
        let decision = try #require(result.decisions.first { $0.kind == .literalMembership })
        #expect(decision.subjectParameter == nil)
        #expect(decision.limitations.contains("enum-decision-unverified-subject-type"))
    }

    @Test("catch의 암묵적 error도 파라미터 가림으로 취급한다")
    func implicitCatchShadow() throws {
        let result = try scan("""
        func f(_ error: Status) {
            do { try work() } catch { _ = [.a].contains(error) }
        }
        """)
        #expect(result.decisions.first?.subjectParameter == nil)
        #expect(result.decisions.first?.limitations.contains("enum-decision-unverified-subject-type") == true)
    }

    @Test("명시적 함수 파라미터가 아닌 대상은 첫 범위에서 지원하지 않는다", arguments: [
        "self.status", "makeStatus()", "Status.a", "other", "status!", "status as Status",
    ])
    func rejectsOtherSubjectShapes(subject: String) throws {
        let result = try scan("func f(_ status: Status) { _ = [.a].contains(\(subject)) }")
        #expect(result.decisions.first?.subjectParameter == nil)
        #expect(result.decisions.first?.limitations.contains("enum-decision-unverified-subject-type") == true)
    }

    @Test("클로저를 건너뛰어 바깥 함수 파라미터에 붙이지 않는다")
    func rejectsClosureCaptureRoute() throws {
        let result = try scan("func f(_ status: Status) { let later = { [.a].contains(status) } }")
        #expect(result.decisions.first?.subjectParameter == nil)
    }

    @Test("선택형과 배열 및 가변 인자를 단순 enum 값으로 읽지 않는다", arguments: [
        "Status?", "[Status]", "Status...", "Container<Status>", "inout Status",
    ])
    func rejectsUnsupportedParameterTypes(type: String) throws {
        let result = try scan("func f(_ status: \(type)) { _ = [.a].contains(status) }")
        #expect(result.decisions.first?.subjectParameter == nil)
    }

    @Test("if-case와 동등 비교 및 fallback 없는 switch를 새 지원으로 주장하지 않는다")
    func excludesOtherDecisionKinds() throws {
        let result = try scan("""
        if case .a = status { use(status) }
        if status == Status.a { use(status) }
        customGate(status)
        switch status { case .a: break; case .b: break }
        """)
        #expect(result.decisions.isEmpty)
    }

    @Test("다른 타입의 사용자 패턴 연산자를 enum 대상이라고 추측하지 않는다")
    func customPatternOperatorNeedsSubjectBinding() throws {
        let source = """
        func ~= (pattern: Status, value: Other) -> Bool { true }
        func f(_ value: Other) {
            switch value { case Status.a: break; default: break }
            switch true { case Status.a: break; default: break }
        }
        """
        let result = try scan(source)
        #expect(result.decisions.count == 2)
        let typed = try #require(result.decisions[0].subjectParameter)
        #expect(try typed.typeNameLocation == location(in: source, line: 2, matching: "Other"))
        // Other와 Status의 불일치는 정확한 타입 참조를 받은 컴파일러 바인더가 거절한다.
        #expect(result.decisions[0].explicitCases.map(\.name) == ["a"])
        #expect(result.decisions[1].subjectParameter == nil)
        #expect(result.decisions[1].limitations.contains("enum-decision-unverified-subject-type"))
    }

    @Test("같은 함수의 결정 수가 늘어도 가림 요약은 함수마다 한 번만 순회한다")
    func cachesOneShadowWalkPerFunction() {
        let sites = Array(repeating: """
            _ = [.a].contains(status)
            switch status { case .a: break; default: break }
            """, count: 128).joined(separator: "\n")
        let source = """
        enum Status { case a, b }
        func first(_ status: Status) {
        \(sites)
        }
        func second(_ status: Status) {
        \(sites)
        }
        """
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        var walkCount = 0
        let result = EnumDecisionScanner().scan(
            tree: tree, path: path, converter: converter,
            onShadowSummaryWalk: { walkCount += 1 }
        )
        #expect(result.decisions.count == 512)
        #expect(walkCount == 2)
        #expect(result.decisions.allSatisfy { $0.subjectParameter != nil && $0.limitations.isEmpty })
    }

    @Test("캐시된 최초 바인딩은 사용 이전에 있을 때만 가림으로 판정한다")
    func cachedSummaryPreservesBindingBoundary() throws {
        let result = try scan("""
        func f(_ status: Status) {
            _ = [.a].contains(status)
            let status = other
            _ = [.a].contains(status)
        }
        """)
        #expect(result.decisions.count == 2)
        #expect(result.decisions[0].subjectParameter != nil)
        #expect(result.decisions[1].subjectParameter == nil)
        #expect(result.decisions[1].limitations.contains("enum-decision-unverified-subject-type"))
    }

    @Test("중첩 함수 이름은 사용 뒤에 선언되어도 가림으로 남는다")
    func cachedSummaryPreservesHoistedNames() throws {
        let result = try scan("""
        func f(_ status: Status) {
            _ = [.a].contains(status)
            func status() {}
        }
        """)
        #expect(result.decisions.first?.subjectParameter == nil)
        #expect(result.decisions.first?.limitations.contains("enum-decision-unverified-subject-type") == true)
    }

    @Test("캐시된 매크로와 미해결 속성 위치는 그 뒤의 모든 이름을 차단한다", arguments: [
        "#makeBindings()",
        "@Wrapper var unrelated = 0",
    ])
    func cachedSummaryPreservesUnknownExpansionBoundary(expansion: String) throws {
        let result = try scan("""
        func f(_ first: Status, _ second: Status) {
            _ = [.a].contains(first)
            \(expansion)
            _ = [.a].contains(second)
        }
        """)
        #expect(result.decisions.count == 2)
        #expect(result.decisions[0].subjectParameter?.parameterName == "first")
        #expect(result.decisions[1].subjectParameter == nil)
        #expect(result.decisions[1].limitations.contains("enum-decision-unverified-subject-type"))
    }

    @Test("같은 소스의 순서와 정렬된 JSON이 결정적이다")
    func deterministicEncoding() throws {
        let source = """
        enum E { case a, b }
        func f(_ value: E) {
            switch value { case .a: break; default: break }
            _ = ![.a].contains(value)
        }
        """
        let first = try scan(source)
        let second = try scan(source)
        #expect(first == second)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(first) == encoder.encode(second))
        #expect(try JSONDecoder().decode(EnumDecisionScanFacts.self, from: encoder.encode(first)) == first)
    }

    @Test("예전 캐시는 미수집으로 남고 새 빈 소스는 수집된 빈 사실을 가진다")
    func distinguishesOldCacheAndEmptyScan() throws {
        let data = Data(#"{"path":"/p/Old.swift","declarations":[],"ignoresEntireFile":false}"#.utf8)
        let old = try JSONDecoder().decode(SourceFileFacts.self, from: data)
        #expect(old.enumDecisionFacts == nil)
        let empty = try scan("")
        #expect(empty.inventories.isEmpty)
        #expect(empty.decisions.isEmpty)
        #expect(empty.limitations.isEmpty)
    }
}
