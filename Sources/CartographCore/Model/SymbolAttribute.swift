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
    /// `CodingKey` 를 준수하는 중첩 열거형.
    case codingKey
    /// `override` 제어자.
    case overrideDeclaration
    /// `// cartograph:ignore` 주석으로 사용자가 제외한 선언.
    case ignoreComment
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
