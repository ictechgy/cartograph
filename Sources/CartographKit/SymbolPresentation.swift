import CartographCore

extension SymbolQuery.Subject {
    /// 리포트 조립용 도우미가 서비스 타입에 역으로 의존하지 않도록 표현 변환을 값 타입에 둔다.
    init(node: GraphNode) {
        self.init(name: node.name, qualifiedName: node.qualifiedName, kind: node.kind.rawValue,
            module: node.module, usr: node.usr, accessibility: node.accessibility.rawValue, location: node.location)
    }
}

extension SymbolQueryDocument {
    /// 서비스와 독립된 후보 표현. 위치·USR 정렬을 모든 질의가 공유한다.
    static func presenting(_ nodes: [GraphNode], in graph: CodeGraph) -> [Candidate] {
        nodes.sorted { left, right in
            (left.location?.path ?? "", left.location?.line ?? 0, left.id.rawValue)
                < (right.location?.path ?? "", right.location?.line ?? 0, right.id.rawValue)
        }.map { node in
            Candidate(qualifiedName: node.qualifiedName, usr: node.usr ?? node.id.rawValue,
                kind: node.kind.rawValue, module: node.module, location: node.location,
                container: graph.semanticParent(of: node.id).flatMap { graph.node($0)?.name })
        }
    }
}
