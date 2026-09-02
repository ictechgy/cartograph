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
