import CartographAnalysis
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("주입된 레이어 프로젝트 경로")
struct LayerRuleProjectPathsTests {
    @Test("실제 tmp 별칭과 끝 슬래시를 환경에서 확인한다")
    func actualSystemAliases() {
        let roots = LayerRuleProjectPaths.confirmed(
            projectPath: "/tmp/LayerProject/", fileSystem: LocalFileSystem()
        )
        let evaluator = evaluator(projectPaths: roots)
        #expect(evaluator.layer(of: node(path: "/private/tmp/LayerProject/Features/Home.swift")) == "UI")
    }

    @Test("실제 심볼릭 링크 루트를 확인한 뒤 순수 판정에 전달한다")
    func actualSymbolicLinkRoot() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: directory) }
        let physical = directory.appendingPathComponent("physical")
        try manager.createDirectory(at: physical, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: physical)
        let roots = LayerRuleProjectPaths.confirmed(projectPath: alias.path, fileSystem: LocalFileSystem())
        let evaluator = evaluator(projectPaths: roots)
        let subject = node(path: physical.appendingPathComponent("Features/Home.swift").path)
        #expect(evaluator.layer(of: subject) == "UI")
        #expect(evaluator.assignment(of: subject).match?.candidate == "Features/Home.swift")
    }

    @Test("호스트에 없는 별칭도 주입된 메모리 파일 시스템만으로 확인한다")
    func injectedAliasesAndCurrentDirectory() {
        let storage = InMemoryFileSystem(currentDirectoryPath: "/virtual", files: [
            "/physical/Features/Home.swift": "struct Home {}",
        ])
        let fileSystem = AliasFileSystem(storage: storage, aliases: ["/virtual/link": "/physical"])
        let roots = LayerRuleProjectPaths.confirmed(projectPath: "link", fileSystem: fileSystem)
        #expect(roots.contains("link"))
        #expect(roots.contains("/virtual/link"))
        #expect(roots.contains("/physical"))
        #expect(!roots.contains("/private/physical"))
        #expect(evaluator(projectPaths: roots).layer(of: node(path: "/physical/Features/Home.swift")) == "UI")
    }

    @Test("서로 다른 private 디렉터리는 별칭 준비 단계에서도 합치지 않는다")
    func unrelatedPrivatePrefixIsNotPrepared() {
        let storage = InMemoryFileSystem(files: [
            "/project/Features/Home.swift": "struct Home {}",
            "/private/project/Features/Home.swift": "struct ExternalHome {}",
        ])
        let memory = AliasFileSystem(storage: storage, aliases: [:])
        for fileSystem in [memory as any FileSystem, LocalFileSystem()] {
            let roots = LayerRuleProjectPaths.confirmed(projectPath: "/project", fileSystem: fileSystem)
            #expect(!roots.contains("/private/project"))
            let evaluator = LayerRuleEvaluator(layers: [
                .init(name: "UI", patterns: ["Features/**"]),
                .init(name: "External", patterns: ["/private/project/Features/**"]),
            ], rules: [], projectPaths: roots)
            #expect(evaluator.layer(of: node(path: "/private/project/Features/Home.swift")) == "External")
        }
    }

    @Test("확인할 수 없는 별칭은 원래 리터럴 루트로 확대하지 않는다")
    func unavailableResolutionKeepsOnlyLiteralRoot() {
        let storage = InMemoryFileSystem(files: ["/project/Features/Home.swift": "struct Home {}"])
        let fileSystem = AliasFileSystem(storage: storage, aliases: [:], permitsResolution: false)
        let roots = LayerRuleProjectPaths.confirmed(projectPath: "/project", fileSystem: fileSystem)
        #expect(roots == ["/project"])
        #expect(evaluator(projectPaths: roots).layer(of: node(path: "/project/Features/Home.swift")) == "UI")
        #expect(evaluator(projectPaths: roots).layer(of: node(path: "/private/project/Features/Home.swift")) == nil)
    }

    @Test("일반 규칙 검사와 설명이 같은 주입된 별칭을 사용한다")
    func serviceAssessmentAndExplanationUseInjectedAliases() throws {
        let storage = InMemoryFileSystem(files: [
            "/physical/Features/Screen.swift": "struct Screen {}",
            "/physical/Data/Store.swift": "struct Store {}",
        ])
        let fileSystem = AliasFileSystem(storage: storage, aliases: ["/virtual/link": "/physical"])
        var snapshot = SnapshotBuilder()
        snapshot.symbol("Screen", kind: .structType, module: "App", path: "/physical/Features/Screen.swift")
        snapshot.symbol("Store", kind: .structType, module: "App", path: "/physical/Data/Store.swift")
        snapshot.reference(from: "Screen", to: "Store", kind: .call, path: "/physical/Features/Screen.swift", line: 42)
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/virtual/link"
        configuration.layers = [
            .init(name: "UI", patterns: ["Features/**"]), .init(name: "Data", patterns: ["Data/**"]),
        ]
        configuration.rules = [.init(from: "UI", deny: ["Data"])]
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot.build())
        ))
        let outcome = try service.checkRules(level: .type)
        #expect(outcome.findingCount == 1)
        let context = try service.loadContext()
        let assessed = try service.layerViolations(in: context, level: .type)
        #expect(assessed.violations.first?.location?.line == 42)
        let explained = try service.explainRules(of: "Screen", level: .type)
        #expect(explained.output.contains("is in layer 'UI'"))
        #expect(explained.output.contains("matched: Features/Screen.swift against 'Features/**'"))
    }

    private func evaluator(projectPaths: [String]) -> LayerRuleEvaluator {
        LayerRuleEvaluator(layers: [.init(name: "UI", patterns: ["Features/**"])],
            rules: [], projectPaths: projectPaths)
    }

    private func node(path: String) -> GraphNode {
        GraphNode(id: "n", name: "Home", kind: .structType, module: "App",
            location: .init(path: path, line: 1, column: 1))
    }
}

/// 가상 경로만 읽으므로 실제 호스트의 링크·현재 디렉터리·stat에 의존하면 테스트가 실패한다.
private struct AliasFileSystem: FileSystem {
    let storage: InMemoryFileSystem
    let aliases: [String: String]
    var permitsResolution = true

    var currentDirectoryPath: String { storage.currentDirectoryPath }

    func realPath(at path: String) throws -> String {
        let translated = translate(path)
        guard permitsResolution,
              storage.directoryExists(at: translated) || storage.fileExists(at: translated) else {
            throw CocoaError(.featureUnsupported)
        }
        return translated
    }

    func fileExists(at path: String) -> Bool { storage.fileExists(at: translate(path)) }
    func directoryExists(at path: String) -> Bool { storage.directoryExists(at: translate(path)) }
    func readData(at path: String) throws -> Data { try storage.readData(at: translate(path)) }
    func write(_ data: Data, to path: String) throws { try storage.write(data, to: translate(path)) }
    func contentsOfDirectory(at path: String) throws -> [String] {
        try storage.contentsOfDirectory(at: translate(path))
    }
    func directoryEntries(at path: String, maximumEntries: Int) throws -> [DirectoryEntry] {
        try storage.directoryEntries(at: translate(path), maximumEntries: maximumEntries)
    }

    private func translate(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : currentDirectoryPath + "/" + path
        for alias in aliases.keys.sorted() {
            if absolute == alias || absolute.hasPrefix(alias + "/") {
                return aliases[alias]! + String(absolute.dropFirst(alias.count))
            }
        }
        return absolute
    }
}
