import CartographCore
@testable import CartographSyntax
import Testing

@Suite("지역 함수 보강 진단")
struct LocalFunctionDiagnosticsTests {
    private let path = "/p/Local.swift"

    @Test("신선하지 않은 소스의 모든 지역 함수에 원인과 조치를 붙인다")
    func reportsStaleSource() {
        let local = local(name: "local", line: 3)
        let scope = scope(functions: [local])
        let owner = owner()
        let result = LocalFunctionBinder.enrichWithDiagnostics(
            IndexSnapshot(symbols: [owner]),
            scopes: [scope],
            freshPaths: [],
            edgeKinds: []
        )

        #expect(result.snapshot == IndexSnapshot(symbols: [owner]))
        #expect(result.diagnostics.map(\.reason) == [.sourceNotFresh])
        #expect(result.diagnostics.first?.ownerUSR == owner.usr)
        #expect(result.diagnostics.first?.action.contains("Rebuild") == true)
    }

    @Test("스코프의 미지원 이유를 지역 함수마다 보존한다")
    func preservesUnsupportedReason() {
        let local = local(name: "local", line: 3, isSupported: false, reason: .unknownAttributes)
        let scope = scope(
            functions: [local],
            hasUnsupportedSyntax: true,
            reason: .unknownAttributes
        )
        let result = LocalFunctionBinder.enrichWithDiagnostics(
            IndexSnapshot(symbols: [owner()]),
            scopes: [scope],
            freshPaths: [path],
            edgeKinds: []
        )

        #expect(result.snapshot.symbols.count == 1)
        #expect(result.diagnostics.map(\.reason) == [.unknownAttributes])
    }

    @Test("진입 호출이 없는 지역 함수는 기존 투영을 유지하고 사슬 부재를 설명한다")
    func reportsMissingEntryChain() {
        let owner = owner()
        let local = local(name: "local", line: 3)
        let result = LocalFunctionBinder.enrichWithDiagnostics(
            IndexSnapshot(symbols: [owner]),
            scopes: [scope(functions: [local])],
            freshPaths: [path],
            edgeKinds: []
        )

        #expect(result.snapshot == IndexSnapshot(symbols: [owner]))
        #expect(result.diagnostics.map(\.reason) == [.noEntryChain])
    }

    @Test("필터가 필요한 간선을 빼면 보강하지 않고 필터 원인을 남긴다")
    func reportsFilteredEdges() {
        let result = LocalFunctionBinder.enrichWithDiagnostics(
            IndexSnapshot(symbols: [owner()]),
            scopes: [scope(functions: [local(name: "local", line: 3)])],
            freshPaths: [path],
            edgeKinds: [.call, .reference]
        )

        #expect(result.snapshot.symbols.count == 1)
        #expect(result.diagnostics.map(\.reason) == [.filteredEdgeKinds])
    }

    @Test("컴파일러 참조를 옮길 때 출처를 합치고 복원할 때 컴파일러 출처로 되돌린다")
    func preservesReferenceOriginsAcrossProjection() {
        let owner = owner()
        let target = IndexedSymbol(
            usr: "target", name: "target()", kind: .function, module: "App",
            location: location(line: 1, column: 6)
        )
        let local = local(name: "local", line: 3)
        let ownerCall = LocalFunctionReferenceFacts(
            name: "local", location: location(line: 5, column: 9), localOwner: nil,
            isCall: true, isUnqualified: true
        )
        let nestedCall = LocalFunctionReferenceFacts(
            name: "target", location: location(line: 4, column: 9), localOwner: local.location,
            isCall: true, isUnqualified: true
        )
        let compilerReference = IndexedReference(
            sourceUSR: owner.usr, targetUSR: target.usr, kind: .call,
            location: nestedCall.location, origin: .compiler
        )
        let input = IndexSnapshot(
            symbols: [owner, target], references: [compilerReference]
        )
        let scope = scope(functions: [local], references: [ownerCall, nestedCall])
        let enriched = LocalFunctionBinder.enrichWithDiagnostics(
            input, scopes: [scope], freshPaths: [path], edgeKinds: []
        ).snapshot
        let generated = enriched.symbols.first { $0.name == "local()" }

        #expect(generated != nil)
        #expect(enriched.references.contains {
            $0.sourceUSR == generated?.usr && $0.targetUSR == target.usr
                && $0.origin == .compilerAndSyntax
        })
        #expect(enriched.references.contains {
            $0.sourceUSR == owner.usr && $0.targetUSR == generated?.usr
                && $0.origin == .syntax
        })

        let restored = LocalFunctionBinder.enrichWithDiagnostics(
            enriched, scopes: [], freshPaths: [], edgeKinds: []
        ).snapshot
        #expect(restored.references.contains {
            $0.sourceUSR == owner.usr && $0.targetUSR == target.usr
                && $0.origin == .compiler
        })
    }

    private func location(line: Int, column: Int) -> CartographCore.SourceLocation {
        SourceLocation(path: path, line: line, column: column)
    }

    private func owner() -> IndexedSymbol {
        IndexedSymbol(
            usr: "outer", name: "outer()", kind: .function, module: "App",
            location: location(line: 2, column: 6)
        )
    }

    private func local(
        name: String,
        line: Int,
        isSupported: Bool = true,
        reason: LocalFunctionSkipReason? = nil
    ) -> LocalFunctionFacts {
        LocalFunctionFacts(
            name: name,
            indexName: "\(name)()",
            location: location(line: line, column: 10),
            parentLocation: nil,
            scopeStart: location(line: 2, column: 15),
            scopeEnd: location(line: 7, column: 1),
            isSupported: isSupported,
            reason: reason
        )
    }

    private func scope(
        functions: [LocalFunctionFacts],
        references: [LocalFunctionReferenceFacts] = [],
        hasUnsupportedSyntax: Bool = false,
        reason: LocalFunctionSkipReason? = nil
    ) -> LocalFunctionScopeFacts {
        LocalFunctionScopeFacts(
            ownerName: "outer",
            ownerLocation: owner().location,
            functions: functions,
            references: references,
            blockedNames: [],
            hasUnsupportedSyntax: hasUnsupportedSyntax,
            reason: reason
        )
    }
}
