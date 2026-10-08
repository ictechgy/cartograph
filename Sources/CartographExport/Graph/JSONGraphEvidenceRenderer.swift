import CartographCore
import Foundation

/// 기존 그래프 JSON에 원본 reference occurrence와 별도 import·inventory 사실을 더하는
/// opt-in 렌더러.
///
/// occurrence를 graph edge로 다시 해석하지 않고 `GraphBuilder.BuildResult.nodeIDByUSR`와
/// 최종 간선 집합을 대조한다. 따라서 level roll-up, 필터, 외부 심볼, self-loop 정책은
/// 그래프 생성과 정확히 같다.
public struct JSONGraphEvidenceRenderer: Sendable {
    private let prettyPrinted: Bool

    public init(prettyPrinted: Bool = true) {
        self.prettyPrinted = prettyPrinted
    }

    /// reference 배열을 자르지 않고 결정적인 JSON 문서로 만든다.
    ///
    /// - Parameters:
    ///   - result: 최종 그래프와 그 그래프를 만든 USR → node 매핑.
    ///   - snapshot: occurrence와 import·index inventory 사실.
    ///   - projectPath: 출력 위치를 프로젝트 상대 경로로 바꾸는 기준.
    ///   - sourceFiles: 한 번의 프로젝트 walk가 관찰한 source inventory. nil은 inventory 미제공이다.
    public func render(
        result: GraphBuilder.BuildResult,
        snapshot: IndexSnapshot,
        projectPath: String,
        sourceFiles: [String]? = nil
    ) throws -> String {
        let assembler = Assembler(result: result, snapshot: snapshot, projectPath: projectPath)
        let evidence = assembler.evidence()
        let imports = assembler.moduleImports()
        let limitations = Self.limitations(graph: result.graph, importCount: imports.count)
        let document = Document(
            graph: result.graph,
            evidence: evidence,
            moduleImports: imports,
            inventory: assembler.inventory(sourceFiles: sourceFiles),
            limitations: limitations.isEmpty ? nil : limitations
        )
        let encoder = JSONEncoder.cartographDefault(prettyPrinted: prettyPrinted)
        return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
    }

    /// import 선언 사실이 module topology와 같은 값으로 오인되지 않게 실제 공백을 센다.
    private static func limitations(graph: CodeGraph, importCount: Int) -> [String] {
        guard importCount > 0, !graph.edges.contains(where: { $0.kind == .importDeclaration }) else { return [] }
        return [
            "module-import-topology: \(importCount) import declaration(s) are exported as separate facts; "
                + "the graph has no importDeclaration edges, so imports are not represented as topology"
        ]
    }
}

private extension JSONGraphEvidenceRenderer {
    struct Document: Encodable {
        let tool = Cartograph.toolName
        let version = Cartograph.version
        let level: GraphLevel
        let nodeCount: Int
        let edgeCount: Int
        let nodes: [GraphNode]
        let edges: [GraphEdge]
        let evidenceCount: Int
        let unlocatedEvidenceCount: Int
        let evidence: [Evidence]
        let moduleImportCount: Int
        let unlocatedModuleImportCount: Int
        let moduleImports: [ModuleImport]
        let inventory: Inventory
        let limitations: [String]?

        init(
            graph: CodeGraph,
            evidence: [Evidence],
            moduleImports: [ModuleImport],
            inventory: Inventory,
            limitations: [String]?
        ) {
            level = graph.level
            nodeCount = graph.nodeCount
            edgeCount = graph.edgeCount
            nodes = graph.sortedNodes
            edges = graph.edges
            evidenceCount = evidence.count
            unlocatedEvidenceCount = evidence.count(where: { $0.location == nil })
            self.evidence = evidence
            moduleImportCount = moduleImports.count
            unlocatedModuleImportCount = moduleImports.count(where: { $0.location == nil })
            self.moduleImports = moduleImports
            self.inventory = inventory
            self.limitations = limitations
        }
    }

    struct Evidence: Encodable {
        let source: NodeID
        let target: NodeID
        let kind: EdgeKind
        let sourceUSR: String
        let targetUSR: String
        let targetKind: SymbolKind?
        let origin: ReferenceOrigin
        let position: ReferencePosition
        let location: SourceLocation?
    }

    struct ModuleImport: Encodable {
        let modulePath: [String]
        let scopedKind: String?
        let isConditional: Bool
        let isReexported: Bool
        let isIgnored: Bool
        let isIgnoredOnlyByFileComment: Bool
        let location: SourceLocation?
    }

    struct Inventory: Encodable {
        let source: FileInventory?
        let index: FileInventory?
    }

    struct FileInventory: Encodable {
        let totalCount: Int
        let files: [String]
        let omittedCount: Int
    }

    struct EdgeSignature: Hashable {
        let source: NodeID
        let target: NodeID
        let kind: EdgeKind
    }

    struct Assembler {
        let result: GraphBuilder.BuildResult
        let snapshot: IndexSnapshot
        let baseVariants: [String]

        init(result: GraphBuilder.BuildResult, snapshot: IndexSnapshot, projectPath: String) {
            self.result = result
            self.snapshot = snapshot
            baseVariants = PathFilter.variants(of: projectPath)
        }

        func evidence() -> [Evidence] {
            let visible = Set(result.graph.edges.map {
                EdgeSignature(source: $0.source, target: $0.target, kind: $0.kind)
            })
            return snapshot.references.compactMap { reference in
                guard let source = result.nodeIDByUSR[reference.sourceUSR],
                      let target = result.nodeIDByUSR[reference.targetUSR],
                      visible.contains(EdgeSignature(source: source, target: target, kind: reference.kind))
                else { return nil }
                return Evidence(
                    source: source,
                    target: target,
                    kind: reference.kind,
                    sourceUSR: reference.sourceUSR,
                    targetUSR: reference.targetUSR,
                    targetKind: reference.targetKind,
                    origin: reference.origin,
                    position: reference.position,
                    location: relative(reference.location)
                )
            }
            .sorted(by: Self.evidenceOrder)
        }

        func moduleImports() -> [ModuleImport] {
            snapshot.imports.map { entry in
                ModuleImport(
                    modulePath: entry.modulePath,
                    scopedKind: entry.scopedKind,
                    isConditional: entry.isConditional,
                    isReexported: entry.isReexported,
                    isIgnored: entry.isIgnored,
                    isIgnoredOnlyByFileComment: entry.isIgnoredOnlyByFileComment,
                    location: relative(entry.location)
                )
            }
            .sorted(by: Self.importOrder)
        }

        func inventory(sourceFiles: [String]?) -> Inventory {
            Inventory(
                source: sourceFiles.map(fileInventory),
                index: snapshot.indexedFileDates.map { fileInventory(Array($0.keys)) }
            )
        }

        private func fileInventory(_ paths: [String]) -> FileInventory {
            let unique = Set(paths)
            let files = unique.compactMap(relativePath).sorted()
            return FileInventory(totalCount: unique.count, files: files, omittedCount: unique.count - files.count)
        }

        private func relative(_ location: SourceLocation?) -> SourceLocation? {
            guard let location else { return nil }
            let relative = location.relative(toBaseVariants: baseVariants)
            guard Self.isRelative(relative.path), relative.line > 0, relative.column > 0 else { return nil }
            return relative
        }

        private func relativePath(_ path: String) -> String? {
            relative(SourceLocation(path: path, line: 1, column: 1))?.path
        }

        private static func isRelative(_ path: String) -> Bool {
            !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("\\")
                && !(path.count >= 2 && path.dropFirst().first == ":")
                && !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
        }

        private static func evidenceOrder(_ lhs: Evidence, _ rhs: Evidence) -> Bool {
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

        private static func importOrder(_ lhs: ModuleImport, _ rhs: ModuleImport) -> Bool {
            if (lhs.location == nil) != (rhs.location == nil) { return lhs.location != nil }
            if let left = lhs.location, let right = rhs.location, left != right { return left < right }
            if lhs.modulePath != rhs.modulePath {
                return lhs.modulePath.lexicographicallyPrecedes(rhs.modulePath)
            }
            if lhs.scopedKind != rhs.scopedKind { return (lhs.scopedKind ?? "") < (rhs.scopedKind ?? "") }
            let leftFlags = [lhs.isConditional, lhs.isReexported, lhs.isIgnored, lhs.isIgnoredOnlyByFileComment]
                .map { $0 ? 1 : 0 }
            let rightFlags = [rhs.isConditional, rhs.isReexported, rhs.isIgnored, rhs.isIgnoredOnlyByFileComment]
                .map { $0 ? 1 : 0 }
            return leftFlags.lexicographicallyPrecedes(rightFlags)
        }
    }
}
