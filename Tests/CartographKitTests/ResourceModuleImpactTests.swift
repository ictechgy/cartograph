import CartographCore
import CartographTestSupport
@testable import CartographKit
import Testing

@Suite("UI 리소스의 명시적 모듈 경계")
struct ResourceModuleImpactTests {
    @Test("동명 타입은 명시한 모듈만 선택하고 없거나 잘못된 모듈은 임의로 고르지 않는다",
          arguments: ["Main.xib", "Main.storyboard"], ["FeatureA", "FeatureB", "", "Unknown"])
    func selectsOnlyExplicitModule(resourceName: String, module: String) throws {
        func sourcePath(_ owner: String) -> String {
            owner == "FeatureA" ? "/p/First/Screen.swift" : "/p/Second/Screen.swift"
        }
        func location(_ owner: String, _ line: Int) -> CartographCore.SourceLocation {
            .init(path: sourcePath(owner), line: line, column: 1)
        }
        func testPath(_ owner: String) -> String {
            owner == "FeatureA" ? "/p/FirstTests/ScreenTests.swift" : "/p/SecondTests/ScreenTests.swift"
        }
        let resourcePath = "/p/" + resourceName
        let moduleAttribute = module.isEmpty ? "" : "customModule=\"\(module)\""
        let resource = """
            <document><objects>
              <viewController id="screen" customClass="Screen" \(moduleAttribute)>
                <connections><outletCollection property="labels" destination="label"/></connections>
              </viewController>
              <label id="label"/>
            </objects></document>
            """
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "FeatureA-screen", name: "Screen", kind: .classType,
                  module: "FeatureA", location: location("FeatureA", 1)),
            .init(usr: "FeatureA-labels", name: "labels", kind: .property, module: "FeatureA",
                  location: location("FeatureA", 2), parentUSR: "FeatureA-screen",
                  attributes: [.interfaceBuilderOutlet]),
            .init(usr: "FeatureB-screen", name: "Screen", kind: .classType,
                  module: "FeatureB", location: location("FeatureB", 1)),
            .init(usr: "FeatureB-labels", name: "labels", kind: .property, module: "FeatureB",
                  location: location("FeatureB", 2), parentUSR: "FeatureB-screen",
                  attributes: [.interfaceBuilderOutlet]),
            .init(usr: "FeatureA-render", name: "render()", kind: .function,
                  module: "FeatureA", location: location("FeatureA", 20)),
            .init(usr: "FeatureB-render", name: "render()", kind: .function,
                  module: "FeatureB", location: location("FeatureB", 20)),
            .init(usr: "FeatureA-test", name: "testRender()", kind: .function, module: "FeatureATests",
                  location: .init(path: testPath("FeatureA"), line: 1, column: 1), attributes: [.unitTest]),
            .init(usr: "FeatureB-test", name: "testRender()", kind: .function, module: "FeatureBTests",
                  location: .init(path: testPath("FeatureB"), line: 1, column: 1), attributes: [.unitTest]),
        ], references: [
            .init(sourceUSR: "FeatureA-render", targetUSR: "FeatureA-labels", kind: .reference),
            .init(sourceUSR: "FeatureB-render", targetUSR: "FeatureB-labels", kind: .reference),
            .init(sourceUSR: "FeatureA-test", targetUSR: "FeatureA-render", kind: .call),
            .init(sourceUSR: "FeatureB-test", targetUSR: "FeatureB-render", kind: .call),
        ])
        let sourceFacts = ["FeatureA", "FeatureB"].map { owner in
            RuntimeFileFacts(path: sourcePath(owner), declarations: [
                .init(name: "Screen", indexName: "Screen", qualifiedName: "Screen", kind: .classType,
                      location: location(owner, 1), endLocation: location(owner, 10)),
                .init(name: "labels", indexName: "labels", qualifiedName: "Screen.labels", kind: .property,
                      location: location(owner, 2), endLocation: location(owner, 3), objectiveCName: "labels"),
            ])
        }
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: InMemoryFileSystem(files: [resourcePath: resource]),
            indexProviderOverride: StaticIndexProvider(snapshot)
        ))
        let context = AnalysisContext(snapshot: snapshot,
            runtimeFiles: sourceFacts + service.runtimeResourceFacts(paths: [resourcePath]),
            runtimeFreshness: [
                sourcePath("FeatureA"): .fresh, sourcePath("FeatureB"): .fresh,
                testPath("FeatureA"): .fresh, testPath("FeatureB"): .fresh,
            ])
        let impact = try service.impactDocument(files: [resourceName], in: context)
        let affected = try service.affectedDocument(files: [resourceName], in: context)
        let selected: Set<String> = ["\(module)-screen", "\(module)-labels"]
        let consumers: Set<String> = ["\(module)-render", "\(module)-test"]

        let findings = context.runtimeDiscovery()?.findings.filter { $0.boundary.api == "outletCollection" }
        #expect(findings?.count == 1)
        if ["FeatureA", "FeatureB"].contains(module) {
            #expect(impact.status == "found")
            #expect(impact.selectionIssues.isEmpty)
            // 파일명·타입명·프로퍼티명이 모두 같아도 직접 선택과 전파 결과는 compiler module에 묶인다.
            #expect(Set(impact.selected.compactMap(\.usr)) == selected)
            #expect(Set(impact.affected.compactMap(\.symbol.usr)) == consumers)
            #expect(impact.tests.map(\.usr) == ["\(module)-test"])
            #expect(Set(affected.selected.map(\.usr)) == selected)
            #expect(affected.tests.map(\.symbol.usr) == ["\(module)-test"])
            #expect(affected.selectionIssues.isEmpty)
            #expect(findings?.first?.targets == [NodeID("\(module)-labels")])
        } else {
            #expect(impact.status == "incomplete")
            #expect(affected.status == "incomplete")
            for issues in [impact.selectionIssues, affected.selectionIssues] {
                #expect(issues.count == 1)
                #expect(issues.first?.requested == resourcePath)
                #expect(issues.first?.kind == "file")
                #expect(issues.first?.status == "unindexed")
            }
            #expect(impact.selected.isEmpty)
            #expect(impact.affected.isEmpty)
            #expect(impact.tests.isEmpty)
            #expect(affected.selected.isEmpty)
            #expect(affected.tests.isEmpty)
            #expect(findings?.first?.targets.isEmpty == true)
            #expect(findings?.first?.status == (module.isEmpty ? .ambiguous : .unresolved))
        }
    }
}
