import CartographCore
@testable import CartographIndexStore
import Foundation
import IndexStoreDB
import Testing

@Suite("레코드 발생 중복 제거")
struct OccurrenceDeduplicatorTests {
    /// 판독기의 레코드 항목 하나. 같은 (유닛, 레코드) 쌍이 경로·모듈 표기만 바꿔 다시 나올 수 있다.
    private struct Entry {
        let unit: String
        let record: String
        let occurrences: [SymbolOccurrence]
    }

    @Test("유닛이 같은 레코드를 다시 의존하면 그 항목의 발생은 다시 내지 않는다")
    func repeatedRecordContextAddsNothing() {
        // 경로 표기만 다른 두 번째 항목도 같은 레코드라 발생이 첫 항목과 같다. 사이에 다른 레코드가 끼어도 같다.
        let first = [occurrence("A", path: "/p/A.swift"), occurrence("B", path: "/p/A.swift", line: 4)]
        let respelled = first.map { relocated($0, to: "/private/p/A.swift") }
        let collected = collect([
            Entry(unit: "u1", record: "r1", occurrences: first),
            Entry(unit: "u1", record: "r2", occurrences: [occurrence("C", path: "/p/C.swift")]),
            Entry(unit: "u1", record: "r1", occurrences: respelled),
        ])
        #expect(collected.occurrences.map(\.symbol.usr) == ["A", "B", "C"])
        #expect(collected.occurrences.allSatisfy { !$0.location.path.hasPrefix("/private") })
    }

    @Test("레코드 안의 같은 발생은 한 번만 남기고 다른 유닛의 같은 레코드는 따로 낸다")
    func duplicatesCollapseOnlyWithinOneContext() {
        let duplicated = [occurrence("A"), occurrence("A"), occurrence("A", line: 9)]
        let collected = collect([
            Entry(unit: "u1", record: "r1", occurrences: duplicated),
            Entry(unit: "u2", record: "r1", occurrences: duplicated),
        ])
        #expect(collected.occurrences.map(\.location.line) == [3, 9, 3, 9])
    }

    @Test("관계는 순서와 무관하게 비교하고 내용이 다르면 다른 발생으로 둔다")
    func relationsCompareAsUnorderedPairs() {
        let caller = relation("caller", roles: [.calledBy, .containedBy])
        let receiver = relation("Receiver", roles: .receivedBy)
        let collected = collect([Entry(unit: "u1", record: "r1", occurrences: [
            occurrence("work", relations: [caller, receiver]),
            occurrence("work", relations: [receiver, caller]),
            occurrence("work", relations: [caller]),
            occurrence("work", relations: [relation("caller", roles: .calledBy), receiver]),
        ])])
        #expect(collected.occurrences.map(\.relations.count) == [2, 1, 2])
    }

    @Test("구분자가 든 USR 로 관계 서명이 겹쳐도 서로 다른 관계 집합을 합치지 않는다")
    func relationSetsNeverCollideThroughTheirSpelling() {
        // 문자열로 이어 붙인 서명은 두 관계 `a`·`b` 와 USR 이 `a:1,b` 인 관계 하나를 같은 "a:1,b:2" 로 만들었다.
        let pair = [relation("a", roles: SymbolRole(rawValue: 1)), relation("b", roles: SymbolRole(rawValue: 2))]
        let single = [relation("a:1,b", roles: SymbolRole(rawValue: 2))]
        let collected = collect([Entry(unit: "u1", record: "r1", occurrences: [
            occurrence("work", relations: pair),
            occurrence("work", relations: single),
        ])])
        #expect(collected.occurrences.count == 2)
    }

    @Test("붙잡는 키는 읽기 전체가 아니라 레코드 하나 크기로 묶인다")
    func retainedKeysAreBoundedByOneRecord() {
        // 읽기 전체에 걸친 집합은 발생마다 키를 끝까지 붙잡아 큰 인덱스에서 읽기 단계 메모리를 두 배로 만들었다.
        let entries = (0..<4).map { index in
            Entry(unit: "u\(index)", record: "r\(index)", occurrences: (1...25).map {
                occurrence("S\(index)", line: $0)
            })
        }
        let collected = collect(entries)
        #expect(collected.occurrences.count == 100)
        #expect(collected.retainedKeyCounts == [25, 25, 25, 25])
    }

    /// 판독기의 레코드 순회와 같은 순서로 중복 제거를 돌린다.
    private func collect(_ entries: [Entry]) -> (occurrences: [SymbolOccurrence], retainedKeyCounts: [Int]) {
        var deduplicator = RawIndexStoreReader.OccurrenceDeduplicator()
        var occurrences: [SymbolOccurrence] = []
        var retainedKeyCounts: [Int] = []
        for entry in entries where deduplicator.begin(unit: entry.unit, record: entry.record) {
            occurrences += entry.occurrences.filter { deduplicator.admit($0) }
            retainedKeyCounts.append(deduplicator.retainedKeyCount)
        }
        return (occurrences, retainedKeyCounts)
    }

    private func occurrence(
        _ usr: String, path: String = "/p/A.swift", line: Int = 3, relations: [SymbolRelation] = []
    ) -> SymbolOccurrence {
        SymbolOccurrence(
            symbol: symbol(usr),
            location: SymbolLocation(
                path: path, timestamp: Date(timeIntervalSince1970: 0), moduleName: "App",
                isSystem: false, line: line, utf8Column: 5
            ),
            roles: [.reference, .call],
            symbolProvider: .swift,
            relations: relations
        )
    }

    private func relocated(_ occurrence: SymbolOccurrence, to path: String) -> SymbolOccurrence {
        var moved = occurrence
        moved.location.path = path
        return moved
    }

    private func relation(_ usr: String, roles: SymbolRole) -> SymbolRelation {
        SymbolRelation(symbol: symbol(usr), roles: roles)
    }

    private func symbol(_ usr: String) -> Symbol {
        Symbol(usr: usr, name: usr, kind: .instanceMethod, subKind: .none, properties: SymbolProperty(),
               language: .swift)
    }
}
