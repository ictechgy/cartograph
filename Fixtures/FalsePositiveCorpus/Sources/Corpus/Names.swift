/// 백틱 식별자와 실패 가능 이니셜라이저. 인덱스와 구문의 이름 표기가 다르다.
public struct Money {
    public let amount: Int
    public init?(rawValue: String) {
        guard let amount = Int(rawValue) else { return nil }
        self.amount = amount
    }
    public func `default`() -> Int { amount }
}

/// 제네릭 파라미터는 따로 지울 수 있는 선언이 아니다.
public struct Box<Element> {
    public let value: Element
    public init(_ value: Element) { self.value = value }
}

/// 본문 안의 지역 선언이 같은 이름의 멤버 매칭을 가로채면 안 된다.
public struct Screen {
    @MainActor
    @available(macOS 14, *)
    public var scale: Double = 1
    public init() {}
    public func render() -> Double {
        // 같은 이름의 지역 선언. 멤버의 구문 정보를 가로채면 안 된다.
        let scale = 2.0
        return self.scale * scale
    }
}

/// 테스트만 붙잡고 있는 생산 코드.
public func onlyTestsCallThis() -> Int { 7 }
