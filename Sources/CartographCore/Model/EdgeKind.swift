/// 두 정점 사이 관계의 종류.
///
/// 방향은 언제나 "의존하는 쪽 → 의존되는 쪽" 이다.
/// 즉 `Derived → Base`, `Caller → Callee`, `Extension → ExtendedType` 이다.
public enum EdgeKind: String, Codable, Sendable, CaseIterable, Comparable {
    /// 함수/메서드 호출.
    case call
    /// 타입 언급, 프로퍼티 접근 등 호출이 아닌 일반 참조.
    case reference
    /// 클래스 상속.
    case inheritance
    /// 프로토콜 준수.
    case conformance
    /// 익스텐션이 확장하는 타입.
    case extends
    /// 오버라이드가 가리키는 상위 선언.
    case overrides
    /// 부모 선언이 자식 선언을 포함하는 관계.
    case member
    /// `import` 선언.
    case importDeclaration = "import"
    /// 보존 규칙이 만들어 낸 합성 간선. 근거는 `RetentionReason` 이 따로 보관한다.
    case retention

    /// 이 간선이 "출발점이 도착점을 실제로 사용한다"는 의미인지 여부.
    ///
    /// 도달 가능성(데드코드) 분석은 이 값이 참인 간선만 따라간다.
    /// `member` 는 포함 관계일 뿐이므로, 타입이 살아 있다고 해서 모든 멤버가
    /// 자동으로 살아 있다고 보지 않는다. 이는 Periphery 가 "사용되지 않는 타입의
    /// 자손은 따로 보고하지 않는다"고 처리한 지점과 같은 문제를 다룬다.
    public var impliesUsage: Bool {
        self != .member
    }

    /// 순환 의존성 판정에 포함할 간선인지 여부.
    ///
    /// 포함 관계와 합성 보존 간선은 설계상의 순환이 아니므로 제외한다.
    public var participatesInCycles: Bool {
        switch self {
        case .member, .retention:
            false
        default:
            true
        }
    }

    private var rank: Int {
        EdgeKind.allCases.firstIndex(of: self) ?? 0
    }

    public static func < (lhs: EdgeKind, rhs: EdgeKind) -> Bool {
        lhs.rank < rhs.rank
    }
}
