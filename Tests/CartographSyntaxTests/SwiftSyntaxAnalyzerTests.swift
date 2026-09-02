import CartographCore
import CartographSyntax
import Testing

@Suite("구문 분석")
struct SwiftSyntaxAnalyzerTests {
    private func analyze(_ source: String) -> SourceFileFacts {
        SwiftSyntaxAnalyzer().analyze(source: source, path: "/p/Test.swift")
    }

    @Test("접근 제어자를 읽는다")
    func readsAccessibility() {
        let facts = analyze("""
            public struct A {}
            open class B {}
            package enum C {}
            internal protocol D {}
            fileprivate struct E {}
            private struct F {}
            struct G {}
            """)
        #expect(facts.declaration(named: "A")?.accessibility == .publicLevel)
        #expect(facts.declaration(named: "B")?.accessibility == .openLevel)
        #expect(facts.declaration(named: "C")?.accessibility == .packageLevel)
        #expect(facts.declaration(named: "D")?.accessibility == .internalLevel)
        #expect(facts.declaration(named: "E")?.accessibility == .fileprivateLevel)
        #expect(facts.declaration(named: "F")?.accessibility == .privateLevel)
        #expect(facts.declaration(named: "G")?.accessibility == .internalLevel)
    }

    @Test("private 타입 안의 멤버는 그보다 넓어지지 않는다")
    func nestedAccessibilityIsClamped() {
        let facts = analyze("""
            private struct Outer {
                func inner() {}
            }
            """)
        #expect(facts.declaration(named: "inner")?.accessibility == .privateLevel)
    }

    @Test("선언 속성을 표식으로 옮긴다")
    func readsAttributes() {
        let facts = analyze("""
            @main struct App {}
            @propertyWrapper struct Wrapper {}
            @resultBuilder enum Builder {}
            class View {
                @IBOutlet var label: AnyObject?
                @IBAction func tap() {}
                @IBInspectable var color: Int = 0
                @objc func legacy() {}
            }
            """)
        #expect(facts.declaration(named: "App")?.attributes.contains(.entryPoint) == true)
        #expect(facts.declaration(named: "Wrapper")?.attributes.contains(.propertyWrapper) == true)
        #expect(facts.declaration(named: "Builder")?.attributes.contains(.resultBuilder) == true)
        #expect(facts.declaration(named: "label")?.attributes.contains(.interfaceBuilderOutlet) == true)
        #expect(facts.declaration(named: "tap")?.attributes.contains(.interfaceBuilderAction) == true)
        #expect(facts.declaration(named: "color")?.attributes.contains(.interfaceBuilderInspectable) == true)
        #expect(facts.declaration(named: "legacy")?.attributes.contains(.objc) == true)
    }

    @Test("@objcMembers 는 안쪽 멤버로 전파된다")
    func objcMembersCascades() {
        let facts = analyze("""
            @objcMembers class Legacy {
                func exposed() {}
            }
            class Modern {
                func notExposed() {}
            }
            """)
        #expect(facts.declaration(named: "exposed")?.attributes.contains(.objcAccessible) == true)
        #expect(facts.declaration(named: "notExposed")?.attributes.contains(.objcAccessible) == false)
    }

    @Test("상속 절에서 Codable/CodingKey/프리뷰를 알아낸다")
    func readsInheritanceClause() {
        let facts = analyze("""
            struct User: Codable {
                enum CodingKeys: String, CodingKey { case name }
            }
            struct HomePreview: PreviewProvider {}
            enum Status: String { case active }
            enum Plain { case one }
            """)
        #expect(facts.declaration(named: "User")?.attributes.contains(.codable) == true)
        #expect(facts.declaration(named: "CodingKeys")?.attributes.contains(.codingKey) == true)
        #expect(facts.declaration(named: "CodingKeys")?.attributes.contains(.rawRepresentable) == true)
        #expect(facts.declaration(named: "HomePreview")?.attributes.contains(.preview) == true)
        #expect(facts.declaration(named: "Status")?.attributes.contains(.rawRepresentable) == true)
        #expect(facts.declaration(named: "Plain")?.attributes.contains(.rawRepresentable) == false)
    }

    @Test("XCTest 클래스와 테스트 메서드를 알아본다")
    func recognizesXCTest() {
        let facts = analyze("""
            class MySpec: XCTestCase {
                func testSomething() {}
                func testWithArgument(value: Int) {}
                func helper() {}
            }
            """)
        #expect(facts.declaration(named: "MySpec")?.attributes.contains(.unitTest) == true)
        #expect(facts.declaration(named: "testSomething")?.attributes.contains(.unitTest) == true)
        // XCTest 는 인자가 있는 메서드를 테스트로 실행하지 않는다.
        #expect(facts.declaration(named: "testWithArgument")?.attributes.contains(.unitTest) == false)
        #expect(facts.declaration(named: "helper")?.attributes.contains(.unitTest) == false)
    }

    @Test("swift-testing 매크로를 알아본다")
    func recognizesSwiftTesting() {
        let facts = analyze("""
            @Suite struct Cases {
                @Test func check() {}
            }
            """)
        #expect(facts.declaration(named: "Cases")?.attributes.contains(.testSuite) == true)
        #expect(facts.declaration(named: "check")?.attributes.contains(.testFunction) == true)
    }

    @Test("override 와 dynamic 제어자를 읽는다")
    func readsModifiers() {
        let facts = analyze("""
            class Child: Parent {
                override func run() {}
                dynamic func swizzled() {}
            }
            """)
        #expect(facts.declaration(named: "run")?.attributes.contains(.overrideDeclaration) == true)
        #expect(facts.declaration(named: "swizzled")?.attributes.contains(.dynamicDispatch) == true)
    }

    @Test("dynamicMember 서브스크립트를 알아본다")
    func recognizesDynamicMemberSubscript() {
        let facts = analyze("""
            @dynamicMemberLookup struct Proxy {
                subscript(dynamicMember key: String) -> Int { 0 }
            }
            """)
        #expect(facts.declaration(named: "Proxy")?.attributes.contains(.dynamicMemberLookup) == true)
        #expect(facts.declaration(named: "subscript")?.attributes.contains(.dynamicMemberLookup) == true)
    }

    @Test("무시 주석은 선언과 그 하위에 적용된다")
    func ignoreCommentAppliesToDescendants() {
        let facts = analyze("""
            // cartograph:ignore
            struct Legacy {
                func inner() {}
            }
            struct Normal {}
            """)
        #expect(facts.declaration(named: "Legacy")?.attributes.contains(.ignoreComment) == true)
        #expect(facts.declaration(named: "inner")?.attributes.contains(.ignoreComment) == true)
        #expect(facts.declaration(named: "Normal")?.attributes.contains(.ignoreComment) == false)
    }

    @Test("파일 단위 무시 주석을 인식한다")
    func fileLevelIgnore() {
        let ignored = analyze("""
            // cartograph:ignore:all
            struct A {}
            """)
        #expect(ignored.ignoresEntireFile)
        #expect(!analyze("struct A {}").ignoresEntireFile)
    }

    @Test("여러 종류의 선언을 모두 기록한다")
    func recordsAllDeclarationKinds() {
        let facts = analyze("""
            struct Container {
                typealias Alias = Int
                var stored = 0
                init() {}
                deinit {}
                func method() {}
                subscript(index: Int) -> Int { 0 }
            }
            protocol P { associatedtype Element }
            enum E { case a, b }
            actor Worker {}
            extension Container {}
            @freestanding(expression) macro stringify<T>(_ value: T) -> String
            """)
        let names = Set(facts.declarations.map(\.name))
        #expect(names.isSuperset(of: [
            "Container", "Alias", "stored", "init", "method", "subscript",
            "P", "Element", "E", "a", "b", "Worker", "stringify",
        ]))
    }

    @Test("줄 번호를 정확히 기록한다")
    func recordsLineNumbers() {
        let facts = analyze("""
            struct First {}

            struct Second {}
            """)
        #expect(facts.declaration(named: "First")?.line == 1)
        #expect(facts.declaration(named: "Second")?.line == 3)
        #expect(facts.declaration(atLine: 3)?.name == "Second")
        #expect(facts.declaration(atLine: 99) == nil)
        #expect(facts.declaration(named: "없음") == nil)
    }

    @Test("문법이 깨진 파일도 크래시 없이 처리한다")
    func handlesMalformedSource() {
        let facts = analyze("struct Broken { func missing(")
        #expect(facts.path == "/p/Test.swift")
    }
    @Test("제품 코드의 test 접두사 메서드는 테스트로 보지 않는다")
    func doesNotTreatProductionCodeAsTests() {
        let facts = analyze("""
            struct Pipeline {
                func testData() -> Int { 0 }
                func testRun() {}
            }
            class Runner {
                static func testAll() {}
                func testOnce() {}
            }
            func testFree() {}
            """)
        // 값을 돌려주면 XCTest 가 실행하지 않는다.
        #expect(facts.declaration(named: "testData")?.attributes.contains(.unitTest) == false)
        // 구조체에는 XCTestCase 가 있을 수 없다.
        #expect(facts.declaration(named: "testRun")?.attributes.contains(.unitTest) == false)
        // 타입 메서드는 실행되지 않는다.
        #expect(facts.declaration(named: "testAll")?.attributes.contains(.unitTest) == false)
        // 최상위 함수도 마찬가지다.
        #expect(facts.declaration(named: "testFree")?.attributes.contains(.unitTest) == false)
        // 클래스의 인스턴스 메서드는 남긴다. 기반 클래스가 다른 모듈에 있어도
        // 테스트를 미사용으로 보고하면 안 되기 때문이다.
        #expect(facts.declaration(named: "testOnce")?.attributes.contains(.unitTest) == true)
    }

    @Test("익스텐션에 선언한 테스트 메서드도 남긴다")
    func keepsTestMethodsDeclaredInExtensions() {
        let facts = analyze("""
            extension MySpec {
                func testMore() {}
            }
            """)
        #expect(facts.declaration(named: "testMore")?.attributes.contains(.unitTest) == true)
    }

    @Test("줄 끝 무시 주석도 그 선언에 적용된다")
    func trailingIgnoreCommentAppliesToItsOwnDeclaration() {
        // 줄 끝 주석은 그 선언의 후행 트리비아에 들어간다. 앞 트리비아만 읽으면
        // 사용자는 무시했다고 믿는데 아무 효과가 없다.
        let facts = analyze("""
            func used() {}        // cartograph:ignore
            func other() {}
            """)
        #expect(facts.declaration(named: "used")?.attributes.contains(.ignoreComment) == true)
        #expect(facts.declaration(named: "other")?.attributes.contains(.ignoreComment) == false)
    }

    @Test("백틱 식별자와 실패 가능 이니셜라이저도 매칭된다")
    func matchesEscapedIdentifiersAndFailableInitializers() {
        // 매칭이 안 되면 구문 정보가 붙지 않아 public 선언이 internal 로 분석되고,
        // 그대로 미사용으로 보고된다.
        let facts = analyze("""
            public struct Money {
                public init?(rawValue: String) { nil }
                public func `default`() {}
            }
            """)
        #expect(facts.declaration(matchingIndexName: "init?(rawValue:)", nearLine: 2)?.name == "init")
        #expect(facts.declaration(matchingIndexName: "default()", nearLine: 3)?.accessibility == .publicLevel)
        #expect(SourceFileFacts.baseName(ofIndexName: "init?(rawValue:)") == "init")
        #expect(SourceFileFacts.baseName(ofIndexName: "init(from:)") == "init")
    }

    @Test("본문 안의 지역 선언은 기록하지 않는다")
    func doesNotRecordDeclarationsInsideBodies() {
        // 지역 선언은 인덱스가 걸러 내 정점이 되지 않는다. 그런데도 남겨 두면
        // 이름이 같은 멤버를 찾을 때 줄이 더 가깝다는 이유로 선택되어, public
        // 프로퍼티가 internal 이 되거나 무시 주석이 엉뚱한 곳에 붙는다.
        let facts = analyze("""
            struct Screen {
                @MainActor
                @available(macOS 14, *)
                public var scale: Double = 1
                func render() {
                    let scale = 2.0        // cartograph:ignore
                    _ = scale
                }
                var computed: Int { let scale = 1; return scale }
            }
            """)
        let scales = facts.declarations.filter { $0.name == "scale" }
        #expect(scales.count == 1)
        #expect(scales.first?.accessibility == .publicLevel)
        #expect(scales.first?.attributes.contains(.ignoreComment) == false)
    }

    @Test("SwiftUI 앱 델리게이트 어댑터는 런타임이 관리한다")
    func applicationDelegateAdaptorIsRuntimeManaged() {
        // SwiftUI 가 델리게이트를 대신 만들어 들고 있어 코드 어디에서도 읽지 않지만,
        // 지우면 앱이 델리게이트를 잃는다. 실제 두 프로젝트에서 오탐으로 나왔다.
        let facts = analyze("""
            struct App1 {
                @NSApplicationDelegateAdaptor(D.self) private var macDelegate
                @UIApplicationDelegateAdaptor(D.self) private var iosDelegate
            }
            """)
        #expect(facts.declaration(named: "macDelegate")?.attributes.contains(.runtimeManaged) == true)
        #expect(facts.declaration(named: "iosDelegate")?.attributes.contains(.runtimeManaged) == true)
    }

    @Test("연산자 선언도 기록한다")
    func recordsOperatorDeclarations() {
        let facts = analyze("infix operator <->\n")
        #expect(facts.declaration(named: "<->") != nil)
    }

    @Test("deinit 도 선언으로 기록한다")
    func recordsDeinitializers() {
        let facts = analyze("""
            private class Resource {
                deinit {}
            }
            """)
        #expect(facts.declaration(named: "deinit")?.accessibility == .privateLevel)
    }
}

@Suite("주석 명령")
struct CommentCommandTests {
    @Test("파일 단위 명령을 선언 단위보다 먼저 인식한다")
    func specificCommandWins() {
        #expect(CommentCommand.parse(comment: "// cartograph:ignore:all") == .ignoreAll)
        #expect(CommentCommand.parse(comment: "// cartograph:ignore") == .ignore)
        #expect(CommentCommand.parse(comment: "// 그냥 주석") == nil)
    }
}

@Suite("런타임 관리 속성과 외부 테스트 기반 클래스")
struct RuntimeAttributeSyntaxTests {
    @Test("런타임이 저장소를 관리하는 속성을 알아본다")
    func recognizesRuntimeManagedAttributes() {
        let facts = SwiftSyntaxAnalyzer().analyze(
            source: """
                @Observable final class Store { var items: [Int] = [] }
                @Model final class Item { var title = "" }
                final class Person: NSManagedObject {
                    @NSManaged var name: String
                }
                """,
            path: "/p/A.swift"
        )
        #expect(facts.declaration(named: "Store")?.attributes.contains(.runtimeManaged) == true)
        #expect(facts.declaration(named: "Item")?.attributes.contains(.runtimeManaged) == true)
        #expect(facts.declaration(named: "name")?.attributes.contains(.runtimeManaged) == true)
        #expect(facts.declaration(named: "Person")?.attributes.contains(.runtimeManaged) == false)
    }

    @Test("설정한 외부 테스트 기반 클래스도 테스트로 본다")
    func recognizesExternalTestCaseClasses() {
        // 팀 공통 상위 클래스가 다른 모듈에 있으면 상속 관계를 인덱스에서 따라갈 수 없다.
        let source = "final class MySpec: BaseTestCase { func testThing() {} }"
        let withoutConfiguration = SwiftSyntaxAnalyzer().analyze(source: source, path: "/p/A.swift")
        #expect(withoutConfiguration.declaration(named: "MySpec")?.attributes.contains(.unitTest) == false)

        let configured = SwiftSyntaxAnalyzer(externalTestCaseClasses: ["BaseTestCase"])
            .analyze(source: source, path: "/p/A.swift")
        #expect(configured.declaration(named: "MySpec")?.attributes.contains(.unitTest) == true)
    }
}
