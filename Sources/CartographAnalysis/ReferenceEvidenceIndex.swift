import CartographCore

/// 질의의 마지막 홉을 뒷받침하는 참조 기록. location이 없으면 위치를 모르는 근거다.
public struct ReferenceEvidenceItem: Codable, Sendable, Equatable, Hashable {
    public let sourceUSR: String
    public let targetUSR: String
    public let viaUSR: String
    public let kind: EdgeKind
    public let origin: ReferenceOrigin
    public let location: SourceLocation?
}

/// 이웃 수와 별도로 참조 근거의 크기를 제한하고 생략 사실을 알린다.
public struct ReferenceEvidence: Codable, Sendable, Equatable {
    public let items: [ReferenceEvidenceItem]
    public let totalCount: Int
    public let omittedCount: Int

    /// 배치의 남은 예산에 맞춰 줄여도 이미 생략된 근거를 전체 개수에서 잃지 않는다.
    public func limited(to count: Int) -> Self {
        let shown = Array(items.prefix(max(0, count)))
        return Self(items: shown, totalCount: totalCount, omittedCount: totalCount - shown.count)
    }
}

/// 배치 질의가 매번 전체 인덱스 참조를 훑지 않도록 한 번만 만든 위치 색인.
public struct ReferenceEvidenceIndex: Sendable {
    private struct Key: Hashable {
        let source: String
        let target: String
        let kind: EdgeKind
    }

    private struct Site: Hashable {
        let location: SourceLocation?
        let origin: ReferenceOrigin
    }

    private struct HopKey: Hashable {
        let edge: Key
        let via: NodeID
    }

    private let sites: [Key: [Site]]

    /// 중복 컴파일 유닛의 같은 기록은 한 근거로 접고 다른 관계 종류는 유지한다.
    public init(snapshot: IndexSnapshot, graph: CodeGraph? = nil) {
        let visible = graph.map { graph in
            Set(graph.edges.filter { $0.kind.impliesUsage }.map {
                Key(source: $0.source.rawValue, target: $0.target.rawValue, kind: $0.kind)
            })
        }
        var collected: [Key: Set<Site>] = [:]
        for reference in snapshot.references where reference.kind.impliesUsage {
            let key = Key(source: reference.sourceUSR, target: reference.targetUSR, kind: reference.kind)
            guard visible?.contains(key) != false else { continue }
            let location = reference.location.flatMap {
                !$0.path.isEmpty && $0.line > 0 && $0.column > 0 ? $0 : nil
            }
            collected[key, default: []].insert(Site(location: location, origin: reference.origin))
        }
        sites = collected.mapValues { values in
            values.sorted {
                if ($0.location == nil) != ($1.location == nil) { return $0.location != nil }
                if let left = $0.location, let right = $1.location, left != right { return left < right }
                return $0.origin.rawValue < $1.origin.rawValue
            }
        }
    }

    /// 모든 최단 마지막 홉을 포함한다. 전이 이웃을 원래 질의 대상의 직접 호출자로 바꾸지 않는다.
    public func evidence(for hops: [GraphNeighborhood.Hop], limit: Int) -> ReferenceEvidence {
        let cap = max(0, limit)
        var seen: Set<HopKey> = []
        var shown: [ReferenceEvidenceItem] = []
        var totalCount = 0
        for hop in hops {
            let key = Key(source: hop.edge.source.rawValue, target: hop.edge.target.rawValue, kind: hop.edge.kind)
            guard seen.insert(HopKey(edge: key, via: hop.via)).inserted else { continue }
            let occurrences = sites[key] ?? [Site(location: nil, origin: .graph)]
            totalCount += occurrences.count
            // 표시 예산을 다 쓴 뒤에는 개수만 읽는다. 요청마다 큰 참조 묶음을 복사·정렬하지 않는다.
            shown += occurrences.prefix(cap).map {
                ReferenceEvidenceItem(sourceUSR: key.source, targetUSR: key.target,
                    viaUSR: hop.via.rawValue, kind: key.kind, origin: $0.origin, location: $0.location)
            }
            shown.sort(by: Self.ordered)
            if shown.count > cap { shown.removeSubrange(cap...) }
        }
        return ReferenceEvidence(items: shown, totalCount: totalCount, omittedCount: totalCount - shown.count)
    }

    private static func ordered(_ lhs: ReferenceEvidenceItem, _ rhs: ReferenceEvidenceItem) -> Bool {
        if (lhs.location == nil) != (rhs.location == nil) { return lhs.location != nil }
        if let left = lhs.location, let right = rhs.location, left != right { return left < right }
        return (lhs.sourceUSR, lhs.targetUSR, lhs.viaUSR, lhs.kind.rawValue, lhs.origin.rawValue)
            < (rhs.sourceUSR, rhs.targetUSR, rhs.viaUSR, rhs.kind.rawValue, rhs.origin.rawValue)
    }
}
