import CartographCore
import Foundation

/// 공유 Swift 소스의 module별 USR 대응을 raw symbol graph와 나란히 내보낸다.
public struct SwiftDeclarationProjectionRenderer: Sendable {
    private let prettyPrinted: Bool

    /// 기계 소비용 artifact의 공백 형식을 고정한다.
    public init(prettyPrinted: Bool = true) {
        self.prettyPrinted = prettyPrinted
    }

    /// raw graph와 선언 projection, 원본 occurrence 근거를 한 JSON 문서로 만든다.
    public func render(
        result: GraphBuilder.BuildResult,
        snapshot: IndexSnapshot,
        projectPath: String,
        primaryModule: String
    ) throws -> String {
        let projection = try SwiftDeclarationProjectionBuilder().build(
            result: result,
            snapshot: snapshot,
            projectPath: projectPath,
            primaryModule: primaryModule
        )
        let limitations = Self.limitations(projection)
        let document = Document(
            primaryModule: primaryModule,
            rawGraph: RawGraph(result.graph),
            projection: ProjectedGraph(nodes: projection.nodes, edges: projection.edges),
            evidence: projection.evidence,
            limitations: limitations
        )
        let encoder = JSONEncoder.cartographDefault(prettyPrinted: prettyPrinted)
        return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
    }

    private static func limitations(_ projection: SwiftDeclarationProjection) -> [String] {
        var result: [String] = []
        if projection.mergedGroupCount > 0 {
            result.append(
                "conditional-compilation-unverified: \(projection.mergedGroupCount) shared declaration group(s) "
                    + "were merged by normalized source identity across modules; "
                    + "active #if conditions are not represented"
            )
        }
        if projection.unresolvedGroupCount > 0 {
            result.append(
                "declaration-projection-unresolved: \(projection.unresolvedGroupCount) shared declaration group(s) "
                    + "did not have exactly one declaration in the primary module and remain raw nodes"
            )
        }
        if projection.unavailableKeyCount > 0 {
            result.append(
                "declaration-projection-key-unavailable: \(projection.unavailableKeyCount) declaration(s) lacked a "
                    + "bounded normalized location or lexical parent key and remain raw nodes"
            )
        }
        return result
    }
}

private extension SwiftDeclarationProjectionRenderer {
    struct Document: Encodable {
        let format = "cartograph-declaration-projection"
        let version = 1
        let tool = Cartograph.toolName
        let toolVersion = Cartograph.version
        let primaryModule: String
        let level = GraphLevel.symbol
        let rawGraph: RawGraph
        let projection: ProjectedGraph
        let evidenceCount: Int
        let unlocatedEvidenceCount: Int
        let evidence: [ProjectionEvidence]
        let limitations: [String]

        init(
            primaryModule: String,
            rawGraph: RawGraph,
            projection: ProjectedGraph,
            evidence: [ProjectionEvidence],
            limitations: [String]
        ) {
            self.primaryModule = primaryModule
            self.rawGraph = rawGraph
            self.projection = projection
            evidenceCount = evidence.count
            unlocatedEvidenceCount = evidence.count(where: { $0.location == nil })
            self.evidence = evidence
            self.limitations = limitations
        }
    }

    struct RawGraph: Encodable {
        let nodeCount: Int
        let edgeCount: Int
        let nodes: [GraphNode]
        let edges: [GraphEdge]

        init(_ graph: CodeGraph) {
            nodeCount = graph.nodeCount
            edgeCount = graph.edgeCount
            nodes = graph.sortedNodes
            edges = graph.edges
        }
    }

    struct ProjectedGraph: Encodable {
        let nodeCount: Int
        let edgeCount: Int
        let nodes: [ProjectionNode]
        let edges: [ProjectionEdge]

        init(nodes: [ProjectionNode], edges: [ProjectionEdge]) {
            nodeCount = nodes.count
            edgeCount = edges.count
            self.nodes = nodes
            self.edges = edges
        }
    }
}
