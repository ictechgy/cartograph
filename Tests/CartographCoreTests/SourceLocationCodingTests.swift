import CartographCore
import Foundation
import Testing

/// 합성 Codable 을 쓰던 `SourceLocation` 과 같은 모양. 공개 형식이 그대로인지 바이트로 대조한다.
private struct SynthesizedLocation: Codable {
    let path: String
    let line: Int
    let column: Int
}

@Suite("SourceLocation 직렬화")
struct SourceLocationCodingTests {
    private let locations = [
        CartographCore.SourceLocation(path: "/p/Sources/A.swift", line: 3, column: 7),
        CartographCore.SourceLocation(path: "", line: 0, column: -1),
    ]

    @Test("경로 생략 문맥이 없으면 합성 Codable 과 같은 바이트를 쓰고 읽는다")
    func matchesSynthesizedCodableWithoutContext() throws {
        // 리포트·스냅샷·교환 문서가 같은 타입을 쓴다. 캐시 전용 생략이 이 형식을 바꾸면 안 된다.
        // `.sortedKeys` 없는 인코더는 합성 Codable 끼리도 키 순서가 요소마다 달라 대조 기준이 못 된다.
        let twins = locations.map { SynthesizedLocation(path: $0.path, line: $0.line, column: $0.column) }
        let escapingSlashes = JSONEncoder()
        escapingSlashes.outputFormatting = [.sortedKeys]
        for encoder in [escapingSlashes, .cartographDefault(), .cartographDefault(prettyPrinted: false)] {
            #expect(try encoder.encode(locations) == encoder.encode(twins))
        }
        let decoded = try JSONDecoder().decode([CartographCore.SourceLocation].self, from: JSONEncoder().encode(twins))
        #expect(decoded == locations)
    }

    @Test("경로 생략 문맥이 없으면 경로 없는 위치를 거부한다")
    func requiresThePathWithoutContext() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CartographCore.SourceLocation.self, from: Data(#"{"line":1,"column":2}"#.utf8))
        }
    }

    @Test("문맥이 있으면 생략할 경로와 표기까지 같은 위치에서만 경로를 빼고 되살린다")
    func elidesOnlyTheContextPath() throws {
        let elided = "/tmp/p/A.swift"
        let values = [
            CartographCore.SourceLocation(path: elided, line: 1, column: 2),
            CartographCore.SourceLocation(path: "/private/tmp/p/A.swift", line: 3, column: 4),
        ]
        let encoder = JSONEncoder.cartographDefault(prettyPrinted: false)
        encoder.userInfo[SourceLocationPathElision.userInfoKey] = SourceLocationPathElision()
        let data = try SourceLocationPathElision.eliding(elided, in: encoder.userInfo) { try encoder.encode(values) }
        #expect(String(decoding: data, as: UTF8.self)
            == #"[{"column":2,"line":1},{"column":4,"line":3,"path":"/private/tmp/p/A.swift"}]"#)

        let decoder = JSONDecoder()
        decoder.userInfo[SourceLocationPathElision.userInfoKey] = SourceLocationPathElision()
        let decoded = try SourceLocationPathElision.eliding(elided, in: decoder.userInfo) {
            try decoder.decode([CartographCore.SourceLocation].self, from: data)
        }
        #expect(decoded == values)
    }

    @Test("항목을 마치면 경로를 다시 쓰고, 문맥 없는 인코더에서는 생략하지 않는다")
    func restoresThePreviousPathAfterTheEntry() throws {
        let location = CartographCore.SourceLocation(path: "/p/A.swift", line: 1, column: 1)
        let full = #"{"column":1,"line":1,"path":"/p/A.swift"}"#
        let encoder = JSONEncoder.cartographDefault(prettyPrinted: false)
        encoder.userInfo[SourceLocationPathElision.userInfoKey] = SourceLocationPathElision()
        let inside = try SourceLocationPathElision.eliding(location.path, in: encoder.userInfo) {
            try encoder.encode(location)
        }
        #expect(String(decoding: inside, as: UTF8.self) == #"{"column":1,"line":1}"#)
        // 이전 경로가 남으면 다음 항목의 같은 경로 위치가 경로를 잃는다.
        #expect(String(decoding: try encoder.encode(location), as: UTF8.self) == full)

        let plain = JSONEncoder.cartographDefault(prettyPrinted: false)
        let data = try SourceLocationPathElision.eliding(location.path, in: plain.userInfo) {
            try plain.encode(location)
        }
        #expect(String(decoding: data, as: UTF8.self) == full)
    }
}
