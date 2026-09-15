import CartographCore
@testable import CartographIndexStore
import Foundation
import IndexStoreDB
import Testing

@Suite("컴파일러 호출자와 별칭 준수 근거")
struct CompilerRelationEvidenceTests {
    @Test("수신 타입은 메서드를 호출한 선언이 아니다")
    func receiverIsNotACaller() {
        let occurrence = makeOccurrence("work", kind: .instanceMethod, roles: [.reference, .call, .dynamic],
            relations: [
                SymbolRelation(symbol: symbol("caller", kind: .instanceMethod), roles: [.calledBy, .containedBy]),
                SymbolRelation(symbol: symbol("Receiver", kind: .class), roles: .receivedBy),
            ])
        let result = IndexStoreMapping.references(from: occurrence)
        #expect(result.map(\.sourceUSR) == ["caller"])
        #expect(result.map(\.kind) == [.call])
        #expect(result.map(\.origin) == [.compiler])
    }

    @Test("수신자 근거만 있으면 호출자를 만들어내지 않는다")
    func receiverOnlyDoesNotInventOwnership() {
        let occurrence = makeOccurrence("work", kind: .instanceMethod, roles: [.reference, .call],
            relations: [SymbolRelation(symbol: symbol("Receiver", kind: .class), roles: .receivedBy)])
        #expect(IndexStoreMapping.references(from: occurrence).isEmpty)
    }

    @Test("최상위 호출의 수신자와 실행 진입점을 혼동하지 않는다")
    func topLevelCallKeepsItsEntryPoint() {
        let occurrence = makeOccurrence("work", kind: .instanceMethod, roles: [.reference, .call],
            path: "/p/main.swift",
            relations: [SymbolRelation(symbol: symbol("Receiver", kind: .class), roles: .receivedBy)])
        let result = IndexStoreMapping.references(from: occurrence)
        #expect(result.map(\.sourceUSR) == [IndexStoreMapping.topLevelCodeUSR(forFile: "/p/main.swift")])
        #expect(result.map(\.origin) == [.inferred])
    }

    @Test("같은 위치의 암시적 baseOf가 명시적 별칭 참조의 소유자를 증명한다")
    func exactImplicitBaseBindsConformanceAlias() {
        let occurrences = aliasOccurrences()
        for values in [occurrences, occurrences.reversed().map { $0 }] {
            let snapshot = IndexStoreProvider.snapshot(from: values, includeExternalSymbols: false)
            let aliases = snapshot.references.filter { $0.targetUSR == "Alias" }
            #expect(aliases.count == 1)
            #expect(aliases.first?.sourceUSR == "Owner")
            #expect(aliases.first?.kind == .reference)
            #expect(aliases.first?.origin == .inferred)
        }
    }

    @Test("열·모듈·암시적 역할이 다르면 같은 줄의 타입으로 별칭을 추측하지 않는다")
    func rejectsInexactConformanceEvidence() {
        for occurrences in [
            aliasOccurrences(baseColumn: 48), aliasOccurrences(baseModule: "Other"),
            aliasOccurrences(baseImplicit: false), aliasOccurrences(aliasImplicit: true),
            aliasOccurrences(owners: []), aliasOccurrences(owners: ["Owner", "Another"]),
        ] {
            let snapshot = IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: false)
            #expect(snapshot.references.allSatisfy { $0.targetUSR != "Alias" })
        }
    }

    private func aliasOccurrences(
        baseColumn: Int = 47, baseModule: String = "App", baseImplicit: Bool = true,
        aliasImplicit: Bool = false, owners: [String] = ["Owner"]
    ) -> [SymbolOccurrence] {
        [
            makeOccurrence("Alias", kind: .typealias, roles: .definition, line: 77, column: 11),
            makeOccurrence("Owner", kind: .struct, roles: .definition, line: 85, column: 15),
            makeOccurrence("Another", kind: .struct, roles: .definition, line: 84, column: 15),
            makeOccurrence("Alias", kind: .typealias, roles: aliasImplicit ? [.reference, .implicit] : .reference,
                line: 85, column: 47),
            makeOccurrence("SDKProtocol", kind: .protocol,
                roles: baseImplicit ? [.reference, .implicit, .baseOf] : [.reference, .baseOf],
                line: 85, column: baseColumn, module: baseModule,
                relations: owners.map { SymbolRelation(symbol: symbol($0, kind: .struct), roles: .baseOf) }),
        ]
    }

    private func symbol(_ usr: String, kind: IndexSymbolKind) -> Symbol {
        Symbol(usr: usr, name: usr, kind: kind, subKind: .none, properties: [], language: .swift)
    }

    private func makeOccurrence(
        _ usr: String, kind: IndexSymbolKind, roles: SymbolRole,
        path: String = "/p/A.swift", line: Int = 10, column: Int = 5, module: String = "App",
        relations: [SymbolRelation] = []
    ) -> SymbolOccurrence {
        SymbolOccurrence(symbol: symbol(usr, kind: kind),
            location: SymbolLocation(path: path, timestamp: Date(timeIntervalSince1970: 0),
                moduleName: module, isSystem: false, line: line, utf8Column: column),
            roles: roles, symbolProvider: .swift, relations: relations)
    }
}
