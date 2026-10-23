import CartographCore
import CartographTestSupport
import Testing

@Suite("익스텐션의 아키텍처 참조 출처")
struct ExtensionSourceOwnershipTests {
    private let domainPath = "/p/Domain/DomainType.swift"
    private let appPath = "/p/App/DomainType+App.swift"

    private func snapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("DomainType", module: "Domain", path: domainPath)
        builder.symbol("AppProtocol", kind: .protocolType, module: "App", path: appPath)
        builder.symbol("extension", kind: .extensionDeclaration, module: "App", path: appPath)
        builder.reference(from: "extension", to: "DomainType", kind: .extends, path: appPath)
        // baseOf는 확장 대상 USR을 source로 주어도 실제 발생은 앱 익스텐션에 있다.
        builder.reference(from: "DomainType", to: "AppProtocol", kind: .conformance, path: appPath)
        builder.fileModuleUsage(path: appPath, owningModule: "App")
        return builder.build()
    }

    @Test("모듈과 파일은 익스텐션 위치를 쓰고 타입은 의미 소유자를 유지한다")
    func architecturalSiteAndSemanticTypeAreDifferentLenses() {
        let input = snapshot()
        let module = GraphBuilder().build(from: input)
        #expect(module.edges == [GraphEdge(source: "App", target: "Domain", kind: .extends)])
        let file = GraphBuilder(options: .init(level: .file)).build(from: input)
        #expect(file.edges == [GraphEdge(source: NodeID(appPath), target: NodeID(domainPath), kind: .extends)])
        let type = GraphBuilder(options: .init(level: .type)).build(from: input)
        #expect(type.edges == [GraphEdge(source: "DomainType", target: "AppProtocol", kind: .conformance)])
    }

    @Test("참조 발생의 파일이 제외되면 원본 타입으로 되돌려 간선을 만들지 않는다")
    func excludedExtensionDoesNotLeakThroughOriginalType() {
        var input = snapshot()
        input.symbols.append(IndexedSymbol(usr: "DataType", name: "DataType", kind: .structType,
            module: "Data", location: SourceLocation(path: "/p/Data/Data.swift", line: 1, column: 1)))
        input.references.append(IndexedReference(sourceUSR: "DomainType", targetUSR: "DataType", kind: .reference,
            location: SourceLocation(path: appPath, line: 4, column: 1)))
        let result = GraphBuilder(options: .init(level: .module,
            pathFilter: PathFilter(exclude: ["**/App/**"]))).buildResult(from: input)
        #expect(result.graph.edges.isEmpty)
        #expect(result.sourceAttributionLimitations.isEmpty)
    }

    @Test("원본 타입이 제외되어도 포함된 익스텐션 파일의 실제 참조는 남는다")
    func admittedSiteDoesNotRequireOriginalDeclarationInScope() {
        var input = snapshot()
        input.symbols.append(IndexedSymbol(usr: "DataType", name: "DataType", kind: .structType,
            module: "Data", location: SourceLocation(path: "/p/Data/Data.swift", line: 1, column: 1)))
        input.references.append(IndexedReference(sourceUSR: "DomainType", targetUSR: "DataType", kind: .reference,
            location: SourceLocation(path: appPath, line: 4, column: 1)))
        let graph = GraphBuilder(options: .init(level: .module,
            pathFilter: PathFilter(exclude: ["**/Domain/**"]))).build(from: input)
        #expect(graph.edges == [GraphEdge(source: "App", target: "Data", kind: .reference)])
    }

    @Test("선언 없는 파일도 컴파일 모듈 근거가 있으면 참조 위치로 귀속한다")
    func compilerOwnedFileWithoutDeclarationCanOwnReference() {
        var input = snapshot()
        input.symbols.removeAll { $0.usr == "extension" }
        input.symbols = input.symbols.map { symbol in
            symbol.usr == "AppProtocol" ? IndexedSymbol(usr: symbol.usr, name: symbol.name, kind: symbol.kind,
                module: "App", location: SourceLocation(path: "/p/App/Protocol.swift", line: 1, column: 1)) : symbol
        }
        let graph = GraphBuilder(options: .init(level: .file)).build(from: input)
        #expect(graph.edges.contains { $0.source == NodeID(appPath) && $0.target == "/p/App/Protocol.swift" })
    }

    @Test("위치나 모듈 근거가 없거나 충돌하면 추측하지 않고 기존 출처를 남긴다")
    func unknownOrConflictingModuleUsesLegacySource() {
        var input = snapshot()
        input.fileModuleUsages[appPath] = FileModuleUsage(owningModule: "Other")
        let result = GraphBuilder().buildResult(from: input)
        #expect(result.graph.edges.contains { $0.source == "Domain" && $0.target == "App" })
        #expect(result.sourceAttributionLimitations.count == 1)
        #expect(result.sourceAttributionLimitations.first?.contains("conflicting-file-modules") == true)
        #expect(result.sourceAttributionLimitations.first?.contains(appPath) == true)
        let file = GraphBuilder(options: .init(level: .file)).build(from: input)
        #expect(file.node(NodeID(appPath))?.module == "")
        input.references = [IndexedReference(sourceUSR: "DomainType", targetUSR: "AppProtocol", kind: .reference,
            location: SourceLocation(path: "/not-observed/File.swift", line: 1, column: 1))]
        #expect(GraphBuilder().build(from: input).edges == [GraphEdge(source: "Domain", target: "App", kind: .reference)])
        input.references = [IndexedReference(sourceUSR: "DomainType", targetUSR: "AppProtocol", kind: .reference)]
        let unlocated = GraphBuilder().buildResult(from: input)
        #expect(unlocated.graph.edges == [GraphEdge(source: "Domain", target: "App", kind: .reference)])
        #expect(unlocated.sourceAttributionLimitations.first?.contains("unlocated-reference") == true)
    }

    @Test("실제 파일 상호 참조와 심볼 간선은 제거하지 않는다")
    func realMutualReferenceAndSymbolGraphSurvive() {
        var input = snapshot()
        input.references.append(IndexedReference(sourceUSR: "DomainType", targetUSR: "AppProtocol", kind: .reference,
            location: SourceLocation(path: domainPath, line: 5, column: 1)))
        let file = GraphBuilder(options: .init(level: .file)).build(from: input)
        #expect(file.successors(of: NodeID(domainPath)) == [NodeID(appPath)])
        #expect(file.successors(of: NodeID(appPath)) == [NodeID(domainPath)])
        let symbol = GraphBuilder(options: .init(level: .symbol)).build(from: input)
        #expect(symbol.edges.contains { $0.source == "DomainType" && $0.target == "AppProtocol" && $0.kind == .conformance })
        var reversed = input
        reversed.references.reverse()
        #expect(GraphBuilder(options: .init(level: .file)).build(from: reversed).edges == file.edges)
    }

    @Test("폴백 관측 수는 모두 세고 경로 표시는 제한하며 순서와 무관하다")
    func fallbackWarningsAggregateAndBoundPaths() {
        var input = snapshot()
        input.references = (1...22).map { number in
            IndexedReference(sourceUSR: "DomainType", targetUSR: "AppProtocol", kind: .reference,
                location: SourceLocation(path: "/unobserved/\(number).swift", line: 1, column: 1))
        }
        let forward = GraphBuilder().buildResult(from: input)
        #expect(forward.sourceAttributionLimitations.count == 1)
        #expect(forward.sourceAttributionLimitations.first?.contains("22 module reference occurrence(s)") == true)
        #expect(forward.sourceAttributionLimitations.first?.contains("unknown-file-ownership") == true)
        #expect(forward.sourceAttributionLimitations.first?.contains("omitted paths: 12") == true)
        #expect(forward.sourceAttributionLimitations.first?.contains("legacy semantic source") == true)
        input.references.reverse()
        #expect(GraphBuilder().buildResult(from: input).sourceAttributionLimitations == forward.sourceAttributionLimitations)
        for level in [GraphLevel.symbol, .type] {
            #expect(GraphBuilder(options: .init(level: level)).buildResult(from: input).sourceAttributionLimitations.isEmpty)
        }
    }

    @Test("관측 파일의 모듈이 없으면 경고하고 파일 렌즈의 실제 경로는 유지한다")
    func observedFileWithoutModuleReportsModuleFallback() {
        var input = snapshot()
        input.fileModuleUsages["/p/Unknown.swift"] = FileModuleUsage()
        input.references = [IndexedReference(sourceUSR: "DomainType", targetUSR: "AppProtocol", kind: .reference,
            location: SourceLocation(path: "/p/Unknown.swift", line: 1, column: 1))]
        let module = GraphBuilder().buildResult(from: input)
        #expect(module.sourceAttributionLimitations.first?.contains("missing-file-module") == true)
        let file = GraphBuilder(options: .init(level: .file)).buildResult(from: input)
        #expect(file.graph.edges.first?.source == "/p/Unknown.swift")
        #expect(file.sourceAttributionLimitations.isEmpty)
    }

    @Test("폴백의 자기 간선이 제거되어도 출처 불확실성을 빈 그래프로 숨기지 않는다")
    func droppedFallbackSelfLoopStillHasUnknownSource() {
        var input = snapshot()
        input.references = [IndexedReference(sourceUSR: "DomainType", targetUSR: "DomainType", kind: .reference,
            location: SourceLocation(path: "/not-observed.swift", line: 1, column: 1))]
        let result = GraphBuilder().buildResult(from: input)
        #expect(result.graph.edges.isEmpty)
        #expect(result.sourceAttributionLimitations.first?.contains("1 module reference occurrence(s)") == true)
    }
}
