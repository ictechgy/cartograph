/// 모듈 밖에서 소비될 수 있지만 이 코퍼스 안에서는 아무도 사용하지 않는 public protocol.
/// `--retain-public`이 켜지면 요구사항 전체가 함께 보존되어야 한다.
public protocol PublicLibraryContract {
    associatedtype Element
    init(element: Element)
    func render(_ element: Element) -> String
    var count: Int { get }
    subscript(index: Int) -> Element { get }
}

/// public extension의 무표시 멤버가 실제로 public으로 동작하는지 확인할 host.
public struct InheritedAccessHost {
    public init() {}
}

public extension InheritedAccessHost {
    func publicExtensionAPI() -> Int { 1 }
}

// 확장의 기본 접근과 충돌한다는 경고는 의도적이다. 명시적 public은 모듈 밖에서도 보인다.
private extension InheritedAccessHost {
    public func privateDefaultPublicAPI() -> Int { 2 }
}

/// 타입은 만들지만 모듈 밖 API는 호출하지 않아 retain-public의 경계를 검증한다.
public func exerciseInheritedAccessShapes() {
    _ = InheritedAccessHost()
}
