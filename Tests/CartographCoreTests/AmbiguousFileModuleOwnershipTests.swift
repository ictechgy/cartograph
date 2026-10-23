import CartographCore
import CartographTestSupport
import Testing

@Suite("여러 compile unit의 파일 소유 모듈 불확실성")
struct AmbiguousFileModuleOwnershipTests {
    private let sharedPath = "/p/Shared.m"
    private let targetPath = "/p/Target.m"

    private func snapshot(usage: FileModuleUsage?) -> IndexSnapshot {
        var builder = SnapshotBuilder()
        // 두 모듈의 같은 Clang USR 정의가 병합된 뒤에는 한 대표 모듈만 남는다.
        builder.symbol("c:@F@sharedCaller", name: "sharedCaller", kind: .function,
            module: "FirstUnit", path: sharedPath)
        builder.symbol("c:@F@target", name: "target", kind: .function,
            module: "Target", path: targetPath)
        builder.reference(from: "c:@F@sharedCaller", to: "c:@F@target", kind: .call,
            path: sharedPath, origin: .compiler)
        var result = builder.build()
        if let usage { result.fileModuleUsages[sharedPath] = usage }
        return result
    }

    @Test("병합된 단일 Clang 선언은 알려진 파일 소유 모호성을 확정 모듈로 바꾸지 않는다")
    func mergedClangSymbolDoesNotEraseAmbiguousOwner() {
        let input = snapshot(usage: FileModuleUsage(owningModule: nil,
            referencedModules: ["FirstUnit", "SecondUnit"], hasUnattributedReferences: true))
        let result = GraphBuilder().buildResult(from: input)
        #expect(result.graph.edges == [GraphEdge(source: "FirstUnit", target: "Target", kind: .call)])
        #expect(result.sourceAttributionLimitations.count == 1)
        #expect(result.sourceAttributionLimitations.first?.contains("unresolved-file-module-evidence") == true)
        #expect(result.sourceAttributionLimitations.first?.contains("legacy semantic source") == true)
        #expect(result.sourceAttributionLimitations.first?.contains(sharedPath) == true)
        #expect(result.sourceAttributionLimitations.first?.contains("remain uncertain") == true)
    }

    @Test("모듈이 미확정이어도 실제 발생 파일은 유지하되 임의 모듈 이름을 붙이지 않는다")
    func physicalFileRemainsKnownWithoutInventingModule() {
        let input = snapshot(usage: FileModuleUsage(hasUnattributedReferences: true))
        let result = GraphBuilder(options: .init(level: .file)).buildResult(from: input)
        #expect(result.graph.edges == [GraphEdge(source: NodeID(sharedPath), target: NodeID(targetPath), kind: .call)])
        #expect(result.graph.node(NodeID(sharedPath))?.module == "")
        #expect(result.sourceAttributionLimitations.isEmpty)
        for level in [GraphLevel.symbol, .type] {
            let semantic = GraphBuilder(options: .init(level: level)).buildResult(from: input)
            #expect(semantic.sourceAttributionLimitations.isEmpty)
            #expect(semantic.graph.edges == [
                GraphEdge(source: "c:@F@sharedCaller", target: "c:@F@target", kind: .call)
            ])
        }
    }

    @Test("참조 대상 모듈만 모르는 파일의 확정 소유자나 구형 선언 근거는 유지한다")
    func unknownReferenceTargetIsNotUnknownFileOwner() {
        let usages: [FileModuleUsage?] = [
            FileModuleUsage(owningModule: "FirstUnit", hasUnattributedReferences: true),
            FileModuleUsage(owningModule: nil, hasUnattributedReferences: false), nil,
        ]
        for usage in usages {
            let result = GraphBuilder().buildResult(from: snapshot(usage: usage))
            #expect(result.graph.edges == [GraphEdge(source: "FirstUnit", target: "Target", kind: .call)])
            #expect(result.sourceAttributionLimitations.isEmpty)
        }
    }

    @Test("불확실한 발생 모듈은 다른 의미 소유자를 임의 compile unit으로 바꾸지 않는다")
    func unresolvedSiteFallsBackToActualSemanticSource() {
        var input = snapshot(usage: FileModuleUsage(hasUnattributedReferences: true))
        input.symbols.append(IndexedSymbol(usr: "OriginalOwner", name: "OriginalOwner", kind: .structType,
            module: "Domain", location: SourceLocation(path: "/p/Domain.swift", line: 1, column: 1)))
        input.references = [IndexedReference(sourceUSR: "OriginalOwner", targetUSR: "c:@F@target", kind: .reference,
            location: SourceLocation(path: sharedPath, line: 7, column: 1), origin: .compiler)]
        let result = GraphBuilder().buildResult(from: input)
        #expect(result.graph.edges == [GraphEdge(source: "Domain", target: "Target", kind: .reference)])
        #expect(result.sourceAttributionLimitations.count == 1)
    }
}
