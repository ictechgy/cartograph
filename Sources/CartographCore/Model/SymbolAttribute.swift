/// 보존(retention) 판단에 필요한 심볼 표식.
///
/// Periphery 가 34개 뮤테이터로 처리하던 "이건 안 쓰는 것처럼 보여도 지우면 안 된다"는
/// 지식을 데이터로 환원한 것이다. 인덱스 스토어에서 얻는 것(`implicit`, `unitTest`,
/// `interfaceBuilderAnnotated`)과 구문 분석에서 얻는 것(`objc`, `main` 등)이 섞여 있다.
public enum SymbolAttribute: String, Codable, Sendable, CaseIterable {
    /// 컴파일러가 합성한 선언. 사용자가 지울 수 없다.
    case implicit
    /// `@objc` 또는 `@objc(name)`.
    case objc
    /// `@objcMembers`. 멤버 전체가 Objective-C 로 노출된다.
    case objcMembers
    /// USR 이 `c:` 로 시작해 Objective-C 런타임에서 접근 가능한 심볼.
    case objcAccessible
    /// `dynamic` 제어자. 런타임 치환 대상이 될 수 있다.
    case dynamicDispatch
    /// `@_dynamicReplacement`.
    case dynamicReplacement
    /// `subscript(dynamicMember:)`.
    case dynamicMemberLookup
    /// `@IBOutlet`.
    case interfaceBuilderOutlet
    /// `@IBAction`.
    case interfaceBuilderAction
    /// `@IBInspectable`.
    case interfaceBuilderInspectable
    /// `@IBSegueAction`.
    case interfaceBuilderSegueAction
    /// 인덱스가 Interface Builder 연관으로 표시한 심볼.
    case interfaceBuilderAnnotated
    /// `@main` / `@UIApplicationMain` / `@NSApplicationMain`.
    case entryPoint
    /// `@propertyWrapper` 타입.
    case propertyWrapper
    /// `@resultBuilder` 타입.
    case resultBuilder
    /// 인덱스가 단위 테스트로 표시한 심볼(XCTest).
    case unitTest
    /// swift-testing 의 `@Test`.
    case testFunction
    /// swift-testing 의 `@Suite`.
    case testSuite
    /// SwiftUI `PreviewProvider` 준수 타입 또는 `#Preview` 확장 결과.
    case preview
    /// 원시값(rawValue)을 가진 열거형. 케이스가 동적으로 생성될 수 있다.
    case rawRepresentable
    /// `CaseIterable` 를 준수한다. 케이스가 `allCases` 로만 소비될 수 있다.
    case caseIterable
    /// `CodingKey` 를 준수하는 중첩 열거형.
    case codingKey
    /// 저장소를 런타임이 관리하는 선언.
    ///
    /// `@NSManaged`(Core Data), `@Model`(SwiftData), `@Observable`(Observation)이 여기 속한다.
    /// 값을 읽고 쓰는 주체가 컴파일된 코드가 아니라 런타임이라 인덱스에 참조가 남지 않는다.
    case runtimeManaged
    /// Codable/Encodable/Decodable 을 준수하는 타입.
    ///
    /// 합성된 `init(from:)`/`encode(to:)` 는 저장 프로퍼티 참조를 인덱스에 남기지
    /// 않으므로, 이 표식이 붙은 타입의 프로퍼티는 미사용으로 오인되기 쉽다.
    case codable
    /// `override` 제어자.
    case overrideDeclaration
    /// `// cartograph:ignore` 주석으로 사용자가 제외한 선언.
    case ignoreComment
    /// `// cartograph:ignore:all` 주석이 있는 파일의 선언.
    ///
    /// 파일 범위 주석은 항상 `ignoreComment` 와 함께 붙는다 — 보존 판정은 둘을
    /// 구분할 필요가 없고, 이 표식은 "무시된 이유가 파일 단위인가" 라는 출처만
    /// 남긴다. 불필요한 무시 주석 진단이 파일 범위와 선언 범위를 나눌 때 읽는다.
    case ignoreAllComment
    /// 조상 선언의 `// cartograph:ignore` 가 물려준 무시.
    ///
    /// 선언의 주석은 그 안쪽 서브트리 전체를 덮는다. 그래프에서 전파된 표식과
    /// 자기 주석은 둘 다 `ignoreComment` 로 보이므로, 이 표식이 "무시의 출처가
    /// 조상의 코멘트"임을 남긴다. 불필요한 무시 주석 진단은 자기 주석이 있는
    /// 선언만 코멘트 단위로 세워야 하므로 둘을 구분해야 한다.
    case ignoreInherited
    /// 소스를 읽지 못해 보존에 필요한 주석·접근 수준을 확인하지 못했다.
    case sourceUnavailable
    /// 제네릭 파라미터를 가진 선언.
    case generic

    /// 이 표식이 Interface Builder 계열인지 여부.
    public var isInterfaceBuilderRelated: Bool {
        switch self {
        case .interfaceBuilderOutlet, .interfaceBuilderAction,
             .interfaceBuilderInspectable, .interfaceBuilderSegueAction, .interfaceBuilderAnnotated:
            true
        default:
            false
        }
    }

    /// 이 표식이 Objective-C 노출과 관련되는지 여부.
    public var isObjectiveCRelated: Bool {
        switch self {
        case .objc, .objcMembers, .objcAccessible:
            true
        default:
            false
        }
    }
}
