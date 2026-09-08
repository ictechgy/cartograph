import CartographCore
@testable import CartographAnalysis
import Foundation
import Testing

@Suite("함수 간 값 흐름")
struct ValueFlowAnalyzerTests {
    private func instructions(_ function: String, _ operations: [ValueFlowOperation]) -> [ValueFlowInstruction] {
        operations.enumerated().map { index, operation in
            ValueFlowInstruction(id: index, operation: operation,
                                 location: SourceLocation(path: "/p/\(function).swift", line: index + 1, column: 1))
        }
    }

    private func function(_ id: String, parameters: [ValueFlowParameter] = [], operations: [ValueFlowOperation],
                          result: Int? = nil, entry: Bool = false, kind: ValueFlowFunction.Kind = .function,
                          owner: String? = nil) -> ValueFlowFunction {
        ValueFlowFunction(id: id, symbolUSR: id, name: id, indexName: id + "()",
            location: SourceLocation(path: "/p/\(id).swift", line: 1, column: 1), kind: kind,
            parameters: parameters, blocks: [ValueFlowBlock(id: 0,
                instructions: instructions(id, operations), terminator: .return(result))],
            ownerType: owner, isEntryPoint: entry)
    }

    private func symbol(_ usr: String) -> ValueFlowOperation {
        .symbol(ValueFlowSymbolReference(location: SourceLocation(path: "/p/main.swift", line: 1, column: 1),
                                         spelling: usr, usr: usr))
    }

    private func graph(_ functions: [ValueFlowFunction], fields: [ValueFlowField] = [], types: [ValueFlowType] = [],
                       limits: ValueFlowLimits = ValueFlowLimits()) -> ValueFlowGraph {
        ValueFlowAnalyzer(limits: limits).analyze(ValueFlowProgram(functions: functions, fields: fields, types: types))
    }

    @Test("서로 다른 identity 호출의 인자와 반환이 섞이지 않는다")
    func callSiteIsolation() {
        let identity = function("identity", parameters: [.init(name: "value")], operations: [.parameter(0)], result: 0)
        let main = function("main", operations: [
            .literal(.string("A")), symbol("identity"),
            .call(callee: 1, arguments: [0], argumentLabels: [""], isAwait: false),
            .literal(.string("B")), .call(callee: 1, arguments: [3], argumentLabels: [""], isAwait: false)
        ], result: 4, entry: true)
        let result = graph([main, identity])
        let calls = result.contexts.filter { $0.function == "identity" }
        #expect(calls.count == 2)
        #expect(Set(calls.compactMap { $0.result.singleString }) == ["A", "B"])
        #expect(calls.allSatisfy { $0.arguments.first?.singleString == $0.result.singleString })
        #expect(result.edges.contains { $0.kind == "argument-to-parameter" })
        #expect(result.edges.contains { $0.kind == "return-to-call" })
        #expect(!result.truncated)
    }

    @Test("입력을 버리는 함수는 같은 문자열이어도 입력의 출처를 반환에 섞지 않는다")
    func discardingInputChangesProvenance() {
        let discard = function("discard", parameters: [.init(name: "ignored")], operations: [
            .parameter(0), .literal(.string("same"))
        ], result: 1)
        let main = function("main", operations: [.literal(.string("same")), symbol("discard"),
            .call(callee: 1, arguments: [0], argumentLabels: [""], isAwait: false)], result: 2, entry: true)
        let result = graph([main, discard])
        let returned = result.contexts.first { $0.function == "main" }?.result
        #expect(returned?.singleString == "same")
        #expect(returned?.origins.map(\.id) == ["discard:literal:1"])
    }

    @Test("이름으로 넘긴 콜백을 실제 함수 값으로 호출한다")
    func callbackInvocation() {
        let callback = function("callback", operations: [.literal(.string("callback-value"))], result: 0)
        let invoke = function("invoke", parameters: [.init(name: "callback", isFunction: true)], operations: [
            .parameter(0), .call(callee: 0, arguments: [], argumentLabels: [], isAwait: false)
        ], result: 1)
        let main = function("main", operations: [symbol("invoke"), symbol("callback"),
            .call(callee: 0, arguments: [1], argumentLabels: [""], isAwait: false)], result: 2, entry: true)
        let result = graph([main, invoke, callback])
        #expect(result.contexts.first { $0.function == "main" }?.result.singleString == "callback-value")
    }

    @Test("클로저의 가변 캡처는 생성 당시 값이 아니라 같은 저장소를 읽는다")
    func capturedStorage() {
        let callback = function("callback", operations: [.capture(0), .read(address: 0)], result: 1, kind: .closure)
        let main = function("main", operations: [
            .literal(.string("before")), .local(name: "value", initial: 0, mutable: true),
            .closure(function: "callback", captures: [1]), .literal(.string("after")),
            .write(address: 1, value: 3), .call(callee: 2, arguments: [], argumentLabels: [], isAwait: false)
        ], result: 5, entry: true)
        let result = graph([main, callback])
        #expect(result.contexts.first { $0.function == "main" }?.result.singleString == "after")
    }

    @Test("inout 요약의 쓰기를 호출자 메모리에 적용한다")
    func inoutEffects() {
        let overwrite = function("overwrite", parameters: [.init(name: "value", isInout: true)], operations: [
            .parameter(0), .literal(.string("changed")), .write(address: 0, value: 1)
        ])
        let main = function("main", operations: [
            .literal(.string("before")), .local(name: "value", initial: 0, mutable: true), symbol("overwrite"),
            .call(callee: 2, arguments: [1], argumentLabels: [""], isAwait: false), .read(address: 1)
        ], result: 4, entry: true)
        let result = graph([main, overwrite])
        #expect(result.contexts.first { $0.function == "main" }?.result.singleString == "changed")
    }

    @Test("재귀 요약은 바닥 반환에서 고정점에 도달하며 Swift 스택을 재귀 호출하지 않는다")
    func recursiveSummary() {
        let recurse = ValueFlowFunction(id: "recurse", symbolUSR: "recurse", name: "recurse", indexName: "recurse()",
            location: SourceLocation(path: "/p/recurse.swift", line: 1, column: 1), blocks: [
                ValueFlowBlock(id: 0, instructions: instructions("recurse", [
                    .unknown(reason: "unknown-condition", inputs: [], mayWrite: false)
                ]), terminator: .branch(condition: 0, then: 1, otherwise: 2)),
                ValueFlowBlock(id: 1, instructions: [ValueFlowInstruction(id: 1,
                    operation: .literal(.string("base")), location: .init(path: "/p/recurse.swift", line: 2, column: 1))],
                    terminator: .return(1)),
                ValueFlowBlock(id: 2, instructions: [
                    ValueFlowInstruction(id: 2, operation: symbol("recurse"),
                                         location: .init(path: "/p/recurse.swift", line: 3, column: 1)),
                    ValueFlowInstruction(id: 3, operation: .call(callee: 2, arguments: [], argumentLabels: [], isAwait: false),
                                         location: .init(path: "/p/recurse.swift", line: 4, column: 1))
                ], terminator: .return(3))
            ])
        let main = function("main", operations: [symbol("recurse"),
            .call(callee: 0, arguments: [], argumentLabels: [], isAwait: false)], result: 1, entry: true)
        let result = graph([main, recurse])
        #expect(result.contexts.first { $0.function == "main" }?.result.singleString == "base")
        #expect(!result.truncated)
        #expect(result.iterations < 200)
    }

    @Test("서로 다른 객체의 필드와 호출 문맥이 합쳐지지 않는다")
    func objectIdentity() {
        let site = SourceLocation(path: "/p/Box.swift", line: 1, column: 1)
        let field = ValueFlowField(id: "field", symbolUSR: "field", name: "field", location: site,
                                   ownerType: "Box", isMutable: true)
        let box = ValueFlowType(id: "Box", symbolUSR: "Box", name: "Box", location: site,
                                isReferenceType: true, isFinal: true)
        let reference = ValueFlowSymbolReference(location: site, spelling: "field", usr: "field")
        let initializer = function("init", parameters: [.init(name: "value")], operations: [
            .receiver, .parameter(0), .member(base: 0, symbol: reference), .write(address: 2, value: 1)
        ], kind: .initializer, owner: "Box")
        let main = function("main", operations: [
            symbol("init"), .literal(.string("A")),
            .call(callee: 0, arguments: [1], argumentLabels: [""], isAwait: false),
            .call(callee: 0, arguments: [1], argumentLabels: [""], isAwait: false),
            .member(base: 2, symbol: reference), .literal(.string("B")), .write(address: 4, value: 5),
            .member(base: 3, symbol: reference), .read(address: 7)
        ], result: 8, entry: true)
        let result = graph([main, initializer], fields: [field], types: [box])
        #expect(result.contexts.first { $0.function == "main" }?.result.singleString == "A")
    }

    @Test("미해석 호출에 넘긴 가변 저장소는 처음 값으로 확정하지 않는다")
    func unknownCallEffects() {
        let main = function("main", operations: [
            .literal(.string("before")), .local(name: "value", initial: 0, mutable: true), symbol("external"),
            .call(callee: 2, arguments: [1], argumentLabels: [""], isAwait: false), .read(address: 1)
        ], result: 4, entry: true)
        let result = graph([main])
        #expect(result.contexts.first { $0.function == "main" }?.result.isUnknown == true)
        #expect(result.limitations.contains("unknown-call"))
    }

    @Test("분석 예산 초과는 정상 완료나 빈 값으로 위장하지 않는다")
    func budgetIsExplicit() {
        let identity = function("identity", parameters: [.init(name: "value")], operations: [.parameter(0)], result: 0)
        let main = function("main", operations: [.literal(.string("A")), symbol("identity"),
            .call(callee: 1, arguments: [0], argumentLabels: [""], isAwait: false)], result: 2, entry: true)
        let result = graph([main, identity], limits: .init(contexts: 1))
        #expect(result.truncated)
        #expect(result.contexts.first?.result.isUnknown == true)
        #expect(result.limitations.contains("context-budget"))
    }

    @Test("같은 입력의 문맥과 집합 JSON 순서는 매번 같다")
    func deterministicOutput() throws {
        let main = function("main", operations: [.literal(.string("A"))], result: 0, entry: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(graph([main]))
        let second = try encoder.encode(graph([main]))
        #expect(first == second)
    }
}
