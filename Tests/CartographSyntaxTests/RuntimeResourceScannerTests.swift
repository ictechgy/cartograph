import CartographCore
@testable import CartographSyntax
import Testing

@Suite("런타임 리소스 스캐너")
struct RuntimeResourceScannerTests {
    @Test("action의 목적지 타입과 outlet의 소유 타입을 컨트롤러별로 보존한다")
    func preservesConnectionOwners() {
        let source = """
            <document>
              <objects>
                <viewController id="first" customClass="FirstController" customModule="App">
                  <connections><outlet property="title" destination="first-label"/></connections>
                  <view><subviews><button id="first-button"><connections>
                    <action selector="submit:" destination="first"/>
                  </connections></button></subviews></view>
                </viewController>
                <viewController id="second" customClass="SecondController" customModule="App">
                  <connections><outlet property="title" destination="second-label"/></connections>
                  <view><subviews><button id="second-button"><connections>
                    <action selector="submit:" destination="second"/>
                  </connections></button></subviews></view>
                </viewController>
              </objects>
            </document>
            """

        let facts = RuntimeResourceScanner.scan(source: source, path: "/p/Main.storyboard")
        let actions = facts.boundaries.filter { $0.kind == .interfaceBuilderAction }
        let outlets = facts.boundaries.filter { $0.kind == .interfaceBuilderOutlet }

        #expect(actions.map(\.receiverTypeName) == ["App.FirstController", "App.SecondController"])
        #expect(actions.map(\.targetMemberName) == ["submit:", "submit:"])
        #expect(actions.map(\.resourceObjectID) == ["first", "second"])
        #expect(actions.allSatisfy { $0.receiverOrigin == .explicitTarget && $0.reason == nil })
        #expect(outlets.map(\.receiverTypeName) == ["App.FirstController", "App.SecondController"])
        #expect(outlets.map(\.targetMemberName) == ["title", "title"])
        #expect(outlets.map(\.resourceObjectID) == ["first", "second"])
        #expect(outlets.allSatisfy { $0.receiverOrigin == .enclosingType && $0.reason == nil })
        #expect(facts.boundaries.allSatisfy { $0.location.path == "/p/Main.storyboard" })
        #expect(Set(facts.boundaries.map(\.id)).count == facts.boundaries.count)
    }

    @Test("명시한 모듈만 타입 이름에 붙이고 target 제공자는 모듈로 해석하지 않는다")
    func qualifiesOnlyExplicitModules() {
        let source = """
            <objects>
              <viewController id="explicit" customClass="Screen" customModule="Feature"/>
              <viewController id="provided" customClass="Settings" customModuleProvider="target"/>
              <viewController id="both" customClass="Profile" customModule="Account"
                              customModuleProvider="target"/>
            </objects>
            """

        let classes = RuntimeResourceScanner.scan(source: source, path: "/p/View.xib").boundaries
            .filter { $0.kind == .interfaceBuilderClass }
        #expect(classes.map(\.name) == ["Screen", "Settings", "Profile"])
        #expect(classes.map(\.receiverTypeName) == ["Feature.Screen", "Settings", "Account.Profile"])
        #expect(classes.map(\.resourceObjectID) == ["explicit", "provided", "both"])
    }

    @Test("중복 객체 ID로 향하는 action을 특정 클래스에 연결하지 않는다")
    func duplicateObjectIDsAreAmbiguous() {
        let source = """
            <objects>
              <viewController id="duplicate" customClass="FirstController"/>
              <viewController id="duplicate" customClass="SecondController"/>
              <button id="button"><connections>
                <action selector="go:" destination="duplicate"/>
              </connections></button>
            </objects>
            """

        let facts = RuntimeResourceScanner.scan(source: source, path: "/p/Main.storyboard")
        let action = facts.boundaries.first { $0.kind == .interfaceBuilderAction }
        #expect(action?.receiverTypeName == nil)
        #expect(action?.resourceObjectID == "duplicate")
        #expect(action?.reason == "duplicate resource object id 'duplicate'")
    }

    @Test("손상된 XML에서는 앞에서 읽은 연결도 확정하지 않는다")
    func malformedXMLProducesNoPartialConnections() {
        let source = """
            <document><viewController id="screen" customClass="ScreenController"/>
            <view customClass="Unclosed">
            """

        let facts = RuntimeResourceScanner.scan(source: source, path: "/p/Broken.storyboard")
        #expect(facts.boundaries.isEmpty)
        #expect(facts.limitations == ["malformed Interface Builder XML: /p/Broken.storyboard"])
    }

    @Test("외부 XML 엔티티를 해석하지 않고 문서 전체를 미확정으로 남긴다")
    func refusesExternalEntities() {
        let source = """
            <!DOCTYPE document [<!ENTITY external SYSTEM "file:///etc/passwd">]>
            <document><viewController id="screen" customClass="&external;"/></document>
            """

        let facts = RuntimeResourceScanner.scan(source: source, path: "/p/External.storyboard")
        #expect(facts.boundaries.isEmpty)
        #expect(facts.limitations == ["XML DTDs and external entities are disabled: /p/External.storyboard"])
    }

    @Test("알 수 없는 목적지와 클래스 없는 소유자를 unresolved 경계로 보존한다")
    func preservesUnresolvedConnections() {
        let source = """
            <objects>
              <firstResponder id="external"/>
              <viewController id="plain">
                <connections><outlet property="label" destination="view"/></connections>
              </viewController>
              <button id="button"><connections>
                <action selector="missing:" destination="unknown"/>
                <action selector="external:" destination="external"/>
              </connections></button>
              <connections><outlet property="orphan" destination="view"/></connections>
            </objects>
            """

        let boundaries = RuntimeResourceScanner.scan(source: source, path: "/p/Main.storyboard").boundaries
        let reasons = Set(boundaries.compactMap(\.reason))
        #expect(reasons.contains("owning object 'plain' has no custom class"))
        #expect(reasons.contains("unknown destination object id 'unknown'"))
        #expect(reasons.contains("destination object 'external' has no custom class"))
        #expect(reasons.contains("connection has no owning object"))
        #expect(boundaries.filter { $0.kind != .interfaceBuilderClass }.allSatisfy {
            $0.receiverTypeName == nil
        })
    }

    @Test("XML 주석은 무시하고 이스케이프된 속성 값은 디코딩한다")
    func handlesCommentsAndEscapes() {
        let source = """
            <objects>
              <!-- <viewController id="old" customClass="LegacyController"/> -->
              <viewController id="live" customClass="Live&amp;Preview">
                <connections><outlet property="title&amp;subtitle" destination="label"/></connections>
              </viewController>
            </objects>
            """

        let boundaries = RuntimeResourceScanner.scan(source: source, path: "/p/View.xib").boundaries
        #expect(boundaries.filter { $0.kind == .interfaceBuilderClass }.map(\.name) == ["Live&Preview"])
        #expect(boundaries.filter { $0.kind == .interfaceBuilderOutlet }.map(\.targetMemberName)
                == ["title&subtitle"])
        #expect(!boundaries.compactMap(\.name).contains("LegacyController"))
    }
}
