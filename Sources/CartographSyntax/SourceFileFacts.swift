import CartographCore

/// 구문 분석으로 알아낸 선언 하나의 정보.
///
/// 인덱스 스토어에는 접근 수준과 속성이 기록되지 않는다. 그 공백을 메우는 값이다.
public struct DeclarationFacts: Sendable, Equatable {
    public let name: String
    public let line: Int
    public let accessibility: Accessibility
    public let attributes: Set<SymbolAttribute>

    public init(name: String, line: Int, accessibility: Accessibility, attributes: Set<SymbolAttribute>) {
        self.name = name
        self.line = line
        self.accessibility = accessibility
        self.attributes = attributes
    }
}

/// 소스 파일 하나에서 얻은 구문 정보.
public struct SourceFileFacts: Sendable, Equatable {
    public let path: String
    public let declarations: [DeclarationFacts]
    /// 파일 첫머리에 `// cartograph:ignore:all` 이 있는지 여부.
    public let ignoresEntireFile: Bool

    public init(path: String, declarations: [DeclarationFacts], ignoresEntireFile: Bool = false) {
        self.path = path
        self.declarations = declarations
        self.ignoresEntireFile = ignoresEntireFile
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
    public func declaration(matchingIndexName indexName: String, nearLine line: Int) -> DeclarationFacts? {
        let base = Self.baseName(ofIndexName: indexName)
        guard !base.isEmpty else { return nil }
        return declarations
            .filter { $0.name == base }
            .min { lhs, rhs in
                let lhsDistance = abs(lhs.line - line)
                let rhsDistance = abs(rhs.line - line)
                return lhsDistance == rhsDistance ? lhs.line < rhs.line : lhsDistance < rhsDistance
            }
    }

    /// 인덱스가 붙이는 인자 라벨을 떼어 낸 이름.
    ///
    /// 인덱스는 `emit(_:options:)`, `init(from:)`, `found(_:)` 처럼 인자 라벨까지
    /// 이름에 넣는다. 구문 분석은 `emit`, `init`, `found` 만 안다. 괄호 앞만 보면
    /// 두 이름을 맞출 수 있다.
    public static func baseName(ofIndexName indexName: String) -> String {
        String(indexName.prefix { $0 != "(" })
    }
}
