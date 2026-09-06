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

@Suite("익스텐션 롤업의 경계")
struct ExtensionRollupEdgeCaseTests {
    @Test("익스텐션이 서로를 확장하는 비정상 인덱스에서도 소유 타입을 찾는다")
    func mutuallyExtendingExtensionsStillResolveToOwner() {
        // 정상 Swift 인덱스에서는 일어나지 않지만, 손상된 인덱스에서 이 가드가
        // 없으면 멤버가 소유 타입 대신 익스텐션 정점에 남는다.
        var builder = SnapshotBuilder()
        builder.symbol("T", kind: .structType)
        builder.symbol("E1", name: "T", kind: .extensionDeclaration, parent: "T")
        builder.symbol("E2", name: "T", kind: .extensionDeclaration, parent: "T")
        builder.symbol("M", name: "m()", kind: .method, parent: "E1")
        builder.reference(from: "E1", to: "E2", kind: .extends)
        builder.reference(from: "E2", to: "E1", kind: .extends)

        let result = GraphBuilder(options: .init(level: .type)).buildResult(from: builder.build())
        #expect(result.nodeIDByUSR["M"] == NodeID("T"))
    }
}

@Suite("롤업과 경로 필터")
struct RollupFilterTests {
    @Test("제외된 소유 타입으로 접지 않는다")
    func excludedOwnerIsNotPulledIn() {
        // 익스텐션 멤버가 제외된 파일의 타입을 소유자로 끌어오면 exclude 가
        // 조용히 무력화된다.
        var builder = SnapshotBuilder()
        builder.symbol("Foo", kind: .structType, path: "/p/Generated/Foo.swift")
        builder.symbol("ext", name: "Foo", kind: .extensionDeclaration, path: "/p/Sources/FooExt.swift")
        builder.symbol("ext.bar", name: "bar()", kind: .method, path: "/p/Sources/FooExt.swift", parent: "ext")
        builder.reference(from: "ext", to: "Foo", kind: .extends)

        let graph = GraphBuilder(options: .init(
            level: .type,
            pathFilter: PathFilter(exclude: ["**/Generated/**"])
        )).build(from: builder.build())

        #expect(graph.node("Foo") == nil)
        #expect(graph.node("ext.bar") != nil)
    }

    @Test("분석 범위 밖 타입으로도 접지 않는다")
    func externalOwnerIsNotPulledIn() {
        // `extension UIView` 처럼 소유자가 SDK 타입이면 그것으로 접을 수 없다. 접으면
        // 우리 코드의 멤버가 SDK 타입 정점으로 사라진다. 경로 필터가 아니라 `isExternal`
        // 이 막는 자리이고, 경로별 판정으로 바꾸면서 이 조합에 테스트가 없다는 것이 드러났다.
        var builder = SnapshotBuilder()
        builder.symbol("UIView", kind: .classType, path: "/sdk/UIKit.swift", isExternal: true)
        builder.symbol("ext", name: "UIView", kind: .extensionDeclaration, path: "/p/Sources/ViewExt.swift")
        builder.symbol("ext.bar", name: "bar()", kind: .method, path: "/p/Sources/ViewExt.swift", parent: "ext")
        builder.reference(from: "ext", to: "UIView", kind: .extends)

        let graph = GraphBuilder(options: .init(level: .type)).build(from: builder.build())
        #expect(graph.node("UIView") == nil)
        #expect(graph.node("ext.bar") != nil)
    }

    @Test("포함된 소유 타입으로는 정상적으로 접는다")
    func includedOwnerStillRollsUp() {
        var builder = SnapshotBuilder()
        builder.symbol("Foo", kind: .structType, path: "/p/Sources/Foo.swift")
        builder.symbol("ext", name: "Foo", kind: .extensionDeclaration, path: "/p/Sources/FooExt.swift")
        builder.symbol("ext.bar", name: "bar()", kind: .method, path: "/p/Sources/FooExt.swift", parent: "ext")
        builder.reference(from: "ext", to: "Foo", kind: .extends)

        let graph = GraphBuilder(options: .init(level: .type)).build(from: builder.build())
        #expect(graph.nodeIDs == [NodeID("Foo")])
    }

    /// 참조 배열의 순서가 결과 그래프에 남지 않는지.
    ///
    /// `IndexStoreProvider` 는 참조를 정렬하지 않고 넘긴다. 인덱스에서 읽은 순서 그대로다.
    /// 그래도 되는 이유는 `CodeGraph.init` 이 간선을 서명으로 접은 뒤 다시 정렬하기
    /// 때문인데, 그것은 코드가 지금 그렇다는 사실일 뿐 계약이 아니었다. 여기서 계약으로
    /// 만든다. 이 테스트가 깨지면 참조 순서가 출력에 새는 경로가 생긴 것이므로,
    /// 정렬을 되살리든 새 경로를 고치든 둘 중 하나를 해야 한다.
    @Test("참조를 어떤 순서로 넣어도 그래프가 같다")
    func referenceOrderDoesNotReachTheGraph() {
        func snapshot(reversed: Bool) -> IndexSnapshot {
            var builder = SnapshotBuilder()
            for name in ["A", "B", "C", "D"] {
                builder.symbol(name, kind: .structType, path: "/p/Sources/\(name).swift")
            }
            builder.symbol("ext", name: "D", kind: .extensionDeclaration, path: "/p/Sources/DExt.swift")
            builder.symbol("ext.run", name: "run()", kind: .method, path: "/p/Sources/DExt.swift", parent: "ext")
            var edges: [(String, String, EdgeKind)] = [
                ("A", "B", .reference), ("B", "C", .call), ("C", "D", .conformance),
                ("A", "C", .call), ("D", "A", .reference), ("A", "B", .call),
                // 서명이 같은 쌍. 가중치를 더해 접는 경로를 실제로 밟게 한다.
                // 이것이 없으면 "먼저 온 것이 이긴다" 로 바꿔도 테스트가 통과한다.
                ("B", "C", .call),
                // 익스텐션 간선. 순서 계약이 실제로 필요한 유일한 소비자가
                // `extensionTargets` 이므로 그 경로도 함께 지난다.
                ("ext", "D", .extends), ("ext.run", "A", .call),
            ]
            if reversed { edges.reverse() }
            for edge in edges { builder.reference(from: edge.0, to: edge.1, kind: edge.2) }
            return builder.build()
        }

        for level in [GraphLevel.symbol, .type, .file, .module] {
            let options = GraphBuilder.Options(level: level)
            let forward = GraphBuilder(options: options).build(from: snapshot(reversed: false))
            let backward = GraphBuilder(options: options).build(from: snapshot(reversed: true))
            #expect(forward.edges == backward.edges, "\(level) 에서 간선 순서가 갈렸다")
            #expect(forward.nodeIDs == backward.nodeIDs, "\(level) 에서 정점 순서가 갈렸다")
        }
    }

    /// 같은 익스텐션 USR 에 확장 대상이 둘 오면 순서와 무관하게 같은 것을 고르는지.
    ///
    /// 실제 인덱스에서는 관측되지 않은 형태다. 그래도 참조를 정렬하지 않게 된 뒤로는
    /// "마지막이 이긴다" 가 곧 "인덱스가 준 순서가 이긴다" 라서, 언젠가 이 형태가
    /// 나타나면 같은 프로젝트에 두 답이 나온다. 그 문을 닫아 둔다.
    @Test("익스텐션 대상이 둘이어도 순서에 따라 갈리지 않는다")
    func extensionTargetIsOrderIndependent() {
        func graph(reversed: Bool) -> CodeGraph {
            var builder = SnapshotBuilder()
            builder.symbol("Alpha", kind: .structType, path: "/p/Sources/Alpha.swift")
            builder.symbol("Beta", kind: .structType, path: "/p/Sources/Beta.swift")
            builder.symbol("ext", name: "Alpha", kind: .extensionDeclaration, path: "/p/Sources/Ext.swift")
            builder.symbol("ext.run", name: "run()", kind: .method, path: "/p/Sources/Ext.swift", parent: "ext")
            var targets = ["Alpha", "Beta"]
            if reversed { targets.reverse() }
            for target in targets { builder.reference(from: "ext", to: target, kind: .extends) }
            return GraphBuilder(options: .init(level: .type)).build(from: builder.build())
        }
        #expect(graph(reversed: false).nodeIDs == graph(reversed: true).nodeIDs)
        #expect(graph(reversed: false).edges == graph(reversed: true).edges)
    }
}
