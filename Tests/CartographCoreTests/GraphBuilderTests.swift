import CartographCore
import CartographTestSupport
import Testing

@Suite("GraphBuilder")
struct GraphBuilderTests {
    /// 두 모듈에 걸친 작은 프로젝트.
    ///
    ///   App.HomeView ──references──▶ Domain.User
    ///   App.HomeView 는 App.HomeViewModel 의 멤버를 호출한다.
    private func makeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("HomeView", kind: .structType, module: "App", path: "/p/App/HomeView.swift")
        builder.symbol(
            "HomeView.body", name: "body", kind: .property, module: "App",
            path: "/p/App/HomeView.swift", line: 3, parent: "HomeView"
        )
        builder.symbol("HomeViewModel", kind: .classType, module: "App", path: "/p/App/HomeViewModel.swift")
        builder.symbol(
            "HomeViewModel.load", name: "load", kind: .method, module: "App",
            path: "/p/App/HomeViewModel.swift", line: 5, parent: "HomeViewModel"
        )
        builder.symbol("User", kind: .structType, module: "Domain", path: "/p/Domain/User.swift")
        builder.reference(from: "HomeView.body", to: "HomeViewModel.load", kind: .call)
        builder.reference(from: "HomeViewModel.load", to: "User", kind: .reference)
        return builder.build()
    }

    @Test("모듈 레벨은 모듈당 정점 하나로 접힌다")
    func moduleLevelRollup() {
        let graph = GraphBuilder(options: .init(level: .module)).build(from: makeSnapshot())
        #expect(graph.nodeIDs == [NodeID("App"), NodeID("Domain")])
        #expect(graph.edgeCount == 1)
        #expect(graph.edges.first?.source == NodeID("App"))
        #expect(graph.edges.first?.target == NodeID("Domain"))
    }

    @Test("파일 레벨은 파일당 정점 하나를 만든다")
    func fileLevelRollup() {
        let graph = GraphBuilder(options: .init(level: .file)).build(from: makeSnapshot())
        #expect(graph.nodeCount == 3)
        #expect(graph.node("/p/App/HomeView.swift")?.name == "HomeView.swift")
        #expect(graph.successors(of: "/p/App/HomeView.swift") == [NodeID("/p/App/HomeViewModel.swift")])
    }

    @Test("타입 레벨은 멤버를 소유 타입으로 접는다")
    func typeLevelRollup() {
        let graph = GraphBuilder(options: .init(level: .type)).build(from: makeSnapshot())
        #expect(graph.nodeIDs == [NodeID("HomeView"), NodeID("HomeViewModel"), NodeID("User")])
        #expect(graph.successors(of: "HomeView") == [NodeID("HomeViewModel")])
        #expect(graph.successors(of: "HomeViewModel") == [NodeID("User")])
    }

    @Test("심볼 레벨은 모든 선언을 유지하고 포함 간선을 추가한다")
    func symbolLevelKeepsMembers() {
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: makeSnapshot())
        #expect(graph.nodeCount == 5)
        let memberEdges = graph.edges.filter { $0.kind == .member }
        #expect(memberEdges.count == 2)
        #expect(memberEdges.contains { $0.source == "HomeView" && $0.target == "HomeView.body" })
    }

    @Test("익스텐션은 확장 대상 타입으로 접힌다")
    func extensionsFoldIntoExtendedType() {
        var builder = SnapshotBuilder()
        builder.symbol("User", kind: .structType, module: "Domain")
        builder.symbol("ext:User", name: "User", kind: .extensionDeclaration, module: "App")
        builder.symbol(
            "ext:User.displayName", name: "displayName", kind: .property,
            module: "App", parent: "ext:User"
        )
        builder.symbol("Formatter", kind: .structType, module: "App")
        builder.reference(from: "ext:User", to: "User", kind: .extends)
        builder.reference(from: "ext:User.displayName", to: "Formatter", kind: .reference)

        let graph = GraphBuilder(options: .init(level: .type)).build(from: builder.build())
        #expect(graph.node("ext:User") == nil)
        #expect(graph.successors(of: "User") == [NodeID("Formatter")])
    }

    @Test("외부 심볼은 기본적으로 제외된다")
    func externalSymbolsExcludedByDefault() {
        var builder = SnapshotBuilder()
        builder.symbol("MyType", kind: .structType, module: "App")
        builder.symbol("UIView", kind: .classType, module: "UIKit", isExternal: true)
        builder.reference(from: "MyType", to: "UIView", kind: .inheritance)
        let snapshot = builder.build()

        let excluded = GraphBuilder(options: .init(level: .type)).build(from: snapshot)
        #expect(excluded.nodeCount == 1)
        #expect(excluded.edgeCount == 0)

        let included = GraphBuilder(options: .init(level: .type, includeExternal: true)).build(from: snapshot)
        #expect(included.nodeCount == 2)
        #expect(included.edgeCount == 1)
    }

    @Test("경로 필터가 심볼을 걸러 낸다")
    func pathFilterExcludesSymbols() {
        let options = GraphBuilder.Options(
            level: .type,
            pathFilter: PathFilter(exclude: ["**/Domain/**"])
        )
        let graph = GraphBuilder(options: options).build(from: makeSnapshot())
        #expect(graph.node("User") == nil)
        #expect(graph.nodeCount == 2)
    }

    @Test("간선 종류 필터가 적용된다")
    func edgeKindFilter() {
        let options = GraphBuilder.Options(level: .type, edgeKinds: [.call])
        let graph = GraphBuilder(options: options).build(from: makeSnapshot())
        #expect(graph.edgeCount == 1)
        #expect(graph.edges.allSatisfy { $0.kind == .call })
    }

    @Test("롤업으로 생긴 자기 순환은 기본적으로 제거된다")
    func selfLoopsAreDroppedByDefault() {
        let dropped = GraphBuilder(options: .init(level: .module)).build(from: makeSnapshot())
        #expect(dropped.edges.allSatisfy { !$0.isSelfLoop })

        let kept = GraphBuilder(options: .init(level: .module, dropSelfLoops: false))
            .build(from: makeSnapshot())
        #expect(kept.edges.contains { $0.isSelfLoop })
    }

    @Test("순환하는 부모 관계에서도 무한 루프에 빠지지 않는다")
    func cyclicParentChainTerminates() {
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .method, parent: "B")
        builder.symbol("B", kind: .method, parent: "A")
        let graph = GraphBuilder(options: .init(level: .type)).build(from: builder.build())
        #expect(graph.nodeCount <= 2)
    }

    @Test("빈 스냅샷은 빈 그래프가 된다")
    func emptySnapshot() {
        let graph = GraphBuilder().build(from: IndexSnapshot())
        #expect(graph.isEmpty)
    }
}

@Suite("GraphBuilder.BuildResult")
struct GraphBuildResultTests {
    @Test("USR 매핑으로 정점에 접힌 심볼을 되짚을 수 있다")
    func nodeIDMappingIsExposed() {
        var builder = SnapshotBuilder()
        builder.symbol("Type", kind: .structType, module: "App")
        builder.symbol("Type.method", name: "method", kind: .method, module: "App", parent: "Type")
        let result = GraphBuilder(options: .init(level: .type)).buildResult(from: builder.build())

        #expect(result.nodeIDByUSR["Type.method"] == NodeID("Type"))
        #expect(result.usrs(for: "Type") == ["Type", "Type.method"])
        #expect(result.usrs(for: "없음").isEmpty)
        #expect(result.graph.nodeCount == 1)
    }
}
