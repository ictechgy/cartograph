import CartographCore
import CartographTestSupport
@testable import CartographKit
import Testing

@Suite("outlet collection 리소스 영향")
struct OutletCollectionImpactTests {
    @Test("리소스만 선택해 collection 프로퍼티와 소비자 테스트를 찾고 동명 타 클래스는 제외한다",
          arguments: ["Main.xib", "Main.storyboard"])
    func selectsCollectionPropertyAndConsumers(resourceName: String) throws {
        let sourcePath = "/p/App.swift"
        let resourcePath = "/p/" + resourceName
        let resource = """
            <document><objects>
              <viewController id="screen" customClass="Screen" customModule="App">
                <connections><outletCollection property="labels" destination="label"/></connections>
              </viewController>
              <label id="label"/>
            </objects></document>
            """
        func location(_ line: Int) -> CartographCore.SourceLocation {
            .init(path: sourcePath, line: line, column: 1)
        }
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "screen", name: "Screen", kind: .classType, module: "App", location: location(1)),
            .init(usr: "labels", name: "labels", kind: .property, module: "App",
                  location: location(2), parentUSR: "screen", attributes: [.interfaceBuilderOutlet]),
            .init(usr: "other", name: "Other", kind: .classType, module: "App", location: location(10)),
            .init(usr: "other-labels", name: "labels", kind: .property, module: "App",
                  location: location(11), parentUSR: "other", attributes: [.interfaceBuilderOutlet]),
            .init(usr: "render", name: "render()", kind: .function, module: "App", location: location(20)),
            .init(usr: "other-render", name: "otherRender()", kind: .function, module: "App",
                  location: location(21)),
            .init(usr: "test", name: "testRender()", kind: .function, module: "Tests",
                  location: .init(path: "/p/Tests/ScreenTests.swift", line: 1, column: 1),
                  attributes: [.unitTest]),
        ], references: [
            .init(sourceUSR: "render", targetUSR: "labels", kind: .reference),
            .init(sourceUSR: "other-render", targetUSR: "other-labels", kind: .reference),
            .init(sourceUSR: "test", targetUSR: "render", kind: .call),
        ])
        let declarations: [RuntimeDeclaration] = [
            .init(name: "Screen", indexName: "Screen", qualifiedName: "Screen", kind: .classType,
                  location: location(1), endLocation: location(5)),
            .init(name: "labels", indexName: "labels", qualifiedName: "Screen.labels", kind: .property,
                  location: location(2), endLocation: location(3), objectiveCName: "labels"),
            .init(name: "Other", indexName: "Other", qualifiedName: "Other", kind: .classType,
                  location: location(10), endLocation: location(15)),
            .init(name: "labels", indexName: "labels", qualifiedName: "Other.labels", kind: .property,
                  location: location(11), endLocation: location(12), objectiveCName: "labels"),
        ]
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: InMemoryFileSystem(files: [resourcePath: resource]),
            indexProviderOverride: StaticIndexProvider(snapshot)
        ))
        let files = [RuntimeFileFacts(path: sourcePath, declarations: declarations)]
            + service.runtimeResourceFacts(paths: [resourcePath])
        let context = AnalysisContext(snapshot: snapshot, runtimeFiles: files,
            runtimeFreshness: [sourcePath: .fresh, "/p/Tests/ScreenTests.swift": .fresh])
        let impact = try service.impactDocument(files: [resourceName], in: context)
        let affected = try service.affectedDocument(files: [resourceName], in: context)

        #expect(impact.status == "found")
        #expect(impact.selectionIssues.isEmpty)
        // 타입 선택의 멤버 확장만으로 통과하지 않도록 직접 선택된 프로퍼티를 검사한다.
        #expect(Set(impact.selected.compactMap(\.usr)) == ["screen", "labels"])
        #expect(Set(impact.affected.compactMap(\.symbol.usr)) == ["render", "test"])
        #expect(impact.tests.map(\.usr) == ["test"])
        #expect(Set(affected.selected.map(\.usr)) == ["screen", "labels"])
        #expect(affected.tests.map(\.symbol.usr) == ["test"])
        #expect(affected.selectionIssues.isEmpty)
        let collections = context.runtimeDiscovery()?.findings.filter { $0.boundary.api == "outletCollection" }
        #expect(collections?.count == 1)
        #expect(collections?.first?.targets == [NodeID("labels")])
        #expect(collections?.first?.boundary.kind == .interfaceBuilderOutlet)
    }
}
