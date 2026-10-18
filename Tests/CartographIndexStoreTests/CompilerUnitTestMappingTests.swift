import CartographCore
@testable import CartographIndexStore
import Foundation
import IndexStoreDB
import Testing

@Suite("컴파일러 테스트 표식의 원시 수집")
struct CompilerUnitTestMappingTests {
    @Test("선언의 컴파일러 비트만 true와 false로 수집한다", arguments: [true, false])
    func capturesDeclarationBit(marked: Bool) throws {
        let value = try #require(IndexStoreMapping.indexedSymbol(from: occurrence(marked, roles: .definition)))
        #expect(value.compilerUnitTest == marked)
        #expect(value.attributes.contains(.unitTest) == marked)
    }

    @Test("참조만으로 만든 외부 심볼은 선언 관찰을 가장하지 않는다")
    func referenceOnlySymbolRemainsUnknown() throws {
        let value = try #require(IndexStoreMapping.externalSymbol(from: occurrence(true, roles: .reference)))
        #expect(value.isExternal)
        #expect(value.compilerUnitTest == nil)
    }

    @Test("선언과 정의 순서가 달라도 양성 관찰을 보존하고 정의 위치를 우선한다")
    func combinesDeclarationAndDefinitionEvidence() throws {
        for declarationMarked in [false, true] {
            for definitionMarked in [false, true] {
                let declaration = occurrence(declarationMarked, roles: .declaration, line: 1)
                let definition = occurrence(definitionMarked, roles: .definition, line: 9)
                for values in [[declaration, definition], [definition, declaration]] {
                    let snapshot = IndexStoreProvider.snapshot(from: values, includeExternalSymbols: false)
                    let value = try #require(snapshot.symbolsByUSR()["probe"])
                    #expect(value.compilerUnitTest == (declarationMarked || definitionMarked))
                    #expect(value.location.line == 9)
                    #expect(value.attributes.contains(.unitTest) == (declarationMarked || definitionMarked))
                }
            }
        }
    }

    private func occurrence(_ marked: Bool, roles: SymbolRole, line: Int = 1) -> SymbolOccurrence {
        SymbolOccurrence(
            symbol: Symbol(usr: "probe", name: "testProbe()", kind: .instanceMethod, subKind: .none,
                properties: marked ? [.unitTest] : [], language: .swift),
            location: SymbolLocation(path: "/p/Tests.swift", timestamp: Date(timeIntervalSince1970: 0),
                moduleName: "Tests", isSystem: false, line: line, utf8Column: 1),
            roles: roles, symbolProvider: .swift, relations: []
        )
    }
}
