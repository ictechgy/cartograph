import CartographCore

/// 서로 다른 호출 문맥에서도 같은 문자열인 표현식만 소스 수준 브리지 사실에 적용한다.
public struct ValueFlowBridgeConstants: Sendable {
    /// I/O 없이 값 그래프에서 소스 수준 상수 후보를 고른다.
    public init() {}

    /// 예산이 잘린 실행이나 일부 문맥이 미상인 위치는 상수로 승격하지 않는다.
    public func resolve(in graph: ValueFlowGraph) -> [SourceLocation: String] {
        guard !graph.truncated else { return [:] }
        let eligible: Set<String> = ["literal", "read", "call", "copy"]
        var last: [String: [SourceLocation: ValueFlowGraphNode]] = [:]
        for node in graph.nodes where eligible.contains(node.kind) {
            if let prior = last[node.context]?[node.location], prior.instruction >= node.instruction { continue }
            last[node.context, default: [:]][node.location] = node
        }
        var values: [SourceLocation: ValueFlowValue] = [:]
        for context in last.keys.sorted() {
            for (location, node) in last[context, default: [:]] {
                values[location] = values[location, default: ValueFlowValue()].joining(node.value, limit: 32)
            }
        }
        return values.compactMapValues { value in
            guard let name = value.singleString else { return nil }
            // Swift String 동등성은 정규화 형태를 합치지만 채널 이름의 UTF-8은 달라질 수 있다.
            let agrees = value.origins.allSatisfy { origin in
                guard case let .string(original)? = origin.literal else { return true }
                return original.utf8.elementsEqual(name.utf8)
            }
            return agrees ? name : nil
        }
    }
}
