// Alamofire의 잠금 확장과 Argument Parser의 제네릭 확장에서 인덱스의 dynamic 역할이
// 명시적 dynamic 제어자로 오인되던 형태를 호출되는 쪽과 호출되지 않는 쪽으로 고정한다.
protocol StaticExtensionProtocol {
    func requiredValue() -> Int
}

struct StaticExtensionImplementation: StaticExtensionProtocol {
    func requiredValue() -> Int { 1 }
}

extension StaticExtensionProtocol {
    func liveProtocolExtensionHelper() -> Int { requiredValue() }
    func unusedProtocolExtensionHelper() -> Int { 2 }
}

extension Sequence {
    func liveSequenceExtensionHelper() -> Int { reduce(0) { count, _ in count + 1 } }
    func unusedSequenceExtensionHelper() -> Int { 3 }
}

class ExplicitDynamicHost {
    dynamic func lateBound() -> Int { 4 }
}

extension ExplicitDynamicHost {
    @_dynamicReplacement(for: lateBound())
    func replacementLateBound() -> Int { 5 }
}

/// 실제 호출과 요구사항 구현은 유지하고 명시적인 런타임 치환도 보호한다.
public func exerciseStaticExtensionDispatchShapes() {
    _ = StaticExtensionImplementation().liveProtocolExtensionHelper()
    _ = [1, 2].liveSequenceExtensionHelper()
    _ = ExplicitDynamicHost()
}
