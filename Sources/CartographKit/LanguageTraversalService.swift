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
    ///   - revision: 분석한 소스의 revision. 이 계층은 git 을 모르므로 호출자가 정해 넘긴다.
    public func languageTraversalDocument(
        symbols: [String], direction: TraversalDirection = .dependents, maxDepth: Int? = nil,
        limit: Int = Self.languageTraversalReachedLimit, generatedAt: Date = Date(), revision: String? = nil,
        in existingContext: AnalysisContext? = nil
    ) throws -> LanguageTraversalDocument {
        try validateTraversalLimits(symbols: symbols, maxDepth: maxDepth, limit: limit)
        try validateExchangeText(symbols + (revision.map { [$0] } ?? []))
        let project = try canonicalProjectForExchange()
        let context = try existingContext ?? loadContext()
        let graph = context.buildGraph(level: .symbol).graph
        let automatic = context.runtimeDiscovery()
        var limitations = analysisLimitations(context: context, symbolGraph: graph)
            + Self.automaticRuntimeLimitations(automatic)
        let requests = TraversalRootRequests(symbols: symbols, graph: graph)
        let closedWorld = Self.isClosedWorld(limitations)
        let runtime = Self.automaticImpactDependencies(automatic) + context.impactLifecycle().dependencies
        let generator = TraversalHopGenerator(graph: graph, direction: direction, closedWorld: closedWorld,
            runtimeDependencies: runtime)
        let result = MultiRootTraversal(generator: generator)
            .traverse(roots: requests.resolved.map(\.node), maxDepth: maxDepth ?? 128)
        let presenter = TraversalPresenter(graph: graph, project: project, requests: requests)
        let rows = presenter.reached(result.reached, limit: limit)
        limitations += requests.limitations + presenter.limitations(rows: rows, result: result,
            direction: direction, reasons: context.impactReviewReasons())
        return LanguageTraversalDocument(
            tool: .init(name: Cartograph.toolName, version: Cartograph.version),
            generatedAt: Self.bridgeTimestamp(generatedAt), project: project, revision: revision,
            graphRevision: Self.graphRevision(graph: graph, runtime: runtime, closedWorld: closedWorld),
            direction: direction.rawValue,
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
        limit: Int = Self.languageTraversalReachedLimit, generatedAt: Date = Date(), revision: String? = nil
    ) throws -> CommandOutcome {
        guard let parsed = TraversalDirection(rawValue: direction) else {
            throw CartographError.invalidConfiguration(path: projectPath,
                reason: "Traversal direction must be dependents or dependencies.")
        }
        let document = try languageTraversalDocument(symbols: symbols, direction: parsed, maxDepth: maxDepth,
            limit: limit, generatedAt: generatedAt, revision: revision)
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

    /// isthmus 는 제어 문자(C0·DEL·C1·U+2028·U+2029)가 든 id·revision 이 있는 문서를 통째로 거부한다.
    /// 해석하지 못한 root 는 원문이 그대로 `id` 가 되므로, 문서를 만들기 전에 막는다.
    private func validateExchangeText(_ values: [String]) throws {
        guard let bad = values.first(where: { $0.isEmpty || ExchangeText.containsControlCharacter($0) }) else { return }
        throw CartographError.invalidConfiguration(path: projectPath, reason:
            "A language traversal root or revision is empty or contains a control character "
                + "(\(bad.debugDescription)); isthmus rejects such ids. Pass the symbol.usr from routes or bridges facts.")
    }


    /// 순회에 쓴 그래프의 내용 해시.
    ///
    /// 정점(id·종류), 간선(양 끝·종류), 자동 발견 런타임 연결, 닫힌 세계 판정을 정렬해 담는다. 위치는
    /// 넣지 않는다 — 줄만 옮긴 편집은 순회 결과를 바꾸지 않는다. 닫힌 세계 판정은 dispatch 걸음의
    /// 근거 등급을 정하므로 넣는다. 그래서 같은 그래프 위의 정·역방향 문서가 같은 값을 낸다.
    ///
    /// 값은 행마다 UTF-8 바이트 사전순으로 정렬한 `[[[String]]]` 을 `JSONEncoder.cartographDefault(prettyPrinted:
    /// false)` 로 인코딩한 바이트의 SHA-256 이다. isthmus 가 이 값을 불투명 문자열로 비교하므로 바이트는 그대로 두고,
    /// 행 배열과 인코딩을 통째로 만드는 대신 정렬한 인덱스를 돌며 같은 바이트를 조각으로 흘린다.
    /// `onHashedChunk` 는 해시에 넘긴 조각의 바이트 수를 받는 테스트용 관측 지점이다.
    static func graphRevision(graph: CodeGraph, runtime: [ImpactDependency], closedWorld: Bool,
                              onHashedChunk: ((Int) -> Void)? = nil) -> String {
        var digest = JSONStringArrayDigest(onChunk: onHashedChunk)
        digest.beginArray()
        appendNodeRows(of: graph, to: &digest)
        appendEdgeRows(of: graph, to: &digest)
        // 런타임 연결은 작고 같은 연결이 여러 계약으로 겹친다. 문자열 동등성으로 합치던 그대로 둔다.
        digest.appendRows(Set(runtime.map { [$0.source.rawValue, $0.target.rawValue] }).sorted(by: lexicographic))
        digest.appendRows([[closedWorld ? "closed-world" : "open-world"]])
        digest.endArray()
        return digest.finalize()
    }

    /// 정점 행 `[id, 종류]`. `sortedNodes` 는 문자열 `<`(정규화 비교) 순이라 결합 문자가 든 id 에서 UTF-8 순서와
    /// 갈리므로 인덱스만 다시 정렬한다. id 가 서로 달라 종류까지 갈 일은 없지만 행 비교 규칙을 그대로 따른다.
    private static func appendNodeRows(of graph: CodeGraph, to digest: inout JSONStringArrayDigest) {
        let nodes = graph.sortedNodes
        let order = nodes.indices.sorted { lhs, rhs in
            let byID = compareUTF8(nodes[lhs].id.rawValue, nodes[rhs].id.rawValue)
            return byID != 0 ? byID < 0 : compareUTF8(nodes[lhs].kind.rawValue, nodes[rhs].kind.rawValue) < 0
        }
        digest.beginArray()
        for index in order {
            digest.beginArray()
            digest.append(nodes[index].id.rawValue)
            digest.append(nodes[index].kind.rawValue)
            digest.endArray()
        }
        digest.endArray()
    }

    /// 간선 행 `[source, target, 종류]`. `graph.edges` 는 종류를 선언 순위로 정렬하므로 같은 두 정점 사이에서
    /// rawValue 순서와 갈린다. 이미 거의 정렬된 순서라 안정 정렬이 대부분 한 번 훑기로 끝난다.
    private static func appendEdgeRows(of graph: CodeGraph, to digest: inout JSONStringArrayDigest) {
        let edges = graph.edges
        let order = edges.indices.sorted { edgePrecedes(edges[$0], edges[$1]) }
        digest.beginArray()
        for index in order {
            digest.beginArray()
            digest.append(edges[index].source.rawValue)
            digest.append(edges[index].target.rawValue)
            digest.append(edges[index].kind.rawValue)
            digest.endArray()
        }
        digest.endArray()
    }

    private static func edgePrecedes(_ lhs: GraphEdge, _ rhs: GraphEdge) -> Bool {
        let bySource = compareUTF8(lhs.source.rawValue, rhs.source.rawValue)
        if bySource != 0 { return bySource < 0 }
        let byTarget = compareUTF8(lhs.target.rawValue, rhs.target.rawValue)
        if byTarget != 0 { return byTarget < 0 }
        return compareUTF8(lhs.kind.rawValue, rhs.kind.rawValue) < 0
    }

    /// 두 문자열의 UTF-8 바이트 사전순 비교. 음수면 `lhs` 가 앞이고 0 이면 바이트가 같다.
    private static func compareUTF8(_ lhs: String, _ rhs: String) -> Int {
        var right = rhs.utf8.makeIterator()
        for left in lhs.utf8 {
            guard let next = right.next() else { return 1 }
            if left != next { return left < next ? -1 : 1 }
        }
        return right.next() == nil ? 0 : -1
    }

    private static func lexicographic(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.lexicographicallyPrecedes(rhs) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
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
    /// 증명은 보이지 않는 구현이 없을 때만 성립하므로 `bound` 를 내지 않는다. 따라가지 않은
    /// 루트 밖 디렉터리 링크 뒤 소스는 색인됐어도 그래프에 없으므로 같은 공백이다.
    static let openWorldLimitationPrefixes = [
        "empty-index:", "index-staleness:", "unindexed-sources:", "missing-sources:", "unreadable-sources:",
        "header-projection:", "configured-path-filter:", "configured-edge-kinds:", "source-discovery-exclusions:",
        "objective-c-sources:", "public-api-not-retained:", "symlinked-directories-outside-root:",
        "build-module-coverage:", "build-module-coverage-unknown:",
    ]

    static func isClosedWorld(_ limitations: [String]) -> Bool {
        !limitations.contains { limitation in openWorldLimitationPrefixes.contains { limitation.hasPrefix($0) } }
    }
}

// MARK: - 교환 문자열

/// isthmus 교환 문서가 받는 문자열 규칙. 서비스·표현·CLI 가 함께 쓰므로 어느 한 타입에 두지 않는다.
public enum ExchangeText {
    /// isthmus `controlCharacterPattern` 과 같은 범위(C0·DEL·C1·U+2028·U+2029)의 문자가 있는지.
    public static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
        }
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
        return .init(usr: id.rawValue, qualifiedName: Self.exchangeName(of: node, in: graph),
            kind: node.kind.rawValue, location: relativeLocation(of: node))
    }

    /// 감싸는 타입까지 붙인 구문 표기. isthmus 는 빈 이름·제어 문자가 든 이름이 하나라도 있으면 문서를
    /// 통째로 거부하므로, 인자 목록을 떼어 비었거나 쓸 수 없는 표기는 인덱스 이름, 그다음 USR 로 대신한다.
    static func exchangeName(of node: GraphNode, in graph: CodeGraph) -> String {
        let candidates = [ExternalRetentionIndex.syntaxQualifiedName(of: node, in: graph), node.name, node.id.rawValue]
        return candidates.first { name in
            !name.isEmpty && !name.hasPrefix(".") && !name.hasSuffix(".") && !name.contains("..")
                && !ExchangeText.containsControlCharacter(name)
        } ?? node.id.rawValue
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
        // 다른 root 에서 닿은 root 는 두 목록에 모두 있으므로 집합으로 한 번만 센다.
        let outside = Set(requests.resolved.map(\.node) + rows.nodes).count { id in
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
