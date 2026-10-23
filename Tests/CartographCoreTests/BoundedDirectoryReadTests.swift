import CartographCore
import Foundation
import Testing

@Suite("Bounded directory enumeration")
struct BoundedDirectoryReadTests {
    @Test("The actual local reader refuses the next entry before returning a partial list")
    func exactBudgetAndOverflow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fs = LocalFileSystem()
        #expect(try fs.directoryEntries(at: directory.path, maximumEntries: 0).isEmpty)
        for name in ["a", "b", "c"] { try Data().write(to: directory.appendingPathComponent(name)) }
        #expect(try fs.directoryEntries(at: directory.path, maximumEntries: 3).count == 3)
        #expect(throws: (any Error).self) { try fs.directoryEntries(at: directory.path, maximumEntries: 2) }
        #expect(throws: (any Error).self) { try fs.directoryEntries(at: directory.path, maximumEntries: -1) }
        #expect(throws: (any Error).self) { try fs.directoryEntries(at: directory.appendingPathComponent("missing").path, maximumEntries: 3) }
        let link = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("a"))
        #expect(try fs.directoryEntries(at: directory.path, maximumEntries: 4).filter(\.isSymbolicLink).count == 1)
    }

    @Test("A legacy provider without a bounded implementation never calls its unbounded listing")
    func unsupportedProviderRefuses() {
        #expect(throws: (any Error).self) {
            try UnboundedOnlyFileSystem().directoryEntries(at: "/p", maximumEntries: 1)
        }
    }
}

private struct UnboundedOnlyFileSystem: FileSystem {
    func readData(at _: String) throws -> Data { Data() }
    func write(_: Data, to _: String) throws {}
    func fileExists(at _: String) -> Bool { false }
    func directoryExists(at _: String) -> Bool { true }
    func contentsOfDirectory(at _: String) throws -> [String] {
        Issue.record("A bounded request invoked the unbounded fallback.")
        return []
    }
    var currentDirectoryPath: String { "/p" }
}
