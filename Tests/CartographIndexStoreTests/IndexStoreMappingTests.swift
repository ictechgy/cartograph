import CartographCore
@testable import CartographIndexStore
import Foundation
import IndexStoreDB
import Testing

@Suite("인덱스 심볼 변환")
struct IndexStoreMappingTests {
    private func symbol(
        _ usr: String,
        name: String? = nil,
        kind: IndexSymbolKind = .struct,
        subKind: IndexSymbolSubKind = .none,
        properties: SymbolProperty = SymbolProperty()
    ) -> Symbol {
        Symbol(usr: usr, name: name ?? usr, kind: kind, subKind: subKind, properties: properties, language: .swift)
    }

    private func location(
        _ path: String = "/p/A.swift",
        module: String = "App",
        line: Int = 3,
        column: Int = 5,
        isSystem: Bool = false
    ) -> SymbolLocation {
        SymbolLocation(
            path: path, timestamp: Date(timeIntervalSince1970: 0), moduleName: module,
            isSystem: isSystem, line: line, utf8Column: column
        )
    }

    private func occurrence(
        _ symbol: Symbol,
        roles: SymbolRole,
        location: SymbolLocation? = nil,
        relations: [SymbolRelation] = []
    ) -> SymbolOccurrence {
        SymbolOccurrence(
            symbol: symbol,
            location: location ?? self.location(),
            roles: roles,
            symbolProvider: .swift,
            relations: relations
        )
    }

    @Test("심볼 종류를 도메인 종류로 옮긴다")
    func mapsSymbolKinds() {
        #expect(IndexStoreMapping.symbolKind(.class, subKind: .none) == .classType)
        #expect(IndexStoreMapping.symbolKind(.struct, subKind: .none) == .structType)
        #expect(IndexStoreMapping.symbolKind(.enum, subKind: .none) == .enumType)
        #expect(IndexStoreMapping.symbolKind(.protocol, subKind: .none) == .protocolType)
        #expect(IndexStoreMapping.symbolKind(.extension, subKind: .none) == .extensionDeclaration)
        #expect(IndexStoreMapping.symbolKind(.instanceMethod, subKind: .none) == .method)
        #expect(IndexStoreMapping.symbolKind(.staticMethod, subKind: .none) == .method)
        #expect(IndexStoreMapping.symbolKind(.constructor, subKind: .none) == .initializer)
        #expect(IndexStoreMapping.symbolKind(.destructor, subKind: .none) == .deinitializer)
        #expect(IndexStoreMapping.symbolKind(.instanceProperty, subKind: .none) == .property)
        #expect(IndexStoreMapping.symbolKind(.enumConstant, subKind: .none) == .enumCase)
        #expect(IndexStoreMapping.symbolKind(.macro, subKind: .none) == .macro)
        #expect(IndexStoreMapping.symbolKind(.union, subKind: .none) == .unknown)
    }

    @Test("하위 종류가 상위 종류보다 우선한다")
    func subKindWins() {
        #expect(IndexStoreMapping.symbolKind(.instanceMethod, subKind: .swiftSubscript) == .subscriptDeclaration)
        #expect(IndexStoreMapping.symbolKind(.typealias, subKind: .swiftAssociatedType) == .associatedType)
    }

    @Test("인덱스 성질을 보존 표식으로 옮긴다")
    func mapsProperties() {
        let attributes = IndexStoreMapping.attributes(
            properties: [.unitTest, .ibAnnotated, .generic],
            roles: [.definition, .implicit, .dynamic]
        )
        #expect(attributes.contains(.unitTest))
        #expect(attributes.contains(.interfaceBuilderAnnotated))
        #expect(attributes.contains(.generic))
        #expect(attributes.contains(.implicit))
        #expect(attributes.contains(.dynamicDispatch))
    }

    @Test("정의 발생만 심볼이 된다")
    func onlyDefinitionsBecomeSymbols() {
        #expect(IndexStoreMapping.indexedSymbol(from: occurrence(symbol("A"), roles: .definition)) != nil)
        #expect(IndexStoreMapping.indexedSymbol(from: occurrence(symbol("A"), roles: .declaration)) != nil)
        #expect(IndexStoreMapping.indexedSymbol(from: occurrence(symbol("A"), roles: .reference)) == nil)
    }

    @Test("접근자와 지역 선언, 파라미터는 제외한다")
    func skipsNoiseDeclarations() {
        let getter = symbol("g", kind: .instanceMethod, subKind: .accessorGetter)
        #expect(IndexStoreMapping.indexedSymbol(from: occurrence(getter, roles: .definition)) == nil)

        let localVariable = symbol("l", kind: .variable, properties: [.local])
        #expect(IndexStoreMapping.indexedSymbol(from: occurrence(localVariable, roles: .definition)) == nil)

        let parameter = symbol("p", kind: .parameter)
        #expect(IndexStoreMapping.indexedSymbol(from: occurrence(parameter, roles: .definition)) == nil)
    }

    @Test("위치와 모듈, 시스템 여부를 옮긴다")
    func mapsLocation() throws {
        let mapped = try #require(
            IndexStoreMapping.indexedSymbol(
                from: occurrence(
                    symbol("A"),
                    roles: .definition,
                    location: location("/sdk/UIKit.swift", module: "UIKit", line: 7, column: 2, isSystem: true)
                )
            )
        )
        #expect(mapped.location == SourceLocation(path: "/sdk/UIKit.swift", line: 7, column: 2))
        #expect(mapped.module == "UIKit")
        #expect(mapped.isExternal)
    }

    @Test("childOf 관계에서 부모 USR 을 읽는다")
    func readsParentFromChildOf() throws {
        let mapped = try #require(
            IndexStoreMapping.indexedSymbol(
                from: occurrence(
                    symbol("Type.member", kind: .instanceMethod),
                    roles: .definition,
                    relations: [SymbolRelation(symbol: symbol("Type"), roles: .childOf)]
                )
            )
        )
        #expect(mapped.parentUSR == "Type")
    }

    @Test("baseOf 는 파생 → 기반 방향의 상속 간선이 된다")
    func baseOfBecomesInheritance() {
        // libIndexStore 의 관계 역할은 "발생 심볼이 관련 심볼에 대해 갖는 관계"다.
        // baseOf 는 "발생 심볼이 관련 심볼의 기반"이므로 방향이 뒤집힌다.
        let references = IndexStoreMapping.references(
            from: occurrence(
                symbol("Base", kind: .class),
                roles: .reference,
                relations: [SymbolRelation(symbol: symbol("Derived", kind: .class), roles: .baseOf)]
            )
        )
        #expect(references.count == 1)
        #expect(references[0].sourceUSR == "Derived")
        #expect(references[0].targetUSR == "Base")
        #expect(references[0].kind == .inheritance)
    }

    @Test("프로토콜이 기반이면 준수 간선이 된다")
    func baseOfProtocolBecomesConformance() {
        let references = IndexStoreMapping.references(
            from: occurrence(
                symbol("P", kind: .protocol),
                roles: .reference,
                relations: [SymbolRelation(symbol: symbol("S", kind: .struct), roles: .baseOf)]
            )
        )
        #expect(references[0].kind == .conformance)
        #expect(references[0].sourceUSR == "S")
    }

    @Test("overrideOf 는 오버라이드 → 기반 방향이다")
    func overrideOfDirection() {
        let references = IndexStoreMapping.references(
            from: occurrence(
                symbol("Derived.run", kind: .instanceMethod),
                roles: .definition,
                relations: [SymbolRelation(symbol: symbol("Base.run"), roles: .overrideOf)]
            )
        )
        #expect(references[0].sourceUSR == "Derived.run")
        #expect(references[0].targetUSR == "Base.run")
        #expect(references[0].kind == .overrides)
    }

    @Test("calledBy 는 호출자 → 피호출자 간선이 된다")
    func calledByDirection() {
        let references = IndexStoreMapping.references(
            from: occurrence(
                symbol("callee", kind: .instanceMethod),
                roles: [.reference, .call],
                relations: [SymbolRelation(symbol: symbol("caller"), roles: [.calledBy, .containedBy])]
            )
        )
        // 호출 관계가 있으면 포함 관계로 중복해서 만들지 않는다.
        #expect(references.count == 1)
        #expect(references[0].kind == .call)
        #expect(references[0].sourceUSR == "caller")
    }

    @Test("containedBy 는 참조 발생일 때만 참조 간선이 된다")
    func containedByOnlyForReferences() {
        let asReference = IndexStoreMapping.references(
            from: occurrence(
                symbol("Type"),
                roles: .reference,
                relations: [SymbolRelation(symbol: symbol("holder"), roles: .containedBy)]
            )
        )
        #expect(asReference.map(\.kind) == [.reference])

        let asDefinition = IndexStoreMapping.references(
            from: occurrence(
                symbol("Type"),
                roles: .definition,
                relations: [SymbolRelation(symbol: symbol("holder"), roles: .containedBy)]
            )
        )
        #expect(asDefinition.isEmpty)
    }

    @Test("extendedBy 는 익스텐션 → 확장 대상 간선이 된다")
    func extendedByDirection() {
        let references = IndexStoreMapping.references(
            from: occurrence(
                symbol("User", kind: .struct),
                roles: .reference,
                relations: [SymbolRelation(symbol: symbol("ext", kind: .extension), roles: .extendedBy)]
            )
        )
        #expect(references[0].sourceUSR == "ext")
        #expect(references[0].targetUSR == "User")
        #expect(references[0].kind == .extends)
    }

    @Test("자기 자신을 향한 관계는 버린다")
    func selfRelationsAreDropped() {
        let references = IndexStoreMapping.references(
            from: occurrence(
                symbol("A"),
                roles: .reference,
                relations: [SymbolRelation(symbol: symbol("A"), roles: .calledBy)]
            )
        )
        #expect(references.isEmpty)
    }

    @Test("발생 목록을 스냅샷으로 접는다")
    func foldsOccurrencesIntoSnapshot() {
        let occurrences = [
            occurrence(symbol("Type", kind: .struct), roles: .definition),
            occurrence(
                symbol("Type.method", kind: .instanceMethod),
                roles: .definition,
                relations: [SymbolRelation(symbol: symbol("Type"), roles: .childOf)]
            ),
            occurrence(
                symbol("Other", kind: .struct),
                roles: .reference,
                relations: [SymbolRelation(symbol: symbol("Type.method"), roles: .containedBy)]
            ),
        ]
        let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
        #expect(snapshot.symbols.map(\.usr) == ["Type", "Type.method"])
        #expect(snapshot.references.count == 1)
        #expect(snapshot.references[0].sourceUSR == "Type.method")
    }

    @Test("외부 심볼 수집을 켜면 참조 대상도 정점 후보가 된다")
    func collectsExternalSymbolsWhenRequested() {
        let occurrences = [
            occurrence(symbol("Mine", kind: .struct), roles: .definition),
            occurrence(
                symbol("c:objc(cs)UIView", name: "UIView", kind: .class),
                roles: .reference,
                location: location("/sdk/UIKit.h", module: "UIKit", isSystem: true)
            ),
        ]
        let without = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
        #expect(without.symbols.map(\.usr) == ["Mine"])

        let with = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: true)
        #expect(with.symbols.count == 2)
        #expect(with.symbols.contains { $0.name == "UIView" && $0.isExternal })
    }

    @Test("부모 정보가 있는 발생을 대표로 삼는다")
    func prefersOccurrenceWithParent() throws {
        let occurrences = [
            occurrence(symbol("m", kind: .instanceMethod), roles: .definition),
            occurrence(
                symbol("m", kind: .instanceMethod),
                roles: .definition,
                relations: [SymbolRelation(symbol: symbol("Type"), roles: .childOf)]
            ),
        ]
        let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
        #expect(try #require(snapshot.symbols.first).parentUSR == "Type")
    }

    @Test("제네릭 파라미터는 정점으로 만들지 않는다")
    func skipsGenericTypeParameters() {
        // 인덱스에는 타입 별칭으로 남지만 따로 지울 수 있는 선언이 아니다.
        let occurrence = occurrence(
            symbol("T", kind: .typealias, subKind: .swiftGenericTypeParam),
            roles: .definition
        )
        #expect(IndexStoreMapping.indexedSymbol(from: occurrence) == nil)
    }

    @Test("접근자에서 나온 호출을 그 프로퍼티의 것으로 옮긴다")
    func resolvesAccessorEdgesToTheirProperty() {
        // 계산 프로퍼티의 게터는 정점이 아니다. 그대로 두면 게터에서만 부르는
        // 함수가 미사용으로 보고된다.
        let getter = symbol("getter", kind: .instanceMethod, subKind: .accessorGetter)
        let occurrences = [
            occurrence(
                getter,
                roles: .definition,
                relations: [SymbolRelation(symbol: symbol("property"), roles: .accessorOf)]
            ),
            occurrence(
                symbol("helper", kind: .function),
                roles: [.reference, .call],
                relations: [SymbolRelation(symbol: getter, roles: .calledBy)]
            ),
        ]
        let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
        #expect(snapshot.references.contains { $0.sourceUSR == "property" && $0.targetUSR == "helper" })
        #expect(!snapshot.references.contains { $0.sourceUSR == "getter" })
    }

    @Test("프로퍼티가 자기 자신을 가리키게 된 간선은 버린다")
    func dropsSelfEdgesCreatedByAccessorResolution() {
        let getter = symbol("getter", kind: .instanceMethod, subKind: .accessorGetter)
        let occurrences = [
            occurrence(
                getter,
                roles: .definition,
                relations: [SymbolRelation(symbol: symbol("property"), roles: .accessorOf)]
            ),
            occurrence(
                symbol("property"),
                roles: [.reference],
                relations: [SymbolRelation(symbol: getter, roles: .containedBy)]
            ),
        ]
        let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
        #expect(snapshot.references.isEmpty)
    }

    @Test("투영값으로만 쓰인 프로퍼티도 쓰인 것으로 본다")
    func projectedValueUsageReachesTheWrappedProperty() {
        // SwiftUI 는 `Child(text: $name)` 처럼 `$name` 만 쓰는 일이 흔하다. 인덱스에는
        // `$name` 으로만 참조가 남아, 실제로 살아 있는 상태가 미사용으로 보고됐다.
        let symbols = [
            IndexedSymbol(usr: "name", name: "name", kind: .property, module: "M",
                          location: SourceLocation(path: "/p/A.swift", line: 1, column: 1),
                          parentUSR: "View"),
            IndexedSymbol(usr: "$name", name: "$name", kind: .property, module: "M",
                          location: SourceLocation(path: "/p/A.swift", line: 1, column: 1),
                          parentUSR: "View", attributes: [.implicit]),
        ]
        let facets = IndexStoreMapping.propertyWrapperFacets(in: symbols)
        #expect(facets["$name"] == "name")

        let rewritten = IndexStoreMapping.resolvingSynthesizedSymbols(
            [IndexedReference(sourceUSR: "body", targetUSR: "$name", kind: .call,
                              location: SourceLocation(path: "/p/A.swift", line: 5, column: 1))],
            owners: facets
        )
        #expect(rewritten.first?.targetUSR == "name")
    }

    @Test("저장소 곁가지는 접지 않는다")
    func doesNotFoldBackingStorage() {
        // `_name` 은 컴파일러가 합성한 멤버와이즈 이니셜라이저가 늘 참조한다. 접으면
        // 아무도 쓰지 않는 프로퍼티까지 살아 있는 것으로 보여 미탐이 된다.
        let symbols = [
            IndexedSymbol(usr: "name", name: "name", kind: .property, module: "M",
                          location: SourceLocation(path: "/p/A.swift", line: 1, column: 1),
                          parentUSR: "View"),
            IndexedSymbol(usr: "_name", name: "_name", kind: .property, module: "M",
                          location: SourceLocation(path: "/p/A.swift", line: 1, column: 1),
                          parentUSR: "View", attributes: [.implicit]),
        ]
        #expect(IndexStoreMapping.propertyWrapperFacets(in: symbols).isEmpty)
    }

    @Test("사용자가 직접 이름 붙인 프로퍼티는 건드리지 않는다")
    func leavesExplicitlyNamedPropertiesAlone() {
        let symbols = [
            IndexedSymbol(usr: "name", name: "name", kind: .property, module: "M",
                          location: SourceLocation(path: "/p/A.swift", line: 1, column: 1),
                          parentUSR: "T"),
            // implicit 이 아니므로 곁가지가 아니다.
            IndexedSymbol(usr: "dollar", name: "$name", kind: .property, module: "M",
                          location: SourceLocation(path: "/p/A.swift", line: 2, column: 1),
                          parentUSR: "T"),
        ]
        #expect(IndexStoreMapping.propertyWrapperFacets(in: symbols).isEmpty)
    }

    @Test("main.swift 의 최상위 문장은 가상 심볼에서 나온 것으로 본다")
    func attributesTopLevelStatementsToASyntheticSymbol() throws {
        // 최상위 문장은 감싸는 선언이 없어 관계가 비어 있다. 그대로 두면
        // 실행 파일이 실제로 부르는 코드가 통째로 미사용으로 보고된다.
        let occurrences = [
            occurrence(
                symbol("run", kind: .instanceMethod),
                roles: [.reference, .call],
                location: location("/p/main.swift")
            )
        ]
        let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
        let topLevelUSR = IndexStoreMapping.topLevelCodeUSR(forFile: "/p/main.swift")
        #expect(snapshot.symbols.contains { $0.usr == topLevelUSR && $0.name == "top-level code" })
        let reference = try #require(snapshot.references.first)
        #expect(reference.sourceUSR == topLevelUSR)
        #expect(reference.targetUSR == "run")
        #expect(reference.kind == .call)
    }

    @Test("다른 파일의 관계 없는 참조는 가상 심볼을 만들지 않는다")
    func doesNotSynthesizeTopLevelCodeOutsideMainSwift() {
        let occurrences = [
            occurrence(
                symbol("run", kind: .instanceMethod),
                roles: [.reference, .call],
                location: location("/p/Other.swift")
            )
        ]
        let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
        #expect(snapshot.symbols.isEmpty)
        #expect(snapshot.references.isEmpty)
    }

    @Test("정의의 위치를 선언의 위치보다 우선한다")
    func prefersTheDefinitionLocation() throws {
        // 선언만 있는 발생의 줄 번호를 쓰면 구문 정보를 붙일 때 엉뚱한 자리를 짚는다.
        let occurrences = [
            occurrence(symbol("m", kind: .instanceMethod), roles: .declaration, location: location(line: 10)),
            occurrence(symbol("m", kind: .instanceMethod), roles: .definition, location: location(line: 20)),
        ]
        let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
        #expect(try #require(snapshot.symbols.first).location.line == 20)
    }

    @Test("정의를 대표로 삼아도 부모 정보는 잃지 않는다")
    func keepsTheParentWhenUpgradingToTheDefinition() throws {
        let occurrences = [
            occurrence(
                symbol("m", kind: .instanceMethod),
                roles: .declaration,
                location: location(line: 10),
                relations: [SymbolRelation(symbol: symbol("Type"), roles: .childOf)]
            ),
            occurrence(symbol("m", kind: .instanceMethod), roles: .definition, location: location(line: 20)),
        ]
        let symbol = try #require(IndexStoreProvider.snapshot(
            from: occurrences, includeExternalSymbols: false
        ).symbols.first)
        #expect(symbol.location.line == 20)
        #expect(symbol.parentUSR == "Type")
    }

    @Test("경로 해시는 실행마다 같은 값을 준다")
    func stableHashIsDeterministic() {
        // Swift 의 Hasher 는 실행마다 시드가 달라 파일 이름으로 쓸 수 없다.
        #expect(IndexStoreProvider.stableHash("/a/b") == IndexStoreProvider.stableHash("/a/b"))
        #expect(IndexStoreProvider.stableHash("/a/b") != IndexStoreProvider.stableHash("/a/c"))
        #expect(
            IndexStoreProvider
                .defaultDatabasePath(forStore: "/a/b", libraryPath: "/lib.dylib", libraryModificationDate: nil)
                .contains("cartograph-index-db")
        )
    }
}

@Suite("인덱스 캐시 경로")
struct IndexDatabasePathTests {
    @Test("같은 입력이면 같은 캐시 경로를 준다")
    func stableForSameInput() {
        let first = IndexStoreProvider.defaultDatabasePath(
            forStore: "/store", libraryPath: "/lib.dylib",
            libraryModificationDate: Date(timeIntervalSince1970: 100)
        )
        let second = IndexStoreProvider.defaultDatabasePath(
            forStore: "/store", libraryPath: "/lib.dylib",
            libraryModificationDate: Date(timeIntervalSince1970: 100)
        )
        #expect(first == second)
    }

    @Test("툴체인이 바뀌면 캐시도 갈린다")
    func toolchainChangeInvalidatesCache() {
        // 인덱스 포맷은 하위 호환만 보장된다. 툴체인이 바뀐 뒤 예전 캐시를 그대로
        // 열면 조용히 잘못된 결과가 나온다.
        let base = IndexStoreProvider.defaultDatabasePath(
            forStore: "/store", libraryPath: "/Xcode26/lib.dylib",
            libraryModificationDate: Date(timeIntervalSince1970: 100)
        )
        let otherPath = IndexStoreProvider.defaultDatabasePath(
            forStore: "/store", libraryPath: "/Xcode27/lib.dylib",
            libraryModificationDate: Date(timeIntervalSince1970: 100)
        )
        // 같은 경로가 제자리에서 업데이트되는 경우까지 잡으려면 경로만으로는 부족하다.
        let updatedInPlace = IndexStoreProvider.defaultDatabasePath(
            forStore: "/store", libraryPath: "/Xcode26/lib.dylib",
            libraryModificationDate: Date(timeIntervalSince1970: 900)
        )
        #expect(base != otherPath)
        #expect(base != updatedInPlace)
    }

    @Test("인덱스 스토어가 다르면 캐시도 다르다")
    func differentStoresUseDifferentCaches() {
        #expect(
            IndexStoreProvider
                .defaultDatabasePath(forStore: "/a", libraryPath: "/lib.dylib", libraryModificationDate: nil)
                != IndexStoreProvider
                .defaultDatabasePath(forStore: "/b", libraryPath: "/lib.dylib", libraryModificationDate: nil)
        )
    }
}

@Suite("관계 없는 참조의 귀속")
struct UnattributedReferenceTests {
    private func symbol(_ usr: String, kind: SymbolKind, line: Int) -> IndexedSymbol {
        IndexedSymbol(
            usr: usr,
            name: usr,
            kind: kind,
            module: "App",
            location: CartographCore.SourceLocation(path: "/p/A.swift", line: line, column: 1)
        )
    }

    private func at(_ line: Int, _ column: Int) -> CartographCore.SourceLocation {
        CartographCore.SourceLocation(path: "/p/A.swift", line: line, column: column)
    }

    @Test("열거형 케이스의 연관 값 타입이 그 케이스의 의존성이 된다")
    func enumCasePayloadGetsAnEdge() {
        // 인덱서는 이 자리의 참조를 ref 로 남기면서 어떤 관계도 달지 않는다. 관계가
        // 있을 때만 간선을 만들면 페이로드 타입은 아무도 쓰지 않는 것처럼 보이고,
        // 실제로는 지우면 컴파일이 깨진다. 오늘은 합성 init 이 우연히 살리고 있다.
        let references = IndexStoreProvider.enclosingReferences(
            for: [(usr: "s:Payload", location: at(6, 16))],
            definitionSites: ["/p/A.swift": [
                (usr: "s:Failure", location: at(5, 6)),
                (usr: "s:broke", location: at(6, 10)),
            ]],
            symbols: [
                "s:Failure": symbol("s:Failure", kind: .enumType, line: 5),
                "s:broke": symbol("s:broke", kind: .enumCase, line: 6),
            ]
        )
        #expect(references.map(\.sourceUSR) == ["s:broke"])
        #expect(references.map(\.targetUSR) == ["s:Payload"])
    }

    @Test("타입 별칭의 우변도 같은 방식으로 붙는다")
    func typeAliasRightHandSideGetsAnEdge() {
        let references = IndexStoreProvider.enclosingReferences(
            for: [(usr: "s:Aliased", location: at(9, 22))],
            definitionSites: ["/p/A.swift": [(usr: "s:Shortcut", location: at(9, 11))]],
            symbols: ["s:Shortcut": symbol("s:Shortcut", kind: .typeAlias, line: 9)]
        )
        #expect(references.map(\.sourceUSR) == ["s:Shortcut"])
    }

    @Test("인덱서가 관계를 붙여 주는 자리에서는 위치로 추측하지 않는다")
    func otherDeclarationKindsAreLeftAlone() {
        // 프로퍼티나 메서드 안의 참조에는 인덱서가 containedBy 를 단다. 거기서 관계 없는
        // 참조가 나타났다면 매크로가 펼친 코드일 가능성이 높고, 그 위치는 사용자가 쓴
        // 자리가 아니라 속성 줄이다. 넓게 잡으면 앞 선언에 붙어 없는 의존성을 만든다.
        // 실제로 `@Observable` 이 그 모양으로 거짓 순환 두 건을 만들었다.
        let references = IndexStoreProvider.enclosingReferences(
            for: [(usr: "s:Other", location: at(50, 2))],
            definitionSites: ["/p/A.swift": [(usr: "s:id", location: at(42, 9))]],
            symbols: ["s:id": symbol("s:id", kind: .property, line: 42)]
        )
        #expect(references.isEmpty)
    }

    @Test("같은 위치의 정의는 소유자로 뽑지 않는다")
    func definitionsAtTheSamePositionAreSkipped() {
        // 이름 없는 파라미터는 자기 타입과 같은 자리에 기록된다. 그것을 소유자로 뽑으면
        // 파라미터는 그래프의 정점이 아니라 간선이 통째로 사라진다.
        let references = IndexStoreProvider.enclosingReferences(
            for: [(usr: "s:Payload", location: at(6, 16))],
            definitionSites: ["/p/A.swift": [
                (usr: "s:broke", location: at(6, 10)),
                (usr: "s:param", location: at(6, 16)),
            ]],
            symbols: [
                "s:broke": symbol("s:broke", kind: .enumCase, line: 6),
                "s:param": symbol("s:param", kind: .parameter, line: 6),
            ]
        )
        #expect(references.map(\.sourceUSR) == ["s:broke"])
    }

    @Test("앞에 정의가 없으면 아무 데도 붙이지 않는다")
    func referencesBeforeAnyDefinitionAreDropped() {
        let references = IndexStoreProvider.enclosingReferences(
            for: [(usr: "s:Imported", location: at(1, 8))],
            definitionSites: ["/p/A.swift": [(usr: "s:Later", location: at(5, 1))]],
            symbols: ["s:Later": symbol("s:Later", kind: .enumCase, line: 5)]
        )
        #expect(references.isEmpty)
    }
}
