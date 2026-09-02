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

@Suite("심볼릭 링크 순환")
struct SymlinkTraversalTests {
    @Test("상위를 가리키는 심볼릭 링크에서 같은 파일을 반복해서 담지 않는다", .timeLimit(.minutes(1)))
    func parentSymlinkDoesNotDuplicateFiles() throws {
        // 파일 하나짜리 트리가 서른 개 경로로 부풀어 오르는 것을 실제로 확인했다.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-symlink-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("// x".utf8).write(to: nested.appendingPathComponent("A.swift"))
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("up"),
            withDestinationURL: root
        )

        let files = LocalFileSystem().recursiveFiles(
            under: root.path,
            isIncluded: { $0.hasSuffix(".swift") }
        )
        #expect(files.count == 1)
    }
    @Test("끊어진 심볼릭 링크는 파일로 세지 않는다")
    func skipsDanglingSymlinks() throws {
        // "디렉터리가 아니다"만으로 파일이라고 보면 끊어진 링크가 소스 목록에 들어와
        // 읽기 실패나 유령 정점이 된다.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "struct A {}".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("stale.swift").path,
            withDestinationPath: root.appendingPathComponent("gone.swift").path
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link.swift").path,
            withDestinationPath: root.appendingPathComponent("A.swift").path
        )

        let found = LocalFileSystem().recursiveFiles(under: root.path, isIncluded: { $0.hasSuffix(".swift") })
        let names = Set(found.map { ($0 as NSString).lastPathComponent })
        #expect(!names.contains("stale.swift"))
        // 같은 파일을 가리키는 두 이름은 한 번만 센다.
        #expect(found.count == 1)
    }

}
