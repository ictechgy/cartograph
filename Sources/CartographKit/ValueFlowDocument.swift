import CartographAnalysis
import CartographCore
import CartographSyntax

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
    /// 경로 하나의 정규화. 파일 시스템을 거치므로 `load` 한 번 안에서는 경로마다 한 번만 부른다.
    /// 테스트는 이 자리에 횟수를 세는 함수를 넣는다.
    var canonicalize: (String) -> String = Self.canonicalPath

    /// sourceSnapshot은 첫 읽기 전체의 고정된 입력이다. 누락 파일을 뒤늦게 읽어 버전을 섞지 않는다.
    func load(snapshot raw: IndexSnapshot, sourceSnapshot: [String: String]? = nil) -> (program: ValueFlowProgram, snapshot: IndexSnapshot) {
        // 인덱스 위치·신선도 키와 디스크에서 찾은 소스 경로가 한 사전을 나눠 쓴다.
        var canonicalPaths = CanonicalPathMemo(resolve: canonicalize)
        let snapshot = normalized(raw, canonicalPaths: &canonicalPaths)
        var externalLinks: [String] = []
        let inventory = fileSystem.recursiveFiles(under: projectPath,
            isIncluded: { $0.hasSuffix(".swift") || $0.hasSuffix(".m") || $0.hasSuffix(".mm") },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:),
            onExternalDirectoryLink: { externalLinks.append($0) }).sorted()
        let swiftFiles = inventory.filter {
            $0.hasSuffix(".swift") && !AnalysisLimitationCollector.isPackageManifest($0, projectPath: projectPath)
        }
        let paths = swiftFiles.filter { pathFilter.allows($0) }
        var program = ValueFlowProgram()
        var fresh: Set<String> = []
        var seen: Set<String> = []
        var unreadable = 0
        var uncaptured = 0
        var stale = 0
        var unindexed = 0
        var undated = 0
        for path in paths {
            let canonical = canonicalPaths.path(path)
            guard seen.insert(canonical).inserted else { continue }
            let source: String?
            if let sourceSnapshot {
                guard let captured = sourceSnapshot[canonical] else { uncaptured += 1; continue }
                source = captured
            }
            else { source = try? fileSystem.readText(at: path) }
            guard let source else {
                unreadable += 1
                continue
            }
            let parsed = SwiftValueFlowParser().scan(source: source, path: canonical)
            program.functions += parsed.functions
            program.fields += parsed.fields
            program.types += parsed.types
            program.limitations += parsed.limitations
            if let indexed = snapshot.sourceFreshnessDates?[canonical] {
                if let modified = fileSystem.modificationDate(at: path) {
                    if modified <= indexed { fresh.insert(canonical) } else { stale += 1 }
                } else { undated += 1 }
            } else { unindexed += 1 }
        }
        let counts = [("unreadable-value-flow-sources", unreadable), ("uncaptured-value-flow-sources", uncaptured), ("stale-value-flow-sources", stale),
            ("unindexed-value-flow-sources", unindexed), ("undated-value-flow-sources", undated),
            ("filtered-value-flow-sources", swiftFiles.count - paths.count),
            ("objective-c-value-flow-unavailable", inventory.count { !$0.hasSuffix(".swift") })]
        program.limitations += counts.filter { $0.1 > 0 }.map { "\($0.0): \($0.1) file(s)" }
        if let linked = AnalysisLimitationCollector.externalDirectoryLinkLimitation(
            ProjectFileInventory.inScope(externalLinks, pathFilter: pathFilter), projectPath: projectPath
        ) {
            program.limitations.append(linked)
        }
        return (ValueFlowIndexBinder().bind(program: program, snapshot: snapshot, freshPaths: fresh), snapshot)
    }

    static func canonicalPath(_ path: String) -> String {
        LocalFileSystem.canonicalPath(path)
    }

    /// 심볼·참조 위치와 신선도 키를 정규 경로로 맞춘다.
    ///
    /// 고유 경로는 파일 수만큼인데 위치는 발생 수만큼이다. 같은 경로는 `canonicalPaths` 가 한 번만 정규화한다.
    private func normalized(_ raw: IndexSnapshot, canonicalPaths: inout CanonicalPathMemo) -> IndexSnapshot {
        func location(_ value: SourceLocation) -> SourceLocation {
            SourceLocation(path: canonicalPaths.path(value.path), line: value.line, column: value.column)
        }
        let symbols = raw.symbols.map {
            IndexedSymbol(usr: $0.usr, name: $0.name, kind: $0.kind, module: $0.module,
                location: location($0.location), parentUSR: $0.parentUSR, isExternal: $0.isExternal,
                accessibility: $0.accessibility, attributes: $0.attributes,
                compilerUnitTest: $0.compilerUnitTest)
        }
        let references = raw.references.map {
            IndexedReference(sourceUSR: $0.sourceUSR, targetUSR: $0.targetUSR, kind: $0.kind,
                location: $0.location.map(location), targetKind: $0.targetKind,
                origin: $0.origin, position: $0.position, receiverTypeUSR: $0.receiverTypeUSR)
        }
        let dates = raw.indexedFileDates.map {
            Dictionary($0.map { (canonicalPaths.path($0.key), $0.value) }, uniquingKeysWith: min)
        }
        let oldestDates = raw.oldestIndexedFileDates.map {
            Dictionary($0.map { (canonicalPaths.path($0.key), $0.value) }, uniquingKeysWith: min)
        }
        let headers = raw.admittedHeaderPaths.map { $0.map { canonicalPaths.path($0) }.sorted() }
        let enumFiles = raw.enumImpactFiles?.map { $0.rebased { canonicalPaths.path($0) } }
        return IndexSnapshot(symbols: symbols, references: references, indexedFileDates: dates,
            oldestIndexedFileDates: oldestDates,
            admittedHeaderPaths: headers, enumImpactFiles: enumFiles,
            sourceRecordAdmissions: raw.sourceRecordAdmissions?.map { $0.rebased { canonicalPaths.path($0) } })
    }
}
