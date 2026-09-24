import CartographCore
@testable import CartographSyntax
import Testing

@Suite("스키마 사실 스캐너")
struct SchemaFactScannerTests {
    private func scan(_ source: String, path: String = "/p/Store.swift") -> SchemaScanResult {
        SchemaFactScanner().scan(source: source, path: path)
    }

    private func channels(_ source: String, path: String = "/p/Store.swift") -> [String] {
        scan(source, path: path).facts.map(\.fact).compactMap(\.channel)
    }

    // MARK: sqlite3

    @Test("sqlite3 인자 위치의 SQL 리터럴에서 관계를 읽는다")
    func sqlite3Arguments() {
        let source = """
            import SQLite3
            func purge(db: OpaquePointer) {
                sqlite3_prepare_v2(db, "DELETE FROM sessions WHERE expired = 1", -1, &stmt, nil)
                sqlite3_exec(db, "INSERT INTO audit (id) VALUES (1)", nil, nil, nil)
            }
            """
        #expect(channels(source).sorted() == ["audit", "sessions"])
    }

    @Test("sqlite3 인자가 리터럴이 아니면 동적 사실로 남긴다")
    func sqlite3DynamicArgument() {
        let source = """
            import SQLite3
            func purge(db: OpaquePointer, sql: String) {
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            }
            """
        let result = scan(source)
        #expect(result.facts.count == 1)
        #expect(result.facts.first?.fact.isDynamic == true)
        #expect(result.facts.first?.fact.channel == "sql")
        #expect(result.counts.unjoinedDynamic == 1)
    }

    @Test("sqlite3 인자의 보간 리터럴은 접두사와 함께 동적 사실로 남는다")
    func sqlite3InterpolatedArgument() {
        let source = """
            import SQLite3
            func purge(db: OpaquePointer, name: String) {
                sqlite3_prepare_v2(db, "DELETE FROM \\(name) WHERE expired = 1", -1, &stmt, nil)
            }
            """
        let result = scan(source)
        #expect(result.facts.count == 1)
        #expect(result.facts.first?.fact.isDynamic == true)
        #expect(result.facts.first?.fact.channelPrefix == "DELETE FROM ")
    }

    @Test("프레임워크 import가 없으면 sqlite3 형태의 호출을 읽지 않는다")
    func sqlite3RequiresImport() {
        let source = """
            func purge(db: OpaquePointer, sql: String) {
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            }
            """
        let result = scan(source)
        #expect(result.facts.isEmpty)
        #expect(result.counts.unjoinedDynamic == 0)
    }

    @Test("import가 없어도 호출 안의 대문자 SQL 리터럴은 게이트 없는 경로로 읽힌다")
    func ungatedLiteralInsideUngatedCall() {
        let source = """
            func purge(db: OpaquePointer) {
                sqlite3_prepare_v2(db, "DELETE FROM sessions", -1, &stmt, nil)
            }
            """
        #expect(channels(source) == ["sessions"])
    }

    // MARK: GRDB

    @Test("GRDB의 sql: 인자와 Table 생성자에서 관계를 읽는다")
    func grdbSurfaces() {
        let source = """
            import GRDB
            func migrate(db: Database) throws {
                try db.execute(sql: "INSERT INTO items (id) VALUES (1)")
                let users = Table("users")
                try db.create(table: "audit")
            }
            """
        #expect(channels(source).sorted() == ["audit", "items", "users"])
    }

    @Test("GRDB databaseTableName 선언 자리가 관계 사실이 된다")
    func grdbDatabaseTableName() {
        let source = """
            import GRDB
            struct Player: FetchableRecord, PersistableRecord {
                static let databaseTableName = "players"
            }
            """
        let facts = scan(source).facts.map(\.fact)
        #expect(facts.count == 1)
        #expect(facts.first?.channel == "players")
        #expect(facts.first?.kind == .relationUse)
        #expect(facts.first?.target == .persistence)
        #expect(facts.first?.isDynamic == false)
    }

    @Test("static var databaseTableName의 단일 getter도 읽는다")
    func grdbComputedTableName() {
        let source = """
            import GRDB
            struct Player: FetchableRecord {
                static var databaseTableName: String { "players" }
            }
            """
        #expect(channels(source) == ["players"])
    }

    @Test("테이블 바인딩된 수신자의 호출은 관계 사용이고 Column 인자는 컬럼이다")
    func tableBoundReceiverColumns() {
        let source = """
            import GRDB
            let users = Table("users")
            func active(db: Database) throws {
                try users.filter(Column("active") == true).fetchAll(db)
            }
            """
        let facts = scan(source).facts.map(\.fact)
        let column = facts.first { $0.method != nil }
        #expect(facts.contains { $0.channel == "users" && $0.method == nil })
        #expect(column?.channel == "users")
        #expect(column?.method == "active")
    }

    // MARK: SQLite.swift

    @Test("SQLite.swift의 prepare와 Table에서 관계를 읽는다")
    func sqliteSwiftSurfaces() {
        let source = """
            import SQLite
            func purge(db: Connection) throws {
                let sessions = Table("sessions")
                try db.prepare("DELETE FROM sessions WHERE expired = 1")
            }
            """
        #expect(channels(source).sorted() == ["sessions", "sessions"])
    }

    // MARK: Fluent

    @Test("Fluent의 schema 호출과 static schema 선언에서 관계를 읽는다")
    func fluentSurfaces() {
        let source = """
            import Fluent
            struct User: Model {
                static let schema = "users"
            }
            struct CreateUsers: Migration {
                func prepare(on db: Database) -> EventLoopFuture<Void> {
                    db.schema("users").field("name", .string).create()
                }
            }
            """
        #expect(channels(source).sorted() == ["users", "users"])
    }

    @Test("Fluent query(T.self)는 모델의 schema 바인딩으로 해석된다")
    func fluentQueryModel() {
        let source = """
            import Fluent
            struct User: Model { static let schema = "users" }
            func all(on db: Database) {
                db.query(User.self)
            }
            """
        // 선언 자리(`static let schema`)와 사용 자리(`query`)가 각각 한 건씩이다.
        #expect(channels(source) == ["users", "users"])
    }

    @Test("Fluent query(T.self)의 바인딩이 없으면 동적 사실로 남는다")
    func fluentQueryUnknownModel() {
        let source = """
            import Fluent
            func all(on db: Database) {
                db.query(User.self)
            }
            """
        let result = scan(source)
        #expect(result.facts.count == 1)
        #expect(result.facts.first?.fact.isDynamic == true)
        #expect(result.counts.unjoinedDynamic == 1)
    }

    // MARK: 게이트 없는 리터럴

    @Test("게이트 없는 대문자 SQL 리터럴은 관계를 읽는다")
    func ungatedUppercaseLiteral() {
        let source = """
            let cleanup = "DELETE FROM logs WHERE created < ?"
            """
        #expect(channels(source) == ["logs"])
    }

    @Test("SQL 동사를 가진 소문자 리터럴은 세지 않고 개수로 남긴다")
    func ungatedLowercaseLiteralSkipped() {
        let source = """
            let cleanup = "delete from logs where created < ?"
            """
        let result = scan(source)
        #expect(result.facts.isEmpty)
        #expect(result.counts.skippedSqlLiterals == 1)
    }

    @Test("SQL 모양의 산문은 관계로 읽지 않고 건너뛴 개수로 남긴다")
    func proseIsNotSql() {
        let source = """
            let prompt = "Select an option from the menu"
            let hint = "Grant access to the report"
            """
        let result = scan(source)
        #expect(result.facts.isEmpty)
        #expect(result.counts.skippedSqlLiterals == 2)
    }

    @Test("게이트가 있는 인자 리터럴은 원시 리터럴 패스가 다시 읽지 않는다")
    func gatedLiteralsNotDoubleCounted() {
        let source = """
            import SQLite3
            func purge(db: OpaquePointer) {
                sqlite3_exec(db, "DELETE FROM sessions", nil, nil, nil)
            }
            """
        #expect(channels(source) == ["sessions"])
    }

    // MARK: 미지원 표면 계수

    @Test("Core Data·SwiftData·Realm 표면은 사실이 아니라 관측 개수다")
    func unsupportedSurfacesCounted() {
        let source = """
            import CoreData
            import SwiftData
            import RealmSwift
            class Dog: Object {}
            func load(context: NSManagedObjectContext, realm: Realm) {
                let request = NSFetchRequest<Dog>(entityName: "Dog")
                let dogs = realm.objects(Dog.self)
                let descriptor = FetchDescriptor<Dog>()
            }
            """
        let result = scan(source)
        #expect(result.facts.isEmpty)
        #expect(result.counts.coreDataReferences == 1)
        #expect(result.counts.swiftDataReferences == 1)
        #expect(result.counts.realmReferences == 2)
    }

    @Test("지원 표면 밖 프레임워크 import는 파일당 한 번 이름으로 센다")
    func unsupportedFrameworksCounted() {
        let source = """
            import FMDB
            import PostgresNIO
            import FMDB
            func open(db: FMDatabase) {}
            """
        let result = scan(source)
        #expect(result.facts.isEmpty)
        #expect(result.counts.unsupportedFrameworks == ["FMDB", "PostgresNIO"])
    }

    // MARK: 위치와 결정성

    @Test("사실은 SQL 인자의 위치를 갖는다")
    func factLocations() {
        let source = "import SQLite3\nfunc f(db: OpaquePointer) {\n    sqlite3_exec(db, \"DELETE FROM t\", nil, nil, nil)\n}\n"
        let fact = scan(source).facts.first?.fact
        #expect(fact?.location.line == 3)
        #expect(fact?.location.column == 22)
        #expect(fact?.location.path == "/p/Store.swift")
    }

    @Test("같은 입력을 두 번 읽으면 같은 사실 목록이 나온다")
    func deterministicOrdering() {
        let source = """
            import GRDB
            func migrate(db: Database) throws {
                try db.execute(sql: "INSERT INTO items (id) VALUES (1)")
                try db.execute(sql: "DELETE FROM audit")
                let users = Table("users")
            }
            """
        #expect(scan(source).facts == scan(source).facts)
        #expect(scan(source).facts.map(\.fact) == scan(source).facts.map(\.fact).sorted())
    }

    @Test("사실은 감싸는 선언을 싣고 온다")
    func enclosingDeclaration() {
        let source = """
            import SQLite3
            struct Store {
                func purge(db: OpaquePointer) {
                    sqlite3_exec(db, "DELETE FROM sessions", nil, nil, nil)
                }
            }
            """
        let scanned = scan(source).facts.first
        #expect(scanned?.declaration?.indexName == "purge(db:)")
        #expect(scanned?.declaration?.qualifiedName == "Store.purge")
    }

    // MARK: 채널 이스케이프

    @Test("호출 인자 리터럴의 점은 한정자로 유지된다")
    func qualifiedCallArgument() {
        let source = """
            import GRDB
            func migrate(db: Database) throws {
                try db.create(table: "main.users")
                let t = Table("main.sessions")
            }
            """
        let channels = scan(source).facts.compactMap(\.fact.channel)
        #expect(channels.contains("main.users"))
        #expect(channels.contains("main.sessions"))
        #expect(!channels.contains { $0.contains("%2E") })
    }

    @Test("static 테이블명 선언의 점은 리터럴 식별자로 이스케이프된다")
    func declaredNameEscapesDot() {
        let source = """
            import GRDB
            struct Store: TableRecord {
                static let databaseTableName = "audit.v2"
            }
            """
        #expect(scan(source).facts.first?.fact.channel == "audit%2Ev2")
    }

    // MARK: 선언 수집 경계

    @Test("extension의 static 테이블명 선언도 타입에 귀속된다")
    func extensionTableBinding() {
        let source = """
            import GRDB
            struct Player { }
            extension Player: FetchableRecord {
                static let databaseTableName = "players"
            }
            func load(db: Database) throws {
                try db.create(table: "players")
            }
            """
        // 선언 자리(4행)·`create` 인자(7행)가 아니라 `Player.all()` 수신자 해석(9행)의
        // 사실을 구분해 단정한다 — 선언만으로는 9행 사실이 나올 수 없다.
        let result = scan(source + "\nextension Player { func f() { Player.all() } }\n")
        #expect(result.facts.contains { $0.fact.channel == "players" && $0.fact.location.line == 9 })
    }

    @Test("중첩된 다른 테이블 수신자 호출의 컬럼은 자기 채널로 귀속된다")
    func nestedReceiverColumnKeepsOwnChannel() {
        let source = """
            import SQLite
            let users = Table("users")
            let orders = Table("orders")
            func sync(db: Connection) {
                _ = users.filter(Column("id") == orders.count(Column("oid")))
            }
            """
        let result = scan(source)
        // `oid`는 바깥 `users` 채널이 아니라 안쪽 `orders` 채널로만 나온다.
        #expect(result.facts.contains { $0.fact.channel == "orders" && $0.fact.method == "oid" })
        #expect(!result.facts.contains { $0.fact.channel == "users" && $0.fact.method == "oid" })
        #expect(result.facts.contains { $0.fact.channel == "users" && $0.fact.method == "id" })
    }

    @Test("한정 생성자 SQLite.Table도 관계를 읽는다")
    func qualifiedTableConstructor() {
        let source = """
            import SQLite
            let t = SQLite.Table("users")
            """
        #expect(channels(source).contains("users"))
    }

    @Test("gated 호출이 참조한 바인딩 리터럴은 ungated 패스가 다시 읽지 않는다")
    func boundLiteralNotDoubleCounted() {
        let source = """
            import SQLite3
            let sql = "DELETE FROM logs"
            func f(db: OpaquePointer) {
                sqlite3_exec(db, sql, nil, nil, nil)
            }
            """
        let logs = scan(source).facts.filter { $0.fact.channel == "logs" }
        #expect(logs.count == 1)
        #expect(logs.first?.fact.location.line == 4)
    }

    @Test("표현식 빌더 인자는 바깥 호출에서 동적 근거를 만들지 않는다")
    func expressionBuilderNotOvercounted() {
        let source = """
            import SQLite
            let users = Table("users")
            func seed(db: Connection) throws {
                try db.run(users.insert(Column("email") <- "a"))
            }
            """
        let result = scan(source)
        #expect(result.counts.unjoinedDynamic == 0)
        #expect(result.facts.contains { $0.fact.channel == "users" })
    }

    @Test("같은 이름이 다른 값으로 재바인딩되면 어느 쪽에도 귀속하지 않는다")
    func conflictingRebindIsNotMisattributed() {
        let source = """
            import SQLite
            func f(db: Connection) {
                let users = Table("a")
            }
            func g(db: Connection) {
                let users = Table("b")
            }
            func h(db: Connection) {
                _ = users.filter(Column("id") > 0)
            }
            """
        let result = scan(source)
        // `Table("a")`·`Table("b")` 호출 자리의 사실은 각 1건씩이고,
        // `users.filter`는 어느 바인딩에도 귀속하지 않아 추가 사실이 없다.
        #expect(result.facts.filter { $0.fact.channel == "a" }.count == 1)
        #expect(result.facts.filter { $0.fact.channel == "b" }.count == 1)
        #expect(!result.facts.contains { $0.fact.location.line == 10 })
    }

    @Test("GRDB tableExists의 첫 인자는 관계명이다")
    func tableExistsReadsRelation() {
        let source = """
            import GRDB
            func check(db: Database) throws {
                _ = try db.tableExists("users")
            }
            """
        #expect(channels(source).contains("users"))
    }
}
