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

    @Test("include/exclude 밖 무시 소스의 생성·삭제·추적 해제가 세대와 한계를 갱신하고 범위 밖 추적 파일은 그대로 둔다")
    func ignoredSourcesOutsideScopeRefreshSessionLimitations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-git-outside-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("임시 Git 프로젝트 정리 실패: \(error)") }
        }
        let fs = LocalFileSystem()
        let physical = try fs.realPath(at: root.path)
        try git(root: physical, ["init", "-q"])
        try fs.write(text: "struct App {}", to: physical + "/App.swift")
        // 기본 제외 `**/*.generated.swift` 에 걸리는 R.swift 출력이다. 분석 범위 밖이라 지문의 소스 목록에 없다.
        try fs.write(text: "R.generated.swift\n", to: physical + "/.gitignore")
        var builder = SnapshotBuilder(path: physical + "/App.swift")
        builder.symbol("App", kind: .structType)
        let service = CartographService(
            configuration: .init(indexStorePath: physical + "/index", projectPath: physical),
            environment: .init(
                fileSystem: fs, indexProviderOverride: StaticIndexProvider(builder.build()), usesSyntaxCache: false
            )
        )
        let session = try AnalysisSession(service: service)
        let first = try session.status()
        #expect(outsideScopeSentence(in: first) == nil)

        try fs.write(text: "enum R {}", to: physical + "/R.generated.swift")
        let created = try session.status()
        #expect(created.generation == first.generation + 1)
        #expect(outsideScopeSentence(in: created)?.contains(" 1 ignored source file(s) are outside") == true)
        #expect(created.limitations == (try freshLimitations(service)))

        try fs.removeItem(at: physical + "/R.generated.swift")
        let removed = try session.status()
        #expect(removed.generation == created.generation + 1)
        #expect(removed.limitations == first.limitations)

        // 범위 밖이어도 Git 이 고른 파일은 한계에 들어가지 않으므로 세션을 다시 준비시키지 않는다.
        try fs.write(text: "enum Tracked {}", to: physical + "/Tracked.generated.swift")
        try git(root: physical, ["add", "Tracked.generated.swift"])
        let tracked = try session.status()
        #expect(tracked.generation == removed.generation)
        #expect(tracked.limitations == (try freshLimitations(service)))

        try fs.write(text: "R.generated.swift\nTracked.generated.swift\n", to: physical + "/.gitignore")
        try git(root: physical, ["rm", "-q", "--cached", "Tracked.generated.swift"])
        let untracked = try session.status()
        #expect(untracked.generation == tracked.generation + 1)
        #expect(outsideScopeSentence(in: untracked)?.contains(" 1 ignored source file(s) are outside") == true)
        #expect(untracked.limitations == (try freshLimitations(service)))
    }

    @Test("범위 밖 무시 링크가 같은 파일을 가리켜도 범위 안 원본의 편집은 새 세대를 만든다")
    func ignoredLinkOutsideScopeKeepsTargetContentInFingerprint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-git-link-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("임시 Git 프로젝트 정리 실패: \(error)") }
        }
        let fs = LocalFileSystem()
        let physical = try fs.realPath(at: root.path)
        try git(root: physical, ["init", "-q"])
        try fs.write(text: "struct Zone {}", to: physical + "/Zone.swift")
        try fs.write(text: "Alias.generated.swift\n", to: physical + "/.gitignore")
        // 탐색은 같은 파일의 두 이름 중 먼저 걸은 것만 남긴다. 링크 이름이 원본보다 앞서 정렬되게 한다.
        try FileManager.default.createSymbolicLink(
            atPath: physical + "/Alias.generated.swift", withDestinationPath: "Zone.swift")
        var builder = SnapshotBuilder(path: physical + "/Zone.swift")
        builder.symbol("Zone", kind: .structType)
        let service = CartographService(
            configuration: .init(indexStorePath: physical + "/index", projectPath: physical),
            environment: .init(
                fileSystem: fs, indexProviderOverride: StaticIndexProvider(builder.build()), usesSyntaxCache: false
            )
        )
        let session = try AnalysisSession(service: service)
        let first = try session.status()
        // 링크는 Git 이 고르지 않은 경로로 세지만, Git 이 고른 소스를 가리키므로 범위 밖 무시 소스 문장에는 들지 않는다.
        #expect(first.limitations.contains { $0.hasPrefix("source-discovery-exclusions: 1 ") })
        #expect(outsideScopeSentence(in: first) == nil)

        try fs.write(text: "struct Zone { let edited = 1 }", to: physical + "/Zone.swift")
        #expect(try session.status().generation == first.generation + 1)
    }

    /// `source-discovery-exclusions` 한계에서 범위 밖 무시 소스 문장이 있으면 그 한계 전체를 돌려준다.
    private func outsideScopeSentence(in metadata: AnalysisSession.Metadata) -> String? {
        metadata.limitations.first {
            $0.hasPrefix("source-discovery-exclusions:") && $0.contains("outside the include/exclude scope")
        }
    }

    /// 같은 서비스로 새로 준비한 세션의 한계. 오래 산 세션이 내야 할 답의 기준이다.
    private func freshLimitations(_ service: CartographService) throws -> [String] {
        try AnalysisSession(service: service).status().limitations
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
