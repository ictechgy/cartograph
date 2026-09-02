import CartographCore
import IndexStoreDB

/// IndexStoreDB 의 값 타입을 도구의 도메인 모델로 옮긴다.
///
/// 인덱스 스토어를 열지 않고도 검증할 수 있도록 전부 순수 함수로 둔다.
/// IndexStoreDB 의 `Symbol`/`SymbolOccurrence` 는 공개 이니셜라이저가 있어
/// 테스트에서 직접 만들어 넣을 수 있다.
public enum IndexStoreMapping {
    /// 인덱스 심볼 종류를 도메인 종류로 옮긴다.
    public static func symbolKind(_ kind: IndexSymbolKind, subKind: IndexSymbolSubKind) -> SymbolKind {
        switch subKind {
        case .swiftSubscript: return .subscriptDeclaration
        case .swiftAssociatedType: return .associatedType
        default: break
        }

        switch kind {
        case .module: return .module
        case .class: return .classType
        case .struct: return .structType
        case .enum: return .enumType
        case .protocol: return .protocolType
        case .extension: return .extensionDeclaration
        case .typealias: return .typeAlias
        case .function: return .function
        case .instanceMethod, .classMethod, .staticMethod, .conversionFunction: return .method
        case .constructor: return .initializer
        case .destructor: return .deinitializer
        case .instanceProperty, .classProperty, .staticProperty, .field: return .property
        case .variable: return .variable
        case .enumConstant: return .enumCase
        case .parameter: return .parameter
        case .macro: return .macro
        default: return .unknown
        }
    }

    /// 인덱스가 알려 주는 성질을 보존 규칙이 쓰는 표식으로 옮긴다.
    public static func attributes(properties: SymbolProperty, roles: SymbolRole) -> Set<SymbolAttribute> {
        var result: Set<SymbolAttribute> = []
        if properties.contains(.unitTest) { result.insert(.unitTest) }
        if properties.contains(.ibAnnotated) { result.insert(.interfaceBuilderAnnotated) }
        if properties.contains(.ibOutletCollection) { result.insert(.interfaceBuilderOutlet) }
        if properties.contains(.generic) { result.insert(.generic) }
        if roles.contains(.implicit) { result.insert(.implicit) }
        if roles.contains(.dynamic) { result.insert(.dynamicDispatch) }
        return result
    }

    public static func sourceLocation(_ location: SymbolLocation) -> SourceLocation {
        SourceLocation(path: location.path, line: location.line, column: location.utf8Column)
    }

    /// 선언 발생을 심볼로 옮긴다. 선언이 아니거나 다룰 필요가 없으면 nil.
    ///
    /// 접근자(getter/setter/willSet/didSet)와 지역 선언은 제외한다.
    /// 접근자는 프로퍼티와 1:1 로 붙어 다녀 따로 보고하면 잡음만 늘고,
    /// 지역 선언은 애초에 바깥에서 참조될 수 없다.
    public static func indexedSymbol(from occurrence: SymbolOccurrence) -> IndexedSymbol? {
        guard occurrence.roles.contains(.definition) || occurrence.roles.contains(.declaration) else {
            return nil
        }
        guard !isAccessor(occurrence.symbol.subKind) else { return nil }
        guard !occurrence.symbol.properties.contains(.local) else { return nil }

        let kind = symbolKind(occurrence.symbol.kind, subKind: occurrence.symbol.subKind)
        guard kind != .parameter else { return nil }

        return IndexedSymbol(
            usr: occurrence.symbol.usr,
            name: occurrence.symbol.name,
            kind: kind,
            module: occurrence.location.moduleName,
            location: sourceLocation(occurrence.location),
            parentUSR: parentUSR(of: occurrence),
            isExternal: occurrence.location.isSystem,
            accessibility: .internalLevel,
            attributes: attributes(properties: occurrence.symbol.properties, roles: occurrence.roles)
        )
    }

    /// 참조된 외부 심볼을 외부 정점으로 만든다.
    ///
    /// 위치는 참조가 나타난 자리다. 정의 위치는 인덱스에 없기 때문이며,
    /// 외부 정점은 `--include-external` 을 켰을 때만 그래프에 들어간다.
    public static func externalSymbol(from occurrence: SymbolOccurrence) -> IndexedSymbol? {
        guard occurrence.roles.contains(.reference) else { return nil }
        let kind = symbolKind(occurrence.symbol.kind, subKind: occurrence.symbol.subKind)
        guard kind != .parameter, kind != .unknown else { return nil }

        return IndexedSymbol(
            usr: occurrence.symbol.usr,
            name: occurrence.symbol.name,
            kind: kind,
            module: occurrence.location.moduleName,
            location: sourceLocation(occurrence.location),
            isExternal: true
        )
    }

    /// 발생에 붙은 관계를 "의존하는 쪽 → 의존되는 쪽" 방향의 참조로 정규화한다.
    ///
    /// libIndexStore 의 관계 역할은 언제나 "발생 심볼이 관련 심볼에 대해 갖는 관계"로
    /// 읽는다. 예컨대 `baseOf` 는 "발생 심볼이 관련 심볼의 기반"이라는 뜻이므로
    /// 간선은 관련 심볼(파생) → 발생 심볼(기반) 방향이 된다.
    public static func references(from occurrence: SymbolOccurrence) -> [IndexedReference] {
        let location = sourceLocation(occurrence.location)
        let subject = occurrence.symbol
        var result: [IndexedReference] = []

        for relation in occurrence.relations {
            let other = relation.symbol.usr
            guard other != subject.usr else { continue }

            if relation.roles.contains(.baseOf) {
                let kind: EdgeKind = subject.kind == .protocol ? .conformance : .inheritance
                result.append(
                    IndexedReference(sourceUSR: other, targetUSR: subject.usr, kind: kind, location: location)
                )
            }
            if relation.roles.contains(.overrideOf) {
                result.append(
                    IndexedReference(
                        sourceUSR: subject.usr, targetUSR: other, kind: .overrides, location: location
                    )
                )
            }
            if relation.roles.contains(.extendedBy) {
                result.append(
                    IndexedReference(sourceUSR: other, targetUSR: subject.usr, kind: .extends, location: location)
                )
            }
            if relation.roles.contains(.calledBy) || relation.roles.contains(.receivedBy) {
                result.append(
                    IndexedReference(sourceUSR: other, targetUSR: subject.usr, kind: .call, location: location)
                )
            } else if relation.roles.contains(.containedBy), occurrence.roles.contains(.reference) {
                result.append(
                    IndexedReference(
                        sourceUSR: other, targetUSR: subject.usr, kind: .reference, location: location
                    )
                )
            }
            if relation.roles.contains(.specializationOf) {
                result.append(
                    IndexedReference(
                        sourceUSR: subject.usr, targetUSR: other, kind: .reference, location: location
                    )
                )
            }
        }
        return result
    }

    /// 선언을 감싸는 부모 심볼의 USR.
    static func parentUSR(of occurrence: SymbolOccurrence) -> String? {
        for relation in occurrence.relations
        where relation.roles.contains(.childOf) || relation.roles.contains(.accessorOf) {
            return relation.symbol.usr
        }
        return nil
    }

    static func isAccessor(_ subKind: IndexSymbolSubKind) -> Bool {
        switch subKind {
        case .accessorGetter, .accessorSetter, .swiftAccessorWillSet, .swiftAccessorDidSet,
             .swiftAccessorAddressor, .swiftAccessorMutableAddressor:
            true
        default:
            false
        }
    }
}
