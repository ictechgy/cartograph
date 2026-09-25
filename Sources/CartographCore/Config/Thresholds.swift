/// CI 에서 실패로 처리할 임계값.
///
/// 모든 값이 선택 사항이며, 지정하지 않은 항목은 검사하지 않는다.
/// 브라운필드 프로젝트는 베이스라인으로 현재 상태를 고정한 뒤
/// 임계값을 조금씩 조여 가는 방식을 권한다.
public struct Thresholds: Sendable, Codable, Equatable {
    /// 허용할 순환 의존성 최대 개수.
    public var maxCycles: Int?
    /// 허용할 미사용 심볼 최대 개수.
    public var maxUnusedSymbols: Int?
    /// 허용할 레이어 규칙 위반 최대 개수.
    public var maxRuleViolations: Int?
    /// 허용할 최대 불안정도 I(0...1). 초과 모듈이 있으면 실패한다.
    public var maxInstability: Double?
    /// 허용할 주계열로부터의 최대 거리 D(0...1).
    public var maxDistanceFromMainSequence: Double?
    /// 정점 하나가 의존해도 되는 서로 다른 정점의 최대 개수 Ce.
    ///
    /// 불안정도 I 는 비율이라 의존 대상이 3개인 모듈과 30개인 모듈을 같은 1.0 으로 본다.
    /// 여러 계층에 손을 뻗는 "만능" 모듈을 잡으려면 절대 개수의 상한이 필요하다.
    public var maxEfferentCoupling: Int?

    public init(
        maxCycles: Int? = nil,
        maxUnusedSymbols: Int? = nil,
        maxRuleViolations: Int? = nil,
        maxInstability: Double? = nil,
        maxDistanceFromMainSequence: Double? = nil,
        maxEfferentCoupling: Int? = nil
    ) {
        self.maxCycles = maxCycles
        self.maxUnusedSymbols = maxUnusedSymbols
        self.maxRuleViolations = maxRuleViolations
        self.maxInstability = maxInstability
        self.maxDistanceFromMainSequence = maxDistanceFromMainSequence
        self.maxEfferentCoupling = maxEfferentCoupling
    }

    /// 아무 임계값도 검사하지 않는 설정.
    ///
    /// `none` 으로 두면 호출부에서 `Optional.none` 과 헷갈린다.
    public static let disabled = Thresholds()

    private enum CodingKeys: String, CodingKey {
        case maxCycles = "max_cycles"
        case maxUnusedSymbols = "max_unused_symbols"
        case maxRuleViolations = "max_rule_violations"
        case maxInstability = "max_instability"
        case maxDistanceFromMainSequence = "max_distance"
        case maxEfferentCoupling = "max_efferent_coupling"
    }
}
