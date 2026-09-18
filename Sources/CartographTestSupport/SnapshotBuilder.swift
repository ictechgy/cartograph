import CartographCore

/// 테스트에서 인덱스 스냅샷을 손으로 조립하기 위한 빌더.
///
/// 실제 인덱스 스토어 없이 분석 계층 전체를 검증할 수 있게 해 준다.
/// 이 타입이 있기 때문에 Core/Analysis/Export 테스트는 Xcode 빌드에 의존하지 않는다.
public struct SnapshotBuilder {
    private var symbols: [IndexedSymbol] = []
    private var references: [IndexedReference] = []
    private var parameters: [IndexedParameter] = []
    private var propertyAccesses: [String: PropertyAccessFacts] = [:]
    private var imports: [IndexedImport] = []
    private var fileModuleUsages: [String: FileModuleUsage] = [:]
    private let defaultModule: String
    private let defaultPath: String

    public init(module: String = "App", path: String = "/project/Sources/App/App.swift") {
        self.defaultModule = module
        self.defaultPath = path
    }

    /// 심볼 하나를 추가한다. USR 은 이름에서 유도하므로 테스트에서 짧게 쓸 수 있다.
    @discardableResult
    public mutating func symbol(
        _ usr: String,
        name: String? = nil,
        kind: SymbolKind = .structType,
        module: String? = nil,
        path: String? = nil,
        line: Int = 1,
        column: Int = 1,
        parent: String? = nil,
        isExternal: Bool = false,
        accessibility: Accessibility = .internalLevel,
        attributes: Set<SymbolAttribute> = []
    ) -> Self {
        symbols.append(
            IndexedSymbol(
                usr: usr,
                name: name ?? usr,
                kind: kind,
                module: module ?? defaultModule,
                location: SourceLocation(path: path ?? defaultPath, line: line, column: column),
                parentUSR: parent,
                isExternal: isExternal,
                accessibility: accessibility,
                attributes: attributes
            )
        )
        return self
    }

    /// 참조 하나를 추가한다.
    @discardableResult
    public mutating func reference(
        from source: String,
        to target: String,
        kind: EdgeKind = .reference,
        path: String? = nil,
        line: Int = 1,
        targetKind: SymbolKind? = nil,
        origin: ReferenceOrigin = .unknown
    ) -> Self {
        references.append(
            IndexedReference(
                sourceUSR: source,
                targetUSR: target,
                kind: kind,
                location: SourceLocation(path: path ?? defaultPath, line: line, column: 1),
                targetKind: targetKind,
                origin: origin
            )
        )
        return self
    }

    /// 파라미터 선언 하나를 추가한다.
    ///
    /// 파라미터는 그래프 정점이 아니라 스냅샷의 별도 목록으로 흐르므로 빌더도
    /// 심볼과 다른 통로를 둔다. `isReferenced` 는 구문 보강이 채우는 값이다.
    @discardableResult
    public mutating func parameter(
        _ usr: String,
        name: String,
        functionUSR: String,
        module: String? = nil,
        path: String? = nil,
        line: Int = 1,
        column: Int = 1,
        isReferenced: Bool? = nil
    ) -> Self {
        parameters.append(
            IndexedParameter(
                usr: usr,
                name: name,
                module: module ?? defaultModule,
                location: SourceLocation(path: path ?? defaultPath, line: line, column: column),
                functionUSR: functionUSR,
                isReferenced: isReferenced
            )
        )
        return self
    }

    /// 프로퍼티 하나에 대한 접근 방향 근거를 추가한다.
    ///
    /// 파라미터와 달리 접근 근거는 그래프 정점의 USR 을 키로 하는 표다.
    /// 키가 없는 심볼은 "근거 없음" 이므로 미사용으로 읽히지 않는다.
    @discardableResult
    public mutating func propertyAccess(
        _ usr: String,
        read: Bool = false,
        write: Bool = false,
        ambiguous: Bool = false
    ) -> Self {
        propertyAccesses[usr] = PropertyAccessFacts(
            hasRead: read, hasWrite: write, hasAmbiguous: ambiguous)
        return self
    }

    /// `import` 선언 하나를 추가한다.
    ///
    /// 실제 파이프라인에서는 구문 분석이 이 목록을 채운다 — 인덱스는 import를
    /// 모듈 심볼 표식으로만 남겨 속성과 `#if` 여부를 알 수 없기 때문이다.
    @discardableResult
    public mutating func importDecl(
        _ modulePath: String,
        path: String? = nil,
        line: Int = 1,
        scopedKind: String? = nil,
        isConditional: Bool = false,
        isReexported: Bool = false,
        isIgnored: Bool = false,
        isIgnoredOnlyByFileComment: Bool = false
    ) -> Self {
        imports.append(
            IndexedImport(
                modulePath: modulePath.components(separatedBy: "."),
                scopedKind: scopedKind,
                isConditional: isConditional,
                isReexported: isReexported,
                isIgnored: isIgnored,
                isIgnoredOnlyByFileComment: isIgnoredOnlyByFileComment,
                location: SourceLocation(path: path ?? defaultPath, line: line, column: 1)
            )
        )
        return self
    }

    /// 파일 하나의 모듈 사용 근거를 추가한다.
    @discardableResult
    public mutating func fileModuleUsage(
        path: String? = nil,
        owningModule: String? = nil,
        referencedModules: Set<String> = [],
        hasUnattributedReferences: Bool = false
    ) -> Self {
        fileModuleUsages[path ?? defaultPath] = FileModuleUsage(
            owningModule: owningModule,
            referencedModules: referencedModules,
            hasUnattributedReferences: hasUnattributedReferences
        )
        return self
    }

    public func build() -> IndexSnapshot {
        IndexSnapshot(symbols: symbols, references: references, parameters: parameters,
                      propertyAccesses: propertyAccesses, imports: imports,
                      fileModuleUsages: fileModuleUsages)
    }
}
