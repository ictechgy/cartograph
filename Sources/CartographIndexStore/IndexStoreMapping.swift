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
        // 제네릭 파라미터는 인덱스에 타입 별칭으로 남지만 따로 지울 수 있는 선언이
        // 아니다. 정점으로 두면 `struct Reactive<Base>` 의 `Base` 가 미사용으로
        // 보고된다.
        guard occurrence.symbol.subKind != .swiftGenericTypeParam else { return nil }

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

    /// 파라미터 선언 발생을 옮긴다. 선언이 아니거나 보고 가치가 없으면 nil.
    ///
    /// 파라미터는 `indexedSymbol` 이 걸러 내는 종류다 — 그래프 정점이 아니라
    /// 미사용 파라미터 질의 전용 입력이므로 별도의 통로를 둔다. 이름이 `_` 이면
    /// 쓰지 않겠다고 선언한 것이고, 접근자(`newValue` 같은)의 파라미터는 사용자가
    /// 이름을 바꿀 수 없는 컴파일러 계약이라 보고하지 않는다 — 부모가 접근자인
    /// 선언은 그래프 정점으로 이어지지 않으므로 어차피 분석 단계에서 걸러진다.
    public static func indexedParameter(from occurrence: SymbolOccurrence) -> IndexedParameter? {
        guard occurrence.roles.contains(.definition) || occurrence.roles.contains(.declaration) else {
            return nil
        }
        guard symbolKind(occurrence.symbol.kind, subKind: occurrence.symbol.subKind) == .parameter,
              !occurrence.roles.contains(.implicit),
              !occurrence.location.isSystem,
              occurrence.symbol.name != "_",
              let functionUSR = parentUSR(of: occurrence)
        else { return nil }

        // 사용 여부는 인덱스에 없다. 지역 심볼의 참조 발생이 기록되지 않기 때문에
        // 구문 보강(`SnapshotEnricher`)이 본문 스캔 결과로 `isReferenced` 를 채운다.
        return IndexedParameter(
            usr: occurrence.symbol.usr,
            name: occurrence.symbol.name,
            module: occurrence.location.moduleName,
            location: sourceLocation(occurrence.location),
            functionUSR: functionUSR
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

    /// 프로퍼티·변수를 대상으로 한 참조 발생의 접근 방향.
    ///
    /// 인덱스는 `self.x = v` 에 write, `_ = x` 에 read 역할을 단다. 방향 비트가
    /// 전혀 없는 참조도 있다 — 전수 조사에서 그 모양은 전부 멤버와이즈
    /// 이니셜라이저의 인자 라벨이었다(`S(x: v)` 의 `x:` 자리). 값이 그 자리로
    /// 들어가는 것은 쓰기이므로 쓰기로 센다. 반대로 동적 디스패치·주소 접근·
    /// 암시적 발생은 방향을 알 수 없어 불명으로 센다 — 하나라도 있으면
    /// "읽힌 적 없다" 는 말을 못 한다.
    ///
    /// 대상이 프로퍼티·변수가 아니거나 참조가 아니면 nil.
    public static func propertyAccess(of occurrence: SymbolOccurrence) -> PropertyAccessFacts? {
        guard occurrence.roles.contains(.reference) else { return nil }
        let kind = symbolKind(occurrence.symbol.kind, subKind: occurrence.symbol.subKind)
        guard kind == .property || kind == .variable else { return nil }
        // 암시적·동적·주소 접근은 방향 비트가 있어도 신뢰하지 않는다 — `&x` 처럼
        // 포인터를 넘기는 접근은 write 만 달고도 읽을 수 있다.
        if occurrence.roles.contains(.implicit) || occurrence.roles.contains(.dynamic)
            || occurrence.roles.contains(.addressOf) {
            return PropertyAccessFacts(hasAmbiguous: true)
        }
        let read = occurrence.roles.contains(.read)
        let write = occurrence.roles.contains(.write)
        if read || write { return PropertyAccessFacts(hasRead: read, hasWrite: write) }
        // `handler()` 처럼 호출되는 프로퍼티는 읽어야 호출할 수 있지만, 호출 역할만
        // 있고 방향이 없으면 추측하지 않는다.
        if occurrence.roles.contains(.call) { return PropertyAccessFacts(hasAmbiguous: true) }
        return PropertyAccessFacts(hasWrite: true)
    }

    /// 참조 USR 하나가 어느 모듈의 선언을 가리키는지에 대한 단서.
    public enum ModuleEvidence: Equatable {
        /// USR에 모듈 이름이 박혀 있어 바로 읽었다.
        case module(String)
        /// import 없이 참조할 수 있는 대상 — stdlib·컴파일러 생성 심볼이거나
        /// `import` 문 자체가 남기는 모듈 심볼 표식(`c:@M@…`)이다. 후자를
        /// 사용 근거로 세면 모든 import가 자기 자신 때문에 "사용됨"이 된다.
        case implicit
        /// USR에 모듈이 없어(`c:objc…` 같은 clang 심볼) 선언 조회가 필요하다.
        case deferred
    }

    /// 참조 대상 USR의 모듈 귀속 단서를 읽는다.
    ///
    /// Swift USR은 `s:<길이><모듈>` 로 모듈 이름을 담는다. `s:` 다음이 숫자가
    /// 아니면(`s:Si`, `s:s8SendableP` 등) 모듈 문맥이 없는 stdlib·컴파일러
    /// 생성 심볼이다. `c:@M@` 는 `import M` 문과 `M.name` 한정자가 남기는
    /// 모듈 심볼 참조로, 사용 증거로 세면 자기 자신의 표식을 사용으로 읽게 되어
    /// 무시한다 — `M.name` 의 실제 사용은 멤버의 참조 발생이 따로 귀속한다.
    public static func moduleEvidence(ofUSR usr: String) -> ModuleEvidence {
        guard usr.hasPrefix("s:") else {
            return usr.hasPrefix("c:@M@") ? .implicit : .deferred
        }
        let rest = usr.dropFirst(2)
        guard let first = rest.first, first.isNumber else { return .implicit }
        var length = 0
        var index = rest.startIndex
        while index < rest.endIndex, rest[index].isNumber {
            length = length * 10 + Int(String(rest[index]))!
            index = rest.index(after: index)
        }
        guard let end = rest.index(index, offsetBy: length, limitedBy: rest.endIndex) else {
            return .deferred
        }
        return .module(String(rest[index..<end]))
    }

    /// 발생에 붙은 관계를 "의존하는 쪽 → 의존되는 쪽" 방향의 참조로 정규화한다.
    ///
    /// libIndexStore 의 관계 역할은 언제나 "발생 심볼이 관련 심볼에 대해 갖는 관계"로
    /// 읽는다. 예컨대 `baseOf` 는 "발생 심볼이 관련 심볼의 기반"이라는 뜻이므로
    /// 간선은 관련 심볼(파생) → 발생 심볼(기반) 방향이 된다.
    public static func references(from occurrence: SymbolOccurrence, includeSelfReferences: Bool = false)
        -> [IndexedReference] {
        let location = sourceLocation(occurrence.location)
        let subject = occurrence.symbol
        var result: [IndexedReference] = []

        for relation in occurrence.relations {
            let other = relation.symbol.usr
            guard other != subject.usr || includeSelfReferences else { continue }
            let subjectKind = symbolKind(subject.kind, subKind: subject.subKind)
            let otherKind = symbolKind(relation.symbol.kind, subKind: relation.symbol.subKind)

            if relation.roles.contains(.baseOf) {
                let kind: EdgeKind = subject.kind == .protocol ? .conformance : .inheritance
                result.append(
                    IndexedReference(sourceUSR: other, targetUSR: subject.usr, kind: kind, location: location,
                        targetKind: subjectKind)
                )
            }
            if relation.roles.contains(.overrideOf) {
                result.append(
                    IndexedReference(
                        sourceUSR: subject.usr, targetUSR: other, kind: .overrides, location: location,
                        targetKind: otherKind
                    )
                )
            }
            if relation.roles.contains(.extendedBy) {
                result.append(IndexedReference(sourceUSR: other, targetUSR: subject.usr, kind: .extends,
                    location: location, targetKind: subjectKind))
            }
            // receivedBy는 수신 타입이다. 그것을 호출자로 읽으면 모든 인스턴스 호출에
            // 타입 → 메서드 간선이 붙어 사용·영향 범위가 부풀고 미사용 멤버도 살아난다.
            if relation.roles.contains(.calledBy) {
                result.append(
                    IndexedReference(sourceUSR: other, targetUSR: subject.usr, kind: .call, location: location,
                        targetKind: subjectKind)
                )
            } else if relation.roles.contains(.containedBy), occurrence.roles.contains(.reference) {
                result.append(
                    IndexedReference(
                        sourceUSR: other, targetUSR: subject.usr, kind: .reference, location: location,
                        targetKind: subjectKind
                    )
                )
            }
            if relation.roles.contains(.specializationOf) {
                result.append(
                    IndexedReference(
                        sourceUSR: subject.usr, targetUSR: other, kind: .reference, location: location,
                        targetKind: otherKind
                    )
                )
            }
        }

        if result.isEmpty, let topLevel = topLevelCodeReference(from: occurrence, location: location) {
            result.append(topLevel)
        }
        return result.map {
            IndexedReference(sourceUSR: $0.sourceUSR, targetUSR: $0.targetUSR,
                kind: $0.kind, location: $0.location, targetKind: $0.targetKind,
                origin: $0.origin == .unknown ? .compiler : $0.origin)
        }
    }

    /// `main.swift` 의 최상위 문장에서 나온 참조.
    ///
    /// `service.run()` 같은 최상위 문장은 감싸는 선언이 없어 관계가 비어 있다.
    /// 그대로 두면 간선이 하나도 생기지 않아, 실행 파일이 실제로 부르는 코드가
    /// 통째로 미사용으로 보고된다. 파일을 대표하는 가상 심볼에 붙여 시작점으로 삼는다.
    static func topLevelCodeReference(
        from occurrence: SymbolOccurrence,
        location: SourceLocation
    ) -> IndexedReference? {
        guard isTopLevelCodeFile(occurrence.location.path),
              occurrence.roles.contains(.reference) || occurrence.roles.contains(.call),
              !occurrence.roles.contains(.definition),
              !occurrence.roles.contains(.declaration)
        else { return nil }

        return IndexedReference(
            sourceUSR: topLevelCodeUSR(forFile: occurrence.location.path),
            targetUSR: occurrence.symbol.usr,
            kind: occurrence.roles.contains(.call) ? .call : .reference,
            location: location,
            targetKind: symbolKind(occurrence.symbol.kind, subKind: occurrence.symbol.subKind),
            origin: .inferred
        )
    }

    /// 최상위 코드를 대표하는 가상 심볼.
    public static func topLevelCodeSymbol(path: String, module: String) -> IndexedSymbol {
        IndexedSymbol(
            usr: topLevelCodeUSR(forFile: path),
            name: "top-level code",
            kind: .function,
            module: module,
            location: SourceLocation(path: path, line: 1, column: 1),
            accessibility: .privateLevel
        )
    }

    /// 파일마다 하나씩 두는 가상 심볼의 USR.
    public static func topLevelCodeUSR(forFile path: String) -> String {
        topLevelCodeUSRPrefix + path
    }

    public static let topLevelCodeUSRPrefix = "cartograph:top-level-code:"

    /// Swift 가 최상위 코드를 허용하는 유일한 파일 이름.
    static func isTopLevelCodeFile(_ path: String) -> Bool {
        path.hasSuffix("/main.swift") || path == "main.swift"
    }

    /// 선언을 감싸는 부모 심볼의 USR.
    static func parentUSR(of occurrence: SymbolOccurrence) -> String? {
        for relation in occurrence.relations
        where relation.roles.contains(.childOf) || relation.roles.contains(.accessorOf) {
            return relation.symbol.usr
        }
        return nil
    }

    /// 접근자 USR 을 그 프로퍼티의 USR 로 옮기는 표.
    ///
    /// 계산 프로퍼티의 게터 안에서 부른 것은 인덱스에 "게터가 부른다"로 남는다.
    /// 게터는 정점이 아니므로 그 간선은 통째로 버려지고, 게터에서만 부르는 함수가
    /// 미사용으로 보고된다. `willSet`/`didSet` 도 마찬가지다.
    public static func accessorOwners(in occurrences: [SymbolOccurrence]) -> [String: String] {
        var result: [String: String] = [:]
        for occurrence in occurrences where isAccessor(occurrence.symbol.subKind) {
            guard result[occurrence.symbol.usr] == nil, let owner = parentUSR(of: occurrence) else { continue }
            result[occurrence.symbol.usr] = owner
        }
        return result
    }

    /// 프로퍼티 래퍼가 만들어 낸 곁가지 심볼을 원래 프로퍼티로 옮기는 표.
    ///
    /// `@State var name` 은 `name` 외에 `$name`(투영값)과 `_name`·`__name`(저장소)을
    /// 함께 만든다. SwiftUI 코드는 `Child(text: $name)` 처럼 `$name` 만 쓰는 일이 흔한데,
    /// 인덱스에는 `$name` 으로만 참조가 남아 정작 `name` 은 아무도 안 쓰는 것으로 보인다.
    /// 실제로 살아 있는 SwiftUI 상태가 통째로 미사용으로 보고되는 가장 흔한 오탐이다.
    ///
    /// 곁가지는 컴파일러가 만든 것이라 `.implicit` 이 붙는다. 사용자가 직접 `_foo` 라고
    /// 이름 지은 프로퍼티는 implicit 이 아니므로 건드리지 않는다.
    public static func propertyWrapperFacets(in symbols: [IndexedSymbol]) -> [String: String] {
        var declaredByParentAndName: [String: String] = [:]
        for symbol in symbols where !symbol.attributes.contains(.implicit) {
            declaredByParentAndName[facetKey(parent: symbol.parentUSR, name: symbol.name)] = symbol.usr
        }

        var result: [String: String] = [:]
        for symbol in symbols where symbol.attributes.contains(.implicit) {
            guard let wrapped = wrappedName(ofFacet: symbol.name),
                  let owner = declaredByParentAndName[facetKey(parent: symbol.parentUSR, name: wrapped)],
                  owner != symbol.usr
            else { continue }
            result[symbol.usr] = owner
        }
        return result
    }

    /// 곁가지 이름에서 원래 프로퍼티 이름을 얻는다. 곁가지가 아니면 nil.
    ///
    /// 투영값(`$name`)만 본다. 저장소(`_name`, `__name`)는 컴파일러가 합성한
    /// 멤버와이즈 이니셜라이저가 늘 참조하므로, 그것까지 접으면 아무도 쓰지 않는
    /// 프로퍼티도 전부 살아 있는 것으로 보인다. 실제로 미탐을 만드는 것을 확인했다.
    /// `$name` 은 사용자가 직접 써야만 참조가 생기므로 사용 신호로 신뢰할 수 있다.
    static func wrappedName(ofFacet name: String) -> String? {
        guard name.hasPrefix("$"), name.count > 1 else { return nil }
        return String(name.dropFirst())
    }

    private static func facetKey(parent: String?, name: String) -> String {
        (parent ?? "") + "\u{0}" + name
    }

    /// 참조의 양 끝에 있는 합성 심볼을 그 선언으로 바꾼다.
    ///
    /// 선언 자신을 가리키게 된 간선은 버린다. 게터가 자기 프로퍼티를 읽거나
    /// 투영값이 자기 저장소를 읽는 것은 의존 관계가 아니다.
    public static func resolvingSynthesizedSymbols(
        _ references: [IndexedReference],
        owners: [String: String],
        includeSelfReferences: Bool = false
    ) -> [IndexedReference] {
        guard !owners.isEmpty else { return references }
        return references.compactMap { reference in
            let source = owners[reference.sourceUSR] ?? reference.sourceUSR
            let target = owners[reference.targetUSR] ?? reference.targetUSR
            guard source != target || includeSelfReferences else { return nil }
            return IndexedReference(
                sourceUSR: source, targetUSR: target, kind: reference.kind,
                location: reference.location, targetKind: reference.targetKind,
                origin: reference.origin
            )
        }
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
