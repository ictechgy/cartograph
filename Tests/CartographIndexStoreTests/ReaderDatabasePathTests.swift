import Testing
import Foundation
import CartographCore
import CartographTestSupport
@testable import CartographIndexStore

/// 판독기 DB 는 사라진 유닛을 잊지 못해 유령 유닛이 파일 발생을 삼키는
/// 버그가 있었다. 유닛 집합 지문을 DB 경로에 섞어, 유닛이 바뀌면 새 DB 로
/// 갈아타는 계약을 고정한다.
@Suite("판독기 DB 경로")
struct ReaderDatabasePathTests {
    private func provider(
        fileSystem: any FileSystem,
        storePath: String = "/store"
    ) -> IndexStoreProvider {
        IndexStoreProvider(
            configuration: .init(
                storePath: storePath,
                databasePath: "/db",
                libraryPath: "/lib.dylib",
                sourceRoots: ["/src"]
            ),
            fileSystem: fileSystem
        )
    }

    @Test("유닛 집합이 바뀌면 판독기 DB 경로가 달라진다")
    func pathChangesWithUnits() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/v5/units/main.o-AAA")
        let first = provider(fileSystem: fileSystem).prepareReaderDatabase()

        try fileSystem.write(text: "u2", to: "/store/v5/units/other.o-BBB")
        let second = provider(fileSystem: fileSystem).prepareReaderDatabase()

        #expect(first != second)
        #expect(first.hasPrefix("/db-"))
        #expect(second.hasPrefix("/db-"))
    }

    @Test("유닛 집합이 같으면 판독기 DB 경로가 같다")
    func pathStableForSameUnits() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/v5/units/main.o-AAA")
        try fileSystem.write(text: "u2", to: "/store/v5/units/other.o-BBB")

        let first = provider(fileSystem: fileSystem).prepareReaderDatabase()
        let second = provider(fileSystem: fileSystem).prepareReaderDatabase()

        #expect(first == second)
    }

    @Test("유닛 집합이 같은 개수로 교체돼도 판독기 DB 경로가 달라진다")
    func pathChangesWhenSameCountUnitsAreSwapped() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/v5/units/main.o-AAA")
        try fileSystem.write(text: "u2", to: "/store/v5/units/other.o-BBB")
        let first = provider(fileSystem: fileSystem).prepareReaderDatabase()

        // 지워진 유닛을 다른 유닛이 대신하는 일반 재빌드 형태 — 개수는
        // 그대로지만 집합이 달라졌으므로 낡은 DB 를 재사용하면 유령이 온다.
        try fileSystem.removeItem(at: "/store/v5/units/other.o-BBB")
        try fileSystem.write(text: "u3", to: "/store/v5/units/other.o-CCC")

        #expect(provider(fileSystem: fileSystem).prepareReaderDatabase() != first)
    }

    @Test("유닛 일부가 지워져도 판독기 DB 경로가 달라진다")
    func pathChangesWhenUnitDeleted() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/v5/units/main.o-AAA")
        try fileSystem.write(text: "u2", to: "/store/v5/units/other.o-BBB")
        let first = provider(fileSystem: fileSystem).prepareReaderDatabase()

        try fileSystem.removeItem(at: "/store/v5/units/other.o-BBB")

        // 유닛이 지워져도 남은 목록으로 지문을 만들어 새 DB 를 연다 —
        // 지워진 유닛을 담은 낡은 DB 로는 돌아가지 않는다.
        let second = provider(fileSystem: fileSystem).prepareReaderDatabase()
        #expect(second != first)
        #expect(second.hasPrefix("/db-"))
        #expect(!second.hasSuffix("-unverified"))
    }

    @Test("유닛 디렉터리를 못 읽으면 검증 못 한 전용 경로를 쓴다")
    func fallsBackToUnverifiedPathWithoutUnits() {
        let fileSystem = InMemoryFileSystem()
        let provider = provider(fileSystem: fileSystem)

        // 버전 없는 경로에는 지워진 유닛을 담은 낡은 DB 가 남아 있을 수
        // 있어 재사용하지 않는다.
        #expect(provider.prepareReaderDatabase() == "/db-unverified")
    }

    @Test("검증 못 한 경로는 열 때마다 지우고 다시 만든다")
    func unverifiedPathIsRecreatedOnOpen() {
        // 검증 못 한 DB 는 지워진 유닛을 담은 채 재사용될 수 있으므로
        // 열기 전에 항상 지운다 — 이것이 유령 유닛 버그의 재발 방지다.
        let fileSystem = InMemoryFileSystem(files: [
            "/db-unverified/data.mdb": "stale",
        ])
        let provider = provider(fileSystem: fileSystem)

        #expect(provider.prepareReaderDatabase() == "/db-unverified")
        #expect(!fileSystem.directoryExists(at: "/db-unverified"))
    }

    @Test("검증 못 한 경로를 지우지 못하면 낡은 DB 를 다시 열지 않는다")
    func unverifiedFallsBackToUniquePathWhenRemovalFails() throws {
        // 삭제가 실패한 낡은 `-unverified` 를 그대로 열면 유령 유닛 버그가
        // 그대로 재현된다 — 한 번만 쓰는 경로로 돌리고 낡은 DB 는 건드리지
        // 않는다. `FileSystem.removeItem` 의 기본 구현처럼 항상 던지는
        // 채택 타입에서도 이 경로로 빠진다.
        final class FailingRemoveFileSystem: FileSystem, @unchecked Sendable {
            let inner = InMemoryFileSystem()
            var currentDirectoryPath: String { inner.currentDirectoryPath }
            func realPath(at path: String) throws -> String { try inner.realPath(at: path) }
            func fileExists(at path: String) -> Bool { inner.fileExists(at: path) }
            func directoryExists(at path: String) -> Bool { inner.directoryExists(at: path) }
            func readData(at path: String) throws -> Data { try inner.readData(at: path) }
            func write(_ data: Data, to path: String) throws { try inner.write(data, to: path) }
            func removeItem(at _: String) throws { throw CocoaError(.featureUnsupported) }
            func contentsOfDirectory(at path: String) throws -> [String] {
                try inner.contentsOfDirectory(at: path)
            }
            func directoryEntries(at path: String) throws -> [DirectoryEntry] {
                try inner.directoryEntries(at: path)
            }
            func modificationDate(at path: String) -> Date? { inner.modificationDate(at: path) }
            func fingerprintStamp(at path: String) -> FileFingerprintStamp? {
                inner.fingerprintStamp(at: path)
            }
            func directoryListingStamp(at path: String) -> DirectoryListingStamp? {
                inner.directoryListingStamp(at: path)
            }
        }
        let fileSystem = FailingRemoveFileSystem()
        try fileSystem.inner.write(text: "stale", to: "/db-unverified/data.mdb")

        let path = provider(fileSystem: fileSystem).prepareReaderDatabase()
        #expect(path.hasPrefix("/db-unverified-"))
        #expect(fileSystem.inner.fileExists(at: "/db-unverified/data.mdb"))
    }

    @Test("지문을 못 만들면 형제를 정리하지 않는다")
    func unverifiedDoesNotPruneSiblings() {
        // 목록 실패가 일시적일 수 있으므로, 지문이 없을 때 검증된 캐시를
        // 지우는 것은 유령보다 나쁘다.
        let fileSystem = InMemoryFileSystem(files: [
            "/db-0123456789abcdef/data.mdb": "keep",
        ])
        let provider = provider(fileSystem: fileSystem)

        _ = provider.prepareReaderDatabase()
        #expect(fileSystem.directoryExists(at: "/db-0123456789abcdef"))
    }

    @Test("v5 없는 스토어는 units 디렉터리를 읽는다")
    func fallsBackToUnitsDirectory() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/units/main.o-AAA")
        let first = provider(fileSystem: fileSystem).prepareReaderDatabase()

        try fileSystem.write(text: "u2", to: "/store/units/other.o-BBB")

        #expect(first != provider(fileSystem: fileSystem).prepareReaderDatabase())
        #expect(first.hasPrefix("/db-"))
    }

    @Test("형제 판독기 DB 는 현재 것만 남기고 지운다")
    func prunesStaleSiblingDatabases() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/store/v5/units/main.o-AAA": "u1",
            // 지문을 못 만들던 시절의 버전 없는 경로와 다른 지문의 형제,
            // 그리고 삭제 실패 폴백이 남긴 unverified 형제.
            "/db/data.mdb": "stale",
            "/db-aaaaaaaaaaaaaaaa/data.mdb": "stale",
            "/db-bbbbbbbbbbbbbbbb/data.mdb": "stale",
            "/db-unverified/data.mdb": "stale",
            "/db-unverified-12345/data.mdb": "stale",
            // 이름이 비슷해도 다른 스토어의 DB(baseName 이 다름)는 건드리지 않는다.
            "/other-db/data.mdb": "keep",
            // 지문 형태가 아닌 접미도 우리 것이 아니다 — 백업 같은 무관한
            // 항목을 접두사만 맞는다고 지우면 안 된다. 16자가 안 되는
            // 16진 접미(`db-2024`, `db-dead`)도 호출자 소유일 수 있어 보존한다.
            "/db-backup/data.mdb": "keep",
            "/db-2024/data.mdb": "keep",
            "/db-dead/data.mdb": "keep",
        ])
        let provider = provider(fileSystem: fileSystem)
        let current = provider.prepareReaderDatabase()
        try fileSystem.write(text: "keep", to: "\(current)/data.mdb")

        provider.pruneStaleReaderDatabases(keeping: current)

        #expect(fileSystem.fileExists(at: "\(current)/data.mdb"))
        #expect(fileSystem.fileExists(at: "/other-db/data.mdb"))
        #expect(fileSystem.directoryExists(at: "/db-backup"))
        #expect(fileSystem.directoryExists(at: "/db-2024"))
        #expect(fileSystem.directoryExists(at: "/db-dead"))
        #expect(!fileSystem.directoryExists(at: "/db"))
        #expect(!fileSystem.directoryExists(at: "/db-aaaaaaaaaaaaaaaa"))
        #expect(!fileSystem.directoryExists(at: "/db-bbbbbbbbbbbbbbbb"))
        #expect(!fileSystem.directoryExists(at: "/db-unverified"))
        #expect(!fileSystem.directoryExists(at: "/db-unverified-12345"))
    }

    @Test("막 수정된 형제 DB 는 정리 유예가 지키다")
    func recentlyModifiedSiblingsSurvivePruning() throws {
        // 같은 스토어를 여는 다른 프로세스가 막 만든 DB 를 지우는 경쟁을
        // 줄인다 — 수정 시각이 유예 안쪽이면 이번 정리는 건너뛴다.
        let fileSystem = InMemoryFileSystem(files: [
            "/store/v5/units/main.o-AAA": "u1",
            "/db-aaaaaaaaaaaaaaaa/data.mdb": "young",
            "/db-bbbbbbbbbbbbbbbb/data.mdb": "old",
        ])
        fileSystem.setModificationDate(Date(), for: "/db-aaaaaaaaaaaaaaaa")
        fileSystem.setModificationDate(
            Date(timeIntervalSinceNow: -3600), for: "/db-bbbbbbbbbbbbbbbb")

        let provider = provider(fileSystem: fileSystem)
        let current = provider.prepareReaderDatabase()
        provider.pruneStaleReaderDatabases(keeping: current)

        #expect(fileSystem.directoryExists(at: "/db-aaaaaaaaaaaaaaaa"))
        #expect(!fileSystem.directoryExists(at: "/db-bbbbbbbbbbbbbbbb"))
    }
}
