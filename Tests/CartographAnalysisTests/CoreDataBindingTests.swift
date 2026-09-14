import CartographCore
@testable import CartographAnalysis
import Testing

@Suite("Core Data 실제 클래스 이름 규칙")
struct CoreDataBindingTests {
    @Test("Swift bare name은 런타임 이름이 아니고 ObjC 별칭과 모듈 이름은 가능하다")
    func requiresActualRuntimeClassName() {
        #expect(resolve(name: "SwiftRecord", swiftName: "SwiftRecord", alias: "LegacyRecord").status == .unresolved)
        #expect(resolve(name: "LegacyRecord", swiftName: "SwiftRecord", alias: "LegacyRecord").status == .resolved)
        #expect(resolve(name: "App.SwiftRecord", swiftName: "SwiftRecord", alias: "LegacyRecord").status == .resolved)
    }

    @Test("category 생성은 런타임 별칭뿐 아니라 extension 대상 Swift 이름도 맞아야 한다")
    func generatedCategoryRequiresMatchingSwiftType() {
        #expect(resolve(name: "LegacyRecord", swiftName: "SwiftRecord", alias: "LegacyRecord",
            codeGeneration: "category").status == .unresolved)
        #expect(resolve(name: "App.SwiftRecord", swiftName: "SwiftRecord", alias: "LegacyRecord",
            codeGeneration: "category").status == .resolved)
        #expect(resolve(name: "LegacyRecord", swiftName: "LegacyRecord", alias: "LegacyRecord",
            codeGeneration: "category").status == .resolved)
    }

    private func resolve(
        name: String, swiftName: String, alias: String, codeGeneration: String? = nil
    ) -> RuntimeDiscoveryFinding {
        let location = SourceLocation(path: "/p/Record.swift", line: 1, column: 1)
        let snapshot = IndexSnapshot(symbols: [
            .init(usr: "record", name: swiftName, kind: .classType, module: "App", location: location),
        ], references: [
            .init(sourceUSR: "record", targetUSR: "c:objc(cs)NSManagedObject", kind: .inheritance),
        ])
        let boundary = RuntimeBoundary(
            kind: .coreDataEntityClass, api: "representedClassName",
            location: .init(path: "/p/Model.xcdatamodel/contents", line: 2, column: 1),
            name: name, nameOrigin: .resource, receiverTypeName: name, coreDataCodeGeneration: codeGeneration
        )
        let report = RuntimeDiscoveryResolver().resolve(files: [
            .init(path: location.path, declarations: [
                .init(name: swiftName, indexName: swiftName, qualifiedName: swiftName, kind: .classType,
                    location: location, endLocation: location, objectiveCName: alias),
            ], boundaries: [boundary]),
        ], snapshot: snapshot, graph: GraphBuilder(options: .init(level: .symbol)).build(from: snapshot),
            freshness: [location.path: .fresh])
        return report.findings[0]
    }
}
