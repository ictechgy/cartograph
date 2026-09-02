/// 인덱스에서 읽어 온 선언 하나.
///
/// 인덱스 스토어와 구문 분석 결과가 합쳐진 형태다.
/// `accessibility` 와 속성 일부는 인덱스에 없으므로 구문 분석이 나중에 채운다.
public struct IndexedSymbol: Hashable, Sendable, Codable {
    /// 컴파일러가 부여한 고유 식별자. 그래프의 1차 키다.
    public let usr: String
    public let name: String
    public let kind: SymbolKind
    public let module: String
    public let location: SourceLocation
    /// 자신을 감싸는 선언의 USR. 타입 레벨 롤업과 멤버 판정에 쓴다.
    public let parentUSR: String?
    /// SDK 등 프로젝트 외부 심볼인지 여부.
    public let isExternal: Bool
    public var accessibility: Accessibility
    public var attributes: Set<SymbolAttribute>

    public init(
        usr: String,
        name: String,
        kind: SymbolKind,
        module: String,
        location: SourceLocation,
        parentUSR: String? = nil,
        isExternal: Bool = false,
        accessibility: Accessibility = .internalLevel,
        attributes: Set<SymbolAttribute> = []
    ) {
        self.usr = usr
        self.name = name
        self.kind = kind
        self.module = module
        self.location = location
        self.parentUSR = parentUSR
        self.isExternal = isExternal
        self.accessibility = accessibility
        self.attributes = attributes
    }

    /// Objective-C 런타임에서 접근 가능한 심볼인지 여부.
    ///
    /// Clang 계열 USR 은 `c:` 로 시작한다. Swift 심볼이라도 `@objc` 로 노출되면
    /// 별도의 Clang USR 이 함께 생성되므로, 이 판정과 `@objc` 속성을 함께 본다.
    public var isObjectiveCAccessible: Bool {
        usr.hasPrefix("c:") || attributes.contains(.objc) || attributes.contains(.objcMembers)
            || attributes.contains(.objcAccessible)
    }
}
