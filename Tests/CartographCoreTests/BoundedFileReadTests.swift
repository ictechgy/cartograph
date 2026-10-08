import CartographCore
import Foundation
import Testing

@Suite("설정 파일 byte 상한 읽기")
struct BoundedFileReadTests {
    @Test("실제 파일은 문자 수와 무관하게 상한+1 byte까지만 읽는다")
    func readsOnlyBudgetAndSentinel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.json")
        try Data("한글".utf8).write(to: file)
        let fileSystem = LocalFileSystem()
        #expect(try fileSystem.readData(at: file.path, maximumBytes: 3).count == 4)
        #expect(try fileSystem.readData(at: file.path, maximumBytes: 6).count == 6)
        #expect(try fileSystem.readData(at: file.path, maximumBytes: 0).count == 1)
        #expect(throws: (any Error).self) { try fileSystem.readData(at: directory.path, maximumBytes: 4) }
    }
}
