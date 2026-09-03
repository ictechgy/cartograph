import CartographCore
@testable import CartographKit
import CartographTestSupport
import Testing

@Suite("보고 범위")
struct ReportScopeTests {
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
