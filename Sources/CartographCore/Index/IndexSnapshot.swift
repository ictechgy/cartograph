/// 한 번의 분석에 사용할 인덱스 전체 스냅샷.
///
/// 인덱스 스토어를 열어 두고 질의하는 대신 한 번에 읽어 값 타입으로 고정한다.
/// 덕분에 이후 모든 분석 단계가 순수 함수가 되고, 테스트에서는
/// 인덱스 스토어 없이 스냅샷을 직접 만들어 넣을 수 있다.
public struct IndexSnapshot: Sendable, Codable, Equatable {
    public var symbols: [IndexedSymbol]
    public var references: [IndexedReference]

    public init(symbols: [IndexedSymbol] = [], references: [IndexedReference] = []) {
        self.symbols = symbols
        self.references = references
    }

    /// USR 로 심볼을 찾기 위한 사전. 반복 조회가 많아 미리 만들어 쓴다.
    public func symbolsByUSR() -> [String: IndexedSymbol] {
        Dictionary(symbols.map { ($0.usr, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 등장하는 모듈 이름 목록(정렬됨).
    public var moduleNames: [String] {
        Set(symbols.map(\.module)).sorted()
    }

    /// 등장하는 소스 파일 경로 목록(정렬됨).
    public var filePaths: [String] {
        Set(symbols.map(\.location.path)).sorted()
    }

    /// 두 스냅샷을 합친다. 인덱스 스토어와 구문 분석 결과를 합칠 때 쓴다.
    public func merging(_ other: IndexSnapshot) -> IndexSnapshot {
        IndexSnapshot(symbols: symbols + other.symbols, references: references + other.references)
    }
}
