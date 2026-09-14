import CartographConfig
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("Core Data 모델 리소스 열거")
struct CoreDataRuntimeDiscoveryTests {
    @Test("현재 버전 포인터가 지정한 모델만 확정하고 이전 버전의 이동 가능성은 남긴다")
    func usesExplicitCurrentVersionWithoutDroppingMigrationInputs() throws {
        let fileSystem = versionedFileSystem()
        let marker = "/p/Versions.xcdatamodeld/.xccurrentversion"
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["_XCCurrentVersionName": "V2.xcdatamodel"], format: .binary, options: 0
        )
        try fileSystem.write(data, to: marker)
        let facts = service(fileSystem).runtimeResourceFacts()
        #expect(facts.first { $0.path.contains("V2.xcdatamodel/") }?.boundaries.first?.reason == nil)
        #expect(facts.first { $0.path.contains("V1.xcdatamodel/") }?.boundaries.first?.reason?
            .contains("migration") == true)
        #expect(facts.contains { $0.path == marker })
    }

    @Test("깨진 포인터와 경로 탈출 또는 없는 버전은 다른 모델로 대체하지 않는다")
    func rejectsInvalidCurrentVersionPointers() throws {
        for value in ["../V2.xcdatamodel", "/p/V2.xcdatamodel", "Missing.xcdatamodel", "V2", ""] {
            let fileSystem = versionedFileSystem()
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["_XCCurrentVersionName": value], format: .xml, options: 0
            )
            try fileSystem.write(data, to: "/p/Versions.xcdatamodeld/.xccurrentversion")
            let facts = service(fileSystem).runtimeResourceFacts()
            let models = facts.filter { $0.path.hasSuffix("/contents") }
            #expect(models.count == 2)
            #expect(models.allSatisfy { $0.boundaries.first?.reason != nil })
            #expect(facts.flatMap(\.limitations).contains { $0.contains("current version") })
        }
        let fileSystem = versionedFileSystem()
        try fileSystem.write(text: "not a plist", to: "/p/Versions.xcdatamodeld/.xccurrentversion")
        #expect(service(fileSystem).runtimeResourceFacts().flatMap(\.limitations)
            .contains { $0.contains("current version") })
    }

    private func versionedFileSystem() -> InMemoryFileSystem {
        InMemoryFileSystem(files: [
            "/p/Versions.xcdatamodeld/V1.xcdatamodel/contents": model(entity: "First"),
            "/p/Versions.xcdatamodeld/V2.xcdatamodel/contents": model(entity: "Second"),
        ])
    }

    @Test("필터로 한 버전만 남아도 제외된 현재 버전 포인터를 추측하지 않는다")
    func excludedVersionSelectionDoesNotPromoteTheRemainingModel() throws {
        let fileSystem = versionedFileSystem()
        try fileSystem.write(text: """
            <plist version="1.0"><dict><key>_XCCurrentVersionName</key><string>V2.xcdatamodel</string></dict></plist>
            """, to: "/p/Versions.xcdatamodeld/.xccurrentversion")
        let facts = service(fileSystem, include: ["Versions.xcdatamodeld/V1.xcdatamodel/contents"])
            .runtimeResourceFacts()
        #expect(facts.count == 1)
        #expect(facts.first?.boundaries.first?.reason?.contains("current version") == true)
        #expect(facts.first?.boundaries.first?.receiverTypeName == nil)
    }

    @Test("포인터가 선택한 버전이 제외되면 포함된 다른 버전을 쓰지 않는다")
    func excludedSelectedModelDoesNotFallBack() throws {
        let fileSystem = versionedFileSystem()
        try fileSystem.write(text: """
            <plist version="1.0"><dict><key>_XCCurrentVersionName</key><string>V2.xcdatamodel</string></dict></plist>
            """, to: "/p/Versions.xcdatamodeld/.xccurrentversion")
        let facts = service(fileSystem, include: [
            "Versions.xcdatamodeld/.xccurrentversion", "Versions.xcdatamodeld/V1.xcdatamodel/contents",
        ]).runtimeResourceFacts()
        #expect(facts.count == 2)
        #expect(facts.flatMap(\.boundaries).allSatisfy { $0.reason?.contains("excluded") == true })
    }

    private func service(_ fileSystem: InMemoryFileSystem, include: [String] = []) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.include = include.map { GlobPattern($0) }
        return CartographService(configuration: configuration,
            environment: .init(fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(.init())))
    }

    @Test("xcdatamodel contents만 읽고 여러 xcdatamodeld 버전은 모두 미확정으로 남긴다")
    func enumeratesModelContentsConservatively() {
        let fileSystem = InMemoryFileSystem(files: [
            "/p/Single.xcdatamodel/contents": model(entity: "Single"),
            "/p/Versions.xcdatamodeld/V1.xcdatamodel/contents": model(entity: "First"),
            "/p/Versions.xcdatamodeld/V2.xcdatamodel/contents": model(entity: "Second"),
            "/p/Documentation/contents": model(entity: "Ignored"),
        ])
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(
            configuration: configuration,
            environment: .init(fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(.init()))
        )

        let facts = service.runtimeResourceFacts().filter { $0.path.hasSuffix("/contents") }
        #expect(facts.count == 3)
        #expect(facts.first { $0.path.contains("Single") }?.boundaries.first?.reason == nil)
        let versioned = facts.filter { $0.path.contains("Versions.xcdatamodeld") }
        #expect(versioned.count == 2)
        #expect(versioned.allSatisfy { $0.boundaries.first?.reason?.contains("current version") == true })
        #expect(!facts.contains { $0.path.contains("Documentation") })
    }

    private func model(entity: String) -> String {
        "<model><entity name=\"\(entity)\" representedClassName=\"App.\(entity)\"/></model>"
    }
}
