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
}
