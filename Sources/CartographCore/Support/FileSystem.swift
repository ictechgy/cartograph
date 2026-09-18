import Foundation
import Darwin

/// 파일 접근을 한 겹 감싼 추상화.
///
/// 디스크를 건드리지 않고도 설정 로딩·베이스라인·리포트 출력을 테스트할 수 있게 한다.
/// FileManager 를 직접 쓰면 테스트가 임시 디렉터리에 의존하게 되고,
/// 병렬 실행에서 서로 간섭하기 쉽다.
public protocol FileSystem: Sendable {
    /// 다른 생산자와 같은 프로젝트를 식별하도록 실제 절대 경로를 돌려준다. 해결할 수 없으면 실패한다.
    func realPath(at path: String) throws -> String
    func fileExists(at path: String) -> Bool
    func directoryExists(at path: String) -> Bool
    func readData(at path: String) throws -> Data
    func write(_ data: Data, to path: String) throws
    /// 경로의 파일이나 디렉터리를 지운다. 디렉터리는 내용물까지 함께 지운다.
    ///
    /// 낡은 캐시 디렉터리 정리처럼 쓰기가 필요한 곳에서만 호출한다. 없는 경로를
    /// 지우면 오류다 — 호출자가 "이미 없다" 를 허용할지는 각자 정한다.
    /// 기본 구현은 지원하지 않음 오류를 던지므로 기존 채택 타입은 그대로 컴파일된다.
    func removeItem(at path: String) throws
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
    /// 파일 내용 캐시를 안전하게 재사용할 수 있는 운영체제 지문. 알 수 없으면 nil 이다.
    ///
    /// 수정 시각 하나만으로는 같은 시각으로 되돌린 편집이나 권한·심볼릭 링크 교체를
    /// 구별할 수 없으므로, 구현체는 모든 필드를 실제 파일 상태에서 채워야 한다.
    func fingerprintStamp(at path: String) -> FileFingerprintStamp?
    /// 디렉터리 항목 구성이 바뀌었는지만 판별하는 지문. 알 수 없으면 nil 이다.
    ///
    /// 목록 캐시의 유효성 검사에 쓴다. 파일 내용 변경은 파일 지문이 따로 잡으므로
    /// 여기서는 구조 변화 — 항목 추가·삭제·이름 변경·링크 대상 교체 — 만 감지하면
    /// 된다. 링크 대상이 바뀌면 대상의 inode 가 바뀌므로 해결 경로 문자열은 필요 없다.
    func directoryListingStamp(at path: String) -> DirectoryListingStamp?
    var currentDirectoryPath: String { get }
}

extension FileSystem {
    /// 정규화를 지원하지 않는 구현은 경로를 추측해 교환 문서를 만들지 않는다.
    public func realPath(at _: String) throws -> String {
        throw CocoaError(.featureUnsupported)
    }

    /// 삭제를 지원하지 않는 구현을 위한 기본값. 캐시 정리는 베스트 에포트이므로
    /// 호출자가 실패를 삼키는 곳에서만 쓴다.
    public func removeItem(at _: String) throws {
        throw CocoaError(.featureUnsupported)
    }

    /// 수정 시각을 알 수 없는 구현을 위한 기본값.
    public func modificationDate(at _: String) -> Date? { nil }

    /// 운영체제 파일 지문을 제공하지 않는 구현은 매번 내용을 읽도록 한다.
    public func fingerprintStamp(at _: String) -> FileFingerprintStamp? { nil }

    /// 파일 지문에서 구조 필드만 취하는 기본 구현. stat 을 따로 제공할 수 없는
    /// 구현도 안전하게 목록 캐시를 쓸 수 있다.
    public func directoryListingStamp(at path: String) -> DirectoryListingStamp? {
        fingerprintStamp(at: path).map(DirectoryListingStamp.init)
    }

    /// 종류를 함께 주지 못하는 구현을 위한 기본값. 예전처럼 항목마다 물어본다.
    public func directoryEntries(at path: String) throws -> [DirectoryEntry] {
        try contentsOfDirectory(at: path).map {
            // 링크 여부를 알 수 없으면 링크로 취급한다. `recursiveFiles` 가 방문
            // 집합 키를 실제 경로로 바꿔 계산해야 링크 순환에서 같은 트리를
            // 반복해 걷지 않는다.
            let isLink = (try? realPath(at: $0)) != $0
            return DirectoryEntry(
                path: $0, isDirectory: directoryExists(at: $0), isRegularFile: fileExists(at: $0),
                isSymbolicLink: isLink)
        }
    }
}

/// 파일 내용 digest를 재사용할 때 확인하는 운영체제 파일 상태.
///
/// mtime만 저장하면 편집 뒤 시각을 복원한 파일이나 권한만 바뀐 파일을 놓칠 수 있다.
/// 장치·inode·크기·mtime·ctime·권한과 심볼릭 링크 대상 경로를 함께 비교해 그런
/// 상태에서는 캐시가 내용을 다시 읽도록 만든다.
public struct FileFingerprintStamp: Sendable, Equatable, Hashable {
    /// 마지막 경로 요소가 심볼릭 링크이면 따라간 대상의 실제 경로, 아니면 입력 철자.
    ///
    /// 링크가 아닌 파일에까지 realpath 를 적용하지 않는다 — 조상 디렉터리 링크의
    /// 재지정은 이미 inode·장치 변화로 드러나고, realpath 는 구성 요소마다 lstat 을
    /// 거치므로 수백 개 입력을 매번 확인하는 세션 지문에서 지배적인 비용이었다.
    public let resolvedPath: String
    /// 파일이 속한 장치 식별자.
    public let device: UInt64
    /// 파일 inode 식별자.
    public let inode: UInt64
    /// 파일 크기(바이트).
    public let size: UInt64
    /// mtime의 초 단위 부분.
    public let modificationSeconds: Int64
    /// mtime의 나노초 부분.
    public let modificationNanoseconds: Int64
    /// ctime의 초 단위 부분.
    public let changeSeconds: Int64
    /// ctime의 나노초 부분.
    public let changeNanoseconds: Int64
    /// POSIX 파일 모드와 종류 비트.
    public let mode: UInt32

    /// 운영체제 파일 상태를 만든다.
    public init(
        resolvedPath: String,
        device: UInt64,
        inode: UInt64,
        size: UInt64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64,
        mode: UInt32
    ) {
        self.resolvedPath = resolvedPath
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
        self.mode = mode
    }

    /// stat 의 정규 파일 종류 비트로 읽는다. 디렉터리·FIFO ·소켓 입력을 내용
    /// 지문 대상으로 오인하지 않기 위한 판정이다.
    public var isRegularFile: Bool {
        mode & 0o170000 == 0o100000
    }
}

/// 디렉터리 항목 구성 변화를 감지하는 운영체제 지문.
///
/// `FileFingerprintStamp` 와 달리 해결 경로를 담지 않는다 — 디렉터리 목록은
/// "같은 물리 디렉터리인가"와 "항목이 바뀌었는가"만 중요하고, 둘 다 stat 필드로
/// 판별된다. 링크가 다른 디렉터리를 가리키면 inode 가 바뀌고, 항목 구성이 바뀌면
/// mtime·ctime 이 바뀐다.
public struct DirectoryListingStamp: Sendable, Equatable, Hashable {
    /// 디렉터리가 속한 장치 식별자.
    public let device: UInt64
    /// 디렉터리 inode 식별자. 링크 경유 경로에서는 따라간 대상의 inode 다.
    public let inode: UInt64
    /// 디렉터리 크기(바이트).
    public let size: UInt64
    /// mtime의 초 단위 부분.
    public let modificationSeconds: Int64
    /// mtime의 나노초 부분.
    public let modificationNanoseconds: Int64
    /// ctime의 초 단위 부분.
    public let changeSeconds: Int64
    /// ctime의 나노초 부분.
    public let changeNanoseconds: Int64
    /// POSIX 파일 모드와 종류 비트.
    public let mode: UInt32

    /// 운영체제 디렉터리 상태를 만든다.
    public init(
        device: UInt64,
        inode: UInt64,
        size: UInt64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64,
        mode: UInt32
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
        self.mode = mode
    }

    /// 파일 지문의 구조 필드만 취한다.
    public init(_ stamp: FileFingerprintStamp) {
        self.init(
            device: stamp.device,
            inode: stamp.inode,
            size: stamp.size,
            modificationSeconds: stamp.modificationSeconds,
            modificationNanoseconds: stamp.modificationNanoseconds,
            changeSeconds: stamp.changeSeconds,
            changeNanoseconds: stamp.changeNanoseconds,
            mode: stamp.mode
        )
    }
}

/// 디렉터리 열거 결과 한 줄.
public struct DirectoryEntry: Sendable, Equatable {
    public let path: String
    public let isDirectory: Bool
    /// 일반 파일인지 여부. 끊어진 심볼릭 링크는 둘 다 거짓이다.
    public let isRegularFile: Bool
    /// 항목 자체가 심볼릭 링크인지 여부. 링크만 실제 경로로 환산해 방문 집합에 쓴다.
    /// 알 수 없는 구현은 참을 넣어 예전처럼 모든 경로를 환산하게 한다.
    public let isSymbolicLink: Bool

    public init(path: String, isDirectory: Bool, isRegularFile: Bool, isSymbolicLink: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
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
    ///   - onDirectory: 방문한 디렉터리마다 한 번씩 부른다. 열거가 실패한
    ///     디렉터리에도 부른다 — 그 지문이 바뀌면 읽을 수 있게 된 것이므로
    ///     캐시하는 호출자는 실패한 디렉터리도 검증 대상에 넣어야 한다.
    ///   - onDiscardedLink: 같은 파일을 가리켜 버려진 심볼릭 링크 경로마다
    ///     부른다. 결과 목록에는 안 들어가지만, 링크가 재지정되면 목록이
    ///     달라지므로 캐시하는 호출자는 이 경로들도 검증 대상에 넣어야 한다.
    public func recursiveFiles(
        under root: String,
        isIncluded: (String) -> Bool,
        shouldDescend: (String) -> Bool = { _ in true },
        onDirectory: (String) -> Void = { _ in },
        onDiscardedLink: (String) -> Void = { _ in }
    ) -> [String] {
        guard directoryExists(at: root) else {
            return fileExists(at: root) && isIncluded(root) ? [root] : []
        }
        var result: [String] = []
        // 심볼릭 링크가 상위 디렉터리를 가리키면 같은 트리를 끝없이 다시 걷는다.
        // 파일 하나짜리 트리가 서른 개 경로로 부풀어 오르는 것을 실제로 확인했다.
        // 실제 경로 기준으로 방문 여부를 기록해 한 번씩만 본다.
        //
        // 경로의 어느 구성 요소도 링크가 아니면 문자열 철자가 곧 실제 경로와
        // 일대일이므로, 환산 비용은 링크가 끼어든 경로에만 치른다. 링크가 아닌
        // 자식의 방문 키는 부모 키에 이름을 붙인 것으로 충분하다 — 부모 키가
        // 실제 경로면 그 아래 이름 철자도 실제 경로이고, 아니면 둘 다 같은
        // 철자로만 도달 가능하다.
        var visited: Set<String> = []
        var visitedFiles: Set<String> = []
        // 루트는 해석된 철자로 열거한다. 예전 Foundation 구현이 돌려준 경로는
        // realpath 수준으로 풀린 철자였기 때문에 `/var`·`/tmp`처럼 링크가 끼어든
        // 조상 아래에서도 실제 경로가 반환됐다 — 인덱스 스토어가 기록한 철자와
        // 맞춰야 파일 단위 조회(최신 unit 시각)가 맞는다. 중간 링크까지 푸는
        // 것은 realpath 뿐이며 canonicalPath 는 마지막 구성 요소만 본다.
        let resolvedRoot = (try? realPath(at: root)) ?? Self.canonicalPath(root)
        var pending: [(path: String, key: String)] = [(resolvedRoot, resolvedRoot)]

        while let directory = pending.popLast() {
            guard visited.insert(directory.key).inserted else { continue }
            onDirectory(directory.path)
            guard let entries = try? directoryEntries(at: directory.path)
            else { continue }
            for entry in entries {
                // 링크 항목의 키도 루트와 같은 realpath 수준으로 풀어야 한다.
                // canonicalPath 는 마지막 구성 요소만 풀어, 링크 대상이 링크 조상
                // 아래에 있으면 루트 키와 다른 철자가 되어 같은 파일을 두 번 센다.
                // 방문 집합에만 쓰이므로 걸러지는 파일에는 환산 비용을 치르지 않는다.
                func visitKey() -> String {
                    entry.isSymbolicLink
                        ? (try? realPath(at: entry.path)) ?? Self.canonicalPath(entry.path)
                        : directory.key + "/" + (entry.path as NSString).lastPathComponent
                }
                if entry.isDirectory {
                    if shouldDescend(entry.path) { pending.append((entry.path, visitKey())) }
                } else if entry.isRegularFile, isIncluded(entry.path) {
                    // 끊어진 심볼릭 링크는 일반 파일이 아니다. 그것을 소스 파일로 세면
                    // 읽는 쪽에서 실패하거나 유령 정점이 된다.
                    // 같은 파일을 가리키는 두 이름은 한 번만 센다.
                    guard visitedFiles.insert(visitKey()).inserted else {
                        // 버려진 이름도 나중에 다른 파일을 가리킬 수 있다 — 재지정은
                        // 부모 디렉터리 지문에는 드러나지 않으니 따로 감시한다.
                        if entry.isSymbolicLink { onDiscardedLink(entry.path) }
                        continue
                    }
                    result.append(entry.path)
                }
            }
        }
        return result.sorted()
    }
}

extension FileSystem {
    /// 심볼릭 링크를 풀고 표준화한 절대 경로.
    ///
    /// macOS에서 `/tmp`와 `/private/tmp`처럼 동일한 물리적 위치를 가리키는 서로 다른 표기나
    /// 상대 경로 표현을 일관되게 비교하고 방문 집합을 관리하기 위해 쓴다.
    public func canonicalPath(_ path: String) -> String {
        Self.canonicalPath(path)
    }

    /// 심볼릭 링크를 풀고 표준화한 절대 경로.
    ///
    /// macOS에서 `/tmp`와 `/private/tmp`처럼 동일한 물리적 위치를 가리키는 서로 다른 표기나
    /// 상대 경로 표현을 일관되게 비교하고 방문 집합을 관리하기 위해 쓴다.
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// 실제 디스크를 사용하는 기본 구현.
///
/// 상태를 갖지 않으므로 그대로 Sendable 이다. FileManager.default 는
/// 여기서 쓰는 연산에 한해 스레드 안전하다.
public struct LocalFileSystem: FileSystem {
    public init() {}

    /// Foundation은 `/private/tmp`를 `/tmp`로 되돌리므로 언어 간 식별에는 POSIX 경로를 쓴다.
    public func realPath(at path: String) throws -> String {
        guard !path.utf8.contains(0) else { throw CocoaError(.fileReadInvalidFileName) }
        guard let resolved = realpath(path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

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

    public func removeItem(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    public func contentsOfDirectory(at path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
            .map { (path as NSString).appendingPathComponent($0) }
            .sorted()
    }

    /// 열거 한 번으로 종류까지 받아 온다.
    ///
    /// `readdir` 의 `d_type` 이 종류를 함께 주므로 항목마다 stat 을 부르지 않는다.
    /// 심볼릭 링크만 대상을 확인하기 위해 stat 을 한 번 더 한다. 큰 저장소의
    /// 세션 입력 지문 계산은 이 순회가 지배적이라 Foundation 의 URL 기반 열거를
    /// 쓰지 않는다.
    public func directoryEntries(at path: String) throws -> [DirectoryEntry] {
        // opendir 는 심볼릭 링크를 따라가므로, 링크로 지정된 루트도 예외 없이 연다.
        guard let stream = path.withCString({ opendir($0) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closedir(stream) }
        // 경로 자체가 심볼릭 링크면 자식 철자를 실제 경로로 맞춘다. 예전 구현의
        // ENOTDIR 재시도가 돌려주던 것과 같은 철자다 — 그대로 두면 링크로 지정된
        // 루트 아래 경로가 실제 경로 접두사로 상대화되지 않는다. 링크 경로의
        // 조상에도 링크가 낄 수 있으니 realpath 로 통째로 푼다.
        var info = Darwin.stat()
        let childBase = path.withCString({ lstat($0, &info) }) == 0
            && info.st_mode & 0o170000 == 0o120000
            ? (try? realPath(at: path)) ?? Self.canonicalPath(path) : path
        // NSString 경로 조립을 피한다 — appendingPathComponent 가 돌려주는 문자열은
        // 해시할 때 NSString 을 거쳐 네이티브 String 연결보다 한 자릿수 이상 느리다.
        // 이 목록의 경로는 세션 지문에서 항목마다 집합·맵 키로 해시된다.
        let separator = childBase.hasSuffix("/") ? "" : "/"
        var entries: [DirectoryEntry] = []
        while let item = readdir(stream) {
            // d_name 은 고정 크기 튜플이라 전체를 복사하지 않고 길이만큼만 디코딩한다.
            let name = withUnsafeBytes(of: &item.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(item.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            entries.append(classify(at: childBase + separator + name,
                                    type: Int32(item.pointee.d_type)))
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// `d_type` 에 없는 종류(심볼릭 링크의 대상·`DT_UNKNOWN`)만 stat 으로 확인한다.
    private func classify(at path: String, type: Int32) -> DirectoryEntry {
        if type == DT_UNKNOWN {
            // d_type 을 주지 않는 파일 시스템에서는 항목 자체를 lstat 한다.
            var info = Darwin.stat()
            guard path.withCString({ lstat($0, &info) }) == 0 else {
                return DirectoryEntry(path: path, isDirectory: false,
                                      isRegularFile: false, isSymbolicLink: false)
            }
            if info.st_mode & 0o170000 == 0o120000 {
                return classifyLinked(at: path)
            }
            return DirectoryEntry(
                path: path,
                isDirectory: info.st_mode & 0o170000 == 0o040000,
                isRegularFile: info.st_mode & 0o170000 == 0o100000,
                isSymbolicLink: false
            )
        }
        if type == DT_LNK {
            return classifyLinked(at: path)
        }
        return DirectoryEntry(
            path: path,
            isDirectory: type == DT_DIR,
            isRegularFile: type == DT_REG,
            isSymbolicLink: false
        )
    }

    /// 심볼릭 링크 항목의 대상 종류를 stat 으로 확인한다. 끊어진 링크는 둘 다 거짓이다.
    private func classifyLinked(at path: String) -> DirectoryEntry {
        var info = Darwin.stat()
        let resolved = path.withCString { stat($0, &info) }
        return DirectoryEntry(
            path: path,
            isDirectory: resolved == 0 && info.st_mode & 0o170000 == 0o040000,
            isRegularFile: resolved == 0 && info.st_mode & 0o170000 == 0o100000,
            isSymbolicLink: true
        )
    }

    public func modificationDate(at path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// 내용 재사용 여부를 판단할 수 있도록 stat의 전체 파일 상태를 읽는다.
    public func fingerprintStamp(at path: String) -> FileFingerprintStamp? {
        guard !path.utf8.contains(0) else { return nil }
        var leaf = Darwin.stat()
        let leafStatus = path.withCString { pointer in
            withUnsafeMutablePointer(to: &leaf) { output in
                lstat(pointer, output)
            }
        }
        guard leafStatus == 0 else { return nil }
        var info = Darwin.stat()
        let result = path.withCString { pointer in
            withUnsafeMutablePointer(to: &info) { output in
                stat(pointer, output)
            }
        }
        guard result == 0, info.st_size >= 0 else { return nil }
        // 링크가 아닌 파일의 해결 경로는 입력 철자와 같다. realpath 는 경로의 각
        // 구성 요소에 lstat 을 거치므로 끝 요소가 실제로 링크일 때만 부른다.
        let resolvedPath: String
        if leaf.st_mode & 0o170000 == 0o120000 {
            guard let resolved = try? realPath(at: path) else { return nil }
            resolvedPath = resolved
        } else {
            resolvedPath = path
        }
        return FileFingerprintStamp(
            resolvedPath: resolvedPath,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            mode: UInt32(info.st_mode)
        )
    }

    /// 항목 구성 감시는 stat 한 번으로 충분하다. 파일 지문과 달리 realpath 를
    /// 부르지 않는다 — 경로 해석은 구성 요소마다 lstat 을 거치므로 깊은 트리의
    /// 디렉터리마다 몇 배 비싸다. 링크가 다른 대상을 가리키면 stat 이 따라간
    /// 대상의 inode 로 드러난다.
    public func directoryListingStamp(at path: String) -> DirectoryListingStamp? {
        guard !path.utf8.contains(0) else { return nil }
        var info = Darwin.stat()
        let result = path.withCString { pointer in
            withUnsafeMutablePointer(to: &info) { output in
                stat(pointer, output)
            }
        }
        guard result == 0, info.st_size >= 0 else { return nil }
        return DirectoryListingStamp(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            mode: UInt32(info.st_mode)
        )
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
        ".swift-build", ".benchmark-results", ".omc",
    ]

    /// `recursiveFiles(under:isIncluded:shouldDescend:)` 에 그대로 넘길 수 있는 판정.
    public static func shouldDescend(into path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return !prunedNames.contains(name) && !name.hasPrefix(".build-")
    }
}
