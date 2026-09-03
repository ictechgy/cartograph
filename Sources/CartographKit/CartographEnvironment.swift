import CartographCore
import CartographIndexStore
import Foundation

/// 도구가 바깥 세계와 만나는 지점을 한곳에 모은다.
///
/// 파일 시스템, 툴체인 위치, 인덱스 공급자를 모두 주입 가능하게 두어
/// 파이프라인 전체를 실제 인덱스 없이 테스트할 수 있게 한다.
public struct CartographEnvironment: Sendable {
    public var fileSystem: any FileSystem
    /// Xcode 개발자 디렉터리. nil 이면 실행 시점에 알아낸다.
    public var developerDirectory: String?
    /// DerivedData 위치. nil 이면 기본 경로를 쓴다.
    public var derivedDataPath: String?
    /// 인덱스 공급자를 직접 지정한다. 테스트에서 실제 인덱스 스토어를 대체한다.
    public var indexProviderOverride: (any IndexProviding)?
    /// 구문 분석 캐시를 쓸지 여부. 끄면 매 실행마다 다시 파싱한다.
    ///
    /// 캐시 키가 파일 내용이라 켜 두어도 결과가 달라지지 않지만, 결과를 의심할
    /// 때 변수를 하나 줄일 수 있어야 한다.
    public var usesSyntaxCache: Bool

    public init(
        fileSystem: any FileSystem = LocalFileSystem(),
        developerDirectory: String? = nil,
        derivedDataPath: String? = nil,
        indexProviderOverride: (any IndexProviding)? = nil,
        usesSyntaxCache: Bool = true
    ) {
        self.fileSystem = fileSystem
        self.developerDirectory = developerDirectory
        self.derivedDataPath = derivedDataPath
        self.indexProviderOverride = indexProviderOverride
        self.usesSyntaxCache = usesSyntaxCache
    }

    /// 실제 환경에서 사용할 기본값.
    public static func live() -> CartographEnvironment {
        CartographEnvironment(
            fileSystem: LocalFileSystem(),
            developerDirectory: XcodeEnvironment.developerDirectory(),
            derivedDataPath: Self.defaultDerivedDataPath
        )
    }

    /// Xcode 의 기본 DerivedData 경로.
    public static var defaultDerivedDataPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }
}
