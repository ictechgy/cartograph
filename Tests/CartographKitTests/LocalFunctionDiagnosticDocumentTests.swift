import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("미분석 지역 함수 상세 응답")
struct LocalFunctionDiagnosticDocumentTests {
    private let path = "/p/Local.swift"
    private let source = "func owner() {\n    func hidden() {}\n}"

    @Test("없는 심볼을 물어도 미분석 함수의 이름·위치·원인·조치를 준다")
    func explainsUnenteredLocalInNotFound() throws {
        let service = fixture(source)
        let document = try service.queryDocument(symbol: "missing")
        #expect(document.status == "notFound")
        let details = try #require(document.localFunctionDiagnostics)
        let item = try #require(details.items.first)
        #expect(item.name == "hidden()")
        #expect(item.location == SourceLocation(path: path, line: 2, column: 10))
        #expect(item.ownerName == "owner")
        #expect(item.ownerUSR == "owner")
        #expect(item.reason == .noEntryChain)
        #expect(item.action.contains("Inspect"))
        #expect(details.totalCount == 1 && details.omittedCount == 0)
    }

    @Test("성공·모호 응답도 같은 미분석 근거를 보존한다")
    func includesDetailsInFoundAndAmbiguous() throws {
        let found = try fixture(source).queryDocument(symbol: "owner")
        #expect(found.status == "found")
        #expect(found.localFunctionDiagnostics?.totalCount == 1)
        let ambiguous = try fixture(source, ambiguous: true).queryDocument(symbol: "owner()")
        #expect(ambiguous.status == "ambiguous")
        #expect(ambiguous.localFunctionDiagnostics == found.localFunctionDiagnostics)
    }

    @Test("원인이 다르면 오래된 소스와 날짜 미제공을 구별한다")
    func distinguishesFreshnessFailures() throws {
        let stale = try fixture(source, modified: 30).queryDocument(symbol: "owner")
        #expect(stale.localFunctionDiagnostics?.items.first?.reason == .sourceNotFresh)
        let unindexed = try fixture(source, indexed: nil).queryDocument(symbol: "owner")
        #expect(unindexed.localFunctionDiagnostics?.items.first?.reason == .indexDateUnavailable)
        let undated = try fixture(source, modified: nil).queryDocument(symbol: "owner")
        #expect(undated.localFunctionDiagnostics?.items.first?.reason == .sourceDateUnavailable)
    }

    @Test("진단 목록을 제한해도 전체 개수와 생략 개수를 정확히 준다")
    func boundsDetails() throws {
        let functions = (0..<55).map { "    func local\($0)() {}" }.joined(separator: "\n")
        let document = try fixture("func owner() {\n\(functions)\n}").queryDocument(symbol: "owner")
        let details = try #require(document.localFunctionDiagnostics)
        #expect(details.totalCount == 55 && details.omittedCount == 5 && details.items.count == 50)
        #expect(details.items.first?.name == "local0()")
        #expect(details.items.last?.name == "local49()")
    }

    @Test("알릴 지역 함수가 없으면 새 선택 키를 생략한다")
    func omitsEmptyDetails() throws {
        let document = try fixture("func owner() {}").queryDocument(symbol: "owner")
        #expect(document.localFunctionDiagnostics == nil)
        let value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
            as? [String: Any])
        #expect(value["localFunctionDiagnostics"] == nil)
    }

    @Test("경로 필터 밖의 지역 함수 상세를 응답에 노출하지 않는다")
    func filtersDiagnosticDetails() throws {
        let fileSystem = InMemoryFileSystem(files: [path: source, "/p/Visible.swift": "func visible() {}"])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 10), for: path)
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "owner", name: "owner()", kind: .function, module: "App",
                location: SourceLocation(path: path, line: 1, column: 6)),
            IndexedSymbol(usr: "visible", name: "visible()", kind: .function, module: "App",
                location: SourceLocation(path: "/p/Visible.swift", line: 1, column: 6)),
        ], indexedFileDates: [path: Date(timeIntervalSince1970: 20)])
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.exclude = ["Local.swift"]
        let service = CartographService(configuration: configuration, environment: .init(fileSystem: fileSystem,
            indexProviderOverride: StaticIndexProvider(snapshot)))
        let document = try service.queryDocument(symbol: "visible")
        #expect(document.localFunctionDiagnostics == nil)
        #expect(!document.limitations.contains { $0.hasPrefix("local-function-projection:") })
    }

    @Test("같은 위치의 다른 출처도 스냅샷 순서를 뒤집어 직렬화하면 동일하다")
    func capturesOriginsDeterministically() throws {
        let service = fixture(source)
        let context = try service.loadContext()
        var snapshot = context.snapshot
        snapshot.references = [ReferenceOrigin.syntax, .compiler, .inferred].map {
            IndexedReference(sourceUSR: "owner", targetUSR: "outside", kind: .call,
                location: SourceLocation(path: path, line: 2, column: 10), origin: $0)
        }
        let first = try service.captureSnapshot(in: AnalysisContext(snapshot: snapshot))
        snapshot.references.reverse()
        let second = try service.captureSnapshot(in: AnalysisContext(snapshot: snapshot))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(first) == encoder.encode(second))
    }

    @Test("스냅샷을 옮겨 읽어도 참조 출처와 진단 위치를 보존한다")
    func preservesDiagnosticsAndOriginThroughSnapshots() throws {
        let service = fixture(source)
        let context = try service.loadContext()
        var snapshot = context.snapshot
        snapshot.references.append(IndexedReference(sourceUSR: "owner", targetUSR: "outside", kind: .reference,
            location: SourceLocation(path: path, line: 2, column: 10), origin: .inferred))
        let captured = try service.captureSnapshot(in: AnalysisContext(snapshot: snapshot,
            localFunctionDiagnostics: context.localFunctionDiagnostics))
        let data = try JSONEncoder().encode(captured)
        let moved = try JSONDecoder().decode(AnalysisSnapshotDocument.self, from: data).rebased(to: "/moved")
        #expect(moved.localFunctionDiagnostics?.first?.location.path == "/moved/Local.swift")
        #expect(moved.localFunctionDiagnostics?.first?.reason == .noEntryChain)
        #expect(moved.snapshot.references.first?.origin == .inferred)
        #expect(moved.snapshot.references.first?.location?.path == "/moved/Local.swift")
    }

    private func fixture(
        _ source: String, modified: Double? = 10, indexed: Double? = 20, ambiguous: Bool = false
    ) -> CartographService {
        let fileSystem = InMemoryFileSystem(files: [path: source])
        if let modified { fileSystem.setModificationDate(Date(timeIntervalSince1970: modified), for: path) }
        var symbols = [IndexedSymbol(usr: "owner", name: "owner()", kind: .function, module: "App",
            location: SourceLocation(path: path, line: 1, column: 6))]
        if ambiguous {
            symbols.append(IndexedSymbol(usr: "owner2", name: "owner()", kind: .function, module: "Other",
                location: SourceLocation(path: path, line: 20, column: 6)))
        }
        let snapshot = IndexSnapshot(symbols: symbols,
            indexedFileDates: indexed.map { [path: Date(timeIntervalSince1970: $0)] })
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return CartographService(configuration: configuration, environment: .init(fileSystem: fileSystem,
            indexProviderOverride: StaticIndexProvider(snapshot)))
    }
}
