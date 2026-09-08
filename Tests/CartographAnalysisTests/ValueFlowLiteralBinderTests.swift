import CartographCore
@testable import CartographAnalysis
import Testing

@Suite("문자열 리터럴의 타입 문맥")
struct ValueFlowLiteralBinderTests {
    private let site = SourceLocation(path: "/p/F.swift", line: 1, column: 1)

    private func function(_ id: String, operations: [ValueFlowOperation], parameters: [ValueFlowParameter] = [],
                          returnType: String? = nil, result: Int? = 0) -> ValueFlowFunction {
        ValueFlowFunction(id: id, symbolUSR: id, name: id, indexName: id + "()", location: site,
            parameters: parameters,
            blocks: [.init(id: 0, instructions: operations.enumerated().map {
                .init(id: $0.offset, operation: $0.element, location: site)
            }, terminator: .return(result))], returnType: returnType)
    }

    private func bind(_ program: ValueFlowProgram, snapshot: IndexSnapshot = .init(), fresh: Bool = true)
        -> ValueFlowProgram {
        ValueFlowLiteralBinder(program: program, snapshot: snapshot, freshPaths: fresh ? [site.path] : []).bind()
    }

    private func isKnown(_ program: ValueFlowProgram, function: String = "f", instruction: Int = 0) -> Bool {
        guard let operation = program.functions.first(where: { $0.id == function })?
            .blocks.flatMap(\.instructions).first(where: { $0.id == instruction })?.operation else { return false }
        if case .literal(.string("A")) = operation { return true }
        return false
    }

    @Test("추론된 String과 명시된 String만 신선한 소스에서 승격한다")
    func contexts() {
        for (type, inferred, expected) in [(nil as String?, true, true), ("String", false, true),
            ("Swift.String", false, true), ("StaticString", false, false), ("Alias", false, false),
            (nil, false, false)] {
            let program = ValueFlowProgram(functions: [function("f", operations: [
                .stringLiteral("A", expectedType: type, inferred: inferred)
            ])])
            #expect(isKnown(bind(program)) == expected)
            #expect(!isKnown(bind(program, fresh: false)))
        }
    }

    @Test("암시적 리터럴 생성자 증거가 있으면 String 표기에도 승격하지 않는다")
    func implicitConversion() {
        let program = ValueFlowProgram(functions: [function("f", operations: [
            .stringLiteral("A", expectedType: "String", inferred: false)
        ])])
        let initializer = IndexedSymbol(usr: "custom-init", name: "init(stringLiteral:)", kind: .initializer,
            module: "P", location: site)
        for kind in [EdgeKind.call, .reference] {
            let snapshot = IndexSnapshot(symbols: [initializer], references: [
                .init(sourceUSR: "f", targetUSR: "custom-init", kind: kind, location: site)
            ])
            let lowered = bind(program, snapshot: snapshot)
            #expect(!isKnown(lowered))
            #expect(lowered.limitations.contains("contextual-string-literal"))
        }
    }

    @Test("실제 피호출자의 인자 타입과 반환 타입을 따로 적용한다")
    func argumentsAndReturns() {
        let identity = function("identity", operations: [.parameter(0)],
            parameters: [.init(name: "value", declaredType: "String")], returnType: "String")
        let main = function("f", operations: [
            .stringLiteral("A", expectedType: nil, inferred: false),
            .symbol(.init(location: site, spelling: "identity", usr: "identity")),
            .call(callee: 1, arguments: [0], argumentLabels: [""], isAwait: false)
        ], result: 2)
        #expect(isKnown(bind(.init(functions: [identity, main]))))
        let returned = function("f", operations: [.stringLiteral("A", expectedType: nil, inferred: false)], returnType: "String")
        #expect(isKnown(bind(.init(functions: [returned]))))
        #expect(!isKnown(bind(.init(functions: [main]))))
    }

    @Test("콜백의 반환 기대 타입은 실제 함수 인자에서 얻는다")
    func callback() {
        let callback = function("callback", operations: [.stringLiteral("A", expectedType: nil, inferred: false)])
        let invoke = function("invoke", operations: [], parameters: [.init(name: "body", declaredType: "() -> String")])
        let main = function("f", operations: [
            .closure(function: "callback", captures: []),
            .symbol(.init(location: site, spelling: "invoke", usr: "invoke")),
            .call(callee: 1, arguments: [0], argumentLabels: [""], isAwait: false)
        ], result: 2)
        #expect(isKnown(bind(.init(functions: [callback, invoke, main])), function: "callback"))
    }

    @Test("inout 저장과 필드 저장의 타입을 읽되 미해결 주소는 추측하지 않는다")
    func writes() {
        let setter = function("f", operations: [.parameter(0),
            .stringLiteral("A", expectedType: nil, inferred: false), .write(address: 0, value: 1)],
            parameters: [.init(name: "value", isInout: true, declaredType: "inout String")], result: nil)
        #expect(isKnown(bind(.init(functions: [setter])), instruction: 1))
        let field = ValueFlowField(id: "field", symbolUSR: "field", name: "field", location: site,
            declaredType: "String", isMutable: true)
        let write = function("f", operations: [.symbol(.init(location: site, spelling: "field", usr: "field")),
            .stringLiteral("A", expectedType: nil, inferred: false), .write(address: 0, value: 1)], result: nil)
        #expect(isKnown(bind(.init(functions: [write], fields: [field])), instruction: 1))
        #expect(!isKnown(bind(.init(functions: [write])), instruction: 1))
    }
    @Test("숫자와 불리언도 컴파일러의 커스텀 리터럴 변환 증거를 무시하지 않는다")
    func scalarConversions() {
        for (name, literal) in [("integerLiteral", ValueFlowLiteral.integer(1)), ("booleanLiteral", .boolean(true)),
                                ("nilLiteral", .null)] {
            let program = ValueFlowProgram(functions: [function("f", operations: [.literal(literal)])])
            let initializer = IndexedSymbol(usr: "convert", name: "init(\(name):)", kind: .initializer,
                module: "P", location: site)
            let snapshot = IndexSnapshot(symbols: [initializer], references: [
                .init(sourceUSR: "f", targetUSR: "convert", kind: .call, location: site)
            ])
            let operation = bind(program, snapshot: snapshot).functions[0].blocks[0].instructions[0].operation
            #expect(operation == .unknown(reason: "contextual-literal-conversion", inputs: [], mayWrite: true))
        }
    }

}
