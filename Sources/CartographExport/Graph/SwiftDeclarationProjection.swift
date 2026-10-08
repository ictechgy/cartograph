import CartographCore

/// 선언 projection의 전제 위반이다. raw 분석 그래프를 바꾸는 대신 export만 실패시킨다.
public enum SwiftDeclarationProjectionError: Error, Equatable {
    case symbolLevelRequired
    case primaryModuleNotFound
}

/// symbol graph 위에 공유 소스 선언의 module별 USR 대응을 얹는 순수 builder.
struct SwiftDeclarationProjectionBuilder {
    fileprivate static let maximumParentDepth = 64

    func build(
        result: GraphBuilder.BuildResult,
        snapshot: IndexSnapshot,
        projectPath: String,
        primaryModule: String
    ) throws -> SwiftDeclarationProjection {
        guard result.graph.level == .symbol else { throw SwiftDeclarationProjectionError.symbolLevelRequired }
        guard snapshot.symbols.contains(where: { $0.module == primaryModule }) else {
            throw SwiftDeclarationProjectionError.primaryModuleNotFound
        }
        let normalizer = ProjectionPathNormalizer(projectPath: projectPath)
        let symbolsByUSR = Dictionary(grouping: snapshot.symbols, by: \.usr)
        let graphIDs = Set(result.graph.nodeIDs.map(\.rawValue))
        var keys = DeclarationKeyResolver(
            symbolsByUSR: symbolsByUSR,
            visibleUSRs: graphIDs,
            normalizer: normalizer
        )
        var nodes = Dictionary(uniqueKeysWithValues: result.graph.sortedNodes.map { node in
            (node.id, ProjectionNode.raw(node, symbol: Self.uniqueSymbol(node.usr, in: symbolsByUSR),
                primaryModule: primaryModule, normalizer: normalizer))
        })
        var rawToProjected = Dictionary(uniqueKeysWithValues: result.graph.nodeIDs.map { ($0, $0) })
        var groups: [String: [IndexedSymbol]] = [:]
        var unavailable = 0
        for node in result.graph.sortedNodes {
            guard let usr = node.usr, let symbol = Self.uniqueSymbol(usr, in: symbolsByUSR),
                  let key = keys.key(for: symbol) else {
                unavailable += 1
                continue
            }
            groups[key, default: []].append(symbol)
        }

        var merged = 0
        var unresolved = 0
        for declarations in groups.values where declarations.count > 1 {
            let modules = Set(declarations.map(\.module))
            let primaries = declarations.filter { $0.module == primaryModule }
            guard modules.count == declarations.count, primaries.count == 1, let primary = primaries.first else {
                unresolved += 1
                continue
            }
            let canonical = NodeID(primary.usr)
            let aliases = declarations.map(\.usr).filter { $0 != primary.usr }.sorted()
            let variants = Self.variants(
                declarations, primaryUSR: primary.usr, normalizer: normalizer
            )
            nodes[canonical] = ProjectionNode(
                id: canonical,
                state: .merged,
                aliases: aliases,
                variants: variants
            )
            for alias in aliases {
                let raw = NodeID(alias)
                nodes.removeValue(forKey: raw)
                rawToProjected[raw] = canonical
            }
            merged += 1
        }
        let edges = Self.projectedEdges(graph: result.graph, mapping: rawToProjected)
        let evidence = Self.evidence(
            result: result,
            snapshot: snapshot,
            projected: rawToProjected,
            normalizer: normalizer
        )
        return SwiftDeclarationProjection(
            nodes: nodes.values.sorted { $0.id < $1.id },
            edges: edges,
            rawToProjected: rawToProjected,
            evidence: evidence,
            mergedGroupCount: merged,
            unresolvedGroupCount: unresolved,
            unavailableKeyCount: unavailable
        )
    }

    private static func uniqueSymbol(
        _ usr: String?,
        in symbolsByUSR: [String: [IndexedSymbol]]
    ) -> IndexedSymbol? {
        guard let usr, let declarations = symbolsByUSR[usr], declarations.count == 1 else { return nil }
        return declarations[0]
    }

    private static func variants(
        _ declarations: [IndexedSymbol],
        primaryUSR: String,
        normalizer: ProjectionPathNormalizer
    ) -> [ProjectionVariant] {
        declarations.map { symbol in
            ProjectionVariant(symbol: symbol, primary: symbol.usr == primaryUSR, normalizer: normalizer)
        }
        .sorted {
            if $0.primary != $1.primary { return $0.primary }
            return $0.usr < $1.usr
        }
    }

    private static func projectedEdges(
        graph: CodeGraph,
        mapping: [NodeID: NodeID]
    ) -> [ProjectionEdge] {
        var grouped: [ProjectedEdgeSignature: [ProjectionRawEdge]] = [:]
        for edge in graph.edges {
            let source = mapping[edge.source] ?? edge.source
            let target = mapping[edge.target] ?? edge.target
            let key = ProjectedEdgeSignature(source: source, target: target, kind: edge.kind)
            grouped[key, default: []].append(ProjectionRawEdge(edge))
        }
        return grouped.map { key, rawEdges in
            ProjectionEdge(
                source: key.source,
                target: key.target,
                kind: key.kind,
                weight: rawEdges.reduce(0) { $0 + $1.weight },
                rawEdges: rawEdges.sorted()
            )
        }
        .sorted()
    }

    private static func evidence(
        result: GraphBuilder.BuildResult,
        snapshot: IndexSnapshot,
        projected: [NodeID: NodeID],
        normalizer: ProjectionPathNormalizer
    ) -> [ProjectionEvidence] {
        let visible = Set(result.graph.edges.map {
            RawEdgeSignature(source: $0.source, target: $0.target, kind: $0.kind)
        })
        return snapshot.references.compactMap { reference in
            guard let rawSource = result.nodeIDByUSR[reference.sourceUSR],
                  let rawTarget = result.nodeIDByUSR[reference.targetUSR],
                  visible.contains(RawEdgeSignature(
                    source: rawSource, target: rawTarget, kind: reference.kind
                  )) else { return nil }
            return ProjectionEvidence(
                source: projected[rawSource] ?? rawSource,
                target: projected[rawTarget] ?? rawTarget,
                kind: reference.kind,
                sourceUSR: reference.sourceUSR,
                targetUSR: reference.targetUSR,
                targetKind: reference.targetKind,
                origin: reference.origin,
                position: reference.position,
                location: normalizer.relative(reference.location)
            )
        }
        .sorted()
    }
}

/// renderer가 직렬화하는 projection 값이다.
struct SwiftDeclarationProjection {
    let nodes: [ProjectionNode]
    let edges: [ProjectionEdge]
    let rawToProjected: [NodeID: NodeID]
    let evidence: [ProjectionEvidence]
    let mergedGroupCount: Int
    let unresolvedGroupCount: Int
    let unavailableKeyCount: Int
}

struct ProjectionNode: Encodable {
    enum State: String, Encodable { case merged, raw }

    let id: NodeID
    let state: State
    let aliases: [String]
    let variants: [ProjectionVariant]

    static func raw(
        _ node: GraphNode,
        symbol: IndexedSymbol?,
        primaryModule: String,
        normalizer: ProjectionPathNormalizer
    ) -> Self {
        let variant = symbol.map {
            ProjectionVariant(symbol: $0, primary: $0.module == primaryModule, normalizer: normalizer)
        } ?? ProjectionVariant(node: node, primary: node.module == primaryModule, normalizer: normalizer)
        return Self(id: node.id, state: .raw, aliases: [], variants: [variant])
    }
}

struct ProjectionVariant: Encodable {
    let usr: String
    let name: String
    let kind: SymbolKind
    let module: String?
    let parentUSR: String?
    let location: SourceLocation?
    let accessibility: Accessibility
    let attributes: [SymbolAttribute]
    let primary: Bool

    init(symbol: IndexedSymbol, primary: Bool, normalizer: ProjectionPathNormalizer) {
        usr = symbol.usr
        name = symbol.name
        kind = symbol.kind
        module = symbol.module
        parentUSR = symbol.parentUSR
        location = normalizer.relative(symbol.location)
        accessibility = symbol.accessibility
        attributes = symbol.attributes.sorted { $0.rawValue < $1.rawValue }
        self.primary = primary
    }

    init(node: GraphNode, primary: Bool, normalizer: ProjectionPathNormalizer) {
        usr = node.usr ?? node.id.rawValue
        name = node.name
        kind = node.kind
        module = node.module
        parentUSR = nil
        location = normalizer.relative(node.location)
        accessibility = node.accessibility
        attributes = node.attributes.sorted { $0.rawValue < $1.rawValue }
        self.primary = primary
    }
}

struct ProjectionRawEdge: Encodable, Comparable {
    let source: NodeID
    let target: NodeID
    let kind: EdgeKind
    let weight: Int

    init(_ edge: GraphEdge) {
        source = edge.source
        target = edge.target
        kind = edge.kind
        weight = edge.weight
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.source, lhs.target, lhs.kind) < (rhs.source, rhs.target, rhs.kind)
    }
}

struct ProjectionEdge: Encodable, Comparable {
    let source: NodeID
    let target: NodeID
    let kind: EdgeKind
    let weight: Int
    let rawEdges: [ProjectionRawEdge]

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.source, lhs.target, lhs.kind) < (rhs.source, rhs.target, rhs.kind)
    }
}

struct ProjectionEvidence: Encodable, Comparable {
    let source: NodeID
    let target: NodeID
    let kind: EdgeKind
    let sourceUSR: String
    let targetUSR: String
    let targetKind: SymbolKind?
    let origin: ReferenceOrigin
    let position: ReferencePosition
    let location: SourceLocation?

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.target != rhs.target { return lhs.target < rhs.target }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if (lhs.location == nil) != (rhs.location == nil) { return lhs.location != nil }
        if let left = lhs.location, let right = rhs.location, left != right { return left < right }
        if lhs.sourceUSR != rhs.sourceUSR { return lhs.sourceUSR < rhs.sourceUSR }
        if lhs.targetUSR != rhs.targetUSR { return lhs.targetUSR < rhs.targetUSR }
        if lhs.targetKind != rhs.targetKind {
            return (lhs.targetKind?.rawValue ?? "") < (rhs.targetKind?.rawValue ?? "")
        }
        if lhs.origin != rhs.origin { return lhs.origin.rawValue < rhs.origin.rawValue }
        return lhs.position.rawValue < rhs.position.rawValue
    }
}

private struct ProjectedEdgeSignature: Hashable {
    let source: NodeID
    let target: NodeID
    let kind: EdgeKind
}

private struct RawEdgeSignature: Hashable {
    let source: NodeID
    let target: NodeID
    let kind: EdgeKind
}

/// 새 projection 필드에만 쓰는 project-relative 위치 정규화다.
struct ProjectionPathNormalizer {
    private let baseVariants: [String]

    init(projectPath: String) {
        baseVariants = PathFilter.variants(of: projectPath)
    }

    func relative(_ location: SourceLocation?) -> SourceLocation? {
        guard let location else { return nil }
        let value = location.relative(toBaseVariants: baseVariants)
        guard Self.isRelative(value.path), value.line > 0, value.column > 0 else { return nil }
        return value
    }

    private static func isRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("\\")
            && !(path.count >= 2 && path.dropFirst().first == ":")
            && path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

private enum DeclarationKeyMemo {
    case available(key: String, ancestryHeight: Int)
    case unavailable
}

private enum DeclarationKeyResolution {
    case available(key: String, ancestryHeight: Int)
    case unavailable
    /// 호출 지점의 남은 depth 예산 부족이다.
    /// 선언 자체의 실패가 아니므로 memo에 저장하지 않는다.
    case budgetExceeded
}

/// 같은 위치의 선언도 lexical parent를 증명하지 못하면 합치지 않는다.
private struct DeclarationKeyResolver {
    let symbolsByUSR: [String: [IndexedSymbol]]
    let visibleUSRs: Set<String>
    let normalizer: ProjectionPathNormalizer
    var memo: [String: DeclarationKeyMemo] = [:]

    mutating func key(for symbol: IndexedSymbol) -> String? {
        switch resolve(symbol.usr, visiting: [], depth: 0) {
        case let .available(key, _): key
        case .unavailable, .budgetExceeded: nil
        }
    }

    private mutating func resolve(
        _ usr: String,
        visiting: Set<String>,
        depth: Int
    ) -> DeclarationKeyResolution {
        guard depth < SwiftDeclarationProjectionBuilder.maximumParentDepth else {
            return .budgetExceeded
        }
        if let known = memo[usr] {
            switch known {
            case let .available(key, ancestryHeight):
                guard depth + ancestryHeight < SwiftDeclarationProjectionBuilder.maximumParentDepth else {
                    return .budgetExceeded
                }
                return .available(key: key, ancestryHeight: ancestryHeight)
            case .unavailable:
                return .unavailable
            }
        }
        guard !visiting.contains(usr),
              visibleUSRs.contains(usr),
              let declarations = symbolsByUSR[usr], declarations.count == 1,
              let symbol = declarations.first,
              let location = normalizer.relative(symbol.location) else {
            memo[usr] = .unavailable
            return .unavailable
        }
        let parentKey: String
        let ancestryHeight: Int
        if let parentUSR = symbol.parentUSR {
            switch resolve(parentUSR, visiting: visiting.union([usr]), depth: depth + 1) {
            case let .available(key, parentHeight):
                parentKey = key
                ancestryHeight = parentHeight + 1
            case .unavailable:
                memo[usr] = .unavailable
                return .unavailable
            case .budgetExceeded:
                return .budgetExceeded
            }
        } else {
            parentKey = ""
            ancestryHeight = 0
        }
        let fields = [
            location.path,
            String(location.line),
            String(location.column),
            symbol.kind.rawValue,
            symbol.name,
            parentKey,
        ]
        let key = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        memo[usr] = .available(key: key, ancestryHeight: ancestryHeight)
        return .available(key: key, ancestryHeight: ancestryHeight)
    }
}
