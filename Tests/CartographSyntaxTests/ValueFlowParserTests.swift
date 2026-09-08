import CartographCore
import CartographSyntax
import Testing

@Suite("값 흐름 구문 lowering")
struct ValueFlowParserTests {
    @Test("리터럴 반환은 정확한 위치와 단일 반환 간선을 만든다")
    func literalReturn() throws {
        let program = SwiftValueFlowParser().scan(source: "func answer() -> String { \"origin-A\" }", path: "/p.swift")
        let function = try #require(program.functions.first(where: { $0.name == "answer" }))
        #expect(function.indexName == "answer()")
        #expect(function.blocks.count == 1)
        guard case .return(let value?) = function.blocks[0].terminator else {
            Issue.record("단일 표현식 함수가 값을 반환하지 않았다")
            return
        }
        guard let instruction = function.blocks[0].instructions.first(where: { $0.id == value }) else {
            Issue.record("반환 명령을 찾지 못했다")
            return
        }
        #expect(instruction.operation == .stringLiteral("origin-A", expectedType: "String", inferred: false))
        #expect(instruction.location == SourceLocation(path: "/p.swift", line: 1, column: 27))
    }

    @Test("매개변수는 주소 지역과 읽기로 낮아지고 호출은 심볼과 인자를 보존한다")
    func parameterAndCall() throws {
        let source = "func identity(_ value: String) -> String { value }\nfunc use() -> String { identity(\"x\") }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let identity = try #require(program.functions.first(where: { $0.name == "identity" }))
        #expect(identity.parameters == [
            ValueFlowParameter(name: "value", label: "", isInout: false, isFunction: false, declaredType: "String")
        ])
        #expect(identity.blocks[0].instructions.contains {
            if case .parameter(0) = $0.operation { return true }
            return false
        })
        #expect(identity.blocks[0].instructions.contains {
            if case .local(name: "value", initial: _, mutable: false) = $0.operation { return true }
            return false
        })
        let use = try #require(program.functions.first(where: { $0.name == "use" }))
        #expect(use.blocks.flatMap(\.instructions).contains {
            if case .call(_, let arguments, let labels, false) = $0.operation {
                return arguments.count == 1 && labels == [""]
            }
            return false
        })
    }

    @Test("문자열 리터럴은 반환·명시 타입·추론·호출 인자 문맥을 구분한다")
    func stringLiteralContexts() throws {
        let source = """
            func returned() -> String { "return-value" }
            func direct(_ value: String) -> String { value }
            func locals() -> String {
                let inferred = "inferred"
                let typed: String = "typed"
                return typed
            }
            """
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let returned = try #require(program.functions.first(where: { $0.name == "returned" }))
        #expect(returned.returnType == "String")
        #expect(returned.blocks.flatMap(\.instructions).contains {
            if case .stringLiteral("return-value", "String", false) = $0.operation { return true }
            return false
        })
        let locals = try #require(program.functions.first(where: { $0.name == "locals" }))
        #expect(locals.blocks.flatMap(\.instructions).contains {
            if case .stringLiteral("inferred", nil, true) = $0.operation { return true }
            return false
        })
        #expect(locals.blocks.flatMap(\.instructions).contains {
            if case .stringLiteral("typed", "String", false) = $0.operation { return true }
            return false
        })
        let direct = try #require(program.functions.first(where: { $0.name == "direct" }))
        #expect(direct.parameters[0].declaredType == "String")
    }

    @Test("inout 대입은 읽기 없이 주소와 쓰기를 만든다")
    func inoutWrite() throws {
        let source = "func overwrite(_ value: inout String) { value = \"origin-A\" }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let function = try #require(program.functions.first)
        #expect(function.parameters[0].isInout)
        #expect(function.blocks.flatMap(\.instructions).contains {
            if case .write(_, let value) = $0.operation {
                return function.blocks.flatMap(\.instructions).contains { $0.id == value }
            }
            return false
        })
        #expect(!function.blocks.flatMap(\.instructions).contains {
            if case .read = $0.operation { return true }
            return false
        })
    }

    @Test("연산자의 리터럴 피연산자는 잘못된 inout 주소 오류를 만들지 않는다")
    func operatorLiteralOperands() {
        let program = SwiftValueFlowParser().scan(source: "func f(_ x: Int) -> Int { x - 1 }", path: "/p/F.swift")
        #expect(!program.functions.flatMap(\.blocks).flatMap(\.instructions).contains {
            if case .unknown("inout address unavailable", _, _) = $0.operation { return true }
            return false
        })
    }

    @Test("class 멤버의 동적 디스패치를 static 함수로 확정하지 않는다")
    func dynamicClassMembers() {
        let program = SwiftValueFlowParser().scan(source: """
            class Base {
                class func name() -> String { "base" }
                class var label: String { "base" }
                static func fixed() -> String { "fixed" }
            }
            """, path: "/p/F.swift")
        #expect(program.functions.first { $0.name == "name" }?.unavailableReason != nil)
        #expect(program.functions.first { $0.name == "label" }?.unavailableReason != nil)
        #expect(program.functions.first { $0.name == "fixed" }?.unavailableReason == nil)
    }

    @Test("연산자는 값을 확정하지 않고 입력을 unknown으로 남긴다")
    func unknownOperator() throws {
        let program = SwiftValueFlowParser().scan(source: "func compare(_ x: Int) -> Bool { x == 0 }", path: "/p.swift")
        let function = try #require(program.functions.first)
        #expect(function.blocks.flatMap(\.instructions).contains {
            if case .operatorApplication(_, let inputs) = $0.operation {
                return inputs.count == 2
            }
            return false
        })
    }

    @Test("if와 while은 분기·점프 CFG로 표현된다")
    func controlFlow() throws {
        let source = "func choose(_ flag: Bool) -> String { if flag { return \"a\" } else { return \"b\" } }\nfunc loop(_ flag: Bool) { while flag { _ = flag } }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let choose = try #require(program.functions.first(where: { $0.name == "choose" }))
        #expect(choose.blocks.contains { if case .branch = $0.terminator { return true }; return false })
        #expect(choose.blocks.contains { if case .return(.some) = $0.terminator { return true }; return false })
        let loop = try #require(program.functions.first(where: { $0.name == "loop" }))
        #expect(loop.blocks.contains { if case .branch = $0.terminator { return true }; return false })
        #expect(loop.blocks.contains { if case .jump = $0.terminator { return true }; return false })
    }

    @Test("클래스 필드와 명시적 초기화는 타입·필드·수신자를 보존한다")
    func classField() throws {
        let source = "final class Box { var field: String; init(field: String) { self.field = field } }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let type = try #require(program.types.first(where: { $0.name == "Box" }))
        #expect(type.isReferenceType)
        let field = try #require(program.fields.first(where: { $0.name == "field" }))
        #expect(field.ownerType == type.id)
        let initializer = try #require(program.functions.first(where: { $0.kind == .initializer }))
        #expect(initializer.indexName == "init(field:)")
        #expect(initializer.blocks.flatMap(\.instructions).contains {
            if case .member(_, let reference) = $0.operation { return reference.spelling == "field" }
            return false
        })
        #expect(initializer.blocks.flatMap(\.instructions).contains {
            if case .write = $0.operation { return true }
            return false
        })
    }

    @Test("인스턴스 메서드의 bare 필드와 메서드는 implicit self 수신자를 보존한다")
    func implicitReceiver() throws {
        let source = "final class Box { var field: String; func call() -> String { read() }; func read() -> String { field } }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let read = try #require(program.functions.first(where: { $0.name == "read" }))
        #expect(read.blocks.flatMap(\.instructions).contains {
            if case .member(_, let symbol) = $0.operation { return symbol.spelling == "field" }
            return false
        })
        let call = try #require(program.functions.first(where: { $0.name == "call" }))
        #expect(call.blocks.flatMap(\.instructions).contains {
            if case .member(_, let symbol) = $0.operation { return symbol.spelling == "read" }
            return false
        })
    }

    @Test("다른 파일의 extension도 placeholder owner와 implicit self 수신자를 보존한다")
    func externalExtensionOwner() throws {
        let source = "extension ExternalBox { func read() -> String { self.value } }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let type = try #require(program.types.first)
        #expect(type.isExtension)
        let function = try #require(program.functions.first(where: { $0.name == "read" }))
        #expect(function.ownerType == type.id)
        #expect(function.blocks.flatMap(\.instructions).contains {
            if case .receiver = $0.operation { return true }
            return false
        })
    }

    @Test("failable과 convenience initializer는 성공 객체를 확정하지 않는다")
    func unsupportedInitializers() throws {
        let source = "final class Box { convenience init() {} init?() {} }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let initializers = program.functions.filter { $0.kind == .initializer }
        #expect(initializers.contains { $0.unavailableReason == "convenience initializer is unavailable" })
        #expect(initializers.contains { $0.unavailableReason == "failable initializer is unavailable" })
    }

    @Test("빈 struct와 기본값이 있는 불변 struct만 합성 zero-argument initializer를 얻는다")
    func structInitializers() throws {
        let source = """
            struct Empty {}
            struct Immutable { let value = 1 }
            struct Required { let value: Int }
            struct Mutable { var value = 1 }
            final class ReferenceMutable { var value = 1 }
            """
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        for name in ["Empty", "Immutable"] {
            let type = try #require(program.types.first(where: { $0.name == name }))
            #expect(program.functions.contains { $0.kind == .initializer && $0.ownerType == type.id })
        }
        for name in ["Required", "Mutable"] {
            let type = try #require(program.types.first(where: { $0.name == name }))
            #expect(!program.functions.contains { $0.kind == .initializer && $0.ownerType == type.id })
        }
        let reference = try #require(program.types.first(where: { $0.name == "ReferenceMutable" }))
        #expect(program.functions.contains { $0.kind == .initializer && $0.ownerType == reference.id })
    }

    @Test("ternary와 if 표현식은 임시 주소에 분기별 값을 쓰고 merge에서 읽는다")
    func expressionControlFlow() throws {
        let source = """
            func ternary(_ flag: Bool) -> String { flag ? "a" : "b" }
            func conditional(_ flag: Bool) -> String {
                let value = if flag { "a" } else { "b" }
                return value
            }
            """
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        for name in ["ternary", "conditional"] {
            let function = try #require(program.functions.first(where: { $0.name == name }))
            let instructions = function.blocks.flatMap(\.instructions)
            let temporary = try #require(instructions.first {
                if case .local(name: let name, initial: nil, mutable: true) = $0.operation {
                    return name.hasSuffix("expression>")
                }
                return false
            })
            let writes = instructions.filter {
                if case .write(let address, _) = $0.operation { return address == temporary.id }
                return false
            }
            #expect(writes.count == 2)
            #expect(instructions.contains {
                if case .read(let address) = $0.operation { return address == temporary.id }
                return false
            })
            #expect(!instructions.contains {
                if case .unknown(let reason, _, _) = $0.operation { return reason.contains("expression result") || reason == "ternary merge" }
                return false
            })
        }
    }

    @Test("지원하지 않는 구문의 unknown reason은 소스 원문을 포함하지 않는다")
    func unknownReasonDoesNotExposeSource() {
        let source = "func f() { for secretItem in secretCollection { _ = secretItem } }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let reasons = program.functions.flatMap { function in
            function.blocks.flatMap(\.instructions).compactMap { instruction -> String? in
                if case .unknown(let reason, _, _) = instruction.operation { return reason }
                return nil
            }
        }
        #expect(reasons.contains("unsupported statement"))
        #expect(reasons.allSatisfy { !$0.contains("secretItem") && !$0.contains("secretCollection") })
    }

    @Test("지원하지 않는 제어 흐름은 뒤의 return을 정상 경로로 계속 내리지 않는다")
    func unsupportedControlFlowStopsPath() throws {
        let source = "func f(_ value: Int) -> String { switch value { case 0: return \"A\"; default: return \"B\" } }"
        let function = try #require(SwiftValueFlowParser().scan(source: source, path: "/p.swift").functions.first)
        #expect(function.blocks.contains {
            if case .stop(let reason) = $0.terminator { return reason == "unsupported control flow" }
            return false
        })
        #expect(!function.blocks.flatMap(\.instructions).contains {
            if case .literal(.string("B")) = $0.operation { return true }
            return false
        })
    }

    @Test("파싱 오류가 있는 함수는 unavailable reason을 가진다")
    func parseErrorMarksFunctionUnavailable() throws {
        let program = SwiftValueFlowParser().scan(source: "func broken( {", path: "/p.swift")
        let function = try #require(program.functions.first)
        #expect(function.unavailableReason == "function contains parse errors")
        #expect(program.limitations.contains("source contains parse errors; affected code is conservative"))
    }

    @Test("property wrapper가 붙은 getter와 초기화 함수는 효과를 확정하지 않는다")
    func propertyWrapperEffectsAreUnknown() throws {
        let source = "@Wrapper var value: String { get { \"x\" } }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let getter = try #require(program.functions.first(where: { $0.kind == .getter }))
        #expect(getter.unavailableReason == "property effects are unknown")
        let field = try #require(program.fields.first)
        #expect(field.hasUnknownObservers)
    }

    @Test("알 수 없는 타입 속성은 타입 unavailable reason으로 보존된다")
    func unknownTypeAttribute() throws {
        let source = "@Observable final class Model { func read() {} }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let type = try #require(program.types.first)
        #expect(type.unavailableReason == "type has unknown attribute effects")
        let function = try #require(program.functions.first(where: { $0.name == "read" }))
        #expect(function.ownerType == type.id)
    }

    @Test("async 호출은 await 표시를 유지하고 클로저는 synthetic 함수로 분리한다")
    func asyncAndClosure() throws {
        let source = "func value() async -> String { \"x\" }\nfunc use() async -> String { await value() }\nfunc make(_ outer: String) -> () -> String { { outer } }"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let use = try #require(program.functions.first(where: { $0.name == "use" }))
        #expect(use.blocks.flatMap(\.instructions).contains {
            if case .call(_, _, _, true) = $0.operation { return true }
            return false
        })
        let closure = try #require(program.functions.first(where: { $0.kind == .closure }))
        #expect(closure.blocks.flatMap(\.instructions).contains {
            if case .capture(0) = $0.operation { return true }
            return false
        })
        #expect(program.functions.contains { function in
            function.blocks.flatMap(\.instructions).contains {
                if case .closure(let id, let captures) = $0.operation { return id == closure.id && captures.count == 1 }
                return false
            }
        })
    }

    @Test("진입점과 외부 호출 가능성 메타데이터는 선언 속성을 따른다")
    func declarationMetadata() throws {
        let source = "@main struct App { static func main() {} }\npublic func exposed() {}\n@objc func objectiveC() {}\nfunc ordinary() {}"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let main = try #require(program.functions.first(where: { $0.name == "main" }))
        #expect(main.isEntryPoint)
        let exposed = try #require(program.functions.first(where: { $0.name == "exposed" }))
        #expect(exposed.mayBeCalledExternally)
        let objectiveC = try #require(program.functions.first(where: { $0.name == "objectiveC" }))
        #expect(objectiveC.mayBeCalledExternally)
        let ordinary = try #require(program.functions.first(where: { $0.name == "ordinary" }))
        #expect(!ordinary.mayBeCalledExternally)
    }

    @Test("Void 함수와 getter는 반환값 계약에 맞는 terminator를 만든다")
    func voidAndGetterReturns() throws {
        let source = """
            func consume() { "ignored" }
            func produce() -> String { "kept" }
            final class Box {
                var field: String {
                    get { field }
                    set { field = newValue }
                }
            }
            """
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        let consume = try #require(program.functions.first(where: { $0.name == "consume" }))
        #expect(consume.blocks.contains { if case .return(nil) = $0.terminator { return true }; return false })
        let produce = try #require(program.functions.first(where: { $0.name == "produce" }))
        #expect(produce.blocks.contains { if case .return(.some) = $0.terminator { return true }; return false })
        let getter = try #require(program.functions.first(where: { $0.kind == .getter }))
        #expect(getter.blocks.contains { if case .return(.some) = $0.terminator { return true }; return false })
        let setter = try #require(program.functions.first(where: { $0.kind == .setter }))
        #expect(setter.blocks.contains { if case .return(nil) = $0.terminator { return true }; return false })
    }

    @Test("파싱 오류와 조건부 컴파일은 limitation으로 남는다")
    func limitations() {
        let source = "#if DEBUG\nfunc debugOnly() {\n#else\nfunc other() {}\n#endif\nfunc broken( {"
        let program = SwiftValueFlowParser().scan(source: source, path: "/p.swift")
        #expect(program.limitations.contains { $0.contains("conditional compilation") })
        #expect(program.limitations.contains { $0.contains("parse errors") })
    }

    @Test("같은 소스는 ID와 위치가 결정적으로 같다")
    func deterministic() {
        let source = "func f() { let x = 1; _ = x }"
        let parser = SwiftValueFlowParser()
        #expect(parser.scan(source: source, path: "/p.swift").functions == parser.scan(source: source, path: "/p.swift").functions)
    }
}
