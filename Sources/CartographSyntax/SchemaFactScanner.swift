import CartographCore
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// `schema` 스캔 한 파일의 계수들 — 사실로 만들지 못한 근거를 세어 limitation으로 올린다.
///
/// "없다"와 "못 봤다"를 구분하는 장부다. 지원 표면 밖 프레임워크의 import도
/// 사실이 아니라 관측 개수로 남긴다 — Core Data 엔티티명은 SQL 카탈로그의
/// 관계가 아니므로 사실로 만들면 없는 선언을 찾는 거짓 진단이 된다.
public struct SchemaScanCounts: Sendable, Equatable {
    /// 비리터럴 SQL 인자·미해석 피연산자 수 — 동적 사실로도 남는다.
    public var unjoinedDynamic = 0
    /// SQL 동사를 가졌지만 대문자 형태가 아니라 strict 게이트를 못 넘은 게이트 없는 리터럴 수.
    public var skippedSqlLiterals = 0
    /// `NSFetchRequest`·`NSEntityDescription`·`@FetchRequest`·`entityName:` 관측 수.
    public var coreDataReferences = 0
    /// `@Model`·`FetchDescriptor`·`#Predicate` 관측 수.
    public var swiftDataReferences = 0
    /// `realm.objects(`·Realm 객체 상속 선언의 관측 수.
    public var realmReferences = 0
    /// 지원 표면이 없는 DB 프레임워크의 이 파일 내 import 이름(정렬됨).
    public var unsupportedFrameworks: [String] = []

    public init() {}
}

/// `SchemaFactScanner`가 파일 하나를 읽은 결과다.
public struct SchemaScanResult: Sendable, Equatable {
    public let facts: [ScannedBridgeFact]
    public let counts: SchemaScanCounts

    public init(facts: [ScannedBridgeFact], counts: SchemaScanCounts) {
        self.facts = facts
        self.counts = counts
    }
}

/// Swift 소스에서 DB 관계 참조를 읽어 `relation-use` 사실을 만든다.
///
/// isthmus persistence 조인의 호출 측 생산자다 — 선언(`relation-decl`)은
/// schemagraph가 낸다. 증거가 있는 표면만 읽는다: sqlite3 C API 인자,
/// GRDB `sql:` 인자·`Table`·`databaseTableName`, SQLite.swift `Table`·
/// `prepare`/`run`, Fluent `schema`·`static let schema`·`query(T.self)`,
/// 그리고 게이트 없는 대문자 SQL 리터럴. Core Data·SwiftData·Realm과
/// 나머지 프레임워크는 관측 개수로만 남긴다.
///
/// 선언 수집이 사용 스캔보다 먼저다 — 타입→테이블 바인딩이 사용 지점보다
/// 아래에 선언돼도 해석돼야 한다.
public struct SchemaFactScanner: Sendable {
    public init() {}

    public func scan(source: String, path: String) -> SchemaScanResult {
        let parsed = Parser.parse(source: source)
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }.as(SourceFileSyntax.self) ?? parsed
        let converter = SourceLocationConverter(fileName: path, tree: tree)

        let declarations = SchemaDeclCollector()
        declarations.walk(tree)

        let collector = SchemaFactCollector(converter: converter, declarations: declarations, path: path)
        collector.walk(tree)
        var counts = collector.counts
        counts.unsupportedFrameworks = declarations.unsupportedFrameworks
        return SchemaScanResult(
            facts: collector.facts.sorted { $0.fact < $1.fact },
            counts: counts
        )
    }
}

// MARK: - 선언 수집 패스

/// import·리터럴 바인딩·타입→테이블 바인딩을 사용 지점보다 먼저 모은다.
final class SchemaDeclCollector: SyntaxVisitor {
    /// 이 파일이 import하는 모듈의 첫 경로 구성요소들(`import GRDB.Support`의 `GRDB`).
    private(set) var imports: Set<String> = []
    /// `let sql = "…"` — 파일 수준의 한 단계 상수 해석.
    private(set) var stringBindings: [String: String] = [:]
    /// `let users = Table("users")` — 식별자가 가리키는 관계 이름.
    private(set) var tableBindings: [String: String] = [:]
    /// `static let/var databaseTableName`·`static let/var schema` — 타입이 가리키는 관계 이름.
    private(set) var typeTables: [String: String] = [:]
    /// 타입 선언의 중첩 스택 — `static let`이 어느 타입의 것인지 귀속한다.
    private var typeStack: [String] = []
    /// `let sql = "…"`의 리터럴 노드들 — gated 호출이 이름으로 참조한 리터럴은
    /// ungated 리터럴 패스가 다시 읽지 않게 억제 목록으로 넘긴다.
    /// 같은 값의 재바인딩도 허용되므로 이름당 여러 리터럴을 기억한다.
    private var stringBindingLiteralIds: [String: [SyntaxIdentifier]] = [:]
    /// gated 호출의 SQL 인자로 참조된 바인딩 리터럴 — 중복 발화 억제용.
    private(set) var suppressedLiteralIds: Set<SyntaxIdentifier> = []
    /// 같은 이름이 다른 값으로 다시 묶인 식별자 — 어느 쪽도 믿을 수 없어 귀속을 끊는다.
    private var poisonedNames: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    /// 지원 표면에 없는 DB 프레임워크 모듈 이름들.
    static let unsupportedDbModules: Set<String> = [
        "FMDB", "PostgresNIO", "PostgresClientKit", "MySQLNIO", "MySQLKit",
        "MongoSwift", "MongoDB", "Redis", "Supabase", "CassandraClient", "DuckDB",
    ]

    /// `static let x = "…"` 초기값이나 `static var x: T { "…" }` 단일 getter의 리터럴.
    static func tableNameLiteral(of binding: PatternBindingSyntax) -> String? {
        if let literal = binding.initializer?.value.as(StringLiteralExprSyntax.self)?.representedLiteralValue {
            return literal
        }
        guard case let .getter(getter) = binding.accessorBlock?.accessors,
              getter.count == 1,
              let literal = getter.first?.item.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        else { return nil }
        return literal
    }

    /// 지원 표면에 없는 DB 프레임워크의 import 이름 — 파일당 한 번 센다.
    var unsupportedFrameworks: [String] {
        imports.intersection(Self.unsupportedDbModules).sorted()
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let first = node.path.first {
            imports.insert(first.name.text)
        }
        return .visitChildren
    }

    private func pushType(_ node: some SyntaxProtocol & NamedDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node) }
    override func visitPost(_: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node) }
    override func visitPost(_: StructDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { pushType(node) }
    override func visitPost(_: EnumDeclSyntax) { typeStack.removeLast() }
    /// `extension Player { static let databaseTableName = … }` — 준수를 extension으로
    /// 나누는 관용구가 흔해 타입→테이블 귀속에 반드시 필요하다.
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // 확장 대상은 한정형일 수 있다 — `typeTables` 조회는 단순 이름 기준이라 마지막
        // 구성요소만 취한다(중첩 타입의 단순 이름 한계는 조회 쪽과 같은 규약이다).
        typeStack.append(node.extendedType.trimmedDescription.components(separatedBy: ".").last
            ?? node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_: ExtensionDeclSyntax) { typeStack.removeLast() }

    /// 이름이 새 값으로 재바인딩되면 두 선언 중 어느 것도 믿을 수 없다 — 잘못된 관계명을
    /// 싣는 오귀속보다 사용 지점의 동적 근거가 낫다.
    private func bind<T: Equatable>(
        _ name: String, _ value: T, into bindings: inout [String: T]
    ) {
        if poisonedNames.contains(name) { return }
        if let existing = bindings[name], existing != value {
            bindings.removeValue(forKey: name)
            poisonedNames.insert(name)
            return
        }
        bindings[name] = value
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isStatic = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { continue }
            if let literal = binding.initializer?.value.as(StringLiteralExprSyntax.self),
               let value = literal.representedLiteralValue {
                bind(identifier, value, into: &stringBindings)
                stringBindingLiteralIds[identifier, default: []].append(literal.id)
            } else if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
                      isTableConstructorCall(call),
                      let name = call.arguments.first?.expression
                        .as(StringLiteralExprSyntax.self)?.representedLiteralValue {
                // `let users = Table("users")` — 식별자→관계 바인딩. 호출 인자 리터럴은
                // `.`가 한정자라 `escapeQualified`로 채널 형태를 미리 만들어 둔다.
                bind(identifier, escapeQualified(name), into: &tableBindings)
            }
            // 타입 안의 static 테이블명 선언 — `static let schema = "users"`나
            // `static var databaseTableName: String { "users" }` 둘 다다.
            if isStatic, let type = typeStack.last,
               ["databaseTableName", "schema", "tableName"].contains(identifier),
               let literal = Self.tableNameLiteral(of: binding) {
                bind(type, escapeName(literal), into: &typeTables)
            }
        }
        return .visitChildren
    }

    /// gated 호출의 SQL 인자가 바인딩 상수를 가리키면 선언 자리의 리터럴을 억제한다 —
    /// 억제하지 않으면 같은 SQL이 선언 위치와 호출 위치에서 두 번 사실이 된다.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let calleeName = sqlCallName(of: node) else { return .visitChildren }
        var sqlArg: ExprSyntax?
        if sqlite, SchemaSqlSurface.sqliteSqlFunctions.contains(calleeName),
           node.arguments.count > 1 {
            sqlArg = Array(node.arguments)[1].expression
        } else if sqliteSwift, SchemaSqlSurface.sqliteSwiftSqlMethods.contains(calleeName),
                  let first = node.arguments.first, first.label == nil {
            sqlArg = first.expression
        } else if (grdb || sqliteSwift || fluent),
                  let labeled = node.arguments.first(where: { $0.label?.text == "sql" }) {
            sqlArg = labeled.expression
        } else if (fluent || grdb), SchemaSqlSurface.sqlConstructors.contains(calleeName),
                  let first = node.arguments.first, first.label == nil {
            sqlArg = first.expression
        }
        if let reference = sqlArg?.as(DeclReferenceExprSyntax.self),
           let ids = stringBindingLiteralIds[reference.baseName.text] {
            suppressedLiteralIds.formUnion(ids)
        }
        return .visitChildren
    }

    private func importsAny(_ modules: [String]) -> Bool {
        modules.contains { imports.contains($0) }
    }
    private var sqlite: Bool { importsAny(["SQLite3", "SQLite3_ObjC"]) }
    private var grdb: Bool { importsAny(["GRDB"]) }
    private var sqliteSwift: Bool { importsAny(["SQLite"]) }
    private var fluent: Bool { importsAny(["Fluent", "FluentKit", "FluentSQL"]) }
}

// MARK: - 사실 수집 패스

final class SchemaFactCollector: SyntaxVisitor {
    private(set) var facts: [ScannedBridgeFact] = []
    private(set) var counts = SchemaScanCounts()

    private let converter: SourceLocationConverter
    private let declarations: SchemaDeclCollector
    private let path: String

    /// 심볼 귀속용 선언 스택 — 사실을 감싸는 가장 안쪽 선언이 USR을 받는다.
    private var declarationStack: [EnclosingDeclaration] = []
    private var typeNames: [String] = []
    /// 게이트가 있는 인자로 이미 읽은 문자열 리터럴 — 원시 리터럴 패스가 다시 읽지 않게 한다.
    private var consumedLiterals: Set<SyntaxIdentifier> = []

    init(converter: SourceLocationConverter, declarations: SchemaDeclCollector, path: String) {
        self.converter = converter
        self.declarations = declarations
        self.path = path
        super.init(viewMode: .sourceAccurate)
    }

    private func has(_ modules: String...) -> Bool {
        modules.contains { declarations.imports.contains($0) }
    }

    private var sqlite: Bool { has("SQLite3", "SQLite3_ObjC") }
    private var grdb: Bool { has("GRDB") }
    private var sqliteSwift: Bool { has("SQLite") }
    private var fluent: Bool { has("Fluent", "FluentKit", "FluentSQL") }
    private var coreData: Bool { has("CoreData") }
    private var swiftData: Bool { has("SwiftData") }
    private var realm: Bool { has("RealmSwift", "Realm") }

    // MARK: 선언 문맥

    private func pushType(_ name: String, node: some SyntaxProtocol) {
        typeNames.append(name)
        pushDeclaration(name: name, indexName: name, node: node)
    }

    private func popType() {
        typeNames.removeLast()
        declarationStack.removeLast()
    }

    private func pushDeclaration(name: String, indexName: String, node: some SyntaxProtocol) {
        let start = node.startLocation(converter: converter)
        let end = node.endLocation(converter: converter)
        declarationStack.append(EnclosingDeclaration(
            name: name, indexName: indexName,
            qualifiedName: (typeNames + [name]).joined(separator: "."),
            line: start.line,
            start: CartographCore.SourceLocation(path: path, line: start.line, column: start.column),
            end: CartographCore.SourceLocation(path: path, line: end.line, column: end.column)
        ))
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node)
        // Realm 객체 선언 자체가 관측 근거다 — 관계 이름이 아니라 개수로 남긴다.
        if realm, node.inheritanceClause?.inheritedTypes.contains(where: {
            ["Object", "EmbeddedObject"].contains($0.type.trimmedDescription.components(separatedBy: ".").last)
        }) == true {
            counts.realmReferences += 1
        }
        return .visitChildren
    }
    override func visitPost(_: ClassDeclSyntax) { popType() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node)
        return .visitChildren
    }
    override func visitPost(_: StructDeclSyntax) { popType() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, node: node)
        return .visitChildren
    }
    override func visitPost(_: EnumDeclSyntax) { popType() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.extendedType.trimmedDescription, node: node)
        return .visitChildren
    }
    override func visitPost(_: ExtensionDeclSyntax) { popType() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let base = node.name.text
        pushDeclaration(
            name: base,
            indexName: RuntimeSyntaxNames.indexName(base, parameters: node.signature.parameterClause.parameters),
            node: node
        )
        return .visitChildren
    }
    override func visitPost(_: FunctionDeclSyntax) { declarationStack.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushDeclaration(
            name: "init",
            indexName: RuntimeSyntaxNames.indexName("init", parameters: node.signature.parameterClause.parameters),
            node: node
        )
        return .visitChildren
    }
    override func visitPost(_: InitializerDeclSyntax) { declarationStack.removeLast() }

    // MARK: 타입 테이블 선언

    /// `static let databaseTableName = "users"`·`static let schema = "users"` 선언 자리도 사용 사실이다.
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isStatic = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
        guard isStatic, !typeNames.isEmpty else { return .visitChildren }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  ["databaseTableName", "schema", "tableName"].contains(identifier),
                  let literal = SchemaDeclCollector.tableNameLiteral(of: binding)
            else { continue }
            // 선언이 증거인 프레임워크가 import됐을 때만 낸다 — 어느 프로젝트에나
            // `static let schema`는 있을 수 있는 이름이다.
            let gated = (identifier == "databaseTableName" && grdb)
                || (identifier == "schema" && fluent)
                || (identifier == "tableName" && (grdb || sqliteSwift))
            if gated {
                emit(channel: escapeName(literal), method: nil, dynamic: false, at: binding)
            }
        }
        return .visitChildren
    }

    // MARK: 호출

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression.as(MemberAccessExprSyntax.self)
        guard let calleeName = sqlCallName(of: node) else { return .visitChildren }
        let base = callee?.base
        let called = node.calledExpression.as(GenericSpecializationExprSyntax.self)?.expression
            ?? node.calledExpression
        let isConstructor = called.is(DeclReferenceExprSyntax.self)
        // `SQLite.Table("users")` 같은 한정 생성자 — 대문자 기본 식별자는 모듈·타입이다.
        let isQualifiedConstructor = callee != nil
            && calleeName == "Table"
            && base?.as(DeclReferenceExprSyntax.self)?.baseName.text.first?.isUppercase == true

        if sqlite && SchemaSqlSurface.sqliteSqlFunctions.contains(calleeName) {
            // sqlite3_prepare_v2(db, sql, …) — SQL은 두 번째 인자다.
            let args = Array(node.arguments)
            if args.count > 1 {
                if let literal = args[1].expression.as(StringLiteralExprSyntax.self) {
                    consumedLiterals.insert(literal.id)
                }
                emitSqlArgument(args[1].expression, at: args[1])
            }
        }
        // GRDB·SQLite.swift·Fluent의 `sql:` 라벨 인자 — 라벨 자체가 계약이다.
        if (grdb || sqliteSwift || fluent),
           let sqlArg = node.arguments.first(where: { $0.label?.text == "sql" }) {
            consumedLiterals.insert(sqlArg.expression.id)
            emitSqlArgument(sqlArg.expression, at: sqlArg)
        }
        // SQLite.swift `db.prepare("…")`·`db.run("…")` — 첫 인자가 SQL이다.
        if sqliteSwift && SchemaSqlSurface.sqliteSwiftSqlMethods.contains(calleeName),
           let first = node.arguments.first, first.label == nil {
            if let literal = first.expression.as(StringLiteralExprSyntax.self) {
                consumedLiterals.insert(literal.id)
            }
            // `db.run(users.insert(…))` — 표현식 빌더 인자는 안쪽 호출이 자기 사실을
            // 내므로 바깥에서 동적 근거를 중복 계수하지 않는다.
            if !resolvesToBoundTable(first.expression) {
                emitSqlArgument(first.expression, at: first)
            }
        }
        // `Table("users")` — GRDB·SQLite.swift 공용 타입 이름.
        if (grdb || sqliteSwift), calleeName == "Table", isConstructor || isQualifiedConstructor,
           let arg = node.arguments.first, arg.label == nil {
            emitNameArgument(arg.expression, at: arg)
        }
        // GRDB `db.create(table:)` 계열 — `table:` 라벨 인자가 관계명이다.
        if grdb, SchemaSqlSurface.grdbTableLabelMethods.contains(calleeName),
           let tableArg = node.arguments.first(where: { $0.label?.text == "table" }) {
            emitNameArgument(tableArg.expression, at: tableArg)
        }
        // GRDB `db.tableExists("users")` — 첫 인자가 관계명이다.
        if grdb, SchemaSqlSurface.grdbTableArgMethods.contains(calleeName),
           let arg = node.arguments.first, arg.label == nil {
            emitNameArgument(arg.expression, at: arg)
        }
        // Fluent `schema("users")`·`database.schema("users")`.
        if fluent, calleeName == "schema",
           let arg = node.arguments.first, arg.label == nil {
            emitNameArgument(arg.expression, at: arg)
        }
        // Fluent `db.query(User.self)` — 모델 타입의 schema 바인딩으로 해석한다.
        if fluent, calleeName == "query",
           let arg = node.arguments.first, arg.label == nil {
            emitModelArgument(arg.expression, at: arg)
        }
        // `SQLQueryString("SELECT …")`·`SQLLiteral("…")` — SQL을 담는 생성자.
        if (fluent || grdb), isConstructor, SchemaSqlSurface.sqlConstructors.contains(calleeName),
           let arg = node.arguments.first, arg.label == nil {
            consumedLiterals.insert(arg.expression.id)
            emitSqlArgument(arg.expression, at: arg)
        }
        // 테이블 바인딩된 수신자의 멤버 호출 — `users.filter(…)`, `User.select(…)` 등.
        if let table = base.flatMap(tableName(of:)) {
            emit(channel: table, method: nil, dynamic: false, at: node.calledExpression)
            // 호출 인자 안의 `Column("x")`는 그 테이블의 컬럼 참조다. 중첩된 바인딩
            // 수신자 호출은 건너뛴다 — 그쪽 방문이 자기 채널로 낸다.
            let columns = ColumnCollector(root: node) { [self] nested in
                guard let nestedBase = nested.calledExpression
                    .as(MemberAccessExprSyntax.self)?.base else { return false }
                return tableName(of: nestedBase) != nil
            }
            columns.walk(node)
            for found in columns.names {
                emit(channel: table, method: escapeName(found.name), dynamic: false, at: found.node)
            }
        }
        // Core Data·SwiftData·Realm 표면은 관계 사실이 아니라 관측 개수다.
        countUnsupportedSurface(calleeName: calleeName, node: node)
        return .visitChildren
    }

    /// SQLite.swift 표현식 빌더 인자가 바인딩된 테이블로 해석되는지 본다 —
    /// `users.insert(…)`의 안쪽 호출이 수신자 처리로 자기 사실을 낸다.
    private func resolvesToBoundTable(_ expression: ExprSyntax) -> Bool {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            return declarations.tableBindings[name] != nil || declarations.typeTables[name] != nil
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.base {
            return tableName(of: base) != nil
        }
        return false
    }

    /// 수신자 식이 가리키는 관계의 채널 이름 — 바인딩값은 수집 때 이미 이스케이프됐다.
    private func tableName(of expression: ExprSyntax?) -> String? {
        guard let expression else { return nil }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            return declarations.tableBindings[name] ?? declarations.typeTables[name]
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Table",
           let literal = call.arguments.first?.expression
            .as(StringLiteralExprSyntax.self)?.representedLiteralValue {
            return escapeQualified(literal)
        }
        return nil
    }

    /// 지원 표면 밖 프레임워크의 호출 관측을 센다.
    private func countUnsupportedSurface(calleeName: String, node: FunctionCallExprSyntax) {
        if coreData {
            if calleeName == "NSFetchRequest" || calleeName == "NSEntityDescription"
                || node.arguments.contains(where: { $0.label?.text == "entityName" }) {
                counts.coreDataReferences += 1
            }
        }
        if swiftData, calleeName == "FetchDescriptor" {
            counts.swiftDataReferences += 1
        }
        if realm, calleeName == "objects" {
            counts.realmReferences += 1
        }
    }

    // MARK: 매크로·속성 관측

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let name = node.attributeName.trimmedDescription
        if coreData && name == "FetchRequest" { counts.coreDataReferences += 1 }
        if swiftData && ["Query", "Model"].contains(name) { counts.swiftDataReferences += 1 }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if swiftData && node.macroName.text == "Predicate" { counts.swiftDataReferences += 1 }
        return .visitChildren
    }

    // MARK: 게이트 없는 문자열 리터럴

    /// 어느 게이트 인자로도 소비되지 않은 리터럴 — strict 모드로만 발화한다.
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard !consumedLiterals.contains(node.id),
              !declarations.suppressedLiteralIds.contains(node.id)
        else { return .visitChildren }
        if let value = node.representedLiteralValue {
            if looksLikeSql(value, strict: true) {
                emitSql(value, strict: true, at: node)
            } else if looksLikeSql(value) {
                // SQL 동사를 가졌지만 대문자 형태가 아니다 — 산문일 가능성이 커
                // 관계를 만들지 않되 버린 개수는 limitation으로 남긴다.
                counts.skippedSqlLiterals += 1
            }
        } else if let prefix = interpolatedPrefix(of: node) {
            if looksLikeSql(prefix, strict: true) {
                counts.unjoinedDynamic += 1
                emitDynamic(expression: node.trimmedDescription, channelPrefix: prefix, at: node)
            } else if looksLikeSql(prefix) {
                counts.skippedSqlLiterals += 1
            }
        }
        return .visitChildren
    }

    // MARK: 인자 방출

    /// SQL 인자 하나 — 리터럴·바인딩된 상수면 관계를 읽고, 아니면 동적 근거다.
    private func emitSqlArgument(_ expression: ExprSyntax, at node: some SyntaxProtocol) {
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            if let value = literal.representedLiteralValue {
                emitSql(value, at: node)
                return
            }
            // 게이트가 확정한 SQL 자리다 — 보간 리터럴은 접두사와 함께 동적 근거로 남긴다.
            counts.unjoinedDynamic += 1
            emitDynamic(
                expression: literal.trimmedDescription,
                channelPrefix: interpolatedPrefix(of: literal),
                at: node
            )
            return
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self),
           let value = declarations.stringBindings[reference.baseName.text] {
            emitSql(value, at: node)
            return
        }
        counts.unjoinedDynamic += 1
        emitDynamic(expression: expression.trimmedDescription, channelPrefix: nil, at: node)
    }

    /// 관계명 인자 하나(`Table(…)`, `schema(…)`, `table:`) — 비리터럴은 동적 근거다.
    /// 호출 인자 리터럴의 `.`는 한정자라 `escapeQualified`로 채널을 만든다.
    private func emitNameArgument(_ expression: ExprSyntax, at node: some SyntaxProtocol) {
        // 이름이 대문자 SQL 동사 형태여도 ungated 리터럴 패스가 다시 읽지 않게 한다.
        if let literalExpr = expression.as(StringLiteralExprSyntax.self) {
            consumedLiterals.insert(literalExpr.id)
        }
        if let literal = expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue {
            emit(channel: escapeQualified(literal), method: nil, dynamic: false, at: node)
            return
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self),
           let value = declarations.stringBindings[reference.baseName.text] {
            emit(channel: escapeQualified(value), method: nil, dynamic: false, at: node)
            return
        }
        counts.unjoinedDynamic += 1
        emitDynamic(expression: expression.trimmedDescription, channelPrefix: nil, at: node)
    }

    /// `query(User.self)`의 모델 타입 인자 — 타입→테이블 바인딩으로 해석하고 못 찾으면 동적 근거다.
    private func emitModelArgument(_ expression: ExprSyntax, at node: some SyntaxProtocol) {
        if let member = expression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "self",
           let typeName = member.base?.trimmedDescription.components(separatedBy: ".").last,
           let table = declarations.typeTables[typeName] {
            emit(channel: table, method: nil, dynamic: false, at: node)
            return
        }
        counts.unjoinedDynamic += 1
        emitDynamic(expression: expression.trimmedDescription, channelPrefix: nil, at: node)
    }

    /// SQL 텍스트의 관계들을 사실로 낸다 — 미해석 피연산자는 개수로 남긴다.
    private func emitSql(_ sql: String, strict: Bool = false, at node: some SyntaxProtocol) {
        let (relations, unresolved) = sqlRelations(sql, strict: strict)
        for relation in relations {
            emit(channel: relation.name, method: nil, dynamic: false, at: node)
        }
        counts.unjoinedDynamic += unresolved
    }

    private func emitDynamic(expression: String, channelPrefix: String?, at node: some SyntaxProtocol) {
        let location = node.startLocation(converter: converter)
        facts.append(ScannedBridgeFact(
            fact: BridgeFact(
                kind: .relationUse, target: .persistence,
                channel: expression.isEmpty ? nil : String(expression.prefix(160)),
                isDynamic: true,
                channelPrefix: channelPrefix,
                location: CartographCore.SourceLocation(path: path, line: location.line, column: location.column)
            ),
            declaration: declarationStack.last
        ))
    }

    private func emit(channel: String, method: String?, dynamic: Bool, at node: some SyntaxProtocol) {
        let location = node.startLocation(converter: converter)
        facts.append(ScannedBridgeFact(
            fact: BridgeFact(
                kind: .relationUse, target: .persistence,
                channel: channel, method: method,
                isDynamic: dynamic,
                location: CartographCore.SourceLocation(path: path, line: location.line, column: location.column)
            ),
            declaration: declarationStack.last
        ))
    }
}

/// 호출 표현식 안의 `Column("name")` 생성자를 찾는다 — 수신자 테이블의 컬럼 참조다.
/// 바인딩된 수신자의 중첩 멤버 호출은 건너뛴다 — 그 컬럼은 그 호출 자신의 채널 소유다.
private final class ColumnCollector: SyntaxVisitor {
    struct Found {
        let name: String
        let node: FunctionCallExprSyntax
    }
    private(set) var names: [Found] = []
    private let root: FunctionCallExprSyntax
    private let isBoundReceiverCall: (FunctionCallExprSyntax) -> Bool

    init(root: FunctionCallExprSyntax,
         isBoundReceiverCall: @escaping (FunctionCallExprSyntax) -> Bool) {
        self.root = root
        self.isBoundReceiverCall = isBoundReceiverCall
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if node.id != root.id, isBoundReceiverCall(node) { return .skipChildren }
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
              callee.baseName.text == "Column",
              let literal = node.arguments.first?.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        else { return .visitChildren }
        names.append(Found(name: literal, node: node))
        return .visitChildren
    }
}

/// 보간 문자열의 첫 리터럴 세그먼트를 디코드한다 — 접두사가 SQL 모양일 때만
/// 동적 근거로 남기는 판정에 쓴다.
private func interpolatedPrefix(of literal: StringLiteralExprSyntax) -> String? {
    guard literal.segments.contains(where: { $0.as(ExpressionSegmentSyntax.self) != nil }) else { return nil }
    let leading = literal.segments.prefix { $0.as(StringSegmentSyntax.self) != nil }
    guard !leading.isEmpty else { return nil }
    let segments = StringLiteralSegmentListSyntax(Array(leading))
    let prefix = StringLiteralExprSyntax(
        openingPounds: literal.openingPounds,
        openingQuote: literal.openingQuote,
        segments: segments,
        closingQuote: literal.closingQuote,
        closingPounds: literal.closingPounds
    )
    return prefix.representedLiteralValue
}

/// 두 수집 패스가 함께 쓰는 지원 표면 상수 — Decl→Fact 방향 참조를 막기 위해
/// 어느 수집기의 멤버로도 두지 않는다.
enum SchemaSqlSurface {
    /// sqlite3 C API의 SQL 인자를 가진 함수들 — 두 번째 인자가 SQL이다.
    static let sqliteSqlFunctions: Set<String> = [
        "sqlite3_prepare", "sqlite3_prepare_v2", "sqlite3_prepare_v3",
        "sqlite3_prepare16", "sqlite3_prepare16_v2", "sqlite3_prepare16_v3",
        "sqlite3_exec", "sqlite3_get_table",
    ]
    /// SQLite.swift의 첫 인자가 SQL인 메서드다 — `db.prepare("…")`·`db.run("…")`.
    static let sqliteSwiftSqlMethods: Set<String> = ["prepare", "run", "execute", "scalar"]
    /// SQL 텍스트를 담는 생성자 — `SQLQueryString("…")`·`SQLLiteral("…")`.
    static let sqlConstructors: Set<String> = ["SQLQueryString", "SQLLiteral", "SQL"]
    /// GRDB에서 `table:` 라벨 인자가 관계명인 메서드다.
    static let grdbTableLabelMethods: Set<String> = ["create", "drop", "alter", "rename"]
    /// GRDB에서 첫 번째 무표기 인자가 관계명인 메서드다 — `db.tableExists("users")`.
    static let grdbTableArgMethods: Set<String> = ["tableExists"]
}

/// 호출의 함수 이름 — `NSFetchRequest<Dog>(…)` 같은 제네릭 특수화 노드는 한 겹 벗긴다.
func sqlCallName(of node: FunctionCallExprSyntax) -> String? {
    if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
        return member.declName.baseName.text
    }
    let called = node.calledExpression.as(GenericSpecializationExprSyntax.self)?.expression
        ?? node.calledExpression
    return called.as(DeclReferenceExprSyntax.self)?.baseName.text
}

/// `Table("…")` 또는 `SQLite.Table("…")` 같은 관계 생성자 호출인지 본다 —
/// 한정 형태는 기본 식별자가 대문자(모듈·타입)일 때만 인정한다.
func isTableConstructorCall(_ call: FunctionCallExprSyntax) -> Bool {
    if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
        return ref.baseName.text == "Table"
    }
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
        return member.declName.baseName.text == "Table"
            && member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text.first?.isUppercase == true
    }
    return false
}
