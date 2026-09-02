import CartographCore

/// 테스트에서 인덱스 스냅샷을 손으로 조립하기 위한 빌더.
///
/// 실제 인덱스 스토어 없이 분석 계층 전체를 검증할 수 있게 해 준다.
/// 이 타입이 있기 때문에 Core/Analysis/Export 테스트는 Xcode 빌드에 의존하지 않는다.
public struct SnapshotBuilder {
    private var symbols: [IndexedSymbol] = []
    private var references: [IndexedReference] = []
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
        line: Int = 1
    ) -> Self {
        references.append(
            IndexedReference(
                sourceUSR: source,
                targetUSR: target,
                kind: kind,
                location: SourceLocation(path: path ?? defaultPath, line: line, column: 1)
            )
        )
        return self
    }

    public func build() -> IndexSnapshot {
        IndexSnapshot(symbols: symbols, references: references)
    }
}
