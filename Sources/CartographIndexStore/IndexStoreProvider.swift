import CartographCore
import Foundation
import IndexStoreDB

/// IndexStoreDB 로 실제 인덱스를 읽어 스냅샷을 만든다.
///
/// 도구에서 유일하게 외부 상태(디스크의 인덱스 스토어)에 의존하는 지점이다.
/// 변환 규칙은 `IndexStoreMapping` 에 순수 함수로 빼 두었기 때문에,
/// 여기 남은 책임은 "열고, 파일을 훑고, 모으는 것" 뿐이다.
public struct IndexStoreProvider: IndexProviding {
    public struct Configuration: Sendable, Equatable {
        /// 컴파일러가 인덱스를 기록한 디렉터리.
        public var storePath: String
        /// IndexStoreDB 가 만들 LMDB 캐시 위치.
        public var databasePath: String
        /// libIndexStore 동적 라이브러리 경로.
        public var libraryPath: String
        /// 소스 파일을 찾기 시작할 디렉터리들.
        public var sourceRoots: [String]
        public var pathFilter: PathFilter
        /// SDK 등 외부 심볼도 정점 후보로 수집할지 여부.
        public var includeExternalSymbols: Bool

        public init(
            storePath: String,
            databasePath: String,
            libraryPath: String,
            sourceRoots: [String],
            pathFilter: PathFilter = .passthrough,
            includeExternalSymbols: Bool = false
        ) {
            self.storePath = storePath
            self.databasePath = databasePath
            self.libraryPath = libraryPath
            self.sourceRoots = sourceRoots
            self.pathFilter = pathFilter
            self.includeExternalSymbols = includeExternalSymbols
        }
    }

    private let configuration: Configuration
    private let fileSystem: any FileSystem

    public init(configuration: Configuration, fileSystem: any FileSystem = LocalFileSystem()) {
        self.configuration = configuration
        self.fileSystem = fileSystem
    }

    public func loadSnapshot() throws -> IndexSnapshot {
        let database = try openDatabase()
        let paths = sourceFilePaths()
        var occurrences: [SymbolOccurrence] = []
        for path in paths {
            occurrences.append(contentsOf: database.symbolOccurrences(inFilePath: path))
        }
        return Self.snapshot(from: occurrences, includeExternalSymbols: configuration.includeExternalSymbols)
    }

    /// 분석 대상 Swift 소스 파일 목록.
    ///
    /// 빌드 산출물과 체크아웃된 의존성 디렉터리에는 아예 들어가지 않는다.
    /// 큰 저장소에서는 이 가지치기만으로 탐색 시간이 몇 배 차이가 난다.
    func sourceFilePaths() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for root in configuration.sourceRoots {
            let files = fileSystem.recursiveFiles(
                under: root,
                isIncluded: { $0.hasSuffix(".swift") && configuration.pathFilter.allows($0) },
                shouldDescend: { !Self.prunedDirectoryNames.contains(($0 as NSString).lastPathComponent) }
            )
            for file in files where seen.insert(file).inserted {
                result.append(file)
            }
        }
        return result.sorted()
    }

    /// 들어가 봐야 소용없는 디렉터리 이름.
    static let prunedDirectoryNames: Set<String> = [
        ".build", ".git", "DerivedData", "Pods", "Carthage", "checkouts", ".swiftpm",
    ]

    /// 발생 목록을 스냅샷으로 접는다.
    ///
    /// 같은 USR 의 선언이 여러 번 나타나면(부분 선언, 여러 타깃에서의 재컴파일)
    /// 먼저 만난 것을 대표로 삼고 정렬로 결정성을 지킨다.
    static func snapshot(
        from occurrences: [SymbolOccurrence],
        includeExternalSymbols: Bool
    ) -> IndexSnapshot {
        var symbolsByUSR: [String: IndexedSymbol] = [:]
        var references: [IndexedReference] = []

        for occurrence in occurrences {
            if let symbol = IndexStoreMapping.indexedSymbol(from: occurrence) {
                if symbolsByUSR[symbol.usr] == nil {
                    symbolsByUSR[symbol.usr] = symbol
                } else if symbolsByUSR[symbol.usr]?.parentUSR == nil, symbol.parentUSR != nil {
                    // 같은 심볼이라도 부모 정보가 붙은 발생이 더 쓸모 있다.
                    symbolsByUSR[symbol.usr] = symbol
                }
            }
            references.append(contentsOf: IndexStoreMapping.references(from: occurrence))
        }

        if includeExternalSymbols {
            for occurrence in occurrences {
                guard symbolsByUSR[occurrence.symbol.usr] == nil,
                      let external = IndexStoreMapping.externalSymbol(from: occurrence)
                else { continue }
                symbolsByUSR[external.usr] = external
            }
        }

        return IndexSnapshot(
            symbols: symbolsByUSR.values.sorted { $0.usr < $1.usr },
            references: references.sorted {
                ($0.sourceUSR, $0.targetUSR, $0.kind.rawValue)
                    < ($1.sourceUSR, $1.targetUSR, $1.kind.rawValue)
            }
        )
    }

    private func openDatabase() throws -> IndexStoreDB {
        let library: IndexStoreLibrary
        do {
            library = try IndexStoreLibrary(dylibPath: configuration.libraryPath)
        } catch {
            throw CartographError.indexStoreLibraryNotFound(searchedPaths: [configuration.libraryPath])
        }

        do {
            return try IndexStoreDB(
                storePath: configuration.storePath,
                databasePath: configuration.databasePath,
                library: library,
                waitUntilDoneInitializing: true,
                readonly: false,
                listenToUnitEvents: true
            )
        } catch {
            throw CartographError.indexStoreUnreadable(
                path: configuration.storePath,
                underlying: "\(error)"
            )
        }
    }

    /// 인덱스 스토어마다 안정적으로 대응되는 캐시 디렉터리 경로.
    ///
    /// 매번 새로 만들면 대규모 프로젝트에서 초기화 비용이 크고, 한곳에 고정하면
    /// 스토어가 바뀔 때 낡은 캐시와 섞인다. 경로 해시를 이름에 넣어 둘 다 피한다.
    ///
    /// 해시에는 libIndexStore 의 경로와 갱신 시각도 넣는다. 인덱스 포맷은 하위 호환만
    /// 보장되어, 툴체인이 바뀐 뒤 예전 캐시를 그대로 열면 조용히 잘못된 결과가 나온다.
    /// 툴체인이 제자리에서 업데이트되는 경우(같은 경로, 새 버전)까지 잡으려면
    /// 경로만으로는 부족하다.
    public static func defaultDatabasePath(
        forStore storePath: String,
        libraryPath: String? = nil,
        libraryModificationDate: Date? = nil
    ) -> String {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cartograph-index-db")
        let identity = [
            storePath,
            libraryPath ?? "",
            libraryModificationDate.map { String($0.timeIntervalSince1970) } ?? "",
        ].joined(separator: "\u{0}")
        return (directory as NSString).appendingPathComponent(stableHash(identity))
    }

    /// 경로용 안정 해시(FNV-1a 64비트).
    ///
    /// Swift 의 Hasher 는 실행마다 시드가 달라 파일 이름으로 쓸 수 없다.
    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
