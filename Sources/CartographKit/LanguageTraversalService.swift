import CartographAnalysis
import CartographCore
import Foundation

extension CartographService {
    /// 한 번의 다중 root 순회를 isthmus `language-traversal` v1 문서로 만든다.
    ///
    /// isthmus trace 가 route-call·relation-use 를 감싼 선언을 root 로 넘기면, 도달 정점마다 닿은
    /// root 를 모두 싣는다. `change-impact` 는 정점마다 via 하나뿐이라 root 가 둘 이상이면 출처가
    /// 사라지고, root 마다 따로 돌리면 느리고 크다. root id 와 도달 usr 는 인덱스 USR 그대로라
    /// `routes`·`bridges` 사실의 `symbol.usr` 와 문자열이 같다.
    ///
    /// root 는 선택한 선언 그대로다. `change-impact` 처럼 타입을 멤버로 넓히지 않는다 — 넓힌 멤버는
    /// root 가 아니라서 via 사슬이 계약의 부모 root 규칙을 어기게 되고, route-call·relation-use 의
    /// root 는 애초에 함수 선언이다. 타입 root 는 한계로 알린다.
    ///
    /// - Parameters:
    ///   - symbols: root 로 삼을 선언(이름, 한정 이름 또는 USR). 입력 순서가 root 인덱스다.
    ///   - direction: `dependents`(호출자 쪽) 또는 `dependencies`(피호출자 쪽).
    ///   - maxDepth: 보고할 최대 depth. 없으면 계약 상한 128 이다.
    ///   - limit: 보고할 최대 도달 정점 수(1...100000).
    ///   - generatedAt: 문서 시각. 같은 입력에 같은 바이트를 내려면 고정한다.
    public func languageTraversalDocument(
        symbols: [String], direction: TraversalDirection = .dependents, maxDepth: Int? = nil,
        limit: Int = Self.languageTraversalReachedLimit, generatedAt: Date = Date(),
        in existingContext: AnalysisContext? = nil
    ) throws -> LanguageTraversalDocument {
        try validateTraversalLimits(symbols: symbols, maxDepth: maxDepth, limit: limit)
        let project = try canonicalProjectForExchange()
        let context = try existingContext ?? loadContext()
        let graph = context.buildGraph(level: .symbol).graph
        let automatic = context.runtimeDiscovery()
        var limitations = analysisLimitations(context: context, symbolGraph: graph)
            + Self.automaticRuntimeLimitations(automatic)
        let requests = TraversalRootRequests(symbols: symbols, graph: graph)
        let generator = TraversalHopGenerator(graph: graph, direction: direction,
            closedWorld: Self.isClosedWorld(limitations),
            runtimeDependencies: Self.automaticImpactDependencies(automatic))
        let result = MultiRootTraversal(generator: generator)
            .traverse(roots: requests.resolved.map(\.node), maxDepth: maxDepth ?? 128)
        let presenter = TraversalPresenter(graph: graph, project: project, requests: requests)
        let rows = presenter.reached(result.reached, limit: limit)
        limitations += requests.limitations + presenter.limitations(rows: rows, result: result,
            direction: direction, reasons: context.impactReviewReasons())
        return LanguageTraversalDocument(
            tool: .init(name: Cartograph.toolName, version: Cartograph.version),
            generatedAt: Self.bridgeTimestamp(generatedAt), project: project, direction: direction.rawValue,
            roots: presenter.roots(), reached: rows.values, rootsTruncated: rows.rootsTruncated,
            truncationReasons: (result.truncatedByDepth ? ["depth"] : []) + (rows.outputTruncated ? ["output"] : [])
                + (requests.unresolved.isEmpty ? [] : ["root-not-found"]),
            limitations: limitations
        )
    }

    /// `impact --format language-traversal` 명령. 해석하지 못한 root 는 문서를 낸 뒤 사용 오류(64)다.
    ///
    /// 방향은 문자열로 받는다. 실행 타깃이 분석 모듈을 직접 import 하지 않게 하려는 것이다(`impact` 의 `format` 과 같다).
    public func languageTraversal(
        symbols: [String], direction: String = "dependents", maxDepth: Int? = nil,
        limit: Int = Self.languageTraversalReachedLimit, generatedAt: Date = Date()
    ) throws -> CommandOutcome {
        guard let parsed = TraversalDirection(rawValue: direction) else {
            throw CartographError.invalidConfiguration(path: projectPath,
                reason: "Traversal direction must be dependents or dependencies.")
        }
        let document = try languageTraversalDocument(symbols: symbols, direction: parsed, maxDepth: maxDepth,
            limit: limit, generatedAt: generatedAt)
        let unresolved = document.roots.filter { $0.symbol == nil }.map(\.id)
        return CommandOutcome(
            output: try Self.encodeSortedJSON(document),
            subjectNotFound: !unresolved.isEmpty,
            notFoundMessage: "No declaration matches \(unresolved.count) root(s): "
                + unresolved.prefix(10).joined(separator: ", ")
                + ". Pass the symbol.usr from routes or bridges facts; the document above lists them as root-not-found."
        )
    }

    /// 계약의 도달 정점 상한. 기본 출력 한도로도 쓴다.
    public static let languageTraversalReachedLimit = 100_000

    private func validateTraversalLimits(symbols: [String], maxDepth: Int?, limit: Int) throws {
        guard (1...10_000).contains(symbols.count), (1...Self.languageTraversalReachedLimit).contains(limit),
              maxDepth.map({ (1...128).contains($0) }) ?? true else {
            throw CartographError.invalidConfiguration(path: projectPath, reason:
                "A language traversal needs 1...10000 roots, a limit of 1...100000 and an optional depth of 1...128.")
        }
    }

    // MARK: - 런타임과 닫힌 세계

    /// 자동 발견한 런타임 연결을 영향 관계로 옮긴다. `impact` 와 같은 규칙이다.
    static func automaticImpactDependencies(_ automatic: RuntimeDiscoveryReport?) -> [ImpactDependency] {
        automatic?.connections.compactMap { connection -> ImpactDependency? in
            guard let source = connection.source, source != connection.target else { return nil }
            return .init(source: source, target: connection.target, contract: connection.boundaryID,
                origin: .automatic, kind: connection.kind)
        } ?? []
    }

    /// 풀지 못한 런타임 경계와 발견기의 한계. `impact` 와 같은 문구다.
    static func automaticRuntimeLimitations(_ automatic: RuntimeDiscoveryReport?) -> [String] {
        let unresolvedStates: Set<RuntimeDiscoveryStatus> = [.dynamic, .unresolved, .ambiguous, .stale, .unindexed]
        let unresolved = automatic?.findings.count { unresolvedStates.contains($0.status) } ?? 0
        let summary = unresolved > 0
            ? ["unresolved-runtime-boundaries: \(unresolved) boundary(s) have unresolved names, "
                + "receivers or index evidence; impact can miss paths through them. Inspect runtime discover or collect a trace."]
            : []
        return summary + (automatic?.limitations ?? [])
    }

    /// 이 한계가 있으면 인덱스가 프로젝트 전체를 담는다고 볼 수 없다. 구현이 하나뿐이라는
    /// 증명은 보이지 않는 구현이 없을 때만 성립하므로 `bound` 를 내지 않는다.
    static let openWorldLimitationPrefixes = [
        "empty-index:", "index-staleness:", "unindexed-sources:", "missing-sources:", "unreadable-sources:",
        "configured-path-filter:", "configured-edge-kinds:", "objective-c-sources:", "public-api-not-retained:",
    ]

    static func isClosedWorld(_ limitations: [String]) -> Bool {
        !limitations.contains { limitation in openWorldLimitationPrefixes.contains { limitation.hasPrefix($0) } }
    }
}

// MARK: - root 해석

/// 요청 문자열을 root 로 푼다. 입력 순서를 지키고 같은 선언으로 풀린 요청은 하나로 합친다.
struct TraversalRootRequests {
    struct Resolved {
        let position: Int
        let node: NodeID
    }

    /// 문서의 root 목록. 해석한 것은 USR, 못 한 것은 원문이다.
    private(set) var ids: [String] = []
    private(set) var resolved: [Resolved] = []
    private(set) var unresolved: [String] = []
    private(set) var limitations: [String] = []
    private(set) var containerRoots = 0

    init(symbols: [String], graph: CodeGraph) {
        let lookup = GraphQueryIndex(graph: graph)
        var seen: Set<String> = []
        for subject in symbols {
            let outcome = Self.resolve(subject, lookup: lookup, graph: graph)
            let id = outcome.node?.rawValue ?? subject
            guard seen.insert(id).inserted else { continue }
            if let node = outcome.node {
                resolved.append(.init(position: ids.count, node: node))
                if graph.node(node).map(Self.isContainer) == true { containerRoots += 1 }
            } else {
                unresolved.append(subject)
                limitations.append("root-not-found: \(subject) " + outcome.explanation)
            }
            ids.append(id)
        }
        if containerRoots > 0 {
            limitations.append("container-roots-not-expanded: \(containerRoots) root(s) are types or extensions; "
                + "their members are not traversed as part of the root. Pass member USRs as roots to include them.")
        }
    }

    private static func resolve(
        _ subject: String, lookup: GraphQueryIndex, graph: CodeGraph
    ) -> (node: NodeID?, explanation: String) {
        switch lookup.resolve(subject) {
        case let .found(node): return (node.id, "")
        case let .ambiguous(candidates):
            if let type = ImpactSelection.sharedExtendedType(candidates, graph: graph) { return (type.id, "") }
            return (nil, "matches \(candidates.count) declarations; pass one USR")
        case .notFound:
            return (nil, "matches no declaration; pass the symbol.usr from routes or bridges facts")
        }
    }

    private static func isContainer(_ node: GraphNode) -> Bool {
        node.kind.isTypeDeclaration || node.kind == .extensionDeclaration
    }
}

// MARK: - 표현

/// 순회 결과를 계약의 모양으로 옮긴다.
struct TraversalPresenter {
    struct Rows {
        let values: [LanguageTraversalDocument.Reached]
        let nodes: [NodeID]
        let rootsTruncated: Bool
        let outputTruncated: Bool
    }

    /// 정점 하나가 싣는 root 인덱스 상한(계약).
    static let rootsPerReached = 64

    let graph: CodeGraph
    let requests: TraversalRootRequests
    private let baseVariants: [String]
    /// 순회 root 인덱스 → 문서 root 인덱스. 해석 못 한 요청이 섞여 두 인덱스가 다를 수 있다.
    private let documentIndex: [Int]

    init(graph: CodeGraph, project: String, requests: TraversalRootRequests) {
        self.graph = graph
        self.requests = requests
        baseVariants = PathFilter.variants(of: project)
        documentIndex = requests.resolved.map(\.position)
    }

    func roots() -> [LanguageTraversalDocument.Root] {
        let symbols = Dictionary(uniqueKeysWithValues: requests.resolved.map { ($0.position, $0.node) })
        return requests.ids.enumerated().map { position, id in
            .init(id: id, symbol: symbols[position].flatMap(symbol(for:)))
        }
    }

    /// 출력 한도를 적용한다. (depth, usr) 순 앞부분만 남긴다.
    ///
    /// 앞부분은 via 에 대해 닫혀 있다. 일반 행의 via 는 depth 가 하나 작고, root 항목의 via 정점은
    /// 그 root 를 포함한 모든 root 기준 depth 라서 root 항목의 depth 보다 작다. 그래서 잘라도
    /// 부모 없는 행(계약 위반)이 생기지 않는다.
    func reached(_ visits: [TraversalVisit], limit: Int) -> Rows {
        let kept = Array(visits.prefix(limit))
        let values = kept.compactMap(row(for:))
        return Rows(values: values, nodes: kept.map(\.node),
            rootsTruncated: kept.contains { $0.roots.count > Self.rootsPerReached },
            outputTruncated: visits.count > limit)
    }

    private func row(for visit: TraversalVisit) -> LanguageTraversalDocument.Reached? {
        guard let symbol = symbol(for: visit.node) else { return nil }
        let relationships = Set([visit.hop.relationship] + visit.hop.edges.map(\.rawValue))
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        return .init(symbol: symbol, via: visit.via.rawValue, depth: visit.depth,
            roots: visit.roots.prefix(Self.rootsPerReached).map { documentIndex[$0] },
            relationships: relationships, evidence: visit.evidence.rawValue)
    }

    /// 감싸는 타입까지 붙인 이름과 프로젝트 상대 위치.
    private func symbol(for id: NodeID) -> LanguageTraversalDocument.Symbol? {
        guard let node = graph.node(id) else { return nil }
        return .init(usr: id.rawValue, qualifiedName: ExternalRetentionIndex.syntaxQualifiedName(of: node, in: graph),
            kind: node.kind.rawValue, location: relativeLocation(of: node))
    }

    private func relativeLocation(of node: GraphNode) -> SourceLocation? {
        guard let location = node.location?.relative(toBaseVariants: baseVariants),
              Self.isProjectRelative(location.path), location.line >= 1, location.column >= 1 else { return nil }
        return location
    }

    /// isthmus 의 프로젝트 상대 경로 규칙과 같다: 비지 않고, 루트·드라이브로 시작하지 않고, `..` 가 없다.
    static func isProjectRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("\\")
            && !(path.count >= 2 && path.dropFirst().first == ":")
            && !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    // MARK: - 한계

    /// 이 순회가 보지 못했거나 좁게 판정한 것. 해당이 없으면 아무것도 싣지 않는다.
    func limitations(
        rows: Rows, result: TraversalResult, direction: TraversalDirection, reasons: [NodeID: Set<RetentionReason>]
    ) -> [String] {
        var lines: [String] = []
        if direction == .dependents, let runtime = runtimeInvokedLimitation(rows: rows, reasons: reasons) {
            lines.append(runtime)
        }
        if result.boundBlockedByOpenWorld > 0 {
            lines.append("dispatch-bound-unproven: \(result.boundBlockedByOpenWorld) dispatch hop(s) have a single "
                + "project implementation, but other limitations say the index does not cover the whole project, "
                + "so they are reported as candidate.")
        }
        let outside = (requests.resolved.map(\.node) + rows.nodes).count { id in
            guard let node = graph.node(id), node.location != nil else { return false }
            return relativeLocation(of: node) == nil
        }
        if outside > 0 {
            lines.append("traversal-location-outside-project: \(outside) symbol location(s) lie outside the "
                + "project root and were omitted.")
        }
        return lines
    }

    /// 외부 프레임워크·런타임이 부르는 선언. 프로그램 안에 호출자가 없어 역방향 도달이 거기서 멈춘다.
    ///
    /// SwiftUI `body`·`@main`·`@objc`·IB 연결·외부 프로토콜 구현이 그렇다. 호출자를 지어내지 않고,
    /// 멈춘 자리가 "소비자 없음"으로 읽히지 않도록 이름을 남긴다.
    private func runtimeInvokedLimitation(rows: Rows, reasons: [NodeID: Set<RetentionReason>]) -> String? {
        let nodes = Set(requests.resolved.map(\.node) + rows.nodes)
            .filter { !(reasons[$0] ?? []).isDisjoint(with: Self.runtimeInvokedReasons) }
            .sorted { $0.rawValue.utf16.lexicographicallyPrecedes($1.rawValue.utf16) }
        guard !nodes.isEmpty else { return nil }
        let shown = nodes.prefix(20).map { id in
            graph.node(id).map { ExternalRetentionIndex.syntaxQualifiedName(of: $0, in: graph) + " (\(id.rawValue))" }
                ?? id.rawValue
        }
        return "runtime-invoked-entry-points: \(nodes.count) declaration(s) in this traversal are invoked by an "
            + "external framework or the runtime (SwiftUI View.body, @main, @objc or Interface Builder hooks, external "
            + "protocol witnesses); the analyzed program has no caller for those invocations, so dependents stop "
            + "there: " + shown.joined(separator: ", ") + (nodes.count > 20 ? ", …" : "")
    }

    /// 프로그램 밖 호출자가 부를 수 있다는 보존 근거.
    static let runtimeInvokedReasons: Set<RetentionReason> = [
        .entryPoint, .externalConformance, .externalOverride, .interfaceBuilder, .objectiveCAccessible, .preview,
    ]
}
