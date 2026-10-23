import CartographCore
@testable import CartographIndexStore
import Foundation
import IndexStoreDB
import Testing

@Suite("동일 Clang USR 병합 뒤 모듈 소유권")
struct MergedClangModuleOwnershipTests {
    private let sourcePath = "/p/Shared.m"

    @Test("두 unit의 같은 파일·USR 정의를 병합해도 알려진 모호성 경고가 남는다")
    func mergedDefinitionsKeepFileAmbiguity() throws {
        var warnings: [[String]] = []
        for modules in [["Alpha", "Beta"], ["Beta", "Alpha"]] {
            let snapshot = IndexStoreProvider.snapshot(from: occurrences(modules: modules),
                                                       includeExternalSymbols: false)
            let declarations = snapshot.symbols.filter { $0.usr == "c:@F@sharedCaller" }
            #expect(declarations.count == 1)
            #expect(declarations.first?.module == modules.first)
            let usage = try #require(snapshot.fileModuleUsages[sourcePath])
            #expect(usage.owningModule == nil)
            #expect(usage.hasUnattributedReferences)
            let result = GraphBuilder().buildResult(from: snapshot)
            #expect(result.sourceAttributionLimitations.count == 1)
            #expect(result.sourceAttributionLimitations.first?.contains("unresolved-file-module-evidence") == true)
            #expect(result.sourceAttributionLimitations.first?.contains("legacy semantic source") == true)
            #expect(result.sourceAttributionLimitations.first?.contains(sourcePath) == true)
            #expect(result.graph.edges.allSatisfy { $0.source == NodeID(modules[0]) && $0.target == "Target" })
            #expect(!result.graph.edges.isEmpty)
            warnings.append(result.sourceAttributionLimitations)
        }
        #expect(warnings[0] == warnings[1])
    }

    @Test("같은 Clang 파일의 단일 unit은 여전히 확정 모듈 근거다")
    func singleUnitIsNegativeControl() throws {
        let snapshot = IndexStoreProvider.snapshot(from: occurrences(modules: ["Alpha"]), includeExternalSymbols: false)
        let usage = try #require(snapshot.fileModuleUsages[sourcePath])
        #expect(usage.owningModule == "Alpha")
        #expect(!usage.hasUnattributedReferences)
        let result = GraphBuilder().buildResult(from: snapshot)
        #expect(result.sourceAttributionLimitations.isEmpty)
        #expect(result.graph.edges == [GraphEdge(source: "Alpha", target: "Target", kind: .call)])
    }

    private func occurrences(modules: [String]) -> [SymbolOccurrence] {
        let caller = Symbol(usr: "c:@F@sharedCaller", name: "sharedCaller", kind: .function,
            subKind: .none, properties: [], language: .c)
        let target = Symbol(usr: "c:@F@target", name: "target", kind: .function,
            subKind: .none, properties: [], language: .c)
        var result = [SymbolOccurrence(symbol: target,
            location: location(path: "/p/Target.m", module: "Target", line: 1), roles: .definition,
            symbolProvider: .clang, relations: [])]
        for module in modules {
            result.append(SymbolOccurrence(symbol: caller,
                location: location(path: sourcePath, module: module, line: 1), roles: .definition,
                symbolProvider: .clang, relations: []))
            result.append(SymbolOccurrence(symbol: target,
                location: location(path: sourcePath, module: module, line: 2), roles: [.reference, .call],
                symbolProvider: .clang, relations: [SymbolRelation(symbol: caller, roles: .calledBy)]))
        }
        return result
    }

    private func location(path: String, module: String, line: Int) -> SymbolLocation {
        SymbolLocation(path: path, timestamp: Date(timeIntervalSince1970: 0), moduleName: module,
            isSystem: false, line: line, utf8Column: 1)
    }
}
