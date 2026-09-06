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
    /// 다른 플랫폼이 언어 경계를 넘어 부른다고 외부 도구(isthmus)가 알려 왔다.
    ///
    /// 인덱스는 Dart 나 JavaScript 를 보지 못한다. 근거는 `--external-retentions` 파일에
    /// 있고 `dead --explain` 이 그것을 문장으로 만든다.
    case externalBridge

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

    /// 테스트 타깃에만 존재할 수 있는 뿌리인지 여부.
    ///
    /// 프리뷰는 여기 들어가지 않는다. `#Preview` 와 `PreviewProvider` 는 정의상
    /// 생산 모듈 안에, 그것이 미리 보는 뷰와 같은 파일에 산다. 프리뷰를 근거로
    /// 모듈을 테스트 타깃으로 판정하면 프리뷰 하나가 앱 모듈 전체를 분석에서
    /// 떨어뜨린다. 이 기능이 겨냥하는 바로 그 프로젝트가 조용히 빈 결과를 받는다.
    public var isTestTargetRoot: Bool {
        switch self {
        case .xcTest, .swiftTesting: true
        default: false
        }
    }

    /// 리포트에 그대로 실을 수 있는 영문 설명.
    /// 이 근거가 소유 타입이 살아 있을 때만 성립하는지.
    ///
    /// "프레임워크가 부른다" 는 주장은 그 타입을 누군가 만들 때만 참이다. 아무도 만들지
    /// 않는 뷰의 `body` 를 무조건 살리면 답이 스스로 모순된다 — 타입은 "미사용" 인데
    /// 그 멤버는 "보존됨" 이라고 답한다. 소유 타입이 없는 최상위 선언에는 조건이 붙을
    /// 자리가 없으므로 그대로 무조건이다.
    public var needsReachableOwner: Bool {
        switch self {
        case .externalConformance, .externalOverride: true
        default: false
        }
    }

    /// 이 근거로 살아남은 멤버가 자신을 감싸는 타입까지 함께 살리는지.
    ///
    /// 대부분의 근거는 "이 선언을 지우면 무언가 깨진다" 는 주장이고, 그 선언을 담은 타입도
    /// 함께 필요하다는 뜻이다. 셋만 다르다. 합성 선언과 외부 준수·오버라이드는 *타입이
    /// 존재하면 반드시 따라 생기는* 것이라, 그 타입을 누가 쓰는지와 무관하게 존재한다.
    /// 그것을 조상까지 전파하면 아무도 만들지 않는 구조체가 자기 memberwise init 때문에,
    /// 아무도 그리지 않는 뷰가 자기 `body` 때문에 영원히 살아남는다.
    ///
    /// 새 근거를 더하는 사람이 반드시 이 판단을 내리도록 값 옆에 둔다.
    public var retainsContainingType: Bool {
        switch self {
        case .compilerSynthesized, .externalConformance, .externalOverride: false
        default: true
        }
    }

    /// 사람이 읽는 근거 문장.
    ///
    /// **"… is " 뒤에 붙는다.** `--explain` 이 "X is retained because it is \(explanation)." 로
    /// 쓰기 때문이다. 동사로 시작하는 문구를 넣으면 "it is satisfies a protocol" 이 되어
    /// 나갔고 실제로 세 개가 그랬다. 새 근거를 더할 때는 명사구나 과거분사로 쓸 것.
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
        case .externalOverride: "an override of a declaration outside the analyzed code"
        case .externalConformance: "required by a protocol declared outside the analyzed code"
        case .dynamicDispatch: "reachable through dynamic dispatch"
        case .preview: "a SwiftUI preview"
        case .userConfigured: "matched by a retain rule in the configuration"
        case .ignoreComment: "marked with a // cartograph:ignore comment"
        case .externalBridge: "called from another platform across a bridge, per the external retentions file"
        }
    }
}
