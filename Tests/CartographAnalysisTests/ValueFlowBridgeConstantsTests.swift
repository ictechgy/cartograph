import CartographCore
import CartographAnalysis
import Testing

@Suite("호출 문맥에서 브리지 상수 승격")
struct ValueFlowBridgeConstantsTests {
    private let location = SourceLocation(path: "/p/Bridge.swift", line: 7, column: 4)

    private func node(_ id: Int, context: String = "c0", kind: String = "call", value: ValueFlowValue)
        -> ValueFlowGraphNode {
        ValueFlowGraphNode(id: "\(context):n\(id)", context: context, function: "f", instruction: id,
            kind: kind, location: location, value: value)
    }

    private func graph(_ nodes: [ValueFlowGraphNode], truncated: Bool = false) -> ValueFlowGraph {
        ValueFlowGraph(contexts: [], nodes: nodes, edges: [], limitations: [], iterations: 1, truncated: truncated)
    }

    private func string(_ value: String) -> ValueFlowValue { .init(atoms: [.literal(.string(value))]) }

    @Test("같은 위치의 함수 참조 대신 호출 결과를 읽는다")
    func resultOfExpression() {
        let input = graph([node(0, kind: "symbol", value: .unknown("function")),
                           node(1, kind: "read", value: .unknown("callee")), node(2, value: string("channel"))])
        #expect(ValueFlowBridgeConstants().resolve(in: input)[location] == "channel")
    }

    @Test("다른 호출에 다른 이름이나 미상 인자가 있으면 소스 상수로 승격하지 않는다")
    func multipleContexts() {
        let known = node(1, value: string("A"))
        let other = node(1, context: "c1", value: string("B"))
        let unknown = node(1, context: "c2", value: .unknown("entry-parameter"))
        #expect(ValueFlowBridgeConstants().resolve(in: graph([known, other])).isEmpty)
        #expect(ValueFlowBridgeConstants().resolve(in: graph([known, unknown])).isEmpty)
        #expect(ValueFlowBridgeConstants().resolve(in: graph([known,
            node(1, context: "c1", value: string("A"))]))[location] == "A")
    }

    @Test("분석 예산이 잘렸거나 문자열이 아니면 이름을 만들지 않는다")
    func incomplete() {
        #expect(ValueFlowBridgeConstants().resolve(in: graph([node(1, value: string("A"))], truncated: true)).isEmpty)
        #expect(ValueFlowBridgeConstants().resolve(in: graph([node(1, value: .init(atoms: [.literal(.integer(1))]))])).isEmpty)
    }
    @Test("Swift에서 동등해도 바이트가 다른 채널 이름은 하나로 확정하지 않는다")
    func normalizationDoesNotMergeChannels() {
        let first = ValueFlowValue(atoms: [.literal(.string("é"))], origins: [
            .init(id: "first", location: location, literal: .string("é"))])
        let second = ValueFlowValue(atoms: [.literal(.string("e\u{301}"))], origins: [
            .init(id: "second", location: location, literal: .string("e\u{301}"))])
        let joined = first.joining(second, limit: 32)
        #expect(joined.singleString != nil)
        #expect(ValueFlowBridgeConstants().resolve(in: graph([node(1, value: joined)])).isEmpty)
    }

}
