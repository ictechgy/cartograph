import CartographCore
import CartographKit
import CartographTestSupport
import Foundation
@testable import cartograph
import Testing

@Suite("Cartograph MCP 도구")
struct MCPToolsTests {
    private func makeSession() throws -> AnalysisSession {
        var builder = SnapshotBuilder()
        builder.symbol("Home", kind: .structType, attributes: [.entryPoint])
        builder.symbol("Service", kind: .classType)
        builder.symbol("Handler", kind: .classType)
        builder.symbol("Dispatcher", kind: .classType)
        builder.reference(from: "Home", to: "Service", kind: .call)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )
        return try AnalysisSession(service: service)
    }

    private func object(_ result: MCPToolResult) -> [String: MCPJSONValue] {
        result.structuredContent?.objectValue ?? [:]
    }

    @Test("serve는 MCP stdout을 오염시키는 전역 옵션을 거부한다")
    func serveRejectsConflictingOptions() {
        for arguments in [
            ["--since", "HEAD"], ["--level", "symbol"], ["--report-format", "json"],
            ["--strict"], ["--output", "/tmp/result.json"],
        ] {
            do {
                let command = try ServeCommand.parse(arguments)
                try command.validate()
                Issue.record("오류가 발생해야 한다: \(arguments)")
            } catch {
                #expect(!"\(error)".isEmpty)
            }
        }
    }

    @Test("도구 정의는 다섯 도구를 읽기 전용 힌트와 함께 공개한다")
    func publishesToolDefinitions() {
        #expect(CartographMCPTools.definitions.map(\.name).sorted() == [
            "cartograph_check", "cartograph_impact", "cartograph_query", "cartograph_runtime_discover",
            "cartograph_status",
        ])
        #expect(CartographMCPTools.definitions.allSatisfy { $0.readOnly && !$0.destructive })
    }

    @Test("고정 Core Data 근거를 못 읽으면 런타임 도구만 실패하고 기본 query는 유지한다")
    func rejectsMissingFixedBuildEvidenceWithoutChangingQuery() throws {
        let tools = CartographMCPTools(makeSession: makeSession,
            coreDataBuildEvidencePath: "/p/missing-coredata.json")
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_runtime_discover", arguments: .object([:]))
        }
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_impact", arguments: .object([
                "symbols": .array([.string("Service")]),
            ]))
        }
        let result = try tools.call(name: "cartograph_query", arguments: .object([
            "symbols": .array([.string("Service")]),
        ]))
        #expect(!result.isError)
        #expect(object(result)["coreDataBuildEvidence"] == nil)
        #expect(object(result)["session"]?.objectValue?["generation"] == .integer(1))
    }

    @Test("MCP 클라이언트는 서버의 고정 빌드 근거 경로를 바꿀 수 없다")
    func refusesClientSelectedBuildEvidencePaths() throws {
        let tools = CartographMCPTools(makeSession: makeSession,
            coreDataBuildEvidencePath: "/p/coredata.json")
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_runtime_discover", arguments: .object([
                "coreDataBuildEvidencePath": .string("/outside/coredata.json"),
            ]))
        }
        #expect(throws: (any Error).self) {
            _ = try ServeCommand.parse(["--coredata-build-evidence", " "])
        }
    }

    @Test("MCP 모델 근거는 프로젝트 밖이나 인증 파일 경로를 읽지 않는다")
    func rejectsOutOfScopeAndCredentialEvidencePaths() throws {
        for (path, reason) in [
            ("/outside/evidence.json", "inside the configured project"),
            ("/p/auth.json", "credential-like"),
            ("/p/evidence.yml", "JSON file"),
        ] {
            let tools = CartographMCPTools(makeSession: makeSession, coreDataBuildEvidencePath: path)
            do {
                _ = try tools.call(name: "cartograph_runtime_discover", arguments: .object([:]))
                Issue.record("허용하지 않은 근거 경로를 수용했다")
            } catch let error as MCPToolFailure {
                #expect(error.message.contains(reason))
            }
        }
    }

    @Test("runtime discover는 전체 계수와 잘림을 같은 세대의 구조화 결과로 반환한다")
    func runtimeDiscoveryReturnsSessionEnvelope() throws {
        let provider = MCPCountingIndexProvider(snapshot: runtimeSnapshot())
        let tools = CartographMCPTools(makeSession: { try self.runtimeSession(provider: provider) })

        let first = try tools.call(
            name: "cartograph_runtime_discover",
            arguments: .object(["limit": .integer(1)])
        )
        let second = try tools.call(name: "cartograph_runtime_discover", arguments: .object([:]))
        let firstObject = object(first)
        let resultData = try JSONEncoder.cartographDefault().encode(firstObject["result"]!)
        let document = try JSONDecoder().decode(RuntimeDiscoveryDocument.self, from: resultData)

        #expect(firstObject["session"]?.objectValue?["generation"] == .integer(1))
        #expect(document.format == "runtime-discovery")
        #expect(document.status == "needsReview")
        #expect(document.boundaryCount == 2)
        #expect(document.findings.count == 1)
        #expect(document.truncated)
        #expect(!first.isError)
        #expect(object(second)["session"]?.objectValue?["generation"] == .integer(1))
        #expect(provider.loadCount == 1)
    }

    @Test("runtime discover는 세션을 만들기 전에 limit 범위를 검증한다")
    func validatesRuntimeDiscoveryLimitBeforeCreatingSession() {
        var creations = 0
        let tools = CartographMCPTools(makeSession: {
            creations += 1
            return try self.makeSession()
        })
        for limit in [0, 10_001] {
            #expect(throws: MCPToolFailure.self) {
                try tools.call(
                    name: "cartograph_runtime_discover",
                    arguments: .object(["limit": .integer(Int64(limit))])
                )
            }
        }
        #expect(creations == 0)
    }

    @Test("세션은 실제 도구를 처음 호출할 때만 만든다")
    func createsSessionLazily() throws {
        var creations = 0
        let tools = CartographMCPTools(makeSession: {
            creations += 1
            return try self.makeSession()
        })
        #expect(creations == 0)
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_query", arguments: .object([
                "symbols": .array((0..<1000).map { .string("S\($0)") }),
                "limit": .integer(10_000),
            ]))
        }
        #expect(creations == 0)
        let result = try tools.call(name: "cartograph_status", arguments: .object([:]))
        #expect(creations == 1)
        #expect(object(result)["generation"] == .integer(1))
    }

    @Test("query는 배치 결과를 구조화하고 없는 심볼은 도구 오류로 표시한다")
    func queryResultAndMissingSubject() throws {
        let tools = CartographMCPTools(makeSession: makeSession)
        let found = try tools.call(name: "cartograph_query", arguments: .object([
            "symbols": .array([.string("Service")]),
        ]))
        #expect(!found.isError)
        #expect(object(found)["result"]?.objectValue?["format"]?.stringValue == "symbol-query-batch")
        let queryData = try JSONEncoder.cartographDefault().encode(object(found)["result"]!)
        let batch = try JSONDecoder().decode(SymbolQueryBatchDocument.self, from: queryData)
        #expect(batch.results.count == 1)
        #expect(batch.results[0].requested == "Service")

        let missing = try tools.call(name: "cartograph_query", arguments: .object([
            "symbols": .array([.string("Missing")]),
        ]))
        #expect(missing.isError)
    }

    @Test("큰 query 배치는 선택 근거 예산을 공유하고 결과 순서와 전체 개수를 유지한다")
    func sharesOptionalEvidenceBudgetAcrossQueryBatch() throws {
        let ownerPath = "/p/Owner.swift"
        let targetPath = "/p/Target.swift"
        let hidden = (0..<60).map { "    func hidden\($0)() {}" }
        let calls = (0..<40).map { _ in "    target()" }
        let source = (["func owner() {"] + hidden + calls + ["}"]).joined(separator: "\n")
        let fileSystem = InMemoryFileSystem(files: [ownerPath: source, targetPath: "func target() {}"])
        for path in [ownerPath, targetPath] {
            fileSystem.setModificationDate(Date(timeIntervalSince1970: 10), for: path)
        }
        let snapshot = IndexSnapshot(symbols: [
            IndexedSymbol(usr: "owner", name: "owner()", kind: .function, module: "App",
                location: SourceLocation(path: ownerPath, line: 1, column: 6)),
            IndexedSymbol(usr: "target", name: "target()", kind: .function, module: "App",
                location: SourceLocation(path: targetPath, line: 1, column: 6)),
        ], references: (0..<40).map { index in
            IndexedReference(sourceUSR: "owner", targetUSR: "target", kind: .call,
                location: SourceLocation(path: ownerPath, line: 62 + index, column: 5), origin: .compiler)
        }, indexedFileDates: [ownerPath: Date(timeIntervalSince1970: 20), targetPath: Date(timeIntervalSince1970: 20)])
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(fileSystem: fileSystem,
            indexProviderOverride: StaticIndexProvider(snapshot)))
        let tools = CartographMCPTools(makeSession: { try AnalysisSession(service: service) })
        let result = try tools.call(name: "cartograph_query", arguments: .object([
            "symbols": .array(Array(repeating: .string("target"), count: 1000)), "limit": .integer(1),
        ]))
        let data = try JSONEncoder.cartographDefault().encode(object(result)["result"]!)
        let batch = try JSONDecoder().decode(SymbolQueryBatchDocument.self, from: data)
        #expect(batch.results.count == 1000)
        #expect(batch.results.allSatisfy { $0.requested == "target" && $0.status == "found" })
        let references = batch.results.flatMap { $0.result?.usedBy ?? [] }.compactMap(\.referenceEvidence)
        #expect(references.reduce(0) { $0 + $1.items.count } == 200)
        #expect(references.allSatisfy { $0.totalCount == 40 && $0.omittedCount == 40 - $0.items.count })
        let diagnostics = batch.results.compactMap(\.localFunctionDiagnostics)
        #expect(diagnostics.reduce(0) { $0 + $1.items.count } == 50)
        #expect(diagnostics.allSatisfy { $0.totalCount == 60 && $0.omittedCount == 60 - $0.items.count })
        #expect(data.count < 2 * 1024 * 1024)
        let handler = MCPMessageHandler(tools: CartographMCPTools.definitions,
            serverName: "cartograph", serverVersion: Cartograph.version, instructions: "",
            callTool: { name, arguments in try tools.call(name: name, arguments: arguments) })
        let request = MCPJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("tools/call"),
            "params": .object([
                "_meta": .object([
                    "io.modelcontextprotocol/protocolVersion": .string(MCPMessageHandler.currentVersion),
                    "io.modelcontextprotocol/clientCapabilities": .object([:]),
                ]),
                "name": .string("cartograph_query"),
                "arguments": .object([
                    "symbols": .array(Array(repeating: .string("target"), count: 1000)), "limit": .integer(1),
                ]),
            ]),
        ])
        let encoded = try #require(handler.handle(JSONEncoder.cartographDefault().encode(request)))
        let response = try JSONDecoder().decode(MCPJSONValue.self, from: encoded)
        #expect(response.objectValue?["error"] == nil)
        #expect(response.objectValue?["result"] != nil)
        #expect(encoded.count <= 4 * 1024 * 1024)
    }

    @Test("impact는 정확히 하나의 선택 모드와 범위를 요구한다")
    func validatesImpactSelectors() throws {
        let tools = CartographMCPTools(makeSession: makeSession)
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_impact", arguments: .object([:]))
        }
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_impact", arguments: .object([
                "symbols": .array([.string("Service")]), "files": .array([.string("Sources/App.swift")]),
            ]))
        }
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_query", arguments: .object([
                "symbols": .array([.string("Service")]), "depth": .integer(129),
            ]))
        }
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_impact", arguments: .object([
                "symbols": .array([.string("Dispatcher")]), "runtimeContracts": .array([]),
            ]))
        }
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_impact", arguments: .object([
                "symbols": .array([.string("Dispatcher")]),
                "runtimeContracts": .array([.object(["id": .string("x"), "target": .string("Dispatcher"), "unknown": .boolean(true)])]),
            ]))
        }
        #expect(throws: MCPToolFailure.self) {
            try tools.call(name: "cartograph_impact", arguments: .object([
                "symbols": .array([.string("Dispatcher")]),
                "runtimeContracts": .array([.object([
                    "id": .string(String(repeating: "x", count: 257)),
                    "target": .string("Dispatcher"), "mechanism": .string("registration"),
                    "requiredScenarios": .array([.string("launch")]),
                ])]),
            ]))
        }
    }

    @Test("runtime contract는 정적 간선 없이도 영향과 계약 근거를 연결한다")
    func runtimeContractAddsRuntimeOnlyImpact() throws {
        let tools = CartographMCPTools(makeSession: makeSession)
        let result = try tools.call(name: "cartograph_impact", arguments: .object([
            "symbols": .array([.string("Dispatcher")]),
            "runtimeContracts": .array([.object([
                "id": .string("handler.dispatch"),
                "source": .string("Handler"),
                "target": .string("Dispatcher"),
                "mechanism": .string("registration"),
                "requiredScenarios": .array([.string("launch")]),
                "expectedValue": .string("secret-value"),
            ])]),
        ]))
        let data = try JSONEncoder.cartographDefault().encode(object(result)["result"]!)
        let document = try JSONDecoder().decode(ImpactDocument.self, from: data)
        let affected = document.affected.first { $0.symbol.name == "Handler" }
        #expect(affected?.relationship == "runtimeContract")
        #expect(affected?.runtimeContracts == ["handler.dispatch"])
        #expect(!result.isError)
        let serialized = String(
            decoding: try JSONEncoder.cartographDefault().encode(result.structuredContent!), as: UTF8.self
        )
        #expect(!serialized.contains("secret-value"))

        let emptyValue = try tools.call(name: "cartograph_impact", arguments: .object([
            "symbols": .array([.string("Dispatcher")]),
            "runtimeContracts": .array([.object([
                "id": .string("empty-value"), "target": .string("Dispatcher"),
                "mechanism": .string("registration"),
                "requiredScenarios": .array([.string("launch")]), "expectedValue": .string(""),
            ])]),
        ]))
        #expect(!emptyValue.isError)
    }

    @Test("check 결과에 발견이 있으면 구조화된 도구 오류로 반환한다")
    func checkFindingsAreToolErrors() throws {
        let tools = CartographMCPTools(makeSession: makeSession)
        let result = try tools.call(name: "cartograph_check", arguments: .object(["limit": .integer(1)]))
        #expect(result.isError)
        #expect(object(result)["result"]?.objectValue?["format"]?.stringValue == "project-check")
        let data = try JSONEncoder.cartographDefault().encode(object(result)["result"]!)
        let document = try JSONDecoder().decode(CheckDocument.self, from: data)
        #expect(document.diagnosticCount > document.diagnostics.count)
        #expect(document.truncated)
    }

    @Test("세션 생성 오류 뒤 다음 도구 호출은 복구된다")
    func recoversAfterSessionFactoryError() throws {
        var attempts = 0
        let tools = CartographMCPTools(makeSession: {
            attempts += 1
            if attempts == 1 { throw AnalysisSessionError.unavailable }
            return try self.makeSession()
        })
        let handler = MCPMessageHandler(
            tools: CartographMCPTools.definitions,
            callTool: { name, arguments in try tools.call(name: name, arguments: arguments) }
        )
        let discover = Self.discoveryRequest()
        #expect(handler.handle(discover) != nil)
        #expect(attempts == 0)
        let first = try JSONDecoder().decode(MCPJSONValue.self, from: handler.handle(Self.request(id: 2, name: "cartograph_status"))!)
        #expect(first.objectValue?["result"]?.objectValue?["isError"] == .boolean(true))
        let second = try JSONDecoder().decode(MCPJSONValue.self, from: handler.handle(Self.request(id: 3, name: "cartograph_status"))!)
        #expect(second.objectValue?["result"]?.objectValue?["isError"] == .boolean(false))
    }

    private static func request(id: Int = 1, name: String) -> Data {
        let params: MCPJSONValue = .object([
            "_meta": .object([
                "io.modelcontextprotocol/protocolVersion": .string(MCPMessageHandler.currentVersion),
                "io.modelcontextprotocol/clientCapabilities": .object([:]),
            ])
        ])
        return try! JSONEncoder.cartographDefault().encode(MCPJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .integer(Int64(id)), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": .object([:]), "_meta": params.objectValue!["_meta"]!]),
        ]))
    }

    private func runtimeSession(provider: MCPCountingIndexProvider) throws -> AnalysisSession {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App.swift": """
                import Foundation
                let first = NSClassFromString(dynamicFirst)
                let second = NSClassFromString(dynamicSecond)
                struct Root {}
                """,
        ])
        let service = CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem,
                indexProviderOverride: provider
            )
        )
        return try AnalysisSession(service: service)
    }

    private func runtimeSnapshot() -> IndexSnapshot {
        var builder = SnapshotBuilder(path: "/p/App.swift")
        builder.symbol("Root", kind: .structType, line: 4)
        return builder.build()
    }

    private static func discoveryRequest() -> Data {
        let meta: MCPJSONValue = .object([
            "io.modelcontextprotocol/protocolVersion": .string(MCPMessageHandler.currentVersion),
            "io.modelcontextprotocol/clientCapabilities": .object([:]),
        ])
        return try! JSONEncoder.cartographDefault().encode(MCPJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("server/discover"),
            "params": .object(["_meta": .object(meta.objectValue!)]),
        ]))
    }
}

private final class MCPCountingIndexProvider: IndexProviding, @unchecked Sendable {
    private let snapshot: IndexSnapshot
    private let lock = NSLock()
    private var count = 0

    init(snapshot: IndexSnapshot) {
        self.snapshot = snapshot
    }

    var loadCount: Int { lock.withLock { count } }

    func loadSnapshot() throws -> IndexSnapshot {
        lock.withLock { count += 1 }
        return snapshot
    }
}
