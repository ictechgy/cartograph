import CartographCore
import CartographSyntax
import CartographTestSupport
import Testing

@Suite("Interface Builder 참조 수집")
struct InterfaceBuilderScannerTests {
    private let storyboard = """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB">
          <scenes>
            <scene sceneID="tne-QT-ifu">
              <objects>
                <viewController id="BYZ-38-t0r" customClass="HomeViewController" customModule="App">
                  <view key="view">
                    <subviews>
                      <view customClass="ShadowView" customModule="DesignKit"/>
                    </subviews>
                  </view>
                  <connections>
                    <outlet property="titleLabel" destination="abc"/>
                    <action selector="didTapDone:" destination="def"/>
                  </connections>
                </viewController>
              </objects>
            </scene>
          </scenes>
        </document>
        """

    @Test("customClass, outlet, action 을 모두 읽는다")
    func readsAllReferenceKinds() {
        let references = InterfaceBuilderScanner.references(in: storyboard)
        #expect(references.customClassNames == ["HomeViewController", "ShadowView"])
        #expect(references.outletNames == ["titleLabel"])
        #expect(references.actionSelectors == ["didTapDone:"])
        #expect(!references.isEmpty)
    }

    @Test("빈 문서에서는 아무것도 나오지 않는다")
    func emptyDocument() {
        #expect(InterfaceBuilderScanner.references(in: "").isEmpty)
        #expect(InterfaceBuilderScanner.references(in: "<document/>").isEmpty)
    }

    @Test("닫는 따옴표가 없는 손상된 문서에서도 멈추지 않는다")
    func malformedDocumentTerminates() {
        // 필요한 것은 몇 개의 속성뿐이라 XML 파서를 쓰지 않는다. 대신 어떤 입력에도
        // 무한 루프에 빠지지 않아야 한다.
        let malformed = "<view customClass=\"Unclosed"
        #expect(InterfaceBuilderScanner.references(in: malformed).isEmpty)
        #expect(InterfaceBuilderScanner.references(in: "customClass=\"\"").isEmpty)
    }

    @Test("여러 문서를 합쳐 수집한다")
    func scansMultipleDocuments() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Base.lproj/Main.storyboard": storyboard,
            "/p/Views/Badge.xib": "<view customClass=\"BadgeView\"/>",
            "/p/README.md": "customClass=\"NotADocument\"",
            "/p/.build/checkouts/Other.storyboard": "<view customClass=\"Vendor\"/>",
        ])
        let references = InterfaceBuilderScanner(fileSystem: fileSystem).scan(roots: ["/p"])
        #expect(references.customClassNames == ["HomeViewController", "ShadowView", "BadgeView"])
        #expect(!references.customClassNames.contains("NotADocument"))
        #expect(!references.customClassNames.contains("Vendor"))
    }

    @Test("경로 필터가 적용된다")
    func respectsPathFilter() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App/Main.storyboard": "<view customClass=\"Kept\"/>",
            "/p/Legacy/Old.storyboard": "<view customClass=\"Dropped\"/>",
        ])
        let references = InterfaceBuilderScanner(fileSystem: fileSystem)
            .scan(roots: ["/p"], pathFilter: PathFilter(exclude: ["**/Legacy/**"]))
        #expect(references.customClassNames == ["Kept"])
    }

    @Test("스토리보드가 지목한 타입에 표식을 붙인다")
    func marksCustomClassesInSnapshot() {
        // 스토리보드에서만 쓰이는 화면은 Swift 코드 어디에도 참조가 없다.
        var builder = SnapshotBuilder()
        builder.symbol("HomeViewController", kind: .classType)
        builder.symbol("Unrelated", kind: .classType)
        builder.symbol("HomeViewController.method", name: "HomeViewController", kind: .method)

        let marked = SnapshotEnricher.marking(
            builder.build(),
            interfaceBuilderReferences: InterfaceBuilderReferences(customClassNames: ["HomeViewController"])
        )
        let byUSR = marked.symbolsByUSR()
        #expect(byUSR["HomeViewController"]?.attributes.contains(.interfaceBuilderAnnotated) == true)
        #expect(byUSR["Unrelated"]?.attributes.contains(.interfaceBuilderAnnotated) == false)
        // 같은 이름의 메서드까지 살리지는 않는다.
        #expect(byUSR["HomeViewController.method"]?.attributes.contains(.interfaceBuilderAnnotated) == false)
    }

    @Test("참조가 없으면 스냅샷을 그대로 둔다")
    func noReferencesLeavesSnapshotUnchanged() {
        var builder = SnapshotBuilder()
        builder.symbol("A", kind: .classType)
        let snapshot = builder.build()
        #expect(SnapshotEnricher.marking(snapshot, interfaceBuilderReferences: .init()) == snapshot)
    }

    @Test("보강 경로에서 스토리보드까지 함께 읽는다")
    func enrichmentReadsInterfaceBuilderDocuments() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App.swift": "final class HomeViewController: UIViewController {}",
            "/p/Main.storyboard": "<viewController customClass=\"HomeViewController\"/>",
        ])
        var builder = SnapshotBuilder()
        builder.symbol("HomeViewController", kind: .classType, path: "/p/App.swift", line: 1)

        let enriched = SnapshotEnricher(fileSystem: fileSystem)
            .enrich(builder.build(), interfaceBuilderRoots: ["/p"])
        #expect(enriched.symbols[0].attributes.contains(.interfaceBuilderAnnotated))
    }

    @Test("루트를 주지 않으면 스토리보드를 읽지 않는다")
    func withoutRootsNoScanHappens() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App.swift": "final class HomeViewController {}",
            "/p/Main.storyboard": "<viewController customClass=\"HomeViewController\"/>",
        ])
        var builder = SnapshotBuilder()
        builder.symbol("HomeViewController", kind: .classType, path: "/p/App.swift", line: 1)
        let enriched = SnapshotEnricher(fileSystem: fileSystem).enrich(builder.build())
        #expect(!enriched.symbols[0].attributes.contains(.interfaceBuilderAnnotated))
    }
}
