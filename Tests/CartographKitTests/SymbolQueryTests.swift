import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("심볼 질의")
struct SymbolQueryTests {
    /// HomeView → UserService → UserRepository 로 흐르는 사슬 하나와,
    /// 아무도 부르지 않는 선언 하나. 깊이·도달성·이웃을 한 번에 확인할 수 있다.
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

    @Test("누가 쓰는지와 무엇을 쓰는지를 함께 답한다")
    func answersBothDirections() throws {
        let document = try makeService().queryDocument(symbol: "UserService")
        #expect(document.status == "found")
        let result = try #require(document.result)
        #expect(result.subject.qualifiedName == "Domain.UserService")
        #expect(result.usedBy.map(\.qualifiedName) == ["Presentation.HomeView"])
        #expect(result.dependsOn.map(\.qualifiedName) == ["Data.UserRepository"])
    }

    @Test("기본 깊이는 직접 이웃까지만이고 깊이를 늘리면 전이 이웃도 답한다")
    func followsDepth() throws {
        let direct = try #require(try makeService().queryDocument(symbol: "HomeView").result)
        #expect(direct.dependsOn.map(\.qualifiedName) == ["Domain.UserService"])

        let transitive = try #require(try makeService().queryDocument(symbol: "HomeView", depth: 2).result)
        #expect(transitive.dependsOn.map(\.qualifiedName) == ["Domain.UserService", "Data.UserRepository"])
    }

    @Test("개수 제한에 걸리면 잘렸다는 사실을 같이 알린다")
    func reportsTruncation() throws {
        // 잘린 답을 전부인 것처럼 내보내면, 이웃이 없다는 뜻으로 읽힌다.
        let result = try #require(try makeService().queryDocument(symbol: "HomeView", depth: 2, limit: 1).result)
        #expect(result.dependsOn.count == 1)
        #expect(result.truncated.dependsOn)
        #expect(!result.truncated.usedBy)
    }

    @Test("보존 근거를 산문이 아니라 값으로 답한다")
    func reportsRetentionAsAValue() throws {
        let result = try #require(try makeService().queryDocument(symbol: "HomeView").result)
        #expect(result.reachability.state == "retained")
        #expect(result.reachability.reason == .entryPoint)
    }

    @Test("도달할 수 없는 선언은 도달 불가라고만 답한다")
    func reportsUnreachableWithoutAVerdict() throws {
        let result = try #require(try makeService().queryDocument(symbol: "DeadHelper").result)
        #expect(result.reachability.state == "unreachable")
        #expect(result.reachability.reason == nil)
        #expect(result.usedBy.isEmpty)
    }

    @Test("경로를 통해 도달한 선언은 그 경로를 같이 답한다")
    func reportsTheReachingPath() throws {
        let result = try #require(try makeService().queryDocument(symbol: "UserRepository").result)
        #expect(result.reachability.state == "reachable")
        #expect(result.reachability.path == ["Presentation.HomeView", "Domain.UserService", "Data.UserRepository"])
    }

    @Test("베이스라인이 이미 아는 판정은 그렇다고 표시한다")
    func reflectsTheBaseline() throws {
        // 팀이 알고 남겨 둔 것을 에이전트가 다시 심사하게 두면 안 된다.
        let fileSystem = InMemoryFileSystem()
        let service = makeService(configure: { $0.baselinePath = "/p/baseline.json" }, fileSystem: fileSystem)
        _ = try service.writeBaseline(diagnostics: try service.collectAllDiagnostics(), to: "/p/baseline.json")

        let result = try #require(try service.queryDocument(symbol: "DeadHelper").result)
        #expect(result.reachability.state == "unreachable")
        #expect(result.reachability.suppressedByBaseline)
    }

    @Test("이름이 여럿에 걸리면 고르지 않고 후보를 돌려준다")
    func returnsCandidatesInsteadOfGuessing() throws {
        var builder = SnapshotBuilder()
        builder.symbol(
            "s:7Network6ClientC", name: "Client", kind: .classType,
            module: "Network", path: "/p/Network/Client.swift"
        )
        builder.symbol(
            "s:7Storage6ClientC", name: "Client", kind: .classType,
            module: "Storage", path: "/p/Storage/Client.swift"
        )
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )

        let document = try service.queryDocument(symbol: "Client")
        #expect(document.status == "ambiguous")
        #expect(document.result == nil)
        let candidates = try #require(document.candidates)
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.usr?.isEmpty == false })
    }

    @Test("없는 이름은 사용 오류로 끝난다")
    func unknownNameIsAUsageError() throws {
        let outcome = try makeService().query(symbol: "NoSuchThing")
        #expect(outcome.subjectNotFound)
        #expect(outcome.output.contains("\"notFound\""))
    }

    @Test("설정된 해상도와 무관하게 심볼 레벨로 답한다고 밝힌다")
    func alwaysReportsTheSymbolLevel() throws {
        // 도달성 분석은 항상 심볼 레벨로 만든다. 설정값을 그대로 실어 보내면
        // 심볼 레벨 답을 모듈 레벨 답이라고 말하게 된다.
        let document = try makeService { $0.level = .module }.queryDocument(symbol: "UserService")
        #expect(document.level == "symbol")
    }

    @Test("이 분석이 보지 못하는 채널을 모든 답에 실어 보낸다")
    func shipsLimitationsWithEveryAnswer() throws {
        let plainSwift = try #require(try makeService().queryDocument(symbol: "UserService").result)
        #expect(plainSwift.limitations.contains { $0.hasPrefix("single-configuration:") })
        #expect(!plainSwift.limitations.contains { $0.hasPrefix("objective-c-sources:") })

        let mixed = InMemoryFileSystem(files: [
            "/p/Legacy/LegacyBridge.m": "@implementation LegacyBridge @end",
            "/p/Resources/Main.storyboard": "<document/>",
        ])
        let result = try #require(try makeService(fileSystem: mixed).queryDocument(symbol: "UserService").result)
        #expect(result.limitations.contains { $0.hasPrefix("objective-c-sources: 1 file(s)") })
        #expect(result.limitations.contains { $0.hasPrefix("interface-builder-documents: 1 document(s)") })
    }

    @Test("빌드 산출물 안의 파일은 한계 목록에 세지 않는다")
    func ignoresBuildArtifactsWhenCountingLimitations() throws {
        // .build 나 Pods 안의 남의 코드까지 세면 숫자가 프로젝트의 사실이 아니게 된다.
        let noisy = InMemoryFileSystem(files: [
            "/p/Pods/Vendor/Vendor.m": "@implementation Vendor @end",
            "/p/.build/checkouts/Dep/Dep.m": "@implementation Dep @end",
        ])
        let result = try #require(try makeService(fileSystem: noisy).queryDocument(symbol: "UserService").result)
        #expect(!result.limitations.contains { $0.hasPrefix("objective-c-sources:") })
    }

    @Test("같은 두 정점 사이에 간선이 여럿이면 종류까지 정렬해 하나를 고른다")
    func picksTheSameEdgeEveryRun() throws {
        // 정렬 키에 종류가 없으면 두 간선의 순서가 갈리고, 먼저 만난 쪽만 담기므로
        // 실행마다 다른 edge 값이 나온다. 출력을 diff 할 수 있어야 한다.
        var builder = SnapshotBuilder()
        builder.symbol("Caller", kind: .structType, module: "App", path: "/p/Caller.swift", attributes: [.entryPoint])
        builder.symbol("Callee", kind: .classType, module: "App", path: "/p/Callee.swift")
        builder.reference(from: "Caller", to: "Callee", kind: .reference)
        builder.reference(from: "Caller", to: "Callee", kind: .call)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )

        let result = try #require(try service.queryDocument(symbol: "Caller").result)
        #expect(result.dependsOn.map(\.edge) == ["call"])
    }

    @Test("출력 JSON 은 키 순서가 고정되어 diff 할 수 있다")
    func encodesDeterministically() throws {
        let service = makeService()
        let first = try service.query(symbol: "UserService").output
        let second = try service.query(symbol: "UserService").output
        #expect(first == second)
        let decoded = try JSONDecoder().decode(SymbolQueryDocument.self, from: Data(first.utf8))
        #expect(decoded.result?.subject.name == "UserService")
    }
}
