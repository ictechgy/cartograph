import CartographAnalysis
import CartographConfig
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

/// 레이어 패턴의 대조 대상(`match_on`)을 설정 파일에서 실행까지 확인한다.
///
/// 패턴 하나는 기본적으로 이름·모듈·경로 어디에 맞아도 레이어를 배정한다. 파일 이름을 의도한
/// `*Network*` 가 `Domain/Errors.swift` 에 선언된 `NetworkError` 타입 이름에도 걸려, 먼저 정의된
/// Network 레이어로 끌려가고 Domain 의 정당한 참조가 위반으로 보고된다.
///
/// 경로의 어느 요소도 패턴에 맞지 않을 때만 `match_on: path` 가 이 둘을 가른다. `/` 없는 경로 패턴은
/// 절대·상대 경로의 각 요소(디렉터리와 파일 이름)에 대조되므로 `NetworkError.swift` 에 선언됐거나
/// `Network/` 아래에 있으면 여전히 맞는다(`LayerRuleEvaluatorTests.matchTargetBoundaries`).
@Suite("레이어 패턴의 대조 대상")
struct LayerMatchTargetTests {
    private func yaml(matchOn: String?) -> String {
        """
        layers:
          - name: Network
            match: ["*Network*"]
        \(matchOn.map { "    match_on: \($0)\n" } ?? "")  - name: Domain
            match: ["Domain/**"]
        rules:
          - from: Domain
            deny: [Network]
        """
    }

    private func service(_ configuration: CartographConfiguration) -> CartographService {
        var snapshot = SnapshotBuilder()
        snapshot.symbol("NetworkError", kind: .structType, module: "App", path: "/project/Domain/Errors.swift")
        snapshot.symbol("Validator", kind: .structType, module: "App", path: "/project/Domain/Validator.swift")
        snapshot.symbol("NetworkClient", kind: .structType, module: "App",
                        path: "/project/Network/NetworkClient.swift")
        snapshot.reference(from: "Validator", to: "NetworkError", kind: .reference,
                           path: "/project/Domain/Validator.swift", line: 7)
        var configuration = configuration
        configuration.projectPath = "/project"
        let fileSystem = InMemoryFileSystem(files: [
            "/project/Domain/Errors.swift": "struct NetworkError {}",
            "/project/Domain/Validator.swift": "struct Validator {}",
            "/project/Network/NetworkClient.swift": "struct NetworkClient {}",
        ])
        return CartographService(configuration: configuration, environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot.build())
        ))
    }

    @Test("match_on: path 로 지정한 레이어는 타입 이름에 걸리지 않는다")
    func pathOnlyLayerIgnoresTypeNames() throws {
        let loaded = try ConfigurationLoader().load(yaml: yaml(matchOn: "[path]"), path: "/project/.cartograph.yml")
        #expect(loaded.warnings.isEmpty)
        let service = service(loaded.configuration)

        let outcome = try service.checkRules(level: .type)
        #expect(outcome.findingCount == 0)
        let error = try service.explainRules(of: "NetworkError", level: .type)
        #expect(error.output.contains("is in layer 'Domain'"))
        let client = try service.explainRules(of: "NetworkClient", level: .type)
        #expect(client.output.contains("is in layer 'Network'"))
        #expect(client.output.contains("against '*Network*' (match_on: path)"))
    }

    @Test("match_on 이 없으면 이름·모듈·경로를 모두 대조하던 결과가 그대로다")
    func defaultMatchesEveryCandidate() throws {
        let loaded = try ConfigurationLoader().load(yaml: yaml(matchOn: nil), path: "/project/.cartograph.yml")
        #expect(loaded.configuration.layers.allSatisfy { $0.matchTargets == nil })
        let service = service(loaded.configuration)

        let outcome = try service.checkRules(level: .type)
        #expect(outcome.findingCount == 1)
        let error = try service.explainRules(of: "NetworkError", level: .type)
        #expect(error.output.contains("is in layer 'Network'"))
        #expect(error.output.contains("matched: NetworkError against '*Network*'\n"))
    }
}
