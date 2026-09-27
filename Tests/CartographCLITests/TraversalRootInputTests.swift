import ArgumentParser
@testable import cartograph
import CartographKit
import Foundation
import Testing

@Suite("impact --roots-from 입력")
struct TraversalRootInputTests {
    /// 테스트마다 새 임시 파일에 내용을 쓰고 경로를 돌려준다.
    private func file(_ contents: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-roots-\(UUID().uuidString).txt")
        try contents.write(to: url)
        return url.path
    }

    private func file(_ text: String) throws -> String { try file(Data(text.utf8)) }

    @Test("위치 인자 root 가 먼저 오고 파일 root 가 뒤에 붙으며 같은 문자열은 한 번만 쓴다")
    func mergesPositionalFirst() throws {
        let path = try file("s:C\ns:A\n# comment\ns:C\n")
        let roots = try TraversalRootInput.roots(positional: ["s:A", "s:B"], rootsFrom: path, quiet: true)
        #expect(roots == ["s:A", "s:B", "s:C"])
    }

    @Test("- 는 표준 입력에서 읽는다")
    func readsStandardInput() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("[\"s:A\", \"s:B\"]".utf8))
        try pipe.fileHandleForWriting.close()
        let roots = try TraversalRootInput.roots(
            positional: [], rootsFrom: "-", quiet: true, standardInput: pipe.fileHandleForReading)
        #expect(roots == ["s:A", "s:B"])
    }

    @Test("bridge-facts 문서의 usr 를 root 로 쓴다")
    func readsBridgeFacts() throws {
        let path = try file("""
            {"format":"bridge-facts","version":1,"facts":[{"symbol":{"usr":"s:A"}},{"symbol":{"qualifiedName":"B"}}]}
            """)
        #expect(try TraversalRootInput.roots(positional: [], rootsFrom: path, quiet: true) == ["s:A"])
    }

    @Test("제어 문자·빈 root·빈 목록·상한 초과·형식 위반·없는 파일·크기 초과는 모두 사용 오류다")
    func rejectsInvalidInputAsUsageErrors() throws {
        let tooMany = (0...TraversalRootInput.maximumRootCount).map { "s:R\($0)" }.joined(separator: "\n")
        var oversized = Data(repeating: UInt8(ascii: " "), count: TraversalRootList.maximumByteCount)
        oversized.append(contentsOf: Array("s:A".utf8))
        let cases: [(positional: [String], path: String)] = [
            ([], try file("s:A\u{1}\n")),
            ([], try file("s:A\u{85}\n")),
            ([], try file("s:A\u{2028}\n")),
            ([], try file("[\"s:A\", \"\"]")),
            ([], try file("[\"  \"]")),
            ([], try file("# only a comment\n")),
            ([], try file(tooMany)),
            (["s:Z"], try file("[1]")),
            (["s:Z"], try file(Data([0xC3, 0x28]))),
            (["s:Z"], try file(oversized)),
            (["s:Z"], FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).txt").path),
        ]
        for (positional, path) in cases {
            #expect(throws: ValidationError.self, "\(path)") {
                try TraversalRootInput.roots(positional: positional, rootsFrom: path, quiet: true)
            }
        }
    }

    @Test("합친 root 가 정확히 상한이면 받는다")
    func acceptsExactlyTheRootLimit() throws {
        let text = (1...TraversalRootInput.maximumRootCount).map { "s:R\($0)" }.joined(separator: "\n")
        let roots = try TraversalRootInput.roots(positional: [], rootsFrom: try file(text), quiet: true)
        #expect(roots.count == TraversalRootInput.maximumRootCount)
    }
}
