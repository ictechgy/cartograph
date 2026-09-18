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

    @Test("유닛 디렉터리가 없으면 기존 경로를 그대로 쓴다")
    func pathUnchangedWithoutUnits() {
        let fileSystem = InMemoryFileSystem()
        let provider = provider(fileSystem: fileSystem)

        #expect(provider.effectiveDatabasePath() == "/db")
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
}
