@testable import cartograph
import CartographConfig
import Foundation
import Testing

/// 실제 디렉터리에 써 본다.
///
/// 상수만 검사하는 테스트는 설치기가 엉뚱한 자리에 써도 전부 녹색이다. 스킬은
/// 정해진 경로에 있어야만 읽히므로, 한 칸 어긋나면 조용히 아무 일도 일어나지 않는다.
@Suite("스킬 설치")
struct SkillCommandTests {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func installedFile(under root: URL) -> URL {
        root.appendingPathComponent(AgentSkillTemplate.directory)
            .appendingPathComponent(AgentSkillTemplate.fileName)
    }

    @Test("중간 디렉터리까지 만들어 정해진 자리에 쓴다")
    func createsIntermediateDirectories() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var command = try SkillCommand.parse(["--project", root.path])
        try command.run()

        let contents = try String(contentsOf: installedFile(under: root), encoding: .utf8)
        #expect(contents == AgentSkillTemplate.markdown + "\n")
    }

    @Test("이미 있는 파일을 말없이 덮어쓰지 않는다")
    func refusesToOverwriteWithoutForce() throws {
        // 사용자가 손본 스킬을 조용히 되돌리면, 되돌아간 사실조차 드러나지 않는다.
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var first = try SkillCommand.parse(["--project", root.path])
        try first.run()
        try "손댄 내용".write(to: installedFile(under: root), atomically: true, encoding: .utf8)

        var second = try SkillCommand.parse(["--project", root.path])
        #expect(throws: (any Error).self) { try second.run() }
        #expect(try String(contentsOf: installedFile(under: root), encoding: .utf8) == "손댄 내용")

        var forced = try SkillCommand.parse(["--project", root.path, "--force"])
        try forced.run()
        #expect(try String(contentsOf: installedFile(under: root), encoding: .utf8)
            == AgentSkillTemplate.markdown + "\n")
    }
}
