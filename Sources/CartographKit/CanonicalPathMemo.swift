import CartographCore

/// 같은 경로를 쓰는 자리마다 다시 정규화하지 않도록 경로별 실제 경로를 한 번만 계산해 둔다.
///
/// `LocalFileSystem.canonicalPath` 는 경로 구성 요소마다 파일 시스템을 거친다. 고유 경로는 파일 수만큼인데
/// 심볼·참조 위치와 신선도 키는 발생 수만큼이라, 자리마다 부르면 같은 시스템 호출을 수십~수백 배 되풀이한다.
/// 한 번의 계산 안에서만 쓴다. 오래 들고 있으면 그사이 바뀐 링크를 놓친다.
struct CanonicalPathMemo {
    private let resolve: (String) -> String
    private var resolved: [String: String] = [:]

    /// - Parameter resolve: 경로 하나의 정규화. 부르는 쪽이 같은 규칙을 넘겨 정규화 횟수를 셀 수 있게 한다.
    init(resolve: @escaping (String) -> String = LocalFileSystem.canonicalPath) {
        self.resolve = resolve
    }

    /// 처음 보는 경로만 정규화하고, 본 적 있는 경로는 기억한 값을 돌려준다.
    mutating func path(_ raw: String) -> String {
        if let known = resolved[raw] { return known }
        let path = resolve(raw)
        resolved[raw] = path
        return path
    }
}
