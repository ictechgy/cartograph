/// 그래프의 정점 하나.
///
/// 정점은 레벨에 따라 심볼·타입·파일·모듈 어느 것이든 될 수 있으므로,
/// 심볼 전용 정보(`usr`, `accessibility`)는 선택 값이거나 기본값을 가진다.
public struct GraphNode: Hashable, Sendable, Codable, Identifiable {
    public let id: NodeID
    /// 사람이 읽는 이름. 모듈은 모듈명, 파일은 파일명, 심볼은 선언 이름이다.
    public let name: String
    public let kind: SymbolKind
    /// 이 정점이 속한 모듈. 모듈 정점 자신도 자기 이름을 가진다.
    public let module: String?
    /// 심볼 레벨에서의 USR. 베이스라인 키로도 쓰인다.
    public let usr: String?
    public let location: SourceLocation?
    public let accessibility: Accessibility
    public let attributes: Set<SymbolAttribute>
    /// SDK 등 프로젝트 외부에서 온 정점인지 여부.
    public let isExternal: Bool

    public init(
        id: NodeID,
        name: String,
        kind: SymbolKind,
        module: String? = nil,
        usr: String? = nil,
        location: SourceLocation? = nil,
        accessibility: Accessibility = .internalLevel,
        attributes: Set<SymbolAttribute> = [],
        isExternal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.module = module
        self.usr = usr
        self.location = location
        self.accessibility = accessibility
        self.attributes = attributes
        self.isExternal = isExternal
    }

    /// 인자 목록을 뗀 이름.
    ///
    /// 인덱스는 함수 이름을 `main()`, `describe(_:)` 처럼 인자 라벨까지 붙여 준다.
    /// 이름으로 규칙을 거는 쪽에서는 그 꼬리가 늘 걸림돌이 된다.
    public var baseName: String {
        guard let parenthesis = name.firstIndex(of: "(") else { return name }
        return String(name[name.startIndex..<parenthesis])
    }

    /// 리포트에 표시할 한 줄 이름. 모듈이 있으면 `Module.Name` 형태가 된다.
    public var qualifiedName: String {
        guard let module, kind != .module, !module.isEmpty else { return name }
        return "\(module).\(name)"
    }
}

extension GraphNode {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, module, usr, location, accessibility, attributes, isExternal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(NodeID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(SymbolKind.self, forKey: .kind),
            module: try container.decodeIfPresent(String.self, forKey: .module),
            usr: try container.decodeIfPresent(String.self, forKey: .usr),
            location: try container.decodeIfPresent(SourceLocation.self, forKey: .location),
            accessibility: try container.decodeIfPresent(Accessibility.self, forKey: .accessibility)
                ?? .internalLevel,
            attributes: Set(try container.decodeIfPresent([SymbolAttribute].self, forKey: .attributes) ?? []),
            isExternal: try container.decodeIfPresent(Bool.self, forKey: .isExternal) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(module, forKey: .module)
        try container.encodeIfPresent(usr, forKey: .usr)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encode(accessibility, forKey: .accessibility)
        try container.encode(attributes.sorted { $0.rawValue < $1.rawValue }, forKey: .attributes)
        try container.encode(isExternal, forKey: .isExternal)
    }
}
