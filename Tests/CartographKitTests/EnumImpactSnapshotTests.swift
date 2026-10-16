import CartographAnalysis
import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("enum 검토 snapshot 보존")
struct EnumImpactSnapshotTests {
    @Test("과거 문서 왕복과 루트 이동에 enum 근거가 남는다")
    func documentRoundTripAndRebase() throws {
        let original = AnalysisSnapshotDocument(projectRoot: "/old", snapshot: snapshot(root: "/old"))
        let decoded = try JSONDecoder().decode(AnalysisSnapshotDocument.self,
            from: JSONEncoder.cartographDefault().encode(original))
        try decoded.validate()
        let moved = decoded.rebased(to: "/new")
        let file = try #require(moved.snapshot.enumImpactFiles?.first)
        #expect(file.path == "/new/Included.swift")
        #expect(file.inventories.first?.location.path == "/new/Included.swift")
        #expect(file.decisions.first?.location.path == "/new/Included.swift")
        #expect(file.decisions.first?.endLocation.path == "/new/Included.swift")
        #expect(file.decisions.first?.evidenceLocations.first?.path == "/new/Included.swift")
        #expect(file.decisions.first?.enumUSR == "E")
    }

    @Test("snapshot 내보내기는 제외된 파일의 enum 사실을 다시 끼워 넣지 않는다")
    func exportFiltersIncludedFiles() throws {
        var input = snapshot(root: "/p")
        let excluded = CartographCore.SourceLocation(path: "/p/Excluded.swift", line: 1, column: 1)
        input.symbols.append(.init(usr: "Other", name: "Other", kind: .enumType,
            module: "App", location: excluded))
        input.enumImpactFiles?.append(.init(path: excluded.path, status: "fresh",
            inventories: [.init(enumUSR: "Other", caseUSRs: [], location: excluded, complete: true)]))
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration,
            environment: .init(fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(input)),
            allowsEmptyIndex: true)
        let context = AnalysisContext(snapshot: input,
            pathFilter: .init(exclude: [GlobPattern("Excluded.swift")], basePath: "/p"))
        let captured = try service.captureSnapshot(in: context)
        #expect(captured.snapshot.enumImpactFiles?.map(\.path) == ["/p/Included.swift"])
        #expect(captured.snapshot.enumImpactFiles?.first == input.enumImpactFiles?.first)
        let supplemental = try service.supplementalSnapshot(sourcePaths: ["/p/Included.swift"])
        #expect(supplemental.enumImpactFiles?.map(\.path) == ["/p/Included.swift"])
        #expect(supplemental.enumImpactFiles?.first == input.enumImpactFiles?.first)
    }

    @Test("Core Data 보충 문맥은 기존 enum 근거와 미수집 겹침을 구분한다")
    func augmentationPreservesCoverage() throws {
        let base = snapshot(root: "/p")
        let path = "/p/Included.swift"
        let generated = IndexedSymbol(usr: "Generated", name: "Generated", kind: .classType,
            module: "App", location: .init(path: "/p/Generated.swift", line: 1, column: 1))
        let disjoint = CartographService.augmentedEnumImpactFiles(
            base: base, supplemental: .init(symbols: [generated]), includedBasePaths: [path])
        #expect(disjoint == base.enumImpactFiles)
        let overlapping = CartographService.augmentedEnumImpactFiles(
            base: base, supplemental: .init(symbols: base.symbols), includedBasePaths: [path])
        #expect(overlapping?.first?.status == "partial")
        #expect(overlapping?.first?.limitations.contains("overlapping-unscanned-file-capture") == true)
        #expect(CartographService.augmentedEnumImpactFiles(
            base: base, supplemental: .init(), includedBasePaths: [])?.isEmpty == true)
    }

    @Test("값 흐름 경로 정규화도 enum 위치와 근거를 함께 보존한다")
    func valueFlowNormalizationPreservesFacts() throws {
        let raw = snapshot(root: "/p/Folder/..")
        let loader = ValueFlowSourceLoader(fileSystem: InMemoryFileSystem(),
            projectPath: "/p", pathFilter: .passthrough)
        let result = loader.load(snapshot: raw, sourceSnapshot: [:]).snapshot
        let file = try #require(result.enumImpactFiles?.first)
        #expect(file.path == "/p/Included.swift")
        #expect(file.inventories.first?.location.path == "/p/Included.swift")
        #expect(file.decisions.first?.evidenceLocations.first?.path == "/p/Included.swift")
        #expect(file.decisions.first?.enumUSR == "E")
    }

    private func snapshot(root: String) -> IndexSnapshot {
        let location = CartographCore.SourceLocation(path: "\(root)/Included.swift", line: 1, column: 1)
        let owner = IndexedSymbol(usr: "E", name: "E", kind: .enumType, module: "App", location: location)
        let member = IndexedSymbol(usr: "E.a", name: "a", kind: .enumCase, module: "App",
            location: .init(path: location.path, line: 2, column: 6), parentUSR: "E")
        return .init(symbols: [owner, member], enumImpactFiles: [
            .init(path: location.path, status: "fresh",
                inventories: [.init(enumUSR: "E", caseUSRs: ["E.a"], location: location, complete: true)],
                decisions: [.init(kind: .switchUnknownDefault, location: location,
                    endLocation: .init(path: location.path, line: 8, column: 1), enumUSR: "E",
                    explicitCaseUSRs: ["E.a"], evidenceLocations: [member.location], status: "resolved")]),
        ])
    }
}
