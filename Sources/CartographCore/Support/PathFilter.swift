/// include/exclude 글롭으로 경로를 걸러 내는 필터.
///
/// 규칙은 단순하다.
/// 1. include 가 비어 있지 않으면, 하나라도 일치해야 통과한다.
/// 2. exclude 에 하나라도 일치하면 무조건 탈락한다(exclude 우선).
public struct PathFilter: Sendable, Equatable {
    public let include: [GlobPattern]
    public let exclude: [GlobPattern]

    public init(include: [GlobPattern] = [], exclude: [GlobPattern] = []) {
        self.include = include
        self.exclude = exclude
    }

    /// 어떤 경로도 거르지 않는 필터.
    public static let passthrough = PathFilter()

    public func allows(_ path: String) -> Bool {
        if exclude.matchesAny(path) { return false }
        if include.isEmpty { return true }
        return include.matchesAny(path)
    }
}
