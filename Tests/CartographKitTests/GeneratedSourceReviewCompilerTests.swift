import CartographAnalysis
import CartographCore
import CartographIndexStore
import CartographKit
import CartographSyntax
import Dispatch
import Foundation
import Testing

@Suite("실제 생성 헤더 검토는 findings와 간선을 그대로 둔다", .serialized)
struct GeneratedSourceReviewCompilerTests: Sendable {
    @Test("컴파일한 generated와 수동 토큰 및 filename 대조군의 전체 판정을 보존한다")
    func reviewPreservesCompilerGraphAndFindings() async throws {
        let fixture = try await blocking { try self.compileFixture() }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raw = try await blocking { try self.load(fixture) }
        let snapshot = SnapshotEnricher(fileSystem: LocalFileSystem()).enrichWithDiagnostics(raw).snapshot
        let context = AnalysisContext(snapshot: snapshot)
        let service = CartographService(configuration: .init(projectPath: fixture.root.path),
            environment: .init(fileSystem: LocalFileSystem()))
        let before = service.unusedCode(in: context)
        let expected = ["filenameUnused()", "generatedUnused()", "manualToken()"]
        #expect(before.report.unused.map(\.name).sorted() == expected)
        let live = try #require(snapshot.symbols.first { $0.name == "liveGenerated()" && !$0.isExternal })
        let token = try #require(snapshot.symbols.first { $0.name == "usedToken()" && !$0.isExternal })
        #expect(before.graph.outgoingEdges(from: NodeID(live.usr)).contains {
            $0.target == NodeID(token.usr) && $0.kind == .call
        })
        let diagnostics = AnalysisDiagnostics.diagnostics(for: before.report)
        let review = try service.findingReviewDocument(diagnostics: diagnostics,
            options: .init(inspectGeneratedHeaders: true))
        #expect(review.diagnostics == diagnostics)
        #expect(review.findingCount == 3)
        #expect(review.files.count == 3)
        let marked = review.files.filter { $0.generatedMarker?.status == .markerObserved }
        #expect(marked.count == 1)
        #expect(marked.first?.path.hasSuffix("/Generated.swift") == true)
        #expect(marked.first?.generatedMarker?.fileStableDuringRead == true)
        #expect(review.files.filter { $0.generatedMarker?.status == .noMarkerInHeader }.count == 2)
        let after = service.unusedCode(in: context)
        #expect(after.report.unused.map(\.name).sorted() == expected)
        #expect(AnalysisDiagnostics.diagnostics(for: after.report) == diagnostics)
        #expect(after.graph.nodes == before.graph.nodes)
        #expect(after.graph.edges == before.graph.edges)
    }

    private struct Fixture: Sendable {
        let root: URL
        let store: String
        let library: String
    }

    private func compileFixture() throws -> Fixture {
        let fs = LocalFileSystem()
        let requested = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-followup-generated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: try fs.realPath(at: requested.path))
        do {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Fixtures/FollowupGeneratedReview")
            let names = ["Generated.swift", "DesignTokens.swift", "NeedleGenerated.swift", "Main.swift"]
            for name in names {
                try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                    to: root.appendingPathComponent(name))
            }
            let store = root.appendingPathComponent("IndexStore").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.currentDirectoryURL = root
            process.arguments = ["swiftc", "-module-name", "GeneratedReview", "-parse-as-library", "-emit-library"]
                + names + ["-o", "libGeneratedReview.dylib", "-index-store-path", store]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw NSError(domain: "GeneratedSourceReviewCompilerTests", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message])
            }
            return .init(root: root, store: store,
                library: try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func load(_ fixture: Fixture) throws -> IndexSnapshot {
        try IndexStoreProvider(configuration: .init(storePath: fixture.store,
            databasePath: fixture.root.appendingPathComponent("UnusedDB").path, libraryPath: fixture.library,
            sourceRoots: [fixture.root.path], includeExternalSymbols: true, readerMode: .raw)).loadSnapshot()
    }

    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
