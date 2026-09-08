import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("값 흐름 서비스")
struct ValueFlowServiceTests {
    private let path = "/p/Names.swift"
    private let source = "public func name() -> String { \"channel\" }"

    private func service(fresh: Bool = true, unreadable: Bool = false, duplicate: Bool = false)
        -> CartographService {
        let fileSystem = InMemoryFileSystem(currentDirectoryPath: "/p", files: [path: source])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: fresh ? 1 : 3), for: path)
        if unreadable { fileSystem.setReadError(.fileReadNoPermission, for: path) }
        var symbols = [IndexedSymbol(usr: "s:name", name: "name()", kind: .function, module: "P",
            location: .init(path: path, line: 1, column: 13))]
        if duplicate {
            symbols.append(IndexedSymbol(usr: "s:other", name: "name()", kind: .function, module: "P",
                location: .init(path: path, line: 2, column: 13)))
        }
        let snapshot = IndexSnapshot(symbols: symbols, indexedFileDates: [path: Date(timeIntervalSince1970: 2)])
        return CartographService(configuration: .init(projectPath: "/p"), environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot), usesSyntaxCache: false))
    }

    @Test("신선한 컴파일러 선언과 연결한 함수 반환값을 값 레벨로 내보낸다")
    func knownReturn() throws {
        let result = try service().valueFlowDocument(symbol: "name")
        #expect(result.status == "found")
        #expect(result.level == "value")
        #expect(result.symbolUSR == "s:name")
        #expect(result.selectedContexts.count == 1)
        #expect(result.graph.contexts.first?.result.singleString == "channel")
        let first = try service().dataflow(symbol: "name")
        let second = try service().dataflow(symbol: "name")
        #expect(first.output == second.output)
        #expect(!first.output.contains("\"candidates\""))
        #expect(!first.output.contains("\"callSite\""))
        #expect(!first.subjectNotFound)
    }

    @Test("낡은 인덱스와 읽을 수 없는 소스는 확정 반환값으로 바뀌지 않는다")
    func missingEvidence() throws {
        for subject in [service(fresh: false), service(unreadable: true)] {
            let result = try subject.valueFlowDocument(symbol: "name")
            #expect(result.status == "unavailable")
            #expect(result.graph.contexts.allSatisfy { $0.result.singleString == nil })
            #expect(!result.graph.limitations.isEmpty)
        }
    }

    @Test("없는 이름과 모호한 이름은 서로 다른 조회 상태다")
    func lookups() throws {
        let missing = try service(fresh: false).dataflow(symbol: "missing")
        #expect(missing.subjectNotFound)
        #expect(missing.output.contains("notFound"))
        #expect(missing.output.contains("limitations"))
        let ambiguous = try service(duplicate: true).valueFlowDocument(symbol: "name")
        #expect(ambiguous.status == "ambiguous")
        #expect(ambiguous.candidates == ["s:name", "s:other"])
    }
    @Test("프로젝트 매니페스트를 프로그램 전역으로 낮추지 않고 파일별 공백을 센다")
    func sourceInventory() {
        let fileSystem = InMemoryFileSystem(currentDirectoryPath: "/p", files: [
            "/p/Package.swift": "let package = Package()", "/p/Fresh.swift": "func fresh() {}",
            "/p/Stale.swift": "func stale() {}", "/p/Missing.swift": "func missing() {}",
            "/p/Undated.swift": "func undated() {}", "/p/Native.m": "void callback() {}"
        ])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 1), for: "/p/Fresh.swift")
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 3), for: "/p/Stale.swift")
        let snapshot = IndexSnapshot(indexedFileDates: ["/p/Fresh.swift": Date(timeIntervalSince1970: 2),
            "/p/Stale.swift": Date(timeIntervalSince1970: 2), "/p/Undated.swift": Date(timeIntervalSince1970: 2)])
        let loaded = ValueFlowSourceLoader(fileSystem: fileSystem, projectPath: "/p", pathFilter: .passthrough)
            .load(snapshot: snapshot)
        #expect(!loaded.program.fields.contains { $0.name == "package" })
        #expect(loaded.program.limitations.contains("stale-value-flow-sources: 1 file(s)"))
        #expect(loaded.program.limitations.contains("unindexed-value-flow-sources: 1 file(s)"))
        #expect(loaded.program.limitations.contains("undated-value-flow-sources: 1 file(s)"))
        #expect(loaded.program.limitations.contains("objective-c-value-flow-unavailable: 1 file(s)"))
    }

}
