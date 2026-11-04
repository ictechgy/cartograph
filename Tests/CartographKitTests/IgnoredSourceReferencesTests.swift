import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("Git 이 무시한 컴파일 소스의 참조")
struct IgnoredSourceReferencesTests {
    @Test("무시 파일 밖 선언을 쓰는 참조만 대상으로 고른다")
    func targetsOnlyUsagesLeavingIgnoredFiles() {
        var builder = SnapshotBuilder(path: "/p/Generated.swift")
        builder.symbol("generated", kind: .function)
        builder.symbol("generatedType", kind: .structType)
        builder.symbol("generatedExtension", kind: .extensionDeclaration)
        builder.reference(from: "generated", to: "helper", kind: .call)
        builder.reference(from: "generated", to: "Model", kind: .reference)
        builder.reference(from: "generatedType", to: "Requestable", kind: .conformance)
        // 파일 안의 참조와 익스텐션은 대상을 쓰지 않는다. 생성기가 모든 타입을 넓히면 미사용 타입이 살아남는다.
        builder.reference(from: "generated", to: "generatedType", kind: .reference)
        builder.reference(from: "generatedExtension", to: "Unused", kind: .extends)
        #expect(IgnoredSourceReferences.targets(in: builder.build()) == ["helper", "Model", "Requestable"])
    }

    @Test("링크를 풀면 추적 소스인 무시 경로는 보조 근거에서 뺀다")
    func ignoredLinksToTrackedSourcesAreExcluded() throws {
        // 무시된 링크가 추적 파일을 가리키면 그 파일은 본 분석이 이미 읽는다. 다시 세면 죽은 추적 코드가 부르는
        // 선언까지 "무시 소스가 쓴다" 로 살아남는다.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ignored-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracked = directory.appendingPathComponent("Tracked.swift")
        let generated = directory.appendingPathComponent("Generated.swift")
        let link = directory.appendingPathComponent("Linked.swift")
        try "struct Tracked {}\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "struct Generated {}\n".write(to: generated, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tracked)

        let kept = IgnoredSourceReferences.untrackedSources(
            ignored: [generated.path, link.path], tracked: [tracked.path])
        #expect(kept == [generated.path])
    }

    @Test("대상 선언에만 표식을 붙이고 대상이 없으면 스냅샷을 그대로 둔다")
    func marksOnlyTargets() {
        var builder = SnapshotBuilder()
        builder.symbol("helper", kind: .function)
        builder.symbol("other", kind: .function)
        let snapshot = builder.build()
        let marked = IgnoredSourceReferences.marking(snapshot, targets: ["helper"])
        #expect(marked.symbols.first { $0.usr == "helper" }?.attributes.contains(.referencedFromIgnoredSource) == true)
        #expect(marked.symbols.first { $0.usr == "other" }?.attributes.contains(.referencedFromIgnoredSource) == false)
        #expect(IgnoredSourceReferences.marking(snapshot, targets: []) == snapshot)
    }

    @Test("무시된 생성 파일만 부르는 앱 코드를 미사용으로 보고하지 않는다")
    func helperCalledOnlyFromIgnoredGeneratedFileIsRetained() throws {
        // R.swift·SwiftGen 출력처럼 `.gitignore` 에 둔 생성 파일만 helper 를 부른다. 발견에서 빼기만 하던 때는
        // helper 가 호출자를 잃고 unreachable 이었다. 지우면 생성 코드가 컴파일되지 않는다.
        let fileSystem = LocalFileSystem()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = try fileSystem.realPath(at: temporary.path)
        try fileSystem.write(Data("Generated.swift\n".utf8), to: root + "/.gitignore")
        try fileSystem.write(Data("func helper() {}\nfunc unused() {}\n".utf8), to: root + "/App.swift")
        try fileSystem.write(Data("func generated() { helper() }\n".utf8), to: root + "/Generated.swift")
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-c", "core.hooksPath=/dev/null", "-C", root, "init", "-q"]
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)

        var builder = SnapshotBuilder(path: root + "/App.swift")
        builder.symbol("helper", name: "helper()", kind: .function, line: 1)
        builder.symbol("unused", name: "unused()", kind: .function, line: 2)
        builder.symbol("generated", name: "generated()", kind: .function, path: root + "/Generated.swift")
        builder.reference(from: "generated", to: "helper", kind: .call, path: root + "/Generated.swift")
        var configuration = CartographConfiguration.default
        configuration.projectPath = root
        let service = CartographService(configuration: configuration, environment: .init(
            fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(builder.build()),
            usesSyntaxCache: false))
        let context = try service.loadContext()
        #expect(context.projectFileInventory?.ignoredSourceFiles.map { URL(fileURLWithPath: $0).lastPathComponent }
            == ["Generated.swift"])
        let report = service.unusedCode(in: context).report
        #expect(report.retentions[NodeID("helper")] == .ignoredSourceReference)
        #expect(report.unused.map(\.id).contains(NodeID("unused")))
        #expect(!report.unused.map(\.id).contains(NodeID("helper")))
    }
}
