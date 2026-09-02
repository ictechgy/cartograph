/// Swift 접근 수준.
///
/// 인덱스 스토어에는 접근 수준이 기록되지 않으므로 구문 분석(`CartographSyntax`)으로
/// 채워 넣는다. 확인하지 못한 심볼은 Swift 기본값인 `internalLevel` 로 둔다.
public enum Accessibility: String, Codable, Sendable, CaseIterable, Comparable {
    case openLevel = "open"
    case publicLevel = "public"
    case packageLevel = "package"
    case internalLevel = "internal"
    case fileprivateLevel = "fileprivate"
    case privateLevel = "private"

    /// 넓은 순서대로의 순위. 값이 작을수록 더 넓게 노출된다.
    private var rank: Int {
        switch self {
        case .openLevel: 0
        case .publicLevel: 1
        case .packageLevel: 2
        case .internalLevel: 3
        case .fileprivateLevel: 4
        case .privateLevel: 5
        }
    }

    /// 모듈 밖에서 접근 가능한 수준인지 여부. `--retain-public` 판단에 쓴다.
    public var isExposedOutsideModule: Bool {
        self == .openLevel || self == .publicLevel
    }

    /// 더 넓게 노출되는 쪽이 "작다"고 본다. 상속 시 최대 노출 수준 계산에 유용하다.
    public static func < (lhs: Accessibility, rhs: Accessibility) -> Bool {
        lhs.rank < rhs.rank
    }

    /// 구문에서 읽은 접근 제어자 문자열을 매핑한다. 알 수 없으면 nil.
    public init?(modifierName: String) {
        switch modifierName {
        case "open": self = .openLevel
        case "public": self = .publicLevel
        case "package": self = .packageLevel
        case "internal": self = .internalLevel
        case "fileprivate": self = .fileprivateLevel
        case "private": self = .privateLevel
        default: return nil
        }
    }
}
