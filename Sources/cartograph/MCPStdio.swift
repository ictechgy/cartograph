import Foundation
import Darwin

/// MCP JSON-RPC 줄을 고정 크기 청크로 읽어 처리한다.
struct MCPStdioRunner {
    static let chunkSize = 4096
    static let maxLineSize = MCPMessageHandler.maxMessageSize

    /// 주입된 청크 읽기·응답 쓰기로 stdio 처리를 실행한다.
    static func run(
        readChunk: () throws -> Data?,
        writeResponse: (Data) throws -> Void,
        handler: MCPMessageHandler
    ) throws {
        var line: [UInt8] = []
        line.reserveCapacity(maxLineSize)
        var discardingOversize = false

        func process(_ bytes: [UInt8]) throws {
            for byte in bytes {
                if discardingOversize {
                    if byte == 0x0A {
                        discardingOversize = false
                        line.removeAll(keepingCapacity: true)
                        try writeResponse(handler.oversizedRequestResponse())
                    }
                    continue
                }
                if byte == 0x0A {
                    try emit(line, writeResponse: writeResponse, handler: handler)
                    line.removeAll(keepingCapacity: true)
                    continue
                }
                guard line.count < maxLineSize else {
                    discardingOversize = true
                    line.removeAll(keepingCapacity: true)
                    continue
                }
                line.append(byte)
            }
        }

        while let chunk = try readChunk(), !chunk.isEmpty {
            try process(Array(chunk))
        }
        if !line.isEmpty, !discardingOversize {
            try emit(line, writeResponse: writeResponse, handler: handler)
        } else if discardingOversize {
            try writeResponse(handler.oversizedRequestResponse())
        }
    }

    /// 표준 파일 핸들을 연결해 줄 단위 서버를 실행한다.
    static func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        handler: MCPMessageHandler
    ) throws {
        try run(
            readChunk: { try readChunk(from: input) },
            writeResponse: { data in
                try output.write(contentsOf: data)
                try output.write(contentsOf: Data("\n".utf8))
            },
            handler: handler
        )
    }

    private static func emit(
        _ bytes: [UInt8],
        writeResponse: (Data) throws -> Void,
        handler: MCPMessageHandler
    ) throws {
        var request = bytes
        if request.last == 0x0D { request.removeLast() }
        if let response = handler.handle(Data(request)) { try writeResponse(response) }
    }

    private static func readChunk(from input: FileHandle) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(input.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            throw NSError(domain: "CartographMCP", code: Int(errno))
        }
    }
}
