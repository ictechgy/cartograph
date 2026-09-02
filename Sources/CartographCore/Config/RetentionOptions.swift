/// 데드코드 분석에서 무엇을 살려 둘지 정하는 설정.
///
/// 기본값은 "거짓 양성보다 거짓 음성이 낫다"는 쪽으로 잡았다.
/// 지워도 되는 코드를 놓치는 비용보다, 지우면 안 되는 코드를 지우라고
/// 권하는 비용이 훨씬 크기 때문이다.
public struct RetentionOptions: Sendable, Codable, Equatable {
    /// public/open 선언을 보존한다. 라이브러리 패키지라면 켠다.
    public var retainPublic: Bool
    /// Objective-C 런타임에서 접근 가능한 선언을 보존한다.
    ///
    /// Periphery 는 기본값이 꺼짐이라 혼합 언어 프로젝트에서 거짓 양성이 잦았다.
    /// iOS 앱은 UIKit·KVO·셀렉터 사용이 흔하므로 기본값을 켬으로 둔다.
    public var retainObjectiveCAccessible: Bool
    /// Interface Builder 연결 가능성이 있는 선언을 보존한다.
    ///
    /// xib/storyboard 를 아직 파싱하지 않으므로, 연결 여부를 확인하는 대신
    /// `@IBOutlet`/`@IBAction` 계열을 보수적으로 모두 보존한다.
    public var retainInterfaceBuilder: Bool
    /// 테스트 선언을 보존한다.
    public var retainTests: Bool
    /// SwiftUI 프리뷰를 보존한다. 끄면 프리뷰 전용 코드가 미사용으로 보고된다.
    public var retainPreviews: Bool
    /// Codable 타입의 저장 프로퍼티를 보존한다.
    ///
    /// 합성된 `init(from:)`/`encode(to:)` 는 인덱스에 참조를 남기지 않는다.
    public var retainCodableProperties: Bool
    /// 원시값 열거형의 케이스를 보존한다.
    public var retainRawRepresentableEnumCases: Bool
    /// 이름이 일치하면 보존할 심볼 글롭 목록. 예: `*.shared`, `AppDelegate`.
    public var retainedNames: [GlobPattern]
    /// 파일 전체를 보존할 경로 글롭 목록.
    public var retainedFiles: [GlobPattern]
    /// 다른 모듈에 있는 XCTest 기반 클래스 이름 목록.
    public var externalTestCaseClasses: [String]

    public init(
        retainPublic: Bool = false,
        retainObjectiveCAccessible: Bool = true,
        retainInterfaceBuilder: Bool = true,
        retainTests: Bool = true,
        retainPreviews: Bool = true,
        retainCodableProperties: Bool = true,
        retainRawRepresentableEnumCases: Bool = true,
        retainedNames: [GlobPattern] = [],
        retainedFiles: [GlobPattern] = [],
        externalTestCaseClasses: [String] = []
    ) {
        self.retainPublic = retainPublic
        self.retainObjectiveCAccessible = retainObjectiveCAccessible
        self.retainInterfaceBuilder = retainInterfaceBuilder
        self.retainTests = retainTests
        self.retainPreviews = retainPreviews
        self.retainCodableProperties = retainCodableProperties
        self.retainRawRepresentableEnumCases = retainRawRepresentableEnumCases
        self.retainedNames = retainedNames
        self.retainedFiles = retainedFiles
        self.externalTestCaseClasses = externalTestCaseClasses
    }

    public static let `default` = RetentionOptions()

    private enum CodingKeys: String, CodingKey {
        case retainPublic = "retain_public"
        case retainObjectiveCAccessible = "retain_objc_accessible"
        case retainInterfaceBuilder = "retain_interface_builder"
        case retainTests = "retain_tests"
        case retainPreviews = "retain_previews"
        case retainCodableProperties = "retain_codable_properties"
        case retainRawRepresentableEnumCases = "retain_raw_representable_enum_cases"
        case retainedNames = "retained_names"
        case retainedFiles = "retained_files"
        case externalTestCaseClasses = "external_test_case_classes"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RetentionOptions.default
        self.init(
            retainPublic: try container.decodeIfPresent(Bool.self, forKey: .retainPublic)
                ?? fallback.retainPublic,
            retainObjectiveCAccessible: try container.decodeIfPresent(
                Bool.self, forKey: .retainObjectiveCAccessible) ?? fallback.retainObjectiveCAccessible,
            retainInterfaceBuilder: try container.decodeIfPresent(Bool.self, forKey: .retainInterfaceBuilder)
                ?? fallback.retainInterfaceBuilder,
            retainTests: try container.decodeIfPresent(Bool.self, forKey: .retainTests)
                ?? fallback.retainTests,
            retainPreviews: try container.decodeIfPresent(Bool.self, forKey: .retainPreviews)
                ?? fallback.retainPreviews,
            retainCodableProperties: try container.decodeIfPresent(Bool.self, forKey: .retainCodableProperties)
                ?? fallback.retainCodableProperties,
            retainRawRepresentableEnumCases: try container.decodeIfPresent(
                Bool.self, forKey: .retainRawRepresentableEnumCases) ?? fallback.retainRawRepresentableEnumCases,
            retainedNames: try container.decodeIfPresent([GlobPattern].self, forKey: .retainedNames) ?? [],
            retainedFiles: try container.decodeIfPresent([GlobPattern].self, forKey: .retainedFiles) ?? [],
            externalTestCaseClasses: try container.decodeIfPresent(
                [String].self, forKey: .externalTestCaseClasses) ?? []
        )
    }
}
