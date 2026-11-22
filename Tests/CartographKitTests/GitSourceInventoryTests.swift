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
        // 무시된 소스 파일은 분석 범위 밖이지만, 색인됐다면 그 참조를 따라가도록 따로 기록한다. 중첩 저장소는 아니다.
        let ignored = Set(inventory.ignoredSourceFiles.map { URL(fileURLWithPath: $0).lastPathComponent })
        #expect(ignored == ["Ignored.swift", "Info.swift", "Noise.swift"])
        #expect(!inventory.ignoredSourceFiles.contains { $0.contains("/nested/") })
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
        let selection = GitSourceSelection.select(fileSystem: fileSystem, projectPath: repository.path)
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
        #expect(GitSourceSelection.select(fileSystem: fileSystem, projectPath: repository.path) == .notApplicable)
        let inventory = ProjectFileInventory(
            fileSystem: fileSystem, projectPath: repository.path, pathFilter: .passthrough)
        #expect(inventory.gitSelectionUnavailableReason == nil)
    }

    @Test("include/exclude 가 거른 무시 소스는 따라가지 않으므로 한계가 그 개수를 따로 말하고 보존을 주장하지 않는다")
    func ignoredSourcesOutsideScopeAreNotClaimedAsRetained() throws {
        // R.swift 의 기본 출력 이름과 SwiftGen 의 흔한 출력 폴더는 기본 제외 글롭에 걸린다. 이 파일들이 쓰는 선언은
        // 색인됐어도 보존되지 않는데, 한계는 "보존한다" 는 문장만 실어 그 파일들에도 해당하는 것처럼 읽혔다.
        let repository = try TemporaryRepository()
        defer { repository.remove() }
        try repository.git(["init", "-q"])
        try repository.write(".gitignore", "Followed.swift\nR.generated.swift\nGenerated/\n")
        for name in ["App.swift", "Followed.swift", "R.generated.swift", "Generated/Strings.swift"] {
            try repository.write(name)
        }
        let fileSystem = LocalFileSystem()
        let root = try fileSystem.realPath(at: repository.path)
        func limitation(projectPath: String) throws -> String {
            var configuration = CartographConfiguration.default
            configuration.projectPath = projectPath
            let inventory = ProjectFileInventory(
                fileSystem: fileSystem, projectPath: projectPath, pathFilter: configuration.pathFilter)
            let limitations = AnalysisLimitationCollector(
                configuration: configuration, fileSystem: fileSystem, projectPath: projectPath,
                storeDate: nil, inventory: inventory
            ).collect(context: nil, symbolGraph: nil, emptyIndexCounts: nil)
            return try #require(limitations.first { $0.hasPrefix("source-discovery-exclusions: ") })
        }
        let retained = "Declarations used by ignored sources the compiler indexed are retained "
            + "(ignoredSourceReference)."
        let outside = " 2 ignored source file(s) are outside the include/exclude scope (the default exclude patterns "
            + "include **/*.generated.swift and **/Generated/**), so declarations used only by them are not retained "
            + "and can be reported as unused; widen include or remove the matching exclude pattern to follow them."

        var configuration = CartographConfiguration.default
        configuration.projectPath = root
        let inventory = ProjectFileInventory(
            fileSystem: fileSystem, projectPath: root, pathFilter: configuration.pathFilter)
        #expect(inventory.ignoredSourceFiles == [root + "/Followed.swift"])
        #expect(inventory.ignoredSourceFilesOutsideScope
            == [root + "/Generated/Strings.swift", root + "/R.generated.swift"])
        let mixed = try limitation(projectPath: root)
        #expect(mixed.contains(retained) && mixed.contains(outside))

        // 따라가는 무시 소스가 없으면 보존 문장은 빠지고, 거른 개수만 남는다.
        try FileManager.default.removeItem(atPath: root + "/Followed.swift")
        let onlyOutside = try limitation(projectPath: root)
        #expect(!onlyOutside.contains(retained) && onlyOutside.contains(outside))

        // 거른 무시 소스가 없으면 그 문장도 없다. 매번 붙는 경보는 읽히지 않는다.
        try repository.write("Followed.swift")
        try FileManager.default.removeItem(atPath: root + "/R.generated.swift")
        try FileManager.default.removeItem(atPath: root + "/Generated/Strings.swift")
        let onlyFollowed = try limitation(projectPath: root)
        #expect(onlyFollowed.contains(retained) && !onlyFollowed.contains("outside the include/exclude scope"))
    }

    @Test("선택에 성공했을 때만 목록을 돌려주고, 시도하지 않았거나 실패했으면 전체 walk 로 폴백하게 한다")
    func inventoryIsPresentOnlyWhenSelected() {
        let listed = GitSourceInventory(paths: ["/project/App.swift"])
        #expect(GitSourceSelection.selected(listed).inventory == listed)
        #expect(GitSourceSelection.notApplicable.inventory == nil)
        #expect(GitSourceSelection.unavailable(reason: "git could not be started").inventory == nil)
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
