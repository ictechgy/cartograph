/// 전송 한도가 있는 배치에서 선택 근거만 제한한다. 요청 순서와 그래프 사실은 보존한다.
public struct QueryEvidenceBudget: Sendable {
    private var references: Int
    private var localFunctions: Int

    /// MCP 기본 예산. 작은 단건 응답은 기존 결과와 같고 큰 배치는 생략 개수로 제한을 알린다.
    public init(referenceLimit: Int = 200, localFunctionLimit: Int = 50) {
        references = max(0, referenceLimit)
        localFunctions = max(0, localFunctionLimit)
    }

    mutating func apply(to document: SymbolQueryDocument) -> SymbolQueryDocument {
        let result = document.result.map { query in
            let users = query.usedBy.map { limited($0) }
            let dependencies = query.dependsOn.map { limited($0) }
            return SymbolQuery(subject: query.subject, reachability: query.reachability,
                usedBy: users, dependsOn: dependencies, members: query.members,
                declaredIn: query.declaredIn, truncated: query.truncated)
        }
        let diagnostics = document.localFunctionDiagnostics.map { full in
            let shown = full.limited(to: localFunctions)
            localFunctions -= shown.items.count
            return shown
        }
        return SymbolQueryDocument(status: document.status, requested: document.requested,
            level: document.level, limitations: document.limitations, result: result,
            candidates: document.candidates, localFunctionDiagnostics: diagnostics)
    }

    private mutating func limited(_ neighbor: SymbolQuery.Neighbor) -> SymbolQuery.Neighbor {
        let evidence = neighbor.referenceEvidence.map { full in
            let shown = full.limited(to: references)
            references -= shown.items.count
            return shown
        }
        return SymbolQuery.Neighbor(name: neighbor.name, qualifiedName: neighbor.qualifiedName,
            kind: neighbor.kind, usr: neighbor.usr, module: neighbor.module, edges: neighbor.edges,
            depth: neighbor.depth, location: neighbor.location, referenceEvidence: evidence)
    }
}
