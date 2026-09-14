import Foundation
@testable import cartograph
import Testing

@Suite("MCP JSON-RPC 프로토콜")
struct MCPProtocolTests {
    private let tool = MCPToolDefinition(
        name: "impact",
        description: "Find change impact.",
        inputSchema: .object(["type": .string("object")]),
        outputSchema: .object(["type": .string("object")])
    )

    private func handler(
        call: @escaping MCPMessageHandler.ToolCall = { _, _ in
            MCPToolResult(structuredContent: .object(["ok": .boolean(true)]))
        }
    ) -> MCPMessageHandler {
        MCPMessageHandler(
            tools: [tool], serverName: "cartograph", serverVersion: "1.0", instructions: "Use tools.", callTool: call
        )
    }

    private func modernMeta(version: String = MCPMessageHandler.currentVersion, capabilities: MCPJSONValue = .object([:])) -> MCPJSONValue {
        .object([
            "_meta": .object([
                "io.modelcontextprotocol/protocolVersion": .string(version),
                "io.modelcontextprotocol/clientCapabilities": capabilities,
            ])
        ])
    }

    private func request(id: MCPJSONValue? = .integer(1), method: String, params: MCPJSONValue? = nil) -> Data {
        var object: [String: MCPJSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return try! JSONEncoder.cartographDefault().encode(MCPJSONValue.object(object))
    }

    private func modernRequest(id: MCPJSONValue? = .integer(1), method: String, extra: [String: MCPJSONValue] = [:]) -> Data {
        var params = modernMeta().objectValue ?? [:]
        params.merge(extra) { _, new in new }
        return request(id: id, method: method, params: .object(params))
    }

    private func object(_ data: Data?) -> [String: MCPJSONValue] {
        let value = try! JSONDecoder().decode(MCPJSONValue.self, from: data!)
        return value.objectValue!
    }

    @Test("modern discover는 초기화 없이 버전과 서버 메타데이터를 돌려준다")
    func modernDiscover() {
        let response = object(handler().handle(modernRequest(method: "server/discover")))
        let result = response["result"]?.objectValue
        #expect(result?["resultType"]?.stringValue == "complete")
        #expect(result?["supportedVersions"]?.arrayValue?.first?.stringValue == MCPMessageHandler.currentVersion)
        #expect(result?["capabilities"]?.objectValue?["tools"]?.objectValue != nil)
        #expect(result?["_meta"]?.objectValue?["io.modelcontextprotocol/serverInfo"]?.objectValue?["name"]?.stringValue == "cartograph")
        #expect(result?["instructions"]?.stringValue == "Use tools.")
    }

    @Test("legacy initialize는 요청한 지원 버전을 협상하고 initialized 알림에는 답하지 않는다")
    func legacyLifecycle() {
        let handler = handler()
        #expect(handler.handle(request(id: nil, method: "notifications/initialized")) == nil)
        let initialize = request(
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
            ])
        )
        let initializeResult = object(handler.handle(initialize))["result"]?.objectValue
        #expect(initializeResult?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(handler.handle(request(id: nil, method: "notifications/initialized")) == nil)
        let list = object(handler.handle(request(method: "tools/list")))
        #expect(list["result"]?.objectValue?["resultType"] == nil)
        #expect(list["result"]?.objectValue?["tools"]?.arrayValue?.count == 1)
        #expect(list["result"]?.objectValue?["tools"]?.arrayValue?.first?.objectValue?["outputSchema"] == nil)
        let missingModernCapabilities = object(handler.handle(request(method: "ping", params: .object([
            "_meta": .object([
                "io.modelcontextprotocol/protocolVersion": .string(MCPMessageHandler.currentVersion),
            ])
        ]))))
        #expect(missingModernCapabilities["error"]?.objectValue?["code"] == .integer(-32_602))
    }

    @Test("initialize는 ID가 있는 요청만 상태를 열고 initialized는 알림으로만 받는다")
    func lifecycleRequiresRequestID() {
        let handler = handler()
        let noID = object(handler.handle(request(id: nil, method: "initialize", params: .object([
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
        ]))))
        #expect(noID["error"]?.objectValue?["code"] == .integer(-32_600))
        let initializedWithID = object(handler.handle(request(method: "notifications/initialized")))
        #expect(initializedWithID["error"]?.objectValue?["code"] == .integer(-32_600))
    }

    @Test("초기화가 끝난 연결은 중복 초기화나 다른 시대 초기화를 받지 않는다")
    func rejectsRepeatedAndCrossEraInitialize() {
        let modern = handler()
        _ = modern.handle(modernRequest(method: "server/discover"))
        let modernAgain = object(modern.handle(request(method: "initialize", params: .object([
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
        ]))))
        #expect(modernAgain["error"]?.objectValue?["code"] == .integer(-32_600))

        let legacy = handler()
        let params: MCPJSONValue = .object([
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
        ])
        _ = legacy.handle(request(method: "initialize", params: params))
        let legacyAgain = object(legacy.handle(request(id: .integer(2), method: "initialize", params: params)))
        #expect(legacyAgain["error"]?.objectValue?["code"] == .integer(-32_600))
    }

    @Test("불완전한 initialize는 레거시 상태를 열지 않는다")
    func invalidInitializeDoesNotAdvanceLifecycle() {
        let handler = handler()
        let invalid = object(handler.handle(request(
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:])])
        )))
        #expect(invalid["error"]?.objectValue?["code"] == .integer(-32_602))
        let next = object(handler.handle(request(method: "tools/list")))
        #expect(next["error"]?.objectValue?["code"] == .integer(-32_602))
    }

    @Test("클라이언트 응답 프레임과 유효한 알림에는 서버가 답하지 않는다")
    func ignoresResponseFramesAndNotifications() {
        let handler = handler()
        let malformedNoID = try! JSONEncoder.cartographDefault().encode(MCPJSONValue.object([
            "jsonrpc": .string("2.0"), "params": .object([:]),
        ]))
        #expect(object(handler.handle(malformedNoID))["error"]?.objectValue?["code"] == .integer(-32_600))
        let clientResponse = try! JSONEncoder.cartographDefault().encode(MCPJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .integer(7), "result": .object([:]),
        ]))
        #expect(handler.handle(clientResponse) == nil)
        #expect(handler.handle(modernRequest(id: nil, method: "ping")) == nil)
        #expect(handler.handle(request(id: nil, method: "unknown")) == nil)
    }

    @Test("도구 호출 알림은 메타데이터만 검증하고 클로저를 실행하지 않는다")
    func toolNotificationDoesNotExecute() {
        var callCount = 0
        let handler = MCPMessageHandler(tools: [tool]) { _, _ in
            callCount += 1
            return MCPToolResult(structuredContent: .object(["ok": .boolean(true)]))
        }
        #expect(handler.handle(modernRequest(id: nil, method: "tools/call", extra: ["name": .string("impact")])) == nil)
        #expect(callCount == 0)
    }

    @Test("modern 요청은 각 요청의 메타데이터를 독립적으로 검증한다")
    func modernMetadataRequiredPerRequest() {
        let handler = handler()
        _ = handler.handle(modernRequest(method: "server/discover"))
        let missing = object(handler.handle(request(method: "ping")))
        #expect(missing["error"]?.objectValue?["code"] == .integer(-32_602))
        let unsupported = object(handler.handle(modernRequest(method: "ping", extra: [
            "_meta": .object([
                "io.modelcontextprotocol/protocolVersion": .string("2025-11-25"),
                "io.modelcontextprotocol/clientCapabilities": .object([:]),
            ])
        ])))
        #expect(unsupported["error"]?.objectValue?["code"] == .integer(-32_022))
        #expect(unsupported["error"]?.objectValue?["data"]?.objectValue?["requested"]?.stringValue == "2025-11-25")
    }

    @Test("tools 호출 성공은 modern 구조화 결과를, legacy는 compact 텍스트만 내보낸다")
    func toolResultShapes() {
        let modern = handler()
        let modernResult = object(modern.handle(modernRequest(method: "tools/call", extra: [
            "name": .string("impact"), "arguments": .object(["query": .string("Foo")]),
        ])))
        let payload = modernResult["result"]?.objectValue
        #expect(payload?["resultType"]?.stringValue == "complete")
        #expect(payload?["structuredContent"]?.objectValue?["ok"] == .boolean(true))
        #expect(payload?["content"]?.arrayValue?.isEmpty == true)

        let legacy = handler()
        _ = legacy.handle(request(method: "initialize", params: .object([
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
        ])))
        let legacyResult = object(legacy.handle(request(method: "tools/call", params: .object([
            "name": .string("impact"), "arguments": .object(["query": .string("Foo")]),
        ]))))
        let content = legacyResult["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue
        #expect(content?["type"]?.stringValue == "text")
        #expect(content?["text"]?.stringValue == #"{"ok":true}"#)
        #expect(legacyResult["result"]?.objectValue?["structuredContent"] == nil)
    }

    @Test("프로토콜 오류와 알림은 구분하고 도구 오류 뒤에도 다음 요청을 처리한다")
    func errorsNotificationsAndRecovery() {
        let handler = handler { name, _ in
            if name == "impact" { throw MCPToolFailure(message: "impact input is invalid") }
            return MCPToolResult(structuredContent: .object(["ok": .boolean(true)]))
        }
        let unknownMethod = object(handler.handle(modernRequest(method: "unknown")))
        #expect(unknownMethod["error"]?.objectValue?["code"] == .integer(-32_601))
        #expect(handler.handle(modernRequest(id: nil, method: "unknown")) == nil)
        let toolFailure = object(handler.handle(modernRequest(method: "tools/call", extra: ["name": .string("impact")])))
        #expect(toolFailure["result"]?.objectValue?["isError"] == .boolean(true))
        #expect(toolFailure["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == "impact input is invalid")
        let next = object(handler.handle(modernRequest(method: "ping")))
        #expect(next["result"]?.objectValue?["resultType"]?.stringValue == "complete")
    }

    @Test("잘못된 JSON-RPC 요청은 고정된 오류를 내고 ID 형식은 보존한다")
    func malformedRequestsAndIDs() {
        let handler = handler()
        let malformed = object(handler.handle(Data("{oops".utf8)))
        #expect(malformed["error"]?.objectValue?["code"] == .integer(-32_700))
        for value in [MCPJSONValue.boolean(true), .null, .number(1.5)] {
            let response = object(handler.handle(request(id: value, method: "ping")))
            #expect(response["error"]?.objectValue?["code"] == .integer(-32_600))
        }
        let stringID = object(handler.handle(modernRequest(id: .string("request-7"), method: "ping")))
        #expect(stringID["id"] == .string("request-7"))
    }

    @Test("도구 목록과 응답 JSON은 키 순서가 결정적이다")
    func outputIsDeterministic() {
        let first = handler().handle(modernRequest(method: "tools/list"))
        let second = handler().handle(modernRequest(method: "tools/list"))
        #expect(first == second)
        #expect(String(decoding: first!, as: UTF8.self).contains("\"annotations\""))
        #expect(!String(decoding: first!, as: UTF8.self).contains("\n"))
    }

    @Test("응답이 상한을 넘으면 데이터 손실 없이 작은 오류를 반환한다")
    func rejectsOversizedResponse() {
        let huge = String(repeating: "x", count: MCPMessageHandler.maxResponseSize)
        let handler = MCPMessageHandler(tools: [tool]) { _, _ in
            MCPToolResult(structuredContent: .object(["payload": .string(huge)]))
        }
        let response = object(handler.handle(modernRequest(method: "tools/call", extra: ["name": .string("impact")])))
        #expect(response["error"]?.objectValue?["code"] == .integer(-32_602))
        #expect(response["error"]?.objectValue?["message"]?.stringValue?.contains("reduce") == true)
        #expect(try! JSONEncoder.cartographDefault().encode(MCPJSONValue.object(response)).count < MCPMessageHandler.maxResponseSize)
    }
}
