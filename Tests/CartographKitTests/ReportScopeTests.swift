import CartographCore
@testable import CartographKit
import CartographTestSupport
import Testing

@Suite("보고 범위")
struct ReportScopeTests {
    @Test("줄 범위만 바뀌어도 팩토리 세션을 갱신하고 파일 생성자 함수 참조도 유지한다")
    func refreshesSessionWhenOnlyLinesChange() throws {
        var builder = SnapshotBuilder()
        builder.symbol("Dead", kind: .structType, path: "/p/A.swift", line: 10)
        let snapshot = builder.build()
        let environment = CartographEnvironment(
            fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(snapshot),
            usesSyntaxCache: false)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        var scope = ReportScope(files: ["/p/A.swift"], changedLines: ["/p/A.swift": []])
        func service() -> CartographService {
            CartographService(configuration: configuration, environment: environment, reportScope: scope)
        }
        let emptyFingerprint = try service().sessionInputFingerprint()
        let session = try AnalysisSession(serviceFactory: service)
        #expect(try session.check().diagnostics.isEmpty)
        #expect(session.metadata?.generation == 1)
        scope = ReportScope(files: ["/p/A.swift"], changedLines: ["/p/A.swift": [10...10, 20...22]])
        #expect(try service().sessionInputFingerprint() != emptyFingerprint)
        #expect(try session.check().diagnostics.count == 1)
        #expect(session.metadata?.generation == 2)
        let selectedFingerprint = try service().sessionInputFingerprint()
        scope = ReportScope(files: ["/p/./A.swift"], changedLines: ["/p/A.swift": [20...22, 10...10]])
        #expect(try service().sessionInputFingerprint() == selectedFingerprint)
        let fileFactory: (Set<String>) -> ReportScope = ReportScope.init(files:)
        scope = fileFactory(["/p/A.swift"])
        #expect(try service().sessionInputFingerprint() != selectedFingerprint)
        #expect(try session.check().diagnostics.count == 1)
        #expect(session.metadata?.generation == 3)
    }

    @Test("줄 필터는 현재 위치만 고르고 위치 불명과 파일 대체 범위는 남긴다")
    func changedLineLocations() {
        let scope = ReportScope(files: ["/p/./A.swift", "/p/B.swift", "/p/Delete.swift"],
                                changedLines: ["/p/A.swift": [3...4, 7...7], "/p/Delete.swift": []])
        func at(_ path: String, _ line: Int) -> Diagnostic {
            Diagnostic(ruleIdentifier: "unused-symbol", severity: .warning, message: "m",
                       location: SourceLocation(path: path, line: line, column: 1), subject: "s")
        }
        #expect(scope.includes(at("/p/A.swift", 3)))
        #expect(scope.includes(at("/p/./A.swift", 4)))
        #expect(scope.includes(at("/p/A.swift", 7)))
        #expect(!scope.includes(at("/p/A.swift", 2)))
        #expect(!scope.includes(at("/p/A.swift", 5)))
        #expect(scope.includes(at("/p/A.swift", 0)))
        #expect(scope.includes(at("/p/B.swift", 90)))
        #expect(!scope.includes(at("/p/Other.swift", 3)))
        #expect(!scope.includes(at("/p/Delete.swift", 1)))
        #expect(scope.includes(diagnostic(path: nil)))
    }

    private func diagnostic(path: String?) -> Diagnostic {
        Diagnostic(
            ruleIdentifier: "unused-symbol",
            severity: .warning,
            message: "m",
            location: path.map { SourceLocation(path: $0, line: 1, column: 1) },
            subject: path ?? "none"
        )
    }

    @Test("범위 안의 파일만 남긴다")
    func keepsOnlyScopedFiles() {
        let scope = ReportScope(files: ["/p/New.swift"])
        let kept = scope.filtering([diagnostic(path: "/p/New.swift"), diagnostic(path: "/p/Old.swift")])
        #expect(kept.map(\.subject) == ["/p/New.swift"])
    }

    @Test("위치가 없는 발견은 남긴다")
    func keepsDiagnosticsWithoutALocation() {
        // 어느 파일의 것인지 모른다고 숨기면, 사용자는 무엇이 걸러졌는지도 모른 채
        // "문제 없음"을 보게 된다.
        let scope = ReportScope(files: ["/p/New.swift"])
        #expect(scope.filtering([diagnostic(path: nil)]).count == 1)
    }

    @Test("범위를 주지 않으면 전부 보고한다")
    func reportsEverythingWithoutAScope() throws {
        var builder = SnapshotBuilder()
        builder.symbol("Used", kind: .structType, path: "/p/A.swift", attributes: [.entryPoint])
        builder.symbol("Dead", kind: .structType, path: "/p/B.swift")
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let environment = CartographEnvironment(
            fileSystem: InMemoryFileSystem(),
            indexProviderOverride: StaticIndexProvider(builder.build()),
            usesSyntaxCache: false
        )
        let all = try CartographService(configuration: configuration, environment: environment)
            .detectUnusedCode()
        #expect(all.findingCount == 1)

        let scoped = try CartographService(
            configuration: configuration,
            environment: environment,
            reportScope: ReportScope(files: ["/p/A.swift"])
        ).detectUnusedCode()
        #expect(scoped.findingCount == 0)
    }
}
