import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("분석 한계 수집")
struct AnalysisLimitationCollectorTests {
    @Test("범위에 헤더가 없으면 헤더 투영 경고를 만들지 않는다")
    func headerProjectionDoesNotInventAbsentHeaders() {
        let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": ""])
        let result = collector(fileSystem).collect(context: nil, symbolGraph: nil, emptyIndexCounts: nil)
        #expect(!result.contains { $0.hasPrefix("header-projection:") })
    }

    @Test("실제 읽은 헤더 레코드만 투영 경고에서 빼고 신선도·미관측 헤더 한계는 유지한다")
    func onlyAdmittedHeadersClearProjectionWarning() {
        let old = Date(timeIntervalSince1970: 1_000)
        let fileSystem = InMemoryFileSystem(files: ["/p/Read.h": "", "/p/FileOnly.h": "", "/p/NeverBuilt.h": ""])
        fileSystem.setModificationDate(old.addingTimeInterval(10), for: "/p/Read.h")
        let snapshot = IndexSnapshot(indexedFileDates: ["/p/Read.h": old, "/p/FileOnly.h": old],
            admittedHeaderPaths: ["/p/Read.h"])
        let result = collector(fileSystem).collect(context: AnalysisContext(snapshot: snapshot),
            symbolGraph: nil, emptyIndexCounts: nil)
        let projection = result.first { $0.hasPrefix("header-projection:") } ?? ""
        #expect(projection.hasPrefix("header-projection: 2 "))
        #expect(projection.contains("FileOnly.h") && projection.contains("NeverBuilt.h"))
        #expect(!projection.contains("Read.h"))
        #expect(result.contains { $0.hasPrefix("index-staleness:") && $0.contains("Read.h") })
        #expect(result.contains { $0.hasPrefix("unindexed-sources:") && $0.contains("NeverBuilt.h") })
        let legacy = IndexSnapshot(indexedFileDates: snapshot.indexedFileDates)
        let legacyResult = collector(fileSystem).collect(context: AnalysisContext(snapshot: legacy),
            symbolGraph: nil, emptyIndexCounts: nil)
        #expect(legacyResult.contains { $0.hasPrefix("header-projection: 3 ") })
    }

    @Test("한 문맥만 재빌드하면 최신 시각이 다른 문맥의 낡은 소스를 가리지 않는다")
    func partialContextCoverageRemainsStale() {
        let old = Date(timeIntervalSince1970: 1_000)
        let fileSystem = InMemoryFileSystem(files: ["/p/Shared.swift": ""])
        fileSystem.setModificationDate(old.addingTimeInterval(50), for: "/p/Shared.swift")
        let snapshot = IndexSnapshot(indexedFileDates: ["/p/Shared.swift": old.addingTimeInterval(100)],
            oldestIndexedFileDates: ["/p/Shared.swift": old])
        let result = collector(fileSystem).collect(context: AnalysisContext(snapshot: snapshot),
            symbolGraph: nil, emptyIndexCounts: nil)
        #expect(result.contains { $0.hasPrefix("index-staleness: 1 of 1") && $0.contains("Shared.swift") })
        let legacy = IndexSnapshot(indexedFileDates: snapshot.indexedFileDates)
        let legacyResult = collector(fileSystem).collect(context: AnalysisContext(snapshot: legacy),
            symbolGraph: nil, emptyIndexCounts: nil)
        #expect(!legacyResult.contains { $0.hasPrefix("index-staleness:") })
    }

    @Test("경고 경로의 줄바꿈·따옴표·방향 제어 문자는 출력 행을 바꾸지 않는다")
    func diagnosticPathsEscapeControls() throws {
        let path = "/p/A\n\"B\u{202E}.swift"
        let fileSystem = InMemoryFileSystem(files: [path: ""])
        let context = AnalysisContext(snapshot: IndexSnapshot(indexedFileDates: [:]))
        let result = collector(fileSystem).collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)
        let warning = result.first { $0.hasPrefix("unindexed-sources:") } ?? ""
        #expect(warning.contains("paths:"))
        #expect(!warning.contains("\n") && !warning.contains("\u{202E}"))
        #expect(warning.contains("\\n") && warning.contains("\\\"") && warning.contains("\\u202E"))
        let encoded = try #require(warning.components(separatedBy: "; paths: ").last)
        #expect(try JSONDecoder().decode([String].self, from: Data(encoded.utf8)) == [String(path.dropFirst(3))])
    }

    @Test("많은 경고 경로는 결정적인 앞 64개와 생략 수를 내보내고 전체 개수는 유지한다")
    func diagnosticPathCountIsBounded() throws {
        let paths = (0..<100).map { String(format: "/p/Sources/File%03d.swift", $0) }
        let fileSystem = InMemoryFileSystem(files: Dictionary(uniqueKeysWithValues: paths.map { ($0, "") }))
        let context = AnalysisContext(snapshot: IndexSnapshot(indexedFileDates: [:]), missingSourcePaths: paths)
        let result = collector(fileSystem).collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)
        for prefix in ["unindexed-sources: 100 of 100", "missing-sources: 100"] {
            let warning = try #require(result.first { $0.hasPrefix(prefix) })
            #expect(warning.hasSuffix("; omitted-paths: 36"))
            let encoded = warning.components(separatedBy: "; paths: ")[1]
                .components(separatedBy: "; omitted-paths: ")[0]
            let displayed = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
            #expect(displayed == Array(paths.prefix(64)).map { String($0.dropFirst(3)) })
        }
    }

    @Test("긴 유니코드와 제어 문자 경로는 이스케이프 후 UTF-8 예산을 지키며 생략을 알린다")
    func diagnosticPathByteBudgetIncludesEscapes() throws {
        for tail in [String(repeating: "😀", count: 3_000), String(repeating: "\u{202E}", count: 2_000)] {
            let path = "/p/Z" + tail + ".swift"
            let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": "", path: ""])
            let result = collector(fileSystem).collect(
                context: AnalysisContext(snapshot: IndexSnapshot(indexedFileDates: [:])),
                symbolGraph: nil, emptyIndexCounts: nil)
            let warning = try #require(result.first { $0.hasPrefix("unindexed-sources: 2 of 2") })
            #expect(warning.hasSuffix("; paths: [\"A.swift\"]; omitted-paths: 1"))
            #expect(warning.utf8.count < AnalysisLimitationCollector.maximumDiagnosticPathBytes)
            #expect(!warning.contains("\u{202E}"))
        }
    }

    @Test("신선도와 누락 경고는 관련된 프로젝트 상대 경로만 안전하게 식별한다")
    func diagnosticsIdentifyOnlyRelevantScopedPaths() {
        let old = Date(timeIntervalSince1970: 1_000)
        let fileSystem = InMemoryFileSystem(files: ["/p/Sources/API.h": "", "/p/Sources/New.swift": "",
            "/p/Excluded/Private.h": ""])
        fileSystem.setModificationDate(old.addingTimeInterval(50), for: "/p/Sources/API.h")
        let context = AnalysisContext(snapshot: IndexSnapshot(indexedFileDates: ["/p/Sources/API.h": old]),
            missingSourcePaths: ["/p/Sources/Deleted.swift", "/private/Secret.h", "/p/Excluded/Private.h"])
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.include = ["Sources/**"]
        let result = AnalysisLimitationCollector(configuration: configuration, fileSystem: fileSystem,
            projectPath: "/p", storeDate: nil).collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)
        #expect(result.contains { $0.hasPrefix("index-staleness:") && $0.contains("Sources/API.h") })
        #expect(result.contains { $0.hasPrefix("header-projection: 1 ") && $0.contains("Sources/API.h") })
        #expect(result.contains { $0.hasPrefix("unindexed-sources:") && $0.contains("Sources/New.swift") })
        #expect(result.contains { $0.hasPrefix("missing-sources:") && $0.contains("Sources/Deleted.swift") })
        #expect(result.allSatisfy { !$0.contains("/private/") && !$0.contains("Excluded/") && !$0.contains("/p/") })
    }

    @Test("한 번의 수집은 경로마다 정규화를 한 번만 하고 모든 판정과 진단 경로가 같은 정규 경로를 쓴다")
    func canonicalizesEachPathOnce() {
        // 정규화는 경로 구성 요소마다 파일 시스템을 거친다. 소스 하나가 신선도·색인 여부·헤더 판정·진단 경로에
        // 거듭 쓰이므로, 자리마다 부르면 같은 경로를 여러 번 묻는다.
        let old = Date(timeIntervalSince1970: 1_000)
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Sources/Fresh.swift": "", "/p/Sources/Stale.swift": "", "/p/Sources/New.swift": "",
            "/p/Sources/API.h": "",
        ])
        for path in ["/p/Sources/Fresh.swift", "/p/Sources/New.swift", "/p/Sources/API.h"] {
            fileSystem.setModificationDate(old, for: path)
        }
        fileSystem.setModificationDate(old.addingTimeInterval(50), for: "/p/Sources/Stale.swift")
        let snapshot = IndexSnapshot(indexedFileDates: [
            "/p/Sources/Fresh.swift": old, "/p/Sources/Stale.swift": old, "/p/Sources/API.h": old,
        ], admittedHeaderPaths: ["/p/Sources/Other.h"])
        let context = AnalysisContext(snapshot: snapshot, missingSourcePaths: ["/p/Sources/Gone.swift"],
            unreadableSourcePaths: ["/p/Sources/Locked.swift"])
        var calls: [String: Int] = [:]
        var collector = collector(fileSystem)
        // 표기를 바꾸는 정규화다. 우회한 자리가 있으면 원래 표기가 진단에 남는다.
        collector.canonicalize = { path in
            calls[path, default: 0] += 1
            return path.replacingOccurrences(of: "/Sources/", with: "/Real/")
        }

        let result = collector.collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)

        #expect(calls == Dictionary(uniqueKeysWithValues: [
            "Fresh.swift", "Stale.swift", "New.swift", "API.h", "Other.h", "Gone.swift", "Locked.swift",
        ].map { ("/p/Sources/" + $0, 1) }))
        #expect(result.contains { $0.hasPrefix("index-staleness: 1 of 4") && $0.contains("[\"Real/Stale.swift\"]") })
        #expect(result.contains { $0.hasPrefix("unindexed-sources: 1 of 4") && $0.contains("[\"Real/New.swift\"]") })
        #expect(result.contains { $0.hasPrefix("header-projection: 1 ") && $0.contains("[\"Real/API.h\"]") })
        #expect(result.contains { $0.hasPrefix("missing-sources: 1 ") && $0.contains("[\"Real/Gone.swift\"]") })
        #expect(result.contains { $0.hasPrefix("unreadable-sources: 1 ") && $0.contains("[\"Real/Locked.swift\"]") })
        #expect(result.allSatisfy { !$0.contains("Sources/") })
    }

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

    @Test("Clang 소스와 헤더도 파일별 신선도와 누락을 함께 센다", arguments: [false, true])
    func clangCoverageIncludesHeaders(withInventory: Bool) {
        let old = Date(timeIntervalSince1970: 1_000)
        let paths = ["/p/A.swift", "/p/B.m", "/p/C.mm", "/p/D.h"]
        let fileSystem = InMemoryFileSystem(files: Dictionary(uniqueKeysWithValues: paths.map { ($0, "") }))
        for path in paths { fileSystem.setModificationDate(old.addingTimeInterval(50), for: path) }
        let context = AnalysisContext(snapshot: IndexSnapshot(indexedFileDates: ["/p/A.swift": old, "/p/B.m": old]))
        let configuration = CartographConfiguration(projectPath: "/p")
        let inventory = withInventory ? ProjectFileInventory(
            fileSystem: fileSystem, projectPath: "/p", pathFilter: configuration.pathFilter) : nil
        let result = AnalysisLimitationCollector(configuration: configuration, fileSystem: fileSystem,
            projectPath: "/p", storeDate: old.addingTimeInterval(100), inventory: inventory)
            .collect(context: context, symbolGraph: nil, emptyIndexCounts: nil)
        #expect(result.contains { $0.hasPrefix("index-staleness: 2 of 4") })
        #expect(result.contains { $0.hasPrefix("unindexed-sources: 2 of 4") })
    }

    @Test("소스별 신선도 변경이 외부 보존 파일의 비교 기준까지 바꾸지 않는다")
    func externalRetentionsKeepTheirStoreDateComparison() {
        let store = "/p/.build/index/store"
        let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": "", store + "/v5/units/unit": ""])
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 2_000), for: store + "/v5/units")
        fileSystem.setModificationDate(Date(timeIntervalSince1970: 1_100), for: "/p/A.swift")
        let context = AnalysisContext(
            snapshot: IndexSnapshot(indexedFileDates: ["/p/A.swift": Date(timeIntervalSince1970: 1_000)]),
            externalRetentions: ExternalRetentionsDocument(generatedAt: "1970-01-01T00:25:00Z", retentions: [])
        )
        var config = CartographConfiguration.default
        config.projectPath = "/p"
        config.indexStorePath = store
        let service = CartographService(configuration: config, environment: CartographEnvironment(fileSystem: fileSystem))
        let result = service.analysisLimitations(context: context)
        #expect(result.contains { $0.hasPrefix("index-staleness: 1 of 1") })
        #expect(result.contains { $0.hasPrefix("external-retentions-stale:") })
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

    @Test("cycles·rules·metrics 도 한계를 응답에 싣는다")
    func discoveryCommandsCarryLimitations() throws {
        // 세 명령은 모두 CI 게이트다. Objective-C 소스가 있는데 한계가 없으면,
        // "순환 없음·규칙 위반 없음"이 보지 못하는 채널까지 검사한 답처럼 읽힌다.
        let fileSystem = InMemoryFileSystem(files: ["/p/Handler.m": "", "/p/App.swift": ""])
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, path: "/p/App.swift", attributes: [.entryPoint])
        var config = CartographConfiguration.default
        config.projectPath = "/p"
        config.reportFormat = .json
        let service = CartographService(
            configuration: config,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(builder.build()),
                usesSyntaxCache: false
            )
        )
        for outcome in [try service.detectCycles(), try service.checkRules(), try service.measureMetrics()] {
            #expect(outcome.output.contains("objective-c-sources"))
        }
    }

    @Test("알릴 한계가 없는 실행은 지표 JSON 에 limitations 키를 만들지 않는다")
    func metricsJSONOmitsAbsentLimitations() throws {
        let fileSystem = InMemoryFileSystem(files: ["/p/App.swift": ""])
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, path: "/p/App.swift", attributes: [.entryPoint])
        var config = CartographConfiguration.default
        config.projectPath = "/p"
        config.reportFormat = .json
        let service = CartographService(
            configuration: config,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(builder.build()),
                usesSyntaxCache: false
            )
        )
        let metricsOutput = try service.measureMetrics().output
        #expect(!metricsOutput.contains("\"limitations\""))
    }

    private func collector(_ fileSystem: any FileSystem, storeDate: Date? = nil) -> AnalysisLimitationCollector {
        var config = CartographConfiguration.default
        config.projectPath = "/p"
        return AnalysisLimitationCollector(
            configuration: config, fileSystem: fileSystem, projectPath: "/p", storeDate: storeDate
        )
    }
}
