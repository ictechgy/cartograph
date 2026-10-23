import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("Git 선택 입력 신선도")
struct GitSourceFreshnessTests {
    @Test("소스 내용이 그대로여도 ignore·info exclude·tracked 전환이 세션과 snapshot 지문을 갱신한다")
    func selectionChangesInvalidateBothFingerprints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-git-freshness-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("임시 Git 프로젝트 정리 실패: \(error)") }
        }
        let fs = LocalFileSystem()
        let physical = try fs.realPath(at: root.path)
        try git(root: physical, ["init", "-q"])
        try fs.write(text: "struct App {}", to: physical + "/App.swift")
        try fs.write(text: "struct Ignored {}", to: physical + "/Ignored.swift")
        try fs.write(text: "struct Info {}", to: physical + "/Info.swift")
        try fs.write(text: "Ignored.swift\n", to: physical + "/.gitignore")
        try fs.write(text: "Info.swift\n", to: physical + "/.git/info/exclude")
        var builder = SnapshotBuilder(path: physical + "/App.swift")
        builder.symbol("App", kind: .structType)
        let service = CartographService(configuration: .init(indexStorePath: physical + "/index", projectPath: physical),
            environment: .init(fileSystem: fs, indexProviderOverride: StaticIndexProvider(builder.build()), usesSyntaxCache: false))
        let session = try AnalysisSession(service: service)
        let first = try session.status()
        let firstSnapshot = try service.sessionInputFingerprint()
        let sourceStamp = fs.fingerprintStamp(at: physical + "/Ignored.swift")

        try fs.write(text: "# a comment only\nIgnored.swift\n", to: physical + "/.gitignore")
        #expect(try session.status().generation == first.generation)
        #expect(try service.sessionInputFingerprint() == firstSnapshot)

        try fs.write(text: "", to: physical + "/.gitignore")
        let unignored = try session.status()
        #expect(unignored.generation == first.generation + 1)
        #expect(unignored.fingerprint != first.fingerprint)
        #expect(try service.sessionInputFingerprint() != firstSnapshot)

        try fs.write(text: "Ignored.swift\n", to: physical + "/.gitignore")
        let ignoredAgain = try session.status()
        let ignoredSnapshot = try service.sessionInputFingerprint()
        try git(root: physical, ["add", "-f", "Ignored.swift"])
        let tracked = try session.status()
        #expect(tracked.generation == ignoredAgain.generation + 1)
        #expect(tracked.fingerprint != ignoredAgain.fingerprint)
        #expect(try service.sessionInputFingerprint() != ignoredSnapshot)

        let trackedSnapshot = try service.sessionInputFingerprint()
        try fs.write(text: "", to: physical + "/.git/info/exclude")
        let infoIncluded = try session.status()
        #expect(infoIncluded.generation == tracked.generation + 1)
        #expect(infoIncluded.fingerprint != tracked.fingerprint)
        #expect(try service.sessionInputFingerprint() != trackedSnapshot)
        #expect(fs.fingerprintStamp(at: physical + "/Ignored.swift") == sourceStamp)
    }

    private func git(root: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", root] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
