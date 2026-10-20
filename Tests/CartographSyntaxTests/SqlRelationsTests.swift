@testable import CartographSyntax
import Testing

/// kartograph·rustograph와 동일한 관계 추출 계약을 Swift 포트가 지키는지 검증한다.
@Suite("SQL 관계 추출")
struct SqlRelationsTests {
    private func relations(_ sql: String, strict: Bool = false) -> [String] {
        sqlRelations(sql, strict: strict).relations.map(\.name)
    }

    @Test("테이블 값 함수는 관계가 아니고 미해석 근거를 남긴다")
    func tableValuedFunctions() {
        #expect(relations("SELECT * FROM pragma_table_info('t')").isEmpty)
        #expect(relations("SELECT * FROM users JOIN main.pragma_table_info('t') p ON true") == ["users"])
        #expect(relations("SELECT * FROM pragma_table_info('t') AS p, users") == ["users"])
        #expect(sqlRelations("SELECT * FROM pragma_table_info('t')").unresolved == 1)
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

    // MARK: 계열 공통 규칙 — 함수 인자 안의 FROM(R1)·CTE 이름(R2)·IS [NOT] DISTINCT FROM(R3)

    @Test("계열 공통 사례의 관계 집합을 그대로 낸다", arguments: sharedSqlRelationCases)
    func sharedCases(_ shared: SharedSqlRelationCase) {
        #expect(Set(relations(shared.sql)) == Set(shared.relations))
    }

    @Test("CTE 본문이 DML이어도 본문 안의 관계는 읽는다")
    func dmlCteBodyKeepsRelations() {
        // 본문을 여는 `(` 앞의 AS·MATERIALIZED는 함수 이름이 아니다 — R1이 본문의 FROM을 막지 않는다.
        #expect(relations("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d") == ["t"])
        #expect(relations("WITH d AS MATERIALIZED (DELETE FROM t RETURNING *) SELECT * FROM d") == ["t"])
    }

    @Test("CTE 이름은 비인용만 대소문자를 접어 비교하고 한정 이름은 CTE가 아니다")
    func cteNameComparison() {
        #expect(relations("WITH Recent AS (SELECT * FROM orders) SELECT * FROM recent") == ["orders"])
        #expect(relations("WITH \"Recent\" AS (SELECT * FROM orders) SELECT * FROM \"Recent\"") == ["orders"])
        #expect(relations("WITH \"Recent\" AS (SELECT 1) SELECT * FROM recent") == ["recent"])
        #expect(relations("WITH recent AS (SELECT 1) SELECT * FROM s.recent") == ["s.recent"])
        // 쉼표 목록에서 CTE 이름만 빠지고 뒤의 관계는 계속 읽는다.
        #expect(relations("WITH recent AS (SELECT 1) SELECT * FROM recent, orders") == ["orders"])
    }

    @Test("CTE 모양이 아닌 WITH와 쉼표 뒤 이름은 CTE 이름으로 모으지 않는다")
    func nonCteWithForms() {
        #expect(relations("GRANT SELECT ON metrics TO app WITH GRANT OPTION") == ["metrics"])
        #expect(relations("SELECT * FROM t WITH (NOLOCK)") == ["t"])
        #expect(relations("SELECT id, orders AS n FROM orders") == ["orders"])
    }

    @Test("같은 이름의 테이블을 가리는 CTE는 그 문장의 테이블 사용도 가린다")
    func cteShadowsSameNamedTable() {
        // 공통 규칙은 문장 단위라 본문 안의 실제 테이블도 내지 않는다 — README에 적은 한계다.
        #expect(relations("WITH users AS (SELECT * FROM users WHERE active) SELECT * FROM users") == [])
    }

    @Test("함수 인자 안의 FROM은 관계도 미해석도 아니다")
    func functionArgumentFromIsNotRelation() {
        // FROM 뒤에 이름이 없는 함수 인자(`FROM 2)`)도 읽지 못한 피연산자로 세지 않는다.
        #expect(sqlRelations("SELECT SUBSTRING(name FROM 2) FROM users").unresolved == 0)
        #expect(sqlRelations("SELECT SUBSTRING(name FROM 1 FOR 3) FROM users").unresolved == 0)
        let placeholder = sqlRelations("SELECT * FROM events WHERE EXTRACT(EPOCH FROM ?) > 0")
        #expect(placeholder.relations.map(\.name) == ["events"])
        #expect(placeholder.unresolved == 0)
        #expect(relations("SELECT OVERLAY(name PLACING 'x' FROM 2 FOR 3) FROM users") == ["users"])
    }

    @Test("함수 인자 그룹 안의 하위 질의는 그대로 읽는다")
    func subqueryInsideFunctionArgumentsFires() {
        #expect(relations("SELECT COALESCE((SELECT max(id) FROM users), 0) FROM orders") == ["users", "orders"])
        #expect(relations("SELECT ARRAY(SELECT id FROM users) FROM orders") == ["users", "orders"])
    }

    @Test("절 키워드 뒤의 괄호는 첫 토큰이 SELECT가 아니어도 함수 인자 그룹이 아니다")
    func clauseWordParensAreNotFunctionArguments() {
        // 괄호로 시작하는 집합 질의(`((SELECT …) UNION SELECT … FROM b)`)의 뒤 FROM도 관계를 연다.
        #expect(relations("SELECT * FROM ((SELECT * FROM a) UNION SELECT * FROM b) AS u") == ["a", "b"])
        #expect(relations("SELECT * FROM t WHERE id IN ((SELECT a FROM x) UNION SELECT b FROM y)") == ["t", "x", "y"])
    }

    @Test("함수 인자 문맥은 문장 경계를 넘지 않는다")
    func functionArgumentScopeEndsAtStatement() {
        // 앞 문장의 닫히지 않은 괄호가 다음 문장의 FROM까지 막지 않는다.
        #expect(relations("SELECT EXTRACT(YEAR FROM d; SELECT * FROM t") == ["t"])
    }

    @Test("IS [NOT] DISTINCT FROM의 피연산자는 관계도 미해석도 아니다")
    func distinctFromOperand() {
        #expect(relations("SELECT * FROM events WHERE kind IS DISTINCT FROM $1") == ["events"])
        let placeholder = sqlRelations("SELECT * FROM events WHERE kind IS NOT DISTINCT FROM ?")
        #expect(placeholder.relations.map(\.name) == ["events"])
        #expect(placeholder.unresolved == 0)
        // 연산자가 아닌 DISTINCT(`SELECT DISTINCT … FROM`) 뒤의 FROM은 그대로 관계를 연다.
        #expect(relations("SELECT DISTINCT kind FROM events") == ["events"])
    }

    @Test("strict 모드에서도 세 규칙은 키워드 대소문자와 무관하게 발화를 막는다")
    func strictModeAppliesSharedRules() {
        #expect(relations("WITH RECENT AS (SELECT * FROM ORDERS) SELECT * FROM RECENT", strict: true) == ["ORDERS"])
        #expect(relations("With recent as (SELECT * FROM orders) SELECT * FROM recent", strict: true) == ["orders"])
        #expect(relations("SELECT EXTRACT(YEAR FROM CREATED_AT) FROM ORDERS", strict: true) == ["ORDERS"])
        #expect(relations("SELECT * FROM EVENTS WHERE A IS NOT DISTINCT FROM B", strict: true) == ["EVENTS"])
    }
}

/// 계열 공통 사례 하나다 — persistence 생산자 7곳과 isthmus 공유 벡터가 같은 SQL과 기대값을 쓴다.
struct SharedSqlRelationCase: Sendable, CustomTestStringConvertible {
    let id: String
    /// 사례가 고정하는 규칙이다(R1 함수 인자 FROM, R2 CTE 이름, R3 IS [NOT] DISTINCT FROM).
    let rule: String
    let sql: String
    /// 낼 관계 이름의 집합이다 — 순서와 중복은 각 생산자의 기존 규칙이라 비교하지 않는다.
    let relations: [String]

    var testDescription: String { "\(rule) \(id)" }
}

/// 공통 사례 14개다. SQL과 기대값을 사례 원본에서 글자 그대로 옮겼다(긴 SQL만 `+`로 나눴다).
/// 고칠 때는 계열 생산자와 isthmus `conformance/sql-relations.json`이 함께 바뀌어야 한다.
private let sharedSqlRelationCases: [SharedSqlRelationCase] = [
    SharedSqlRelationCase(id: "cte/simple", rule: "R2",
        sql: "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent",
        relations: ["orders"]),
    SharedSqlRelationCase(id: "cte/recursive-with-columns", rule: "R2",
        sql: "WITH RECURSIVE tree(id, parent_id) AS (SELECT id, parent_id FROM nodes UNION ALL SELECT n.id, "
            + "n.parent_id FROM nodes n JOIN tree t ON n.parent_id = t.id) SELECT * FROM tree",
        relations: ["nodes"]),
    SharedSqlRelationCase(id: "cte/multiple-materialized", rule: "R2",
        sql: "WITH a AS (SELECT 1), b AS MATERIALIZED (SELECT * FROM orders) SELECT * FROM a JOIN b ON true",
        relations: ["orders"]),
    SharedSqlRelationCase(id: "cte/not-materialized", rule: "R2",
        sql: "WITH c AS NOT MATERIALIZED (SELECT * FROM orders) SELECT * FROM c",
        relations: ["orders"]),
    SharedSqlRelationCase(id: "cte/insert-select", rule: "R2",
        sql: "WITH staged AS (SELECT * FROM imports) INSERT INTO orders SELECT * FROM staged",
        relations: ["imports", "orders"]),
    SharedSqlRelationCase(id: "cte/scope-is-one-statement", rule: "R2",
        sql: "WITH recent AS (SELECT 1) SELECT * FROM recent; SELECT * FROM recent",
        relations: ["recent"]),
    SharedSqlRelationCase(id: "function-from/extract", rule: "R1",
        sql: "SELECT EXTRACT(YEAR FROM created_at) FROM orders",
        relations: ["orders"]),
    SharedSqlRelationCase(id: "function-from/trim", rule: "R1",
        sql: "SELECT TRIM(BOTH ' ' FROM name) FROM users",
        relations: ["users"]),
    SharedSqlRelationCase(id: "function-from/substring", rule: "R1",
        sql: "SELECT SUBSTRING(name FROM 2 FOR 3) FROM users",
        relations: ["users"]),
    SharedSqlRelationCase(id: "subquery/derived-table-still-fires", rule: "R1",
        sql: "SELECT * FROM (SELECT * FROM orders) AS sub",
        relations: ["orders"]),
    SharedSqlRelationCase(id: "subquery/scalar-still-fires", rule: "R1",
        sql: "SELECT (SELECT max(id) FROM users) FROM orders",
        relations: ["users", "orders"]),
    SharedSqlRelationCase(id: "subquery/in-select-still-fires", rule: "R1",
        sql: "SELECT * FROM orders WHERE id IN (SELECT order_id FROM payments)",
        relations: ["orders", "payments"]),
    SharedSqlRelationCase(id: "distinct-from/is", rule: "R3",
        sql: "SELECT * FROM events WHERE a IS DISTINCT FROM b",
        relations: ["events"]),
    SharedSqlRelationCase(id: "distinct-from/is-not", rule: "R3",
        sql: "SELECT * FROM events WHERE a IS NOT DISTINCT FROM b",
        relations: ["events"]),
]
