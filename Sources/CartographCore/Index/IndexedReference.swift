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
    /// 인덱스가 보고한 대상 종류. 그래프에서 제외한 매개변수 같은 대상을 구분할 때 쓴다.
    public let targetKind: SymbolKind?
    /// 과거 스냅샷이나 출처를 명시하지 않은 공급자는 unknown으로 남긴다.
    public let origin: ReferenceOrigin
    /// 구문 보강이 채운 참조 자리. 보강하지 못한 공급자는 unknown으로 남긴다.
    public let position: ReferencePosition

    public init(
        sourceUSR: String, targetUSR: String, kind: EdgeKind,
        location: SourceLocation? = nil, targetKind: SymbolKind? = nil,
        origin: ReferenceOrigin = .unknown, position: ReferencePosition = .unknown
    ) {
        self.sourceUSR = sourceUSR
        self.targetUSR = targetUSR
        self.kind = kind
        self.location = location
        self.targetKind = targetKind
        self.origin = origin
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case sourceUSR, targetUSR, kind, location, targetKind, origin, position
    }

    /// 이전 교환 파일에 출처나 자리가 없으면 추정하지 않는다.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sourceUSR: try values.decode(String.self, forKey: .sourceUSR),
            targetUSR: try values.decode(String.self, forKey: .targetUSR),
            kind: try values.decode(EdgeKind.self, forKey: .kind),
            location: try values.decodeIfPresent(SourceLocation.self, forKey: .location),
            targetKind: try values.decodeIfPresent(SymbolKind.self, forKey: .targetKind),
            origin: try values.decodeIfPresent(ReferenceOrigin.self, forKey: .origin) ?? .unknown,
            position: try values.decodeIfPresent(ReferencePosition.self, forKey: .position) ?? .unknown)
    }

    /// 모르는 출처·자리는 키를 생략해 기존 공급자의 출력 계약을 유지한다.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourceUSR, forKey: .sourceUSR)
        try values.encode(targetUSR, forKey: .targetUSR)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(location, forKey: .location)
        try values.encodeIfPresent(targetKind, forKey: .targetKind)
        if origin != .unknown { try values.encode(origin, forKey: .origin) }
        if position != .unknown { try values.encode(position, forKey: .position) }
    }

    /// 구문 보강이 채운 자리를 갈아 끼운 복사본.
    public func withPosition(_ position: ReferencePosition) -> IndexedReference {
        IndexedReference(
            sourceUSR: sourceUSR, targetUSR: targetUSR, kind: kind, location: location,
            targetKind: targetKind, origin: origin, position: position
        )
    }
}
