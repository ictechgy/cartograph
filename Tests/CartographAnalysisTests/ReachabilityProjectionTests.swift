import CartographAnalysis
import CartographCore
import CartographTestSupport
import Testing

@Suite("질의용 도달성 투영과 전체 분석의 동등성")
struct ReachabilityProjectionTests {
    @Test("조건부 증인·기본 구현·상속·무시 근거의 모든 정점 설명을 전체 분석과 맞춘다",
          arguments: [false, true], [false, true])
    func allNodeParity(ownerIsUsed: Bool, reverseOverrides: Bool) {
        let snapshot = witnessSnapshot(ownerIsUsed: ownerIsUsed)
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        for testOnly in [false, true] {
            let analyzer = ReachabilityAnalyzer(options: .init(
                reportMembersOfUnusedTypes: true,
                followOverridesInReverse: reverseOverrides,
                findsTestOnlyCode: testOnly
            ))
            let full = analyzer.analyze(graph: graph, snapshot: snapshot)
            let projection = analyzer.analyzeReachability(graph: graph, snapshot: snapshot)
            expectParity(projection, full, graph: graph)
            #expect(full.unused.contains { $0.id == "Dead" })
            #expect(full.testOnly.contains { $0.id == "TestHelper" } == testOnly)
            #expect(full.explain("Ignored.member", in: graph) == .retained(.ignoreComment))
            #expect(full.explain("Ignored", in: graph) == .retainedByMember(
                InheritedRetention(member: "Ignored.member", reason: .ignoreComment)
            ))
            #expect(full.retentions["Owner.body"] == (ownerIsUsed ? .externalOverride : nil))
            if ownerIsUsed {
                #expect(full.explain("Owner.deinit", in: graph)
                    == .reachable(path: ["Root", "Later", "Owner", "Owner.deinit"]))
            } else {
                #expect(full.explain("Owner.body", in: graph) == .unreachable)
                #expect(full.explain("Owner.deinit", in: graph) == .unreachable)
            }
            if reverseOverrides {
                #expect(full.explain("defaultHelper", in: graph) != .unreachable)
            } else {
                #expect(full.explain("defaultHelper", in: graph) == .unreachable)
            }
        }
    }

    @Test("외부·필터 밖 익스텐션 소유자는 증인을 잘못 가두지 않는다", arguments: [false, true])
    func unavailableExtensionOwner(includeExternal: Bool) {
        var builder = SnapshotBuilder()
        builder.symbol("Root", attributes: [.entryPoint])
        builder.symbol("Extension", kind: .extensionDeclaration)
        builder.symbol("Extension.required", kind: .method, parent: "Extension",
                       attributes: [.overrideDeclaration])
        builder.symbol("SDKType", kind: .classType, isExternal: true)
        builder.symbol("Dead")
        builder.reference(from: "Extension", to: "SDKType", kind: .extends)
        builder.reference(from: "Extension.required", to: "sdk:requirement", kind: .overrides)
        var snapshot = builder.build()
        // 같은 관계를 남겨 두고 SDK 선언 자체의 유무를 바꾼다.
        if !includeExternal { snapshot.symbols.removeAll { $0.usr == "SDKType" } }
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let analyzer = ReachabilityAnalyzer()
        let full = analyzer.analyze(graph: graph, snapshot: snapshot)
        expectParity(analyzer.analyzeReachability(graph: graph, snapshot: snapshot), full, graph: graph)
        #expect(full.retentions["Extension.required"] == .externalOverride)
        #expect(full.unused.contains { $0.id == "Dead" })
    }

    @Test("필터로 소유 타입이 빠진 익스텐션도 전체 분석의 보수적 근거를 유지한다")
    func filteredExtensionOwner() {
        var builder = SnapshotBuilder(path: "/project/App.swift")
        builder.symbol("Root", attributes: [.entryPoint])
        builder.symbol("Hidden", path: "/project/Hidden.swift")
        builder.symbol("Extension", kind: .extensionDeclaration)
        builder.symbol("Extension.required", kind: .method, parent: "Extension",
                       attributes: [.overrideDeclaration])
        builder.reference(from: "Extension", to: "Hidden", kind: .extends)
        builder.reference(from: "Extension.required", to: "sdk:requirement", kind: .overrides)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol,
            pathFilter: PathFilter(exclude: ["Hidden.swift"], basePath: "/project"))).build(from: snapshot)
        let analyzer = ReachabilityAnalyzer()
        let full = analyzer.analyze(graph: graph, snapshot: snapshot)
        expectParity(analyzer.analyzeReachability(graph: graph, snapshot: snapshot), full, graph: graph)
        #expect(!graph.contains("Hidden"))
        #expect(full.retentions["Extension.required"] == .externalOverride)
    }

    @Test("직접 클래스 오버라이드와 역방향 디스패치의 설명이 같다", arguments: [false, true])
    func classOverrides(reverse: Bool) {
        var builder = SnapshotBuilder()
        builder.symbol("Root", attributes: [.entryPoint])
        builder.symbol("Base", kind: .classType)
        builder.symbol("Base.run", kind: .method, parent: "Base")
        builder.symbol("Derived", kind: .classType)
        builder.symbol("Derived.run", kind: .method, parent: "Derived")
        builder.reference(from: "Root", to: reverse ? "Base.run" : "Derived.run", kind: .call)
        builder.reference(from: "Root", to: "Derived", kind: .reference)
        builder.reference(from: "Derived", to: "Base", kind: .inheritance)
        builder.reference(from: "Derived.run", to: "Base.run", kind: .overrides)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let analyzer = ReachabilityAnalyzer(options: .init(followOverridesInReverse: reverse))
        let full = analyzer.analyze(graph: graph, snapshot: snapshot)
        expectParity(analyzer.analyzeReachability(graph: graph, snapshot: snapshot), full, graph: graph)
        #expect(full.explain("Base.run", in: graph) != .unreachable)
        #expect(full.explain("Derived.run", in: graph) != .unreachable)
    }

    @Test("투영을 만든 뒤에도 전체 분석의 미사용·파라미터·무시 발견이 그대로 남는다")
    func deadDiagnosticsRemainPresent() {
        var builder = SnapshotBuilder()
        builder.symbol("Root", kind: .function, attributes: [.entryPoint])
        builder.symbol("UsedIgnore", kind: .function, attributes: [.ignoreComment])
        builder.symbol("Dead", kind: .function)
        builder.reference(from: "Root", to: "UsedIgnore", kind: .call)
        builder.parameter("input", name: "input", functionUSR: "Root", isReferenced: false)
        let snapshot = builder.build()
        let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
        let analyzer = ReachabilityAnalyzer()
        let before = analyzer.analyze(graph: graph, snapshot: snapshot)
        let projection = analyzer.analyzeReachability(graph: graph, snapshot: snapshot)
        let after = analyzer.analyze(graph: graph, snapshot: snapshot)
        #expect(before == after)
        #expect(before.unused.map(\.id) == ["Dead"])
        #expect(before.unusedParameters.map(\.usr) == ["input"])
        #expect(before.superfluousIgnores.map(\.node.id) == ["UsedIgnore"])
        expectParity(projection, before, graph: graph)
    }

    @Test("여러 뿌리와 다이아몬드의 첫 경로는 입력 배열 순서가 바뀌어도 같다")
    func deterministicFirstPath() {
        var builder = SnapshotBuilder()
        for root in ["BRoot", "ARoot"] { builder.symbol(root, attributes: [.entryPoint]) }
        for node in ["Right", "Left", "Target", "Dead"] { builder.symbol(node) }
        for root in ["BRoot", "ARoot"] {
            builder.reference(from: root, to: "Right", kind: .call)
            builder.reference(from: root, to: "Left", kind: .call)
        }
        builder.reference(from: "Right", to: "Target", kind: .call)
        builder.reference(from: "Left", to: "Target", kind: .call)
        let original = builder.build()
        var reversed = original
        reversed.symbols.reverse()
        reversed.references.reverse()
        for snapshot in [original, reversed] {
            let graph = GraphBuilder(options: .init(level: .symbol)).build(from: snapshot)
            let analyzer = ReachabilityAnalyzer()
            let full = analyzer.analyze(graph: graph, snapshot: snapshot)
            expectParity(analyzer.analyzeReachability(graph: graph, snapshot: snapshot), full, graph: graph)
            #expect(full.explain("Target", in: graph) == .reachable(path: ["ARoot", "Left", "Target"]))
        }
    }

    @Test("설명 우선순위와 순환 선행자 방어를 공개 보고서와 동일하게 유지한다")
    func explanationPrecedenceAndCycles() {
        let nodes = ["root", "owner", "cycleA", "cycleB", "dead"].map {
            GraphNode(id: NodeID($0), name: $0, kind: .function)
        }
        let graph = CodeGraph(level: .symbol, nodes: nodes, edges: [])
        let inherited = InheritedRetention(member: "root", reason: .interfaceBuilder)
        let retentions: [NodeID: RetentionReason] = ["root": .entryPoint, "missing": .ignoreComment]
        let inheritedRetentions: [NodeID: InheritedRetention] = ["root": inherited, "owner": inherited]
        let predecessors: [NodeID: NodeID] = [
            "root": "cycleA", "owner": "cycleA", "cycleA": "cycleB", "cycleB": "cycleA",
        ]
        let full = UnusedCodeReport(unused: [], retentions: retentions, reachableCount: 4,
            totalCount: 5, inheritedRetentions: inheritedRetentions, predecessors: predecessors)
        let projection = ReachabilityReport(retentions: retentions,
            inheritedRetentions: inheritedRetentions, predecessors: predecessors)
        expectParity(projection, full, graph: graph)
        #expect(projection.explain("missing", in: graph) == .unknown)
        #expect(projection.explain("root", in: graph) == .retained(.entryPoint))
        #expect(projection.explain("owner", in: graph) == .retainedByMember(inherited))
        #expect(projection.explain("cycleA", in: graph) == .reachable(path: ["cycleB", "cycleA"]))
        #expect(projection.explain("dead", in: graph) == .unreachable)
        // 공개 Equatable은 설명에 쓰이지 않는 발견과 수치도 계속 구분한다.
        let different = UnusedCodeReport(unused: nodes, retentions: retentions, reachableCount: 0,
            totalCount: 5, inheritedRetentions: inheritedRetentions, predecessors: predecessors)
        #expect(full != different)
        #expect(full.reachability == different.reachability)
    }

    @Test("빈 그래프도 전체 보고서와 같은 미확인 설명을 준다")
    func emptyGraph() {
        let snapshot = IndexSnapshot()
        let graph = CodeGraph(level: .symbol, nodes: [], edges: [])
        let analyzer = ReachabilityAnalyzer()
        expectParity(analyzer.analyzeReachability(graph: graph, snapshot: snapshot),
                     analyzer.analyze(graph: graph, snapshot: snapshot), graph: graph)
    }

    private func expectParity(_ projection: ReachabilityReport, _ full: UnusedCodeReport, graph: CodeGraph) {
        #expect(projection == full.reachability)
        #expect(projection.retentions == full.retentions)
        #expect(projection.inheritedRetentions == full.inheritedRetentions)
        for id in graph.sortedNodes.map(\.id) + [NodeID("missing")] {
            #expect(projection.explain(id, in: graph) == full.explain(id, in: graph), "정점: \(id)")
        }
    }

    private func witnessSnapshot(ownerIsUsed: Bool) -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("Root", attributes: [.entryPoint])
        builder.symbol("Later", kind: .function)
        builder.symbol("Owner", kind: .classType)
        builder.symbol("Owner.body", kind: .property, parent: "Owner", attributes: [.overrideDeclaration])
        builder.symbol("Owner.deinit", kind: .deinitializer, parent: "Owner")
        builder.reference(from: "Owner.body", to: "sdk:body", kind: .overrides)
        builder.reference(from: "Owner.body", to: "Owner", kind: .reference)
        builder.reference(from: "Root", to: "Later", kind: .call)
        if ownerIsUsed { builder.reference(from: "Later", to: "Owner", kind: .reference) }
        builder.symbol("Parent", kind: .protocolType)
        builder.symbol("Parent.run", kind: .method, parent: "Parent")
        builder.symbol("Child", kind: .protocolType)
        builder.symbol("Child.run", kind: .method, parent: "Child")
        builder.symbol("Defaults", kind: .extensionDeclaration)
        builder.symbol("Defaults.run", kind: .method, parent: "Defaults")
        builder.symbol("defaultHelper", kind: .function)
        builder.reference(from: "Root", to: "Child.run", kind: .call)
        builder.reference(from: "Child.run", to: "Parent.run", kind: .overrides)
        builder.reference(from: "Defaults", to: "Parent", kind: .extends)
        builder.reference(from: "Defaults.run", to: "Parent.run", kind: .overrides)
        builder.reference(from: "Defaults.run", to: "defaultHelper", kind: .call)
        builder.symbol("Ignored", kind: .classType)
        builder.symbol("Ignored.member", kind: .method, parent: "Ignored", attributes: [.ignoreComment])
        builder.symbol("Ignored.zInherited", kind: .method, parent: "Ignored.member",
                       attributes: [.ignoreComment, .ignoreInherited])
        builder.symbol("TestRoot", kind: .function, module: "AppTests", attributes: [.testFunction])
        builder.symbol("TestHelper", kind: .function)
        builder.reference(from: "TestRoot", to: "TestHelper", kind: .call)
        builder.symbol("Dead", kind: .function)
        builder.symbol("DeadCycleA", kind: .function)
        builder.symbol("DeadCycleB", kind: .function)
        builder.reference(from: "DeadCycleA", to: "DeadCycleB", kind: .call)
        builder.reference(from: "DeadCycleB", to: "DeadCycleA", kind: .call)
        return builder.build()
    }
}
