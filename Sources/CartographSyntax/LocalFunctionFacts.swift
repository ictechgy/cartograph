import CartographCore

/// 인덱스에 빠진 지역 함수와 그 호출을 한 indexed owner 아래에 모은 구문 근거.
public struct LocalFunctionScopeFacts: Codable, Sendable, Equatable {
    /// 지역 함수들을 담은 indexed 함수·메서드의 기본 이름.
    public let ownerName: String
    /// indexed owner 식별자의 물리적 위치.
    public let ownerLocation: SourceLocation
    /// owner 본문에서 찾은 이름 있는 지역 함수들.
    public let functions: [LocalFunctionFacts]
    /// owner 본문과 지역 함수 본문에서 찾은 선언 참조들.
    public let references: [LocalFunctionReferenceFacts]
    /// 지역 함수 이름을 가릴 수 있는 매개변수·패턴·캡처 이름.
    public let blockedNames: Set<String>
    /// 보수적으로 지역 함수 보강을 막아야 하는 구문이 owner 안에 있었는지 여부.
    public let hasUnsupportedSyntax: Bool
    /// owner를 보강하지 못하게 한 가장 구체적인 이유. 예전 캐시는 nil이다.
    public let reason: LocalFunctionSkipReason?

    /// 지역 함수 scope facts를 만든다.
    public init(
        ownerName: String,
        ownerLocation: SourceLocation,
        functions: [LocalFunctionFacts],
        references: [LocalFunctionReferenceFacts],
        blockedNames: Set<String>,
        hasUnsupportedSyntax: Bool,
        reason: LocalFunctionSkipReason? = nil
    ) {
        self.ownerName = ownerName
        self.ownerLocation = ownerLocation
        self.functions = functions
        self.references = references
        self.blockedNames = blockedNames
        self.hasUnsupportedSyntax = hasUnsupportedSyntax
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case ownerName, ownerLocation, functions, references, blockedNames, hasUnsupportedSyntax, reason
    }

    /// 결정적인 캐시 출력을 위해 집합을 정렬해 인코딩한다.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ownerName, forKey: .ownerName)
        try container.encode(ownerLocation, forKey: .ownerLocation)
        try container.encode(functions, forKey: .functions)
        try container.encode(references, forKey: .references)
        try container.encode(blockedNames.sorted(), forKey: .blockedNames)
        try container.encode(hasUnsupportedSyntax, forKey: .hasUnsupportedSyntax)
        try container.encodeIfPresent(reason, forKey: .reason)
    }

    /// 집합으로 저장된 차단 이름을 다시 복원한다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasUnsupportedSyntax = try container.decode(Bool.self, forKey: .hasUnsupportedSyntax)
        let reason = try container.decodeIfPresent(LocalFunctionSkipReason.self, forKey: .reason)
        self.init(
            ownerName: try container.decode(String.self, forKey: .ownerName),
            ownerLocation: try container.decode(SourceLocation.self, forKey: .ownerLocation),
            functions: try container.decode([LocalFunctionFacts].self, forKey: .functions),
            references: try container.decode([LocalFunctionReferenceFacts].self, forKey: .references),
            blockedNames: Set(try container.decode([String].self, forKey: .blockedNames)),
            hasUnsupportedSyntax: hasUnsupportedSyntax || reason != nil,
            reason: reason ?? (hasUnsupportedSyntax ? .unsupportedSyntax : nil)
        )
    }
}

/// 한 indexed owner 안에서 선언된 이름 있는 지역 함수의 구문 사실.
public struct LocalFunctionFacts: Codable, Sendable, Equatable {
    /// 인자 목록을 뺀 함수 이름.
    public let name: String
    /// 인자 라벨을 포함한 인덱스 표기 이름.
    public let indexName: String
    /// 함수 식별자의 물리적 위치.
    public let location: SourceLocation
    /// 가장 가까운 이름 있는 지역 함수의 위치. indexed owner면 nil이다.
    public let parentLocation: SourceLocation?
    /// 이 함수가 선언된 어휘 범위의 시작 위치(반열린 범위).
    public let scopeStart: SourceLocation
    /// 이 함수가 선언된 어휘 범위의 끝 위치(반열린 범위).
    public let scopeEnd: SourceLocation
    /// 이 함수의 구문을 지역 함수 보강에 사용해도 되는지 여부.
    public let isSupported: Bool
    /// 이 지역 함수의 구문 근거를 사용할 수 없는 구체적인 이유. 예전 캐시는 nil이다.
    public let reason: LocalFunctionSkipReason?

    /// 지역 함수 facts를 만든다.
    public init(
        name: String,
        indexName: String,
        location: SourceLocation,
        parentLocation: SourceLocation?,
        scopeStart: SourceLocation,
        scopeEnd: SourceLocation,
        isSupported: Bool,
        reason: LocalFunctionSkipReason? = nil
    ) {
        self.name = name
        self.indexName = indexName
        self.location = location
        self.parentLocation = parentLocation
        self.scopeStart = scopeStart
        self.scopeEnd = scopeEnd
        self.isSupported = isSupported
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case name, indexName, location, parentLocation, scopeStart, scopeEnd, isSupported, reason
    }

    /// 예전 캐시의 `isSupported: false`를 일반적인 미지원 구문 원인으로 복원한다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isSupported = try container.decode(Bool.self, forKey: .isSupported)
        let reason = try container.decodeIfPresent(LocalFunctionSkipReason.self, forKey: .reason)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            indexName: try container.decode(String.self, forKey: .indexName),
            location: try container.decode(SourceLocation.self, forKey: .location),
            parentLocation: try container.decodeIfPresent(SourceLocation.self, forKey: .parentLocation),
            scopeStart: try container.decode(SourceLocation.self, forKey: .scopeStart),
            scopeEnd: try container.decode(SourceLocation.self, forKey: .scopeEnd),
            isSupported: isSupported && reason == nil,
            reason: reason ?? (isSupported ? nil : .unsupportedSyntax)
        )
    }

    /// 선택적인 reason을 포함해 지역 함수 사실을 저장한다.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(indexName, forKey: .indexName)
        try container.encode(location, forKey: .location)
        try container.encodeIfPresent(parentLocation, forKey: .parentLocation)
        try container.encode(scopeStart, forKey: .scopeStart)
        try container.encode(scopeEnd, forKey: .scopeEnd)
        try container.encode(isSupported && reason == nil, forKey: .isSupported)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

/// owner 본문에서 찾은 선언 참조 하나의 구문 사실.
public struct LocalFunctionReferenceFacts: Codable, Sendable, Equatable {
    /// 참조된 기본 이름.
    public let name: String
    /// 참조 토큰의 물리적 위치.
    public let location: SourceLocation
    /// 참조가 들어 있는 가장 가까운 이름 있는 지역 함수의 위치.
    public let localOwner: SourceLocation?
    /// 참조가 호출식의 callee인지 여부.
    public let isCall: Bool
    /// 멤버 접근이 아닌 무자격 참조인지 여부.
    public let isUnqualified: Bool

    /// 지역 함수 참조 facts를 만든다.
    public init(
        name: String,
        location: SourceLocation,
        localOwner: SourceLocation?,
        isCall: Bool,
        isUnqualified: Bool
    ) {
        self.name = name
        self.location = location
        self.localOwner = localOwner
        self.isCall = isCall
        self.isUnqualified = isUnqualified
    }
}
