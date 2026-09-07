import CartographCore
import CartographTestSupport
import Foundation
import Testing

@Suite("IndexSnapshot")
struct IndexSnapshotTests {
    private func makeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType, module: "App", path: "/p/App/A.swift")
        builder.symbol("B", kind: .structType, module: "Domain", path: "/p/Domain/B.swift")
        builder.reference(from: "A", to: "B")
        return builder.build()
    }

    @Test("USR 사전을 만든다")
    func symbolsByUSR() {
        let byUSR = makeSnapshot().symbolsByUSR()
        #expect(byUSR.count == 2)
        #expect(byUSR["A"]?.module == "App")
    }

    @Test("USR 이 겹치면 먼저 온 심볼을 남긴다")
    func duplicateUSRKeepsFirst() {
        var builder = SnapshotBuilder()
        builder.symbol("A", name: "First", kind: .structType)
        builder.symbol("A", name: "Second", kind: .classType)
        #expect(builder.build().symbolsByUSR()["A"]?.name == "First")
    }

    @Test("모듈과 파일 목록을 정렬해서 돌려준다")
    func listsModulesAndFiles() {
        let snapshot = makeSnapshot()
        #expect(snapshot.moduleNames == ["App", "Domain"])
        #expect(snapshot.filePaths == ["/p/App/A.swift", "/p/Domain/B.swift"])
    }

    @Test("두 스냅샷을 합칠 수 있다")
    func merging() {
        var other = SnapshotBuilder()
        other.symbol("C", kind: .structType)
        let merged = makeSnapshot().merging(other.build())
        #expect(merged.symbols.count == 3)
        #expect(merged.references.count == 1)
    }

    @Test("빈 스냅샷은 아무 목록도 갖지 않는다")
    func emptySnapshot() {
        let empty = IndexSnapshot()
        #expect(empty.moduleNames.isEmpty)
        #expect(empty.filePaths.isEmpty)
        #expect(empty.symbolsByUSR().isEmpty)
    }

    @Test("파일별 시각이 없는 옛 스냅샷도 읽고 새 시각은 왕복한다")
    func indexDatesAreBackwardCompatible() throws {
        let old = Data(#"{"symbols":[],"references":[]}"#.utf8)
        #expect(try JSONDecoder().decode(IndexSnapshot.self, from: old).indexedFileDates == nil)
        let dates = ["/p/A.swift": Date(timeIntervalSince1970: 1_000)]
        let snapshot = IndexSnapshot(indexedFileDates: dates)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try JSONDecoder().decode(IndexSnapshot.self, from: encoder.encode(snapshot)) == snapshot)
    }

    @Test("스냅샷을 합쳐도 소스별 신선도 근거가 사라지거나 새 시각에 가려지지 않는다")
    func mergingPreservesIndexDates() {
        let old = Date(timeIntervalSince1970: 1_000)
        let fresh = old.addingTimeInterval(100)
        let first = IndexSnapshot(indexedFileDates: ["/p/A.swift": old])
        let second = IndexSnapshot(indexedFileDates: ["/p/A.swift": fresh, "/p/B.swift": fresh])
        #expect(first.merging(second).indexedFileDates == ["/p/A.swift": old, "/p/B.swift": fresh])
        #expect(first.merging(IndexSnapshot()).indexedFileDates == first.indexedFileDates)
        #expect(IndexSnapshot().merging(first).indexedFileDates == first.indexedFileDates)
        #expect(IndexSnapshot().merging(IndexSnapshot()).indexedFileDates == nil)
    }
}

@Suite("IndexedSymbol")
struct IndexedSymbolTests {
    private func symbol(usr: String, attributes: Set<SymbolAttribute> = []) -> IndexedSymbol {
        IndexedSymbol(
            usr: usr,
            name: "Thing",
            kind: .classType,
            module: "App",
            location: SourceLocation(path: "/p/A.swift", line: 1, column: 1),
            attributes: attributes
        )
    }

    @Test("Clang USR 은 Objective-C 접근 가능으로 본다")
    func clangUSRIsObjectiveCAccessible() {
        // @objc 로 노출된 Swift 심볼에는 별도의 Clang USR 이 함께 생성된다.
        #expect(symbol(usr: "c:objc(cs)Legacy").isObjectiveCAccessible)
        #expect(!symbol(usr: "s:3App5ThingC").isObjectiveCAccessible)
    }

    @Test("속성으로도 Objective-C 접근 가능을 판단한다")
    func attributesImplyObjectiveCAccess() {
        #expect(symbol(usr: "s:x", attributes: [.objc]).isObjectiveCAccessible)
        #expect(symbol(usr: "s:x", attributes: [.objcMembers]).isObjectiveCAccessible)
        #expect(symbol(usr: "s:x", attributes: [.objcAccessible]).isObjectiveCAccessible)
        #expect(!symbol(usr: "s:x", attributes: [.generic]).isObjectiveCAccessible)
    }
}
