@testable import cartograph
import CartographCore
import Foundation
import Testing

/// 실제 git 저장소를 만들어 확인한다.
///
/// 이 계층의 결함은 전부 "보고가 조용히 좁혀져 문제 없음을 출력하는" 방향으로
/// 실패한다. 문자열 조작만으로는 재현되지 않으므로 진짜 저장소가 필요하다.
@Suite("변경 파일 목록")
struct ChangedFilesTests {
    /// 임시 디렉터리는 심볼릭 링크 뒤에 있다. git 은 `/private/var/...` 를
    /// 돌려주는데 Foundation 의 정규화는 오히려 `/private` 을 떼어 `/var/...` 로
    /// 만든다. 두 표기를 직접 비교하면 안 되고, 실제 비교는 `ReportScope` 가
    /// 양쪽을 같은 방식으로 정규화해 수행한다. 테스트도 같은 기준으로 본다.
    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try run(["init", "-q", "."], in: root)
        try run(["config", "user.email", "t@example.com"], in: root)
        try run(["config", "user.name", "t"], in: root)
        return root
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) throws -> String {
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
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("커밋된 변경, 미커밋 변경, 새 파일을 모두 찾는다")
    func findsEveryKindOfChange() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "Sources/Base.swift", in: root)
        try write("let t = 1", to: "Sources/Tracked.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        try write("let c = 2", to: "Sources/Committed.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "second"], in: root)
        // 추적 파일을 고치고 커밋하지 않는다. 미커밋 변경의 가장 흔한 형태다.
        try write("let t = 2", to: "Sources/Tracked.swift", in: root)
        try write("let n = 3", to: "Sources/Untracked.swift", in: root)

        let changed = try ChangedFiles.since(base, workingDirectory: root.path)
        let names = Set(changed.map { ($0 as NSString).lastPathComponent })
        #expect(names.contains("Committed.swift"))
        #expect(names.contains("Tracked.swift"))
        #expect(names.contains("Untracked.swift"))
        #expect(!names.contains("Base.swift"))
    }

    @Test("하위 디렉터리에서 실행해도 저장소 루트 기준으로 맞춘다")
    func resolvesPathsAgainstTheRepositoryRoot() throws {
        // `ls-files` 는 기본적으로 실행 디렉터리 기준 상대 경로를 낸다. 그대로
        // 루트에 이어 붙이면 존재하지 않는 경로가 되어 발견이 전부 숨겨진다.
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "pkg/Sources/Base.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        try write("let n = 1", to: "pkg/Sources/New.swift", in: root)

        let changed = try ChangedFiles.since("HEAD", workingDirectory: root.appendingPathComponent("pkg").path)
        let expected = normalized(root.appendingPathComponent("pkg/Sources/New.swift").path)
        #expect(Set(changed.map(normalized)).contains(expected))
    }

    @Test("비ASCII 파일명도 실제 경로 그대로 준다")
    func handlesNonASCIIFileNames() throws {
        // git 의 core.quotePath 는 기본이 켜져 있어 한글 이름을 8진수로 이스케이프한다.
        // 그 문자열은 실제 경로와 절대 일치하지 않아 그 파일의 발견이 사라진다.
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "Sources/Base.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        try write("let k = 1", to: "Sources/새 기능.swift", in: root)

        let changed = try ChangedFiles.since("HEAD", workingDirectory: root.path)
        let expected = normalized(root.appendingPathComponent("Sources/새 기능.swift").path)
        #expect(Set(changed.map(normalized)).contains(expected))
        // 이스케이프된 채로 나오면 실제 경로와 절대 일치하지 않는다.
        #expect(changed.allSatisfy { !$0.contains("\\") })
    }

    @Test("지워진 파일은 목록에 넣지 않는다")
    func excludesDeletedFiles() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "Sources/Gone.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)
        let base = try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Gone.swift"))
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "remove"], in: root)

        let changed = try ChangedFiles.since(base, workingDirectory: root.path)
        #expect(changed.allSatisfy { !$0.hasSuffix("Gone.swift") })
    }

    @Test("없는 기준점은 git 이 말한 이유를 그대로 전한다")
    func reportsWhatGitSaid() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1", to: "Sources/Base.swift", in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "base"], in: root)

        #expect(throws: CartographError.self) {
            try ChangedFiles.since("nosuchrevision", workingDirectory: root.path)
        }
    }
}
