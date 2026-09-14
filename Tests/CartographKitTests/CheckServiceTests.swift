import CartographAnalysis
import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("통합 CI 점검")
struct CheckServiceTests {
    @Test("순환의 대표 정점이 아닌 구성원을 고쳐도 통합 점검에서 순환을 숨기지 않는다")
    func includesCycleWhenOtherParticipantChanges() throws {
        let service = CartographService(configuration: {
            var config = CartographConfiguration.default
            config.projectPath = "/p"
            return config
        }(), environment: .init(fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(snapshot())),
            reportScope: ReportScope(files: ["/p/Feature/B.swift"]))
        let document = try service.checkDocument()
        #expect(document.checks.first { $0.name == "cycles" && $0.level == "type" }?.findingCount == 1)
        #expect(document.diagnostics.contains { $0.ruleIdentifier == AnalysisDiagnostics.Rule.cycle })
        #expect(document.limitations.contains { $0.hasPrefix("scoped-diagnostics:") })
    }

    private func snapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("FeatureA", kind: .structType, module: "Feature", path: "/p/Feature/A.swift")
        builder.symbol("FeatureB", kind: .structType, module: "Feature", path: "/p/Feature/B.swift")
        builder.symbol("Dead", kind: .structType, module: "Feature", path: "/p/Feature/Dead.swift")
        builder.reference(from: "FeatureA", to: "FeatureB", kind: .call)
        builder.reference(from: "FeatureB", to: "FeatureA", kind: .call)
        return builder.build()
    }

    private func service(
        configure: (inout CartographConfiguration) -> Void = { _ in },
        provider: (any IndexProviding)? = nil,
        fileSystem: InMemoryFileSystem = InMemoryFileSystem()
    ) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configure(&configuration)
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: provider ?? StaticIndexProvider(snapshot())
            )
        )
    }

    @Test("하나의 인덱스 문맥으로 타입 순환까지 점검한다")
    func checksTypeCyclesWithOneIndexRead() throws {
        let provider = CountingProvider(snapshot: snapshot())
        let document = try service(provider: provider).checkDocument()

        #expect(provider.loadCount == 1)
        #expect(document.checks.map(\.name) == ["dead", "cycles", "cycles", "rules"])
        #expect(document.checks.map(\.level) == ["symbol", "module", "type", "module"])
        #expect(document.checks[1].findingCount == 0)
        #expect(document.checks[2].findingCount == 1)
        #expect(document.diagnostics.contains { $0.ruleIdentifier == AnalysisDiagnostics.Rule.cycle })
    }

    @Test("베이스라인과 변경 파일 범위를 각 점검에 함께 적용한다")
    func appliesBaselineAndScopeToCombinedChecks() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Feature/A.swift": "struct FeatureA {}",
            "/p/Feature/B.swift": "struct FeatureB {}",
            "/p/Feature/Dead.swift": "struct Dead {}",
        ])
        let initial = service(fileSystem: fileSystem)
        let baseline = Baseline.capturing(try initial.checkDocument().diagnostics.filter {
            $0.ruleIdentifier == AnalysisDiagnostics.Rule.cycle
        })
        try BaselineStore(fileSystem: fileSystem).write(baseline, to: "/p/baseline.json")
        // 순환의 첫 선언이 범위 안에 있어 같은 진단에 범위와 베이스라인을 모두 적용한다.
        // 범위 밖의 진단이 통합 결과로 새어 들어오면 안 된다.
        let scopedService = CartographService(
            configuration: {
                var config = CartographConfiguration.default
                config.projectPath = "/p"
                config.baselinePath = "/p/baseline.json"
                return config
            }(),
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(snapshot())
            ),
            reportScope: ReportScope(files: ["/p/Feature/A.swift"])
        )
        let document = try scopedService.checkDocument()
        #expect(document.suppressedCount > 0)
        #expect(document.diagnostics.map(\.subject) == ["FeatureA"])
        #expect(document.diagnostics.map(\.location?.path) == ["Feature/A.swift"])
    }

    @Test("임계값 초과를 문서와 명령 결과에 함께 남긴다")
    func reportsThresholdFailure() throws {
        let service = service { $0.thresholds.maxCycles = 0 }
        let document = try service.checkDocument()
        let outcome = try service.check()

        #expect(document.thresholdFailures.count == 1)
        #expect(document.thresholdFailures.first?.level == "type")
        #expect(outcome.thresholdFailure != nil)
        #expect(outcome.findingCount > 0)
    }

    @Test("빈 인덱스는 허용하지 않으면 통과로 위장하지 않는다")
    func rejectsEmptyIndex() {
        let service = CartographService(
            configuration: {
                var configuration = CartographConfiguration.default
                configuration.projectPath = "/p"
                return configuration
            }(),
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(IndexSnapshot())
            )
        )
        #expect(throws: CartographError.self) { try service.checkDocument() }
    }

    @Test("JSON 통합 점검은 같은 입력에서 결정적이다")
    func jsonIsDeterministic() throws {
        let service = service { $0.reportFormat = .json }
        let first = try service.check().output
        let second = try service.check().output
        #expect(first == second)
        #expect(first.contains("project-check"))
    }
}

private final class CountingProvider: IndexProviding, @unchecked Sendable {
    private let snapshot: IndexSnapshot
    private let lock = NSLock()
    private var count = 0

    init(snapshot: IndexSnapshot) { self.snapshot = snapshot }

    var loadCount: Int { lock.withLock { count } }

    func loadSnapshot() throws -> IndexSnapshot {
        lock.withLock { count += 1 }
        return snapshot
    }
}
