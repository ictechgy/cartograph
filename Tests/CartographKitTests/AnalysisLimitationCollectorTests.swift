import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("분석 한계 수집")
struct AnalysisLimitationCollectorTests {
    @Test("다른 타깃의 새 유닛이 낡은 파일의 인덱스를 가리지 않는다")
    func partialBuildDoesNotHideStaleFile() {
        let old = Date(timeIntervalSince1970: 1_000)
        let newer = old.addingTimeInterval(100)
        let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": "", "/p/B.swift": ""])
        fileSystem.setModificationDate(old.addingTimeInterval(50), for: "/p/A.swift")
        fileSystem.setModificationDate(old, for: "/p/B.swift")
        let context = AnalysisContext(snapshot: IndexSnapshot(indexedFileDates: [
            "/p/A.swift": old, "/p/B.swift": newer,
        ]))
        let result = collector(fileSystem, storeDate: newer)
            .collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)
        #expect(result.contains { $0.hasPrefix("index-staleness: 1 of 2") })
        #expect(!result.contains { $0.hasPrefix("unindexed-sources:") })
    }

    @Test("파일별 유닛이 없는 소스는 전체 스토어 시각으로 최신인 척하지 않는다")
    func missingUnitIsReportedSeparately() {
        let fileSystem = InMemoryFileSystem(files: ["/p/New.swift": ""])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 500), for: "/p/New.swift")
        let context = AnalysisContext(snapshot: IndexSnapshot(indexedFileDates: [:]))
        let result = collector(fileSystem, storeDate: Date(timeIntervalSince1970: 1_000))
            .collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)
        #expect(result.contains { $0.hasPrefix("unindexed-sources: 1 of 1") })
        #expect(!result.contains { $0.hasPrefix("index-staleness:") })
        let unknown = collector(fileSystem)
            .collect(context: AnalysisContext(snapshot: IndexSnapshot()), symbolGraph: nil, emptyIndexCounts: nil)
        #expect(!unknown.contains { $0.hasPrefix("unindexed-sources:") })
    }

    @Test("루트 매니페스트는 유닛 누락으로 세지 않지만 동명 타깃 소스는 센다")
    func manifestsDoNotCreatePermanentWarnings() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Package.swift": "import PackageDescription",
            "/p/Package@swift-6.0.swift": "import PackageDescription",
            "/p/Sources/Package.swift": "struct Package {}",
        ])
        let context = AnalysisContext(snapshot: IndexSnapshot(indexedFileDates: [:]))
        let result = collector(fileSystem).collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)
        #expect(result.contains { $0.hasPrefix("unindexed-sources: 1 of 1") })
    }

    @Test("누락과 읽기 실패는 분석 범위에 속한 파일만 센다")
    func sourceFailuresRespectScope() {
        var config = CartographConfiguration.default
        config.projectPath = "/p"
        config.include = ["Sources/**"]
        let context = AnalysisContext(
            snapshot: IndexSnapshot(),
            missingSourcePaths: ["/p/Sources/Missing.swift", "/p/Tests/Removed.swift"],
            unreadableSourcePaths: ["/p/Sources/Locked.swift", "/p/Tests/Locked.swift"]
        )
        let result = AnalysisLimitationCollector(
            configuration: config, fileSystem: InMemoryFileSystem(), projectPath: "/p", storeDate: nil
        ).collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)
        #expect(result.contains { $0.hasPrefix("missing-sources: 1 ") })
        #expect(result.contains { $0.hasPrefix("unreadable-sources: 1 ") })
    }

    @Test("읽기 실패는 query의 근거와 notFound와 dead 리포트까지 전달된다")
    func sourceFailureReachesCommandResponses() throws {
        let path = "/p/Service.swift"
        let fileSystem = InMemoryFileSystem(files: [path: "// cartograph:ignore\nstruct Service {}"])
        fileSystem.setReadError(.fileReadNoPermission, for: path)
        var builder = SnapshotBuilder()
        builder.symbol("s:Service", name: "Service", kind: .structType, path: path, line: 2)
        var config = CartographConfiguration.default
        config.projectPath = "/p"
        config.reportFormat = .json
        let service = CartographService(
            configuration: config,
            environment: CartographEnvironment(
                fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(builder.build()), usesSyntaxCache: false
            )
        )
        let document = try service.queryDocument(symbol: "Service")
        #expect(document.result?.reachability.reason == .sourceUnavailable)
        #expect(document.limitations.contains { $0.hasPrefix("unreadable-sources: 1 ") })
        let missing = try service.queryDocument(symbol: "Absent")
        #expect(missing.status == "notFound")
        #expect(missing.limitations.contains { $0.hasPrefix("unreadable-sources: 1 ") })
        let dead = try service.detectUnusedCode()
        #expect(dead.findingCount == 0)
        #expect(dead.output.contains("unreadable-sources: 1 "))
    }

    private func collector(_ fileSystem: any FileSystem, storeDate: Date? = nil) -> AnalysisLimitationCollector {
        var config = CartographConfiguration.default
        config.projectPath = "/p"
        return AnalysisLimitationCollector(
            configuration: config, fileSystem: fileSystem, projectPath: "/p", storeDate: storeDate
        )
    }
}
