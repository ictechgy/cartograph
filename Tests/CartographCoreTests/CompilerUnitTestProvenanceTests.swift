import CartographCore
import Foundation
import Testing

@Suite("컴파일러 테스트 표식 출처의 교환 호환성")
struct CompilerUnitTestProvenanceTests {
    @Test("관찰한 true와 false는 각각 왕복하고 옛 디코더는 새 키를 무시한다", arguments: [true, false])
    func roundTripsCapturedValue(value: Bool) throws {
        let original = symbol(value)
        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["compilerUnitTest"] as? Bool == value)
        #expect(try JSONDecoder().decode(IndexedSymbol.self, from: data) == original)
        let legacy = try JSONDecoder().decode(LegacySymbol.self, from: data)
        #expect(legacy.usr == original.usr)
        #expect(legacy.attributes == original.attributes)
        #expect(legacy.location == original.location)
    }

    @Test("키가 없는 옛 보존 표식에서 컴파일러 관찰을 추정하지 않는다")
    func missingKeyRemainsUnknown() throws {
        let original = symbol(nil)
        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["compilerUnitTest"] == nil)
        let decoded = try JSONDecoder().decode(IndexedSymbol.self, from: data)
        #expect(decoded.attributes.contains(.unitTest))
        #expect(decoded.compilerUnitTest == nil)
    }

    @Test("중복 USR의 모든 출처 조합은 관찰만 합치고 첫 대표의 다른 필드를 보존한다")
    func duplicateOrdersPreserveEvidenceAndFirstIdentity() throws {
        let values: [Bool?] = [nil, false, true]
        let expected: [[Bool?]] = [[nil, false, true], [false, false, true], [true, true, true]]
        for (leftIndex, left) in values.enumerated() {
            for (rightIndex, right) in values.enumerated() {
                let first = symbol(left, name: "first", line: 1, attributes: [.unitTest])
                let second = symbol(right, name: "second", line: 9, attributes: [.implicit])
                let merged = IndexSnapshot(symbols: [first]).merging(IndexSnapshot(symbols: [second]))
                #expect(merged.symbols == [first, second])
                let result = try #require(merged.symbolsByUSR()[first.usr])
                #expect(result.compilerUnitTest == expected[leftIndex][rightIndex])
                #expect(result.name == "first")
                #expect(result.location == first.location)
                #expect(result.attributes == first.attributes)
                #expect(result.module == first.module)
                #expect(result.parentUSR == first.parentUSR)
                let roundTrip = try JSONDecoder().decode(IndexSnapshot.self,
                    from: JSONEncoder().encode(merged))
                #expect(roundTrip.symbolsByUSR()[first.usr]?.compilerUnitTest == expected[leftIndex][rightIndex])
            }
        }
    }

    @Test("관찰값이 달라도 기존 보존 표식은 바꾸지 않는다")
    func provenanceDoesNotRewriteRetentionAttributes() {
        for value in [nil, false, true] as [Bool?] {
            #expect(symbol(value).attributes == [.unitTest])
            #expect(symbol(value, attributes: []).attributes.isEmpty)
        }
    }

    private func symbol(
        _ value: Bool?, name: String = "testProbe()", line: Int = 1,
        attributes: Set<SymbolAttribute> = [.unitTest]
    ) -> IndexedSymbol {
        .init(usr: "probe", name: name, kind: .method, module: "Tests",
            location: .init(path: "/p/Tests.swift", line: line, column: 1),
            parentUSR: "owner", attributes: attributes, compilerUnitTest: value)
    }

    // 새 키를 모르는 기존 IndexedSymbol의 필드 구성을 그대로 사용한다.
    private struct LegacySymbol: Decodable {
        let usr: String
        let name: String
        let kind: SymbolKind
        let module: String
        let location: CartographCore.SourceLocation
        let parentUSR: String?
        let isExternal: Bool
        let accessibility: Accessibility
        let attributes: Set<SymbolAttribute>
    }
}
