import CartographCore
@testable import CartographKit
import Foundation
import Testing

@Suite("Git source inventory boundaries")
struct GitSourceInventoryTests {
    @Test("Git ignore와 info exclude를 지키되 추적 파일은 보존하고 중첩 저장소는 따로 남긴다")
    func ignoresAndTrackedPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String = "struct Example {}") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "core.hooksPath=/dev/null", "-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        try write(".gitignore", "Ignored.swift\nTracked.swift\n.claude/\n")
        try write(".git/info/exclude", "Info.swift\n")
        for name in ["App.swift", "Ignored.swift", "Tracked.swift", "Info.swift", ".claude/worktrees/copy/Noise.swift"] {
            try write(name)
        }
        try git(["add", "-f", "Tracked.swift"])
        try write("nested/.git", "gitdir: /nonexistent")
        try write("nested/Noise.swift")
        let fs = LocalFileSystem()
        let inventory = ProjectFileInventory(fileSystem: fs, projectPath: root.path, pathFilter: .passthrough)
        #expect(Set(inventory.sourceFiles.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["App.swift", "Tracked.swift"])
        #expect(!inventory.discoveryExclusions.isEmpty)
        #expect(inventory.discoveryExclusions.contains { $0.hasSuffix("/nested") })
    }

    @Test("저장소인데 Git 이 목록을 내지 못하면 전체 walk 로 폴백하고 그 사실을 한계로 남긴다")
    func reportsUnavailableGitSelection() throws {
        let repository = try TemporaryRepository()
        defer { repository.remove() }
        try repository.git(["init", "-q"])
        try repository.write(".gitignore", ".claude/\n")
        try repository.write("App.swift")
        try repository.write(".claude/worktrees/copy/Noise.swift")
        try repository.git(["add", "App.swift"])
        // 손상된 index 는 `git ls-files` 를 결정적으로 실패시킨다. 시간 상한처럼 실행마다 흔들리지 않는다.
        try repository.write(".git/index", "not an index")
        let fileSystem = LocalFileSystem()
        let selection = GitSourceInventory.select(fileSystem: fileSystem, projectPath: repository.path)
        guard case let .unavailable(reason) = selection else {
            Issue.record("a corrupt index must make Git selection unavailable, got \(selection)")
            return
        }
        #expect(reason.contains("exited with status"))

        let inventory = ProjectFileInventory(
            fileSystem: fileSystem, projectPath: repository.path, pathFilter: .passthrough)
        #expect(inventory.gitSelectionUnavailableReason == reason)
        // 폴백은 무시 파일까지 센다 — 그래서 답이 흔들릴 수 있다고 알려야 한다.
        let names = Set(inventory.sourceFiles.map { URL(fileURLWithPath: $0).lastPathComponent })
        #expect(names == ["App.swift", "Noise.swift"])
        var configuration = CartographConfiguration.default
        configuration.projectPath = repository.path
        let limitations = AnalysisLimitationCollector(
            configuration: configuration, fileSystem: fileSystem, projectPath: repository.path,
            storeDate: nil, inventory: inventory
        ).collect(context: nil, symbolGraph: nil, emptyIndexCounts: nil)
        #expect(limitations.contains { $0.hasPrefix("source-discovery-git-unavailable: ") && $0.contains(reason) })
    }

    @Test("저장소 밖 프로젝트는 Git 선택을 시도하지 않고 한계도 남기지 않는다")
    func outsideRepositoryIsNotAFailure() throws {
        let repository = try TemporaryRepository()
        defer { repository.remove() }
        try repository.write("App.swift")
        let fileSystem = LocalFileSystem()
        #expect(GitSourceInventory.select(fileSystem: fileSystem, projectPath: repository.path) == .notApplicable)
        let inventory = ProjectFileInventory(
            fileSystem: fileSystem, projectPath: repository.path, pathFilter: .passthrough)
        #expect(inventory.gitSelectionUnavailableReason == nil)
    }
}

/// 테스트마다 새로 만드는 임시 디렉터리. Git 저장소로 만들지는 호출자가 정한다.
private struct TemporaryRepository {
    let root: URL
    var path: String { root.path }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ text: String = "struct Example {}") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
