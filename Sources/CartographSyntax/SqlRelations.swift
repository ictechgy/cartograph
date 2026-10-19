/// SQL 어휘 하나다 — 인용된 식별자는 키워드가 아니다.
///
/// `offset`은 원문의 Character 위치로, 같은 키워드의 피연산자 목록 안에서
/// 같은 이름을 두 번 내지 않는 dedup 키의 일부다. kartograph `SqlRelations.kt`의
/// 포트라 알고리즘·게이트·계수 규칙을 같이 유지한다 — 두 생산자가 같은 SQL을
/// 다르게 읽으면 isthmus 조인 결과가 생산자 언어에 따라 달라진다.
/// 함수 인자 안의 FROM(R1)·CTE 이름(R2)·`IS [NOT] DISTINCT FROM`(R3)은 persistence
/// 생산자 7곳 공통 규칙이라 isthmus 공유 사례(`conformance/sql-relations.json`)를 따른다
/// (`SqlRelationContext`).
struct SqlToken: Hashable {
    let text: String
    let quoted: Bool
    let offset: Int
}

/// 관계 이름 하나와 그것을 연 키워드 토큰의 원문 위치다.
struct SqlRelation: Hashable {
    let name: String
    let keyword: Int
}

/// SQL 텍스트를 어휘로 나눈다 — 인용 식별자는 내용을 보존하고
/// 그 외엔 식별자 문자열과 단일 기호 토큰만 만든다.
/// `;`는 문장 경계로, `{}`·`$`·`?`·`:`·`@` 같은 플레이스홀더 기호는 미해석
/// 피연산자 계수를 위해 토큰으로 남긴다.
func lexSql(_ text: String) -> [SqlToken] {
    let chars = Array(text)
    var tokens: [SqlToken] = []
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\"" || c == "`" || c == "[" {
            let end: Character = c == "[" ? "]" : c
            var j = i + 1
            while j < chars.count && chars[j] != end { j += 1 }
            tokens.append(SqlToken(text: String(chars[(i + 1)..<j]), quoted: true, offset: i))
            i = j + 1
        } else if isIdentStart(c) {
            var j = i + 1
            while j < chars.count && isIdentPart(chars[j]) { j += 1 }
            tokens.append(SqlToken(text: String(chars[i..<j]), quoted: false, offset: i))
            i = j
        } else if c == "-" && (i + 1 < chars.count && chars[i + 1] == "-") {
            while i < chars.count && chars[i] != "\n" { i += 1 }
        } else if c == "/" && (i + 1 < chars.count && chars[i + 1] == "*") {
            i += 2
            while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
            i += 2
        } else if c == "'" {
            // 문자열 리터럴은 이름이 아니다 — '' 와 \' 는 escape다.
            i += 1
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "'" && i + 1 < chars.count && chars[i + 1] == "'" { i += 2; continue }
                if chars[i] == "'" { i += 1; break }
                i += 1
            }
        } else {
            if c == "." || c == "," || c == "(" || c == ")" || c == ";" ||
                c == "{" || c == "}" || c == "$" || c == "?" || c == ":" || c == "@" {
                tokens.append(SqlToken(text: String(c), quoted: false, offset: i))
            }
            i += 1
        }
    }
    return tokens
}

/// SQL 문을 여는 강한 동사 표다 — 관계 키워드와 겹치는 update·truncate는
/// 뺀다(문장 머리 규칙이 따로 있다). WITH는 SELECT를 동반하므로 없다.
/// strict 모드는 게이트 없는 문자열 리터럴용으로, 동사가 대문자일 때만 인정한다.
func looksLikeSql(_ text: String, strict: Bool = false) -> Bool {
    var head = true
    for t in lexSql(text) {
        if !isNameToken(t) { continue }
        if isSqlVerb(t.text) && (!strict || t.text == t.text.uppercased()) { return true }
        if head {
            head = false
            let lower = t.text.lowercased()
            if (lower == "update" || lower == "truncate") && (!strict || t.text == t.text.uppercased()) {
                return true
            }
        }
    }
    return false
}

/// SQL 텍스트에서 관계 이름을 읽는다.
///
/// 한정 이름(`schema.table`)은 그대로 두고, 이름 자체에 점이 있는 인용
/// 식별자("a.b")는 한 세그먼트로 읽는다 — escape는 기록 시에 한다.
/// 두 번째 반환은 관계 자리의 피연산자를 읽지 못한 횟수다 —
/// `FROM {}` 같은 플레이스홀더를 사실 없이 조용히 넘기지 않기 위해서다.
/// 같은 문장의 CTE 이름, 함수 인자 안의 FROM, `IS [NOT] DISTINCT FROM`의 피연산자는
/// 관계가 아니다(계열 공통 규칙, `SqlRelationContext`).
func sqlRelations(_ text: String, strict: Bool = false) -> (relations: [SqlRelation], unresolved: Int) {
    let tokens = lexSql(text)
    let context = SqlRelationContext(tokens)
    var out: [SqlRelation] = []
    // 같은 키워드의 피연산자 목록 안에서만 중복을 막는다(`FROM a, a`).
    // 다른 위치의 같은 이름은 별개의 사용 근거다 — `SELECT .. FROM t`와
    // `INSERT INTO t`는 각각 사실이어야 한다.
    var seen = Set<String>()
    var consumed = [Bool](repeating: false, count: tokens.count)
    var unresolved = 0
    // strict 모드는 게이트 없이 스캔하는 문자열 리터럴용이다 — 관계 키워드와
    // 동사가 모두 대문자일 때만 발화해 "Select an option from the menu" 같은
    // 산문이 관계 사실을 만들지 않게 한다.
    func upperOk(_ t: SqlToken) -> Bool { !strict || t.text == t.text.uppercased() }
    // `;`로 갈리는 각 문장의 머리 식별자 위치와 그 문장의 동사다 —
    // update·truncate는 문장 머리에서만 관계 키워드로 열고, `on`은
    // grant·revoke 문 안에서만 연다. 다중 문장 리터럴의 뒤 문장도
    // 같은 규칙을 받는다. 문장 머리의 `ident :`는 SQLDelight 라벨이다 —
    // 라벨은 머리를 차지하지 않고 다음 식별자가 머리가 된다.
    var stmtHead = [Bool](repeating: false, count: tokens.count)
    var stmtVerb = [String?](repeating: nil, count: tokens.count)
    do {
        var pending = true
        var verb: String? = nil
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if !t.quoted && t.text == ";" {
                pending = true
                verb = nil
                i += 1
                continue
            }
            if isNameToken(t) && pending {
                if i + 1 < tokens.count, !tokens[i + 1].quoted, tokens[i + 1].text == ":",
                   !(i + 2 < tokens.count && !tokens[i + 2].quoted && tokens[i + 2].text == ":") {
                    i += 2 // 라벨은 머리가 아니다 — 계속 pending 상태로 둔다.
                    continue
                }
                stmtHead[i] = true
                verb = upperOk(t) ? t.text.lowercased() : nil
                pending = false
            }
            stmtVerb[i] = verb
            i += 1
        }
    }
    for i in tokens.indices {
        let tok = tokens[i]
        if consumed[i] || tok.quoted || !isRelationKeyword(tok.text) || !upperOk(tok) { continue }
        let word = tok.text.lowercased()
        let grantStmt = stmtVerb[i] == "grant" || stmtVerb[i] == "revoke"
        // 같은 문장(`;`로 갈리는 세그먼트) 안만 본다 — 뒤 세그먼트의
        // 단어를 앞 문장의 근거로 쓰지 않는다.
        func segmentBefore(_ end: Int) -> AnySequence<SqlToken> {
            AnySequence(tokens[0..<end].reversed().prefix { $0.text != ";" })
        }
        func segmentAfterHas(_ start: Int, _ w: String) -> Bool {
            tokens[start...].prefix { $0.text != ";" }
                .contains { !$0.quoted && $0.text.lowercased() == w && upperOk($0) }
        }
        let fires: Bool
        switch word {
        // 산문 속 "update the .."·upsert의 `DO UPDATE SET`을 막기 위해
        // update는 문장 머리이고 같은 문장에 SET이 있을 때만 연다.
        case "update":
            fires = stmtHead[i] && segmentAfterHas(i + 1, "set")
        // truncate는 항상 문장 머리 동사다 — 산문 중간의 "truncate"는 무시.
        case "truncate":
            fires = stmtHead[i]
        // into는 같은 문장에 INSERT·SELECT·MERGE·REPLACE가 앞선 문맥에서만
        // 연다 — "merged the branch into main" 같은 산문을 막는다.
        // 단, 문장이 "merge"로 시작하는 산문은 SQL `MERGE INTO`와 어휘가
        // 같아 구분 못 한다 — 남은 오탐 여지로 둔다.
        case "into":
            fires = segmentBefore(i).contains {
                !$0.quoted && upperOk($0) &&
                    ["insert", "select", "merge", "replace"].contains($0.text.lowercased())
            }
        // table은 직전 식별자가 DDL 동사일 때만 키워드다 — 산문의
        // "the table"이나 다른 절의 단어는 읽지 않는다.
        case "table":
            fires = tableKeywordContext(tokens, i, strict: strict)
        // on은 `GRANT .. ON t`·`REVOKE .. ON t`의 관계 자리다 — 권한
        // 단어(SELECT 등)가 앞서야 "grant access on .." 같은 산문을
        // 막는다. `CREATE INDEX/TRIGGER .. ON t`의 on도 관계 자리다.
        case "on":
            let grantOn = grantStmt && segmentBefore(i).contains {
                !$0.quoted && upperOk($0) && isGrantPriv($0.text)
            }
            let createOn = stmtVerb[i] == "create" && segmentBefore(i).contains {
                // `rule`은 제외 — CREATE RULE의 ON은 이벤트
                // 자리(`ON INSERT TO t`)라 관계가 아니다.
                !$0.quoted && upperOk($0) &&
                    ["index", "trigger", "policy"].contains($0.text.lowercased())
            }
            fires = grantOn || createOn
        // grant·revoke의 FROM은 권한 주체 자리다 — 관계가 아니므로
        // from·join을 그 문장에서는 열지 않는다. 함수 인자 안의 FROM(R1)과
        // `IS [NOT] DISTINCT FROM`(R3)도 관계 자리가 아니라 미해석으로도 세지 않는다.
        case "from", "join":
            fires = !grantStmt && !(word == "from" && context.suppressesFrom(at: i))
        default:
            fires = true
        }
        if !fires { continue }
        var j = i + 1
        // ONLY·IF NOT EXISTS 같은 수식어는 건너뛴다. `table`은 TRUNCATE 뒤의
        // 수식어일 때만 건너뛴다 — UPDATE table 같은 문에서 table이 진짜
        // 관계 이름일 수 있고, 억지로 건너뛰면 SET 같은 다음 단어가
        // 관계명으로 읽힌다.
        let headIsTruncate = word == "truncate"
        while j < tokens.count && !tokens[j].quoted && isNameModifier(tokens[j].text, afterTruncate: headIsTruncate) {
            consumed[j] = true
            j += 1
        }
        if word == "on" && grantStmt {
            // GRANT/REVOKE ON은 객체 종류어가 낄 수 있다 — `ON TABLE t`의
            // table은 수식어고, `ON SEQUENCE`/`ON FUNCTION`/`ON ALL TABLES`
            // 같은 비테이블 객체는 관계가 아니라 조용히 삼킨다.
            let kind: String? = (j < tokens.count && !tokens[j].quoted) ? tokens[j].text.lowercased() : nil
            if let kind {
                if ["table", "tables", "view", "materialized"].contains(kind) {
                    // 종류어 뒤의 이름이 관계다 — `ON FOREIGN TABLE`의
                    // foreign는 비테이블 목록으로 보낸다(서버·래퍼가 더 흔함).
                    var k = j
                    while k < tokens.count &&
                        ["table", "tables", "view", "materialized"].contains(tokens[k].text.lowercased()) {
                        consumed[k] = true
                        k += 1
                    }
                    j = k
                } else if ["all", "sequence", "schema", "database", "domain", "type", "function",
                           "procedure", "routine", "foreign", "server", "wrapper", "language",
                           "large", "publication", "subscription", "statistics", "tablespace",
                           "collation", "conversion", "extension", "aggregate", "operator",
                           "policy", "cast", "fdw", "parser", "template", "dictionary",
                           "configuration"].contains(kind) {
                    // 비테이블 권한 객체 — 이름·한정자·인자 괄호까지 삼키고
                    // 사실은 내지 않는다(미해석도 아닌 정상 문법이다).
                    var k = j
                    while k < tokens.count {
                        let t = tokens[k]
                        if !t.quoted && t.text == "(" {
                            guard let next = skipParens(tokens, k) else {
                                unresolved += 1 // 닫히지 않은 괄호.
                                break
                            }
                            k = next
                        } else if isNameToken(t) || (!t.quoted && t.text == ".") {
                            consumed[k] = true
                            k += 1
                        } else {
                            // 플레이스홀더 피연산자(`ON SEQUENCE {s}`)는
                            // 읽히지 않은 근거다 — 미해석으로 센다.
                            if !t.quoted && ["{", "}", "$", "?", ":", "@"].contains(t.text) {
                                unresolved += 1
                            }
                            break
                        }
                    }
                    continue
                }
            }
        }
        if j >= tokens.count {
            unresolved += 1 // 이름이 없는 키워드 — "SELECT ... FROM" 꼴.
            continue
        }
        // GRANT/REVOKE의 ON은 형태 검증을 거친다 — name (, name)* 뒤에
        // TO·FROM·`;`·끝이 와야 한다. "grant select on the report"
        // 같은 산문은 이름이 쉼표 없이 이어져 형태가 성립하지 않으므로
        // 이름을 버퍼에 모았다가 형태가 맞을 때만 방출한다.
        let bufferedGrant = word == "on" && grantStmt
        var buf: [String] = []
        var endPos = j
        // 쉼표로 이어지는 목록(`FROM a, b`)을 읽는다 — 괄호 피연산자는
        // 통째로 건너뛰고(안쪽 관계는 그 안의 키워드가 읽는다) 별칭은 삼킨다.
        operandLoop: while j < tokens.count {
            // 괄호 안의 토큰은 소비 표시를 하지 않는다 — 서브쿼리 안의
            // FROM 같은 키워드가 바깥 스캔에서 읽혀야 한다.
            let operandEnd: Int
            if !tokens[j].quoted && tokens[j].text == "(" {
                guard let next = skipParens(tokens, j) else {
                    unresolved += 1 // 닫히지 않은 괄호.
                    break
                }
                operandEnd = next
            } else {
                guard let read = readQualifiedName(tokens, j) else {
                    // 이름 자리에 절 키워드가 오는 것(`DO UPDATE SET`,
                    // `ON TABLES TO`)은 정상 종료다 — 플레이스홀더 등
                    // 읽히지 않는 피연산자만 미해석으로 센다.
                    let clauseNext = j < tokens.count && isNameToken(tokens[j]) && isClauseWord(tokens[j].text)
                    if !clauseNext { unresolved += 1 }
                    break
                }
                let (name, next) = read
                for c in j..<next { consumed[c] = true }
                if ["from", "join"].contains(word), next < tokens.count,
                   !tokens[next].quoted, tokens[next].text == "(" {
                    // 함수의 내부 관계를 추측하지 않고 미해석 근거를 남긴다.
                    unresolved += 1
                    guard let end = skipParens(tokens, next) else { break }
                    operandEnd = end
                } else {
                    // 같은 문장의 CTE 이름은 관계가 아니다(R2) — 소비 표시만 남기고 내지 않는다.
                    if !context.isCteReference(from: j, to: next) {
                        if bufferedGrant {
                            buf.append(name)
                        } else if seen.insert("\(tok.offset) \(name)").inserted {
                            out.append(SqlRelation(name: name, keyword: tok.offset))
                        }
                    }
                    operandEnd = next
                }
            }
            // `AS alias` 또는 쉼표 직전 별칭(`FROM users u, ..`)을 건너뛴다.
            var k = operandEnd
            if k < tokens.count, !tokens[k].quoted, tokens[k].text.lowercased() == "as",
               k + 1 < tokens.count, isNameToken(tokens[k + 1]) {
                k += 2
            } else if k < tokens.count, isNameToken(tokens[k]),
                      k + 1 < tokens.count, !tokens[k + 1].quoted, tokens[k + 1].text == "," {
                k += 1
            }
            for c in operandEnd..<k { consumed[c] = true }
            endPos = k
            if k < tokens.count, !tokens[k].quoted, tokens[k].text == "," {
                j = k + 1
                continue
            }
            break
        }
        if bufferedGrant {
            // 피연산자 뒤가 GRANT 종결자가 아니면 산문이다 — 버퍼를 버린다.
            // `WITH GRANT OPTION`은 피연산자가 아니라 피부여자 뒤에 오고,
            // `)`는 GRANT가 중첩되지 않아 종결자가 아니다 — 둘 다 산문만 허용한다.
            let termOk: Bool
            if endPos >= tokens.count {
                termOk = true
            } else {
                let t = tokens[endPos]
                termOk = !t.quoted && ["to", "from", ";"].contains(t.text.lowercased())
            }
            if termOk {
                for name in buf where seen.insert("\(tok.offset) \(name)").inserted {
                    out.append(SqlRelation(name: name, keyword: tok.offset))
                }
            }
        }
    }
    return (out, unresolved)
}

/// 계열 공통 규칙 세 가지가 관계 키워드마다 묻는 문장·괄호 문맥이다.
///
/// - R1: `(` 바로 앞이 함수 이름이고 그룹이 SELECT·WITH·VALUES로 시작하지 않으면 그 깊이의 FROM은
///   관계를 열지 않는다(`EXTRACT(YEAR FROM created_at)`·`TRIM(BOTH ' ' FROM name)`). 안쪽 하위 질의는 연다.
/// - R2: 문장마다 `WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (`와 `, name …`의 이름을 모아,
///   같은 문장의 한정자 없는 피연산자가 그 이름이면 관계로 내지 않는다. 다른 문장에는 영향이 없다.
/// - R3: FROM 바로 앞이 비인용 `distinct`이고 그 앞이 `is` 또는 `is not`이면 비교 연산자의 일부다.
///
/// persistence 생산자 7곳이 같은 SQL을 같게 읽어야 isthmus 조인이 생산자 언어에 따라 갈리지 않는다.
/// 규칙은 isthmus GRAPH-EXCHANGE의 "SQL 텍스트의 관계 이름" 절이 정본이다. 키워드마다 토큰을
/// 되감지 않도록 문장 번호·괄호 짝·CTE 이름·함수 인자 문맥을 토큰 열을 몇 번 훑어 미리 계산한다.
struct SqlRelationContext {
    private let tokens: [SqlToken]
    /// 토큰마다 속한 문장(`;`로 갈리는 구간) 번호다.
    private let statements: [Int]
    /// 문장마다 모은 CTE 이름의 비교 키다(R2).
    private let cteNames: [Set<String>]
    /// 토큰을 감싼 가장 안쪽 괄호가 함수 인자 그룹인지다(R1).
    private let insideFunctionArguments: [Bool]

    init(_ tokens: [SqlToken]) {
        let (statements, closing) = sqlStatementsAndParens(tokens)
        let definitions = sqlCteDefinitions(tokens, statements: statements, closing: closing)
        self.tokens = tokens
        self.statements = statements
        cteNames = definitions.names
        insideFunctionArguments = sqlFunctionArgumentScopes(tokens, cteParens: definitions.parens)
    }

    /// `index`의 FROM이 관계를 열지 않는지 본다 — 함수 인자 안(R1)이거나 `IS [NOT] DISTINCT FROM`(R3)이다.
    /// 세 규칙은 발화를 막는 쪽이라 strict 모드에서도 키워드 대소문자를 따지지 않는다.
    func suppressesFrom(at index: Int) -> Bool {
        insideFunctionArguments[index] || isDistinctFromOperator(tokens, index)
    }

    /// `start..<next`에서 읽은 피연산자가 같은 문장의 CTE 이름인지 본다(R2) — 한정 이름은 CTE가 아니다.
    func isCteReference(from start: Int, to next: Int) -> Bool {
        next == start + 1 && cteNames[statements[start]].contains(cteKey(tokens[start]))
    }
}

/// 토큰마다 문장 번호를, 여는 괄호마다 같은 문장 안의 짝 닫는 괄호 위치를 한 번에 센다.
/// `;`는 열린 괄호를 모두 버린다 — 앞 문장의 닫히지 않은 괄호가 다음 문장의 문맥이 되지 않게 한다.
private func sqlStatementsAndParens(_ tokens: [SqlToken]) -> (statements: [Int], closing: [Int?]) {
    var statements = [Int](repeating: 0, count: tokens.count)
    var closing = [Int?](repeating: nil, count: tokens.count)
    var statement = 0
    var openParens: [Int] = []
    for index in tokens.indices {
        statements[index] = statement
        if isSqlSymbol(tokens, index, ";") {
            statement += 1
            openParens.removeAll()
        } else if isSqlSymbol(tokens, index, "(") {
            openParens.append(index)
        } else if isSqlSymbol(tokens, index, ")"), let open = openParens.popLast() {
            closing[open] = index
        }
    }
    return (statements, closing)
}

/// R2의 CTE 이름을 문장마다 모은다. 그 정의의 열 목록·본문 `(`도 돌려준다 — 그 괄호는 함수 인자
/// 그룹이 아니다(`WITH d AS MATERIALIZED (DELETE FROM t …)`의 t를 R1이 막지 않게 한다).
private func sqlCteDefinitions(_ tokens: [SqlToken], statements: [Int], closing: [Int?])
    -> (names: [Set<String>], parens: Set<Int>) {
    var names = [Set<String>](repeating: [], count: (statements.last ?? 0) + 1)
    var parens = Set<Int>()
    for index in tokens.indices where isSqlWord(tokens, index, "with") || isSqlSymbol(tokens, index, ",") {
        let recursive = isSqlWord(tokens, index, "with") && isSqlWord(tokens, index + 1, "recursive")
        let nameIndex = index + (recursive ? 2 : 1)
        guard let definition = cteDefinitionParens(tokens, nameIndex: nameIndex, closing: closing) else { continue }
        names[statements[index]].insert(cteKey(tokens[nameIndex]))
        parens.formUnion(definition)
    }
    return (names, parens)
}

/// `nameIndex`에서 `name [(cols)] AS [NOT] [MATERIALIZED] (`가 시작하면 열 목록과 본문의 `(` 위치를
/// 돌려준다. 모양이 다르면(`WITH GRANT OPTION`·`WITH (NOLOCK)`·`, col AS alias`) CTE 정의가 아니다.
private func cteDefinitionParens(_ tokens: [SqlToken], nameIndex: Int, closing: [Int?]) -> [Int]? {
    guard tokens.indices.contains(nameIndex), isCteName(tokens[nameIndex]) else { return nil }
    var parens: [Int] = []
    var cursor = nameIndex + 1
    if isSqlSymbol(tokens, cursor, "(") {
        guard let close = closing[cursor] else { return nil }
        parens.append(cursor)
        cursor = close + 1
    }
    guard isSqlWord(tokens, cursor, "as") else { return nil }
    cursor += 1
    if isSqlWord(tokens, cursor, "not") { cursor += 1 }
    if isSqlWord(tokens, cursor, "materialized") { cursor += 1 }
    guard isSqlSymbol(tokens, cursor, "(") else { return nil }
    return parens + [cursor]
}

/// CTE 이름이 될 수 있는 토큰인지 본다 — 비인용 이름이거나 비어 있지 않은 인용 식별자다.
private func isCteName(_ token: SqlToken) -> Bool {
    token.quoted ? !token.text.isEmpty : isNameToken(token)
}

/// CTE 이름과 한정자 없는 피연산자의 비교 키다. 비인용 이름은 SQL 식별자 규칙대로 소문자로 접고
/// 인용 이름은 그대로 둔다(isthmus 참조 구현과 같은 선택이다).
private func cteKey(_ token: SqlToken) -> String {
    token.quoted ? token.text : token.text.lowercased()
}

/// R1: 토큰마다 감싼 가장 안쪽 괄호가 함수 인자 그룹인지 센다. `;`는 열린 괄호 문맥을 모두 버린다.
private func sqlFunctionArgumentScopes(_ tokens: [SqlToken], cteParens: Set<Int>) -> [Bool] {
    var inside = [Bool](repeating: false, count: tokens.count)
    var groups: [Bool] = []
    for index in tokens.indices {
        if isSqlSymbol(tokens, index, ";") {
            groups.removeAll()
        } else if isSqlSymbol(tokens, index, "(") {
            groups.append(!cteParens.contains(index) && opensFunctionArguments(tokens, index))
        } else if isSqlSymbol(tokens, index, ")") {
            _ = groups.popLast()
        } else {
            inside[index] = groups.last ?? false
        }
    }
    return inside
}

/// `(`가 함수 인자 그룹을 여는지 본다 — 바로 앞이 함수 이름이고 그룹이 SELECT·WITH·VALUES로 시작하지 않는다.
/// 함수 이름은 절 키워드·관계 키워드가 아닌 비인용 이름이다 — 공통 규칙의 "식별자"를 이렇게 좁혀야
/// `FROM ((SELECT …) UNION SELECT … FROM b)`·`AS (DELETE FROM t …)` 같은 하위 질의·CTE 본문 괄호를
/// 함수 인자로 읽지 않는다.
private func opensFunctionArguments(_ tokens: [SqlToken], _ open: Int) -> Bool {
    guard open > 0 else { return false }
    let name = tokens[open - 1]
    guard isNameToken(name), !isClauseWord(name.text), !isRelationKeyword(name.text) else { return false }
    return !["select", "with", "values"].contains { isSqlWord(tokens, open + 1, $0) }
}

/// R3: FROM 바로 앞이 비인용 `distinct`이고 그 앞이 `is` 또는 `is not`이면 비교 연산자의 일부다.
private func isDistinctFromOperator(_ tokens: [SqlToken], _ index: Int) -> Bool {
    guard isSqlWord(tokens, index - 1, "distinct") else { return false }
    return isSqlWord(tokens, index - 2, "is")
        || (isSqlWord(tokens, index - 2, "not") && isSqlWord(tokens, index - 3, "is"))
}

/// `index`의 토큰이 비인용 키워드 `word`(소문자)인지 대소문자 없이 본다 — 범위 밖이면 거짓이다.
private func isSqlWord(_ tokens: [SqlToken], _ index: Int, _ word: String) -> Bool {
    tokens.indices.contains(index) && !tokens[index].quoted && tokens[index].text.lowercased() == word
}

/// `index`의 토큰이 비인용 기호 `symbol`인지 본다 — 범위 밖이면 거짓이다.
private func isSqlSymbol(_ tokens: [SqlToken], _ index: Int, _ symbol: String) -> Bool {
    tokens.indices.contains(index) && !tokens[index].quoted && tokens[index].text == symbol
}

/// 뒤따르는 식별자가 관계 이름인 키워드다. `on`은 GRANT/REVOKE 문 안에서만 관계 키워드로 발화한다.
private func isRelationKeyword(_ word: String) -> Bool {
    ["from", "join", "into", "update", "table", "truncate", "on"].contains(word.lowercased())
}

private func isSqlVerb(_ word: String) -> Bool {
    ["select", "insert", "delete", "create", "alter", "drop", "replace", "merge",
     "lock", "unlock", "rename", "describe", "desc", "analyze", "vacuum", "grant", "revoke"]
        .contains(word.lowercased())
}

/// GRANT/REVOKE의 권한 단어인지 본다 — `ON`이 관계 자리임을 확정하는 근거다.
private func isGrantPriv(_ word: String) -> Bool {
    ["select", "insert", "update", "delete", "truncate", "references", "trigger",
     "execute", "usage", "create", "connect", "temporary", "temp", "maintain", "all"]
        .contains(word.lowercased())
}

/// `table` 토큰이 관계 키워드로 발화하는 문맥인지 본다 — 직전 비인용 식별자가 DDL 동사일 때만이다.
private func tableKeywordContext(_ tokens: [SqlToken], _ i: Int, strict: Bool) -> Bool {
    var k = i - 1
    while k >= 0 {
        if !isNameToken(tokens[k]) { k -= 1; continue }
        if strict && tokens[k].text != tokens[k].text.uppercased() { return false }
        return ["alter", "drop", "create", "truncate", "rename", "lock", "unlock",
                "describe", "desc", "analyze", "vacuum"].contains(tokens[k].text.lowercased())
    }
    return false
}

/// 관계 키워드와 이름 사이에 올 수 있는 수식어다 — `table`은 TRUNCATE 뒤에서만 수식어다.
private func isNameModifier(_ word: String, afterTruncate: Bool) -> Bool {
    ["only", "if", "not", "exists"].contains(word.lowercased())
        || (afterTruncate && word.lowercased() == "table")
}

/// `(` 토큰부터 짝이 맞는 `)` 다음 위치를 돌려준다 — 닫히지 않으면 nil.
private func skipParens(_ tokens: [SqlToken], _ start: Int) -> Int? {
    var depth = 0
    for k in start..<tokens.count {
        let t = tokens[k]
        if t.quoted { continue }
        if t.text == "(" { depth += 1 }
        else if t.text == ")" {
            depth -= 1
            if depth == 0 { return k + 1 }
        }
    }
    return nil
}

/// 관계 이름 위치에 올 수 없는 SQL 절 키워드다 — `FROM {} WHERE` 템플릿의
/// 빈 플레이스홀더 뒤 토큰이 관계명으로 오독되지 않게 한다.
/// (`table`은 이름으로 읽어야 해서 제외한다 — `UPDATE table SET` 참조.)
private func isClauseWord(_ word: String) -> Bool {
    ["where", "set", "on", "group", "order", "by", "having", "limit", "offset",
     "union", "intersect", "except", "values", "returning", "as", "left", "right",
     "inner", "outer", "full", "cross", "natural", "lateral", "using", "and", "or",
     "not", "null", "select", "insert", "delete", "from", "join", "into", "update",
     "truncate", "with", "for", "in", "is", "case", "when", "then", "else", "end",
     "distinct", "asc", "desc", "if", "exists", "only", "between", "like", "to",
     "grant", "revoke", "option", "cascade", "restrict", "privileges",
     // 산문 관사다 — "select an option from the menu" 같은 문장이
     // 관계명을 만들지 않게 한다(`a`는 실제 별칭·이름으로 흔해 제외한다).
     "the", "an"].contains(word.lowercased())
}

/// `ident(.ident)*` 한정 이름을 읽어 (이름, 다음 위치)를 돌려준다.
private func readQualifiedName(_ tokens: [SqlToken], _ start: Int) -> (String, Int)? {
    guard start < tokens.count else { return nil }
    let first = tokens[start]
    if first.quoted {
        if first.text.isEmpty { return nil }
    } else if !isNameToken(first) || isClauseWord(first.text) {
        // 절 키워드(WHERE·SET·AS …)는 이름이 아니다 — `FROM {} WHERE`의
        // where 같은 토큰이 관계명으로 읽히지 않게 한다.
        return nil
    }
    var name = escapeSegment(first)
    var i = start + 1
    while i + 1 < tokens.count && tokens[i].text == "." && !tokens[i].quoted {
        let next = tokens[i + 1]
        if !next.quoted && (!isNameToken(next) || isClauseWord(next.text)) { break }
        name += "." + escapeSegment(next)
        i += 2
    }
    return (name, i)
}

/// 인용 세그먼트의 `%`와 `.`을 escape한다 — `"a.b"` 같은 한 식별자가
/// 한정자로 오독되지 않게 하고, escape 문자 자체의 충돌을 막는다.
/// 비인용 세그먼트는 점을 담을 수 없어 `%`만 escape한다.
private func escapeSegment(_ tok: SqlToken) -> String {
    if tok.quoted {
        return tok.text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ".", with: "%2E")
    }
    return tok.text.replacingOccurrences(of: "%", with: "%25")
}

/// 한정 이름의 각 세그먼트를 escape해 합친다 — 어노테이션에서 온 이름도 `.`가 한정자인 계약과 같게 맞춘다.
func escapeQualified(_ name: String) -> String {
    name.split(separator: ".", omittingEmptySubsequences: false)
        .map { $0.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ".", with: "%2E") }
        .joined(separator: ".")
}

/// 이름 문자열 그대로를 한 세그먼트로 escape한다 — `tableName = "a.b"` 같은 값은 한정자가 아니라 한 식별자다.
func escapeName(_ name: String) -> String {
    name.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ".", with: "%2E")
}

/// 비인용 토큰이 식별자인지 본다 — 기호·빈 문자열은 아니다.
private func isNameToken(_ tok: SqlToken) -> Bool {
    !tok.quoted && !tok.text.isEmpty && isIdentStart(tok.text.first!)
}

/// SQL 식별자 시작 문자인지 본다.
private func isIdentStart(_ c: Character) -> Bool {
    if c == "_" || c == "$" { return true }
    if ("a"..."z").contains(c) || ("A"..."Z").contains(c) { return true }
    return c.unicodeScalars.allSatisfy { $0.value >= 0x80 } && !c.unicodeScalars.isEmpty
}

/// SQL 식별자의 이어지는 문자인지 본다.
private func isIdentPart(_ c: Character) -> Bool {
    isIdentStart(c) || ("0"..."9").contains(c)
}
