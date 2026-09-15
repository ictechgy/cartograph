/// 지역 함수 구문 보강이 특정 함수를 인덱스에 연결하지 못한 이유.
///
/// 이 값은 보강 자체를 실패로 만들지 않는다. 원래 컴파일러 투영을 보존한 채
/// 어느 구문 근거를 더 확인해야 하는지 호출자에게 알려 주는 진단이다.
public enum LocalFunctionSkipReason: String, Codable, Sendable, CaseIterable {
    /// 소스 파일이 인덱스보다 새로워 구문 근거를 사용할 수 없음.
    case sourceNotFresh
    /// 인덱스의 파일 시각을 알 수 없음.
    case indexDateUnavailable
    /// 소스 파일의 수정 시각을 알 수 없음.
    case sourceDateUnavailable
    /// 구문이 지역 함수 보강이 지원하는 형태가 아님.
    case unsupportedSyntax
    /// 조건부 컴파일 블록 안의 구문.
    case conditionalCompilation
    /// 매크로 확장 안의 구문.
    case macroExpansion
    /// 해석하지 못한 사용자 속성.
    case unknownAttributes
    /// 지역 타입 선언이 포함된 owner.
    case localType
    /// `#sourceLocation` 으로 소스 위치가 다시 매핑된 owner.
    case sourceLocationRemapping
    /// SwiftSyntax 파서가 오류를 보고한 owner.
    case parseError
    /// 정확한 위치에 indexed owner가 하나로 정해지지 않음.
    case ambiguousOwner
    /// 같은 이름의 지역 함수가 여럿임.
    case ambiguousName
    /// 매개변수·패턴·캡처가 지역 함수 이름을 가림.
    case shadowedName
    /// indexed owner에서 지역 함수로 이어지는 호출·참조 사슬이 없음.
    case noEntryChain
    /// 한 소스 위치에 서로 충돌하는 indexed reference가 있음.
    case conflictingIndexReference
    /// 현재 그래프 필터가 지역 함수 보강에 필요한 간선을 제외함.
    case filteredEdgeKinds
    /// 같은 위치에 이미 indexed declaration이 있음.
    case existingDeclaration

    /// 사용자가 다음에 취할 수 있는 조치.
    public var action: String {
        switch self {
        case .sourceNotFresh:
            "Rebuild the index after source changes before analyzing again."
        case .indexDateUnavailable:
            "Rebuild the index with per-file dates available, then analyze again."
        case .sourceDateUnavailable:
            "Check source timestamp availability and rebuild the index before analyzing again."
        case .unsupportedSyntax:
            "Inspect the local function and its enclosing declaration in source."
        case .conditionalCompilation:
            "Inspect the conditional branches and the configuration used to build the index."
        case .macroExpansion:
            "Inspect the macro expansion and its enclosing source declaration."
        case .unknownAttributes:
            "Inspect the attributed declaration and its generated behavior manually."
        case .localType:
            "Inspect the local type and its generated behavior manually."
        case .sourceLocationRemapping:
            "Inspect the source locations and #sourceLocation remapping manually."
        case .parseError:
            "Fix the source parse error and rebuild before analyzing again."
        case .ambiguousOwner:
            "Inspect the indexed enclosing owner and exact source location manually."
        case .ambiguousName:
            "Inspect the local function names and indexed enclosing owner manually."
        case .shadowedName:
            "Inspect the shadowing parameter, capture, or local binding manually."
        case .noEntryChain:
            "Inspect the lexical scope and indexed enclosing owner for a missing entry chain."
        case .conflictingIndexReference:
            "Inspect conflicting index references at the source location and rebuild."
        case .filteredEdgeKinds:
            "Include call, reference, and member edges in the analysis."
        case .existingDeclaration:
            "Inspect the existing declaration and refresh the index."
        }
    }

    /// 여러 원인이 겹칠 때 더 구체적인 원인을 먼저 고르는 순서.
    public var priority: Int {
        switch self {
        case .parseError: 0
        case .sourceLocationRemapping: 1
        case .conditionalCompilation: 2
        case .macroExpansion: 3
        case .localType: 4
        case .unknownAttributes: 5
        case .unsupportedSyntax: 6
        case .sourceNotFresh: 7
        case .indexDateUnavailable: 8
        case .sourceDateUnavailable: 9
        case .filteredEdgeKinds: 10
        case .ambiguousOwner: 11
        case .ambiguousName: 12
        case .shadowedName: 13
        case .conflictingIndexReference: 14
        case .existingDeclaration: 15
        case .noEntryChain: 16
        }
    }

    /// 원인 선택을 분석기 밖에 두어 결과 값 타입이 분석기로 역참조하지 않게 한다.
    public static func preferred(_ lhs: Self?, _ rhs: Self?) -> Self? {
        switch (lhs, rhs) {
        case let (left?, right?):
            return left.priority == right.priority
                ? (left.rawValue < right.rawValue ? left : right)
                : (left.priority < right.priority ? left : right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }
}

/// 지역 함수 하나를 원래 인덱스 투영에 남긴 이유와 다음 조치를 설명한다.
public struct LocalFunctionDiagnostic: Codable, Sendable, Equatable {
    /// 지역 함수의 인덱스 이름(인자 라벨 포함).
    public let name: String
    /// 지역 함수 식별자의 물리적 위치.
    public let location: SourceLocation
    /// 지역 함수를 담은 indexed owner의 기본 이름.
    public let ownerName: String
    /// indexed owner USR. owner가 모호하면 nil일 수 있다.
    public let ownerUSR: String?
    /// 지역 함수가 보강되지 않은 이유.
    public let reason: LocalFunctionSkipReason
    /// 이유에 맞춰 계산한 사람용 다음 조치.
    public let action: String

    /// 지역 함수 진단을 만든다.
    /// 조치는 reason에서만 계산해 직렬화 결과가 어긋나지 않게 한다.
    public init(
        name: String,
        location: SourceLocation,
        ownerName: String,
        ownerUSR: String? = nil,
        reason: LocalFunctionSkipReason
    ) {
        self.name = name
        self.location = location
        self.ownerName = ownerName
        self.ownerUSR = ownerUSR
        self.reason = reason
        self.action = reason.action
    }

    private enum CodingKeys: String, CodingKey {
        case name, location, ownerName, ownerUSR, reason, action
    }

    /// 조치를 다시 계산해 캐시에 저장된 오래된 문구를 신뢰하지 않는다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            location: try container.decode(SourceLocation.self, forKey: .location),
            ownerName: try container.decode(String.self, forKey: .ownerName),
            ownerUSR: try container.decodeIfPresent(String.self, forKey: .ownerUSR),
            reason: try container.decode(LocalFunctionSkipReason.self, forKey: .reason)
        )
    }

    /// action을 포함해 공개 진단 형식을 안정적으로 저장한다.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(location, forKey: .location)
        try container.encode(ownerName, forKey: .ownerName)
        try container.encodeIfPresent(ownerUSR, forKey: .ownerUSR)
        try container.encode(reason, forKey: .reason)
        try container.encode(action, forKey: .action)
    }
}
