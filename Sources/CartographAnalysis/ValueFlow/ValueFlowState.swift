import CartographCore

/// 동적 실행 객체를 할당 위치로 추상화한다. 반복 할당은 강한 갱신 대상이 아니다.
struct FlowCell: Hashable {
    var value: ValueFlowValue
    var mutable: Bool
    var unique: Bool
    var initialized: Bool
    var definitions: Set<String>?

    func joining(_ other: FlowCell, limit: Int) -> FlowCell {
        FlowCell(value: value.joining(other.value, limit: limit), mutable: mutable || other.mutable,
                 unique: unique && other.unique, initialized: initialized && other.initialized,
                 definitions: (definitions ?? []).union(other.definitions ?? []))
    }
}

/// 블록 진입 상태. 값 레지스터와 메모리를 합치는 규칙을 분리한다.
struct FlowState: Equatable {
    var values: [Int: ValueFlowValue] = [:]
    var memory: [String: FlowCell] = [:]
    var escaped: Set<String> = []

    func joining(_ other: FlowState, limit: Int) -> FlowState {
        var result = self
        for (key, value) in other.values {
            result.values[key] = result.values[key, default: ValueFlowValue()].joining(value, limit: limit)
        }
        for (key, cell) in other.memory {
            result.memory[key] = result.memory[key].map { $0.joining(cell, limit: limit) } ?? cell
        }
        result.escaped.formUnion(other.escaped)
        return result
    }
}

/// 함수 값의 캡처는 별도 테이블에 둬 값 타입 자체에 재귀 객체를 넣지 않는다.
struct FlowClosure: Hashable {
    let function: String
    let captures: [ValueFlowValue]
    let receiver: ValueFlowValue?
}

/// 문맥 캐시 키에는 인자·캡처·관련 메모리가 포함된다. 이름/함수만으로 요약을 재사용하지 않는다.
struct FlowContextKey: Hashable {
    let function: String
    let calls: [String]
    let arguments: [ValueFlowValue]
    let captures: [ValueFlowValue]
    let receiver: ValueFlowValue?
    let memory: [String: FlowCell]
    let escaped: Set<String>
    let repeated: Bool
}

/// 정상 반환과 부수 효과가 아직 bottom이면 호출 뒤의 본문도 평가하지 않는다.
struct FlowSummary: Equatable {
    var mayReturn = false
    var value = ValueFlowValue()
    var memory: [String: FlowCell] = [:]
    var escaped: Set<String> = []

    func joining(_ other: FlowSummary, limit: Int) -> FlowSummary {
        var result = self
        result.mayReturn = mayReturn || other.mayReturn
        result.value = value.joining(other.value, limit: limit)
        for (key, cell) in other.memory {
            result.memory[key] = result.memory[key].map { $0.joining(cell, limit: limit) } ?? cell
        }
        result.escaped.formUnion(other.escaped)
        return result
    }
}

struct FlowContext {
    let id: String
    let key: FlowContextKey
    let callSite: SourceLocation?
    let caller: String?
    let reason: String
    var summary = FlowSummary()
    var inputDefinitions: [String: Set<String>] = [:]
    var nodes: [Int: ValueFlowGraphNode] = [:]
    var edges: Set<ValueFlowGraphEdge> = []
}

struct FlowCallOutcome {
    var mayReturn: Bool
    var value: ValueFlowValue
    var state: FlowState
    var targets: [String] = []
}

/// 계산 접근자와 저장 필드도 같은 주소 인터페이스로 읽고 쓴다.
struct FlowBoundField {
    let field: String
    let receiver: ValueFlowValue?
}
