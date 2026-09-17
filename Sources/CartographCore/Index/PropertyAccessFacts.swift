/// 프로퍼티·변수 심볼 하나에 기록된 접근 방향의 합산.
///
/// "대입은 되지만 한 번도 읽히지 않는" 선언을 찾기 위한 근거다. 인덱스가 각
/// 참조 발생에 남기는 read/write 역할을 USR 단위로 접은 것이다. 방향을 알 수
/// 없는 접근(동적 디스패치, 주소 접근, 암시적 발생)은 따로 모은다 — 그것이
/// 하나라도 있으면 "읽힌 적 없다"고 확신할 수 없기 때문이다.
public struct PropertyAccessFacts: Codable, Sendable, Equatable {
    /// 읽기 역할이 붙은 참조가 하나 이상 있다.
    public var hasRead: Bool
    /// 쓰기 역할이 붙은 참조가 하나 이상 있다.
    ///
    /// 멤버와이즈 이니셜라이저의 인자 라벨처럼 방향 없이 기록된 대입 자리도
    /// 여기 센다 — 값이 그 자리로 들어가는 것은 쓰기다.
    public var hasWrite: Bool
    /// 방향을 판별할 수 없는 참조가 하나 이상 있다.
    public var hasAmbiguous: Bool

    public init(hasRead: Bool = false, hasWrite: Bool = false, hasAmbiguous: Bool = false) {
        self.hasRead = hasRead
        self.hasWrite = hasWrite
        self.hasAmbiguous = hasAmbiguous
    }

    /// 대입은 확인되지만 읽기가 없고 불명한 접근도 없을 때만 참.
    public var isAssignOnly: Bool {
        hasWrite && !hasRead && !hasAmbiguous
    }

    /// 다른 출처의 근거를 합친다. 어느 쪽에서든 관측된 접근은 관측된 것이다.
    public mutating func merge(_ other: PropertyAccessFacts) {
        hasRead = hasRead || other.hasRead
        hasWrite = hasWrite || other.hasWrite
        hasAmbiguous = hasAmbiguous || other.hasAmbiguous
    }
}
