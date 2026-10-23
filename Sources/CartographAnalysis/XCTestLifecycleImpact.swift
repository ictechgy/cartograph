import CartographCore

/// XCTest가 암묵적으로 실행하는 생명주기와 상속 테스트를 컴파일러 간선과 구분한다.
///
/// 포함 관계 전체를 호출로 바꾸면 쓰이지 않는 도우미까지 모든 테스트에 전파된다.
/// 실행 계약이 알려진 메서드만 연결하고, 하위 클래스의 다른 모듈 실행도 보존한다.
public struct XCTestLifecycleImpact: Sendable, Equatable {
    /// 상속만 하고 테스트를 새로 선언하지 않는 클래스도 실행 대상이다.
    public let testClasses: Set<NodeID>
    /// 정적 XCTest 실행 계약이다. 실제 실행을 관측했다는 뜻은 아니다.
    public let dependencies: [ImpactDependency]

    /// 테스트 판정은 영향 질의에만 적용하며 미사용 코드의 보존 정책을 바꾸지 않는다.
    public init(in graph: CodeGraph) {
        self.init(in: graph, identity: nil)
    }

    /// 스냅샷 신원이 있으면 unitTest 비트만 있는 앱 메서드를 XCTest 실행 계약으로 만들지 않는다.
    /// 신원 없는 기존 그래프 전용 API는 호환성을 위해 보수적인 옛 후보 집합을 유지한다.
    public init(in graph: CodeGraph, identity: XCTestIdentityFacts?) {
        var classes: Set<NodeID> = []
        var methods: [NodeID: [GraphNode]] = [:]
        for node in graph.sortedNodes {
            if node.kind == .classType,
               identity.map({ $0.classUSRs.contains(node.id.rawValue) }) ?? node.attributes.contains(.unitTest) {
                classes.insert(node.id)
            }
            guard node.kind == .method, let owner = graph.semanticParent(of: node.id),
                  graph.node(owner)?.kind == .classType else { continue }
            let testMethod = identity.map { $0.methodUSRs.contains(node.id.rawValue) }
                ?? node.attributes.contains(.unitTest)
            if testMethod { classes.insert(owner) }
            if Self.isLifecycle(node) || testMethod {
                methods[owner, default: []].append(node)
            }
        }
        var pending = classes.sorted()
        var index = 0
        while index < pending.count {
            let current = pending[index]
            index += 1
            for edge in graph.incomingEdges(to: current) where edge.kind == .inheritance {
                guard graph.node(edge.source)?.kind == .classType,
                      identity.map({ $0.classUSRs.contains(edge.source.rawValue) }) ?? true,
                      classes.insert(edge.source).inserted else { continue }
                pending.append(edge.source)
            }
        }
        testClasses = classes
        let provedOwners = identity.map { Set($0.classUSRs.map { NodeID($0) }) }
        dependencies = classes.sorted().flatMap { testClass in
            Self.dependencies(for: testClass, methods: methods, graph: graph,
                provedOwners: provedOwners)
        }
    }

    private static func isLifecycle(_ node: GraphNode) -> Bool {
        let names: Set<String> = ["setUp", "setUpWithError", "tearDown", "tearDownWithError"]
        // Clang 메서드는 괄호 없이, Swift 메서드는 빈 인자 목록과 함께 기록된다.
        return names.contains(node.baseName) && (node.name == node.baseName || node.name == node.baseName + "()")
    }

    private static func dependencies(
        for testClass: NodeID, methods: [NodeID: [GraphNode]], graph: CodeGraph, provedOwners: Set<NodeID>?
    ) -> [ImpactDependency] {
        var pending = [testClass]
        var seen: Set<NodeID> = []
        var result: [ImpactDependency] = []
        while let owner = pending.popLast() {
            guard provedOwners?.contains(owner) ?? true else { continue }
            guard seen.insert(owner).inserted else { continue }
            for method in methods[owner] ?? [] {
                let lifecycle = isLifecycle(method)
                guard lifecycle || owner != testClass else { continue }
                let kind = lifecycle ? "xctest-lifecycle" : "xctest-inherited-test"
                result.append(ImpactDependency(source: testClass, target: method.id,
                    contract: "\(kind):\(testClass.rawValue):\(method.id.rawValue)", origin: .automatic))
            }
            // 오버라이드가 있어도 super 호출과 클래스/인스턴스 실행을 증명하지 못하므로 넓게 유지한다.
            pending += graph.outgoingEdges(from: owner).filter { $0.kind == .inheritance }
                .map(\.target).filter { graph.node($0)?.kind == .classType }
        }
        return result.sorted { $0.target < $1.target }
    }
}
