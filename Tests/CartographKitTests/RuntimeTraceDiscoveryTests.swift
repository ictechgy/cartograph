import CartographAnalysis
import CartographCore
@testable import CartographKit
import CartographTestSupport
import CryptoKit
import Foundation
import Testing

@Suite("실행 trace 문서 검증")
struct RuntimeTraceDiscoveryTests {
    private let sourcePath = "/p/App.swift"
    private let executablePath = "/p/Probe"
    private let tracePath = "/p/trace.json"
    private let callerUSR = "s:4Test6calleryyF"

    @Test("봉인한 v2 관측 구간은 앱 성공을 주장하지 않고 근거로 읽는다")
    func acceptsSealedObservationWindow() throws {
        let fileSystem = makeFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let fingerprint = try service.runtimeTraceInputFingerprint()
        let base = makeTrace(inputFingerprint: fingerprint)
        let trace = RuntimeTraceDocument(
            version: 2, inputFingerprint: base.inputFingerprint,
            executableFingerprint: base.executableFingerprint, executablePath: base.executablePath,
            collectorActive: true, collectionComplete: false, processExitCode: nil,
            events: base.events, droppedEvents: 0, limitations: [],
            launch: .init(platform: .macOS, processID: 72),
            observationWindow: .init(requestedMilliseconds: 1000, elapsedMilliseconds: 1001,
                complete: true, sealedEventCount: 1, processOutcome: .stoppedAfterSeal)
        )
        try write(trace, to: tracePath, fileSystem: fileSystem)
        let report = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
        #expect(trace.evidenceComplete == true)
        #expect(!trace.collectionComplete && trace.processExitCode == nil)
        #expect(report.evidenceCurrent)
        #expect(report.limitations.contains { $0.contains("scenario success") })
        let data = try fileSystem.readData(at: tracePath)
        let decoded = try JSONDecoder().decode(RuntimeTraceDocument.self, from: data)
        #expect(decoded.hasCompleteEvidence)
    }

    @Test("실행 대상 메타데이터는 왕복 보존하고 플랫폼과 맞지 않는 신원은 거부한다")
    func validatesOptionalLaunchIdentity() throws {
        let fileSystem = makeFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let fingerprint = try service.runtimeTraceInputFingerprint()
        let base = makeTrace(inputFingerprint: fingerprint)
        let launches: [(RuntimeTraceLaunch, Bool)] = [
            (.init(platform: .macOS, processID: 72), true),
            (.init(platform: .iOSSimulator, processID: 72,
                simulatorID: "EF6654D7-B424-446C-98B1-F9163912AF01", bundleID: "dev.cartograph.Probe"), true),
            (.init(platform: .iOSSimulator, processID: 72, simulatorID: "booted", bundleID: "dev.Probe"), false),
            (.init(platform: .macOS, processID: 72, bundleID: "dev.Probe"), false),
            (.init(platform: .macOS, processID: -1), false),
            (.init(platform: .iOSSimulator, processID: nil,
                simulatorID: "EF6654D7-B424-446C-98B1-F9163912AF01", bundleID: "dev.cartograph.Probe"), false),
        ]
        for (launch, valid) in launches {
            let trace = RuntimeTraceDocument(
                inputFingerprint: base.inputFingerprint, executableFingerprint: base.executableFingerprint,
                executablePath: base.executablePath, collectorActive: true, collectionComplete: true,
                processExitCode: 0, events: base.events, droppedEvents: 0, limitations: [], launch: launch
            )
            let data = try JSONEncoder.cartographDefault().encode(trace)
            #expect(try JSONDecoder().decode(RuntimeTraceDocument.self, from: data).launch == launch)
            try fileSystem.write(data, to: tracePath)
            if valid {
                let report = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
                #expect(report.evidenceCurrent)
            } else {
                #expect(throws: CartographError.self) {
                    _ = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
                }
            }
        }
    }

    @Test("UIKit의 nil 이름 조회 실패는 읽되 이름 없는 성공은 거부한다")
    func acceptsFailedNilLookup() throws {
        let fileSystem = makeFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let fingerprint = try service.runtimeTraceInputFingerprint()
        for success in [false, true] {
            let event = RuntimeTraceEvent(api: "NSClassFromString", phase: "lookup", result: success)
            try write(makeTrace(inputFingerprint: fingerprint, event: event), to: tracePath, fileSystem: fileSystem)
            if success {
                #expect(throws: CartographError.self) {
                    _ = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
                }
            } else {
                let report = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
                #expect(report.evidenceCurrent)
                #expect(report.connections.isEmpty)
                #expect(report.findings.first?.status == .lookupFailed)
            }
        }
    }

    @Test("현재 입력과 명시한 실행 파일이 맞으면 trace와 정적 발견을 분리해 제공한다")
    func acceptsCurrentTraceWithoutTrustingEmbeddedPath() throws {
        let fileSystem = makeFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let fingerprint = try service.runtimeTraceInputFingerprint()
        let trace = makeTrace(inputFingerprint: fingerprint, executablePath: "/untrusted/embedded/path")
        try write(trace, to: tracePath, fileSystem: fileSystem)

        let report = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
        let document = try service.runtimeTraceDiscoveryDocument(
            tracePath: tracePath,
            executablePath: executablePath,
            limit: 10
        )

        #expect(report.evidenceCurrent)
        #expect(report.findings.first?.status == .lookupFailed)
        #expect(report.connections.isEmpty)
        #expect(document.format == "runtime-discovery-comparison")
        #expect(document.staticDiscovery.format == "runtime-discovery")
        #expect(document.observed.eventCount == 1)
        #expect(document.observed.needsReviewCount == 1)
    }

    @Test("비활성·불완전하거나 예전 입력의 trace는 사건을 보여도 관계를 만들지 않는다")
    func incompleteAndStaleTraceHaveNoStrongConnections() throws {
        let fileSystem = makeFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let fingerprint = try service.runtimeTraceInputFingerprint()
        let observed = invocationEvent()
        let incomplete = makeTrace(
            inputFingerprint: fingerprint,
            collectorActive: false,
            collectionComplete: false,
            event: observed
        )
        try write(incomplete, to: tracePath, fileSystem: fileSystem)
        let incompleteReport = try service.runtimeTraceReport(
            tracePath: tracePath,
            executablePath: executablePath
        )
        #expect(!incompleteReport.evidenceCurrent)
        #expect(incompleteReport.findings.first?.status == .stale)
        #expect(incompleteReport.connections.isEmpty)

        let stale = makeTrace(inputFingerprint: String(repeating: "0", count: 64), event: observed)
        try write(stale, to: tracePath, fileSystem: fileSystem)
        let staleReport = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
        #expect(!staleReport.evidenceCurrent)
        #expect(staleReport.connections.isEmpty)
        #expect(staleReport.limitations.contains { $0.contains("does not match") })
    }

    @Test("다른 실행 파일과 잘못된 형식·필드 크기는 분석 전에 거부한다")
    func rejectsWrongBinaryAndMalformedTrace() throws {
        let fileSystem = makeFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let fingerprint = try service.runtimeTraceInputFingerprint()
        try write(makeTrace(inputFingerprint: fingerprint), to: tracePath, fileSystem: fileSystem)
        try fileSystem.write(text: "different-binary", to: executablePath)
        #expect(throws: CartographError.self) {
            _ = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
        }

        try fileSystem.write(text: "binary", to: executablePath)
        let wrongFormat = RuntimeTraceDocument(
            format: "wrong",
            inputFingerprint: fingerprint,
            executableFingerprint: executableFingerprint("binary"),
            executablePath: executablePath,
            collectorActive: true,
            collectionComplete: true,
            processExitCode: 0,
            events: [],
            droppedEvents: 0,
            limitations: []
        )
        try write(wrongFormat, to: tracePath, fileSystem: fileSystem)
        #expect(throws: CartographError.self) {
            _ = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
        }

        let oversized = RuntimeTraceEvent(
            api: String(repeating: "a", count: 129),
            phase: "lookup",
            name: "Screen",
            result: true
        )
        try write(makeTrace(inputFingerprint: fingerprint, event: oversized),
            to: tracePath, fileSystem: fileSystem)
        #expect(throws: CartographError.self) {
            _ = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
        }
    }

    @Test("읽는 사이 trace가 바뀌면 어느 쪽 사건도 현재 근거로 쓰지 않는다")
    func rejectsTraceChangedDuringRead() throws {
        let base = makeFileSystem()
        let baseService = makeService(fileSystem: base)
        let fingerprint = try baseService.runtimeTraceInputFingerprint()
        let first = makeTrace(inputFingerprint: fingerprint)
        let second = makeTrace(inputFingerprint: fingerprint, event: RuntimeTraceEvent(
            api: "NSProtocolFromString",
            phase: "lookup",
            name: "Missing",
            result: false
        ))
        let encoder = JSONEncoder.cartographDefault()
        try base.write(encoder.encode(first), to: tracePath)
        let changing = MutatingTraceFileSystem(
            base: base,
            tracePath: tracePath,
            replacement: try encoder.encode(second)
        )
        let service = makeService(fileSystem: changing)

        #expect(throws: CartographError.self) {
            _ = try service.runtimeTraceReport(tracePath: tracePath, executablePath: executablePath)
        }
    }

    @Test("표시 한도는 전체 사건·관계·반복 근거 개수를 줄이지 않는다")
    func displayLimitPreservesCounts() {
        let source = GraphNode(id: "source", name: "source", kind: .function)
        let target = GraphNode(id: "target", name: "target", kind: .classType)
        let graph = CodeGraph(level: .symbol, nodes: [source, target], edges: [])
        let observed = RuntimeTraceEvent(
            api: "NSClassFromString",
            phase: "lookup",
            name: "Target",
            result: true
        )
        let report = RuntimeTraceReport(findings: [0, 1].map {
            RuntimeTraceFinding(
                ordinal: $0,
                event: observed,
                status: .observed,
                source: source.id,
                targets: [target.id]
            )
        })

        let document = RuntimeTraceReportDocument(report: report, graph: graph, limit: 1)

        #expect(document.eventCount == 2)
        #expect(document.connectionCount == 1)
        #expect(document.findings.count == 1)
        #expect(document.connections.first?.count == 2)
        #expect(document.connections.first?.evidenceOrdinals == [0])
        #expect(document.connections.first?.evidenceOmitted == 1)
        #expect(document.truncated)
    }

    @Test("실행 근거 세대가 표시된 같은 context만 재사용한다")
    func requiresRuntimeEvidenceContextGeneration() throws {
        let fileSystem = makeFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let context = try service.loadRuntimeEvidenceContext()
        let fingerprint = try #require(context.runtimeInputFingerprint)
        try write(makeTrace(inputFingerprint: fingerprint), to: tracePath, fileSystem: fileSystem)

        let report = try service.runtimeTraceReport(
            tracePath: tracePath,
            executablePath: executablePath,
            in: context
        )
        #expect(report.evidenceCurrent)
        #expect(throws: CartographError.self) {
            _ = try service.runtimeTraceReport(
                tracePath: tracePath,
                executablePath: executablePath,
                in: AnalysisContext(snapshot: context.snapshot)
            )
        }
    }

    private func makeService(fileSystem: (any FileSystem)? = nil) -> CartographService {
        let fileSystem = fileSystem ?? makeFileSystem()
        var snapshot = IndexSnapshot(symbols: [
            .init(
                usr: callerUSR,
                name: "caller()",
                kind: .function,
                module: "Test",
                location: .init(path: sourcePath, line: 1, column: 1)
            ),
        ], references: [])
        snapshot.indexedFileDates = [sourcePath: Date(timeIntervalSinceReferenceDate: 100)]
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return CartographService(
            configuration: configuration,
            environment: .init(fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(snapshot))
        )
    }

    private func makeFileSystem() -> InMemoryFileSystem {
        let fileSystem = InMemoryFileSystem(files: [
            sourcePath: "func caller() {}\n",
            executablePath: "binary",
        ])
        fileSystem.setModificationDate(Date(timeIntervalSinceReferenceDate: 100), for: sourcePath)
        return fileSystem
    }

    private func makeTrace(
        inputFingerprint: String,
        executablePath embeddedPath: String? = nil,
        collectorActive: Bool = true,
        collectionComplete: Bool = true,
        event: RuntimeTraceEvent? = nil
    ) -> RuntimeTraceDocument {
        RuntimeTraceDocument(
            inputFingerprint: inputFingerprint,
            executableFingerprint: executableFingerprint("binary"),
            executablePath: embeddedPath ?? executablePath,
            collectorActive: collectorActive,
            collectionComplete: collectionComplete,
            processExitCode: 0,
            events: [event ?? RuntimeTraceEvent(
                api: "NSClassFromString",
                phase: "lookup",
                name: "Missing",
                result: false,
                callerSymbol: "$s4Test6calleryyF",
                callerImage: executablePath,
                callerOffset: 0
            )],
            droppedEvents: 0,
            limitations: ["The trace covers only executed code paths."]
        )
    }

    private func invocationEvent() -> RuntimeTraceEvent {
        RuntimeTraceEvent(
            api: "NSObject.performSelector",
            phase: "invocation-returned",
            name: "open:",
            result: true,
            receiverClass: "Screen",
            receiverIsClass: false,
            callerSymbol: "$s4Test6calleryyF",
            callerImage: executablePath,
            callerOffset: 0
        )
    }

    private func write(
        _ trace: RuntimeTraceDocument,
        to path: String,
        fileSystem: InMemoryFileSystem
    ) throws {
        try fileSystem.write(JSONEncoder.cartographDefault().encode(trace), to: path)
    }

    private func executableFingerprint(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class MutatingTraceFileSystem: FileSystem, @unchecked Sendable {
    private let base: InMemoryFileSystem
    private let tracePath: String
    private let replacement: Data
    private let lock = NSLock()
    private var changed = false

    init(base: InMemoryFileSystem, tracePath: String, replacement: Data) {
        self.base = base
        self.tracePath = tracePath
        self.replacement = replacement
    }

    var currentDirectoryPath: String { base.currentDirectoryPath }
    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }

    func readData(at path: String) throws -> Data {
        let data = try base.readData(at: path)
        if path == tracePath {
            let shouldChange = lock.withLock { () -> Bool in
                guard !changed else { return false }
                changed = true
                return true
            }
            if shouldChange { try base.write(replacement, to: tracePath) }
        }
        return data
    }

    func write(_ data: Data, to path: String) throws {
        try base.write(data, to: path)
    }

    func removeItem(at path: String) throws { try base.removeItem(at: path) }
}
