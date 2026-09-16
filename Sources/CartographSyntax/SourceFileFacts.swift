import CartographCore

/// 구문 분석으로 알아낸 선언 하나의 정보.
///
/// 인덱스 스토어에는 접근 수준과 속성이 기록되지 않는다. 그 공백을 메우는 값이다.
public struct DeclarationFacts: Codable, Sendable, Equatable {
    public let name: String
    public let line: Int
    public let accessibility: Accessibility
    public let attributes: Set<SymbolAttribute>
    /// 보존 근거를 좁힐 때 이름만 비슷한 선언을 신뢰하지 않도록 실제 식별자 위치를 남긴다.
    /// nil인 예전 캐시·수동 사실은 정확한 컴파일러 바인딩의 근거로 쓰지 않는다.
    public let nameLocation: SourceLocation?
    /// 이 선언이나 조상에 분석기가 해석하지 못한 속성이 있었는지 여부.
    /// nil인 예전 캐시·수동 사실은 속성 효과를 알 수 없으므로 보수적으로 취급한다.
    public let hasUnresolvedAttributes: Bool?

    /// 정확한 위치를 주지 않는 기존 생산자는 보수적인 바인딩을 계속 사용한다.
    public init(
        name: String, line: Int, accessibility: Accessibility, attributes: Set<SymbolAttribute>,
        nameLocation: SourceLocation? = nil, hasUnresolvedAttributes: Bool? = nil
    ) {
        self.name = name
        self.line = line
        self.accessibility = accessibility
        self.attributes = attributes
        self.nameLocation = nameLocation
        self.hasUnresolvedAttributes = hasUnresolvedAttributes
    }
}

/// 함수 시그니처 파라미터 하나의 본문 사용 근거.
///
/// 인덱스는 지역 심볼의 참조 발생을 기록하지 않으므로, 파라미터가 본문에서
/// 읽혔는지는 구문 분석으로만 알 수 있다. 인덱스 쪽 파라미터 선언과는
/// `location`(내부 이름 토큰의 위치)으로 조인한다.
public struct ParameterUsageFacts: Codable, Sendable, Equatable {
    /// 본문에서 쓰는 내부 이름(`func f(label x:)` 이면 `x`).
    public let name: String
    /// 내부 이름 토큰의 위치.
    public let location: SourceLocation
    /// 본문(다른 파라미터의 기본값 포함)에서 이 이름의 참조가 보였는지 여부.
    public let isUsedInBody: Bool

    public init(name: String, location: SourceLocation, isUsedInBody: Bool) {
        self.name = name
        self.location = location
        self.isUsedInBody = isUsedInBody
    }
}

/// 소스 파일 하나에서 얻은 구문 정보.
public struct SourceFileFacts: Codable, Sendable, Equatable {
    public let path: String
    public let declarations: [DeclarationFacts]
    /// 파일 첫머리에 `// cartograph:ignore:all` 이 있는지 여부.
    public let ignoresEntireFile: Bool
    /// 같은 구문 트리에서 찾은 런타임 경계. nil은 예전 캐시처럼 아직 스캔하지 않은 결과다.
    public let runtimeFacts: RuntimeFileFacts?
    /// 컴파일러가 생략한 지역 함수의 구문 근거. nil은 아직 수집하지 않은 캐시다.
    public let localFunctionScopes: [LocalFunctionScopeFacts]?
    /// 본문 있는 함수의 파라미터 사용 근거. nil은 아직 수집하지 않은 캐시다.
    /// nil일 때는 파라미터의 사용 여부를 모르는 것이므로 미사용으로 보고하지 않는다.
    public let parameterUsages: [ParameterUsageFacts]?
    /// 파일의 `import` 선언 목록. nil은 아직 수집하지 않은 캐시다.
    /// nil일 때는 그 파일의 import를 판정할 수 없으므로 보고하지 않는다.
    public let imports: [IndexedImport]?

    public init(
        path: String,
        declarations: [DeclarationFacts],
        ignoresEntireFile: Bool = false,
        runtimeFacts: RuntimeFileFacts? = nil,
        localFunctionScopes: [LocalFunctionScopeFacts]? = nil,
        parameterUsages: [ParameterUsageFacts]? = nil,
        imports: [IndexedImport]? = nil
    ) {
        self.path = path
        self.declarations = declarations
        self.ignoresEntireFile = ignoresEntireFile
        self.runtimeFacts = runtimeFacts
        self.localFunctionScopes = localFunctionScopes
        self.parameterUsages = parameterUsages
        self.imports = imports
    }

    /// 줄 번호로 선언을 찾는다.
    public func declaration(atLine line: Int) -> DeclarationFacts? {
        declarations.first { $0.line == line }
    }

    /// 이름으로 선언을 찾는다. 줄 번호가 어긋날 때의 대비책이다.
    public func declaration(named name: String) -> DeclarationFacts? {
        declarations.first { $0.name == name }
    }

    /// 인덱스 심볼에 대응하는 선언을 찾는다.
    ///
    /// 줄 번호만으로 찾으면 두 가지가 어긋난다. 한 줄에 선언이 여럿이면 엉뚱한
    /// 선언의 정보가 붙고, `@discardableResult` 처럼 속성이 윗줄에 있으면
    /// 구문 쪽 줄 번호(속성 줄)와 인덱스 쪽 줄 번호(이름 줄)가 달라 아예 못 찾는다.
    /// 잘못 붙는 쪽이 더 위험하다. 실제로 쓰이는 public 선언이 미사용으로
    /// 보고될 수 있기 때문이다.
    ///
    /// 그래서 이름 일치를 먼저 요구하고, 같은 이름이 여럿이면(오버로드, 여러 타입의
    /// 동명 메서드) 줄 번호가 가장 가까운 것을 고른다.
    ///
    /// 이름 정규화는 `GraphNode.baseName(ofIndexName:)` 의 규칙 하나를 쓴다.
    /// 실패 가능 이니셜라이저는 인덱스에서 `init?(rawValue:)` 로 온다. 물음표를
    /// 떼지 않으면 구문 쪽 `init` 과 영영 만나지 못해, public 이니셜라이저가
    /// internal 로 분석되어 미사용으로 보고된다.
    public func declaration(matchingIndexName indexName: String, nearLine line: Int) -> DeclarationFacts? {
        let base = GraphNode.baseName(ofIndexName: indexName)
        guard !base.isEmpty else { return nil }
        return declarations
            .filter { $0.name == base }
            .min { lhs, rhs in
                let lhsDistance = abs(lhs.line - line)
                let rhsDistance = abs(rhs.line - line)
                return lhsDistance == rhsDistance ? lhs.line < rhs.line : lhsDistance < rhsDistance
            }
    }
}
