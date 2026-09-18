import CartographCore
import Foundation

/// 인덱스 스냅샷에 구문 분석 결과를 덧붙인다.
///
/// 인덱스는 "무엇이 무엇을 참조하는가"를 정확히 알지만 "그 선언이 public 인지",
/// "@objc 가 붙었는지"는 모른다. 두 출처를 합쳐야 보존 규칙을 제대로 적용할 수 있다.
public struct SnapshotEnricher: Sendable {
    /// 부분 실패를 호출자에게 전달해, 누락된 구문 정보를 완전한 분석으로 오인하지 않게 한다.
    public struct Result: Sendable {
        public let snapshot: IndexSnapshot
        public let missingSourcePaths: [String]
        public let unreadableSourcePaths: [String]
        public let runtimeFiles: [RuntimeFileFacts]
        /// 소스에 있지만 확실하게 세분하지 못해 바깥 인덱스 소유자로 남긴 지역 함수 수.
        public let unresolvedLocalFunctionsByPath: [String: Int]
        /// 개수만으로 알 수 없는 함수별 제외 원인을 보존한다.
        public let localFunctionDiagnostics: [LocalFunctionDiagnostic]
    }

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
        // 분석 결과를 바꾸는 것은 전부 지문에 넣는다. 하나라도 빠지면 그 축이 바뀐
        // 뒤에도 예전 결과가 되살아나고, 사용자는 고쳐진 줄 알았던 오탐을 계속 본다.
        let identity = SourceFactsCache.analyzerIdentity(
            toolVersion: Cartograph.version,
            analysisRevision: SwiftSyntaxAnalyzer.analysisRevision,
            externalTestCaseClasses: retention.externalTestCaseClasses
        )
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
    /// 삭제된 소스는 인덱스에 남을 수 있다. 나머지 읽기 실패는 보존 표식으로 남겨
    /// 주석·접근 수준을 모르는 선언을 미사용으로 보고하지 않는다.
    /// 실패 경로 목록도 필요한 호출자는 `enrichWithDiagnostics` 를 쓴다.
    ///
    /// - Parameter interfaceBuilderRoots: xib/storyboard 를 찾을 디렉터리들.
    ///   비우면 Interface Builder 참조를 수집하지 않는다.
    public func enrich(
        _ snapshot: IndexSnapshot,
        interfaceBuilderRoots: [String] = [],
        pathFilter: PathFilter = .passthrough,
        edgeKinds: Set<EdgeKind> = []
    ) -> IndexSnapshot {
        enrichWithDiagnostics(snapshot, interfaceBuilderRoots: interfaceBuilderRoots,
            pathFilter: pathFilter, edgeKinds: edgeKinds).snapshot
    }

    /// 실패 경로를 한 번의 읽기에서 수집한다. 파일을 다시 읽어 추측하면 실행 사이에 상태가 달라진다.
    public func enrichWithDiagnostics(
        _ snapshot: IndexSnapshot,
        interfaceBuilderRoots: [String] = [],
        pathFilter: PathFilter = .passthrough,
        edgeKinds: Set<EdgeKind> = []
    ) -> Result {
        let stored = cache?.load() ?? [:]
        var facts: [String: SourceFileFacts] = [:]
        var fresh: [String: SourceFactsCache.Entry] = [:]
        var missing: [String] = []
        var unreadable: [String] = []
        var freshPaths: Set<String> = []
        var freshnessFailures: [String: LocalFunctionSkipReason] = [:]

        for path in snapshot.filePaths where path.hasSuffix(".swift") {
            let sourceDate = fileSystem.modificationDate(at: path)
            let source: String
            do {
                source = try fileSystem.readText(at: path)
            } catch {
                // 존재 여부 재조회는 권한 오류도 '없음'으로 오인한다. 읽기가 돌려준 원인만 쓴다.
                if Self.isMissingFile(error) { missing.append(path) } else { unreadable.append(path) }
                continue
            }
            let afterRead = fileSystem.modificationDate(at: path)
            if snapshot.indexedFileDates?[path] == nil {
                freshnessFailures[path] = .indexDateUnavailable
            } else if sourceDate == nil || afterRead == nil {
                freshnessFailures[path] = .sourceDateUnavailable
            } else if let sourceDate, let indexed = snapshot.indexedFileDates?[path], sourceDate <= indexed,
                      afterRead == sourceDate {
                freshPaths.insert(path)
            } else {
                freshnessFailures[path] = .sourceNotFresh
            }
            guard let cache else {
                facts[path] = analyzer.analyze(source: source, path: path)
                continue
            }
            // 내용이 그대로면 파싱을 건너뛴다. 파싱이 이 단계 비용의 대부분이다.
            let fingerprint = cache.fingerprint(of: source)
            let analyzed = stored[path].flatMap { $0.fingerprint == fingerprint ? $0.facts : nil }
                ?? analyzer.analyze(source: source, path: path)
            facts[path] = analyzed
            fresh[path] = SourceFactsCache.Entry(fingerprint: fingerprint, facts: analyzed)
        }

        // 바뀐 것이 없으면 쓰지 않는다. 직렬화 비용이 캐시 이득을 깎는다.
        // 값을 그대로 비교한다. "미스가 있었는가"로 판단해도 결과는 같지만,
        // 왜 같은지가 한눈에 보이지 않아 나중 편집에서 깨지기 쉽다.
        if let cache, fresh != stored { cache.save(fresh) }

        let refinement = Self.enrichResult(snapshot, with: facts, freshSourcePaths: freshPaths,
            edgeKinds: edgeKinds, freshnessFailures: freshnessFailures)
        var enriched = refinement.snapshot
        let unreadablePaths = Set(unreadable)
        for index in enriched.symbols.indices where unreadablePaths.contains(enriched.symbols[index].location.path) {
            enriched.symbols[index].attributes.insert(.sourceUnavailable)
        }
        if !interfaceBuilderRoots.isEmpty {
            let references = InterfaceBuilderScanner(fileSystem: fileSystem)
                .scan(roots: interfaceBuilderRoots, pathFilter: pathFilter)
            enriched = Self.marking(enriched, interfaceBuilderReferences: references)
        }
        let unresolved = Dictionary(grouping: refinement.diagnostics, by: { $0.location.path }).mapValues(\.count)
        return Result(snapshot: enriched, missingSourcePaths: missing, unreadableSourcePaths: unreadable,
            runtimeFiles: facts.values.compactMap(\.runtimeFacts).sorted { $0.path < $1.path },
            unresolvedLocalFunctionsByPath: unresolved, localFunctionDiagnostics: refinement.diagnostics)
    }

    private static func isMissingFile(_ error: any Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
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
    public static func enrich(
        _ snapshot: IndexSnapshot,
        with facts: [String: SourceFileFacts],
        freshSourcePaths: Set<String> = [],
        edgeKinds: Set<EdgeKind> = []
    ) -> IndexSnapshot {
        enrichResult(snapshot, with: facts, freshSourcePaths: freshSourcePaths,
            edgeKinds: edgeKinds, freshnessFailures: [:]).snapshot
    }

    private static func enrichResult(
        _ snapshot: IndexSnapshot,
        with facts: [String: SourceFileFacts],
        freshSourcePaths: Set<String>,
        edgeKinds: Set<EdgeKind>,
        freshnessFailures: [String: LocalFunctionSkipReason]
    ) -> LocalFunctionBinder.Result {
        var enriched = snapshot
        let exactDeclarations = facts.mapValues { file in
            Dictionary(grouping: file.declarations.compactMap { declaration -> BoundDeclaration? in
                guard let location = declaration.nameLocation, location.path == file.path else { return nil }
                return BoundDeclaration(
                    key: DeclarationKey(name: declaration.name, location: location), facts: declaration
                )
            }, by: \.key)
        }
        let indexBindings = Dictionary(grouping: snapshot.symbols) {
            DeclarationKey(name: GraphNode.baseName(ofIndexName: $0.name), location: $0.location)
        }.mapValues { Set($0.map(\.usr)).count }
        enriched.symbols = snapshot.symbols.map { symbol in
            guard !SourceLocalSymbol.contains(symbol.usr) else { return symbol }
            guard let fileFacts = facts[symbol.location.path] else { return symbol }
            var updated = symbol
            updated.attributes.remove(.sourceUnavailable)

            if fileFacts.ignoresEntireFile {
                updated.attributes.insert(.ignoreComment)
                // 파일 범위라는 출처도 남긴다. 선언별 주석으로 파일 전체가
                // 무시된 경우와 구별하지 못하면 불필요 주석 진단이 선언 여럿의
                // 코멘트를 하나로 오인한다.
                updated.attributes.insert(.ignoreAllComment)
            }
            // 이름이 맞는 선언만 신뢰한다. 줄 번호만 보면 한 줄에 선언이 여럿일 때
            // 엉뚱한 선언의 접근 수준과 속성이 붙어 실제로 쓰이는 심볼이
            // 미사용으로 보고된다.
            let key = DeclarationKey(name: GraphNode.baseName(ofIndexName: symbol.name), location: symbol.location)
            let exact = exactDeclarations[symbol.location.path]?[key]
            let bound = exact?.count == 1 && indexBindings[key] == 1 ? exact?.first?.facts : nil
            guard let declaration = bound ?? fileFacts.declaration(
                matchingIndexName: symbol.name,
                nearLine: symbol.location.line
            ) else { return updated }

            updated.accessibility = declaration.accessibility
            updated.attributes.formUnion(declaration.attributes)
            // 인덱스의 dynamic 역할은 프로토콜·가상 호출에도 붙는다. 그것이 Swift의
            // 명시적 dynamic 제어자는 아니다. 정확히 한 선언에 바인딩되고 속성 효과가
            // 명시적으로 해석된 소스만 이 근거를 정정하며, 합성·오래된 캐시·모호한
            // 위치는 계속 보수적으로 둔다.
            if let bound, bound.hasUnresolvedAttributes == false, !symbol.attributes.contains(.implicit) {
                updated.attributes.remove(.dynamicDispatch)
                if bound.attributes.contains(.dynamicDispatch) {
                    updated.attributes.insert(.dynamicDispatch)
                }
            }
            return updated
        }
        enriched.parameters = joinedParameters(snapshot.parameters, with: facts)
        // import는 인덱스가 모듈 심볼 표식(`c:@M@…`)만 남기고 속성·`#if` 여부를
        // 모르므로 구문 사실이 유일한 출처다. 사실을 못 얻은 파일은 목록에
        // 나타나지 않고, 그 파일의 import는 미사용으로 보고되지 않는다.
        enriched.imports = facts.keys.sorted().flatMap { facts[$0]?.imports ?? [] }
        let bound = LocalFunctionBinder.enrichWithDiagnostics(enriched,
            scopes: facts.keys.sorted().flatMap { facts[$0]?.localFunctionScopes ?? [] },
            freshPaths: freshSourcePaths, edgeKinds: edgeKinds, freshnessFailures: freshnessFailures)
        var snapshot = bound.snapshot
        snapshot.references = markingReferencePositions(snapshot.references, with: facts)
        return LocalFunctionBinder.Result(snapshot: snapshot, diagnostics: bound.diagnostics)
    }

    /// 참조가 선언의 인터페이스에 있는지 본문에 있는지 표시한다.
    ///
    /// 구문 사실이 없는 파일의 참조는 `unknown` 으로 남긴다 — 위치를 모르는 것을
    /// 본문이라고 낮추면 필요 없는 공개 노출을 요구하지 않게 되어, "internal 로
    /// 줄여도 된다"는 틀린 답이 나온다.
    static func markingReferencePositions(
        _ references: [IndexedReference],
        with facts: [String: SourceFileFacts]
    ) -> [IndexedReference] {
        guard facts.contains(where: { $0.value.bodyRanges != nil }) else { return references }
        return references.map { reference in
            guard let location = reference.location,
                  let ranges = facts[location.path]?.bodyRanges
            else { return reference }
            let inBody = ranges.contains { $0.contains(location) }
            return reference.withPosition(inBody ? .body : .signature)
        }
    }

    /// 인덱스의 파라미터 선언과 본문 스캔 결과를 위치로 맞붙인다.
    ///
    /// 조인 키는 파라미터 내부 이름 토큰의 (줄, 열)이다 — 인덱스의 파라미터 선언
    /// 위치와 스캐너가 기록한 토큰 위치가 같은 자리를 가리킨다. 맞는 레코드가
    /// 없으면(본문 없는 요구사항, 스캔 못 한 파일) `isReferenced` 는 모름(nil)으로
    /// 남겨 미사용으로 보고하지 않는다.
    private static func joinedParameters(
        _ parameters: [IndexedParameter],
        with facts: [String: SourceFileFacts]
    ) -> [IndexedParameter] {
        guard !parameters.isEmpty else { return parameters }
        let usageBySite = facts.mapValues { file in
            Dictionary((file.parameterUsages ?? []).map {
                (ParameterSite(line: $0.location.line, column: $0.location.column), $0.isUsedInBody)
            }) { first, _ in first }
        }
        return parameters.map { parameter in
            guard let fileFacts = facts[parameter.location.path],
                  fileFacts.parameterUsages != nil,
                  let used = usageBySite[parameter.location.path]?[
                    ParameterSite(line: parameter.location.line, column: parameter.location.column)]
            else { return parameter }
            return IndexedParameter(
                usr: parameter.usr, name: parameter.name, module: parameter.module,
                location: parameter.location, functionUSR: parameter.functionUSR,
                isReferenced: used
            )
        }
    }

    /// 파라미터 조인에 쓰는 소스 내 자리. 경로는 맵 키로 이미 구분된다.
    private struct ParameterSite: Hashable {
        let line: Int
        let column: Int
    }

    private struct DeclarationKey: Hashable {
        let name: String
        let location: SourceLocation
    }

    private struct BoundDeclaration {
        let key: DeclarationKey
        let facts: DeclarationFacts
    }
}
