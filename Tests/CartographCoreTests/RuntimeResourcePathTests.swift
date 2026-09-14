import CartographCore
import Testing

@Suite("런타임 리소스 경로")
struct RuntimeResourcePathTests {
    @Test("Core Data 버전 선택 파일도 입력이고 일반 같은 이름 파일은 아니다")
    func recognizesVersionSelectionOnlyInsideModelBundles() {
        #expect(RuntimeResourcePath.isSupported("/p/Store.xcdatamodeld/.xccurrentversion"))
        #expect(!RuntimeResourcePath.isSupported("/p/Docs/.xccurrentversion"))
        #expect(!RuntimeResourcePath.isSupported("/p/Store.xcdatamodeld/nested/.xccurrentversion"))
    }

    @Test("Interface Builder와 직접 xcdatamodel contents만 지원한다")
    func recognizesOnlySupportedResourcePaths() {
        #expect(RuntimeResourcePath.kind(of: "/p/Main.storyboard") == .interfaceBuilder)
        #expect(RuntimeResourcePath.kind(of: "/p/View.XIB") == .interfaceBuilder)
        #expect(RuntimeResourcePath.kind(of: "/p/Model.xcdatamodel/contents") == .coreDataModel)
        #expect(RuntimeResourcePath.kind(of: "/p/Documentation/contents") == nil)
        #expect(RuntimeResourcePath.kind(of: "/p/Model.xcdatamodel/nested/contents") == nil)
    }

    @Test("버전 모델은 xcdatamodeld를 같은 컨테이너로 묶는다")
    func groupsVersionedModels() {
        #expect(RuntimeResourcePath.coreDataModelContainer(
            "/p/Model.xcdatamodeld/V1.xcdatamodel/contents"
        ) == "/p/Model.xcdatamodeld")
        #expect(RuntimeResourcePath.coreDataModelContainer(
            "/p/Single.xcdatamodel/contents"
        ) == "/p/Single.xcdatamodel")
    }
}
