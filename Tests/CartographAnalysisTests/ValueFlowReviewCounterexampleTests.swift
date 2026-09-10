import CartographCore
@testable import CartographAnalysis
import Testing

@Suite("값 흐름 부수 효과 회귀")
struct ValueFlowReviewCounterexampleTests {
    private let site = SourceLocation(path: "/p/Test.swift", line: 1, column: 1)

    private func ins(_ operations: [ValueFlowOperation]) -> [ValueFlowInstruction] {
        operations.enumerated().map { ValueFlowInstruction(id: $0.offset, operation: $0.element, location: site) }
    }

    private func fn(_ id: String, parameters: [ValueFlowParameter] = [], operations: [ValueFlowOperation],
                    result: Int? = nil, entry: Bool = false, external: Bool = false,
                    kind: ValueFlowFunction.Kind = .function, owner: String? = nil,
                    terminator: ValueFlowTerminator? = nil) -> ValueFlowFunction {
        ValueFlowFunction(id: id, symbolUSR: id, name: id, indexName: id + "()", location: site,
            kind: kind, parameters: parameters,
            blocks: [ValueFlowBlock(id: 0, instructions: ins(operations), terminator: terminator ?? .return(result))],
            ownerType: owner, isEntryPoint: entry, mayBeCalledExternally: external)
    }

    private func symbol(_ usr: String) -> ValueFlowOperation {
        .symbol(ValueFlowSymbolReference(location: site, spelling: usr, usr: usr))
    }

    @Test("외부로 노출된 메모리는 알려진 함수 경계를 넘어 보존된다")
    func escapedState() {
        let callback = fn("callback", operations: [
            .capture(0), .literal(.string("callback-change")), .write(address: 0, value: 1)
        ], kind: .closure)
        let helper = fn("helper", operations: [symbol("external-tick"),
            .call(callee: 0, arguments: [], argumentLabels: [], isAwait: false)])
        let main = fn("main", operations: [
            .literal(.string("before")), .local(name: "value", initial: 0, mutable: true),
            .closure(function: "callback", captures: [1]), symbol("external-sink"),
            .call(callee: 3, arguments: [2], argumentLabels: [""], isAwait: false),
            .literal(.string("reset")), .write(address: 1, value: 5), symbol("helper"),
            .call(callee: 7, arguments: [], argumentLabels: [], isAwait: false), .read(address: 1)
        ], result: 9, entry: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [main, helper, callback]))
        #expect(graph.contexts.first { $0.function == "main" }?.result.isUnknown == true)
    }

    @Test("미지원 본문은 접근 가능한 가변 메모리를 무효화한다")
    func stoppedBody() {
        let stopped = fn("stopped", parameters: [.init(name: "value", isInout: true)],
                         operations: [.parameter(0)], terminator: .stop(reason: "unsupported-body"))
        let main = fn("main", operations: [
            .literal(.string("before")), .local(name: "value", initial: 0, mutable: true), symbol("stopped"),
            .call(callee: 2, arguments: [1], argumentLabels: [""], isAwait: false), .read(address: 1)
        ], result: 4, entry: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [main, stopped]))
        #expect(graph.contexts.first { $0.function == "main" }?.result.isUnknown == true)
    }

    @Test("외부 진입점은 전역 상태를 최초 값으로 가정하지 않는다")
    func externalRoots() {
        let initializer = fn("global-init", operations: [.literal(.string("default"))], result: 0)
        let field = ValueFlowField(id: "global", symbolUSR: "global", name: "global", location: site,
                                   isMutable: true, initializer: "global-init")
        let setter = fn("setter", operations: [symbol("global"), .literal(.string("changed")),
            .write(address: 0, value: 1)], external: true)
        let getter = fn("getter", operations: [symbol("global"), .read(address: 0)], result: 1, external: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [initializer, setter, getter], fields: [field]))
        #expect(graph.contexts.first { $0.function == "getter" }?.result.isUnknown == true)
    }

    @Test("미지원 값 타입 생성자도 inout 부수 효과를 무효화한다")
    func mutableValueInitializer() {
        let field = ValueFlowField(id: "field", symbolUSR: "field", name: "field", location: site,
                                   ownerType: "S", isMutable: true)
        let type = ValueFlowType(id: "S", symbolUSR: "S", name: "S", location: site)
        let initializer = fn("init", parameters: [.init(name: "value", isInout: true)], operations: [
            .parameter(0), .literal(.string("changed")), .write(address: 0, value: 1)
        ], kind: .initializer, owner: "S")
        let main = fn("main", operations: [
            .literal(.string("before")), .local(name: "value", initial: 0, mutable: true), symbol("init"),
            .call(callee: 2, arguments: [1], argumentLabels: [""], isAwait: false), .read(address: 1)
        ], result: 4, entry: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [main, initializer], fields: [field], types: [type]))
        #expect(graph.contexts.first { $0.function == "main" }?.result.isUnknown == true)
    }

    @Test("약한 갱신은 가능한 모든 쓰기 간선을 유지한다")
    func weakUpdateOrigins() {
        let blocks = [
            ValueFlowBlock(id: 0, instructions: [
                .init(id: 0, operation: .literal(.string("A")), location: site),
                .init(id: 1, operation: .local(name: "x", initial: 0, mutable: true), location: site),
                .init(id: 2, operation: .literal(.string("B")), location: site),
                .init(id: 3, operation: .local(name: "y", initial: 2, mutable: true), location: site),
                .init(id: 4, operation: .local(name: "selected", initial: 1, mutable: true), location: site),
                .init(id: 5, operation: .unknown(reason: "condition", inputs: [], mayWrite: false), location: site),
            ], terminator: .branch(condition: 5, then: 1, otherwise: 2)),
            ValueFlowBlock(id: 1, terminator: .jump(3)),
            ValueFlowBlock(id: 2, instructions: [
                .init(id: 6, operation: .write(address: 4, value: 3), location: site)
            ], terminator: .jump(3)),
            ValueFlowBlock(id: 3, instructions: [
                .init(id: 7, operation: .read(address: 4), location: site),
                .init(id: 8, operation: .literal(.string("C")), location: site),
                .init(id: 9, operation: .write(address: 7, value: 8), location: site),
                .init(id: 10, operation: .read(address: 1), location: site),
            ], terminator: .return(10)),
        ]
        let main = ValueFlowFunction(id: "main", symbolUSR: "main", name: "main", indexName: "main()",
            location: site, blocks: blocks, isEntryPoint: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [main]))
        let loadSources = Set(graph.edges.filter { $0.target == "c0:n10" && $0.kind == "load" }.map(\.source))
        #expect(loadSources == ["c0:n-3", "c0:n-11"])
    }

    @Test("인자 불일치도 수신 객체를 무효화한다")
    func mismatchReceiver() {
        let field = ValueFlowField(id: "field", symbolUSR: "field", name: "field", location: site,
                                   ownerType: "Box", isMutable: true)
        let type = ValueFlowType(id: "Box", symbolUSR: "Box", name: "Box", location: site,
                                 isReferenceType: true)
        let fieldRef = ValueFlowSymbolReference(location: site, spelling: "field", usr: "field")
        let methodRef = ValueFlowSymbolReference(location: site, spelling: "mutate", usr: "mutate")
        let initializer = fn("init", operations: [
            .receiver, .member(base: 0, symbol: fieldRef), .literal(.string("before")),
            .write(address: 1, value: 2)
        ], kind: .initializer, owner: "Box")
        let method = fn("mutate", parameters: [.init(name: "defaulted")], operations: [], owner: "Box")
        let main = fn("main", operations: [
            symbol("init"), .call(callee: 0, arguments: [], argumentLabels: [], isAwait: false),
            .member(base: 1, symbol: methodRef),
            .call(callee: 2, arguments: [], argumentLabels: [], isAwait: false),
            .member(base: 1, symbol: fieldRef), .read(address: 4)
        ], result: 5, entry: true)
        let graph = ValueFlowAnalyzer().analyze(
            .init(functions: [main, initializer, method], fields: [field], types: [type]))
        #expect(graph.contexts.first { $0.function == "main" }?.result.isUnknown == true)
    }
    @Test("피호출자의 분기 합류가 호출자와 분기 쓰기 간선을 모두 유지한다")
    func calleeBranchDefinitions() {
        let callee = ValueFlowFunction(id: "callee", symbolUSR: "callee", name: "callee", indexName: "callee()",
            location: site, parameters: [.init(name: "value", isInout: true)], blocks: [
                ValueFlowBlock(id: 0, instructions: [
                    .init(id: 0, operation: .parameter(0), location: site),
                    .init(id: 1, operation: .unknown(reason: "condition", inputs: [], mayWrite: false), location: site),
                ], terminator: .branch(condition: 1, then: 1, otherwise: 2)),
                ValueFlowBlock(id: 1, instructions: [
                    .init(id: 2, operation: .literal(.string("B")), location: site),
                    .init(id: 3, operation: .write(address: 0, value: 2), location: site),
                ], terminator: .jump(3)),
                ValueFlowBlock(id: 2, terminator: .jump(3)),
                ValueFlowBlock(id: 3, instructions: [
                    .init(id: 4, operation: .read(address: 0), location: site),
                ], terminator: .return(4)),
            ])
        let main = fn("main", operations: [
            .literal(.string("A")), .local(name: "x", initial: 0, mutable: true), symbol("callee"),
            .call(callee: 2, arguments: [1], argumentLabels: [""], isAwait: false)
        ], result: 3, entry: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [main, callee]))
        let calleeContext = try! #require(graph.contexts.first { $0.function == "callee" })
        let sources = Set(graph.edges.filter { $0.target == "\(calleeContext.id):n4" && $0.kind == "load" }.map(\.source))
        #expect(sources == ["c0:n-3", "\(calleeContext.id):n-5"])
    }

    @Test("반복 상한 초과로 자를 때 허상 간선을 남기지 않는다")
    func danglingBudgetEdges() {
        let identity = fn("identity", parameters: [.init(name: "value")], operations: [.parameter(0)], result: 0)
        let main = fn("main", operations: [.literal(.string("A")), symbol("identity"),
            .call(callee: 1, arguments: [0], argumentLabels: [""], isAwait: false)], result: 2, entry: true)
        let graph = ValueFlowAnalyzer(limits: .init(iterations: 5)).analyze(.init(functions: [main, identity]))
        let nodeIDs = Set(graph.nodes.map(\.id))
        #expect(graph.truncated)
        #expect(graph.edges.allSatisfy { nodeIDs.contains($0.source) && nodeIDs.contains($0.target) })
    }
    @Test("호출 요약에 inout 변경 전후와 모든 호출자를 기록한다")
    func summaryEffects() throws {
        let setter = fn("setter", parameters: [.init(name: "value", isInout: true)], operations: [
            .parameter(0), .literal(.string("after")), .write(address: 0, value: 1)
        ])
        let main = fn("main", operations: [
            .literal(.string("before")), .local(name: "value", initial: 0, mutable: true), symbol("setter"),
            .call(callee: 2, arguments: [1], argumentLabels: [""], isAwait: false), .read(address: 1)
        ], result: 4, entry: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [main, setter]))
        let context = try #require(graph.contexts.first { $0.function == "setter" })
        #expect(context.callers == ["c0"])
        let effect = try #require(context.effects.first)
        #expect(effect.before?.singleString == "before")
        #expect(effect.after.singleString == "after")
        #expect(!effect.escaped)
    }

    @Test("외부 진입에서도 부수 효과 없는 불변 리터럴 초기화는 유지한다")
    func immutableExternalGlobal() {
        let initializer = fn("global-init", operations: [.literal(.string("fixed"))], result: 0)
        let field = ValueFlowField(id: "global", symbolUSR: "global", name: "global", location: site,
                                   isMutable: false, initializer: "global-init")
        let getter = fn("getter", operations: [symbol("global"), .read(address: 0)], result: 1, external: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [initializer, getter], fields: [field]))
        #expect(graph.contexts.first { $0.function == "getter" }?.result.singleString == "fixed")
    }

    @Test("미확인 연산자는 피연산자를 변경하지만 다른 지역 저장소를 바꾸지 않는다")
    func operatorEffects() {
        let main = fn("main", operations: [
            .literal(.string("operand")), .local(name: "left", initial: 0, mutable: true),
            .literal(.string("kept")), .local(name: "unrelated", initial: 2, mutable: true),
            .literal(.integer(1)), .operatorApplication("+=", inputs: [1, 4]),
            .read(address: 1), .read(address: 3)
        ], result: 7, entry: true)
        let graph = ValueFlowAnalyzer().analyze(.init(functions: [main]))
        #expect(graph.nodes.first { $0.instruction == 6 }?.value.isUnknown == true)
        #expect(graph.contexts.first?.result.singleString == "kept")
        #expect(graph.contexts.first?.effects.isEmpty == true)
    }

    @Test("재귀 연산의 스칼라 지역 주소가 외부 힙으로 누적되지 않는다")
    func recursiveOperatorBudget() {
        let recursive = ValueFlowFunction(id: "recursive", symbolUSR: "recursive", name: "recursive", indexName: "recursive(_:)",
            location: site, parameters: [.init(name: "depth")], blocks: [
                .init(id: 0, instructions: ins([.parameter(0), .local(name: "depth", initial: 0, mutable: false),
                    .literal(.integer(0)), .operatorApplication("==", inputs: [1, 2])]),
                    terminator: .branch(condition: 3, then: 1, otherwise: 2)),
                .init(id: 1, instructions: [.init(id: 4, operation: .literal(.string("A")), location: site)], terminator: .return(4)),
                .init(id: 2, instructions: [
                    .init(id: 5, operation: .literal(.integer(1)), location: site),
                    .init(id: 6, operation: .operatorApplication("-", inputs: [1, 5]), location: site),
                    .init(id: 7, operation: symbol("recursive"), location: site),
                    .init(id: 8, operation: .call(callee: 7, arguments: [6], argumentLabels: [""], isAwait: false), location: site)
                ], terminator: .return(8))
            ])
        let main = fn("main", operations: [symbol("recursive"), .literal(.integer(2)),
            .call(callee: 0, arguments: [1], argumentLabels: [""], isAwait: false)], result: 2, entry: true)
        let graph = ValueFlowAnalyzer(limits: .init(contexts: 12, iterations: 1000)).analyze(.init(functions: [main, recursive]))
        #expect(!graph.truncated)
        #expect(graph.contexts.first { $0.function == "main" }?.result.singleString == "A")
    }

}
