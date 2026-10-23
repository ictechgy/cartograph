import CartographCore
@testable import CartographKit
import CartographTestSupport
import CryptoKit
import Foundation
import Testing

@Suite("영향 질의의 수신자 증거 신선도")
struct ImpactReceiverServiceTests {
    let path = "/p/Receiver.swift"
    let bytes = Data("captured synthetic fixture bytes".utf8)

    @Test("impact·affected가 같은 증거를 쓰고 이전 snapshot은 현재 증명을 쓰지 않는다")
    func currentAndHistorical() throws {
        let (service, context, _) = fixture()
        let current = try service.impactDocument(symbols: ["s:Changed.send"], in: context)
        #expect(!current.affected.contains { $0.symbol.usr == "s:siblingTest" })
        #expect(current.receiverPrecision?.mode == "bounded-final-self")
        #expect(current.receiverPrecision?.exclusions?.first?.requiredReceiver == "s:Changed")
        let affected = try service.affectedDocument(symbols: ["s:Changed.send"], in: context)
        #expect(!affected.tests.contains { $0.symbol.usr == "s:siblingTest" })
        #expect(affected.receiverPrecision == current.receiverPrecision)
        let historical = try service.impactDocument(symbols: ["s:Changed.send"], recordedLimitations: [], in: context)
        #expect(historical.affected.contains { $0.symbol.usr == "s:siblingTest" })
        #expect(historical.receiverPrecision == nil)
        #expect(historical.input?.mode == "historical-snapshot")
    }

    @Test("보관된 context라도 파일 변경·읽기 실패·파일 예산 초과는 후보를 되살린다")
    func rechecksHeldContext() throws {
        for condition in ["changed", "unreadable", "oversized"] {
            let (service, context, fs) = fixture()
            switch condition {
            case "changed": try fs.write(Data("different bytes".utf8), to: path)
            case "unreadable": fs.setReadError(.fileReadNoPermission, for: path)
            default: try fs.write(Data(repeating: 65, count: 8 * 1024 * 1024 + 1), to: path)
            }
            let report = try service.impactDocument(symbols: ["s:Changed.send"], in: context)
            #expect(report.affected.contains { $0.symbol.usr == "s:siblingTest" })
            #expect(report.receiverPrecision?.excludedTransitions == 0)
            #expect(report.limitations.contains { $0.hasPrefix("receiver-source-unverified:") })
        }
    }

    @Test("뒤 파일을 읽는 중 이미 검증한 파일이 바뀌면 impact·affected 모두 전체 후보를 복구한다")
    func rechecksBeforeReturning() throws {
        for output in ["impact", "affected"] {
            for failure in ["changed", "unreadable"] {
                let (_, initial, fs) = fixture()
                let second = "/p/Z.swift"
                try fs.write(bytes, to: second)
                var snapshot = initial.snapshot
                snapshot.dispatchReceiverFiles?.append(.init(path: second, finalClassUSRs: [], selfCalls: [],
                    sourceDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
                let racing = ReceiverMutationFileSystem(base: fs, trigger: second, changed: path,
                    unreadable: failure == "unreadable")
                var configuration = CartographConfiguration.default
                configuration.projectPath = "/p"
                let service = CartographService(configuration: configuration,
                    environment: .init(fileSystem: racing, indexProviderOverride: StaticIndexProvider(snapshot)))
                let context = AnalysisContext(snapshot: snapshot)
                if output == "impact" {
                    let report = try service.impactDocument(symbols: ["s:Changed.send"], in: context)
                    #expect(report.affected.contains { $0.symbol.usr == "s:siblingTest" })
                    #expect(report.receiverPrecision?.mode == "conservative-fallback")
                    #expect(report.receiverPrecision?.excludedTransitions == 0)
                    #expect(report.limitations.contains { $0.hasPrefix("receiver-source-changed-during-query:") })
                } else {
                    let report = try service.affectedDocument(symbols: ["s:Changed.send"], in: context)
                    #expect(report.tests.contains { $0.symbol.usr == "s:siblingTest" })
                    #expect(report.receiverPrecision?.mode == "conservative-fallback")
                    #expect(report.receiverPrecision?.excludedTransitions == 0)
                    #expect(report.limitations.contains { $0.hasPrefix("receiver-source-changed-during-query:") })
                    #expect(report.xcodebuildSelection().refusal != nil)
                }
                #expect(racing.didMutate)
            }
        }
    }

    private func fixture() -> (CartographService, AnalysisContext, InMemoryFileSystem) {
        let location = SourceLocation(path: path, line: 1, column: 1)
        let definitions: [(String, SymbolKind, String?)] = [
            ("Base", .classType, nil), ("Changed", .classType, nil), ("Sibling", .classType, nil),
            ("Base.send", .method, "Base"), ("Changed.send", .method, "Changed"),
            ("Base.shared", .method, "Base"), ("siblingTest", .function, nil)
        ]
        let symbols = definitions.map { name, kind, parent in
            IndexedSymbol(usr: "s:" + name, name: name, kind: kind, module: "Fixture", location: location,
                parentUSR: parent.map { "s:" + $0 }, attributes: name == "siblingTest" ? [.testFunction] : [])
        }
        let snapshot = IndexSnapshot(symbols: symbols, references: [
            .init(sourceUSR: "s:Changed.send", targetUSR: "s:Base.send", kind: .overrides, origin: .compiler),
            .init(sourceUSR: "s:Base.shared", targetUSR: "s:Base.send", kind: .call, location: location,
                origin: .compiler, receiverTypeUSR: "s:Base"),
            .init(sourceUSR: "s:siblingTest", targetUSR: "s:Base.shared", kind: .call, location: location,
                origin: .compiler, receiverTypeUSR: "s:Sibling"),
        ], dispatchReceiverFiles: [
            .init(path: path, finalClassUSRs: ["s:Changed", "s:Sibling"], selfCalls: [
                .init(callerUSR: "s:Base.shared", calleeUSR: "s:Base.send", location: location)
            ], sourceDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        ])
        let fs = InMemoryFileSystem(files: [path: String(decoding: bytes, as: UTF8.self)])
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        let service = CartographService(configuration: configuration,
            environment: .init(fileSystem: fs, indexProviderOverride: StaticIndexProvider(snapshot)))
        return (service, AnalysisContext(snapshot: snapshot), fs)
    }
}

/// The second receiver digest read changes the first admitted file. No sleeps or
/// timestamp tricks are needed to reproduce the cross-file verification race.
private final class ReceiverMutationFileSystem: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    let trigger: String
    let changed: String
    let unreadable: Bool
    private let lock = NSLock()
    private var mutated = false
    var didMutate: Bool { lock.withLock { mutated } }
    var currentDirectoryPath: String { base.currentDirectoryPath }

    init(base: InMemoryFileSystem, trigger: String, changed: String, unreadable: Bool) {
        self.base = base; self.trigger = trigger; self.changed = changed; self.unreadable = unreadable
    }
    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func readData(at path: String) throws -> Data { try base.readData(at: path) }
    func readData(at path: String, maximumBytes: Int) throws -> Data {
        let shouldMutate = lock.withLock {
            if path == trigger && !mutated { mutated = true; return true }
            return false
        }
        if shouldMutate {
            if unreadable { base.setReadError(.fileReadNoPermission, for: changed) }
            else { try base.write(Data("changed during the next file read".utf8), to: changed) }
        }
        return try base.readData(at: path, maximumBytes: maximumBytes)
    }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
}
