import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("분석 파이프라인")
struct CartographServiceTests {
    /// Presentation → Domain → Data 로 흐르고, Data 가 Presentation 을 되참조하는
    /// 작은 프로젝트. 순환·레이어 위반·데드코드를 한 번에 담고 있다.
    private func makeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol(
            "HomeView", kind: .structType, module: "Presentation",
            path: "/p/Features/HomeView.swift", attributes: [.entryPoint]
        )
        builder.symbol("UserService", kind: .classType, module: "Domain", path: "/p/Domain/UserService.swift")
        builder.symbol("UserRepository", kind: .classType, module: "Data", path: "/p/Data/UserRepository.swift")
        builder.symbol("DeadHelper", kind: .structType, module: "Domain", path: "/p/Domain/DeadHelper.swift")
        builder.reference(from: "HomeView", to: "UserService", kind: .call)
        builder.reference(from: "UserService", to: "UserRepository", kind: .call)
        builder.reference(from: "UserRepository", to: "HomeView", kind: .reference)
        return builder.build()
    }

    private func makeService(
        configure: (inout CartographConfiguration) -> Void = { _ in },
        fileSystem: InMemoryFileSystem = InMemoryFileSystem()
    ) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configure(&configuration)
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(makeSnapshot())
            )
        )
    }

    @Test("그래프를 설정된 형식으로 내보낸다")
    func rendersGraph() throws {
        let outcome = try makeService().renderGraph()
        #expect(outcome.output.hasPrefix("digraph Cartograph {"))
        #expect(outcome.output.contains("Presentation"))
        #expect(!outcome.hasFindings)
    }

    @Test("형식과 해상도를 인자로 덮어쓸 수 있다")
    func overridesFormatAndLevel() throws {
        let outcome = try makeService().renderGraph(level: .type, format: .mermaid)
        #expect(outcome.output.hasPrefix("flowchart LR"))
        #expect(outcome.output.contains("HomeView"))
    }

    @Test("순환 의존성을 찾아 보고한다")
    func detectsCycles() throws {
        let outcome = try makeService().detectCycles()
        #expect(outcome.findingCount == 1)
        #expect(outcome.output.contains("Circular dependency"))
        #expect(outcome.output.contains("cycles: 1 error"))
    }

    @Test("임계값을 넘겨도 무엇이 문제인지 먼저 보여 준다")
    func thresholdFailureStillReportsFindings() throws {
        // 임계값을 넘겼다는 사실만 알리고 내용을 숨기면, 사용자는 임계값을 풀고
        // 다시 돌리는 수밖에 없다.
        let outcome = try makeService { $0.thresholds.maxCycles = 0 }.detectCycles()
        #expect(outcome.output.contains("Circular dependency"))
        #expect(outcome.thresholdFailure != nil)
        #expect(outcome.thresholdFailure?.errorDescription?.contains("found 1, allowed at most 0") == true)
    }

    @Test("임계값 안이면 실패 사유가 없다")
    func withinThresholdHasNoFailure() throws {
        let outcome = try makeService { $0.thresholds.maxCycles = 5 }.detectCycles()
        #expect(outcome.thresholdFailure == nil)
        #expect(outcome.hasFindings)
    }

    @Test("도달할 수 없는 선언을 보고한다")
    func detectsUnusedCode() throws {
        let outcome = try makeService().detectUnusedCode()
        #expect(outcome.findingCount == 1)
        #expect(outcome.output.contains("'Domain.DeadHelper' is never used"))
        #expect(outcome.output.contains("reachable"))
    }

    @Test("데드코드 결과는 프로젝트 상대 경로로 보고된다")
    func reportsRelativePaths() throws {
        let outcome = try makeService().detectUnusedCode()
        #expect(outcome.output.contains("Domain/DeadHelper.swift"))
        #expect(!outcome.output.contains("/p/Domain/DeadHelper.swift"))
    }

    @Test("살아 있는 이유를 사람이 읽는 문장으로 설명한다")
    func explainsRetention() throws {
        let service = makeService()
        #expect(try service.explainRetention(of: "HomeView").output
            .contains("is retained because it is declared as an application entry point"))
        #expect(try service.explainRetention(of: "UserRepository").output
            .contains("Presentation.HomeView → Domain.UserService → Data.UserRepository"))

        let dead = try service.explainRetention(of: "DeadHelper")
        #expect(dead.output.contains("not reachable"))
        #expect(dead.hasFindings)
        #expect(try service.explainRetention(of: "없는이름").output.contains("No declaration matches"))
    }

    @Test("아키텍처 지표를 표로 낸다")
    func measuresMetrics() throws {
        let outcome = try makeService().measureMetrics()
        #expect(outcome.output.contains("NODE"))
        #expect(outcome.output.contains("Presentation"))
        #expect(outcome.output.contains("Ca afferent coupling"))
    }

    @Test("지표를 JSON 으로 낼 때 진단을 같은 문서에 담는다")
    func metricsJSONIsSingleDocument() throws {
        // 두 개의 JSON 문서를 이어 붙이면 어떤 파서도 읽지 못한다.
        let service = makeService {
            $0.reportFormat = .json
            $0.thresholds.maxInstability = 0.1
        }
        let outcome = try service.measureMetrics()
        let object = try JSONSerialization.jsonObject(with: Data(outcome.output.utf8)) as? [String: Any]
        #expect(object?["metrics"] != nil)
        #expect(object?["diagnostics"] != nil)
        #expect(outcome.hasFindings)
    }

    @Test("레이어 규칙 위반을 보고한다")
    func checksLayerRules() throws {
        let service = makeService {
            $0.layers = [
                LayerDefinition(name: "Presentation", patterns: ["Presentation"]),
                LayerDefinition(name: "Data", patterns: ["Data"]),
            ]
            $0.rules = [LayerRule(from: "Data", deny: ["Presentation"])]
        }
        let outcome = try service.checkRules()
        #expect(outcome.findingCount == 1)
        #expect(outcome.output.contains("must not depend on Presentation"))
    }

    @Test("레이어 미지정은 정보로만 알리고 임계값에 세지 않는다")
    func unassignedLayersAreInformational() throws {
        let service = makeService {
            $0.layers = [LayerDefinition(name: "Data", patterns: ["Data"])]
            $0.rules = [LayerRule(from: "Data", allow: [])]
            $0.thresholds.maxRuleViolations = 0
        }
        // Presentation 과 Domain 은 레이어가 없지만 그 자체로는 실패가 아니다.
        let outcome = try service.checkRules()
        #expect(outcome.output.contains("does not belong to any layer"))
        #expect(outcome.findingCount == 0)
    }

    @Test("정의되지 않은 레이어를 참조하면 규칙 검사가 실패한다")
    func rulesValidateLayerNames() {
        let service = makeService {
            $0.rules = [LayerRule(from: "Nowhere", deny: ["Data"])]
        }
        #expect(throws: CartographError.self) { try service.checkRules() }
    }

    @Test("베이스라인에 있는 진단은 걸러지고 개수로만 알린다")
    func baselineSuppressesKnownFindings() throws {
        let fileSystem = InMemoryFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let diagnostics = try service.collectAllDiagnostics()
        _ = try service.writeBaseline(diagnostics: diagnostics, to: "/p/baseline.json")

        let withBaseline = makeService(
            configure: { $0.baselinePath = "/p/baseline.json" },
            fileSystem: fileSystem
        )
        let outcome = try withBaseline.detectUnusedCode()
        #expect(outcome.findingCount == 0)
        #expect(outcome.suppressedCount == 1)
        #expect(outcome.output.contains("suppressed by baseline"))
    }

    @Test("베이스라인 파일을 기록한다")
    func writesBaselineFile() throws {
        let fileSystem = InMemoryFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let outcome = try service.writeBaseline(
            diagnostics: try service.collectAllDiagnostics(),
            to: "/p/baseline.json"
        )
        #expect(outcome.output.contains("/p/baseline.json"))
        #expect(fileSystem.fileExists(at: "/p/baseline.json"))
    }

    @Test("모든 명령의 진단을 한 번에 모은다")
    func collectsDiagnosticsFromEveryCommand() throws {
        let service = makeService {
            $0.layers = [
                LayerDefinition(name: "Presentation", patterns: ["Presentation"]),
                LayerDefinition(name: "Data", patterns: ["Data"]),
            ]
            $0.rules = [LayerRule(from: "Data", deny: ["Presentation"])]
        }
        let identifiers = Set(try service.collectAllDiagnostics().map(\.ruleIdentifier))
        #expect(identifiers == ["cycle", "unused-symbol", "layer-violation"])
    }

    @Test("프로젝트 경로가 없으면 현재 디렉터리를 쓴다")
    func fallsBackToCurrentDirectory() {
        let service = CartographService(
            configuration: .default,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(currentDirectoryPath: "/here"),
                indexProviderOverride: StaticIndexProvider(IndexSnapshot())
            )
        )
        #expect(service.projectPath == "/here")
    }

    @Test("인덱스 스토어를 찾지 못하면 안내가 담긴 오류를 낸다")
    func missingIndexStoreIsExplained() {
        let service = CartographService(
            configuration: {
                var configuration = CartographConfiguration.default
                configuration.projectPath = "/p"
                return configuration
            }(),
            environment: CartographEnvironment(fileSystem: InMemoryFileSystem())
        )
        #expect(throws: CartographError.self) { try service.renderGraph() }
    }

    @Test("같은 이름의 정점이 여럿이면 임의로 고르지 않고 후보를 보여 준다")
    func ambiguousNameIsReported() throws {
        // 임의로 하나를 고르면 사용자는 자기가 물어본 것과 다른 답을 받고도 알아채지 못한다.
        var builder = SnapshotBuilder()
        builder.symbol("s:A", name: "Repository", kind: .classType, module: "Data")
        builder.symbol("s:B", name: "Repository", kind: .classType, module: "Domain")
        let service = CartographService(
            configuration: {
                var configuration = CartographConfiguration.default
                configuration.projectPath = "/p"
                return configuration
            }(),
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )
        let outcome = try service.explainRetention(of: "Repository")
        #expect(outcome.output.contains("matches 2 declarations"))
        #expect(outcome.output.contains("s:A"))
        #expect(outcome.output.contains("s:B"))
    }

    @Test("이름으로 찾은 정점이 하나면 그대로 설명한다")
    func uniqueNameResolves() throws {
        let outcome = try makeService().explainRetention(of: "HomeView")
        #expect(outcome.output.contains("is retained because"))
    }

    @Test("인덱스를 한 번만 읽어 모든 진단을 모은다")
    func collectsDiagnosticsWithSingleIndexRead() throws {
        // 인덱스 읽기가 파이프라인에서 가장 느린 단계다. 명령마다 다시 읽으면
        // baseline 처럼 여러 분석을 묶는 경로에서 그 비용이 그대로 반복된다.
        let counting = CountingIndexProvider(snapshot: makeSnapshot())
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: counting
            )
        )
        _ = try service.collectAllDiagnostics()
        #expect(counting.loadCount == 1)
    }

    @Test("지표 임계값 위반도 베이스라인에 기록된다")
    func baselineIncludesMetricFindings() throws {
        // metrics 는 베이스라인을 적용하는데 baseline 이 그것을 기록하지 못하면
        // 영원히 억제할 수 없는 진단이 생긴다.
        let service = makeService {
            $0.thresholds.maxInstability = 0.1
        }
        let identifiers = Set(try service.collectAllDiagnostics().map(\.ruleIdentifier))
        #expect(identifiers.contains("instability"))
    }

    @Test("순환에 낀 정점을 설명한다")
    func explainsCycles() throws {
        // "스무 개가 얽혀 있다"는 보고는 정확하지만 손댈 곳을 알려 주지 않는다.
        // 모듈 레벨 그래프의 정점은 모듈이다. 픽스처는 Presentation → Domain → Data →
        // Presentation 으로 한 바퀴 돈다.
        let service = makeService()
        let explained = try service.explainCycles(of: "Presentation", level: .module)
        #expect(explained.output.contains("Presentation → "))
        #expect(explained.findingCount > 0)

        // 심볼 레벨에서 DeadHelper 는 아무와도 이어져 있지 않다.
        let outside = try service.explainCycles(of: "DeadHelper", level: .symbol)
        #expect(outside.output.contains("not part of any cycle"))
        #expect(outside.findingCount == 0)

        let missing = try service.explainCycles(of: "NoSuchNode", level: .module)
        #expect(missing.subjectNotFound)
    }

    @Test("대표 경로에 없어도 같은 묶음이면 순환에 있다고 말한다")
    func explainsCyclesBeyondTheRepresentativePath() throws {
        // 대표 경로만 보면 같은 강한 연결 요소에 있는 정점에 "순환에 없다"고
        // 거짓말하게 된다. 설명이 틀리는 것은 보고가 틀리는 것보다 나쁘다.
        var builder = SnapshotBuilder()
        for name in ["Alpha", "Beta", "Delta", "Gamma"] {
            builder.symbol(name, kind: .structType, module: name, path: "/p/\(name).swift")
        }
        builder.reference(from: "Alpha", to: "Beta", kind: .call)
        builder.reference(from: "Alpha", to: "Delta", kind: .call)
        builder.reference(from: "Beta", to: "Gamma", kind: .call)
        builder.reference(from: "Delta", to: "Gamma", kind: .call)
        builder.reference(from: "Gamma", to: "Alpha", kind: .call)

        let service = CartographService(
            configuration: {
                var configuration = CartographConfiguration.default
                configuration.projectPath = "/p"
                return configuration
            }(),
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(builder.build()),
                usesSyntaxCache: false
            )
        )
        // 어느 정점을 물어도 순환에 있다고 답해야 한다.
        for name in ["Alpha", "Beta", "Delta", "Gamma"] {
            let explained = try service.explainCycles(of: name, level: .module)
            #expect(explained.findingCount == 1, "\(name) 이 순환 밖으로 판정됐다")
            #expect(!explained.output.contains("not part of any cycle"))
        }
    }

    @Test("정점이 왜 그 레이어인지 설명한다")
    func explainsLayerMembership() throws {
        let service = makeService {
            $0.layers = [LayerDefinition(name: "Presentation", patterns: ["Presentation"])]
            $0.rules = [LayerRule(name: "no data", from: "Presentation", deny: ["Data"])]
        }
        let explained = try service.explainRules(of: "Presentation", level: .module)
        #expect(explained.output.contains("layer 'Presentation'"))
        #expect(explained.output.contains("no data"))

        let orphan = try service.explainRules(of: "Domain", level: .module)
        #expect(orphan.output.contains("belongs to no layer"))

        let missing = try service.explainRules(of: "NoSuchNode", level: .module)
        #expect(missing.subjectNotFound)
    }

    @Test("지표 임계값을 넘기면 --strict 없이도 실패로 표시한다")
    func metricThresholdsFailTheBuild() throws {
        // 같은 설정 파일 안에서 어떤 임계값은 빌드를 세우고 어떤 임계값은 세우지 않으면
        // 사용자는 어느 쪽인지 알 수 없다.
        let service = makeService { $0.thresholds.maxDistanceFromMainSequence = 0.01 }
        let outcome = try service.measureMetrics()
        #expect(outcome.findingCount > 0)
        #expect(outcome.thresholdFailure != nil)

        let relaxed = try makeService { $0.thresholds.maxDistanceFromMainSequence = 1.0 }.measureMetrics()
        #expect(relaxed.thresholdFailure == nil)
    }

    @Test("지표를 SARIF 로 요청하면 진단 형식으로 낸다")
    func metricsHonorMachineDiagnosticFormats() throws {
        // 예전에는 확장자만 .sarif 인 지표 JSON 이 나와 코드 스캐닝이 거부했다.
        let service = makeService {
            $0.thresholds.maxDistanceFromMainSequence = 0.01
            $0.reportFormat = .sarif
        }
        let output = try service.measureMetrics().output
        #expect(output.contains("2.1.0"))
        #expect(output.contains("runs"))
        #expect(!output.contains("afferentCoupling"))
    }

    @Test("없는 이름을 설명하라고 하면 사실을 알린다")
    func explainReportsAnUnknownSubject() throws {
        let outcome = try makeService().explainRetention(of: "NoSuchThing")
        #expect(outcome.subjectNotFound)
        #expect(outcome.findingCount == 0)
    }

    @Test("explain 도 베이스라인을 따른다")
    func explainRespectsTheBaseline() throws {
        // 같은 저장소, 같은 베이스라인인데 보고 방식에 따라 반대 판정이 나오면 안 된다.
        #expect(try makeService().detectUnusedCode().findingCount == 1)

        let fileSystem = InMemoryFileSystem()
        let baselined = makeService(
            configure: { $0.baselinePath = "/p/baseline.json" },
            fileSystem: fileSystem
        )
        _ = try baselined.writeBaseline(
            diagnostics: try baselined.collectAllDiagnostics(),
            to: "/p/baseline.json"
        )
        #expect(try baselined.detectUnusedCode().findingCount == 0)

        let explained = try baselined.explainRetention(of: "DeadHelper")
        #expect(explained.findingCount == 0)
        #expect(explained.output.contains("DeadHelper"))
    }
}

/// 인덱스를 몇 번 읽었는지 세는 공급자.
private final class CountingIndexProvider: IndexProviding, @unchecked Sendable {
    private let snapshot: IndexSnapshot
    private let lock = NSLock()
    private var count = 0

    init(snapshot: IndexSnapshot) {
        self.snapshot = snapshot
    }

    var loadCount: Int { lock.withLock { count } }

    func loadSnapshot() throws -> IndexSnapshot {
        lock.withLock { count += 1 }
        return snapshot
    }
}
