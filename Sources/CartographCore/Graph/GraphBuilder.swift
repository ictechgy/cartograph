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
        /// 파일·모듈 렌즈가 발생 출처를 증명하지 못해 의미 소유자로 폴백한 관측.
        ///
        /// 간선을 삭제하지 않고 관측 수와 경로를 남긴다. 이 경고가 있는 순환·레이어 위반은
        /// 발생 위치로 확정한 아키텍처 의존으로 읽으면 안 된다. 심볼·타입 렌즈에서는 비어 있다.
        public let sourceAttributionLimitations: [String]
        fileprivate let referenceSourcesByPath: [String: NodeID]
        fileprivate let excludedReferencePaths: Set<String>

        public init(graph: CodeGraph, nodeIDByUSR: [String: NodeID]) {
            self.init(graph: graph, nodeIDByUSR: nodeIDByUSR,
                referenceSourcesByPath: [:], excludedReferencePaths: [], sourceAttributionLimitations: [])
        }

        fileprivate init(graph: CodeGraph, nodeIDByUSR: [String: NodeID],
                         referenceSourcesByPath: [String: NodeID], excludedReferencePaths: Set<String>,
                         sourceAttributionLimitations: [String]) {
            self.graph = graph
            self.nodeIDByUSR = nodeIDByUSR
            self.referenceSourcesByPath = referenceSourcesByPath
            self.excludedReferencePaths = excludedReferencePaths
            self.sourceAttributionLimitations = sourceAttributionLimitations
        }

        /// 파일·모듈 렌즈의 발생 위치와 심볼·타입 렌즈의 의미 소유자를 같은 규칙으로 찾는다.
        ///
        /// USR 매핑만 쓰면 앱의 익스텐션에서 나온 참조가 원본 도메인 선언으로 되돌아간다.
        /// 위치나 단일 모듈 근거가 없으면 기존 USR 소유자를 남기며, 제외된 발생은 되살리지 않는다.
        public func sourceNodeID(for reference: IndexedReference) -> NodeID? {
            if let path = reference.location?.path {
                if excludedReferencePaths.contains(path) { return nil }
                if let source = referenceSourcesByPath[path] { return source }
            }
            return nodeIDByUSR[reference.sourceUSR]
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
        let allowedPaths = allowedPaths(in: snapshot)
        let includedSymbols = snapshot.symbols.filter { isIncluded($0, allowedPaths: allowedPaths) }

        var nodesByID: [NodeID: GraphNode] = [:]
        var nodeIDByUSR: [String: NodeID] = [:]

        for symbol in includedSymbols {
            let resolved = resolve(
                symbol: symbol,
                symbolsByUSR: symbolsByUSR,
                extensionTargets: extensionTargets,
                allowedPaths: allowedPaths
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

        let sites = architecturalSources(in: snapshot, allowedPaths: allowedPaths)
        let siteNodes = sites.nodes
        let sourceMapping = BuildResult(
            graph: CodeGraph(level: options.level, nodes: [], edges: []), nodeIDByUSR: nodeIDByUSR,
            referenceSourcesByPath: siteNodes.mapValues(\.id),
            excludedReferencePaths: excludedReferencePaths(in: snapshot), sourceAttributionLimitations: []
        )
        var edges: [GraphEdge] = []
        var unresolvedSources: [String: UnresolvedSources] = [:]
        for reference in snapshot.references {
            guard let source = sourceMapping.sourceNodeID(for: reference),
                  let target = nodeIDByUSR[reference.targetUSR] else { continue }
            guard isIncluded(kind: reference.kind) else { continue }
            if let path = reference.location?.path, let node = siteNodes[path] {
                nodesByID[node.id] = node
            }
            if options.level == .module || options.level == .file,
               reference.location.flatMap({ siteNodes[$0.path] }) == nil {
                let path = reference.location?.path ?? "<unlocated>"
                let reason = reference.location == nil ? "unlocated-reference"
                    : sites.unresolved[path] ?? "unknown-file-ownership"
                unresolvedSources[reason, default: UnresolvedSources()].count += 1
                unresolvedSources[reason, default: UnresolvedSources()].paths.insert(path)
            }
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
        return BuildResult(graph: graph, nodeIDByUSR: nodeIDByUSR,
            referenceSourcesByPath: siteNodes.mapValues(\.id),
            excludedReferencePaths: sourceMapping.excludedReferencePaths,
            sourceAttributionLimitations: sourceAttributionLimitations(unresolvedSources))
    }

    // MARK: - 내부 구현

    /// 경로 필터를 통과하는 경로들. 심볼이 아니라 **파일**마다 한 번만 판정한다.
    ///
    /// 필터는 파일의 성질인데 심볼마다 부르면 같은 경로를 수천 번 다시 본다. 글롭 매칭은
    /// 경로를 세그먼트로 쪼개고 기준 경로의 여러 표기와 대조하는 일이라 싸지 않다.
    /// 프로파일에서 이 판정 하나가 모든 명령의 3분의 1 이상이었다. 파일 하나에 심볼이
    /// 수십 개씩 붙으므로 줄어드는 배수가 그대로 파일당 심볼 수다.
    private func allowedPaths(in snapshot: IndexSnapshot) -> Set<String> {
        Set(snapshot.symbols.map(\.location.path)).filter { options.pathFilter.allows($0) }
    }

    private func isIncluded(_ symbol: IndexedSymbol, allowedPaths: Set<String>) -> Bool {
        if symbol.isExternal, !options.includeExternal { return false }
        return allowedPaths.contains(symbol.location.path)
    }

    private func isIncluded(kind: EdgeKind) -> Bool {
        options.edgeKinds.isEmpty || options.edgeKinds.contains(kind)
    }

    /// 위치 기반 출처는 선언·컴파일 유닛의 파일 근거가 있는 아키텍처 렌즈에만 적용한다.
    ///
    /// 서로 다른 타깃이 공유하는 파일에서 모듈을 하나 임의로 고르면 새 가짜 간선이 생긴다.
    /// 모듈 근거가 충돌하면 기존 의미 소유자를 유지한다. 파일 렌즈는 경로 자체가 근거지만
    /// 모듈은 빈 값으로 남긴다. SDK 참조의 가상 선언 위치는 파일 소유권 근거가 아니다.
    private func architecturalSources(in snapshot: IndexSnapshot, allowedPaths: Set<String>)
        -> (nodes: [String: GraphNode], unresolved: [String: String]) {
        guard options.level == .module || options.level == .file else { return ([:], [:]) }
        var modulesByPath: [String: Set<String>] = [:]
        var unresolvedModulePaths: Set<String> = []
        for symbol in snapshot.symbols where !symbol.isExternal && allowedPaths.contains(symbol.location.path) {
            modulesByPath[symbol.location.path, default: []].formUnion(symbol.module.isEmpty ? [] : [symbol.module])
        }
        for (path, usage) in snapshot.fileModuleUsages where options.pathFilter.allows(path) {
            let module = usage.owningModule ?? ""
            modulesByPath[path, default: []].formUnion(module.isEmpty ? [] : [module])
            // 동일 파일을 여러 compile unit이 공유하면 USR 병합 후 선언에는 첫 모듈만
            // 남을 수 있다. 소유 모듈이 미확정인 usage를 그 단일 선언으로 덮어쓰지 않는다.
            // 소유 모듈이 알려진 파일의 unattributed reference는 import 대상의 불확실성이다.
            if module.isEmpty, usage.hasUnattributedReferences { unresolvedModulePaths.insert(path) }
        }
        var nodes: [String: GraphNode] = [:]
        var unresolved: [String: String] = [:]
        for entry in modulesByPath {
            let (path, modules) = entry
            let module = modules.count == 1 && !unresolvedModulePaths.contains(path) ? modules.first! : ""
            if options.level == .file {
                nodes[path] = GraphNode(id: NodeID(path),
                    name: path.split(separator: "/").last.map(String.init) ?? path, kind: .file, module: module,
                    location: SourceLocation(path: path, line: 1, column: 1))
            } else if !module.isEmpty {
                nodes[path] = GraphNode(id: NodeID(module), name: module, kind: .module, module: module)
            } else {
                unresolved[path] = unresolvedModulePaths.contains(path) ? "unresolved-file-module-evidence"
                    : (modules.isEmpty ? "missing-file-module" : "conflicting-file-modules")
            }
        }
        return (nodes, unresolved)
    }

    private struct UnresolvedSources {
        var count = 0
        var paths: Set<String> = []
    }

    /// 경고는 사유마다 하나로 합치고 경로 표시는 10개로 제한하되 생략 개수는 남긴다.
    private func sourceAttributionLimitations(_ unresolved: [String: UnresolvedSources]) -> [String] {
        unresolved.keys.sorted().map { reason in
            let item = unresolved[reason]!
            let paths = item.paths.sorted()
            let shown = paths.prefix(10).map { String(reflecting: $0) }.joined(separator: ", ")
            return "source-attribution: \(item.count) \(options.level.rawValue) reference occurrence(s) used the "
                + "legacy semantic source (\(reason)); paths: \(shown); omitted paths: \(max(0, paths.count - 10)). "
                + "Architectural source and resulting cycle/rule findings remain uncertain."
        }
    }

    private func excludedReferencePaths(in snapshot: IndexSnapshot) -> Set<String> {
        guard options.level == .module || options.level == .file else { return [] }
        return Set(snapshot.references.compactMap { $0.location?.path }).filter { !options.pathFilter.allows($0) }
    }

    /// 심볼 하나를 현재 레벨의 정점으로 환원한다.
    private func resolve(
        symbol: IndexedSymbol,
        symbolsByUSR: [String: IndexedSymbol],
        extensionTargets: [String: String],
        allowedPaths: Set<String>
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
            // 소유 타입이 분석 범위 밖이면 그것으로 접지 않는다. 그러지 않으면
            // 명시적으로 제외한 파일의 선언이 익스텐션 멤버를 통해 그래프로 끌려 들어와
            // exclude 가 조용히 무력화된다.
            guard let owner = symbolsByUSR[ownerUSR],
                  isIncluded(owner, allowedPaths: allowedPaths)
            else {
                return Self.node(for: symbol)
            }
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
            // 하나의 익스텐션 USR 에 대상이 둘 이상 오는 일은 관측되지 않았다(실제 앱 넷 ·
            // 코퍼스 · 네 레벨 전부에서 0건). 그래도 마지막 것이 이기게 두면 결과가 참조
            // 배열의 순서에 달리고, 그 순서는 이제 인덱스가 준 그대로다. 작은 쪽을 택해
            // 순서와 무관하게 만든다. 값 하나를 골라야 한다는 것 자체는 변하지 않는다.
            result[reference.sourceUSR] = result[reference.sourceUSR]
                .map { Swift.min($0, reference.targetUSR) } ?? reference.targetUSR
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
            // 익스텐션은 확장 대상으로 건너뛴다. 다만 이미 지나온 정점으로 돌아가는
            // 비정상 인덱스에서는 건너뛰기를 포기하고 부모를 따라간다. 그대로 두면
            // 멤버가 소유 타입 대신 익스텐션 정점에 남는다.
            if symbol.kind == .extensionDeclaration,
               let extended = extensionTargets[current],
               !visited.contains(extended) {
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
