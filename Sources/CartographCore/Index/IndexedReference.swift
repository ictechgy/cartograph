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

    public init(sourceUSR: String, targetUSR: String, kind: EdgeKind, location: SourceLocation? = nil) {
        self.sourceUSR = sourceUSR
        self.targetUSR = targetUSR
        self.kind = kind
        self.location = location
    }
}
