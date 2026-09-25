import CartographKit
import CartographCore
import Foundation

/// Cartograph 세션을 MCP 도구 호출로 감싸는 직렬 어댑터.
final class CartographMCPTools {
    typealias SessionFactory = () throws -> AnalysisSession

    static let definitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "cartograph_status",
            description: "Return the prepared analysis session metadata.",
            inputSchema: objectSchema(properties: ["refresh": .object(["type": .string("boolean")])])
        ),
        MCPToolDefinition(
            name: "cartograph_query",
            description: "Query Swift declarations; symbols × limit ≤ 1000. Optional evidence shares "
                + "200 reference records and 50 local diagnostics across the response; omitted counts remain explicit.",
            inputSchema: objectSchema(properties: [
                "symbols": arraySchema(minimum: 1, maximum: 1000),
                "depth": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(128)]),
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(10_000)]),
            ], required: ["symbols"])
        ),
        MCPToolDefinition(
            name: "cartograph_impact",
            description: "Find direct and transitive consumers before editing.",
            inputSchema: objectSchema(properties: [
                "symbols": arraySchema(minimum: 1, maximum: 1000),
                "files": arraySchema(minimum: 1, maximum: 1000),
                "runtimeContracts": runtimeContractsSchema(),
                "depth": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(128)]),
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(10_000)]),
            ])
        ),
        MCPToolDefinition(
            name: "cartograph_affected",
            description: "List the test declarations that reach changed declarations or files, with their depth "
                + "and the path that reached them. Static reachability, not a test run.",
            inputSchema: objectSchema(properties: [
                "symbols": arraySchema(minimum: 1, maximum: 1000),
                "files": arraySchema(minimum: 1, maximum: 1000),
                "depth": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(128)]),
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(10_000)]),
            ])
        ),
        MCPToolDefinition(
            name: "cartograph_runtime_discover",
            description: "Discover supported runtime-only dependencies and unresolved review items.",
            inputSchema: objectSchema(properties: [
                "limit": .object([
                    "type": .string("integer"), "minimum": .integer(1), "maximum": .integer(10_000),
                ]),
            ])
        ),
        MCPToolDefinition(
            name: "cartograph_check",
            description: "Run the combined dead-code, module-cycle, type-cycle and layer checks.",
            inputSchema: objectSchema(properties: [
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(10_000)]),
            ])
        ),
    ]

    private let makeSession: SessionFactory
    private let coreDataBuildEvidencePath: String?
    private var session: AnalysisSession?

    init(makeSession: @escaping SessionFactory, coreDataBuildEvidencePath: String? = nil) {
        self.makeSession = makeSession
        self.coreDataBuildEvidencePath = coreDataBuildEvidencePath
    }

    /// MCP 요청 하나를 검증하고 도구 결과를 만든다.
    func call(name: String, arguments: MCPJSONValue) throws -> MCPToolResult {
        do {
            guard case let .object(object) = arguments else {
                throw MCPToolFailure(message: "tool arguments must be an object")
            }
            switch name {
            case "cartograph_status": return try status(object)
            case "cartograph_query": return try query(object)
            case "cartograph_impact": return try impact(object)
            case "cartograph_affected": return try affected(object)
            case "cartograph_runtime_discover": return try runtimeDiscover(object)
            case "cartograph_check": return try check(object)
            default: throw MCPToolFailure(message: "unknown Cartograph tool")
            }
        } catch let error as MCPToolFailure {
            throw error
        } catch let error as CartographError {
            throw MCPToolFailure(message: error.errorDescription ?? "Cartograph analysis failed")
        } catch let error as AnalysisSessionError {
            throw MCPToolFailure(message: error.errorDescription ?? "analysis session failed")
        } catch {
            throw MCPToolFailure(message: "Cartograph analysis failed")
        }
    }

    private func status(_ arguments: [String: MCPJSONValue]) throws -> MCPToolResult {
        try rejectUnknown(arguments, allowed: ["refresh"])
        let refresh = try optionalBool(arguments["refresh"], name: "refresh") ?? false
        let metadata: AnalysisSession.Metadata
        if refresh {
            metadata = try requireSession().refresh()
        } else {
            metadata = try requireSession().status()
        }
        return try structured(metadata)
    }

    private func query(_ arguments: [String: MCPJSONValue]) throws -> MCPToolResult {
        try rejectUnknown(arguments, allowed: ["symbols", "depth", "limit"])
        let symbols = try requiredStrings(arguments["symbols"], name: "symbols", range: 1...1000)
        let depth = try optionalInt(arguments["depth"], name: "depth", range: 1...128) ?? 1
        let limit = try optionalInt(arguments["limit"], name: "limit", range: 1...10_000) ?? 50
        guard symbols.count <= 1000 / limit else {
            throw MCPToolFailure(message: "symbols × limit exceeds the shared query budget of 1000; split the batch or reduce limit")
        }
        let session = try requireSession()
        let document = try session.query(symbols: symbols, depth: depth, limit: limit,
            evidenceBudget: QueryEvidenceBudget())
        return try structured(
            SessionResult(session: try preparedMetadata(session), result: document),
            isError: document.results.contains { $0.status == "notFound" }
        )
    }

    private func impact(_ arguments: [String: MCPJSONValue]) throws -> MCPToolResult {
        try rejectUnknown(arguments, allowed: ["symbols", "files", "depth", "limit", "runtimeContracts"])
        let symbols = try optionalStrings(arguments["symbols"], name: "symbols", range: 1...1000) ?? []
        let files = try optionalStrings(arguments["files"], name: "files", range: 1...1000) ?? []
        let modeCount = [!symbols.isEmpty, !files.isEmpty].count { $0 }
        guard modeCount == 1 else {
            throw MCPToolFailure(message: "impact requires exactly one non-empty symbols or files selector")
        }
        let depth = try optionalInt(arguments["depth"], name: "depth", range: 1...128)
        let limit = try optionalInt(arguments["limit"], name: "limit", range: 1...10_000) ?? 200
        let runtimeContracts = try runtimeContracts(arguments["runtimeContracts"])
        let session = try requireSession()
        let document = try session.impact(
            symbols: symbols, files: files, maxDepth: depth, limit: limit, runtimeContracts: runtimeContracts,
            coreDataBuildEvidencePath: coreDataBuildEvidencePath
        )
        return try structured(
            SessionResult(session: try preparedMetadata(session), result: document,
                coreDataBuildEvidence: session.runtimeBuildEvidenceMetadata),
            isError: document.status == "incomplete"
        )
    }

    private func affected(_ arguments: [String: MCPJSONValue]) throws -> MCPToolResult {
        try rejectUnknown(arguments, allowed: ["symbols", "files", "depth", "limit"])
        let symbols = try optionalStrings(arguments["symbols"], name: "symbols", range: 1...1000) ?? []
        let files = try optionalStrings(arguments["files"], name: "files", range: 1...1000) ?? []
        guard [!symbols.isEmpty, !files.isEmpty].count(where: { $0 }) == 1 else {
            throw MCPToolFailure(message: "affected requires exactly one non-empty symbols or files selector")
        }
        let depth = try optionalInt(arguments["depth"], name: "depth", range: 1...128)
        let limit = try optionalInt(arguments["limit"], name: "limit", range: 1...10_000) ?? 200
        let session = try requireSession()
        let document = try session.affected(symbols: symbols, files: files, maxDepth: depth, limit: limit)
        return try structured(
            SessionResult(session: try preparedMetadata(session), result: document),
            isError: !document.selectionIssues.isEmpty
        )
    }

    private func check(_ arguments: [String: MCPJSONValue]) throws -> MCPToolResult {
        try rejectUnknown(arguments, allowed: ["limit"])
        let session = try requireSession()
        let limit = try optionalInt(arguments["limit"], name: "limit", range: 1...10_000) ?? 200
        let document = try session.check()
        let bounded = document.bounded(to: limit)
        return try structured(
            SessionResult(session: try preparedMetadata(session), result: bounded),
            isError: document.findingCount > 0 || !document.thresholdFailures.isEmpty
        )
    }

    private func runtimeDiscover(_ arguments: [String: MCPJSONValue]) throws -> MCPToolResult {
        try rejectUnknown(arguments, allowed: ["limit"])
        let limit = try optionalInt(arguments["limit"], name: "limit", range: 1...10_000) ?? 200
        let session = try requireSession()
        let document = try session.runtimeDiscovery(limit: limit, coreDataBuildEvidencePath: coreDataBuildEvidencePath)
        return try structured(
            SessionResult(session: try preparedMetadata(session), result: document,
                coreDataBuildEvidence: session.runtimeBuildEvidenceMetadata),
            isError: document.status == "unavailable"
        )
    }

    private func requireSession() throws -> AnalysisSession {
        if let session { return session }
        let created = try makeSession()
        session = created
        return created
    }

    /// 결과를 만든 세대의 메타데이터를 쓴다. status를 다시 호출해 다른 세대를 붙이지 않는다.
    private func preparedMetadata(_ session: AnalysisSession) throws -> AnalysisSession.Metadata {
        guard let metadata = session.metadata else { throw AnalysisSessionError.unavailable }
        return metadata
    }

    private func structured<T: Encodable>(_ value: T, isError: Bool = false) throws -> MCPToolResult {
        let data = try JSONEncoder.cartographDefault().encode(value)
        let object = try JSONDecoder().decode(MCPJSONValue.self, from: data)
        guard object.isObject else { throw MCPToolFailure(message: "tool result must be a JSON object") }
        return MCPToolResult(structuredContent: object, isError: isError)
    }

    private func rejectUnknown(_ arguments: [String: MCPJSONValue], allowed: Set<String>) throws {
        guard let key = arguments.keys.sorted().first(where: { !allowed.contains($0) }) else { return }
        throw MCPToolFailure(message: "unknown argument '\(key)'")
    }

    private func requiredStrings(
        _ value: MCPJSONValue?, name: String, range: ClosedRange<Int>
    ) throws -> [String] {
        guard let value, case let .array(values) = value, range.contains(values.count) else {
            throw MCPToolFailure(message: "\(name) must contain \(range.lowerBound)...\(range.upperBound) strings")
        }
        let strings = try values.enumerated().map { index, item in
            guard case let .string(string) = item,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw MCPToolFailure(message: "\(name)[\(index)] must be a non-empty string") }
            guard string.utf8.count <= 4096 else {
                throw MCPToolFailure(message: "\(name)[\(index)] must be at most 4096 bytes")
            }
            return string
        }
        return strings
    }

    private func optionalStrings(
        _ value: MCPJSONValue?, name: String, range: ClosedRange<Int>
    ) throws -> [String]? {
        guard let value else { return nil }
        guard case let .array(values) = value, range.contains(values.count) else {
            throw MCPToolFailure(message: "\(name) must contain \(range.lowerBound)...\(range.upperBound) strings")
        }
        return try values.enumerated().map { index, item in
            guard case let .string(string) = item,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw MCPToolFailure(message: "\(name)[\(index)] must be a non-empty string") }
            guard string.utf8.count <= 4096 else {
                throw MCPToolFailure(message: "\(name)[\(index)] must be at most 4096 bytes")
            }
            return string
        }
    }

    private func optionalInt(
        _ value: MCPJSONValue?, name: String, range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value else { return nil }
        guard case let .integer(integer) = value, let result = Int(exactly: integer), range.contains(result) else {
            throw MCPToolFailure(message: "\(name) must be an integer from \(range.lowerBound) through \(range.upperBound)")
        }
        return result
    }

    private func optionalBool(_ value: MCPJSONValue?, name: String) throws -> Bool? {
        guard let value else { return nil }
        guard case let .boolean(result) = value else {
            throw MCPToolFailure(message: "\(name) must be a boolean")
        }
        return result
    }

    private func runtimeContracts(_ value: MCPJSONValue?) throws -> RuntimeContractsDocument? {
        guard let value else { return nil }
        guard case let .array(values) = value, (1...1000).contains(values.count) else {
            throw MCPToolFailure(message: "runtimeContracts must contain 1...1000 contract objects")
        }
        let allowed: Set<String> = ["id", "source", "target", "mechanism", "requiredScenarios", "expectedValue"]
        for (index, value) in values.enumerated() {
            guard case let .object(object) = value else {
                throw MCPToolFailure(message: "runtimeContracts[\(index)] must be an object")
            }
            if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw MCPToolFailure(message: "runtimeContracts[\(index)] has unknown argument '\(unknown)'")
            }
        }
        let data = try JSONEncoder.cartographDefault().encode(value)
        let contracts: [RuntimeContract]
        do {
            contracts = try JSONDecoder().decode([RuntimeContract].self, from: data)
        } catch {
            throw MCPToolFailure(message: "runtimeContracts must use the documented contract fields and value types")
        }
        let document = RuntimeContractsDocument(contracts: contracts)
        do {
            try RuntimeEvidenceStore.validateContracts(document, path: "MCP runtimeContracts")
        } catch {
            throw MCPToolFailure(message: "runtimeContracts must contain valid unique IDs and required scenarios")
        }
        return document
    }

    private static func objectSchema(
        properties: [String: MCPJSONValue] = [:], required: [String] = []
    ) -> MCPJSONValue {
        var value: [String: MCPJSONValue] = [
            "type": .string("object"), "additionalProperties": .boolean(false),
        ]
        if !properties.isEmpty { value["properties"] = .object(properties) }
        if !required.isEmpty { value["required"] = .array(required.map(MCPJSONValue.string)) }
        return .object(value)
    }

    private static func arraySchema(minimum: Int, maximum: Int) -> MCPJSONValue {
        .object([
            "type": .string("array"),
            "items": stringSchema(),
            "minItems": .integer(Int64(minimum)),
            "maxItems": .integer(Int64(maximum)),
        ])
    }

    private static func runtimeContractsSchema() -> MCPJSONValue {
        .object([
            "type": .string("array"),
            "minItems": .integer(1),
            "maxItems": .integer(1000),
            "items": .object([
                "type": .string("object"),
                "additionalProperties": .boolean(false),
                "properties": .object([
                    "id": labelSchema(),
                    "source": stringSchema(),
                    "target": stringSchema(),
                    "mechanism": .object([
                        "type": .string("string"),
                        "enum": .array(RuntimeContract.Mechanism.allCases.map { .string($0.rawValue) }),
                    ]),
                    "requiredScenarios": .object([
                        "type": .string("array"), "items": labelSchema(),
                        "minItems": .integer(1), "maxItems": .integer(100),
                        "uniqueItems": .boolean(true),
                    ]),
                    "expectedValue": stringSchema(minimum: 0),
                ]),
                "required": .array(["id", "target", "mechanism", "requiredScenarios"].map(MCPJSONValue.string)),
            ]),
        ])
    }

    private static func stringSchema(minimum: Int = 1, maximum: Int = 4096) -> MCPJSONValue {
        .object([
            "type": .string("string"), "minLength": .integer(Int64(minimum)),
            "maxLength": .integer(Int64(maximum)),
            "description": .string("At most \(maximum) UTF-8 bytes; control characters are rejected. "
                + (minimum == 0 ? "An empty value is allowed." : "Whitespace-only values are rejected.")),
        ])
    }

    private static func labelSchema() -> MCPJSONValue {
        stringSchema(maximum: 256)
    }
}

private struct SessionResult<Payload: Encodable>: Encodable {
    let session: AnalysisSession.Metadata
    let result: Payload
    var coreDataBuildEvidence: AnalysisSession.RuntimeBuildEvidenceMetadata? = nil
}
