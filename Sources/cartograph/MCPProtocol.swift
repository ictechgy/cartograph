import Foundation

/// JSON-RPC에서 사용하는 작은 JSON 값 표현.
enum MCPJSONValue: Codable, Equatable, Sendable {
    case object([String: MCPJSONValue])
    case array([MCPJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? container.decode(Int64.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([MCPJSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: MCPJSONValue].self) { self = .object(value); return }
        throw DecodingError.typeMismatch(
            MCPJSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value")
        )
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .object(value): try value.encode(to: encoder)
        case let .array(value): try value.encode(to: encoder)
        case let .string(value): try value.encode(to: encoder)
        case let .integer(value): try value.encode(to: encoder)
        case let .number(value): try value.encode(to: encoder)
        case let .boolean(value): try value.encode(to: encoder)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

/// MCP 도구의 선언과 안전성 힌트.
struct MCPToolDefinition: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: MCPJSONValue
    let outputSchema: MCPJSONValue?
    let readOnly: Bool
    let destructive: Bool

    init(
        name: String,
        description: String,
        inputSchema: MCPJSONValue = .object(["type": .string("object")]),
        outputSchema: MCPJSONValue? = nil,
        readOnly: Bool = true,
        destructive: Bool = false
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.readOnly = readOnly
        self.destructive = destructive
    }
}

/// 도구 결과에서 사용하는 텍스트 콘텐츠.
struct MCPContent: Sendable, Equatable {
    let type: String
    let text: String

}

/// 주입된 도구 호출기가 돌려주는 결과.
struct MCPToolResult: Sendable, Equatable {
    let structuredContent: MCPJSONValue?
    let content: [MCPContent]
    let isError: Bool

    init(structuredContent: MCPJSONValue? = nil, content: [MCPContent] = [], isError: Bool = false) {
        self.structuredContent = structuredContent
        self.content = content
        self.isError = isError
    }
}

/// 주입된 도구가 에이전트에게 안전하게 전달할 수 있는 검증 오류.
struct MCPToolFailure: Error, Sendable {
    let message: String

    init(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = String((trimmed.isEmpty ? "tool validation failed" : trimmed).prefix(512))
    }
}

/// MCP JSON-RPC 요청을 처리하는 상태 보유 핸들러.
///
/// 전송 계층은 줄 구분과 입출력을 담당하고, 이 타입은 한 요청을 최대 1MiB까지 읽어
/// 검증한다. 도구 호출은 주입된 클로저로만 실행하므로 네트워크나 프로세스 실행을
/// 이 계층이 직접 수행하지 않는다.
final class MCPMessageHandler {
    typealias ToolCall = (String, MCPJSONValue) throws -> MCPToolResult

    static let currentVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2024-11-05"]
    static let maxMessageSize = 1_048_576
    static let maxResponseSize = 4 * 1024 * 1024

    private enum ProtocolMode {
        case undecided
        case modern
        case legacy(String)
    }

    private let tools: [MCPToolDefinition]
    private let toolByName: [String: MCPToolDefinition]
    private let callTool: ToolCall
    private let serverName: String
    private let serverVersion: String
    private let instructions: String?
    private var mode: ProtocolMode = .undecided
    private var didInitialize = false

    init(
        tools: [MCPToolDefinition],
        serverName: String = "cartograph",
        serverVersion: String = "dev",
        instructions: String? = nil,
        callTool: @escaping ToolCall
    ) {
        self.tools = tools.sorted { $0.name < $1.name }
        toolByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.callTool = callTool
    }

    /// JSON-RPC 요청을 처리한다. 알림이면 응답을 만들지 않는다.
    func handle(_ data: Data) -> Data? {
        guard data.count <= Self.maxMessageSize else {
            return encode(error: .invalidRequest, id: nil, message: "request exceeds 1 MiB")
        }
        let value: MCPJSONValue
        do {
            value = try JSONDecoder().decode(MCPJSONValue.self, from: data)
        } catch {
            return encode(error: .parseError, id: nil, message: "malformed JSON")
        }
        guard case let .object(object) = value else {
            return encode(error: .invalidRequest, id: nil, message: "request must be a JSON object")
        }
        // 클라이언트 응답은 서버가 답할 요청이 아니다. 상대가 이미 그 응답 ID를
        // 소유하므로 ID 형식 검사보다 먼저 무시한다.
        if object["method"] == nil, case .string("2.0")? = object["jsonrpc"],
           object["result"] != nil || object["error"] != nil {
            return nil
        }
        let idResult = requestID(from: object)
        guard case let .success(id) = idResult else {
            return encode(error: .invalidRequest, id: nil, message: "request id must be a string or integer")
        }
        guard case let .string(jsonrpc)? = object["jsonrpc"], jsonrpc == "2.0",
              case let .string(method)? = object["method"], !method.isEmpty
        else {
            return encode(error: .invalidRequest, id: id, message: "invalid JSON-RPC request")
        }
        let isNotification = object["id"] == nil
        guard object["params"].map(Self.isObjectOrNil) ?? true else {
            return responseOrNil(
                isNotification: isNotification,
                response: encode(error: .invalidRequest, id: id, message: "params must be an object")
            )
        }
        let params = object["params"]?.objectValue ?? [:]

        if method == "initialize" {
            guard case .undecided = mode else {
                return encode(error: .invalidRequest, id: id, message: "initialize was already completed")
            }
            guard !isNotification else {
                return encode(error: .invalidRequest, id: nil, message: "initialize requires a request id")
            }
            return initialize(params: params, id: id)
        }
        if method == "notifications/initialized" {
            guard !isNotification else {
                // 레거시 초기화가 성공한 뒤에만 받는 알림이다.
                switch mode {
                case .legacy:
                    guard didInitialize else { return nil }
                case .modern, .undecided:
                    return nil
                }
                return nil
            }
            return encode(error: .invalidRequest, id: id, message: "notifications/initialized is a notification")
        }
        let protocolResult = protocolForRequest(params: params, method: method)
        guard case let .success(modern) = protocolResult else {
            guard case let .failure(error) = protocolResult else { return nil }
            return responseOrNil(
                isNotification: isNotification,
                response: encode(error: error.code, id: id, message: error.message, data: error.data)
            )
        }
        if modern { mode = .modern }
        // 알림은 요청 형식만 검증하고 도구 실행은 하지 않는다.
        guard !isNotification else { return nil }
        let response: Data?
        switch method {
        case "server/discover": response = discover(id: id)
        case "ping": response = success(id: id, result: .object([:]), modern: modern)
        case "tools/list": response = toolsList(id: id, modern: modern)
        case "tools/call": response = toolsCall(params: params, id: id, modern: modern)
        default: response = encode(error: .methodNotFound, id: id, message: "method not found")
        }
        return responseOrNil(isNotification: isNotification, response: response)
    }

    /// 프레이머가 줄을 버린 뒤 돌려줄 크기 오류 응답을 만든다.
    func oversizedRequestResponse() -> Data {
        encode(error: .invalidRequest, id: nil, message: "request exceeds 1 MiB") ?? Data()
    }

    private func initialize(params: [String: MCPJSONValue], id: MCPJSONValue?) -> Data? {
        guard let requested = params["protocolVersion"]?.stringValue,
              params["capabilities"]?.isObject == true,
              let clientInfo = params["clientInfo"]?.objectValue,
              clientInfo["name"]?.stringValue?.isEmpty == false,
              clientInfo["version"]?.stringValue?.isEmpty == false
        else {
            return encode(
                error: .invalidParams,
                id: id,
                message: "protocolVersion, capabilities and clientInfo name/version are required"
            )
        }
        let negotiated = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
        mode = .legacy(negotiated)
        didInitialize = true
        var result: [String: MCPJSONValue] = [
            "protocolVersion": .string(negotiated),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return success(id: id, result: .object(result), modern: false)
    }

    private func discover(id: MCPJSONValue?) -> Data? {
        let meta: [String: MCPJSONValue] = [
            "io.modelcontextprotocol/serverInfo": .object([
                "name": .string(serverName), "version": .string(serverVersion)
            ]),
        ]
        var result: [String: MCPJSONValue] = [
            "supportedVersions": .array(([Self.currentVersion] + Self.legacyVersions).map(MCPJSONValue.string)),
            "capabilities": .object(["tools": .object([:])]),
            "_meta": .object(meta),
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return success(id: id, result: .object(result), modern: true)
    }

    private func toolsList(id: MCPJSONValue?, modern: Bool) -> Data? {
        let definitions = tools.map { tool -> MCPJSONValue in
            var value: [String: MCPJSONValue] = [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
                "annotations": .object([
                    "readOnlyHint": .boolean(tool.readOnly),
                    "destructiveHint": .boolean(tool.destructive),
                ]),
            ]
            if modern, let outputSchema = tool.outputSchema { value["outputSchema"] = outputSchema }
            return .object(value)
        }
        return success(id: id, result: .object(["tools": .array(definitions)]), modern: modern)
    }

    private func toolsCall(params: [String: MCPJSONValue], id: MCPJSONValue?, modern: Bool) -> Data? {
        guard let name = params["name"]?.stringValue, let tool = toolByName[name] else {
            return encode(error: .invalidParams, id: id, message: "unknown or missing tool")
        }
        let arguments = params["arguments"] ?? .object([:])
        guard arguments.isObject else {
            return encode(error: .invalidParams, id: id, message: "tool arguments must be an object")
        }
        do {
            let result = try callTool(tool.name, arguments)
            if modern {
                guard result.structuredContent?.isObject ?? false else {
                    return toolError(id: id, modern: true, message: nil)
                }
                var value: [String: MCPJSONValue] = [
                    "content": .array(result.content.map(Self.encodeContent)),
                    "isError": .boolean(result.isError),
                ]
                if let structured = result.structuredContent { value["structuredContent"] = structured }
                return success(id: id, result: .object(value), modern: true)
            }
            let text: String
            if let structured = result.structuredContent {
                text = try Self.compactJSON(structured)
            } else {
                text = result.content.map(\.text).joined(separator: "\n")
            }
            return success(
                id: id,
                result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "isError": .boolean(result.isError),
                ]),
                modern: false
            )
        } catch let error as MCPToolFailure {
            return toolError(id: id, modern: modern, message: error.message)
        } catch {
            return toolError(id: id, modern: modern, message: nil)
        }
    }

    private func toolError(id: MCPJSONValue?, modern: Bool, message: String?) -> Data? {
        let text = message ?? "tool execution failed"
        return success(
            id: id,
            result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "isError": .boolean(true),
            ]),
            modern: modern
        )
    }

    private func protocolForRequest(
        params: [String: MCPJSONValue],
        method: String
    ) -> Result<Bool, MCPProtocolFailure> {
        let meta = params["_meta"]?.objectValue
        switch mode {
        case .legacy:
            guard meta != nil else { return .success(false) }
            return validateModernMetadata(meta)
        case .modern:
            return validateModernMetadata(meta)
        case .undecided:
            guard method == "server/discover" || meta != nil else {
                return .failure(.init(code: .invalidParams, message: "modern request metadata is required"))
            }
            return validateModernMetadata(meta)
        }
    }

    private func validateModernMetadata(_ meta: [String: MCPJSONValue]?) -> Result<Bool, MCPProtocolFailure> {
        guard let meta,
              let version = meta["io.modelcontextprotocol/protocolVersion"]?.stringValue,
              meta["io.modelcontextprotocol/clientCapabilities"]?.isObject == true
        else {
            return .failure(.init(code: .invalidParams, message: "modern request metadata is required"))
        }
        guard version == Self.currentVersion else {
            return .failure(.init(
                code: .unsupportedVersion,
                message: "unsupported protocol version",
                data: .object([
                    "supported": .array(([Self.currentVersion] + Self.legacyVersions).map(MCPJSONValue.string)),
                    "requested": .string(version),
                ])
            ))
        }
        return .success(true)
    }

    private func requestID(from object: [String: MCPJSONValue]) -> Result<MCPJSONValue?, MCPProtocolFailure> {
        guard let value = object["id"] else { return .success(nil) }
        switch value {
        case .string, .integer: return .success(value)
        default: return .failure(.init(code: .invalidRequest, message: "request id must be a string or integer"))
        }
    }

    private func success(id: MCPJSONValue?, result: MCPJSONValue, modern: Bool) -> Data? {
        var response: [String: MCPJSONValue] = ["jsonrpc": .string("2.0"), "id": id ?? .null]
        var resultObject = result.objectValue ?? [:]
        if modern { resultObject["resultType"] = .string("complete") }
        response["result"] = .object(resultObject)
        guard let encoded = encode(.object(response)) else {
            return encode(error: .internalError, id: id, message: "could not encode response")
        }
        guard encoded.count <= Self.maxResponseSize else {
            return encode(
                error: .invalidParams,
                id: id,
                message: "response exceeds 4 MiB; reduce the query scope or limit"
            )
        }
        return encoded
    }

    private func encode(error: MCPErrorCode, id: MCPJSONValue?, message: String, data: MCPJSONValue? = nil) -> Data? {
        var errorObject: [String: MCPJSONValue] = [
            "code": .integer(Int64(error.rawValue)),
            "message": .string(message),
        ]
        if let data { errorObject["data"] = data }
        return encode(.object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object(errorObject),
        ]))
    }

    private func encode(_ value: MCPJSONValue) -> Data? {
        try? JSONEncoder.cartographDefault(prettyPrinted: false).encode(value)
    }

    private func responseOrNil(isNotification: Bool, response: Data?) -> Data? {
        isNotification ? nil : response
    }

    private static func isObjectOrNil(_ value: MCPJSONValue) -> Bool { value.isObject }

    private static func encodeContent(_ content: MCPContent) -> MCPJSONValue {
        .object(["type": .string(content.type), "text": .string(content.text)])
    }

    private static func compactJSON(_ value: MCPJSONValue) throws -> String {
        let data = try JSONEncoder.cartographDefault(prettyPrinted: false).encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

private enum MCPErrorCode: Int32 {
    case parseError = -32_700
    case invalidRequest = -32_600
    case methodNotFound = -32_601
    case internalError = -32_603
    case invalidParams = -32_602
    case unsupportedVersion = -32_022
}

private struct MCPProtocolFailure: Error {
    let code: MCPErrorCode
    let message: String
    let data: MCPJSONValue?
    init(code: MCPErrorCode, message: String, data: MCPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

extension MCPJSONValue {
    var objectValue: [String: MCPJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var arrayValue: [MCPJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}
