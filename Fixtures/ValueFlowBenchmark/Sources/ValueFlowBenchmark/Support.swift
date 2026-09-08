import Foundation

/// 벤치마크 하네스가 읽을 수 있는 sink 관찰을 출력한다.
func probe(label: String, value: String) {
    print("\(label)=\(value)")
}

func identity(_ value: String) -> String {
    value
}

func literalA() -> String {
    "origin-A"
}

func literalB() -> String {
    "origin-B"
}

func nestedA() -> String {
    literalA()
}

func nestedB() -> String {
    literalB()
}

func discard(_ value: String) -> String {
    _ = value
    return "fixed"
}

func invoke(_ callback: () -> String) -> String {
    callback()
}

func namedCallbackA() -> String {
    "origin-A"
}

func namedCallbackB() -> String {
    "origin-B"
}

func recursive(_ depth: Int) -> String {
    depth == 0 ? "origin-A" : recursive(depth - 1)
}

func asyncValue() async -> String {
    "origin-B"
}

func overwrite(_ value: inout String) {
    value = "origin-A"
}

final class Box {
    var field: String

    init(field: String) {
        self.field = field
    }
}

func overloaded(_ value: String) -> String {
    value
}

func overloaded(_ value: Int) -> String {
    _ = value
    return "origin-B"
}

final class SideEffect {
    private(set) var count = 0

    func returnAfterMutation(_ value: String) -> String {
        count += 1
        return value
    }
}

/// 입력값으로 결과가 결정되지 않는 Foundation API를 호출한다.
func unknownExternalResult(for value: String) -> String {
    let decoded = Data(base64Encoded: value)
    return decoded == nil ? "external-default" : "external-decoded"
}

/// 입력을 가져온 API에 전달한 뒤 고정된 결과를 반환한다.
func externalSideEffectResult(for value: String) -> String {
    NotificationCenter.default.post(
        name: Notification.Name("cartograph-value-flow-side-effect"), object: value)
    return "external-side-effect-default"
}
