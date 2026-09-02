/// 인덱스 스냅샷을 원하는 해상도의 코드 그래프로 변환한다.
///
/// 순수 함수이므로 인덱스 스토어 없이도 완전히 테스트할 수 있다.
/// 롤업(심볼 → 타입/파일/모듈)은 여기서 한 번만 일어나고,
/// 이후 분석 알고리즘은 레벨을 신경 쓰지 않는다.
public struct GraphBuilder: Sendable {
    public struct Options: Sendable, Equatable {
        public var level: GraphLevel
        public var pathFilter: PathFilter
        /// 포함할 간선 종류. 비어 있으면 모두 포함한다.
        public var edgeKinds: Set<EdgeKind>
        /// SDK 등 외부 심볼을 정점으로 포함할지 여부.
        public var includeExternal: Bool
        /// 자기 자신을 가리키는 간선을 제거할지 여부.
        ///
        /// 롤업 이후에는 "모듈이 자기 자신에 의존한다" 같은 무의미한 간선이
        /// 대량으로 생기므로 기본적으로 제거한다.
        public var dropSelfLoops: Bool

        public init(
            level: GraphLevel = .module,
            pathFilter: PathFilter = .passthrough,
            edgeKinds: Set<EdgeKind> = [],
            includeExternal: Bool = false,
            dropSelfLoops: Bool = true
        ) {
            self.level = level
            self.pathFilter = pathFilter
            self.edgeKinds = edgeKinds
            self.includeExternal = includeExternal
            self.dropSelfLoops = dropSelfLoops
        }
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// 그래프와, 그 그래프를 만들 때 쓴 USR → 정점 매핑을 함께 담는다.
    ///
    /// 데드코드 분석과 아키텍처 지표는 "이 정점에 어떤 심볼들이 접혔는가"를
    /// 알아야 하는데, 매핑 규칙을 두 곳에서 따로 구현하면 반드시 어긋난다.
    public struct BuildResult: Sendable {
        public let graph: CodeGraph
        /// 분석에 포함된 심볼의 USR → 정점 식별자.
        public let nodeIDByUSR: [String: NodeID]

        public init(graph: CodeGraph, nodeIDByUSR: [String: NodeID]) {
            self.graph = graph
            self.nodeIDByUSR = nodeIDByUSR
        }

        /// 정점 하나에 접힌 심볼들의 USR 목록.
        public func usrs(for node: NodeID) -> [String] {
            nodeIDByUSR.filter { $0.value == node }.keys.sorted()
        }
    }

    /// 그래프만 필요할 때 쓰는 간편 진입점.
    public func build(from snapshot: IndexSnapshot) -> CodeGraph {
        buildResult(from: snapshot).graph
    }

    public func buildResult(from snapshot: IndexSnapshot) -> BuildResult {
        let symbolsByUSR = snapshot.symbolsByUSR()
        let extensionTargets = Self.extensionTargets(in: snapshot)
        let includedSymbols = snapshot.symbols.filter { isIncluded($0) }

        var nodesByID: [NodeID: GraphNode] = [:]
        var nodeIDByUSR: [String: NodeID] = [:]

        for symbol in includedSymbols {
            let resolved = resolve(
                symbol: symbol,
                symbolsByUSR: symbolsByUSR,
                extensionTargets: extensionTargets
            )
            nodeIDByUSR[symbol.usr] = resolved.id
            // 같은 정점에 여러 심볼이 모이면(롤업) 대표 심볼 하나만 남긴다.
            // 대표를 고르는 기준은 "타입 선언 > 그 외" 이며, 동률이면 먼저 온 것을 쓴다.
            if let existing = nodesByID[resolved.id] {
                nodesByID[resolved.id] = Self.preferredNode(existing, resolved)
            } else {
                nodesByID[resolved.id] = resolved
            }
        }

        var edges: [GraphEdge] = []
        for reference in snapshot.references {
            guard let source = nodeIDByUSR[reference.sourceUSR],
                  let target = nodeIDByUSR[reference.targetUSR] else { continue }
            guard isIncluded(kind: reference.kind) else { continue }
            if options.dropSelfLoops, source == target { continue }
            edges.append(GraphEdge(source: source, target: target, kind: reference.kind))
        }

        // 심볼 레벨에서는 포함 관계(member)도 그래프에 남긴다.
        // 데드코드 분석이 "이 타입에 어떤 멤버가 달려 있는가"를 알아야 하기 때문이다.
        if options.level == .symbol, isIncluded(kind: .member) {
            for symbol in includedSymbols {
                guard let parentUSR = symbol.parentUSR,
                      let parent = nodeIDByUSR[parentUSR],
                      let child = nodeIDByUSR[symbol.usr],
                      parent != child else { continue }
                edges.append(GraphEdge(source: parent, target: child, kind: .member))
            }
        }

        let graph = CodeGraph(level: options.level, nodes: Array(nodesByID.values), edges: edges)
        return BuildResult(graph: graph, nodeIDByUSR: nodeIDByUSR)
    }

    // MARK: - 내부 구현

    private func isIncluded(_ symbol: IndexedSymbol) -> Bool {
        if symbol.isExternal, !options.includeExternal { return false }
        return options.pathFilter.allows(symbol.location.path)
    }

    private func isIncluded(kind: EdgeKind) -> Bool {
        options.edgeKinds.isEmpty || options.edgeKinds.contains(kind)
    }

    /// 심볼 하나를 현재 레벨의 정점으로 환원한다.
    private func resolve(
        symbol: IndexedSymbol,
        symbolsByUSR: [String: IndexedSymbol],
        extensionTargets: [String: String]
    ) -> GraphNode {
        switch options.level {
        case .module:
            return GraphNode(
                id: NodeID(symbol.module),
                name: symbol.module,
                kind: .module,
                module: symbol.module
            )
        case .file:
            let path = symbol.location.path
            return GraphNode(
                id: NodeID(path),
                name: path.split(separator: "/").last.map(String.init) ?? path,
                kind: .file,
                module: symbol.module,
                location: SourceLocation(path: path, line: 1, column: 1)
            )
        case .type:
            let ownerUSR = Self.typeOwnerUSR(
                of: symbol.usr,
                symbolsByUSR: symbolsByUSR,
                extensionTargets: extensionTargets
            )
            let owner = symbolsByUSR[ownerUSR] ?? symbol
            return Self.node(for: owner)
        case .symbol:
            return Self.node(for: symbol)
        }
    }

    private static func node(for symbol: IndexedSymbol) -> GraphNode {
        GraphNode(
            id: NodeID(symbol.usr),
            name: symbol.name,
            kind: symbol.kind,
            module: symbol.module,
            usr: symbol.usr,
            location: symbol.location,
            accessibility: symbol.accessibility,
            attributes: symbol.attributes,
            isExternal: symbol.isExternal
        )
    }

    /// 롤업으로 한 정점에 여러 심볼이 모였을 때 대표를 고른다.
    private static func preferredNode(_ lhs: GraphNode, _ rhs: GraphNode) -> GraphNode {
        if lhs.kind.isTypeDeclaration != rhs.kind.isTypeDeclaration {
            return lhs.kind.isTypeDeclaration ? lhs : rhs
        }
        return lhs
    }

    /// 익스텐션 USR → 확장 대상 타입 USR 매핑.
    static func extensionTargets(in snapshot: IndexSnapshot) -> [String: String] {
        var result: [String: String] = [:]
        for reference in snapshot.references where reference.kind == .extends {
            result[reference.sourceUSR] = reference.targetUSR
        }
        return result
    }

    /// 심볼을 감싸는 최상위 타입의 USR 을 찾는다.
    ///
    /// 익스텐션은 확장 대상 타입으로 접고, 멤버는 부모를 따라 올라간다.
    /// 타입 조상이 없으면(최상위 함수 등) 자기 자신이 정점이 된다.
    static func typeOwnerUSR(
        of usr: String,
        symbolsByUSR: [String: IndexedSymbol],
        extensionTargets: [String: String]
    ) -> String {
        var current = usr
        var visited: Set<String> = []

        while let symbol = symbolsByUSR[current], visited.insert(current).inserted {
            if symbol.kind == .extensionDeclaration, let extended = extensionTargets[current] {
                current = extended
                continue
            }
            if symbol.kind.isTypeDeclaration {
                return current
            }
            guard let parentUSR = symbol.parentUSR, symbolsByUSR[parentUSR] != nil else {
                return current
            }
            current = parentUSR
        }
        return current
    }
}
