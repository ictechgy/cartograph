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

    private func makeService(snapshot: IndexSnapshot) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(snapshot)
            )
        )
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

    @Test("없는 이름은 notFound 로 답하고 사용 오류 표시를 세운다")
    func unknownNameIsFlaggedAsAUsageError() throws {
        // 이 플래그를 종료 코드 64 로 바꾸는 것은 CLI 의 몫이다. 여기서는 플래그가
        // 서는지까지만 확인한다. 실제 종료 코드는 Scripts/verify-cli-contract.sh 가
        // 빌드된 바이너리를 직접 돌려 검증한다.
        let outcome = try makeService().query(symbol: "NoSuchThing")
        #expect(outcome.subjectNotFound)
        #expect(outcome.output.contains("\"notFound\""))
    }

    @Test("이웃 수가 한도와 정확히 같으면 잘렸다고 하지 않는다")
    func doesNotClaimTruncationAtExactlyTheLimit() throws {
        var builder = SnapshotBuilder()
        builder.symbol("Root", kind: .structType, module: "App", path: "/p/Root.swift", attributes: [.entryPoint])
        for index in 0..<2 {
            builder.symbol("Leaf\(index)", kind: .classType, module: "App", path: "/p/Leaf\(index).swift")
            builder.reference(from: "Root", to: "Leaf\(index)", kind: .call)
        }
        let service = makeService(snapshot: builder.build())

        let exact = try #require(try service.queryDocument(symbol: "Root", limit: 2).result)
        #expect(exact.dependsOn.count == 2)
        #expect(!exact.truncated.dependsOn)

        let capped = try #require(try service.queryDocument(symbol: "Root", limit: 1).result)
        #expect(capped.dependsOn.count == 1)
        #expect(capped.truncated.dependsOn)
    }

    @Test("자기 자신을 참조하는 선언은 자기 이웃으로 나오지 않는다")
    func excludesItselfFromItsOwnNeighbours() throws {
        var builder = SnapshotBuilder()
        builder.symbol("Recurse", kind: .method, module: "App", path: "/p/Recurse.swift", attributes: [.entryPoint])
        builder.reference(from: "Recurse", to: "Recurse", kind: .call)
        let service = makeService(snapshot: builder.build())

        let result = try #require(try service.queryDocument(symbol: "Recurse", depth: 3).result)
        #expect(result.dependsOn.isEmpty)
        #expect(result.usedBy.isEmpty)
    }

    @Test("도달 가능한 선언에는 베이스라인 억제 표시가 붙지 않는다")
    func doesNotMarkReachableCodeAsSuppressed() throws {
        // `dead` 는 도달 가능한 정점에 애초에 진단을 내지 않는다. 그런데도 옛
        // 베이스라인 항목이 지문만 맞으면 억제되었다고 표시되면, "도달 가능한데
        // 팀이 억제했다"는 모순된 답이 나간다.
        let fileSystem = InMemoryFileSystem()
        let service = makeService(configure: { $0.baselinePath = "/p/baseline.json" }, fileSystem: fileSystem)
        _ = try service.writeBaseline(diagnostics: try service.collectAllDiagnostics(), to: "/p/baseline.json")

        let reachable = try #require(try service.queryDocument(symbol: "UserRepository").result)
        #expect(reachable.reachability.state == "reachable")
        #expect(!reachable.reachability.suppressedByBaseline)
    }

    @Test("라이브러리로 부를 때 깊이와 개수가 0 이어도 답이 무너지지 않는다")
    func clampsNonPositiveBounds() throws {
        // CLI 는 validate() 로 막지만 queryDocument 는 공개 API 다. 0 을 받고
        // "이웃 없음"이라고 답하면 그 답이 삭제 근거로 쓰인다.
        let result = try #require(try makeService().queryDocument(symbol: "UserService", depth: 0, limit: 0).result)
        #expect(result.usedBy.map(\.qualifiedName) == ["Presentation.HomeView"])
        #expect(result.dependsOn.map(\.qualifiedName) == ["Data.UserRepository"])
    }

    @Test("설정된 해상도와 무관하게 심볼 레벨로 답한다고 밝힌다")
    func alwaysReportsTheSymbolLevel() throws {
        // 도달성 분석은 항상 심볼 레벨로 만든다. 설정값을 그대로 실어 보내면
        // 심볼 레벨 답을 모듈 레벨 답이라고 말하게 된다.
        let document = try makeService { $0.level = .module }.queryDocument(symbol: "UserService")
        #expect(document.level == "symbol")
    }

    @Test("이 분석이 보지 못하는 채널을 상태와 무관하게 모든 답에 실어 보낸다")
    func shipsLimitationsWithEveryAnswer() throws {
        // 알릴 것이 없으면 조용해야 한다. 매번 붙는 경보는 읽히지 않는다.
        let plain = try makeService().queryDocument(symbol: "UserService")
        #expect(plain.limitations.isEmpty)

        let mixed = InMemoryFileSystem(files: [
            "/p/Legacy/LegacyBridge.m": "@implementation LegacyBridge @end",
            "/p/Resources/Main.storyboard": "<document/>",
        ])
        let service = makeService(fileSystem: mixed)
        let found = try service.queryDocument(symbol: "UserService")
        #expect(found.limitations.contains { $0.hasPrefix("objective-c-sources: 1 file(s)") })
        #expect(found.limitations.contains { $0.hasPrefix("interface-builder-documents: 1 document(s)") })

        // 없는 이름을 물었을 때가 오히려 더 중요하다. Objective-C 로 선언된 이름에
        // "그런 것 없다"고만 답하면, 없는 것과 못 보는 것을 구분할 수 없다.
        let missing = try service.queryDocument(symbol: "NoSuchThing")
        #expect(missing.status == "notFound")
        #expect(missing.limitations == found.limitations)
    }

    @Test("분석 범위 밖의 파일은 한계 목록에 세지 않는다")
    func countsOnlyWhatTheAnalysisWouldHaveSeen() throws {
        // .build 나 Pods 안의 남의 코드까지 세면 숫자가 프로젝트의 사실이 아니게 된다.
        let noisy = InMemoryFileSystem(files: [
            "/p/Pods/Vendor/Vendor.m": "@implementation Vendor @end",
            "/p/.build/checkouts/Dep/Dep.m": "@implementation Dep @end",
        ])
        let pruned = try makeService(fileSystem: noisy).queryDocument(symbol: "UserService")
        #expect(!pruned.limitations.contains { $0.hasPrefix("objective-c-sources:") })

        // 설정이 제외한 경로도 마찬가지다. 그래프가 보지 않는 파일을 한계로 알리면
        // 매번 붙는 경보가 되고, 매번 붙는 경보는 읽히지 않는다.
        let excluded = InMemoryFileSystem(files: ["/p/Legacy/Bridge.m": "@implementation Bridge @end"])
        let document = try makeService(
            configure: { $0.exclude = [GlobPattern("Legacy/**")] },
            fileSystem: excluded
        ).queryDocument(symbol: "UserService")
        #expect(!document.limitations.contains { $0.hasPrefix("objective-c-sources:") })
        // 대신 필터가 걸려 있다는 사실 자체를 알린다. 걸러진 호출자와 없는 호출자는
        // 응답만 보고 구분할 수 없다.
        #expect(document.limitations.contains { $0.hasPrefix("configured-path-filter:") })
    }

    @Test("마지막 빌드 뒤에 바뀐 소스가 있으면 몇 개인지 알린다")
    func reportsIndexStaleness() throws {
        // 삭제를 결정하는 소비자에게 가장 위험한 침묵이다. 호출부를 방금 추가하고
        // 빌드하지 않은 상태에서 물으면 "아무도 안 쓴다"는 답이 나온다.
        let built = Date(timeIntervalSince1970: 1_000)
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Domain/Fresh.swift": "",
            "/p/Domain/Edited.swift": "",
            "/p/Domain/Untouched.swift": "",
        ])
        fileSystem.setModificationDate(built.addingTimeInterval(60), for: "/p/Domain/Fresh.swift")
        fileSystem.setModificationDate(built.addingTimeInterval(30), for: "/p/Domain/Edited.swift")
        fileSystem.setModificationDate(built.addingTimeInterval(-60), for: "/p/Domain/Untouched.swift")

        let limitations = makeService(fileSystem: fileSystem).analysisLimitations(storeDate: built)
        #expect(limitations.contains("""
            index-staleness: 2 of 3 source file(s) changed after the index store was written, \
            so a call added since the last build is not here yet
            """))
    }

    @Test("인덱스 스토어 시각을 모르면 신선도를 말하지 않는다")
    func staysSilentWhenTheStoreDateIsUnknown() throws {
        // 모르는 것을 "최신"이라고 말하지 않는다. 항목이 없는 것과 신선하다는 것은
        // 다르고, 후자를 사실이 아닌데 주장하면 그 위에서 삭제 결정이 내려진다.
        let fileSystem = InMemoryFileSystem(files: ["/p/Domain/Any.swift": ""])
        fileSystem.setModificationDate(Date(), for: "/p/Domain/Any.swift")
        let limitations = makeService(fileSystem: fileSystem).analysisLimitations()
        #expect(!limitations.contains { $0.hasPrefix("index-staleness:") })
    }

    @Test("DerivedData 에서 찾은 인덱스도 신선도를 말한다")
    func reportsStalenessForDerivedDataStores() {
        // 신선도 판정이 로케이터를 derivedDataPath 없이 다시 부르고 있었다. Xcode 로
        // 빌드한 프로젝트에서만 이 경고가 영영 나오지 않았고, 하필 그쪽이 인덱스가
        // 가장 자주 낡는 환경이다. 자동 탐색이 열리면 그 침묵이 그대로 퍼진다.
        let built = Date(timeIntervalSince1970: 1_000)
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App/App.xcodeproj/project.pbxproj": "",
            "/p/App/Domain/Edited.swift": "",
            "/dd/App-abcdef/Index.noindex/DataStore/v5/units/a": "",
        ])
        fileSystem.setModificationDate(built, for: "/dd/App-abcdef/Index.noindex/DataStore/v5/units")
        fileSystem.setModificationDate(built.addingTimeInterval(60), for: "/p/App/Domain/Edited.swift")

        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p/App"
        configuration.derivedDataPath = "/dd"
        // 인덱스 공급자를 주입하지 않는다. 주입하면 신선도 판정이 그 자리에서 침묵한다.
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(fileSystem: fileSystem)
        )
        #expect(service.analysisLimitations().contains { $0.hasPrefix("index-staleness: 1 of 1") })
    }

    @Test("기본 제외만으로는 경로 필터 한계가 붙지 않는다")
    func defaultExcludesDoNotCountAsANarrowedFilter() throws {
        // `exclude` 의 기본값이 `defaultExcludes` 라 "비어 있지 않다" 로 판단하면 설정
        // 파일이 없는 프로젝트에서도 늘 참이 된다. 실측한 네 프로젝트 전부가 그랬다.
        let document = try makeService().queryDocument(symbol: "UserService")
        #expect(!document.limitations.contains { $0.hasPrefix("configured-path-filter:") })

        // 기본보다 느슨해도 알릴 것이 없다. 기본이 보여 줬을 호출자를 더 숨기지 못한다.
        let looser = try makeService { $0.exclude = ["**/.build/**"] }
            .queryDocument(symbol: "UserService")
        #expect(!looser.limitations.contains { $0.hasPrefix("configured-path-filter:") })
    }

    @Test("기본보다 좁히면 경로 필터 한계가 붙는다")
    func narrowingBeyondTheDefaultsIsReported() throws {
        let byInclude = try makeService { $0.include = ["Domain/**"] }
            .queryDocument(symbol: "UserService")
        #expect(byInclude.limitations.contains { $0.hasPrefix("configured-path-filter:") })

        let byExclude = try makeService { $0.exclude = ["**/Legacy/**"] }
            .queryDocument(symbol: "UserService")
        #expect(byExclude.limitations.contains { $0.hasPrefix("configured-path-filter:") })
    }

    @Test("라이브러리 패키지에서 공개 API 가 보존되지 않으면 그 사실을 알린다")
    func reportsUnretainedPublicApiForLibraryPackages() throws {
        // 호출자가 저장소 밖에 있으므로 공개 API 전체가 미사용으로 나온다. 그 목록을 그대로
        // 삭제로 옮기면 소비자가 전부 깨진다. 스크래치 패키지에서 공개 타입 둘이 통째로
        // 보고되는 것을 확인했다.
        let library = InMemoryFileSystem(files: [
            "/p/Package.swift": "let package = Package(\n"
                + "    products: [.library(name: \"Core\", targets: [\"Core\"])],\n"
                + "    targets: [.target(name: \"Core\")]\n)"
        ])
        let document = try makeService(fileSystem: library).queryDocument(symbol: "UserService")
        #expect(document.limitations.contains { $0.hasPrefix("public-api-not-retained: this package exports 1") })

        // 보존을 켜면 알릴 것이 없다.
        let retained = try makeService(
            configure: { $0.retention.retainPublic = true },
            fileSystem: library
        ).queryDocument(symbol: "UserService")
        #expect(!retained.limitations.contains { $0.hasPrefix("public-api-not-retained:") })
    }

    @Test("실행 파일이 있는 패키지에는 공개 API 한계를 붙이지 않는다")
    func executablePackagesAreNotWarnedAboutPublicApi() throws {
        // 진입점이 저장소 안에 있으면 도달성 분석이 성립한다. 공개 API 가 미사용으로 나오는
        // 것이 정상적인 답일 수 있어, 여기서 경보를 붙이면 매번 붙는 경보가 된다.
        let mixed = InMemoryFileSystem(files: [
            "/p/Package.swift": "let package = Package(\n"
                + "    products: [.library(name: \"Kit\", targets: [\"Kit\"]), "
                + ".executable(name: \"tool\", targets: [\"tool\"])],\n"
                + "    targets: [.target(name: \"Kit\"), .executableTarget(name: \"tool\")]\n)"
        ])
        let document = try makeService(fileSystem: mixed).queryDocument(symbol: "UserService")
        #expect(!document.limitations.contains { $0.hasPrefix("public-api-not-retained:") })

        // 매니페스트가 아예 없는 프로젝트(Xcode 앱)에서도 조용하다.
        let app = try makeService().queryDocument(symbol: "UserService")
        #expect(!app.limitations.contains { $0.hasPrefix("public-api-not-retained:") })
    }

    @Test("설정이 간선 종류를 좁히면 그 사실을 알린다")
    func reportsConfiguredEdgeKinds() throws {
        let document = try makeService { $0.edgeKinds = [.call] }.queryDocument(symbol: "UserService")
        #expect(document.limitations.contains { $0.hasPrefix("configured-edge-kinds: only call ") })
    }

    @Test("타입에 물으면 멤버를 따로 알려 준다")
    func reportsMembersSeparately() throws {
        // 심볼 레벨 그래프에서 타입의 의존은 전부 멤버가 들고 있다. 멤버를 빼면
        // 클래스에 물었을 때 dependsOn 이 비어 나오고, 그것은 "아무것도 의존하지
        // 않는다"로 읽힌다. 담는 관계를 dependsOn 에 섞는 것도 거짓말이다.
        var builder = SnapshotBuilder()
        builder.symbol("Screen", kind: .classType, module: "App", path: "/p/Screen.swift", attributes: [.entryPoint])
        builder.symbol("load", kind: .method, module: "App", path: "/p/Screen.swift", parent: "Screen")
        builder.symbol("Store", kind: .classType, module: "App", path: "/p/Store.swift")
        builder.reference(from: "load", to: "Store", kind: .call)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )

        let type = try #require(try service.queryDocument(symbol: "Screen").result)
        #expect(type.dependsOn.isEmpty)
        #expect(type.members.map(\.qualifiedName) == ["App.load"])
        #expect(type.members.map(\.edges) == [["member"]])
        #expect(type.declaredIn == nil)

        let member = try #require(try service.queryDocument(symbol: "load").result)
        #expect(member.declaredIn?.qualifiedName == "App.Screen")
        #expect(member.dependsOn.map(\.qualifiedName) == ["App.Store"])
        // 담는 관계는 쓰는 관계가 아니다. 타입이 멤버를 쓴다고 말하면 안 된다.
        #expect(member.usedBy.isEmpty)
    }

    @Test("멤버 목록도 개수 제한과 잘림 표시를 따른다")
    func truncatesMembers() throws {
        var builder = SnapshotBuilder()
        builder.symbol("Screen", kind: .classType, module: "App", path: "/p/Screen.swift", attributes: [.entryPoint])
        for index in 0..<3 {
            builder.symbol("m\(index)", kind: .method, module: "App", path: "/p/Screen.swift", parent: "Screen")
        }
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )

        let result = try #require(try service.queryDocument(symbol: "Screen", limit: 2).result)
        #expect(result.members.count == 2)
        #expect(result.truncated.members)
    }

    @Test("같은 두 정점 사이의 간선이 여럿이면 종류를 모두 알려 준다")
    func reportsEveryRelationToTheSameNeighbour() throws {
        // 하나만 골라 담으면 나머지 관계가 응답에서 사라진다. 호출이면서 동시에
        // 오버라이드인 이웃을 "호출"로만 보고하면, 그 답을 근거로 지운 뒤에야
        // 오버라이드가 깨진 것을 알게 된다. 무엇을 고를지가 정렬 타이에 따라
        // 실행마다 달라지는 문제도 함께 없앤다.
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
        #expect(result.dependsOn.map(\.qualifiedName) == ["App.Callee"])
        #expect(result.dependsOn.map(\.edges) == [["call", "reference"]])
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

    // MARK: - 배치

    @Test("배치는 요청 순서와 중복을 그대로 지킨다")
    func batchKeepsOrderAndDuplicates() throws {
        let outcome = try makeService().queryBatch(
            symbols: ["UserService", "DeadHelper", "UserService"]
        )
        let document = try JSONDecoder().decode(
            SymbolQueryBatchDocument.self, from: Data(outcome.output.utf8)
        )
        #expect(document.format == "symbol-query-batch")
        #expect(document.version == 1)
        #expect(document.results.map(\.requested) == ["UserService", "DeadHelper", "UserService"])
        #expect(document.results[0] == document.results[2])
    }

    @Test("배치의 답은 하나씩 물었을 때와 같다")
    func batchAgreesWithSingleQueries() throws {
        let service = makeService()
        let names = ["HomeView", "UserService", "UserRepository", "DeadHelper", "NoSuchThing"]
        let batch = try JSONDecoder().decode(
            SymbolQueryBatchDocument.self,
            from: Data(try service.queryBatch(symbols: names).output.utf8)
        )
        for (name, result) in zip(names, batch.results) {
            #expect(result == (try service.queryDocument(symbol: name)))
        }
    }

    @Test("배치에 하나라도 없는 이름이 있으면 사용 오류로 표시하되 나머지 답은 낸다")
    func batchReportsMissingNamesWithoutDroppingTheRest() throws {
        let outcome = try makeService().queryBatch(symbols: ["UserService", "NoSuchThing", "DeadHelper"])
        #expect(outcome.subjectNotFound)
        let document = try JSONDecoder().decode(
            SymbolQueryBatchDocument.self, from: Data(outcome.output.utf8)
        )
        #expect(document.results.map(\.status) == ["found", "notFound", "found"])
    }

    @Test("배치는 모호한 이름을 고르지 않고 후보로 답한다")
    func batchReturnsCandidatesForAnAmbiguousName() throws {
        var builder = SnapshotBuilder()
        builder.symbol("Root", kind: .structType, module: "App", path: "/p/Root.swift", attributes: [.entryPoint])
        builder.symbol("A.Config", name: "Config", kind: .structType, module: "App", path: "/p/A.swift")
        builder.symbol("B.Config", name: "Config", kind: .structType, module: "App", path: "/p/B.swift")
        let service = makeService(snapshot: builder.build())

        let document = try JSONDecoder().decode(
            SymbolQueryBatchDocument.self,
            from: Data(try service.queryBatch(symbols: ["Config"]).output.utf8)
        )
        #expect(document.results.first?.status == "ambiguous")
        #expect(document.results.first?.candidates?.count == 2)
        // 모호함은 답이지 실패가 아니다. 종료 코드를 세우면 스윕이 거기서 멈춘다.
        #expect(try !service.queryBatch(symbols: ["Config"]).subjectNotFound)
    }

    @Test("배치도 한계 목록을 모든 결과에 함께 싣는다")
    func batchCarriesLimitationsOnEveryResult() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "@interface Legacy @end", to: "/p/Legacy.m")
        let service = makeService(fileSystem: fileSystem)

        let document = try JSONDecoder().decode(
            SymbolQueryBatchDocument.self,
            from: Data(try service.queryBatch(symbols: ["UserService", "NoSuchThing"]).output.utf8)
        )
        #expect(document.results.allSatisfy { !$0.limitations.isEmpty })
    }

    @Test("잘못된 요청 파일은 형태를 말하며 거부된다")
    func malformedRequestsAreRejectedWithTheirShape() throws {
        let cases: [(String, String)] = [
            ("{}", "not a JSON array"),
            ("[1]", "not a JSON array"),
            ("[]", "0 request"),
            ("[\"\"]", "request 0 is empty"),
            ("[\"  \"]", "request 0 is empty"),
        ]
        for (source, expected) in cases {
            #expect(throws: CartographError.self) {
                try SymbolQueryBatchRequests.parse(Data(source.utf8), path: "/p/r.json")
            }
            do {
                _ = try SymbolQueryBatchRequests.parse(Data(source.utf8), path: "/p/r.json")
            } catch let error as CartographError {
                #expect(
                    error.errorDescription?.contains(expected) == true,
                    "\(source) 의 이유가 '\(expected)' 를 말하지 않는다"
                )
            }
        }
    }

    @Test("요청 수와 파일 크기의 한계를 지킨다")
    func rejectsTooManyRequestsAndOversizedFiles() throws {
        let many = try JSONEncoder().encode((0...1000).map { "N\($0)" })
        #expect(throws: CartographError.self) {
            try SymbolQueryBatchRequests.parse(many, path: "/p/r.json")
        }
        let justEnough = try JSONEncoder().encode((0..<1000).map { "N\($0)" })
        #expect(try SymbolQueryBatchRequests.parse(justEnough, path: "/p/r.json").count == 1000)

        // 크기 한계는 개수보다 먼저 본다. 1 MiB 를 넘는 배열을 파싱하는 것 자체가 비용이다.
        let huge = Data("[\"\(String(repeating: "x", count: 1024 * 1024))\"]".utf8)
        #expect(throws: CartographError.self) {
            try SymbolQueryBatchRequests.parse(huge, path: "/p/r.json")
        }
    }
}
