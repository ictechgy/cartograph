import CartographCore
import Foundation
@testable import cartograph
import Testing

@Suite("MCP JSON 판독")
struct MCPJSONReadingTests {
    private static let modernMeta = #""_meta":{"io.modelcontextprotocol/clientCapabilities":{},"#
        + #""io.modelcontextprotocol/protocolVersion":""# + MCPMessageHandler.currentVersion + #""}"#

    /// 인자를 그대로 돌려주는 도구. 요청이 어떤 값으로 읽혔는지가 응답 바이트에 그대로 드러난다.
    private func echoHandler() -> MCPMessageHandler {
        MCPMessageHandler(tools: [MCPToolDefinition(name: "echo", description: "Echo arguments.")]) { _, arguments in
            MCPToolResult(structuredContent: .object(["arguments": arguments]))
        }
    }

    private static func echoCall(_ arguments: String) -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"# + modernMeta
            + #","name":"echo","arguments":"# + arguments + "}}"
    }

    private static func ping(id: String, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":"# + id + #","method":"ping","params":{"# + modernMeta + extra + "}}"
    }

    private static func echoed(_ arguments: String) -> String {
        #"{"id":1,"jsonrpc":"2.0","result":{"content":[],"isError":false,"resultType":"complete","#
            + #""structuredContent":{"arguments":"# + arguments + "}}}"
    }

    private static func pong(id: String) -> String {
        #"{"id":"# + id + #","jsonrpc":"2.0","result":{"resultType":"complete"}}"#
    }

    private static func failure(_ code: Int, _ message: String, id: String = "null") -> String {
        #"{"error":{"code":"# + "\(code)" + #","message":""# + message + #""},"id":"# + id + #","jsonrpc":"2.0"}"#
    }

    /// 기존 디코더는 중첩마다 호출 스택을 쓰고, 깊은 값을 풀어 놓는 해제도 재귀다. 디버그 빌드에서 수백 단을
    /// 다루려면 테스트 스레드(512 KB)보다 넉넉한 스택이 필요하다.
    private func onLargeStack<Value>(_ body: @escaping @Sendable () -> Value) -> Value {
        let box = LargeStackResult<Value>()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            finished.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        finished.wait()
        return box.value!
    }

    /// 기존 Codable 경로. 판독기는 이 결과와 값뿐 아니라 다시 인코딩한 바이트(키의 원래 표기)까지 같아야 한다.
    private func legacy(_ data: Data) -> MCPJSONValue? {
        try? JSONDecoder().decode(MCPJSONValue.self, from: data)
    }

    /// 두 경로가 같은 값을 내거나 함께 거절하면 참이다. 거절의 이유는 비교하지 않는다(요청에서는 둘 다 parse error).
    private func agrees(_ data: Data) -> Bool {
        let expected = legacy(data)
        let actual = try? MCPJSONReader.parse(data)
        guard expected == actual else { return false }
        guard let expected, let actual else { return true }
        let encoder = JSONEncoder.cartographDefault(prettyPrinted: false)
        return (try? encoder.encode(expected)) == (try? encoder.encode(actual))
    }

    @Test("요청 해독은 숫자·문자열·중복 키·인코딩 경계에서 기존 응답 바이트를 그대로 낸다")
    func requestDecodingKeepsResponseBytes() {
        // 기대 바이트는 Codable 디코더로 요청을 읽던 구현에서 그대로 받아 적었다. Foundation 판마다 답이
        // 달라질 수 있는 표기(2^53 이상의 정수 변환, 언더플로, 끝 쉼표)는 실행 중인 기존 디코더와 직접
        // 비교하는 판독기 테스트가 맡는다.
        let deep = String(repeating: "[", count: 64) + "1" + String(repeating: "]", count: 64)
        let invalidID = "request id must be a string or integer"
        let cases: [(String, [UInt8], String?)] = [
            ("numbers", Array(Self.echoCall(#"{"n":[1,1.0,1e2,1E+2,-0,-0.0,0.25,9223372036854775807,"#
                + #"9223372036854775808,0.1234567890123456789012345,4.9e-324,true,false,0,1,null]}"#).utf8),
             Self.echoed(#"{"n":[1,1,100,100,0,0,0.25,9223372036854775807,9.223372036854776e+18,"#
                + #"0.12345678901234568,5e-324,true,false,0,1,null]}"#)),
            ("strings", Array(Self.echoCall(#"{"s":["\u00e9","e\u0301","\ud83d\ude00","a\u0000b","#
                + #""\"\\\/\b\f\n\r\t","\#u{FEFF}raw","\ufeffescaped","한글",""]}"#).utf8),
             Self.echoed(#"{"s":["\#u{E9}","e\#u{301}","\#u{1F600}","a\u0000b","\"\\/\b\f\n\r\t","#
                + #""\#u{FEFF}raw","\#u{FEFF}escaped","한글",""]}"#)),
            ("duplicates", Array(Self.echoCall(#"{"a":1,"a":2,"\u00e9":1,"e\u0301":2,"b":{"x":1},"b":"\ud800","#
                + #""c":[],"d":{}}"#).utf8), Self.echoed(#"{"a":1,"b":{"x":1},"c":[],"d":{},"\#u{E9}":1}"#)),
            ("nested", Array(Self.echoCall(#"{"x":"# + deep + "}").utf8), Self.echoed(#"{"x":"# + deep + "}")),
            ("integral numbers", Array(Self.echoCall(#"{"limit":1.0,"depth":2e0}"#).utf8),
             Self.echoed(#"{"depth":2,"limit":1}"#)),
            ("id 1.0", Array(Self.ping(id: "1.0").utf8), Self.pong(id: "1")),
            ("id 1e2", Array(Self.ping(id: "1e2").utf8), Self.pong(id: "100")),
            ("id -0", Array(Self.ping(id: "-0").utf8), Self.pong(id: "0")),
            ("id Int64.max", Array(Self.ping(id: "9223372036854775807").utf8), Self.pong(id: "9223372036854775807")),
            ("id Int64.max + 1", Array(Self.ping(id: "9223372036854775808").utf8), Self.failure(-32_600, invalidID)),
            ("id true", Array(Self.ping(id: "true").utf8), Self.failure(-32_600, invalidID)),
            ("id null", Array(Self.ping(id: "null").utf8), Self.failure(-32_600, invalidID)),
            ("id 0.5", Array(Self.ping(id: "0.5").utf8), Self.failure(-32_600, invalidID)),
            ("id with leading BOM", Array(Self.ping(id: "\"\u{FEFF}request\"").utf8),
             Self.pong(id: "\"\u{FEFF}request\"")),
            ("id with leading zero", Array(Self.ping(id: "01").utf8), Self.failure(-32_700, "malformed JSON")),
            ("method with leading BOM",
             Array((#"{"jsonrpc":"2.0","id":2,"method":"\#u{FEFF}ping","params":{"# + Self.modernMeta + "}}").utf8),
             Self.failure(-32_601, "method not found", id: "2")),
            ("duplicate id", Array((#"{"jsonrpc":"2.0","id":3,"id":"x","method":"ping","params":{"#
                + Self.modernMeta + "}}").utf8), Self.pong(id: "3")),
            ("duplicate method", Array((#"{"jsonrpc":"2.0","id":4,"method":"ping","method":"tools/list","params":{"#
                + Self.modernMeta + "}}").utf8), Self.pong(id: "4")),
            // 맨 앞 U+FEFF가 붙은 키는 "id"가 아니므로 알림이다. 그 글자를 지우는 파서는 여기서 응답을 낸다.
            ("key with leading BOM", Array((#"{"jsonrpc":"2.0","\#u{FEFF}id":5,"method":"ping","params":{"#
                + Self.modernMeta + "}}").utf8), nil),
            ("too deep", Array(Self.echoCall(#"{"x":"# + String(repeating: "[", count: 600)
                + String(repeating: "]", count: 600) + "}").utf8), Self.failure(-32_700, "malformed JSON")),
            ("garbage", Array("{oops".utf8), Self.failure(-32_700, "malformed JSON")),
            ("two values", Array("[1 2]".utf8), Self.failure(-32_700, "malformed JSON")),
            ("empty", [], Self.failure(-32_700, "malformed JSON")),
            ("trailing text", Array((Self.ping(id: "6") + " x").utf8), Self.failure(-32_700, "malformed JSON")),
            ("top-level array", Array("[1]".utf8), Self.failure(-32_600, "request must be a JSON object")),
            ("top-level number", Array("1".utf8), Self.failure(-32_600, "request must be a JSON object")),
            ("top-level string", Array("\"x\"".utf8), Self.failure(-32_600, "request must be a JSON object")),
            ("top-level null", Array("null".utf8), Self.failure(-32_600, "request must be a JSON object")),
            ("unknown method", Array((#"{"jsonrpc":"2.0","id":7,"method":"nope","params":{"#
                + Self.modernMeta + "}}").utf8), Self.failure(-32_601, "method not found", id: "7")),
            ("notification",
             Array((#"{"jsonrpc":"2.0","method":"ping","params":{"# + Self.modernMeta + "}}").utf8), nil),
            ("client response", Array(#"{"jsonrpc":"2.0","id":8,"result":{}}"#.utf8), nil),
            ("UTF-8 BOM", [0xEF, 0xBB, 0xBF] + Array(Self.ping(id: "9").utf8), Self.pong(id: "9")),
            ("UTF-16LE", Self.ping(id: "10").utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }, Self.pong(id: "10")),
        ]
        let handler = echoHandler()
        for (label, request, expected) in cases {
            let response = handler.handle(Data(request))
            #expect(response == expected.map { Data($0.utf8) }, "\(label)")
        }
    }

    @Test("깊고 넓게 중첩된 인자가 붙은 요청도 해독에 서버를 오래 묶지 않고 같은 응답을 받는다")
    func deepAndWideRequestIsAnsweredQuickly() {
        // 깊이 500 × 폭 100인 약 100 KB 요청. 값마다 실패한 해독 시도가 그 깊이만큼의 codingPath를 만들던 이전
        // 구현은 이 요청 하나에 디버그 빌드에서 11초, 릴리스에서 수 초를 썼다. 지금은 입력 크기에 비례한다.
        let siblings = Array(repeating: "0", count: 99).joined(separator: ",")
        let nested = String(repeating: "[" + siblings + ",", count: 500) + "0" + String(repeating: "]", count: 500)
        let request = Data(Self.ping(id: "11", extra: #","x":"# + nested).utf8)
        let (response, elapsed) = onLargeStack { [self] in
            let clock = ContinuousClock()
            let start = clock.now
            let response = echoHandler().handle(request)
            return (response, clock.now - start)
        }
        #expect(response == Data(Self.pong(id: "11").utf8))
        #expect(elapsed < .seconds(3))
    }

    @Test("판독기는 숫자 표기마다 기존 디코더와 같은 종류와 값을 낸다")
    func numbersMatchCodableDecoder() throws {
        let digitRuns = [
            "0", "1", "9", "10", "007", "9007199254740993", "4611686018427387905", "9223372036854775807",
            "9223372036854775808", "12345678901234567890",
        ]
        var texts: [String] = []
        for sign in ["", "-"] {
            for digits in digitRuns {
                for fraction in ["", ".", ".0", ".5", ".000000000000000000001", ".99999999999999999999"] {
                    texts += ["", "e", "e+", "e0", "E+2", "e-3", "e19", "e-400", "e400"].map {
                        sign + digits + fraction + $0
                    }
                }
            }
        }
        for text in texts {
            #expect(agrees(Data(text.utf8)), "\(text)")
            #expect(agrees(Data("[\(text)]".utf8)), "[\(text)]")
        }
        // 정수와 실수·불리언의 구분은 기대 값도 직접 적어 고정한다. 1.0은 지금도 정수다.
        #expect(try MCPJSONReader.parse(Data("1.0".utf8)) == .integer(1))
        #expect(try MCPJSONReader.parse(Data("0.25".utf8)) == .number(0.25))
        #expect(try MCPJSONReader.parse(Data("0.1234567890123456789012345".utf8)) == .number(0.12345678901234568))
        #expect(throws: (any Error).self) { try MCPJSONReader.parse(Data("-1e400".utf8)) }
        #expect(try MCPJSONReader.parse(Data("[true,1,false,0]".utf8))
            == .array([.boolean(true), .integer(1), .boolean(false), .integer(0)]))
    }

    @Test("판독기는 JSONEncoder가 쓴 실수를 기존 디코더와 같은 값으로 되읽는다")
    func doublesRoundTripLikeCodableDecoder() throws {
        // 0.0039719409808057805는 JSONSerialization이 1 ulp 다르게 읽는 값이다.
        var generator = SeededGenerator(state: 42)
        var values: [Double] = [0.1, 1.0 / 3, 0.0039719409808057805, 5e-324, .greatestFiniteMagnitude, 1e15, 0x1p60]
        while values.count < 20_000 {
            let value = Double(bitPattern: generator.next())
            if value.isFinite { values.append(value) }
        }
        let data = try JSONEncoder.cartographDefault(prettyPrinted: false).encode(values)
        #expect(agrees(data))
    }

    @Test("판독기는 문자열 맨 앞 U+FEFF와 이스케이프를 기존 디코더처럼 보존한다")
    func stringsMatchCodableDecoder() throws {
        let texts = [
            "\"\u{FEFF}raw\"", #""\ufeffescaped""#, #""\uFEFF""#, "\"a\u{FEFF}b\"", #""\ud83d\ude00""#, #""a\u0000b""#,
            #""\"\\\/\b\f\n\r\t""#, "\"한글 é 😀\"", "\"\u{FFFF}\u{10FFFF}\"", #""\ud800""#, #""\udc00""#,
            #""\ud800x""#,
            #""\x""#, "\"\t\"", "\"\n\"", "[\"\u{FEFF}k\",\"\u{FEFF}\"]", "{\"\u{FEFF}k\":1,\"k\":2}",
        ]
        for text in texts {
            #expect(agrees(Data(text.utf8)), "\(text)")
        }
        #expect(agrees(Data([0x22, 0xFF, 0x22])))
        #expect(agrees(Data([0x22, 0xC0, 0xAF, 0x22])))
        #expect(try MCPJSONReader.parse(Data("\"\u{FEFF}raw\"".utf8)) == .string("\u{FEFF}raw"))
        #expect(try MCPJSONReader.parse(Data(#"{"\ufeffk":1}"#.utf8)) == .object(["\u{FEFF}k": .integer(1)]))
    }

    @Test("판독기는 중복 키에서 앞의 값을 남기고 버려진 값의 오류는 문제 삼지 않는다")
    func duplicateKeysMatchCodableDecoder() throws {
        let texts = [
            #"{"a":1,"a":2}"#, #"{"a":{"x":1},"a":[1]}"#, #"{"\u00e9":1,"e\u0301":2}"#, #"{"e\u0301":2,"\u00e9":1}"#,
            #"{"\u212a":1,"K":2}"#, #"{"a":1,"a":"\ud800"}"#, #"{"a":1,"a":01}"#, #"{"a":1,"a":{"\ud800":1}}"#,
            #"{"a":1,"\ud800":2}"#, #"{"a":"\ud800","a":1}"#, #"{"k":[1,{"k":2,"k":[3]}],"k":4}"#, #"{"":1,"":2}"#,
        ]
        for text in texts {
            #expect(agrees(Data(text.utf8)), "\(text)")
        }
        #expect(try MCPJSONReader.parse(Data(#"{"a":1,"a":"\ud800"}"#.utf8)) == .object(["a": .integer(1)]))
        #expect(throws: (any Error).self) { try MCPJSONReader.parse(Data(#"{"a":1,"\ud800":2}"#.utf8)) }
    }

    @Test("판독기는 형식이 틀린 문서를 기존 디코더처럼 거절하고 받던 형식은 계속 받는다")
    func syntaxMatchesCodableDecoder() {
        let texts = [
            "", "   ", "{oops", "[1 2]", "{\"a\" 1}", "{a:1}", "[1,]", "{\"a\":1,}", "[,]", "[1,,2]", "{,\"a\":1}",
            "'x'", "NaN", "Infinity", "/*c*/1", "[nul]", "[tru]", "[True]", "[1a]", "[- 1]", "{\"a\":1} x",
            "{\"a\":1}{\"b\":2}", " {\"a\":1} ", "\r\n[\t1\r\n]\r\n",
            "[1,\u{FEFF}2]", "[1,\u{0C}2]", "[1]\u{0}", "\u{0}[1]",
            "[[],[[]],{}]", "{\"a\":{\"b\":{\"c\":[1,2,{\"d\":null}]}}}", "[\"\\u12\"]",
        ]
        for text in texts {
            #expect(agrees(Data(text.utf8)), "\(text.debugDescription)")
        }
    }

    @Test("판독기는 BOM과 UTF-16·UTF-32 문서를 기존 디코더와 같은 인코딩으로 읽는다")
    func textEncodingsMatchCodableDecoder() {
        let document = #"{"a":[1,"é😀",{"b":null}],"c":true}"#
        let utf16 = Array(document.utf16)
        let scalars = document.unicodeScalars.map(\.value)
        let little16 = utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let big16 = utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        let little32 = scalars.flatMap { value in (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        let big32 = scalars.flatMap { value in (0..<4).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) } }
        let inputs: [[UInt8]] = [
            [0xEF, 0xBB, 0xBF] + Array(document.utf8), little16, big16, [0xFF, 0xFE] + little16, [0xFE, 0xFF] + big16,
            little32, big32, [0xFF, 0xFE, 0, 0] + little32, [0, 0, 0xFE, 0xFF] + big32, [0xFE, 0xFF, 0, 0] + little32,
            little16 + [0x20], [0x00, 0x31], [0x31, 0x00], [0xFF, 0xFE], [0xEF, 0xBB, 0xBF], [0xEF, 0xBB, 0xBF, 0x31],
            [0, 0, 0, 0x31], [0x31, 0, 0, 0], [0x00], [0x00, 0x00],
        ]
        for bytes in inputs {
            #expect(agrees(Data(bytes)), "\(bytes.prefix(6))")
        }
    }

    @Test("판독기는 기존 디코더와 같은 512단에서 중첩을 끊는다")
    func nestingLimitMatchesCodableDecoder() throws {
        func nested(_ depth: Int) -> Data {
            Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        }
        for depth in [511, 512, 513, 100_000] {
            let data = nested(depth)
            let matches = onLargeStack { [self] in agrees(data) }
            #expect(matches, "depth \(depth)")
        }
        let deepest = nested(512)
        let parsedDeepest = onLargeStack { (try? MCPJSONReader.parse(deepest)) != nil }
        #expect(parsedDeepest)
        #expect(throws: (any Error).self) { try MCPJSONReader.parse(nested(513)) }
    }

    @Test("판독기는 무작위 문서와 바이트 변형에서도 기존 디코더와 같은 답을 낸다")
    func randomDocumentsMatchCodableDecoder() {
        var generator = SeededGenerator(state: 1234)
        let mutations: [UInt8] = [0x00, 0x09, 0x0A, 0x20, 0x22, 0x2C, 0x2D, 0x2E, 0x30, 0x3A, 0x45, 0x5B, 0x5C, 0x5D,
                                  0x65, 0x6E, 0x74, 0x75, 0x7B, 0x7D, 0x80, 0xC3, 0xED, 0xEF, 0xFE, 0xFF]
        for index in 0..<3_000 {
            var bytes = Array(RandomJSON.document(&generator).utf8)
            #expect(agrees(Data(bytes)), "document \(index)")
            let position = Int(generator.next() % UInt64(bytes.count + 1))
            let byte = mutations[Int(generator.next() % UInt64(mutations.count))]
            if generator.next() % 2 == 0 || position == bytes.count {
                bytes.insert(byte, at: position)
            } else {
                bytes[position] = byte
            }
            #expect(agrees(Data(bytes)), "mutation \(index)")
        }
    }
}

/// 넉넉한 스택 스레드가 결과를 돌려주는 칸. 세마포어가 쓰기와 읽기의 순서를 보장한다.
private final class LargeStackResult<Value>: @unchecked Sendable {
    var value: Value?
}

/// 테스트를 결정적으로 만드는 고정 씨앗 난수(SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// 숫자·문자열·중복 키·끝 쉼표의 경계를 섞은 작은 JSON 문서를 만든다.
private enum RandomJSON {
    private static let fragments = [
        "a", "é", "e\\u0301", "한", "😀", "\\u0000", "\\\"", "\\\\", "\\/", " ", "\u{2028}", "\u{FEFF}", "\\ufeff",
        "\u{212A}", "K", "\u{FFFF}", "\\n", "\\ud83d\\ude00", "\\ud800", "\t", "\\x",
    ]
    private static let scalars = [
        "null", "true", "false", "0", "-0", "1.0", "1e2", "0.1", "12345678901234567890", "1e400", "01", "1.",
        "-9223372036854775809", "9007199254740993.0", "4.9e-324",
    ]
    private static let keys = ["\"a\"", "\"b\"", "\"\\u00e9\"", "\"e\\u0301\"", "\"\u{FEFF}a\"", "\"\\ud800\""]

    static func document(_ generator: inout SeededGenerator, depth: Int = 0) -> String {
        switch generator.next() % (depth > 5 ? 2 : 4) {
        case 0: return scalars[Int(generator.next() % UInt64(scalars.count))]
        case 1: return string(&generator)
        case 2:
            let items = (0..<Int(generator.next() % 4)).map { _ in document(&generator, depth: depth + 1) }
            return "[" + items.joined(separator: ",") + (generator.next() % 8 == 0 ? "," : "") + "]"
        default:
            let members = (0..<Int(generator.next() % 4)).map { _ -> String in
                let key = generator.next() % 2 == 0
                    ? keys[Int(generator.next() % UInt64(keys.count))] : string(&generator)
                return key + ":" + document(&generator, depth: depth + 1)
            }
            return "{" + members.joined(separator: ",") + (generator.next() % 8 == 0 ? "," : "") + "}"
        }
    }

    private static func string(_ generator: inout SeededGenerator) -> String {
        let count = Int(generator.next() % 5)
        let body = (0..<count).map { _ in fragments[Int(generator.next() % UInt64(fragments.count))] }
        return "\"" + body.joined() + "\""
    }
}
