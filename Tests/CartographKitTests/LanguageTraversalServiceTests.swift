import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("language-traversal 문서")
struct LanguageTraversalServiceTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("root 와 도달 정점의 id 는 인덱스 USR 이고 이름에 감싸는 타입이 붙는다")
    func usesIndexIdentitiesAndContainerNames() throws {
        let (service, context) = fixture()
        let document = try service.languageTraversalDocument(
            symbols: ["s:Client.logout", "s:Client.fetch"], generatedAt: fixedDate, in: context)
        #expect(document.format == "language-traversal")
        #expect(document.version == 1)
        #expect(document.platform == "swift")
        #expect(document.direction == "dependents")
        #expect(document.project == "/p")
        #expect(document.roots.map(\.id) == ["s:Client.logout", "s:Client.fetch"])
        #expect(document.roots.map { $0.symbol?.usr } == ["s:Client.logout", "s:Client.fetch"])
        let body = try #require(document.reached.first { $0.symbol.usr == "s:Screen.body" })
        #expect(body.symbol.qualifiedName == "Screen.body")
        #expect(body.symbol.location?.path == "Sources/Screen.swift")
        #expect(body.roots == [0, 1])
        #expect(body.relationships == ["call", "dependent"])
        #expect(body.evidence == "direct")
    }

    @Test("SwiftUI body 처럼 프로그램 밖에서 불리는 선언은 호출자를 지어내지 않고 한계로 밝힌다")
    func marksRuntimeInvokedEntryPoints() throws {
        let (service, context) = fixture()
        let document = try service.languageTraversalDocument(symbols: ["s:Client.logout"], generatedAt: fixedDate,
            in: context)
        #expect(!document.reached.contains { $0.via == "s:Screen.body" })
        let line = try #require(document.limitations.first { $0.hasPrefix("runtime-invoked-entry-points:") })
        #expect(line.contains("Screen.body (s:Screen.body)"))
        let forward = try service.languageTraversalDocument(symbols: ["s:Screen.body"], direction: .dependencies,
            generatedAt: fixedDate, in: context)
        #expect(!forward.limitations.contains { $0.hasPrefix("runtime-invoked-entry-points:") })
        #expect(forward.reached.map(\.symbol.usr) == ["s:Client.fetch", "s:Client.logout"])
        #expect(forward.reached.allSatisfy { $0.via == "s:Screen.body" && $0.relationships == ["call", "dependency"] })
    }

    @Test("해석하지 못한 root 는 원문 id 로 남기고 잘림과 root-not-found 를 함께 싣는다")
    func reportsUnresolvedRoots() throws {
        let (service, context) = fixture()
        let document = try service.languageTraversalDocument(
            symbols: ["Missing", "s:Client.logout"], generatedAt: fixedDate, in: context)
        #expect(document.roots.map(\.id) == ["Missing", "s:Client.logout"])
        #expect(document.roots.first?.symbol == nil)
        #expect(document.truncated)
        #expect(document.truncationReasons == ["root-not-found"])
        #expect(document.limitations.contains { $0.hasPrefix("root-not-found: Missing ") })
        // 순회 root 인덱스가 아니라 문서 root 인덱스를 싣는다.
        #expect(document.reached.first { $0.symbol.usr == "s:Screen.body" }?.roots == [1])
    }

    @Test("명령은 해석하지 못한 root 가 있으면 문서를 낸 뒤 사용 오류로 알린다")
    func commandFlagsUnresolvedRoots() throws {
        let (service, _) = fixture()
        let outcome = try service.languageTraversal(symbols: ["Missing"], generatedAt: fixedDate)
        #expect(outcome.subjectNotFound)
        #expect(outcome.output.contains("\"root-not-found\""))
        let found = try service.languageTraversal(symbols: ["s:Client.logout"], generatedAt: fixedDate)
        #expect(!found.subjectNotFound)
        #expect(throws: CartographError.self) {
            try service.languageTraversal(symbols: ["s:Client.logout"], direction: "sideways")
        }
    }

    @Test("같은 입력은 같은 바이트이고 계약에 없는 키와 신고하지 않는 필드를 싣지 않는다")
    func encodesDeterministicContractKeys() throws {
        let (service, _) = fixture()
        let first = try service.languageTraversal(symbols: ["s:Client.logout"], generatedAt: fixedDate).output
        let second = try service.languageTraversal(symbols: ["s:Client.logout"], generatedAt: fixedDate).output
        #expect(first == second)
        let object = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["format", "version", "tool", "generatedAt", "platform", "project", "direction",
            "roots", "reached", "truncated", "limitations"])
        #expect(object["generatedAt"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(!first.contains("dispatch\"") && !first.contains("unresolvedCalls"))
    }

    @Test("출력 한도로 잘리면 output 사유를 싣고 남은 행의 via 는 모두 문서 안에 있다")
    func capsOutputWithoutOrphans() throws {
        let (service, context) = fixture()
        let document = try service.languageTraversalDocument(
            symbols: ["s:Client.fetch", "s:Client.logout"], limit: 1, generatedAt: fixedDate, in: context)
        #expect(document.reached.count == 1)
        #expect(document.truncationReasons == ["output"])
        let rootIDs = Set(document.roots.map(\.id))
        let rowIDs = Set(document.reached.map(\.symbol.usr))
        #expect(document.reached.allSatisfy { rootIDs.contains($0.via) || rowIDs.contains($0.via) })
    }

    @Test("타입 root 는 멤버로 넓히지 않고 한계로 알린다")
    func doesNotExpandContainerRoots() throws {
        let (service, context) = fixture()
        let document = try service.languageTraversalDocument(symbols: ["s:Client"], generatedAt: fixedDate, in: context)
        #expect(document.limitations.contains { $0.hasPrefix("container-roots-not-expanded: 1 root(s)") })
        #expect(!document.reached.contains { $0.symbol.usr == "s:Screen.body" })
    }

    @Test("인덱스가 프로젝트 일부만 담으면 구현이 하나뿐이어도 bound 대신 candidate 로 낸다")
    func openWorldBlocksBoundEvidence() {
        #expect(CartographService.isClosedWorld(["objective-c-sources: 2 file(s)"]) == false)
        #expect(CartographService.isClosedWorld(["unindexed-sources: 3 of 9 source file(s) have no known index unit"])
            == false)
        #expect(CartographService.isClosedWorld(["external-retentions: 2 retention(s)"]))
    }

    @Test("프로젝트 밖 위치는 싣지 않는다")
    func acceptsOnlyProjectRelativePaths() {
        #expect(TraversalPresenter.isProjectRelative("Sources/A.swift"))
        #expect(!TraversalPresenter.isProjectRelative("/elsewhere/A.swift"))
        #expect(!TraversalPresenter.isProjectRelative("../A.swift"))
        #expect(!TraversalPresenter.isProjectRelative("C:/A.swift"))
        #expect(!TraversalPresenter.isProjectRelative(""))
    }

    /// 화면 `body` 가 두 route-call 선언을 부르고, `body` 는 외부 프로토콜 요구사항을 구현한다.
    /// `refresh` 는 `fetch` 만 부른다.
    private func fixture() -> (CartographService, AnalysisContext) {
        var builder = SnapshotBuilder(module: "App", path: "/p/Sources/Client.swift")
        builder.symbol("s:Client", name: "Client")
        builder.symbol("s:Client.fetch", name: "fetch()", kind: .method, line: 3, parent: "s:Client")
        builder.symbol("s:Client.logout", name: "logout()", kind: .method, line: 7, parent: "s:Client")
        builder.symbol("s:Screen", name: "Screen", path: "/p/Sources/Screen.swift")
        builder.symbol("s:Screen.body", name: "body", kind: .property, path: "/p/Sources/Screen.swift", line: 4,
            parent: "s:Screen")
        builder.symbol("s:Screen.refresh", name: "refresh()", kind: .method, path: "/p/Sources/Screen.swift", line: 9,
            parent: "s:Screen")
        builder.reference(from: "s:Screen.body", to: "s:Client.fetch", kind: .call, path: "/p/Sources/Screen.swift")
        builder.reference(from: "s:Screen.refresh", to: "s:Client.fetch", kind: .call, path: "/p/Sources/Screen.swift")
        builder.reference(from: "s:Screen.body", to: "s:Client.logout", kind: .call, path: "/p/Sources/Screen.swift")
        builder.reference(from: "s:Screen.body", to: "s:7SwiftUI4ViewP4body", kind: .overrides,
            path: "/p/Sources/Screen.swift", targetKind: .property)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let snapshot = builder.build()
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: InMemoryFileSystem(currentDirectoryPath: "/p"), indexProviderOverride: StaticIndexProvider(snapshot)))
        return (service, AnalysisContext(snapshot: snapshot))
    }
}
