@testable import CartographSyntax
import Testing

/// kartograph·rustograph와 동일한 관계 추출 계약을 Swift 포트가 지키는지 검증한다.
@Suite("SQL 관계 추출")
struct SqlRelationsTests {
    private func relations(_ sql: String, strict: Bool = false) -> [String] {
        sqlRelations(sql, strict: strict).relations.map(\.name)
    }

    @Test("기본 관계 키워드의 피연산자를 읽는다")
    func basicRelationKeywords() {
        #expect(relations("SELECT * FROM users") == ["users"])
        #expect(relations("SELECT * FROM users JOIN orders ON true") == ["users", "orders"])
        #expect(relations("INSERT INTO users (id) VALUES (1)") == ["users"])
        #expect(relations("UPDATE users SET name = 'x'") == ["users"])
        #expect(relations("DELETE FROM users") == ["users"])
        #expect(relations("SELECT * FROM s.t") == ["s.t"])
        #expect(relations("SELECT * FROM `a.b`") == ["a%2Eb"])
    }

    @Test("쉼표 목록과 별칭을 읽는다")
    func commaListsAndAliases() {
        #expect(relations("SELECT * FROM a, b") == ["a", "b"])
        #expect(relations("SELECT * FROM a x, b y") == ["a", "b"])
        #expect(relations("SELECT * FROM a AS x, b AS y") == ["a", "b"])
    }

    @Test("문장 경계에서만 발화한다")
    func statementBoundaries() {
        #expect(relations("UPDATE a SET x = 1; UPDATE b SET y = 2") == ["a", "b"])
        // 산문: "update the config"은 문장 머리여도 SET이 없어 발화하지 않는다.
        #expect(relations("please update the config") == [])
        #expect(relations("UPDATE t SET x = 1") == ["t"])
        // GRANT/REVOKE는 권한 단어가 앞서야 ON이 발화한다.
        #expect(relations("GRANT SELECT ON TABLE metrics TO app") == ["metrics"])
        #expect(relations("GRANT SELECT ON metrics TO app") == ["metrics"])
        #expect(relations("REVOKE SELECT ON FUNCTION f FROM r") == [])
        #expect(relations("grant select on the report to auditors") == [])
        #expect(relations("grant access on staging to intern") == [])
        // SQLDelight 라벨(`name:`)은 문장 머리를 차지하지 않는다 — 뒤의 동사가 머리다.
        #expect(relations("markAdult:\nUPDATE users SET adult = 1") == ["users"])
        #expect(relations("clearAll:\nTRUNCATE users") == ["users"])
        // 캐스트(`::`)는 라벨이 아니다.
        #expect(relations("SELECT x::int FROM t") == ["t"])
    }

    @Test("산문은 관계를 만들지 않는다")
    func proseDoesNotProduceRelations() {
        #expect(relations("the report into the folder") == [])
        #expect(relations("merged the branch into main") == [])
        #expect(relations("drop the table at noon") == [])
        #expect(relations("turn the table over") == [])
    }

    @Test("하위 질의와 괄호를 따라간다")
    func subqueriesAndParens() {
        #expect(relations("SELECT * FROM (SELECT * FROM a) x JOIN b ON true") == ["a", "b"])
        // INSERT .. SELECT는 양쪽 다 읽는다 — 읽기 원본도 관계 사용이다.
        #expect(relations("INSERT INTO a SELECT * FROM ignored_c") == ["a", "ignored_c"])
    }

    @Test("미해석 피연산자는 개수로 센다")
    func unresolvedOperandsCounted() {
        let deleted = sqlRelations("DELETE FROM {} WHERE id = ?")
        #expect(deleted.relations.isEmpty)
        #expect(deleted.unresolved == 1)
        #expect(sqlRelations("SELECT * FROM users").unresolved == 0)
        // 이름 없이 끝나는 키워드도 미해석이다.
        #expect(sqlRelations("SELECT 1 FROM").unresolved == 1)
        #expect(sqlRelations("SELECT * FROM {} JOIN ?").unresolved == 2)
    }

    @Test("SQL 형태 게이트가 산문을 걸러낸다")
    func looksLikeSqlGate() {
        #expect(looksLikeSql("SELECT * FROM t"))
        #expect(looksLikeSql("update t set x = 1"))
        #expect(!looksLikeSql("please update the config"))
        #expect(!looksLikeSql("a plain sentence"))
        #expect(!looksLikeSql(""))
    }

    @Test("strict 모드는 산문과 소문자 키워드를 거부한다")
    func strictModeRejectsProseAndLowercase() {
        // 산문의 혼합 대소문자 키워드는 strict에서 발화하지 않는다.
        #expect(!looksLikeSql("Select an option from the menu", strict: true))
        #expect(looksLikeSql("SELECT an option FROM the menu", strict: true))
        #expect(relations("Select an option from the menu", strict: true) == [])
        // 게이트 없는 리터럴이 소문자 SQL이면 사실을 만들지 않는다.
        #expect(relations("select * from users", strict: true) == [])
        // 관사는 이름 자리에 설 수 없다 — 대문자 산문의 오탐도 막는다.
        #expect(relations("SELECT a FROM the") == [])
        // strict가 아니면 소문자 SQL은 그대로 읽는다.
        #expect(relations("select * from users") == ["users"])
    }
}
