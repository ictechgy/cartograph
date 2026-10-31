import CartographCore
import Foundation
import Testing

@Suite("값 흐름 격자와 교환")
struct ValueFlowValueTests {
    @Test("값 예산을 넘긴 top은 이후 합류에서도 값을 다시 담지 않는다")
    func valueBudgetIsAbsorbing() {
        let values = (0..<4).map { ValueFlowValue(atoms: [.literal(.integer($0))]) }
        let top = values[0].joining(values[1], limit: 2).joining(values[2], limit: 2)
        #expect(top.unknownReasons.contains("value-budget"))
        #expect(top.atoms.isEmpty)
        #expect(top.joining(values[3], limit: 2).atoms.isEmpty)
        #expect(values[3].joining(top, limit: 2).atoms.isEmpty)
        #expect(top.joining(values[3], limit: 2).joining(top, limit: 2) == top)
    }

    @Test("출처 예산을 넘긴 top은 이후 합류에서도 출처를 다시 담지 않는다")
    func originBudgetIsAbsorbing() {
        let origins = Set((0..<5).map {
            ValueFlowOrigin(id: "origin-\($0)", location: .init(path: "/p/F.swift", line: $0 + 1, column: 1))
        })
        let top = ValueFlowValue(origins: origins).joining(.init(), limit: 1)
        let next = ValueFlowValue(origins: [
            .init(id: "next", location: .init(path: "/p/F.swift", line: 9, column: 1))
        ])
        #expect(top.unknownReasons.contains("origin-budget"))
        #expect(top.origins.isEmpty)
        #expect(top.joining(next, limit: 1) == top)
        #expect(next.joining(top, limit: 1) == top)
    }

    @Test("큰 사용자 예산에서도 출처 상한 계산이 정수 오버플로를 내지 않는다")
    func largeLimit() {
        let value = ValueFlowValue(atoms: [.literal(.string("A"))])
        #expect(value.joining(value, limit: Int.max) == value)
        #expect(value.joining(.unknown("external"), limit: Int.max).singleString == nil)
    }

    @Test("값 집합과 출처를 JSON으로 왕복해도 종류와 미상 이유가 손실되지 않는다")
    func roundTrip() throws {
        let value = ValueFlowValue(atoms: [.literal(.string("A")), .literal(.integer(1)), .literal(.boolean(true)),
            .literal(.null), .literal(.unit), .reference("address"), .object(id: "allocation", type: "Box"),
            .function("callback"), .type("Box")], origins: [
                .init(id: "literal", location: .init(path: "/p/F.swift", line: 1, column: 1), literal: .string("A"))
            ], unknownReasons: ["external", "unavailable"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let decoded = try JSONDecoder().decode(ValueFlowValue.self, from: data)
        #expect(decoded == value)
        #expect(try encoder.encode(decoded) == data)
        #expect(decoded.singleString == nil)
    }
    @Test("다른 문자열의 합류는 정규화 충돌이 아니라 두 가능한 값이다")
    func distinctSpellings() {
        let joined = ValueFlowValue(atoms: [.literal(.string("A"))]).joining(
            ValueFlowValue(atoms: [.literal(.string("B"))]), limit: 32)
        #expect(joined.atoms.count == 2)
        #expect(joined.unknownReasons.isEmpty)
        #expect(joined.singleString == nil)
    }

}
