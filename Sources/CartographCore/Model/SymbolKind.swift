/// 심볼의 선언 종류.
///
/// Swift 키워드와 충돌하지 않도록 케이스 이름에는 접미사를 붙이고,
/// 직렬화에 쓰이는 rawValue 는 사람이 읽기 좋은 Swift 용어를 유지한다.
public enum SymbolKind: String, Codable, Sendable, CaseIterable {
    case module
    case file
    case classType = "class"
    case structType = "struct"
    case enumType = "enum"
    case protocolType = "protocol"
    case extensionDeclaration = "extension"
    case typeAlias = "typealias"
    case associatedType = "associatedtype"
    case function
    case method
    case initializer = "init"
    case deinitializer = "deinit"
    case subscriptDeclaration = "subscript"
    case property
    case variable
    case enumCase = "case"
    case parameter
    case macro
    case unknown

    /// 자체적으로 이름 공간을 형성하는 타입 선언인지 여부.
    ///
    /// 심볼 그래프를 타입 레벨로 접을 때 "접히는 대상"을 고르는 기준이 된다.
    public var isTypeDeclaration: Bool {
        switch self {
        case .classType, .structType, .enumType, .protocolType, .typeAlias, .associatedType:
            true
        default:
            false
        }
    }

    /// 추상 정도를 판단할 때 추상으로 세는 종류.
    ///
    /// Martin 의 추상도 A 는 원래 추상 클래스/인터페이스 비율이다.
    /// Swift 에는 추상 클래스가 없으므로 프로토콜과 연관타입을 추상으로 본다.
    public var isAbstract: Bool {
        switch self {
        case .protocolType, .associatedType:
            true
        default:
            false
        }
    }

    /// 타입에 소속되어 단독으로는 의미가 약한 멤버 선언인지 여부.
    public var isMember: Bool {
        switch self {
        case .method, .initializer, .deinitializer, .subscriptDeclaration, .property, .enumCase:
            true
        default:
            false
        }
    }
}
