import CartographAnalysis
import CartographCore
import CartographIndexStore
import CartographSyntax
import CartographKit
import Foundation
import Dispatch
import Testing

@Suite("실제 컴파일러의 외부 프로퍼티 증인 접근", .serialized)
struct AssignOnlyCompilerTests: Sendable {
    @Test("존재 타입의 요구사항 읽기를 구현 프로퍼티의 읽기 누락으로 보고하지 않는다")
    func externalRequirementReadProtectsWitness() async throws {
        let source = """
        public struct Box: CustomStringConvertible {
            public var description: String
            public var plain: String
            public init(_ text: String) {
                description = text
                plain = text
            }
        }
        public func readDescription(_ value: any CustomStringConvertible) -> String {
            return value.description
        }
        public func exercise() -> String {
            var value = Box("before")
            value.description = "after"
            value.plain = "after"
            return readDescription(value)
        }
        """
        let fixture = try await blocking("compile") { try self.compile(source) }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raw = try await blocking("raw-load") { try self.load(fixture) }
        Self.mark("enrich.begin")
        let snapshot = SnapshotEnricher(fileSystem: LocalFileSystem()).enrichWithDiagnostics(raw).snapshot
        Self.mark("enrich.end")

        let owner = try #require(snapshot.symbols.first {
            $0.name == "Box" && $0.kind == .structType && !$0.isExternal
        })
        let witness = try #require(snapshot.symbols.first {
            $0.name == "description" && $0.kind == .property && $0.parentUSR == owner.usr
        })
        let plain = try #require(snapshot.symbols.first {
            $0.name == "plain" && $0.kind == .property && $0.parentUSR == owner.usr
        })
        let reader = try #require(snapshot.symbols.first {
            $0.name == "readDescription(_:)" && !$0.isExternal
        })
        // 실제 관계와 접근 근거를 먼저 확인한다. 빈 인덱스나 합성한 사실로 판정을 통과시키지 않는다.
        let relation = try #require(raw.references.first {
            $0.sourceUSR == witness.usr && $0.kind == .overrides && $0.origin == .compiler
        })
        let requirement = try #require(raw.symbols.first { $0.usr == relation.targetUSR })
        #expect(requirement.isExternal)
        #expect(requirement.kind == .property)
        #expect(requirement.name == "description")
        let existentialRead = try #require(raw.references.first {
            $0.sourceUSR == reader.usr && $0.targetUSR == requirement.usr && $0.origin == .compiler
                && $0.location?.path == fixture.path && $0.location?.line == 10
        })
        #expect(existentialRead.kind == .reference || existentialRead.kind == .call)
        let requirementAccess = try #require(raw.propertyAccesses[requirement.usr])
        #expect(requirementAccess.hasRead || requirementAccess.hasAmbiguous)
        #expect(!witness.attributes.contains(.overrideDeclaration))
        try #require(raw.propertyAccesses[witness.usr]?.isAssignOnly == true)
        try #require(raw.propertyAccesses[plain.usr]?.isAssignOnly == true)
        #expect(snapshot.propertyAccesses == raw.propertyAccesses)

        let graph = GraphBuilder(options: .init(level: .symbol, includeExternal: false)).build(from: snapshot)
        try #require(!graph.contains(NodeID(requirement.usr)))
        try #require(graph.outgoingEdges(from: NodeID(witness.usr)).allSatisfy { $0.kind != .overrides })
        let report = ReachabilityAnalyzer(policy: RetentionPolicy(options: .init(retainPublic: true)))
            .analyze(graph: graph, snapshot: snapshot)
        try #require(report.retentions[NodeID(witness.usr)] != nil)
        try #require(report.retentions[NodeID(plain.usr)] != nil)

        // 일반 대입 전용 저장소는 계속 보고해야 하므로 무조건 빈 결과를 반환하는 수정은 실패한다.
        #expect(report.assignOnly.map(\.id) == [NodeID(plain.usr)])
        #expect(!report.unused.contains { $0.id == NodeID(witness.usr) })
    }

    // 컴파일과 raw reader의 동기 대기를 cooperative executor 밖에서 수행한다.
    // 단언은 원래 테스트 태스크에 남겨 실패 귀속을 보존한다.
    private func blocking<T: Sendable>(
        _ name: String, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        Self.mark("\(name).begin")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value = try body()
                    Self.mark("\(name).end")
                    continuation.resume(returning: value)
                } catch {
                    Self.mark("\(name).failed")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func mark(_ phase: String) {
        FileHandle.standardError.write(Data("AssignOnlyCompilerPhase \(phase)\n".utf8))
    }

    private struct Fixture: Sendable {
        let root: URL
        let path: String
        let store: String
        let library: String
    }

    private func compile(_ source: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-assign-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let path = root.appendingPathComponent("Witness.swift")
            try Data(source.utf8).write(to: path)
            let store = root.appendingPathComponent("IndexStore").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.currentDirectoryURL = root
            process.arguments = [
                "swiftc", "-module-name", "AssignOnlyWitness", "-parse-as-library",
                "-emit-object", path.lastPathComponent, "-o", "Witness.o", "-index-store-path", store,
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw NSError(domain: "AssignOnlyCompilerTests", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message])
            }
            return Fixture(
                root: root, path: try LocalFileSystem().realPath(at: path.path), store: store,
                library: try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil)
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func load(_ fixture: Fixture) throws -> IndexSnapshot {
        try IndexStoreProvider(configuration: .init(
            storePath: fixture.store, databasePath: fixture.root.appendingPathComponent("UnusedDB").path,
            libraryPath: fixture.library, sourceRoots: [fixture.root.path],
            includeExternalSymbols: true, readerMode: .raw
        )).loadSnapshot()
    }
}
