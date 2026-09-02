import CartographCore
import CartographTestSupport
import Foundation
import Testing

@Suite("FileSystem 추상화")
struct FileSystemTests {
    @Test("메모리 파일 시스템은 파일과 디렉터리를 구분한다")
    func inMemoryDistinguishesFilesAndDirectories() {
        let fileSystem = InMemoryFileSystem(files: ["/p/Sources/A.swift": "// a"])
        #expect(fileSystem.fileExists(at: "/p/Sources/A.swift"))
        #expect(!fileSystem.fileExists(at: "/p/Sources"))
        #expect(fileSystem.directoryExists(at: "/p/Sources"))
        #expect(!fileSystem.directoryExists(at: "/p/Sources/A.swift"))
    }

    @Test("디렉터리 나열은 바로 아래 항목만 돌려준다")
    func directoryListingIsShallow() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Sources/A.swift": "",
            "/p/Sources/Nested/B.swift": "",
            "/p/README.md": "",
        ])
        #expect(try fileSystem.contentsOfDirectory(at: "/p") == ["/p/README.md", "/p/Sources"])
        #expect(try fileSystem.contentsOfDirectory(at: "/p/Sources") == ["/p/Sources/A.swift", "/p/Sources/Nested"])
    }

    @Test("재귀 탐색은 필터와 가지치기를 함께 적용한다")
    func recursiveFilesFiltersAndPrunes() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Sources/A.swift": "",
            "/p/Sources/Nested/B.swift": "",
            "/p/Sources/Nested/C.md": "",
            "/p/.build/D.swift": "",
        ])
        let files = fileSystem.recursiveFiles(
            under: "/p",
            isIncluded: { $0.hasSuffix(".swift") },
            shouldDescend: { !$0.hasSuffix("/.build") }
        )
        #expect(files == ["/p/Sources/A.swift", "/p/Sources/Nested/B.swift"])
    }

    @Test("탐색 시작점이 파일이면 그 파일만 후보가 된다")
    func recursiveFilesAcceptsSingleFile() {
        let fileSystem = InMemoryFileSystem(files: ["/p/A.swift": ""])
        #expect(fileSystem.recursiveFiles(under: "/p/A.swift", isIncluded: { _ in true }) == ["/p/A.swift"])
        #expect(fileSystem.recursiveFiles(under: "/p/A.swift", isIncluded: { _ in false }).isEmpty)
        #expect(fileSystem.recursiveFiles(under: "/nope", isIncluded: { _ in true }).isEmpty)
    }

    @Test("없는 파일을 읽으면 오류가 발생한다")
    func readingMissingFileThrows() {
        #expect(throws: (any Error).self) {
            try InMemoryFileSystem().readData(at: "/nope")
        }
    }

    @Test("텍스트 읽기와 쓰기가 왕복한다")
    func textRoundTrip() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "안녕", to: "/p/a.txt")
        #expect(try fileSystem.readText(at: "/p/a.txt") == "안녕")
        #expect(fileSystem.writtenPaths == ["/p/a.txt"])
        #expect(fileSystem.text(at: "/p/a.txt") == "안녕")
    }

    @Test("로컬 파일 시스템은 중간 디렉터리를 만들어 준다")
    func localFileSystemCreatesIntermediateDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let fileSystem = LocalFileSystem()
        let target = root.appendingPathComponent("nested/deep/file.txt").path
        try fileSystem.write(text: "hello", to: target)

        #expect(fileSystem.fileExists(at: target))
        #expect(fileSystem.directoryExists(at: root.appendingPathComponent("nested").path))
        #expect(try fileSystem.readText(at: target) == "hello")
        #expect(try fileSystem.contentsOfDirectory(at: root.path).count == 1)
        #expect(!fileSystem.currentDirectoryPath.isEmpty)
    }
}
