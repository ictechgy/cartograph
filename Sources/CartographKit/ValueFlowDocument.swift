import CartographAnalysis
import CartographCore
import CartographSyntax
import Foundation

/// 선택한 함수의 호출 문맥과 그 근거 그래프를 함께 내보낸다.
public struct ValueFlowDocument: Sendable, Codable {
    public let format: String
    public let version: Int
    public let level: String
    public let subject: String
    public let status: String
    public let symbolUSR: String?
    public let candidates: [String]?
    public let selectedContexts: [String]
    public let limits: ValueFlowLimits
    public let graph: ValueFlowGraph

    /// 빈 조회에도 분석 한계와 예산을 싣는다.
    public init(subject: String, status: String, symbolUSR: String? = nil, candidates: [String]? = nil,
                selectedContexts: [String] = [], limits: ValueFlowLimits, graph: ValueFlowGraph) {
        self.format = "cartograph-value-flow"
        self.version = 1
        self.level = "value"
        self.subject = subject
        self.status = status
        self.symbolUSR = symbolUSR
        self.candidates = candidates
        self.selectedContexts = selectedContexts.sorted()
        self.limits = limits
        self.graph = graph
    }
}

/// 인덱스와 소스를 같은 경로 체계로 맞추고 파일별 신선도를 확인한다.
struct ValueFlowSourceLoader {
    let fileSystem: any FileSystem
    let projectPath: String
    let pathFilter: PathFilter

    func load(snapshot raw: IndexSnapshot) -> (program: ValueFlowProgram, snapshot: IndexSnapshot) {
        let snapshot = normalized(raw)
        let inventory = fileSystem.recursiveFiles(under: projectPath,
            isIncluded: { $0.hasSuffix(".swift") || $0.hasSuffix(".m") || $0.hasSuffix(".mm") },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:)).sorted()
        let swiftFiles = inventory.filter {
            $0.hasSuffix(".swift") && !AnalysisLimitationCollector.isPackageManifest($0, projectPath: projectPath)
        }
        let paths = swiftFiles.filter { pathFilter.allows($0) }
        var program = ValueFlowProgram()
        var fresh: Set<String> = []
        var seen: Set<String> = []
        var unreadable = 0
        var stale = 0
        var unindexed = 0
        var undated = 0
        for path in paths {
            let canonical = canonicalPath(path)
            guard seen.insert(canonical).inserted else { continue }
            guard let source = try? fileSystem.readText(at: path) else {
                unreadable += 1
                continue
            }
            let parsed = SwiftValueFlowParser().scan(source: source, path: canonical)
            program.functions += parsed.functions
            program.fields += parsed.fields
            program.types += parsed.types
            program.limitations += parsed.limitations
            if let indexed = snapshot.indexedFileDates?[canonical] {
                if let modified = fileSystem.modificationDate(at: path) {
                    if modified <= indexed { fresh.insert(canonical) } else { stale += 1 }
                } else { undated += 1 }
            } else { unindexed += 1 }
        }
        let counts = [("unreadable-value-flow-sources", unreadable), ("stale-value-flow-sources", stale),
            ("unindexed-value-flow-sources", unindexed), ("undated-value-flow-sources", undated),
            ("filtered-value-flow-sources", swiftFiles.count - paths.count),
            ("objective-c-value-flow-unavailable", inventory.count { !$0.hasSuffix(".swift") })]
        program.limitations += counts.filter { $0.1 > 0 }.map { "\($0.0): \($0.1) file(s)" }
        return (ValueFlowIndexBinder().bind(program: program, snapshot: snapshot, freshPaths: fresh), snapshot)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func normalized(_ raw: IndexSnapshot) -> IndexSnapshot {
        func location(_ value: SourceLocation) -> SourceLocation {
            SourceLocation(path: canonicalPath(value.path), line: value.line, column: value.column)
        }
        let symbols = raw.symbols.map {
            IndexedSymbol(usr: $0.usr, name: $0.name, kind: $0.kind, module: $0.module,
                location: location($0.location), parentUSR: $0.parentUSR, isExternal: $0.isExternal,
                accessibility: $0.accessibility, attributes: $0.attributes)
        }
        let references = raw.references.map {
            IndexedReference(sourceUSR: $0.sourceUSR, targetUSR: $0.targetUSR, kind: $0.kind,
                location: $0.location.map(location))
        }
        let dates = raw.indexedFileDates.map {
            Dictionary($0.map { (canonicalPath($0.key), $0.value) }, uniquingKeysWith: min)
        }
        return IndexSnapshot(symbols: symbols, references: references, indexedFileDates: dates)
    }
}
