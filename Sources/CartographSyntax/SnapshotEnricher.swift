import CartographCore

/// 인덱스 스냅샷에 구문 분석 결과를 덧붙인다.
///
/// 인덱스는 "무엇이 무엇을 참조하는가"를 정확히 알지만 "그 선언이 public 인지",
/// "@objc 가 붙었는지"는 모른다. 두 출처를 합쳐야 보존 규칙을 제대로 적용할 수 있다.
public struct SnapshotEnricher: Sendable {
    private let fileSystem: any FileSystem
    private let analyzer: SwiftSyntaxAnalyzer
    /// 파일이 그대로면 다시 파싱하지 않게 해 주는 캐시. nil 이면 매번 파싱한다.
    private let cache: SourceFactsCache?

    public init(
        fileSystem: any FileSystem = LocalFileSystem(),
        analyzer: SwiftSyntaxAnalyzer = .init(),
        cache: SourceFactsCache? = nil
    ) {
        self.fileSystem = fileSystem
        self.analyzer = analyzer
        self.cache = cache
    }

    /// 보존 설정에서 필요한 정보만 받아 분석기를 구성한다.
    public init(
        fileSystem: any FileSystem = LocalFileSystem(),
        retention: RetentionOptions,
        cachePath: String? = nil
    ) {
        // 분석기 설정이 결과를 바꾸므로 캐시 지문에 함께 넣는다. 이것이 없으면
        // `external_test_case_classes` 를 바꾼 뒤에도 예전 결과가 되살아난다.
        let identity = retention.externalTestCaseClasses.sorted().joined(separator: ",")
        self.init(
            fileSystem: fileSystem,
            analyzer: SwiftSyntaxAnalyzer(externalTestCaseClasses: retention.externalTestCaseClasses),
            cache: cachePath.map {
                SourceFactsCache(fileSystem: fileSystem, path: $0, analyzerIdentity: identity)
            }
        )
    }

    /// 스냅샷에 등장하는 소스 파일을 읽어 구문 정보를 붙인다.
    ///
    /// 읽지 못한 파일은 조용히 건너뛴다. 인덱스에는 남아 있지만 이미 삭제된
    /// 파일이 있을 수 있고, 그것 때문에 전체 분석이 실패해서는 안 된다.
    ///
    /// - Parameter interfaceBuilderRoots: xib/storyboard 를 찾을 디렉터리들.
    ///   비우면 Interface Builder 참조를 수집하지 않는다.
    public func enrich(
        _ snapshot: IndexSnapshot,
        interfaceBuilderRoots: [String] = [],
        pathFilter: PathFilter = .passthrough
    ) -> IndexSnapshot {
        let stored = cache?.load() ?? [:]
        var facts: [String: SourceFileFacts] = [:]
        var fresh: [String: SourceFactsCache.Entry] = [:]
        var reparsedAnyFile = false

        for path in snapshot.filePaths where path.hasSuffix(".swift") {
            guard let source = try? fileSystem.readText(at: path) else { continue }
            guard let cache else {
                facts[path] = analyzer.analyze(source: source, path: path)
                continue
            }
            // 내용이 그대로면 파싱을 건너뛴다. 파싱이 이 단계 비용의 대부분이다.
            let fingerprint = cache.fingerprint(of: source)
            let analyzed: SourceFileFacts
            if let hit = stored[path], hit.fingerprint == fingerprint {
                analyzed = hit.facts
            } else {
                analyzed = analyzer.analyze(source: source, path: path)
                reparsedAnyFile = true
            }
            facts[path] = analyzed
            fresh[path] = SourceFactsCache.Entry(fingerprint: fingerprint, facts: analyzed)
        }

        // 바뀐 것이 없으면 쓰지 않는다. 직렬화 비용이 캐시 이득을 깎기 때문이다.
        // 파일이 지워졌을 때도 항목 수가 달라지므로 그때는 다시 쓴다.
        if let cache, reparsedAnyFile || fresh.count != stored.count {
            cache.save(fresh)
        }

        let enriched = Self.enrich(snapshot, with: facts)
        guard !interfaceBuilderRoots.isEmpty else { return enriched }

        let references = InterfaceBuilderScanner(fileSystem: fileSystem)
            .scan(roots: interfaceBuilderRoots, pathFilter: pathFilter)
        return Self.marking(enriched, interfaceBuilderReferences: references)
    }

    /// Interface Builder 문서가 이름으로 지목한 타입에 표식을 붙인다.
    ///
    /// 스토리보드에서만 쓰이는 화면은 Swift 코드 어디에도 참조가 없다.
    /// 이 표식이 없으면 앱의 화면 상당수가 미사용으로 보고된다.
    public static func marking(
        _ snapshot: IndexSnapshot,
        interfaceBuilderReferences references: InterfaceBuilderReferences
    ) -> IndexSnapshot {
        guard !references.customClassNames.isEmpty else { return snapshot }
        var result = snapshot
        result.symbols = snapshot.symbols.map { symbol in
            guard symbol.kind.isTypeDeclaration,
                  references.customClassNames.contains(symbol.name)
            else { return symbol }
            var updated = symbol
            updated.attributes.insert(.interfaceBuilderAnnotated)
            return updated
        }
        return result
    }

    /// 이미 분석된 구문 정보로 스냅샷을 보강한다.
    ///
    /// 파일 접근이 없는 순수 함수라 매칭 규칙만 따로 테스트할 수 있다.
    public static func enrich(_ snapshot: IndexSnapshot, with facts: [String: SourceFileFacts]) -> IndexSnapshot {
        var enriched = snapshot
        enriched.symbols = snapshot.symbols.map { symbol in
            guard let fileFacts = facts[symbol.location.path] else { return symbol }
            var updated = symbol

            if fileFacts.ignoresEntireFile {
                updated.attributes.insert(.ignoreComment)
            }
            // 이름이 맞는 선언만 신뢰한다. 줄 번호만 보면 한 줄에 선언이 여럿일 때
            // 엉뚱한 선언의 접근 수준과 속성이 붙어 실제로 쓰이는 심볼이
            // 미사용으로 보고된다.
            guard let declaration = fileFacts.declaration(
                matchingIndexName: symbol.name,
                nearLine: symbol.location.line
            ) else { return updated }

            updated.accessibility = declaration.accessibility
            updated.attributes.formUnion(declaration.attributes)
            return updated
        }
        return enriched
    }
}
