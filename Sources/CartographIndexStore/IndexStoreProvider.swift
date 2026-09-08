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
        /// 브리지 식별자를 읽을 때만 Clang 구현 파일도 포함한다.
        public var includeObjectiveCSources: Bool

        public init(
            storePath: String,
            databasePath: String,
            libraryPath: String,
            sourceRoots: [String],
            pathFilter: PathFilter = .passthrough,
            includeExternalSymbols: Bool = false,
            includeObjectiveCSources: Bool = false
        ) {
            self.storePath = storePath
            self.databasePath = databasePath
            self.libraryPath = libraryPath
            self.sourceRoots = sourceRoots
            self.pathFilter = pathFilter
            self.includeExternalSymbols = includeExternalSymbols
            self.includeObjectiveCSources = includeObjectiveCSources
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
        var snapshot = Self.snapshot(from: occurrences, includeExternalSymbols: configuration.includeExternalSymbols)
        snapshot.indexedFileDates = Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            database.dateOfLatestUnitFor(filePath: path).map { (path, $0) }
        })
        return snapshot
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
                isIncluded: { path in
                    let extensions = configuration.includeObjectiveCSources ? [".swift", ".m", ".mm"] : [".swift"]
                    return extensions.contains(where: path.hasSuffix) && configuration.pathFilter.allows(path)
                },
                shouldDescend: BuildArtifactDirectories.shouldDescend(into:)
            )
            for file in files where seen.insert(file).inserted {
                result.append(file)
            }
        }
        return result.sorted()
    }

    /// 발생 목록을 스냅샷으로 접는다.
    ///
    /// 같은 USR 의 선언이 여러 번 나타나면(부분 선언, 여러 타깃에서의 재컴파일)
    /// 먼저 만난 것을 대표로 삼고 정렬로 결정성을 지킨다.
    static func snapshot(
        from occurrences: [SymbolOccurrence],
        includeExternalSymbols: Bool
    ) -> IndexSnapshot {
        var symbolsByUSR: [String: IndexedSymbol] = [:]
        var definedUSRs: Set<String> = []
        var references: [IndexedReference] = []
        // 관계 없이 기록된 참조와, 그것을 붙일 후보가 되는 정의 위치들.
        var unattributed: [(usr: String, location: SourceLocation)] = []
        var definitionSites: [String: [(usr: String, location: SourceLocation)]] = [:]

        for occurrence in occurrences {
            if let symbol = IndexStoreMapping.indexedSymbol(from: occurrence) {
                let isDefinition = occurrence.roles.contains(.definition)
                if let existing = symbolsByUSR[symbol.usr] {
                    // 정의의 위치를 우선한다. 선언만 있는 발생의 줄 번호로는
                    // 구문 정보를 붙일 때 엉뚱한 자리를 짚는다.
                    let base = isDefinition && !definedUSRs.contains(symbol.usr) ? symbol : existing
                    symbolsByUSR[symbol.usr] = IndexedSymbol(
                        usr: base.usr,
                        name: base.name,
                        kind: base.kind,
                        module: base.module,
                        location: base.location,
                        // 같은 심볼이라도 부모 정보가 붙은 발생이 더 쓸모 있다.
                        parentUSR: existing.parentUSR ?? symbol.parentUSR,
                        isExternal: base.isExternal,
                        accessibility: base.accessibility,
                        attributes: existing.attributes.union(symbol.attributes)
                    )
                } else {
                    symbolsByUSR[symbol.usr] = symbol
                }
                if isDefinition { definedUSRs.insert(symbol.usr) }
            }
            let occurrenceReferences = IndexStoreMapping.references(from: occurrence)
            references.append(contentsOf: occurrenceReferences)

            let location = IndexStoreMapping.sourceLocation(occurrence.location)
            if occurrence.roles.contains(.definition) {
                definitionSites[location.path, default: []].append((occurrence.symbol.usr, location))
            } else if occurrenceReferences.isEmpty, occurrence.roles.contains(.reference),
                      !occurrence.roles.contains(.implicit) {
                // 암시적 발생은 매크로가 펼친 코드다. 위치가 사용자가 쓴 자리가 아니라
                // 속성 줄이라, 위치로 소유자를 찾으면 앞 선언에 붙는다.
                unattributed.append((occurrence.symbol.usr, location))
            }

            // 최상위 문장이 실제로 참조를 만들었을 때만 가상 심볼을 세운다.
            let topLevelUSR = IndexStoreMapping.topLevelCodeUSR(forFile: occurrence.location.path)
            if symbolsByUSR[topLevelUSR] == nil,
               occurrenceReferences.contains(where: { $0.sourceUSR == topLevelUSR }) {
                symbolsByUSR[topLevelUSR] = IndexStoreMapping.topLevelCodeSymbol(
                    path: occurrence.location.path,
                    module: occurrence.location.moduleName
                )
            }
        }

        if includeExternalSymbols {
            for occurrence in occurrences {
                guard symbolsByUSR[occurrence.symbol.usr] == nil,
                      let external = IndexStoreMapping.externalSymbol(from: occurrence)
                else { continue }
                symbolsByUSR[external.usr] = external
            }
        }

        references += enclosingReferences(
            for: unattributed, definitionSites: definitionSites, symbols: symbolsByUSR
        )

        // 접근자와 프로퍼티 래퍼 곁가지를 모두 원래 선언으로 되돌린다.
        let owners = IndexStoreMapping.accessorOwners(in: occurrences)
            .merging(IndexStoreMapping.propertyWrapperFacets(in: Array(symbolsByUSR.values))) { first, _ in first }
        let resolved = IndexStoreMapping.resolvingSynthesizedSymbols(references, owners: owners)

        // 심볼은 정렬한다. 사전으로 접을 때 같은 USR 이 겹치면 앞의 것이 이기므로
        // 순서가 결과에 남는다. 참조는 정렬하지 않는다 — `CodeGraph.init` 이 간선을
        // 서명으로 접고 다시 정렬하기 때문에 여기서의 순서는 출력에 닿지 않는다.
        // 참조 수는 심볼 수의 열 배 규모라 이 정렬만 없애도 명령마다 눈에 띄게 준다.
        return IndexSnapshot(
            symbols: symbolsByUSR.values.sorted { $0.usr < $1.usr },
            references: resolved
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
            // 일회성 CLI 에 맞는 조합이다. IndexDatastoreImpl::init 을 보면
            // listenToUnitEvents 가 거짓이고 wait 가 참일 때 초기 스캔을 동기로 한 번
            // 수행하고 끝난다. 참으로 두면 FSEvents 리스너와 백그라운드 워커가 뜨고,
            // 빌드가 동시에 스토어를 쓰면 파일마다 다른 시점의 데이터를 읽게 된다.
            //
            // readonly 는 거짓이어야 한다. 참이면 같은 함수가 유닛을 넣기 전에
            // 곧바로 반환해 빈 인덱스가 된다. 여기서 쓰는 데이터베이스는 우리가
            // 만드는 캐시이므로 쓰기가 필요하다.
            return try IndexStoreDB(
                storePath: configuration.storePath,
                databasePath: configuration.databasePath,
                library: library,
                waitUntilDoneInitializing: true,
                readonly: false,
                listenToUnitEvents: false
            )
        } catch {
            throw CartographError.indexStoreUnreadable(
                path: configuration.storePath,
                underlying: "\(error)"
            )
        }
    }

    /// 인덱서가 담고 있는 관계를 남기지 않는 선언 자리들.
    ///
    /// 열거형 케이스의 연관 값 타입, 타입 별칭의 우변, `associatedtype` 증인이 그렇다.
    /// 다른 자리에서는 인덱서가 `containedBy` 를 붙여 주므로, 관계 없는 참조가 나타났다면
    /// 그것은 매크로가 펼친 코드일 가능성이 높다. 넓게 잡으면 그 코드가 앞 선언에 붙어
    /// 없는 의존성을 만들고, 순환 검사에서 거짓 발견이 된다. 실제로 `@Observable` 이
    /// 그 모양으로 두 건을 만들었다.
    static let omitsContainment: Set<SymbolKind> = [.enumCase, .typeAlias, .associatedType]

    /// 관계 없이 기록된 참조를 감싸는 선언에 붙인다.
    ///
    /// 인덱서는 열거형 케이스의 연관 값 타입, 타입 별칭의 우변, `associatedtype` 증인이
    /// 가리키는 타입을 `ref` 로 남기면서 **어떤 관계도 달지 않는다.** 관계가 있을 때만
    /// 간선을 만들면 이런 타입은 아무도 쓰지 않는 것처럼 보이고, 실제로는 지우면 컴파일이
    /// 깨진다. 오늘은 합성 이니셜라이저 보존이 우연히 그것들을 살리고 있다.
    ///
    /// 같은 파일에서 그 참조보다 앞에 있는 가장 가까운 정의에 붙인다. 인덱스는 선언의
    /// 범위를 주지 않으므로 시작 위치만으로 판단한다. 틀려도 간선이 하나 더 생길 뿐이라
    /// 보존이 늘고 없는 발견을 만들지 않는다. 이 저장소가 택하는 방향이다.
    static func enclosingReferences(
        for unattributed: [(usr: String, location: SourceLocation)],
        definitionSites: [String: [(usr: String, location: SourceLocation)]],
        symbols: [String: IndexedSymbol]
    ) -> [IndexedReference] {
        let sorted = definitionSites.mapValues { $0.sorted { $0.location < $1.location } }
        return unattributed.compactMap { entry in
            guard let owner = enclosingDefinition(of: entry.location, in: sorted[entry.location.path] ?? []),
                  owner != entry.usr,
                  let kind = symbols[owner]?.kind, Self.omitsContainment.contains(kind)
            else { return nil }
            return IndexedReference(
                sourceUSR: owner, targetUSR: entry.usr, kind: .reference, location: entry.location
            )
        }
    }

    /// 위치보다 **엄격히** 앞에 있는 가장 가까운 정의. 위치로 정렬된 목록을 이분 탐색한다.
    ///
    /// 같은 위치의 정의는 건너뛴다. 이름 없는 파라미터는 자기 타입과 같은 자리에 기록되어,
    /// `case broke(PayloadOnly)` 에서 그 파라미터가 소유자로 뽑힌다. 파라미터는 그래프의
    /// 정점이 아니라 간선이 통째로 사라진다.
    ///
    /// 파일 하나에 정의가 수천 개인 프로젝트가 있어 선형 탐색을 쓰지 않는다.
    private static func enclosingDefinition(
        of location: SourceLocation,
        in sites: [(usr: String, location: SourceLocation)]
    ) -> String? {
        var low = 0
        var high = sites.count
        while low < high {
            let middle = (low + high) / 2
            if sites[middle].location < location { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? sites[low - 1].usr : nil
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
    ///
    /// 라이브러리 정보에 기본값을 두지 않는다. Xcode 의 DerivedData 경로는 툴체인이
    /// 바뀌어도 그대로라, 빠뜨리면 이 함수가 막으려던 바로 그 상황이 조용히 벌어진다.
    /// 갱신 시각은 읽지 못할 수 있어 옵셔널로 둔다.
    public static func defaultDatabasePath(
        forStore storePath: String,
        libraryPath: String,
        libraryModificationDate: Date?
    ) -> String {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cartograph-index-db")
        let identity = [
            storePath,
            libraryPath,
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
