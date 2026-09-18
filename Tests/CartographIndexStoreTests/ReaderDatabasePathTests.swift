import Testing
import CartographCore
import CartographTestSupport
@testable import CartographIndexStore

/// 판독기 DB 는 사라진 유닛을 잊지 못해 유령 유닛이 파일 발생을 삼키는
/// 버그가 있었다. 유닛 집합 지문을 DB 경로에 섞어, 유닛이 바뀌면 새 DB 로
/// 갈아타는 계약을 고정한다.
@Suite("판독기 DB 경로")
struct ReaderDatabasePathTests {
    private func provider(
        fileSystem: InMemoryFileSystem,
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
        let first = provider(fileSystem: fileSystem).effectiveDatabasePath()

        try fileSystem.write(text: "u2", to: "/store/v5/units/other.o-BBB")
        let second = provider(fileSystem: fileSystem).effectiveDatabasePath()

        #expect(first != second)
        #expect(first.hasPrefix("/db-"))
        #expect(second.hasPrefix("/db-"))
    }

    @Test("유닛 집합이 같으면 판독기 DB 경로가 같다")
    func pathStableForSameUnits() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/v5/units/main.o-AAA")
        try fileSystem.write(text: "u2", to: "/store/v5/units/other.o-BBB")

        let first = provider(fileSystem: fileSystem).effectiveDatabasePath()
        let second = provider(fileSystem: fileSystem).effectiveDatabasePath()

        #expect(first == second)
    }

    @Test("유닛 집합이 같은 개수로 교체돼도 판독기 DB 경로가 달라진다")
    func pathChangesWhenSameCountUnitsAreSwapped() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/v5/units/main.o-AAA")
        try fileSystem.write(text: "u2", to: "/store/v5/units/other.o-BBB")
        let first = provider(fileSystem: fileSystem).effectiveDatabasePath()

        // 지워진 유닛을 다른 유닛이 대신하는 일반 재빌드 형태 — 개수는
        // 그대로지만 집합이 달라졌으므로 낡은 DB 를 재사용하면 유령이 온다.
        try fileSystem.removeItem(at: "/store/v5/units/other.o-BBB")
        try fileSystem.write(text: "u3", to: "/store/v5/units/other.o-CCC")

        #expect(provider(fileSystem: fileSystem).effectiveDatabasePath() != first)
    }

    @Test("유닛 일부가 지워져도 판독기 DB 경로가 달라진다")
    func pathChangesWhenUnitDeleted() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/v5/units/main.o-AAA")
        try fileSystem.write(text: "u2", to: "/store/v5/units/other.o-BBB")
        let first = provider(fileSystem: fileSystem).effectiveDatabasePath()

        try fileSystem.removeItem(at: "/store/v5/units/other.o-BBB")

        // 유닛이 지워져도 남은 목록으로 지문을 만들어 새 DB 를 연다 —
        // 지워진 유닛을 담은 낡은 DB 로는 돌아가지 않는다.
        let second = provider(fileSystem: fileSystem).effectiveDatabasePath()
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
        #expect(provider.effectiveDatabasePath() == "/db-unverified")
    }

    @Test("v5 없는 스토어는 units 디렉터리를 읽는다")
    func fallsBackToUnitsDirectory() throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.write(text: "u1", to: "/store/units/main.o-AAA")
        let first = provider(fileSystem: fileSystem).effectiveDatabasePath()

        try fileSystem.write(text: "u2", to: "/store/units/other.o-BBB")

        #expect(first != provider(fileSystem: fileSystem).effectiveDatabasePath())
        #expect(first.hasPrefix("/db-"))
    }

    @Test("형제 판독기 DB 는 현재 것만 남기고 지운다")
    func prunesStaleSiblingDatabases() throws {
        let fileSystem = InMemoryFileSystem(files: [
            "/store/v5/units/main.o-AAA": "u1",
            // 지문을 못 만들던 시절의 버전 없는 경로와 다른 지문의 형제.
            "/db/data.mdb": "stale",
            "/db-aaa/data.mdb": "stale",
            "/db-bbb/data.mdb": "stale",
            // 이름이 비슷해도 다른 스토어의 DB(baseName 이 다름)는 건드리지 않는다.
            "/other-db/data.mdb": "keep",
        ])
        let provider = provider(fileSystem: fileSystem)
        let current = provider.effectiveDatabasePath()
        try fileSystem.write(text: "keep", to: "\(current)/data.mdb")

        provider.pruneStaleReaderDatabases(keeping: current)

        #expect(fileSystem.fileExists(at: "\(current)/data.mdb"))
        #expect(fileSystem.fileExists(at: "/other-db/data.mdb"))
        #expect(!fileSystem.directoryExists(at: "/db"))
        #expect(!fileSystem.directoryExists(at: "/db-aaa"))
        #expect(!fileSystem.directoryExists(at: "/db-bbb"))
    }
}
