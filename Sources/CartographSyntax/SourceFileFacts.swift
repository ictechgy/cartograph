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
}
