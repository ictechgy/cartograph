import CartographCore

/// 조회 성공 여부와 무관하게 미분석 지역 함수의 위치·원인과 생략 개수를 제공한다.
public struct LocalFunctionDiagnostics: Codable, Sendable, Equatable {
    public let items: [LocalFunctionDiagnostic]
    public let totalCount: Int
    public let omittedCount: Int

    /// 세션 안의 모든 질의가 같은 한계 목록을 재사용한다. 알릴 항목이 없으면 키를 생략한다.
    static func presenting(_ diagnostics: [LocalFunctionDiagnostic]) -> Self? {
        guard !diagnostics.isEmpty else { return nil }
        let ordered = diagnostics.sorted {
            if $0.location != $1.location { return $0.location < $1.location }
            return ($0.ownerUSR ?? "", $0.name, $0.reason.rawValue)
                < ($1.ownerUSR ?? "", $1.name, $1.reason.rawValue)
        }
        let shown = Array(ordered.prefix(50))
        return Self(items: shown, totalCount: ordered.count, omittedCount: ordered.count - shown.count)
    }
}
