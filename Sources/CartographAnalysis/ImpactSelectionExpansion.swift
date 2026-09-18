import CartographCore

/// 컨테이너 확장은 선택과 영향 사이에서 "수정 대상이 되는 정점"을 넓히는 순수 단계다.
///
/// 타입 시드는 그 타입을 확장하는 익스텐션과 그 멤버까지, 익스텐션 시드는 자기
/// 멤버까지 수정 대상으로 확장한다(익스텐션 시드가 확장 대상 타입을 포함하지는
/// 않는다). 익스텐션 멤버의 어휘적 부모는 익스텐션이지만 의미상 소유자는 확장 대상
/// 타입이므로(`semanticParent`), 양쪽 소유자 아래로 모두 내려간다. 반대로 소비자의
/// 형제는 이 단계가 아니라 `ImpactAnalyzer` 의 incoming 사용 간선 순회가 다루므로,
/// 여기서 닿지 않는다.
public enum ImpactSelectionExpansion {
    /// 타입·익스텐션 시드를 그 멤버와 확장 대상까지 포함하도록 확장한다.
    ///
    /// 옮기기 전 구현은 `member`·`extends` 간선 배열을 두 번 훑어 자식 사전을
    /// 미리 만들었다. 그래프가 이미 인접 목록을 갖고 있으므로(`outgoingEdges`·
    /// `incomingEdges`) 방문한 정점의 자식 집합을 그때 계산하면, 같은 결과를
    /// 도달한 범위의 차수 합에 비례하는 비용으로 낸다. 함수 본문의 지역 선언처럼
    /// 컨테이너가 아닌 정점 아래에도 자식이 달릴 수 있으므로, 도달한 정점이면
    /// 종류를 가리지 않고 자식 집합을 읽는다. 순환(타입 ↔ 익스텐션을 잇는
    /// 간선 상호 참조)은 방문 집합으로 잘라 종료를 보장한다.
    ///
    /// - Parameters:
    ///   - selected: 입력 시드. 컨테이너가 아니면 그대로 남는다.
    ///   - graph: 심볼 레벨 의존성 그래프.
    /// - Returns: 시드와 확장된 정점을 합친 집합. 시드가 컨테이너가 아니면
    ///   입력을 그대로 돌려준다.
    public static func expandingContainers(_ selected: Set<NodeID>, graph: CodeGraph) -> Set<NodeID> {
        let roots = selected.filter {
            graph.node($0)?.kind.isTypeDeclaration == true || graph.node($0)?.kind == .extensionDeclaration
        }.sorted()
        guard !roots.isEmpty else { return selected }

        var expander = Expander(graph: graph)
        var result = selected
        var queue = roots
        var head = 0
        while head < queue.count {
            let parent = queue[head]
            head += 1
            for child in expander.children(of: parent).sorted() where result.insert(child).inserted {
                queue.append(child)
            }
        }
        return result
    }
}

/// `ImpactSelectionExpansion` 한 번에 쓰이는 자식 집합 계산기.
///
/// 익스텐션의 멤버 목록은 의미 부모별로 나눠 처음 필요할 때 한 번만 만든다.
/// 여러 타입을 확장하는 익스텐션이 도달되어도 멤버 목록을 타입마다 다시 훑으면
/// `semanticParent` 조회까지 곱해져, 간선 전수 스캔이던 원 구현보다 최악이 나빠진다.
private struct Expander {
    let graph: CodeGraph
    /// 익스텐션 정점 → (의미 부모 정점 → 멤버 집합). 지연 계산 후 캐시한다.
    private var extensionMembers: [NodeID: [NodeID: Set<NodeID>]] = [:]

    /// `owner` 를 컨테이너로 삼는 자식 집합 — 옮기기 전 구현이 간선 전수 스캔으로
    /// 미리 만들던 `children[owner]` 와 같은 집합이다.
    ///
    /// 세 종류의 자식이 있다: 어휘적 멤버(`owner` 가 member 간선의 source),
    /// `owner` 를 의미 부모로 삼는 멤버(어휘 부모가 `owner` 를 확장하는 익스텐션),
    /// `owner` 를 확장하는 익스텐션 자체. extends 방향은 뒤집혀 있으므로
    /// (익스텐션 → 타입) incoming 으로 읽는다.
    mutating func children(of owner: NodeID) -> Set<NodeID> {
        var children: Set<NodeID> = []
        for edge in graph.outgoingEdges(from: owner) where edge.kind == .member {
            children.insert(edge.target)
        }
        for edge in graph.incomingEdges(to: owner) where edge.kind == .extends {
            let ext = edge.source
            guard graph.node(ext)?.kind == .extensionDeclaration else { continue }
            children.insert(ext)
            children.formUnion(extensionMembers(of: ext, under: owner))
        }
        return children
    }

    /// `ext` 익스텐션의 멤버 중 의미 부모가 `owner` 인 것만 돌려준다.
    ///
    /// 같은 멤버가 다른 소유자 아래로 새지 않게 `semanticParent` 와 대조해 나눈다 —
    /// 익스텐션이 여러 타입을 확장하는 비정상 그래프에서도 원 구현과 같다.
    private mutating func extensionMembers(of ext: NodeID, under owner: NodeID) -> Set<NodeID> {
        if let grouped = extensionMembers[ext] { return grouped[owner] ?? [] }
        var grouped: [NodeID: Set<NodeID>] = [:]
        for edge in graph.outgoingEdges(from: ext) where edge.kind == .member {
            if let parent = graph.semanticParent(of: edge.target) {
                grouped[parent, default: []].insert(edge.target)
            }
        }
        extensionMembers[ext] = grouped
        return grouped[owner] ?? []
    }
}
