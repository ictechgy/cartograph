import CartographCore
@testable import CartographSyntax
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

    @Test("등호 주변 공백과 작은따옴표도 읽는다")
    func readsNonCanonicalAttributeSpellings() {
        // XML 이 허용하는 형태다. 손으로 고쳤거나 정렬 도구를 거친 문서에서
        // 이름을 놓치면 스토리보드 전용 화면이 미사용으로 보고된다.
        let document = """
            <button customClass = 'ThemedButton'/>
            <label customClass\t=\t"TitleLabel"/>
            <view customClass='PlainView'/>
            """
        let references = InterfaceBuilderScanner.references(in: document)
        #expect(references.customClassNames == ["ThemedButton", "TitleLabel", "PlainView"])
    }

    @Test("주석 안의 이름은 읽지 않는다")
    func ignoresNamesInsideComments() {
        let document = """
            <!-- <view customClass="LegacyView"/> -->
            <view customClass="LiveView"/>
            """
        #expect(InterfaceBuilderScanner.references(in: document).customClassNames == ["LiveView"])
    }

    @Test("닫히지 않은 주석 뒤는 전부 버린다")
    func dropsEverythingAfterAnUnterminatedComment() {
        let document = """
            <view customClass="LiveView"/>
            <!-- <view customClass="LegacyView"/>
            """
        #expect(InterfaceBuilderScanner.references(in: document).customClassNames == ["LiveView"])
    }

    @Test("속성 이름의 꼬리만 걸리는 경우는 무시한다")
    func doesNotMatchAttributeNameSuffixes() {
        let document = "<view myproperty=\"ghost\" property=\"real\"/>"
        #expect(InterfaceBuilderScanner.references(in: document).outletNames == ["real"])
    }

    @Test("확장자는 대소문자를 가리지 않는다")
    func documentExtensionMatchingIsCaseInsensitive() {
        // APFS 는 기본이 대소문자 구분 없음이라 `Main.XIB` 가 실제로 존재한다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Main.XIB": "<view customClass=\"UpperCase\"/>",
            "/p/Other.Storyboard": "<view customClass=\"MixedCase\"/>",
            "/p/Ignored.swift": "<view customClass=\"NotADocument\"/>",
        ])
        let references = InterfaceBuilderScanner(fileSystem: fileSystem).scan(roots: ["/p"])
        #expect(references.customClassNames == ["UpperCase", "MixedCase"])
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

    /// 이름 전용 스캔과 `references(in:)` 를 맞대 볼 문서들. 위 테스트들이 다루는 형태를 모았다.
    static let nameScanDocuments = [
        "<view customClass=\"A\"/><outlet property=\"b\"/><action selector=\"c:\"/>",
        "<button customClass = 'Themed'/>\n<label customClass\t=\t\"Title\"/>",
        "<!-- <view customClass=\"Legacy\"/> -->\n<view customClass=\"Live\"/>",
        "<view customClass=\"Live\"/>\n<!-- <view customClass=\"Legacy\"/>",
        "<view mycustomClass=\"Ghost\" customClass=\"Real\"/>",
        "<view customClass=\"Unclosed",
        "customClass=\"\"",
        "",
    ]

    @Test("customClass 이름 전용 스캔은 references(in:) 의 이름과 같다", arguments: nameScanDocuments)
    func customClassNameScanMatchesReferences(document: String) {
        // 보강 경로는 outlet·action 을 훑지 않으려고 이름 전용 스캔을 쓴다. 두 스캔이 갈라지면
        // 임베더가 받는 참조와 보존 표식이 서로 다른 타입을 가리킨다.
        #expect(InterfaceBuilderScanner.customClassNames(in: document)
            == InterfaceBuilderScanner.references(in: document).customClassNames)
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

    @Test(
        "공용 빌드 산출물 목록이 거르는 디렉터리 아래 문서는 읽지 않는다",
        arguments: BuildArtifactDirectories.prunedNames.sorted() + [".build-fresh"]
    )
    func skipsSharedBuildArtifactDirectories(directory: String) {
        // 가지치기 목록은 하나뿐이다. 스캐너가 따로 목록을 두면 한쪽에만 있는 이름
        // (`node_modules`, `.build-` 접두 재인덱스 디렉터리) 아래 서드파티 문서가
        // 같은 이름의 앱 타입을 살려 CLI 와 다른 판정이 나온다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App/Main.storyboard": "<view customClass=\"Kept\"/>",
            "/p/\(directory)/x/Vendor.xib": "<view customClass=\"Vendor\"/>",
        ])
        let references = InterfaceBuilderScanner(fileSystem: fileSystem).scan(roots: ["/p"])
        #expect(references.customClassNames == ["Kept"])
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

    @Test("루트로 보강해도 빌드 산출물 아래 문서의 이름으로 앱 타입을 살리지 않는다")
    func rootEnrichmentIgnoresBuildArtifactDocuments() {
        // 임베더가 루트만 넘기는 공개 경로다. CLI 는 공용 목록으로 거른 인벤토리를 넘기므로
        // 여기서 `node_modules` 를 걸으면 같은 프로젝트의 판정이 호출 방식에 따라 갈린다.
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App.swift": "final class Foo {}\nfinal class Bar {}\nfinal class Kept {}",
            "/p/App/Main.storyboard": "<view customClass=\"Kept\"/>",
            "/p/node_modules/x/Foo.xib": "<view customClass=\"Foo\"/>",
            "/p/.build-fresh/Bar.storyboard": "<view customClass=\"Bar\"/>",
        ])
        var builder = SnapshotBuilder()
        builder.symbol("Foo", kind: .classType, path: "/p/App.swift", line: 1)
        builder.symbol("Bar", kind: .classType, path: "/p/App.swift", line: 2)
        builder.symbol("Kept", kind: .classType, path: "/p/App.swift", line: 3)

        let enriched = SnapshotEnricher(fileSystem: fileSystem)
            .enrich(builder.build(), interfaceBuilderRoots: ["/p"])
        let marked = enriched.symbols.filter { $0.attributes.contains(.interfaceBuilderAnnotated) }.map(\.name)
        #expect(marked == ["Kept"])
    }

    @Test("인벤토리 문서로 보강해도 customClass 로 지목된 타입에만 표식을 붙인다")
    func inventoryEnrichmentMarksOnlyCustomClassTypes() {
        // CLI 가 타는 경로다. 표식은 customClass 만 본다. outlet·action 이름이나 주석 속 이름이
        // 타입 이름과 같아도 살리지 않고, 루트로 보강한 결과와 같아야 한다. 빈 목록이 오면
        // (retain_interface_builder: false) 루트가 있어도 표식을 붙이지 않는다.
        let names = ["HomeViewController", "ShadowView", "TitleView", "Done", "LegacyView"]
        let fileSystem = InMemoryFileSystem(files: [
            "/p/App.swift": names.map { "final class \($0) {}" }.joined(separator: "\n"),
            "/p/Main.storyboard": storyboard + """
                <outlet property="TitleView"/><action selector="Done"/>
                <!-- <view customClass="LegacyView"/> -->
                """,
        ])
        var builder = SnapshotBuilder()
        for (index, name) in names.enumerated() {
            builder.symbol(name, kind: .classType, path: "/p/App.swift", line: index + 1)
        }
        let snapshot = builder.build()
        let enricher = SnapshotEnricher(fileSystem: fileSystem)
        func marked(_ enriched: IndexSnapshot) -> [String] {
            enriched.symbols.filter { $0.attributes.contains(.interfaceBuilderAnnotated) }.map(\.name)
        }

        let fromFiles = enricher.enrich(snapshot, interfaceBuilderFiles: ["/p/Main.storyboard"])
        #expect(marked(fromFiles) == ["HomeViewController", "ShadowView"])
        #expect(marked(enricher.enrich(snapshot, interfaceBuilderRoots: ["/p"])) == marked(fromFiles))
        #expect(marked(enricher.enrich(snapshot, interfaceBuilderRoots: ["/p"], interfaceBuilderFiles: [])).isEmpty)
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
