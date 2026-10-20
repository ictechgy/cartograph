import CryptoKit

/// 문자열만 담은 중첩 배열을 `JSONEncoder.cartographDefault(prettyPrinted: false)` 의 인코딩과 같은 바이트로
/// SHA-256 에 흘린다.
///
/// language-traversal 의 `graphRevision` 은 그 인코딩의 해시이고, isthmus 는 이 값을 불투명 문자열로 비교한다.
/// 큰 그래프에서 행 배열과 인코딩 결과를 통째로 만들면 정점 20만·간선 196만에서 해시에만 약 0.9 GB 를 더 쓰므로,
/// 같은 바이트를 64 KiB 안팎 조각으로 해시해 값은 그대로 두고 메모리를 조각 크기로 묶는다.
///
/// 문자열 규칙은 swift-foundation `JSONWriter` 와 같다. `"`·`\` 와 U+0000–U+001F 만 이스케이프하고
/// (`\b`·`\t`·`\n`·`\f`·`\r`, 나머지는 `\u00` 뒤 소문자 16진 두 자리), `/` 는 `.withoutEscapingSlashes` 라 그대로 쓰며,
/// 그 밖의 문자는 정규화하지 않은 UTF-8 바이트 그대로다. 비압축 출력이라 공백이 없다.
struct JSONStringArrayDigest {
    /// 해시에 넘기는 조각의 기준 크기. 문자열 하나를 다 쓴 뒤 이 크기를 넘으면 넘긴다.
    static let chunkSize = 64 * 1024

    private var hasher = SHA256()
    private var buffer: [UInt8] = []
    /// 열린 배열마다 다음 원소 앞에 쉼표가 필요한지. 맨 앞 칸은 최상위 값 자리다.
    private var separatorNeeded = [false]
    /// 해시에 넘긴 조각의 바이트 수를 받는 테스트용 관측 지점.
    private let onChunk: ((Int) -> Void)?

    init(onChunk: ((Int) -> Void)? = nil) {
        self.onChunk = onChunk
        buffer.reserveCapacity(Self.chunkSize + 1024)
    }

    /// 배열을 연다.
    mutating func beginArray() {
        writeSeparator()
        buffer.append(UInt8(ascii: "["))
        separatorNeeded.append(false)
    }

    /// 가장 안쪽 배열을 닫는다.
    mutating func endArray() {
        separatorNeeded.removeLast()
        buffer.append(UInt8(ascii: "]"))
    }

    /// 문자열 원소 하나를 따옴표로 감싸 쓴다. 이스케이프할 바이트가 없으면 UTF-8 을 그대로 복사한다.
    mutating func append(_ value: String) {
        writeSeparator()
        buffer.append(UInt8(ascii: "\""))
        if value.utf8.contains(where: Self.needsEscape) {
            for byte in value.utf8 { appendEscaping(byte) }
        } else {
            buffer.append(contentsOf: value.utf8)
        }
        buffer.append(UInt8(ascii: "\""))
        if buffer.count >= Self.chunkSize { flush() }
    }

    /// 문자열 배열들을 담은 배열 하나를 쓴다.
    mutating func appendRows(_ rows: [[String]]) {
        beginArray()
        for row in rows {
            beginArray()
            row.forEach { append($0) }
            endArray()
        }
        endArray()
    }

    /// 남은 바이트를 넘기고 `sha256:` 뒤에 소문자 16진 digest 를 붙여 돌려준다.
    mutating func finalize() -> String {
        flush()
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func writeSeparator() {
        let depth = separatorNeeded.count - 1
        if separatorNeeded[depth] { buffer.append(UInt8(ascii: ",")) }
        separatorNeeded[depth] = true
    }

    private mutating func flush() {
        guard !buffer.isEmpty else { return }
        buffer.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        onChunk?(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }

    private static func needsEscape(_ byte: UInt8) -> Bool {
        byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\")
    }

    private mutating func appendEscaping(_ byte: UInt8) {
        guard Self.needsEscape(byte) else { return buffer.append(byte) }
        buffer.append(UInt8(ascii: "\\"))
        if let short = Self.shortEscapes[byte] { return buffer.append(short) }
        buffer.append(contentsOf: [UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0")])
        buffer.append(contentsOf: [Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 0x0F)]])
    }

    /// 역슬래시 뒤 한 글자로 쓰는 이스케이프. 나머지 제어 문자는 `\u00xx` 다.
    private static let shortEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "\""): UInt8(ascii: "\""), UInt8(ascii: "\\"): UInt8(ascii: "\\"),
        0x08: UInt8(ascii: "b"), 0x09: UInt8(ascii: "t"), 0x0A: UInt8(ascii: "n"),
        0x0C: UInt8(ascii: "f"), 0x0D: UInt8(ascii: "r"),
    ]

    private static let hexDigits = Array("0123456789abcdef".utf8)
}
