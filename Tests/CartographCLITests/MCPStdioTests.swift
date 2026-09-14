import Foundation
@testable import cartograph
import Testing

@Suite("MCP stdio 프레이머")
struct MCPStdioTests {
    private func handler() -> MCPMessageHandler {
        MCPMessageHandler(tools: []) { _, _ in MCPToolResult() }
    }

    private func ping(id: MCPJSONValue = .integer(1)) -> Data {
        let params: MCPJSONValue = .object([
            "_meta": .object([
                "io.modelcontextprotocol/protocolVersion": .string(MCPMessageHandler.currentVersion),
                "io.modelcontextprotocol/clientCapabilities": .object([:]),
            ])
        ])
        let request: MCPJSONValue = .object([
            "jsonrpc": .string("2.0"), "id": id, "method": .string("ping"), "params": params,
        ])
        return try! JSONEncoder.cartographDefault(prettyPrinted: false).encode(request)
    }

    private func responses(for chunks: [Data]) throws -> [[String: MCPJSONValue]] {
        var index = 0
        var output: [Data] = []
        try MCPStdioRunner.run(
            readChunk: {
                guard index < chunks.count else { return nil }
                defer { index += 1 }
                return chunks[index]
            },
            writeResponse: { output.append($0) },
            handler: handler()
        )
        return try output.map {
            try JSONDecoder().decode(MCPJSONValue.self, from: $0).objectValue!
        }
    }

    @Test("고정 청크 경계와 CRLF 및 EOF 부분 줄을 처리한다")
    func handlesChunksCRLFAndFinalPartialLine() throws {
        let first = ping(id: .string("한글"))
        let second = ping(id: .integer(2))
        let input = Array(first) + [0x0D, 0x0A] + Array(second)
        let split = try #require(first.firstIndex(of: 0xED)) + 1
        let chunks = [Data(input[..<split]), Data(input[split...])]
        let responses = try responses(for: chunks)
        #expect(responses.count == 2)
        #expect(responses[0]["id"] == .string("한글"))
        #expect(responses[1]["id"] == .integer(2))
    }

    @Test("1MiB를 넘는 줄을 한 번만 거부하고 다음 요청을 계속 처리한다")
    func recoversAfterOversizedLine() throws {
        let oversized = Data(repeating: 0x78, count: MCPStdioRunner.maxLineSize + 1)
        let valid = ping(id: .integer(9))
        let responses = try responses(for: [oversized + Data("\n".utf8) + valid + Data("\n".utf8)])
        #expect(responses.count == 2)
        #expect(responses[0]["error"]?.objectValue?["code"] == .integer(-32_600))
        #expect(responses[1]["id"] == .integer(9))
    }

    @Test("빈 줄과 잘못된 UTF8도 다음 줄을 막지 않는다")
    func recoversAfterMalformedLine() throws {
        let valid = ping(id: .integer(4))
        let responses = try responses(for: [Data([0x0A, 0xFF, 0x0A]) + valid + Data("\n".utf8)])
        #expect(responses.count == 3)
        #expect(responses[0]["error"]?.objectValue?["code"] == .integer(-32_700))
        #expect(responses[1]["error"]?.objectValue?["code"] == .integer(-32_700))
        #expect(responses[2]["id"] == .integer(4))
    }
}
