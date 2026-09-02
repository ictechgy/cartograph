import CartographCore
import Foundation

/// 테스트용 메모리 파일 시스템.
///
/// 경로 문자열을 그대로 키로 쓰며, 디렉터리는 "어떤 파일의 접두사인 경로"로 유추한다.
/// 실제 파일 시스템의 모든 의미를 흉내 내지 않고, 도구가 실제로 쓰는 연산만 지원한다.
public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    public let currentDirectoryPath: String

    public init(currentDirectoryPath: String = "/project", files: [String: String] = [:]) {
        self.currentDirectoryPath = currentDirectoryPath
        for (path, contents) in files {
            self.files[path] = Data(contents.utf8)
        }
    }

    /// 기록된 파일 목록(정렬됨). 출력 검증에 쓴다.
    public var writtenPaths: [String] {
        lock.withLock { files.keys.sorted() }
    }

    /// 파일 내용을 문자열로 꺼낸다.
    public func text(at path: String) -> String? {
        lock.withLock { files[path].map { String(decoding: $0, as: UTF8.self) } }
    }

    public func fileExists(at path: String) -> Bool {
        lock.withLock { files[path] != nil }
    }

    public func directoryExists(at path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return lock.withLock { files.keys.contains { $0.hasPrefix(prefix) } }
    }

    public func readData(at path: String) throws -> Data {
        guard let data = lock.withLock({ files[path] }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    public func write(_ data: Data, to path: String) throws {
        lock.withLock { files[path] = data }
    }

    public func contentsOfDirectory(at path: String) throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return lock.withLock {
            var entries: Set<String> = []
            for filePath in files.keys where filePath.hasPrefix(prefix) {
                let remainder = filePath.dropFirst(prefix.count)
                guard let firstComponent = remainder.split(separator: "/").first else { continue }
                entries.insert(prefix + firstComponent)
            }
            return entries.sorted()
        }
    }
}
