import CartographCore

/// `xcodebuild -only-testing:` 에 넘길 XCTest 식별자를 원시 프레임워크 근거와 그래프에서 만든다.
///
/// 틀린 식별자는 오류가 아니라 "테스트 0개 실행, 통과"라는 조용한 누락이 된다.
/// 그래서 증명할 수 있는 형태만 답하고 나머지는 nil 이다. 호출부는 nil 을 그
/// 테스트 모듈 전체 선택으로 넓혀야 한다. Swift Testing 식별자는 Xcode 버전에 따라
/// 받아들이는 형태가 달라 여기서 만들지 않는다.
public enum XCTestIdentifier {
    /// 테스트 선언 하나의 `Module/Class` 또는 `Module/Class/method` 식별자.
    ///
    /// - Parameters:
    ///   - id: 테스트 선언 정점.
    ///   - graph: 심볼 레벨 그래프.
    ///   - canProveClassHierarchy: 그래프가 포함·상속 간선과 모든 경로를 담고 있는지.
    ///     간선 종류나 경로를 좁힌 그래프에서는 하위 클래스가 보이지 않을 수 있어
    ///     "하위 클래스 없음"을 증명할 수 없다.
    ///   - identity: 같은 스냅샷의 프레임워크 근거. 없으면 좁히지 않는다.
    /// - Returns: 모듈 이름이 테스트 타깃 이름이라는 호출부 계약 아래의 식별자. 근거가 없으면 nil.
    public static func identifier(
        for id: NodeID, in graph: CodeGraph, canProveClassHierarchy: Bool,
        identity: XCTestIdentityFacts
    ) -> String? {
        guard canProveClassHierarchy, let node = graph.node(id),
              let module = node.module, !module.isEmpty else { return nil }
        switch node.kind {
        case .classType:
            guard identity.classUSRs.contains(node.usr ?? ""),
                  hasVerifiedMethod(id, in: graph, identity: identity) else { return nil }
            return testCaseClassName(id, in: graph).map { "\(module)/\($0)" }
        case .method:
            guard identity.methodUSRs.contains(node.usr ?? ""),
                  let method = testMethodName(node), let owner = graph.semanticParent(of: id),
                  identity.classUSRs.contains(graph.node(owner)?.usr ?? ""),
                  graph.node(owner)?.module == module,
                  let className = testCaseClassName(owner, in: graph) else { return nil }
            return "\(module)/\(className)/\(method)"
        default:
            return nil
        }
    }

    /// 그래프 전용 시그니처를 유지한다. 원시 신원이 없으므로 모듈 확대가 필요하다.
    public static func identifier(
        for _: NodeID, in _: CodeGraph, canProveClassHierarchy _: Bool
    ) -> String? {
        nil
    }

    /// 클래스 선택에는 직접 또는 상속한 확인된 메서드가 적어도 하나 있어야 한다.
    private static func hasVerifiedMethod(
        _ owner: NodeID, in graph: CodeGraph, identity: XCTestIdentityFacts
    ) -> Bool {
        var pending = [owner]
        var seen: Set<NodeID> = []
        while let current = pending.popLast() {
            guard seen.insert(current).inserted else { continue }
            for edge in graph.outgoingEdges(from: current) {
                if edge.kind == .member,
                   identity.methodUSRs.contains(graph.node(edge.target)?.usr ?? "") { return true }
                if edge.kind == .inheritance,
                   identity.classUSRs.contains(graph.node(edge.target)?.usr ?? "") {
                    pending.append(edge.target)
                }
            }
        }
        return false
    }

    /// 그래프 구성이 클래스 계층을 빠짐없이 담는지.
    ///
    /// 간선 종류를 비워 두면 전부 담는다. 포함 간선이 없으면 메서드의 소유 클래스를,
    /// 상속 간선이 없으면 하위 클래스를 볼 수 없다. 경로 필터가 기본값보다 좁으면
    /// 걸러진 파일의 하위 클래스가 보이지 않는다.
    public static func canProveClassHierarchy(edgeKinds: Set<EdgeKind>, narrowsPaths: Bool) -> Bool {
        guard !narrowsPaths else { return false }
        return edgeKinds.isEmpty || edgeKinds.isSuperset(of: [.member, .inheritance])
    }

    /// 최상위이고 하위 클래스가 없으며 런타임 이름이 소스 이름과 같은 클래스의 이름.
    ///
    /// 중첩 클래스와 `@objc(…)` 로 이름을 바꾼 클래스는 Objective-C 런타임 이름이 소스
    /// 이름과 다르다. 없는 클래스 이름을 받은 xcodebuild 는 테스트 0개를 돌리고 성공하므로
    /// (Xcode 27.0 실측) 어느 이름이 통하는지 증명할 수 없으면 좁히지 않는다.
    /// 하위 클래스가 있으면 상속한 테스트가 하위 클래스 이름으로도 실행되므로, 이
    /// 클래스 이름 하나로 좁히면 그 실행이 빠진다.
    private static func testCaseClassName(_ id: NodeID, in graph: CodeGraph) -> String? {
        guard let node = graph.node(id), node.kind == .classType, graph.semanticParent(of: id) == nil,
              objectiveCClassName(usr: node.usr).map({ $0 == node.name }) ?? true,
              !graph.incomingEdges(to: id).contains(where: { $0.kind == .inheritance }) else { return nil }
        return node.name
    }

    /// Clang 형식 USR 이 담은 Objective-C 클래스 이름. `c:@M@App@objc(cs)Name` 의 `Name` 이다.
    ///
    /// Swift USR(`s:`)이거나 클래스 표기가 없으면 nil 이다.
    static func objectiveCClassName(usr: String?) -> String? {
        guard let usr, let marker = usr.range(of: "(cs)") else { return nil }
        let name = usr[marker.upperBound...].prefix { $0 != "(" && $0 != "@" }
        return name.isEmpty ? nil : String(name)
    }

    /// XCTest 가 실행하는 형태, 곧 인자 없는 `test` 접두사 메서드의 이름.
    private static func testMethodName(_ node: GraphNode) -> String? {
        let base = node.baseName
        guard node.name == base + "()", base.hasPrefix("test") else { return nil }
        return base
    }
}
