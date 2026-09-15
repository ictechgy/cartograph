/// 인덱스에서 읽어 온 심볼 간 관계 하나.
///
/// 방향은 항상 "의존하는 쪽(source) → 의존되는 쪽(target)" 으로 정규화되어 있다.
/// 인덱스 스토어의 관계 역할(childOf/baseOf/calledBy 등)을 이 방향으로 바꾸는
/// 책임은 `CartographIndexStore` 어댑터가 진다.
public struct IndexedReference: Hashable, Sendable, Codable {
    public let sourceUSR: String
    public let targetUSR: String
    public let kind: EdgeKind
    public let location: SourceLocation?
    /// 과거 스냅샷이나 출처를 명시하지 않은 공급자는 unknown으로 남긴다.
    public let origin: ReferenceOrigin

    public init(
        sourceUSR: String, targetUSR: String, kind: EdgeKind,
        location: SourceLocation? = nil, origin: ReferenceOrigin = .unknown
    ) {
        self.sourceUSR = sourceUSR
        self.targetUSR = targetUSR
        self.kind = kind
        self.location = location
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case sourceUSR, targetUSR, kind, location, origin }

    /// 이전 교환 파일에 출처가 없으면 컴파일러 증거라고 추정하지 않는다.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sourceUSR: try values.decode(String.self, forKey: .sourceUSR),
            targetUSR: try values.decode(String.self, forKey: .targetUSR),
            kind: try values.decode(EdgeKind.self, forKey: .kind),
            location: try values.decodeIfPresent(SourceLocation.self, forKey: .location),
            origin: try values.decodeIfPresent(ReferenceOrigin.self, forKey: .origin) ?? .unknown)
    }

    /// 모르는 출처는 키를 생략해 기존 공급자의 출력 계약을 유지한다.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourceUSR, forKey: .sourceUSR)
        try values.encode(targetUSR, forKey: .targetUSR)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(location, forKey: .location)
        if origin != .unknown { try values.encode(origin, forKey: .origin) }
    }
}
