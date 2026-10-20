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

    /// 모듈 순환과 타입 순환이 함께 있는 두 모듈 스냅샷.
    ///
    /// `Core.Store` 에서 나가는 간선은 다른 파일의 익스텐션 멤버(`Store.show`)에 있다. 구성원 기준 범위가
    /// 익스텐션 파일만 바뀐 경우도 순환에 넣는지 보려는 것이다. `Util` 은 순환 밖의 같은 모듈 선언이고,
    /// `Other.Tool` 은 순환 밖 모듈의 선언이다.
    private func twoModuleSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("Store", kind: .classType, module: "Core", path: "/p/Core/Store.swift")
        builder.symbol("StoreScreen", kind: .extensionDeclaration, module: "Core", path: "/p/Core/Store+Screen.swift")
        builder.reference(from: "StoreScreen", to: "Store", kind: .extends)
        builder.symbol(
            "Store.show", kind: .method, module: "Core", path: "/p/Core/Store+Screen.swift", parent: "StoreScreen"
        )
        builder.symbol("Util", kind: .structType, module: "Core", path: "/p/Core/Util.swift")
        builder.symbol("Screen", kind: .structType, module: "Feature", path: "/p/Feature/Screen.swift")
        builder.symbol("Tool", kind: .structType, module: "Other", path: "/p/Other/Tool.swift")
        builder.reference(from: "Store.show", to: "Screen", kind: .call)
        builder.reference(from: "Screen", to: "Store", kind: .call)
        return builder.build()
    }

    private func service(
        configure: (inout CartographConfiguration) -> Void = { _ in },
        provider: (any IndexProviding)? = nil,
        fileSystem: InMemoryFileSystem = InMemoryFileSystem(),
        reportScope: ReportScope? = nil
    ) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configure(&configuration)
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: provider ?? StaticIndexProvider(snapshot())
            ),
            reportScope: reportScope
        )
    }

    @Test("cycles --since 도 대표 정점이 아닌 구성원만 바뀐 순환을 숨기지 않는다",
          arguments: [GraphLevel.file, .type, .symbol])
    func cyclesSinceIncludesCycleWhenAnyParticipantChanges(level: GraphLevel) throws {
        // 대표 경로는 정렬상 앞선 정점에서 시작한다. 진단 위치 하나로 거르면 반대쪽 파일에서 순환을 닫은
        // PR 이 `cycles --level type --since … --strict` 를 0 으로 통과하고, 같은 PR 의 check 만 실패했다.
        for changed in ["/p/Feature/A.swift", "/p/Feature/B.swift"] {
            let outcome = try service(reportScope: ReportScope(files: [changed])).detectCycles(level: level)
            #expect(outcome.findingCount == 1, "changed \(changed)")
        }
        let untouched = try service(reportScope: ReportScope(files: ["/p/Feature/Dead.swift"]))
            .detectCycles(level: level)
        #expect(untouched.findingCount == 0)
    }

    @Test("cycles --since 는 대표 경로 밖의 강결합 요소 구성원만 바뀌어도 그 요소의 순환을 보고한다",
          arguments: [GraphLevel.file, .type])
    func cyclesSinceCountsTheWholeComponent(level: GraphLevel) throws {
        // A ↔ B 가 가장 짧은 대표 순환이고 C 는 A → B → C → A 로만 같은 요소에 든다. check 와 같이
        // 요소 전체를 보므로 C.swift 만 바꾼 PR 에도 그 요소의 순환이 남는다.
        var builder = SnapshotBuilder()
        for name in ["A", "B", "C"] {
            builder.symbol(name, kind: .structType, module: "Feature", path: "/p/Feature/\(name).swift")
        }
        builder.reference(from: "A", to: "B", kind: .call)
        builder.reference(from: "B", to: "A", kind: .call)
        builder.reference(from: "B", to: "C", kind: .call)
        builder.reference(from: "C", to: "A", kind: .call)
        let scoped = service(
            provider: StaticIndexProvider(builder.build()),
            reportScope: ReportScope(files: ["/p/Feature/C.swift"])
        )
        let (_, found) = scoped.cycles(in: try scoped.loadContext(), level: level)
        #expect(found.count == 1)
        #expect(found.first?.path.count == 2)
        #expect(found.first?.component.count == 3)
        #expect(try scoped.detectCycles(level: level).findingCount == 1)
    }

    @Test("cycles --since 의 모듈 순환은 구성원 모듈에 바뀐 파일이 있을 때만 보고한다")
    func cyclesSinceScopesModuleCyclesByMemberModules() throws {
        // 모듈 정점에는 위치가 없어 예전에는 범위와 상관없이 모든 모듈 순환을 보고했다. 구성원 기준이면
        // 순환 밖 모듈만 바꾼 PR 에는 들어오지 않고, 구성원 모듈의 어느 파일을 바꿔도 들어온다.
        let provider = StaticIndexProvider(twoModuleSnapshot())
        let counts = try [["/p/Other/Tool.swift"], ["/p/Core/Util.swift"], ["/p/Feature/Screen.swift"], []].map {
            try service(provider: provider, reportScope: ReportScope(files: Set($0)))
                .detectCycles(level: .module).findingCount
        }
        #expect(counts == [0, 1, 1, 0])
        #expect(try service(provider: provider).detectCycles(level: .module).findingCount == 1)
    }

    @Test("같은 범위에서 cycles --since 와 check 가 같은 모듈·타입 순환 진단을 낸다", arguments: [
        nil, [], ["/p/Core/Store.swift"], ["/p/Feature/Screen.swift"], ["/p/Core/Store+Screen.swift"],
        ["/p/Core/Util.swift"], ["/p/Other/Tool.swift"], ["/p/Unknown.swift"],
    ] as [[String]?])
    func cyclesSinceMatchesCheck(changedFiles: [String]?) throws {
        struct CycleReport: Decodable { let diagnostics: [Diagnostic] }
        let service = service(
            configure: { $0.reportFormat = .json },
            provider: StaticIndexProvider(twoModuleSnapshot()),
            reportScope: changedFiles.map { ReportScope(files: Set($0)) }
        )
        let document = try service.checkDocument()
        var cycleDiagnostics: [Diagnostic] = []
        for level in [GraphLevel.module, .type] {
            let outcome = try service.detectCycles(level: level)
            let summary = document.checks.first { $0.name == "cycles" && $0.level == level.rawValue }
            #expect(summary?.findingCount == outcome.findingCount, "\(level)")
            #expect(summary?.suppressedCount == outcome.suppressedCount, "\(level)")
            cycleDiagnostics += try JSONDecoder().decode(CycleReport.self, from: Data(outcome.output.utf8)).diagnostics
        }
        #expect(cycleDiagnostics.sorted() == document.diagnostics.filter {
            $0.ruleIdentifier == AnalysisDiagnostics.Rule.cycle
        })
    }

    @Test("cycles --since 는 구성원 기준으로 범위를 좁힌 뒤 베이스라인과 임계값을 적용한다")
    func cyclesSinceScopesBeforeBaselineAndThreshold() throws {
        let fileSystem = InMemoryFileSystem()
        let recorder = service(fileSystem: fileSystem)
        let (graph, found) = recorder.cycles(in: try recorder.loadContext(), level: .type)
        try BaselineStore(fileSystem: fileSystem).write(
            Baseline.capturing(AnalysisDiagnostics.diagnostics(for: found, in: graph)), to: "/p/baseline.json"
        )
        func scoped(
            _ changed: String, _ configure: (inout CartographConfiguration) -> Void
        ) throws -> CommandOutcome {
            try service(configure: configure, fileSystem: fileSystem, reportScope: ReportScope(files: [changed]))
                .detectCycles(level: .type)
        }
        // 범위 안에 든 순환만 억제 건수에 들어간다. 범위 밖 순환까지 세면 사용자가 보는 숫자와 맞지 않는다.
        for changed in ["/p/Feature/A.swift", "/p/Feature/B.swift"] {
            let baselined = try scoped(changed) { $0.baselinePath = "/p/baseline.json" }
            #expect(baselined.findingCount == 0, "changed \(changed)")
            #expect(baselined.suppressedCount == 1, "changed \(changed)")
            #expect(try scoped(changed) { $0.thresholds.maxCycles = 0 }.thresholdFailure != nil, "changed \(changed)")
        }
        #expect(try scoped("/p/Feature/Dead.swift") { $0.baselinePath = "/p/baseline.json" }.suppressedCount == 0)
        #expect(try scoped("/p/Feature/Dead.swift") { $0.thresholds.maxCycles = 0 }.thresholdFailure == nil)
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

    @Test("baseline 이 기록한 기존 타입 순환은 통합 점검과 타입 순환 검사를 다시 실패시키지 않는다")
    func baselineRecordsTheTypeCyclesThatCheckSuppresses() throws {
        // 순환 지문은 정점 ID 라 모듈 이름 기록은 타입 USR 진단과 절대 맞지 않는다. 기본 설정(module)
        // 레벨만 거두면 Swift 에서 실제로 생기는 타입 순환이 baseline 뒤에도 check --strict 를 계속 세운다.
        let fileSystem = InMemoryFileSystem()
        let recorder = service(fileSystem: fileSystem)
        _ = try recorder.writeBaseline(diagnostics: try recorder.collectAllDiagnostics(), to: "/p/baseline.json")

        let baselined = service(configure: { $0.baselinePath = "/p/baseline.json" }, fileSystem: fileSystem)
        let document = try baselined.checkDocument()
        #expect(document.findingCount == 0)
        #expect(document.checks.first { $0.name == "cycles" && $0.level == "type" }?.suppressedCount == 1)
        #expect(try baselined.detectCycles(level: .type).findingCount == 0)
    }

    @Test("설정 레벨이 file·symbol 이면 그 레벨 순환도 기록하고 같은 지문은 한 번만 담는다",
          arguments: [GraphLevel.file, .symbol])
    func baselineRecordsTheConfiguredCycleLevelOnce(level: GraphLevel) throws {
        let fileSystem = InMemoryFileSystem()
        let recorder = service(configure: { $0.level = level }, fileSystem: fileSystem)
        let diagnostics = try recorder.collectAllDiagnostics()
        // 심볼 레벨 순환은 같은 두 타입 사이라면 타입 순환과 지문이 같다.
        let cycles = diagnostics.filter { $0.ruleIdentifier == AnalysisDiagnostics.Rule.cycle }
        #expect(Set(cycles.map(\.fingerprint)).count == cycles.count)
        _ = try recorder.writeBaseline(diagnostics: diagnostics, to: "/p/baseline.json")

        let baselined = service(
            configure: {
                $0.level = level
                $0.baselinePath = "/p/baseline.json"
            },
            fileSystem: fileSystem
        )
        #expect(try baselined.detectCycles().findingCount == 0)
        #expect(try baselined.checkDocument().findingCount == 0)
    }

    @Test("순환 설명도 베이스라인이 억제한 순환을 발견으로 세지 않는다")
    func explainCyclesFollowsTheBaseline() throws {
        // 같은 베이스라인인데 cycles --strict 는 0, cycles --explain --strict 는 1 로 끝나면
        // "이 정점이 아직 게이트에 걸리는가"를 묻는 스크립트가 반대 판정을 받는다.
        let fileSystem = InMemoryFileSystem()
        let recorder = service(fileSystem: fileSystem)
        let unbaselined = try recorder.explainCycles(of: "FeatureA", level: .type)
        #expect(unbaselined.findingCount == 1)
        let (graph, found) = recorder.cycles(in: try recorder.loadContext(), level: .type)
        try BaselineStore(fileSystem: fileSystem).write(
            Baseline.capturing(AnalysisDiagnostics.diagnostics(for: found, in: graph)), to: "/p/baseline.json"
        )

        let baselined = service(configure: { $0.baselinePath = "/p/baseline.json" }, fileSystem: fileSystem)
        let explained = try baselined.explainCycles(of: "FeatureA", level: .type)
        #expect(explained.findingCount == 0)
        #expect(explained.suppressedCount == 1)
        #expect(try baselined.detectCycles(level: .type).findingCount == explained.findingCount)
        // 판정만 맞춘다. 억제된 순환도 어디를 끊을지 알려 주는 설명은 그대로다.
        #expect(explained.output == unbaselined.output)
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
