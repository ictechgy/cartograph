import CartographAnalysis
import CartographCore
import Foundation

/// 실행에서 실제로 관측한 한계만 모은다. 파이프라인과 분리해 부분 실패와 신선도를 함께 검증한다.
struct AnalysisLimitationCollector {
    let configuration: CartographConfiguration
    let fileSystem: any FileSystem
    let projectPath: String
    let storeDate: Date?
    let inventory: ProjectFileInventory?
    /// 경로 하나의 정규화. 파일 시스템을 거치므로 `collect` 한 번 안에서는 경로마다 한 번만 부른다.
    /// 테스트는 이 자리에 횟수를 세는 함수를 넣는다.
    var canonicalize: (String) -> String = LocalFileSystem.canonicalPath

    init(
        configuration: CartographConfiguration,
        fileSystem: any FileSystem,
        projectPath: String,
        storeDate: Date?,
        inventory: ProjectFileInventory? = nil
    ) {
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.projectPath = projectPath
        self.storeDate = storeDate
        self.inventory = inventory
    }

    /// 이 분석이 보지 못하는 채널을 프로젝트에서 실제로 찾아 알린다.
    ///
    /// README 의 한계 목록을 문서에만 두면 소비자는 읽지 않는다. 특히 에이전트는
    /// 읽지 않는다. 눈앞의 답에 실어야 그 답을 어디까지 믿을지 스스로 정할 수 있다.
    func collect(
        context: AnalysisContext?,
        symbolGraph: CodeGraph?,
        emptyIndexCounts: (total: Int, inScope: Int)?
    ) -> [String] {
        // 한 번만 걷는다. 분석 범위와 같은 경로 필터를 걸어야 그래프가 보지 않는
        // 파일까지 세지 않는다. 범위 밖의 파일을 한계로 알리면 매번 붙는 경보가
        // 되고, 매번 붙는 경보는 읽히지 않는다.
        let filter = configuration.pathFilter
        let (files, externalLinks) = inventory.map { ($0.limitationFiles, $0.externalDirectoryLinks) }
            ?? walkLimitationFiles(filter: filter)

        func count(_ suffixes: String...) -> Int {
            files.count { path in suffixes.contains { path.hasSuffix($0) } }
        }
        let objectiveCCount = count(".m", ".mm")
        let interfaceBuilderCount = count(".xib", ".storyboard")
        let sourceFiles = files.filter { path in
            Self.sourceSuffixes.contains { path.hasSuffix($0) } && !Self.isPackageManifest(path, projectPath: projectPath)
        }
        // 소스 하나가 신선도 키·색인 여부·헤더 판정·진단 경로에 거듭 쓰인다. 정규화와 상대화 기준 표기
        // 펼치기는 파일 시스템을 거치므로 이번 수집 안에서는 경로마다 한 번만 한다.
        var pathResolver = PathResolver(canonicalize: canonicalize, projectPath: projectPath)
        let indexedDates = context?.snapshot.sourceFreshnessDates.map { dates in
            Dictionary(dates.map { (pathResolver.canonical($0.key), $0.value) }, uniquingKeysWith: min)
        }
        let newerFiles = sourceFiles.filter { path in
            // 공급자가 파일별 시각을 줬다면 전체 스토어 시각으로 대체하지 않는다.
            // 다른 타깃만 빌드했어도 스토어 시각은 최신이기 때문이다.
            let built = indexedDates == nil ? storeDate : indexedDates?[pathResolver.canonical(path)]
            guard let built, let modified = fileSystem.modificationDate(at: path) else { return false }
            return modified > built
        }

        var result: [String] = context?.indexSelectionLimitations ?? []
        if let inventory, !inventory.discoveryExclusions.isEmpty {
            result += Self.sourceDiscoveryLimitation(inventory.discoveryExclusions, projectPath: projectPath).map { [$0] } ?? []
        }
        // 탈출구를 켠 채로 도는 실행은 아무것도 분석하지 않는다. 그 답을 받은 쪽이
        // "발견 없음"을 깨끗함으로 읽지 않도록, 답 자체에 그 사실을 싣는다.
        if let counts = emptyIndexCounts {
            result.append(
                "empty-index: the index store knows none of this project's \(counts.total) "
                    + "source file(s) (\(counts.inScope) in scope), so every answer here is a "
                    + "statement about nothing"
            )
        }
        // 라이브러리 패키지는 호출자가 저장소 밖에 있다. `retain_public` 이 꺼진 채로 돌리면
        // 공개 API 전체가 미사용으로 나오고, 그 목록을 그대로 삭제로 옮기면 소비자가 전부
        // 깨진다. 스크래치 패키지에서 공개 타입 둘이 통째로 보고되는 것을 확인했다.
        if !configuration.retention.retainPublic, let products = libraryProductCount(), products > 0 {
            result.append(
                "public-api-not-retained: this package exports \(products) library product(s) and "
                    + "retain_public is off, so a public declaration whose only callers live "
                    + "outside this repository is reported unreachable"
            )
        }
        if objectiveCCount > 0 {
            result.append(
                "objective-c-sources: \(objectiveCCount) file(s); the graph uses available Clang index evidence, "
                    + "while runtime dispatch and unindexed source paths may be absent"
            )
        }
        let unknownClang = context?.snapshot.symbols.filter {
            $0.usr.hasPrefix("c:") && $0.module.isEmpty && !$0.isExternal
        } ?? []
        if !unknownClang.isEmpty {
            result.append("unknown-clang-module: \(unknownClang.count) local Clang declaration(s) have no "
                + "record/unit module evidence; their empty module is unknown, not a shared target. "
                + "Module-level dependencies and cycles cannot distinguish these owners."
                + diagnosticPaths(unknownClang.map(\.location.path), resolver: &pathResolver))
        }
        let admittedHeaders = Set(context?.snapshot.admittedHeaderPaths?.map { pathResolver.canonical($0) } ?? [])
        let headers = sourceFiles.filter {
            $0.hasSuffix(".h") && !admittedHeaders.contains(pathResolver.canonical($0))
        }
        if !headers.isEmpty {
            result.append(
                "header-projection: \(headers.count) project header file(s) are tracked for dependency freshness; "
                    + "coverage dates do not establish that their declarations and calls are present in the graph"
                    + diagnosticPaths(headers, resolver: &pathResolver)
            )
        }
        if interfaceBuilderCount > 0 {
            result.append(
                "interface-builder-documents: \(interfaceBuilderCount) document(s) are matched by "
                    + "custom class name only, never connection by connection"
            )
        }
        if !newerFiles.isEmpty {
            result.append(
                "index-staleness: \(newerFiles.count) of \(sourceFiles.count) source file(s) changed after the "
                    + (indexedDates == nil ? "index store was written" : "file's index unit was written")
                    + ", so a call added since the last build is not here yet"
                    + diagnosticPaths(newerFiles, resolver: &pathResolver)
            )
        }
        if let indexedDates, emptyIndexCounts == nil {
            let unindexed = sourceFiles.filter { indexedDates[pathResolver.canonical($0)] == nil }
            if !unindexed.isEmpty {
                result.append(
                    "unindexed-sources: \(unindexed.count) of \(sourceFiles.count) source file(s) "
                        + "have no known index unit; "
                        + "build their targets, or exclude files only after verifying they are not target sources, "
                        + "before relying on absent callers. Local module/target membership is not established by "
                        + "this file inventory, so missing-module-units cannot be classified from it; "
                        + "SDK and binary modules are not required to have local source units"
                        + diagnosticPaths(unindexed, resolver: &pathResolver)
                )
            }
        }
        let missing = context?.missingSourcePaths.filter {
            filter.allows($0) && pathResolver.relativeDiagnosticPath($0) != nil
        } ?? []
        let unreadable = context?.unreadableSourcePaths.filter {
            filter.allows($0) && pathResolver.relativeDiagnosticPath($0) != nil
        } ?? []
        let localFunctions = context?.unresolvedLocalFunctionsByPath.reduce(0) { count, entry in
            count + (filter.allows(entry.key) ? entry.value : 0)
        } ?? 0
        if localFunctions > 0 {
            result.append(
                "local-function-projection: \(localFunctions) source local function(s) could not be "
                    + "bound through a fresh, unambiguous call/reference chain; their indexed references "
                    + "remain attributed to enclosing declarations. Inspect source for exact local ownership."
            )
        }
        if !missing.isEmpty {
            result.append(
                "missing-sources: \(missing.count) indexed source file(s) no longer exist; rebuild with a fresh index "
                    + "to remove obsolete declarations"
                    + diagnosticPaths(missing, resolver: &pathResolver)
            )
        }
        if !unreadable.isEmpty {
            result.append(
                "unreadable-sources: \(unreadable.count) source file(s) could not be read; their declarations are kept "
                    + "with reason 'sourceUnavailable' because retention annotations are unknown. Restore access and rebuild"
                    + diagnosticPaths(unreadable, resolver: &pathResolver)
            )
        }
        if let linked = Self.externalDirectoryLinkLimitation(externalLinks, projectPath: projectPath) {
            result.append(linked)
        }
        if configuration.narrowsPathsBeyondDefaults {
            result.append(
                "configured-path-filter: include/exclude patterns narrow the analysis beyond the "
                    + "defaults, so an empty 'usedBy' can mean the caller was filtered out rather "
                    + "than absent"
            )
        }
        if !configuration.edgeKinds.isEmpty {
            result.append(
                "configured-edge-kinds: only "
                    + configuration.edgeKinds.map(\.rawValue).sorted().joined(separator: ", ")
                    + " edges are in the graph, so other relations are invisible here"
            )
        }
        // `single-configuration` 은 여기 있었다. 세는 것이 없어 모든 실행에 붙었고,
        // 프로젝트에 대한 진술이 아니라 인덱스 스토어 일반에 대한 진술이라 정의상
        // README 를 복사한 것이었다. 그 문장은 두 README 의 알려진 한계와 에이전트
        // 스킬에 있고, 여기서는 알릴 것이 있을 때만 말한다.
        result += externalRetentionLimitations(in: context, symbolGraph: symbolGraph, storeDate: storeDate)
        return result
    }

    /// inventory 없이 만든 수집기의 탐색. 한계 목록이 세는 파일과 따라가지 않은 루트 밖 디렉터리 링크를 모은다.
    private func walkLimitationFiles(filter: PathFilter) -> (files: [String], externalLinks: [String]) {
        var externalLinks: [String] = []
        let files = fileSystem.recursiveFiles(
            under: projectPath,
            isIncluded: { path in
                filter.allows(path) && (Self.sourceSuffixes.contains { path.hasSuffix($0) }
                    || RuntimeResourcePath.kind(of: path) == .interfaceBuilder)
            },
            shouldDescend: BuildArtifactDirectories.shouldDescend(into:),
            onExternalDirectoryLink: { externalLinks.append($0) }
        )
        return (files, ProjectFileInventory.inScope(externalLinks, pathFilter: filter))
    }

    /// 루트 밖을 가리켜 따라가지 않은 디렉터리 링크를 알리는 한계. 링크가 없으면 nil 이다.
    ///
    /// 분석 응답·교환 문서(routes·bridges·schema)·값 흐름 문서가 같은 접두사와 문장을 쓰도록 한 벌만 둔다.
    /// isthmus 의 닫힌 접두사 목록에 없는 접두사라 소비자는 이것으로 심각도를 낮추지 않는다 — 분석 대상
    /// 저장소가 심은 링크가 조인 게이트를 느슨하게 만들지 못한다. 링크 경로는 끝 요소를 풀지 않고
    /// 상대화한다. 풀면 링크 대상(루트 밖)이 되어 경로가 목록에서 사라진다.
    static func externalDirectoryLinkLimitation(_ links: [String], projectPath: String) -> String? {
        guard !links.isEmpty else { return nil }
        var spelling = PathResolver(canonicalize: { $0 }, projectPath: projectPath)
        return "symlinked-directories-outside-root: \(links.count) directory symlink(s) resolve outside the "
            + "project root and were not followed, so the sources behind them are not analyzed; run with "
            + "--project at a directory that contains them to include them"
            + encodedDiagnosticPaths(links.compactMap { spelling.relativeDiagnosticPath($0) })
    }

    static let maximumDiagnosticPaths = 64
    static let maximumDiagnosticPathBytes = 8_192

    /// 모든 분석/교환 경로가 동일한 누락 범위를 전달한다. 무시 규칙은 빌드 소속 근거가 아니다.
    static func sourceDiscoveryLimitation(_ paths: [String], projectPath: String) -> String? {
        guard !paths.isEmpty else { return nil }
        var resolver = PathResolver(canonicalize: { $0 }, projectPath: projectPath)
        return "source-discovery-exclusions: \(paths.count) source/resource path(s) or nested repositories "
            + "excluded by Git ignore rules or repository boundaries; tracked files take precedence over ignore rules. "
            + "This does not prove build-target coverage."
            + encodedDiagnosticPaths(paths.compactMap { resolver.relativeDiagnosticPath($0) })
    }

    /// 경고마다 최대 64개·JSON 배열 8 KiB만 내보낸다. 남은 경로 수는 숨기지 않는다.
    private func diagnosticPaths(_ paths: [String], resolver: inout PathResolver) -> String {
        Self.encodedDiagnosticPaths(paths.compactMap { resolver.relativeDiagnosticPath($0) })
    }

    /// 프로젝트 상대 경로를 정렬·중복 제거해 경고 꼬리로 붙인다. 경로가 없으면 빈 문자열이다.
    private static func encodedDiagnosticPaths(_ paths: [String]) -> String {
        let relative = Set(paths).sorted()
        guard !relative.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var displayed: [String] = []
        var bytes = 2 // JSON 배열의 대괄호.
        for path in relative {
            guard displayed.count < Self.maximumDiagnosticPaths,
                  let data = try? encoder.encode(path),
                  let encoded = String(data: data, encoding: .utf8) else { break }
            let safe = Self.escapedDiagnosticControls(encoded)
            let added = safe.utf8.count + (displayed.isEmpty ? 0 : 1)
            guard bytes + added <= Self.maximumDiagnosticPathBytes else { break }
            displayed.append(safe)
            bytes += added
        }
        let omitted = relative.count - displayed.count
        return "; paths: [" + displayed.joined(separator: ",") + "]"
            + (omitted == 0 ? "" : "; omitted-paths: \(omitted)")
    }

    private static func escapedDiagnosticControls(_ encoded: String) -> String {
        encoded.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                ? String(scalar).utf16.map { String(format: "\\u%04X", $0) }.joined() : String(scalar)
        }.joined()
    }

    /// 한 번의 수집 안에서 경로 정규화와 프로젝트 기준 상대화를 경로마다 한 번만 한다.
    ///
    /// 진단 경로마다 `relative(to:)` 를 부르면 기준 경로 표기 펼치기(URL 정규화·링크 해석)까지
    /// 경로 수만큼 되풀이된다. 기준 표기는 수집을 시작할 때 한 번만 펼친다.
    private struct PathResolver {
        private var canonicalPaths: CanonicalPathMemo
        private let baseVariants: [String]

        init(canonicalize: @escaping (String) -> String, projectPath: String) {
            canonicalPaths = CanonicalPathMemo(resolve: canonicalize)
            baseVariants = PathFilter.variants(of: projectPath)
        }

        mutating func canonical(_ path: String) -> String {
            canonicalPaths.path(path)
        }

        /// 프로젝트 안의 상대 경로. 프로젝트 밖이거나 `..` 로 벗어나면 nil 이다.
        mutating func relativeDiagnosticPath(_ path: String) -> String? {
            let relative = SourceLocation(path: canonical(path), line: 1, column: 1)
                .relative(toBaseVariants: baseVariants).path
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
            return relative
        }
    }

    /// 외부 보존 근거가 걸려 있으면 그 사실과 신선도를 알린다.
    ///
    /// `retained` 에 `externalBridge` 가 붙은 답은 인덱스가 아니라 그 파일을 믿은 것이다.
    /// 파일이 낡았으면 이름을 바꾼 핸들러의 근거가 아무것도 가리키지 않게 되고,
    /// 그 수를 세어 주지 않으면 소비자는 파일이 최신이라고 믿는다.
    private func externalRetentionLimitations(
        in context: AnalysisContext?,
        symbolGraph: CodeGraph?,
        storeDate: Date?
    ) -> [String] {
        guard let context, let document = context.externalRetentions else { return [] }
        let index = context.externalRetentionIndex
        var result = [
            "external-retentions: \(index.count) retention(s) from \(document.provenanceDescription) are in "
                + "effect, so a 'retained' answer with reason 'externalBridge' rests on that file, not on the index"
        ]
        result.append(contentsOf: ExternalRetentionProvenanceDiagnostics.limitations(document.provenance))
        if let omitted = document.omittedObjectiveCHandlers, omitted > 0 {
            result.append(
                "external-retentions-objective-c: \(omitted) matched Objective-C handler(s) were omitted by the producer; "
                    + "regenerate retentions with an isthmus build that supports indexed Clang identities"
            )
        }
        // 부르는 쪽이 이미 만든 심볼 그래프를 받는다. 여기서 다시 만들면 `query` 한 번에
        // 그래프를 두 번 짓는다. 인덱스 읽기 다음으로 비싼 단계다.
        let graph = symbolGraph ?? context.buildGraph(level: .symbol).graph
        let unmatched = index.unmatchedCount(in: graph)
        if unmatched > 0 {
            result.append(
                "external-retentions-unmatched: \(unmatched) of \(index.count) retention(s) name no declaration "
                    + "in this index, so the file may predate a rename or a rebuild"
            )
        }
        // 이름만 있는 근거가 여러 선언에 맞으면 전부 살린다. 확신이 없으면 살리는 쪽이
        // 이 도구의 규칙이지만, 그렇게 살아난 것이 있다는 사실은 알려야 한다.
        let ambiguous = index.ambiguousNameMatchCount(in: graph)
        if ambiguous > 0 {
            result.append(
                "external-retentions-ambiguous: \(ambiguous) name(s) from retentions without a USR match more than "
                    + "one declaration, and every one of those declarations is kept"
            )
        }
        // 파일이 인덱스보다 오래됐으면 그 사이의 이름 변경을 모른다. 날짜를 보여 주기만
        // 하면 판단은 사용자 몫인데, 비교는 이쪽이 할 수 있다.
        if let generated = document.generatedAt.flatMap(Self.parseISO8601),
           let built = storeDate, generated < built {
            result.append(
                "external-retentions-stale: the retentions file (\(document.generatedAt ?? "")) predates the index "
                    + "store, so it does not know about declarations renamed or added since"
            )
        }
        return result
    }

    /// 프로젝트 루트의 `Package.swift` 가 선언한 라이브러리 제품 수.
    ///
    /// 실행 파일 제품이 하나라도 있으면 nil 을 돌려 아무 말도 하지 않는다. 그런 패키지는
    /// 진입점이 저장소 안에 있어 도달성 분석이 성립하고, 공개 API 가 미사용으로 나오는
    /// 것이 정상적인 답일 수 있다. 호출자가 전부 밖에 있는 순수 라이브러리만 가른다.
    ///
    /// 매니페스트는 Swift 코드라 실행하지 않고는 정확히 알 수 없다. 여기서는 글자를 세고,
    /// 틀릴 수 있는 쪽을 "말하지 않음" 으로 둔다. 없는 경보를 만드는 것보다 낫다.
    private func libraryProductCount() -> Int? {
        let manifest = (projectPath as NSString).appendingPathComponent("Package.swift")
        guard let source = try? fileSystem.readText(at: manifest) else { return nil }
        guard !source.contains(".executable(") , !source.contains(".executableTarget(") else { return nil }
        return source.components(separatedBy: ".library(").count - 1
    }

    /// 한계 목록을 세는 데 필요한 확장자. 다른 파일은 걷지도 담지도 않는다.
    static let sourceSuffixes = [".m", ".mm", ".h", ".swift"]

    /// 매니페스트는 타깃 소스가 아니라 SwiftPM 입력이다. 인덱스 유닛이 없는 것이 정상이다.
    /// Sources/Package.swift 같은 실제 타깃 파일까지 제외하지 않도록 프로젝트 루트만 가른다.
    static func isPackageManifest(_ path: String, projectPath: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard name == "Package.swift" || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift"))
        else { return false }
        let parent = (LocalFileSystem.canonicalPath(path) as NSString).deletingLastPathComponent
        return parent == LocalFileSystem.canonicalPath(projectPath)
    }

    /// isthmus 가 쓰는 시각을 읽는다. `2026-09-04T12:00:00.000Z` 처럼 소수점 초가 붙는다.
    ///
    /// `.iso8601` 기본 전략은 소수점 초를 거부한다. 그러면 신선도 비교가 조용히 빠져
    /// 낡은 파일이 새것처럼 보인다.
    private static func parseISO8601(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
    }

}
