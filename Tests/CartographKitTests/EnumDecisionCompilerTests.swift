import CartographAnalysis
import CartographCore
import CartographIndexStore
import CartographSyntax
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("실제 컴파일러의 enum 결정 근거", .serialized)
struct EnumDecisionCompilerTests {
    @Test("일반 Array contains와 부정 및 default를 정확한 enum에 결합한다")
    func standardMembershipAndFallback() throws {
        let source = """
        public enum Status: Equatable { case a, b, c }
        public func allows(_ status: Status) -> Bool {
            [Status.a, .b].contains(status)
        }
        public func denies(_ status: Status) -> Bool {
            ![Status.a, .b].contains(status)
        }
        public func fallback(_ status: Status) -> Bool {
            switch status {
            case .a: return true
            case .b: return true
            default: return false
            }
        }
        """
        let excludedSource = """
        public func excluded(_ status: Status) -> Bool { [Status.a, .b].contains(status) }
        """
        let fixture = try compile(source, extraSource: excludedSource)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try load(fixture)
        let enriched = SnapshotEnricher(fileSystem: LocalFileSystem()).enrichWithDiagnostics(snapshot).snapshot
        let facts = try #require(enriched.enumImpactFiles?.first { $0.path == fixture.path })
        #expect(facts.status == "fresh", "\(facts.limitations)")
        let inventory = try #require(facts.inventories.first)
        #expect(inventory.complete)
        #expect(inventory.caseUSRs.count == 3)
        let positive = try #require(facts.decisions.first { $0.kind == .literalMembership })
        let negative = try #require(facts.decisions.first { $0.kind == .negatedLiteralMembership })
        let fallback = try #require(facts.decisions.first { $0.kind == .switchDefault })
        for decision in [positive, negative, fallback] {
            #expect(decision.status == "resolved", "\(decision.operationTargetUSRs) \(decision.limitations)")
            #expect(decision.enumUSR == inventory.enumUSR)
            #expect(decision.explicitCaseUSRs.count == 2)
            #expect(decision.ownerUSR != nil)
        }
        // This verifies the production model against real compiler records, not a mocked USR.
        #expect(positive.operationTargetUSRs == ["s:STsSQ7ElementRpzrlE8containsySbABF"])
        #expect(Set(negative.operationTargetUSRs) == [
            "s:STsSQ7ElementRpzrlE8containsySbABF", "s:Sb1nopyS2bFZ",
        ])
        let baseline = try compile(source.replacingOccurrences(of: "case a, b, c", with: "case a, b"),
            extraSource: excludedSource)
        defer { try? FileManager.default.removeItem(at: baseline.root) }
        let before = SnapshotEnricher(fileSystem: LocalFileSystem()).enrichWithDiagnostics(try load(baseline)).snapshot
        try verifyComparison(fixture: fixture, source: source, snapshot: snapshot, before: before,
            baselineRoot: (baseline.path as NSString).deletingLastPathComponent, inventory: inventory)

    }

    @Test("사용자 contains와 다른 타입의 패턴 매칭을 표준 enum 결정으로 가장하지 않는다")
    func customMembershipIsUnresolved() throws {
        let fixture = try compile("""
        public enum Status: Equatable { case a, b }
        extension Array where Element == Status {
            public func contains(_ status: Status) -> Bool { true }
        }
        public func custom(_ status: Status) -> Bool {
            [Status.a].contains(status)
        }
        public func ~= (pattern: Status, value: Int) -> Bool { true }
        public func unrelated(_ number: Int) -> Bool {
            switch number {
            case Status.a: return true
            default: return false
            }
        }
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try load(fixture)
        let enriched = SnapshotEnricher(fileSystem: LocalFileSystem()).enrichWithDiagnostics(snapshot).snapshot
        let decision = try #require(enriched.enumImpactFiles?.flatMap(\.decisions).first {
            $0.kind == .literalMembership
        })
        #expect(decision.status == "unresolved")
        #expect(decision.enumUSR != nil)
        #expect(decision.explicitCaseUSRs.count == 1)
        #expect(decision.limitations.contains("unsupported-or-unresolved-membership-target"))
        let pattern = try #require(enriched.enumImpactFiles?.flatMap(\.decisions).first { $0.kind == .switchDefault })
        #expect(pattern.status == "unresolved")
        #expect(pattern.limitations.contains("unverified-switch-subject-type"))
    }

    /// Paired real compiler captures exercise identity, persistence, relocation and public output.
    private func verifyComparison(fixture: Fixture, source: String, snapshot: IndexSnapshot,
                                  before: IndexSnapshot, baselineRoot: String,
                                  inventory: EnumCaseInventory) throws {
        let added = try #require(snapshot.symbols.first {
            $0.kind == .enumCase && $0.parentUSR == inventory.enumUSR && $0.name == "c"
        })
        #expect(before.symbols.contains { $0.usr == inventory.enumUSR && $0.kind == .enumType })
        #expect(!before.symbols.contains { $0.usr == added.usr })
        let root = (fixture.path as NSString).deletingLastPathComponent
        let fileSystem = InMemoryFileSystem(currentDirectoryPath: root, files: fixture.sources)
        for path in fixture.sources.keys {
            fileSystem.setModificationDate(Date(timeIntervalSince1970: 1), for: path)
        }
        let baselinePath = root + "/before.json"
        try fileSystem.write(JSONEncoder.cartographDefault().encode(
            AnalysisSnapshotDocument(projectRoot: baselineRoot, snapshot: before)), to: baselinePath)
        var configuration = CartographConfiguration.default
        configuration.projectPath = root
        let unfiltered = CartographService(configuration: configuration,
            environment: .init(fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot)),
            allowsEmptyIndex: true)
        let all = try unfiltered.compareImpact(symbols: [inventory.enumUSR], files: [], beforePath: baselinePath,
            maxDepth: nil, limit: 100, format: "json")
        let allDocument = try JSONDecoder().decode(ImpactComparisonDocument.self, from: Data(all.output.utf8))
        #expect(allDocument.enumChangeReview?.candidateCount == 4)
        configuration.exclude.append(GlobPattern("Excluded.swift"))
        let service = CartographService(configuration: configuration,
            environment: .init(fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot)),
            allowsEmptyIndex: true)
        func compare(_ format: String, symbols: [String]? = nil, files: [String] = []) throws -> CommandOutcome {
            try service.compareImpact(symbols: symbols ?? [inventory.enumUSR], files: files, beforePath: baselinePath,
                maxDepth: nil, limit: 100, format: format)
        }
        let json = try compare("json")
        let decoded = try JSONDecoder().decode(ImpactComparisonDocument.self, from: Data(json.output.utf8))
        #expect(decoded.enumChangeReview?.candidateCount == 3)
        #expect(decoded.enumChangeReview?.candidates.allSatisfy { !$0.location.path.hasSuffix("/Excluded.swift") } == true)
        #expect(decoded.enumChangeReview?.issues.allSatisfy { $0.path?.hasSuffix("/Excluded.swift") != true } == true)
        #expect(decoded.enumChangeReview?.changes.first?.addedCases.map(\.usr) == [added.usr])
        #expect(try compare("json").output == json.output)
        for outcome in [
            try compare("json", symbols: [added.usr]),
            try compare("json", symbols: [], files: [fixture.path]),
        ] {
            let selected = try JSONDecoder().decode(ImpactComparisonDocument.self, from: Data(outcome.output.utf8))
            #expect(selected.enumChangeReview?.changeCount == 1)
            #expect(selected.enumChangeReview?.candidateCount == 3)
            #expect(selected.enumChangeReview?.changes.first?.enumUSR == inventory.enumUSR)
        }
        let text = try compare("text").output
        #expect(text.contains("enum change review: review, 1 expanded enums, 3 candidates"))
        #expect(text.contains("literalMembership"))
        #expect(text.contains("negatedLiteralMembership"))
        #expect(try compare("text").output == text)
    }

    private struct Fixture {
        let root: URL
        let path: String
        let store: String
        let library: String
        let sources: [String: String]
    }

    private func compile(_ text: String, extraSource: String? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-enum-decisions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let source = root.appendingPathComponent("Decisions.swift")
            try Data(text.utf8).write(to: source)
            var inputNames = [source.lastPathComponent]
            var sources = [try LocalFileSystem().realPath(at: source.path): text]
            if let extraSource {
                let extra = root.appendingPathComponent("Excluded.swift")
                try Data(extraSource.utf8).write(to: extra)
                inputNames.append(extra.lastPathComponent)
                sources[try LocalFileSystem().realPath(at: extra.path)] = extraSource
            }
            let store = root.appendingPathComponent("IndexStore").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.currentDirectoryURL = root
            process.arguments = [
                "swiftc", "-module-name", "EnumDecisions", "-parse-as-library",
                "-whole-module-optimization", "-emit-object",
            ] + inputNames + ["-o", "Decisions.o", "-index-store-path", store]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "EnumDecisionCompilerTests", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message])
            }
            return Fixture(root: root, path: try LocalFileSystem().realPath(at: source.path), store: store,
                library: try IndexStoreLocator().locateLibrary(explicitPath: nil, developerDirectory: nil),
                sources: sources)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func load(_ fixture: Fixture) throws -> IndexSnapshot {
        try IndexStoreProvider(configuration: .init(
            storePath: fixture.store, databasePath: fixture.root.appendingPathComponent("UnusedDB").path,
            libraryPath: fixture.library, sourceRoots: [fixture.root.path],
            includeExternalSymbols: false, readerMode: .raw
        )).loadSnapshot()
    }
}
