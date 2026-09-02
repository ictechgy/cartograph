import CartographCore

/// 인덱스 스냅샷에 구문 분석 결과를 덧붙인다.
///
/// 인덱스는 "무엇이 무엇을 참조하는가"를 정확히 알지만 "그 선언이 public 인지",
/// "@objc 가 붙었는지"는 모른다. 두 출처를 합쳐야 보존 규칙을 제대로 적용할 수 있다.
public struct SnapshotEnricher: Sendable {
    private let fileSystem: any FileSystem
    private let analyzer: SwiftSyntaxAnalyzer

    public init(fileSystem: any FileSystem = LocalFileSystem(), analyzer: SwiftSyntaxAnalyzer = .init()) {
        self.fileSystem = fileSystem
        self.analyzer = analyzer
    }

    /// 보존 설정에서 필요한 정보만 받아 분석기를 구성한다.
    public init(fileSystem: any FileSystem = LocalFileSystem(), retention: RetentionOptions) {
        self.init(
            fileSystem: fileSystem,
            analyzer: SwiftSyntaxAnalyzer(externalTestCaseClasses: retention.externalTestCaseClasses)
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
        var facts: [String: SourceFileFacts] = [:]
        for path in snapshot.filePaths where path.hasSuffix(".swift") {
            guard let source = try? fileSystem.readText(at: path) else { continue }
            facts[path] = analyzer.analyze(source: source, path: path)
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
