import CartographCore
@testable import CartographKit
import CartographTestSupport
import Testing

@Suite("실행 환경")
struct CartographEnvironmentTests {
    @Test("기본 환경은 실제 파일 시스템과 Xcode 경로를 쓴다")
    func liveEnvironment() {
        let environment = CartographEnvironment.live()
        #expect(environment.indexProviderOverride == nil)
        #expect(environment.derivedDataPath?.hasSuffix("Library/Developer/Xcode/DerivedData") == true)
    }

    @Test("DerivedData 기본 경로는 홈 디렉터리 아래다")
    func defaultDerivedDataPath() {
        #expect(CartographEnvironment.defaultDerivedDataPath.contains("Library/Developer/Xcode/DerivedData"))
    }

    @Test("테스트에서는 인덱스 공급자를 바꿔 끼울 수 있다")
    func providerCanBeOverridden() throws {
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .structType)
        let environment = CartographEnvironment(
            fileSystem: InMemoryFileSystem(),
            indexProviderOverride: StaticIndexProvider(builder.build())
        )
        #expect(try environment.indexProviderOverride?.loadSnapshot().symbols.count == 1)
    }
}
