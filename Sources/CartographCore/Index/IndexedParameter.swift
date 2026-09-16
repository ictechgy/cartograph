/// 인덱스에서 읽어 온 함수 파라미터 선언 하나.
///
/// 파라미터는 그래프 정점이 아니다 — 도달 가능한 대상이 아니라 시그니처의
/// 구성 요소이므로 `symbols` 에 넣으면 모든 질의가 잡음을 얻는다. 대신 이
/// 별도 목록에 담아 두고, "본문에서 한 번도 읽히지 않은 입력" 이라는 질의에만 쓴다.
/// `functionUSR` 이 가리키는 선언이 그래프에서 도달 가능할 때만 미사용으로
/// 보고한다 — 죽은 함수의 파라미터는 그 함수의 발견에 이미 덮인다.
public struct IndexedParameter: Hashable, Sendable, Codable {
    /// 컴파일러 USR. 베이스라인 지문의 주체다.
    public let usr: String
    /// 본문 안에서 쓰이는 내부 이름.
    public let name: String
    public let module: String
    public let location: SourceLocation
    /// 이 파라미터를 선언한 함수·이니셜라이저·서브스크립트의 USR.
    public let functionUSR: String
    /// 본문에서 이 이름을 쓰는 참조가 구문 분석에서 확인됐는지 여부.
    ///
    /// 인덱스는 지역 심볼의 참조 발생을 기록하지 않으므로, 사용 여부는 본문의
    /// 구문 근거로 판정한다. `nil` 은 근거가 없다는 뜻이다 — 본문을 스캔하지
    /// 못한 파일(오래된 캐시·읽기 실패)의 파라미터는 모르는 것이므로 보고하지 않는다.
    public let isReferenced: Bool?

    public init(
        usr: String,
        name: String,
        module: String,
        location: SourceLocation,
        functionUSR: String,
        isReferenced: Bool? = nil
    ) {
        self.usr = usr
        self.name = name
        self.module = module
        self.location = location
        self.functionUSR = functionUSR
        self.isReferenced = isReferenced
    }
}
