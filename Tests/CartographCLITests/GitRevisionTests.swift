@testable import cartograph
import Foundation
import Testing

/// 순회 문서의 revision 은 작업 트리가 HEAD 와 같을 때만 싣는다. 실제 저장소로 확인한다.
@Suite("순회 문서의 git revision")
struct GitRevisionTests {
    @Test("분석 경로가 깨끗하면 HEAD 를, 고친 파일이나 새 파일이 있으면 nil 을 돌려준다")
    func recordsHeadOnlyWhenClean() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "App/Sources/A.swift", in: root)
        try write("x", to: "Elsewhere/notes.txt", in: root)
        try git(["add", "-A"], in: root)
        try git(["commit", "-qm", "base"], in: root)
        let head = try git(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let project = root.appendingPathComponent("App").path
        #expect(GitRevision.cleanHead(projectPath: project) == head)

        // 프로젝트 밖의 변경은 이 분석과 무관하다.
        try write("y", to: "Elsewhere/notes.txt", in: root)
        #expect(GitRevision.cleanHead(projectPath: project) == head)

        try write("let b = 2", to: "App/Sources/New.swift", in: root)
        #expect(GitRevision.cleanHead(projectPath: project) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("App/Sources/New.swift"))
        try write("let a = 3", to: "App/Sources/A.swift", in: root)
        #expect(GitRevision.cleanHead(projectPath: project) == nil)
    }

    @Test("저장소가 아니거나 커밋이 없으면 revision 을 모른다고 둔다")
    func unknownWithoutCommit() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(GitRevision.cleanHead(projectPath: plain.path) == nil)
        let empty = try makeRepository()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(GitRevision.cleanHead(projectPath: empty.path) == nil)
    }

    @Test("커밋 id 형식만 받는다")
    func acceptsObjectIDs() {
        #expect(GitRevision.isObjectID(String(repeating: "a", count: 40)))
        #expect(GitRevision.isObjectID(String(repeating: "0", count: 64)))
        #expect(!GitRevision.isObjectID(String(repeating: "A", count: 40)))
        #expect(!GitRevision.isObjectID("HEAD"))
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-rev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "."], in: root)
        try git(["config", "user.email", "t@example.com"], in: root)
        try git(["config", "user.name", "t"], in: root)
        return root
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ contents: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
