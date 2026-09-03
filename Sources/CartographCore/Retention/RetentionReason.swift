/// 어떤 선언을 "사용되지 않았지만 지우면 안 된다"고 판단한 근거.
///
/// Periphery 의 가장 큰 사용성 문제는 왜 특정 선언이 살아남았는지 설명하지 못한다는
/// 점이었다. Cartograph 는 보존 결정마다 근거를 값으로 남겨
/// `cartograph dead --explain <USR>` 로 되짚을 수 있게 한다.
public enum RetentionReason: String, Codable, Sendable, CaseIterable {
    /// `@main` 등 앱 진입점.
    case entryPoint
    /// XCTest 테스트 케이스/메서드.
    case xcTest
    /// swift-testing 의 `@Test` / `@Suite`.
    case swiftTesting
    /// 모듈 밖으로 공개된 API(`--retain-public`).
    case publicAPI
    /// Objective-C 런타임에서 접근 가능.
    case objectiveCAccessible
    /// Interface Builder 에서 연결될 수 있는 선언.
    case interfaceBuilder
    /// 컴파일러가 합성한 선언.
    case compilerSynthesized
    /// 원시값 열거형의 케이스. `init(rawValue:)` 로 동적 생성될 수 있다.
    case rawRepresentableEnumCase
    case caseIterableEnumCase
    /// `CodingKey` 열거형 케이스.
    case codingKey
    /// Codable 타입의 저장 프로퍼티. 합성된 인코딩/디코딩이 참조를 남기지 않는다.
    case codableProperty
    /// 저장소를 런타임이 관리하는 선언(Core Data, SwiftData, Observation).
    case runtimeManaged
    /// `@propertyWrapper` 가 요구하는 멤버.
    case propertyWrapperRequirement
    /// `@resultBuilder` 가 요구하는 멤버.
    case resultBuilderRequirement
    /// 외부(SDK) 선언을 오버라이드.
    case externalOverride
    /// 외부 프로토콜 요구사항 구현.
    case externalConformance
    /// `subscript(dynamicMember:)` / `@_dynamicReplacement` 등 동적 디스패치.
    case dynamicDispatch
    /// SwiftUI 프리뷰.
    case preview
    /// 설정의 보존 목록에 사용자가 직접 지정.
    case userConfigured
    /// `// cartograph:ignore` 주석.
    case ignoreComment

    /// 생산 코드가 아니라 테스트나 프리뷰가 살려 둔 뿌리인지 여부.
    ///
    /// 이 구분이 있어야 "생산 코드에서는 죽었고 테스트만 붙잡고 있는" 선언을
    /// 따로 볼 수 있다. 그것은 죽은 코드가 아니지만, 테스트가 유일한 사용자라는
    /// 사실 자체가 팀이 알아야 할 정보다.
    public var isTestOrPreviewRoot: Bool {
        switch self {
        case .xcTest, .swiftTesting, .preview: true
        default: false
        }
    }

    /// 리포트에 그대로 실을 수 있는 영문 설명.
    public var explanation: String {
        switch self {
        case .entryPoint: "declared as an application entry point (@main)"
        case .xcTest: "an XCTest case or test method"
        case .swiftTesting: "a swift-testing @Test or @Suite declaration"
        case .publicAPI: "public API and retain_public is enabled"
        case .objectiveCAccessible: "reachable from the Objective-C runtime"
        case .interfaceBuilder: "connectable from Interface Builder"
        case .compilerSynthesized: "synthesized by the compiler"
        case .rawRepresentableEnumCase: "a case of a raw-representable enum, constructible via init(rawValue:)"
        case .caseIterableEnumCase: "a case of a CaseIterable enum, enumerated by allCases"
        case .codingKey: "a CodingKey case used by synthesized Codable conformance"
        case .codableProperty: "a stored property of a Codable type, read by synthesized coding"
        case .runtimeManaged: "stored and read by a runtime (Core Data, SwiftData or Observation)"
        case .propertyWrapperRequirement: "required by the @propertyWrapper contract"
        case .resultBuilderRequirement: "required by the @resultBuilder contract"
        case .externalOverride: "overrides a declaration outside the analyzed code"
        case .externalConformance: "satisfies a protocol declared outside the analyzed code"
        case .dynamicDispatch: "reachable through dynamic dispatch"
        case .preview: "a SwiftUI preview"
        case .userConfigured: "matched a retain rule in the configuration"
        case .ignoreComment: "marked with a // cartograph:ignore comment"
        }
    }
}
