import Foundation

/// 파일 접근을 한 겹 감싼 추상화.
///
/// 디스크를 건드리지 않고도 설정 로딩·베이스라인·리포트 출력을 테스트할 수 있게 한다.
/// FileManager 를 직접 쓰면 테스트가 임시 디렉터리에 의존하게 되고,
/// 병렬 실행에서 서로 간섭하기 쉽다.
public protocol FileSystem: Sendable {
    func fileExists(at path: String) -> Bool
    func directoryExists(at path: String) -> Bool
    func readData(at path: String) throws -> Data
    func write(_ data: Data, to path: String) throws
    /// 디렉터리 바로 아래 항목들의 전체 경로. 순서는 정렬되어 있다.
    func contentsOfDirectory(at path: String) throws -> [String]
    /// 디렉터리 바로 아래 항목을 종류와 함께 돌려준다.
    ///
    /// 항목마다 따로 `directoryExists`·`fileExists` 를 부르면 큰 저장소에서
    /// 탐색이 분석보다 오래 걸린다. 실측에서 심볼 13,000개짜리 프로젝트의 `dead` 가
    /// 33초였는데 프로파일러가 가리킨 곳은 전부 이 탐색이었다. 파일 시스템이 열거
    /// 과정에서 이미 아는 정보를 한 번에 받아 오면 항목당 시스템 호출이 사라진다.
    func directoryEntries(at path: String) throws -> [DirectoryEntry]
    /// 최종 수정 시각. 알 수 없으면 nil.
    ///
    /// 후보가 여러 개인 인덱스 스토어 중 가장 최근 것을 고르는 데 쓴다.
    func modificationDate(at path: String) -> Date?
    var currentDirectoryPath: String { get }
}

extension FileSystem {
    /// 수정 시각을 알 수 없는 구현을 위한 기본값.
    public func modificationDate(at path: String) -> Date? { nil }

    /// 종류를 함께 주지 못하는 구현을 위한 기본값. 예전처럼 항목마다 물어본다.
    public func directoryEntries(at path: String) throws -> [DirectoryEntry] {
        try contentsOfDirectory(at: path).map {
            DirectoryEntry(path: $0, isDirectory: directoryExists(at: $0), isRegularFile: fileExists(at: $0))
        }
    }
}

/// 디렉터리 열거 결과 한 줄.
public struct DirectoryEntry: Sendable, Equatable {
    public let path: String
    public let isDirectory: Bool
    /// 일반 파일인지 여부. 끊어진 심볼릭 링크는 둘 다 거짓이다.
    public let isRegularFile: Bool

    public init(path: String, isDirectory: Bool, isRegularFile: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
    }
}

extension FileSystem {
    /// UTF-8 텍스트로 읽는다.
    public func readText(at path: String) throws -> String {
        String(decoding: try readData(at: path), as: UTF8.self)
    }

    /// UTF-8 텍스트로 쓴다.
    public func write(text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    /// 디렉터리 트리를 재귀적으로 훑어 조건에 맞는 파일 경로를 모은다.
    ///
    /// - Parameters:
    ///   - root: 탐색 시작 경로. 파일이면 그 파일만 후보가 된다.
    ///   - isIncluded: 파일 경로 필터.
    ///   - shouldDescend: 하위 디렉터리로 내려갈지 결정한다. 빌드 산출물처럼
    ///     들어가 봐야 소용없는 디렉터리를 통째로 건너뛰기 위해 쓴다.
    public func recursiveFiles(
        under root: String,
        isIncluded: (String) -> Bool,
        shouldDescend: (String) -> Bool = { _ in true }
    ) -> [String] {
        guard directoryExists(at: root) else {
            return fileExists(at: root) && isIncluded(root) ? [root] : []
        }
        var result: [String] = []
        var pending = [root]
        // 심볼릭 링크가 상위 디렉터리를 가리키면 같은 트리를 끝없이 다시 걷는다.
        // 파일 하나짜리 트리가 서른 개 경로로 부풀어 오르는 것을 실제로 확인했다.
        // 실제 경로 기준으로 방문 여부를 기록해 한 번씩만 본다.
        var visited: Set<String> = []
        var visitedFiles: Set<String> = []

        while let directory = pending.popLast() {
            guard visited.insert(Self.canonicalPath(directory)).inserted,
                  let entries = try? directoryEntries(at: directory)
            else { continue }
            for entry in entries {
                if entry.isDirectory {
                    if shouldDescend(entry.path) { pending.append(entry.path) }
                } else if entry.isRegularFile, isIncluded(entry.path) {
                    // 끊어진 심볼릭 링크는 일반 파일이 아니다. 그것을 소스 파일로 세면
                    // 읽는 쪽에서 실패하거나 유령 정점이 된다.
                    // 같은 파일을 가리키는 두 이름은 한 번만 센다.
                    guard visitedFiles.insert(Self.canonicalPath(entry.path)).inserted else { continue }
                    result.append(entry.path)
                }
            }
        }
        return result.sorted()
    }
}

extension FileSystem {
    /// 심볼릭 링크를 푼 경로. 방문 여부 판정에만 쓴다.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// 실제 디스크를 사용하는 기본 구현.
///
/// 상태를 갖지 않으므로 그대로 Sendable 이다. FileManager.default 는
/// 여기서 쓰는 연산에 한해 스레드 안전하다.
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func fileExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    public func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func readData(at path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func contentsOfDirectory(at path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
            .map { (path as NSString).appendingPathComponent($0) }
            .sorted()
    }

    /// 열거 한 번으로 종류까지 받아 온다.
    ///
    /// `FileManager` 는 디렉터리를 읽으면서 이미 각 항목의 종류를 알고 있다.
    /// 미리 요청해 두면 캐시된 값을 읽으므로 항목마다 stat 을 부르지 않는다.
    public func directoryEntries(at path: String) throws -> [DirectoryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        return try FileManager.default
            .contentsOfDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                includingPropertiesForKeys: keys,
                options: []
            )
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return DirectoryEntry(
                    path: url.path,
                    isDirectory: values?.isDirectory ?? false,
                    isRegularFile: values?.isRegularFile ?? false
                )
            }
            .sorted { $0.path < $1.path }
    }

    public func modificationDate(at path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    public var currentDirectoryPath: String {
        FileManager.default.currentDirectoryPath
    }
}

/// 소스를 찾을 때 들어가 봐야 소용없는 디렉터리 이름.
///
/// 빌드 산출물과 체크아웃된 의존성이다. 큰 저장소에서는 이 가지치기만으로 탐색
/// 시간이 몇 배 차이가 난다. 목록이 두 벌로 갈라지면 한쪽만 고쳐지고 같은
/// 프로젝트에서 명령마다 다른 숫자가 나온다. 여기 하나만 둔다.
public enum BuildArtifactDirectories {
    public static let prunedNames: Set<String> = [
        ".build", ".git", "DerivedData", "Pods", "Carthage", "checkouts", ".swiftpm", "node_modules",
    ]

    /// `recursiveFiles(under:isIncluded:shouldDescend:)` 에 그대로 넘길 수 있는 판정.
    public static func shouldDescend(into path: String) -> Bool {
        !prunedNames.contains((path as NSString).lastPathComponent)
    }
}
