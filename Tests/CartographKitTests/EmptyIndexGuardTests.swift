import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("빈 인덱스 가드")
struct EmptyIndexGuardTests {
    /// 프로젝트에는 소스가 있는데 인덱스는 그것을 하나도 모르는 상태.
    ///
    /// 실제로 이렇게 되는 경로가 셋이다. `--project` 가 틀렸을 때, 인덱스가 다른
    /// 체크아웃의 것일 때, 경로 필터가 전부 걸러 냈을 때.
    private func makeService(
        snapshot: IndexSnapshot,
        allowsEmptyIndex: Bool = false,
        configure: (inout CartographConfiguration) -> Void = { _ in }
    ) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configure(&configuration)
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(files: ["/p/Sources/A.swift": "struct A {}"]),
                indexProviderOverride: StaticIndexProvider(snapshot)
            ),
            allowsEmptyIndex: allowsEmptyIndex
        )
    }

    private func makeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/A.swift")
        builder.symbol("s:A", name: "A", kind: .structType)
        return builder.build()
    }

    @Test("인덱스가 이 프로젝트를 하나도 모르면 분석을 시작하지 않는다")
    func emptyIndexIsAToolFailure() {
        // 조용히 "발견 없음"으로 끝내면 --strict 가 0줄을 분석하고 통과한다.
        // 그 초록불은 코드가 깨끗하다는 뜻으로 읽힌다.
        let service = makeService(snapshot: IndexSnapshot())
        #expect(throws: CartographError.self) { try service.loadContext() }
    }

    @Test("빈 인덱스는 dead·cycles·rules 를 모두 실패시킨다")
    func everyAnalysisFailsOnAnEmptyIndex() {
        let service = makeService(snapshot: IndexSnapshot())
        #expect(throws: CartographError.self) { try service.detectUnusedCode() }
        #expect(throws: CartographError.self) { try service.detectCycles() }
        #expect(throws: CartographError.self) { try service.checkRules() }
    }

    @Test("탈출구를 켜면 빈 인덱스로도 분석이 진행된다")
    func escapeHatchAllowsAnEmptyIndex() throws {
        let context = try makeService(snapshot: IndexSnapshot(), allowsEmptyIndex: true).loadContext()
        #expect(context.snapshot.symbols.isEmpty)
    }

    @Test("탈출구를 켠 답에는 아무것도 분석하지 않았다는 한계가 실린다")
    func escapeHatchIsReportedAsALimitation() throws {
        // 통과시키되 사실을 숨기지 않는다. 답을 받은 쪽이 "발견 없음"을 깨끗함으로
        // 읽으면 가드를 켠 의미가 없다.
        let service = makeService(snapshot: IndexSnapshot(), allowsEmptyIndex: true)
        let limitations = service.analysisLimitations(context: try service.loadContext())
        #expect(limitations.contains { $0.hasPrefix("empty-index:") })
    }

    @Test("인덱스가 비어 있지 않으면 가드가 걸리지 않는다")
    func nonEmptyIndexPasses() throws {
        let context = try makeService(snapshot: makeSnapshot()).loadContext()
        #expect(context.snapshot.symbols.count == 1)
    }

    @Test("bridges 는 인덱스가 비어 있어도 계속 동작한다")
    func bridgesDoesNotGoThroughTheGuard() throws {
        // 공개 플러그인 스캔은 더미 타깃으로 인덱스만 만들고 그 파일을 제외한다.
        // 설계상 인덱스 기여가 0이므로, 여기서 실패하면 그 용법이 통째로 막힌다.
        let service = makeService(snapshot: IndexSnapshot())
        let document = try service.bridgeFacts()
        #expect(document.facts.isEmpty)
    }

    @Test("오류 메시지는 원인을 좁힐 수 있게 세 숫자를 함께 싣는다")
    func errorNamesWhatItLookedAt() throws {
        let service = makeService(snapshot: IndexSnapshot())
        var message = ""
        do {
            _ = try service.loadContext()
        } catch {
            message = (error as? CartographError)?.errorDescription ?? ""
        }
        // 무엇을 봤는지, 소스가 몇 개인지, 다음에 무엇을 할지.
        #expect(message.contains("/p"))
        #expect(message.contains("Swift files:   1 under the project"))
        #expect(message.contains("--allow-empty-index"))
    }
}

@Suite("빈 인덱스 사실 문장")
struct EmptyIndexFactsTests {
    private func facts(
        sourceFileCount: Int,
        filteredSourceFileCount: Int,
        unitCount: Int?
    ) -> EmptyIndexFacts {
        EmptyIndexFacts(
            projectPath: "/p",
            resolvedProjectPath: "/p",
            storePath: "/p/.build/out",
            storeOrigin: .autoDetected,
            libraryPath: "/xcode/libIndexStore.dylib",
            sourceFileCount: sourceFileCount,
            filteredSourceFileCount: filteredSourceFileCount,
            unitCount: unitCount
        )
    }

    @Test("소스를 하나도 못 찾았으면 프로젝트 경로를 가리키라고 한다")
    func noSourcesRemedy() {
        let remedy = facts(sourceFileCount: 0, filteredSourceFileCount: 0, unitCount: 12).remedy
        #expect(remedy.contains("--project"))
    }

    @Test("경로 필터가 전부 걸러 냈으면 include·exclude 를 가리킨다")
    func filteredOutRemedy() {
        // 이 조합이 기본 제외가 조상 디렉터리에 걸린 경우다. 사용자가 스스로
        // 알아내기 가장 어려운 원인이라 문장이 따로 필요하다.
        let remedy = facts(sourceFileCount: 214, filteredSourceFileCount: 0, unitCount: 900).remedy
        #expect(remedy.contains("--exclude"))
    }

    @Test("유닛이 하나도 없으면 먼저 빌드하라고 한다")
    func nothingCompiledRemedy() {
        let remedy = facts(sourceFileCount: 214, filteredSourceFileCount: 214, unitCount: 0).remedy
        #expect(remedy.contains("swift build"))
    }

    @Test("유닛은 있는데 겹치지 않으면 남의 스토어라고 말한다")
    func foreignStoreRemedy() {
        let remedy = facts(sourceFileCount: 214, filteredSourceFileCount: 214, unitCount: 900).remedy
        #expect(remedy.contains("--index-store"))
    }

    @Test("유닛 수를 모르면 있다고도 없다고도 하지 않는다")
    func unknownUnitCountIsNotGuessed() {
        // "유닛이 있다"고 단정한 문장 뒤에 "index units: unknown" 이 붙으면
        // 그 답 전체를 믿을 수 없게 된다. 두 가능성을 모두 남기고 둘 다의 다음 행동을 준다.
        let unknown = facts(sourceFileCount: 214, filteredSourceFileCount: 214, unitCount: nil)
        #expect(unknown.summary.contains("index units:   unknown"))
        #expect(!unknown.remedy.contains("The store holds units"))
        #expect(unknown.remedy.contains("--index-store"))
        #expect(unknown.remedy.contains("swift build"))
    }

    @Test("심볼릭 링크로 지정했을 때만 실제 경로를 함께 보여 준다")
    func resolvedPathIsShownOnlyWhenItDiffers() {
        let same = facts(sourceFileCount: 1, filteredSourceFileCount: 1, unitCount: 1)
        #expect(!same.summary.contains("resolves to"))

        let linked = EmptyIndexFacts(
            projectPath: "/link",
            resolvedProjectPath: "/real",
            storePath: "/s",
            storeOrigin: .explicit,
            libraryPath: "/lib",
            sourceFileCount: 1,
            filteredSourceFileCount: 1,
            unitCount: 1
        )
        #expect(linked.summary.contains("resolves to /real"))
        #expect(linked.summary.contains("given by --index-store"))
    }
}
