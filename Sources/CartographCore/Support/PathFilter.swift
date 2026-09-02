/// include/exclude 글롭으로 경로를 걸러 내는 필터.
///
/// 규칙은 단순하다.
/// 1. include 가 비어 있지 않으면, 하나라도 일치해야 통과한다.
/// 2. exclude 에 하나라도 일치하면 무조건 탈락한다(exclude 우선).
///
/// 인덱스가 주는 경로는 절대 경로지만 사용자는 `Sources/**` 처럼 프로젝트
/// 기준으로 쓴다. 두 형태를 모두 후보로 보지 않으면 설정이 조용히 아무것도
/// 매칭하지 않고, 결과는 "정점 0개"가 되어 원인을 찾기 어렵다.
public struct PathFilter: Sendable, Equatable {
    public let include: [GlobPattern]
    public let exclude: [GlobPattern]
    /// 상대 경로를 만들 기준 디렉터리.
    public let basePath: String?

    public init(include: [GlobPattern] = [], exclude: [GlobPattern] = [], basePath: String? = nil) {
        self.include = include
        self.exclude = exclude
        self.basePath = basePath
    }

    /// 어떤 경로도 거르지 않는 필터.
    public static let passthrough = PathFilter()

    public func allows(_ path: String) -> Bool {
        let candidates = matchCandidates(for: path)
        if candidates.contains(where: { exclude.matchesAny($0) }) { return false }
        if include.isEmpty { return true }
        return candidates.contains { include.matchesAny($0) }
    }

    /// 절대 경로와, 기준 디렉터리에 대한 상대 경로.
    func matchCandidates(for path: String) -> [String] {
        Self.matchCandidates(for: path, relativeTo: basePath)
    }

    /// 경로 글롭을 적용할 때 시도해야 할 형태들.
    ///
    /// 경로 글롭을 쓰는 곳이 여러 군데라 규칙을 한 곳에 둔다.
    /// 한쪽만 상대 경로를 지원하면 같은 패턴이 설정 위치에 따라 다르게 동작한다.
    public static func matchCandidates(for path: String, relativeTo base: String?) -> [String] {
        guard let base else { return [path] }
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(normalizedBase) else { return [path] }
        return [path, String(path.dropFirst(normalizedBase.count))]
    }
}
