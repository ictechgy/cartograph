/// 그래프를 그릴 해상도.
///
/// 값이 클수록 세밀하다. `symbol` 레벨은 정확하지만 대규모 프로젝트에서
/// 정점이 수만 개가 되므로, 시각화 기본값은 `module` 이다.
public enum GraphLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case module
    case file
    case type
    case symbol

    /// 거친 순서대로의 순위. 비교 및 롤업 방향 판단에 쓴다.
    private var rank: Int {
        switch self {
        case .module: 0
        case .file: 1
        case .type: 2
        case .symbol: 3
        }
    }

    public static func < (lhs: GraphLevel, rhs: GraphLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}
