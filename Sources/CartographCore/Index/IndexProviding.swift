/// 인덱스 스냅샷 공급자.
///
/// 프로덕션에서는 IndexStoreDB 어댑터가, 테스트에서는 메모리 페이크가 구현한다.
/// 이 한 겹 덕분에 도메인과 분석 계층은 IndexStoreDB 를 전혀 알지 못한다.
public protocol IndexProviding: Sendable {
    /// 분석 대상 전체의 스냅샷을 만든다.
    func loadSnapshot() throws -> IndexSnapshot
}

/// 미리 준비된 스냅샷을 그대로 돌려주는 공급자.
///
/// 테스트와, 이미 직렬화된 스냅샷을 재사용하는 경로에서 쓴다.
public struct StaticIndexProvider: IndexProviding {
    private let snapshot: IndexSnapshot

    public init(_ snapshot: IndexSnapshot) {
        self.snapshot = snapshot
    }

    public func loadSnapshot() throws -> IndexSnapshot {
        snapshot
    }
}
