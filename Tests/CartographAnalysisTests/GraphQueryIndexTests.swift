@testable import CartographAnalysis
import CartographCore
import Foundation
import Testing

@Suite("그래프 질의 색인")
struct GraphQueryIndexTests {
    @Test("긴 심볼은 정확하게 찾되 오타 추천으로 이차 비용을 만들지 않는다")
    func longIdentifiersUseExactLookupWithoutSuggestions() {
        let name = String(repeating: "A", count: 4096)
        let node = GraphNode(id: "long", name: name, kind: .function)
        let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [node], edges: []))
        #expect(index.resolve(name) == .found(node))
        #expect(index.similarCandidates(to: name + "B").isEmpty)
    }

    @Test("같은 정점의 별칭은 중복하지 않고 동명 정점은 정렬된 후보로 남긴다")
    func aliasesAndAmbiguity() {
        let first = GraphNode(id: "a", name: "run()", kind: .function, module: "App")
        let second = GraphNode(id: "b", name: "run()", kind: .function, module: "Other")
        let graph = CodeGraph(level: .symbol, nodes: [second, first], edges: [])
        let lookup = GraphQueryIndex(graph: graph)
        #expect(lookup.resolve("run") == .ambiguous([first, second]))
        #expect(lookup.resolve("run()") == .ambiguous([first, second]))
        #expect(lookup.resolve("App.run()") == .found(first))
        #expect(lookup.resolve("a") == .found(first))
        #expect(lookup.resolve("Run") == .notFound)
        #expect(lookup.resolve("") == .notFound)
    }

    @Test("USR 정확 일치는 다른 정점의 이름보다 우선한다")
    func exactIdentifierWins() {
        let first = GraphNode(id: "usr:a", name: "Thing", kind: .structType)
        let second = GraphNode(id: "b", name: "usr:a", kind: .function)
        let lookup = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [second, first], edges: []))
        #expect(lookup.resolve("usr:a") == .found(first))
        #expect(lookup.resolve("Thing") == .found(first))
    }

    @Test("이름 1000건을 물어도 2만 정점을 매번 정렬하지 않는다")
    func largeBatchReusesIndex() {
        let nodes = (0..<20_000).map {
            GraphNode(id: NodeID("usr:\($0)"), name: "symbol\($0)", kind: .function)
        }
        let lookup = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: nodes, edges: []))
        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<1_000 {
            #expect(lookup.resolve("symbol\(index)") == .found(nodes[index]))
        }
        // 이전 코드는 최적화 빌드에서도 8초 이상이었다. 색인 후 조회는 수 밀리초다.
        #expect(clock.now - start < .seconds(3))
    }

    @Test("notFound 추천은 오타와 비슷한 이름을 거리 순으로 돌려준다")
    func similarCandidatesRankByDistance() {
        let error = GraphNode(id: "usr:e", name: "CartographError()", kind: .structType, module: "Core")
        let home = GraphNode(id: "usr:h", name: "HomeView", kind: .structType, module: "App")
        let lookup = GraphQueryIndex(
            graph: CodeGraph(level: .symbol, nodes: [home, error], edges: [])
        )
        let suggestions = lookup.similarCandidates(to: "CartographErros")
        #expect(suggestions.first == error)
        #expect(!suggestions.contains(home))
    }

    @Test("추천 거리가 같으면 이름 순으로 세워 실행마다 같은 순서를 보장한다")
    func similarCandidatesAreDeterministic() {
        let second = GraphNode(id: "usr:b", name: "Abcf", kind: .structType)
        let first = GraphNode(id: "usr:a", name: "Abce", kind: .structType)
        let lookup = GraphQueryIndex(
            graph: CodeGraph(level: .symbol, nodes: [second, first], edges: [])
        )
        #expect(lookup.similarCandidates(to: "Abcd").map(\.name) == ["Abce", "Abcf"])
    }

    @Test("한 정점이 이름과 한정 이름으로 같이 걸려도 한 번만 추천된다")
    func similarCandidatesDoNotDuplicateANode() {
        // 같은 정점의 별칭 키(name·qualifiedName)가 모두 한도 안에 들면 같은
        // 정점이 목록을 두 배로 채운다. 추천은 정점을 주는 것이지 키를 주는 것이 아니다.
        let node = GraphNode(id: "usr:r", name: "UserRepX()", kind: .classType, module: "A")
        let lookup = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: [node], edges: []))
        #expect(lookup.similarCandidates(to: "UserRepX") == [node])
    }

    @Test("추천은 전혀 다른 이름과 빈 이름 앞에서 조용해진다")
    func similarCandidatesStayQuiet() {
        let node = GraphNode(id: "usr:a", name: "UserService", kind: .classType, module: "Domain")
        let lookup = GraphQueryIndex(
            graph: CodeGraph(level: .symbol, nodes: [node], edges: [])
        )
        // USR 로 직접 물었을 때는 "혹시 이것?"이 아니라 "그런 USR 은 없다"가 맞는 답이다.
        #expect(lookup.similarCandidates(to: "c:objc(cs)NSObject(im)someSelector").isEmpty)
        #expect(lookup.similarCandidates(to: "").isEmpty)
    }

    @Test("별칭의 방문 순서와 무관하게 정점의 가장 짧은 거리로 추천한다")
    func similarCandidatesUseBestAliasDistanceInEveryOrder() {
        let first = GraphNode(id: "a", name: "UserRepositoryX()", kind: .function)
        let second = GraphNode(id: "b", name: "UserRepositoryY()", kind: .function)
        let graph = CodeGraph(level: .symbol, nodes: [second, first], edges: [])
        let subject = "UserRepositoryZ"
        let names: [(key: String, value: [NodeID])] = [
            (first.name, [first.id]), (first.baseName, [first.id]),
            (second.name, [second.id]), (second.baseName, [second.id])
        ]
        #expect(GraphQueryIndex.editDistance(subject, first.name) == 3)
        #expect(GraphQueryIndex.editDistance(subject, first.baseName) == 1)
        #expect(GraphQueryIndex.editDistance(subject, second.name) == 3)
        #expect(GraphQueryIndex.editDistance(subject, second.baseName) == 1)
        let orders = permutations(names)
        #expect(orders.count == 24)
        for order in orders {
            let all = GraphQueryIndex.similarCandidates(
                to: subject, limit: 5, graph: graph, names: order
            )
            #expect(all == [first, second], "별칭 순서: \(order.map(\.key))")
            #expect(GraphQueryIndex.similarCandidates(
                to: subject, limit: 1, graph: graph, names: order
            ) == [first])
            #expect(GraphQueryIndex.similarCandidates(
                to: subject, limit: 0, graph: graph, names: order
            ).isEmpty)
        }
        // 공개 경로도 같은 선택기를 써야 한다. 이름 조회는 실패하고 추천만 반환한다.
        for nodes in [[first, second], [second, first]] {
            let index = GraphQueryIndex(graph: CodeGraph(level: .symbol, nodes: nodes, edges: []))
            #expect(index.resolve(subject) == .notFound)
            #expect(index.similarCandidates(to: subject) == [first, second])
            #expect(index.similarCandidates(to: subject.uppercased(), limit: 1) == [first])
        }
    }

    @Test("별칭의 거리가 같으면 정점별 이름 순위까지 비교한 뒤 목록을 자른다")
    func similarCandidatesUseBestAliasNameInEveryOrder() {
        let first = GraphNode(id: "a", name: "Ab()", kind: .function, module: "M")
        let second = GraphNode(id: "b", name: "Bb", kind: .function, module: "B")
        let graph = CodeGraph(level: .symbol, nodes: [second, first], edges: [])
        let subject = "M.Ab"
        let names: [(key: String, value: [NodeID])] = [
            (first.baseName, [first.id]), (first.qualifiedName, [first.id]),
            (second.qualifiedName, [second.id])
        ]
        #expect(first.baseName == "Ab")
        #expect(first.qualifiedName == "M.Ab()")
        #expect(GraphQueryIndex.editDistance(subject, first.baseName) == 2)
        #expect(GraphQueryIndex.editDistance(subject, first.qualifiedName) == 2)
        #expect(GraphQueryIndex.editDistance(subject, second.qualifiedName) == 2)
        #expect(first.baseName < second.qualifiedName && second.qualifiedName < first.qualifiedName)
        let orders = permutations(names)
        #expect(orders.count == 6)
        for order in orders {
            #expect(GraphQueryIndex.similarCandidates(
                to: subject, limit: 5, graph: graph, names: order
            ) == [first, second], "별칭 순서: \(order.map(\.key))")
            #expect(GraphQueryIndex.similarCandidates(
                to: subject, limit: 1, graph: graph, names: order
            ) == [first])
        }
        #expect(GraphQueryIndex(graph: graph).similarCandidates(to: subject) == [first, second])
    }

    @Test("동명 별칭은 기존 첫 대표 정점을 유지하고 정점을 중복 추천하지 않는다")
    func similarCandidatesKeepFirstRepresentativeForSharedAlias() {
        let first = GraphNode(id: "a", name: "UserRepositoryX()", kind: .function)
        let second = GraphNode(id: "b", name: first.name, kind: .function)
        let graph = CodeGraph(level: .symbol, nodes: [second, first], edges: [])
        let names: [(key: String, value: [NodeID])] = [
            (first.name, [first.id, second.id]), (first.baseName, [first.id, second.id])
        ]
        for order in permutations(names) {
            #expect(GraphQueryIndex.similarCandidates(
                to: "UserRepositoryZ", limit: 5, graph: graph, names: order
            ) == [first])
        }
        let index = GraphQueryIndex(graph: graph)
        #expect(index.resolve(first.baseName) == .ambiguous([first, second]))
        #expect(index.similarCandidates(to: "UserRepositoryZ") == [first])
    }


    @Test("다른 모듈의 동명 타입과 메서드 및 프로퍼티는 USR로 구분한다")
    func moduleQualifiedLookupSeparatesIdenticalTypeAndMemberNames() {
        let leftType = GraphNode(id: "s:4Left3BoxV", name: "Box", kind: .structType, module: "Left")
        let rightType = GraphNode(id: "s:5Right3BoxV", name: "Box", kind: .structType, module: "Right")
        let leftMethod = GraphNode(
            id: "s:4Left3BoxV3runyyF", name: "run()", kind: .method, module: "Left"
        )
        let rightMethod = GraphNode(
            id: "s:5Right3BoxV3runyyF", name: "run()", kind: .method, module: "Right"
        )
        let leftProperty = GraphNode(
            id: "s:4Left3BoxV5valueSSvp", name: "value", kind: .property, module: "Left"
        )
        let rightProperty = GraphNode(
            id: "s:5Right3BoxV5valueSSvp", name: "value", kind: .property, module: "Right"
        )
        let graph = CodeGraph(
            level: .symbol,
            nodes: [rightProperty, rightMethod, rightType, leftProperty, leftMethod, leftType],
            edges: [
                GraphEdge(source: leftType.id, target: leftMethod.id, kind: .member),
                GraphEdge(source: leftType.id, target: leftProperty.id, kind: .member),
                GraphEdge(source: rightType.id, target: rightMethod.id, kind: .member),
                GraphEdge(source: rightType.id, target: rightProperty.id, kind: .member)
            ]
        )
        let index = GraphQueryIndex(graph: graph)
        #expect(index.resolve("Box") == .ambiguous([leftType, rightType]))
        #expect(index.resolve("run") == .ambiguous([leftMethod, rightMethod]))
        #expect(index.resolve("value") == .ambiguous([leftProperty, rightProperty]))
        #expect(index.resolve("Box.run") == .ambiguous([leftMethod, rightMethod]))
        #expect(index.resolve("Box.value") == .ambiguous([leftProperty, rightProperty]))
        #expect(index.resolve("Left.Box") == .found(leftType))
        #expect(index.resolve("Right.Box") == .found(rightType))
        #expect(index.resolve("Left.Box.run") == .found(leftMethod))
        #expect(index.resolve("Right.Box.run()") == .found(rightMethod))
        #expect(index.resolve("Left.Box.value") == .found(leftProperty))
        #expect(index.resolve("Right.Box.value") == .found(rightProperty))
        for node in [leftType, rightType, leftMethod, rightMethod, leftProperty, rightProperty] {
            #expect(index.resolve(node.id.rawValue) == .found(node))
        }
        #expect(index.resolve("Missing.Box.run") == .notFound)
        #expect(index.resolve("Missing.Box.value") == .notFound)
    }

    /// 사전의 난수 시드에 기대지 않고, 같은 실제 별칭을 방문하는 모든 순서를 검사한다.
    private func permutations<Element>(_ elements: [Element]) -> [[Element]] {
        guard !elements.isEmpty else { return [[]] }
        return elements.indices.flatMap { index in
            var remaining = elements
            let first = remaining.remove(at: index)
            return permutations(remaining).map { [first] + $0 }
        }
    }
}
