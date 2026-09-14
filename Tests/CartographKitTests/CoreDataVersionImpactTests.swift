import CartographAnalysis
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Testing

@Suite("Core Data 버전 선택 영향")
struct CoreDataVersionImpactTests {
    @Test("현재 버전 선택 파일을 바꾸면 선택된 모델의 Swift 클래스로 영향을 시작한다")
    func markerSelectsCurrentModelClass() throws {
        let marker = "/p/Store.xcdatamodeld/.xccurrentversion"
        let source = "/p/Record.swift"
        let location = SourceLocation(path: source, line: 1, column: 1)
        let model = "/p/Store.xcdatamodeld/V2.xcdatamodel/contents"
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "record", name: "Record", kind: .classType, module: "App", location: location),
        ], references: [.init(sourceUSR: "record", targetUSR: "c:objc(cs)NSManagedObject", kind: .inheritance)])
        let facts = [
            RuntimeFileFacts(path: source, declarations: [
                .init(name: "Record", indexName: "Record", qualifiedName: "Record", kind: .classType,
                    location: location, endLocation: location),
            ]),
            RuntimeFileFacts(path: model, boundaries: [
                .init(kind: .coreDataEntityClass, api: "representedClassName",
                    location: .init(path: model, line: 2, column: 1), name: "App.Record",
                    nameOrigin: .resource, receiverTypeName: "App.Record"),
            ]),
            RuntimeFileFacts(path: marker),
        ]
        let context = AnalysisContext(snapshot: snapshot, runtimeFiles: facts, runtimeFreshness: [source: .fresh])
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration,
            environment: .init(fileSystem: InMemoryFileSystem(), indexProviderOverride: StaticIndexProvider(snapshot)))
        let document = try service.impactDocument(files: [marker], in: context)
        #expect(document.status == "found")
        #expect(document.selected.map(\.usr) == ["record"])
        let absent = AnalysisContext(snapshot: snapshot, runtimeFiles: Array(facts.dropLast()),
            runtimeFreshness: [source: .fresh])
        let missing = try service.impactDocument(files: [marker], in: absent)
        #expect(missing.status != "found")
    }
}
