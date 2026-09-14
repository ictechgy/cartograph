import CartographAnalysis
import CartographCore
import CryptoKit
import Foundation

/// 정적 발견과 실행 trace를 서로 다른 근거로 보여 주는 결합 문서.
public struct RuntimeTraceDiscoveryDocument: Codable, Sendable, Equatable {
    public let format: String
    public let version: Int
    public let status: String
    public let staticDiscovery: RuntimeDiscoveryDocument
    public let observed: RuntimeTraceReportDocument
    public let limitations: [String]

    /// CI가 두 근거의 미해결 수를 합쳐 판정할 때 사용하는 전체 개수.
    public var needsReviewCount: Int {
        staticDiscovery.unresolvedCount + observed.needsReviewCount
    }

    init(staticDiscovery: RuntimeDiscoveryDocument, observed: RuntimeTraceReportDocument) {
        format = "runtime-discovery-comparison"
        version = 1
        self.staticDiscovery = staticDiscovery
        self.observed = observed
        let needsReview = staticDiscovery.unresolvedCount > 0
            || observed.needsReviewCount > 0
            || observed.status == "partial"
        status = needsReview ? "needsReview" : "analyzed"
        limitations = Array(Set(staticDiscovery.limitations + observed.limitations)).sorted()
    }
}

/// 실행 trace의 전체 집계와 출력 한도 안의 사건·관계.
public struct RuntimeTraceReportDocument: Codable, Sendable, Equatable {
    public let status: String
    public let eventCount: Int
    public let connectionCount: Int
    public let needsReviewCount: Int
    public let countsByStatus: [String: Int]
    public let findings: [Finding]
    public let connections: [Connection]
    public let limitations: [String]
    public let truncated: Bool

    /// 실행 사건 하나와 현재 그래프에서 확인한 로컬 선언.
    public struct Finding: Codable, Sendable, Equatable {
        public let ordinal: Int
        public let event: RuntimeTraceEvent
        public let status: RuntimeTraceStatus
        public let source: SymbolQuery.Subject?
        public let targets: [SymbolQuery.Subject]
        public let targetsOmitted: Int?
        public let candidates: [SymbolQuery.Subject]
        public let candidatesOmitted: Int?
        public let reason: String?
    }

    /// 중복 실행을 횟수로 접은 정확한 source-target 관계.
    public struct Connection: Codable, Sendable, Equatable {
        public let source: SymbolQuery.Subject
        public let target: SymbolQuery.Subject
        public let kind: RuntimeBoundaryKind
        public let count: Int
        public let evidenceOrdinals: [Int]
        public let evidenceOmitted: Int?
    }

    init(report: RuntimeTraceReport, graph: CodeGraph, limit: Int) {
        eventCount = report.findings.count
        connectionCount = report.connections.count
        let review: Set<RuntimeTraceStatus> = [.lookupFailed, .unresolved, .ambiguous, .stale, .unindexed]
        let findingReviews = report.findings.count { review.contains($0.status) }
        needsReviewCount = findingReviews + (!report.evidenceCurrent && report.findings.isEmpty ? 1 : 0)
        countsByStatus = Dictionary(grouping: report.findings, by: { $0.status.rawValue }).mapValues(\.count)
        limitations = report.limitations
        status = !report.evidenceCurrent ? "partial" : (needsReviewCount > 0 ? "needsReview" : "observed")

        var remainingTargets = limit
        var remainingCandidates = limit
        findings = report.findings.prefix(limit).map { finding in
            let targets = finding.targets.prefix(remainingTargets).compactMap { graph.node($0) }
            let candidates = finding.candidates.prefix(remainingCandidates).compactMap { graph.node($0) }
            remainingTargets -= targets.count
            remainingCandidates -= candidates.count
            let targetsOmitted = finding.targets.count - targets.count
            let candidatesOmitted = finding.candidates.count - candidates.count
            return Finding(
                ordinal: finding.ordinal,
                event: finding.event,
                status: finding.status,
                source: finding.source.flatMap { graph.node($0) }.map(SymbolQuery.Subject.init),
                targets: targets.map(SymbolQuery.Subject.init),
                targetsOmitted: targetsOmitted > 0 ? targetsOmitted : nil,
                candidates: candidates.map(SymbolQuery.Subject.init),
                candidatesOmitted: candidatesOmitted > 0 ? candidatesOmitted : nil,
                reason: finding.reason
            )
        }

        var remainingEvidence = limit
        connections = report.connections.prefix(limit).compactMap { connection -> Connection? in
            guard let source = graph.node(connection.source), let target = graph.node(connection.target) else {
                return nil
            }
            let evidence = Array(connection.evidenceOrdinals.prefix(remainingEvidence))
            remainingEvidence -= evidence.count
            let omitted = connection.evidenceOrdinals.count - evidence.count
            return Connection(
                source: SymbolQuery.Subject(node: source),
                target: SymbolQuery.Subject(node: target),
                kind: connection.kind,
                count: connection.count,
                evidenceOrdinals: evidence,
                evidenceOmitted: omitted > 0 ? omitted : nil
            )
        }
        truncated = report.findings.count > findings.count
            || report.connections.count > connections.count
            || findings.contains { ($0.targetsOmitted ?? 0) > 0 || ($0.candidatesOmitted ?? 0) > 0 }
            || connections.contains { ($0.evidenceOmitted ?? 0) > 0 }
    }
}

extension CartographService {
    /// 현재 입력과 명시한 실행 파일에 맞는 trace만 로컬 그래프 관계로 돌려준다.
    public func runtimeTraceReport(
        tracePath: String,
        executablePath: String,
        in existingContext: AnalysisContext? = nil
    ) throws -> RuntimeTraceReport {
        try prepareRuntimeTrace(
            tracePath: tracePath,
            executablePath: executablePath,
            existingContext: existingContext
        ).report
    }

    /// 같은 분석 문맥에서 정적 발견과 실행 관측을 나란히 만든다.
    public func runtimeTraceDiscoveryDocument(
        tracePath: String,
        executablePath: String,
        limit: Int = 200,
        in existingContext: AnalysisContext? = nil
    ) throws -> RuntimeTraceDiscoveryDocument {
        guard (1...10_000).contains(limit) else {
            throw CartographError.invalidConfiguration(
                path: projectPath,
                reason: "Runtime discovery limit must be between 1 and 10000."
            )
        }
        let prepared = try prepareRuntimeTrace(
            tracePath: tracePath,
            executablePath: executablePath,
            existingContext: existingContext
        )
        let staticDocument = try runtimeDiscoveryDocument(limit: limit, in: prepared.context)
        return RuntimeTraceDiscoveryDocument(
            staticDiscovery: staticDocument,
            observed: RuntimeTraceReportDocument(report: prepared.report, graph: prepared.graph, limit: limit)
        )
    }

    private func prepareRuntimeTrace(
        tracePath: String,
        executablePath: String,
        existingContext: AnalysisContext?
    ) throws -> (context: AnalysisContext, graph: CodeGraph, report: RuntimeTraceReport) {
        let context = try existingContext ?? loadRuntimeEvidenceContext()
        guard let before = context.runtimeInputFingerprint else {
            throw runtimeTraceError(
                "The supplied analysis context was not prepared for runtime evidence.",
                path: tracePath
            )
        }
        guard before == (try sessionInputFingerprint()) else {
            throw runtimeTraceError(
                "The runtime evidence context is not the current input generation.",
                path: tracePath
            )
        }
        let store = RuntimeTraceArtifactStore(fileSystem: environment.fileSystem)
        let trace = try store.loadStableTrace(at: resolved(tracePath))
        let executable = resolved(executablePath)
        let firstExecutableFingerprint = try store.executableFingerprint(at: executable)
        guard firstExecutableFingerprint == trace.executableFingerprint else {
            throw runtimeTraceError(
                "The supplied executable does not match the trace fingerprint.",
                path: executable
            )
        }
        var invalidReasons: [String] = []
        if !trace.collectorActive {
            invalidReasons.append("The trace collector was not active in the application process.")
        }
        if !trace.hasCompleteEvidence {
            invalidReasons.append("The runtime trace is incomplete.")
        }
        if trace.droppedEvents > 0 {
            invalidReasons.append("The runtime trace dropped \(trace.droppedEvents) events.")
        }
        if trace.inputFingerprint != before {
            invalidReasons.append("The trace input fingerprint does not match the current analysis inputs.")
        }
        var evidenceState: RuntimeTraceEvidenceState = invalidReasons.isEmpty
            ? .current
            : .invalid(reason: invalidReasons.sorted().joined(separator: " "))
        let graph = context.buildGraph(level: .symbol).graph
        let resolver = RuntimeTraceResolver()
        var resolved = resolver.resolve(
            events: trace.events,
            files: context.runtimeFiles ?? [],
            snapshot: context.snapshot,
            graph: graph,
            freshness: context.runtimeFreshness,
            evidenceState: evidenceState
        )
        let finalInput = try? sessionInputFingerprint()
        let finalExecutableFingerprint = try? store.executableFingerprint(at: executable)
        guard finalExecutableFingerprint == firstExecutableFingerprint else {
            throw runtimeTraceError("The executable changed while reading runtime evidence.", path: executable)
        }
        if finalInput != before {
            invalidReasons.append("Analysis inputs changed while resolving runtime evidence.")
            evidenceState = .invalid(reason: Array(Set(invalidReasons)).sorted().joined(separator: " "))
            resolved = resolver.resolve(
                events: trace.events,
                files: context.runtimeFiles ?? [],
                snapshot: context.snapshot,
                graph: graph,
                freshness: context.runtimeFreshness,
                evidenceState: evidenceState
            )
        }
        let report = RuntimeTraceReport(
            findings: resolved.findings,
            limitations: trace.limitations + resolved.limitations + (trace.observationWindow == nil ? [] : [
                "The observation window contains events completed before sealing; "
                    + "application scenario success was not verified.",
            ]),
            evidenceCurrent: resolved.evidenceCurrent
        )
        return (context, graph, report)
    }

    private func resolved(_ path: String) -> String {
        path.hasPrefix("/") ? path : (projectPath as NSString).appendingPathComponent(path)
    }

    private func runtimeTraceError(_ reason: String, path: String) -> CartographError {
        .invalidConfiguration(path: path, reason: reason)
    }
}

private struct RuntimeTraceArtifactStore {
    static let maximumTraceBytes = 128 * 1_024 * 1_024
    static let maximumEvents = 100_000

    let fileSystem: any FileSystem

    func loadStableTrace(at path: String) throws -> RuntimeTraceDocument {
        try rejectSensitive(path)
        let first = try readBounded(path, maximumBytes: Self.maximumTraceBytes)
        let second = try readBounded(path, maximumBytes: Self.maximumTraceBytes)
        guard SHA256.hash(data: first) == SHA256.hash(data: second) else {
            throw error(path, "The runtime trace changed while it was being read.")
        }
        let document: RuntimeTraceDocument
        do {
            document = try JSONDecoder().decode(RuntimeTraceDocument.self, from: first)
        } catch {
            throw self.error(path, "The file is not valid runtime-trace JSON: \(error)")
        }
        try validate(document, path: path)
        return document
    }

    func executableFingerprint(at path: String) throws -> String {
        try rejectSensitive(path)
        let resolved: String
        do {
            resolved = try fileSystem.realPath(at: path)
        } catch {
            throw self.error(path, "The executable path could not be resolved: \(error)")
        }
        try rejectSensitive(resolved)
        if fileSystem is LocalFileSystem, !FileManager.default.isExecutableFile(atPath: resolved) {
            throw error(path, "The supplied trace executable is not an executable file.")
        }
        do {
            if fileSystem is LocalFileSystem {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: resolved))
                defer { try? handle.close() }
                var hasher = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    hasher.update(data: data)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            let data = try fileSystem.readData(at: resolved)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw self.error(path, "The executable could not be read: \(error)")
        }
    }

    private func readBounded(_ path: String, maximumBytes: Int) throws -> Data {
        let data: Data
        do {
            if fileSystem is LocalFileSystem {
                let resolved = try fileSystem.realPath(at: path)
                try rejectSensitive(resolved)
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: resolved))
                defer { try? handle.close() }
                data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            } else {
                data = try fileSystem.readData(at: path)
            }
        } catch {
            throw self.error(path, "The runtime trace could not be read: \(error)")
        }
        guard data.count <= maximumBytes else {
            throw error(path, "The runtime trace exceeds the 128 MiB read limit.")
        }
        return data
    }

    private func validate(_ document: RuntimeTraceDocument, path: String) throws {
        guard document.format == "runtime-trace", [1, 2].contains(document.version) else {
            throw error(path, "Expected runtime-trace format version 1 or 2.")
        }
        guard validFingerprint(document.inputFingerprint),
              validFingerprint(document.executableFingerprint),
              !document.executablePath.isEmpty,
              document.executablePath.utf8.count <= 4_096,
              document.droppedEvents >= 0,
              document.events.count <= Self.maximumEvents,
              document.limitations.count <= 1_000,
              document.limitations.allSatisfy({ $0.utf8.count <= 4_096 })
        else {
            throw error(path, "The runtime trace exceeds a field or event limit.")
        }
        guard document.events.allSatisfy(validEvent) else {
            throw error(path, "The runtime trace contains an unsupported or oversized event.")
        }
        if let launch = document.launch {
            let claimsComplete = document.collectionComplete || document.evidenceComplete == true
                || document.observationWindow?.complete == true
            guard launch.processID.map({ $0 > 0 }) ?? !claimsComplete,
                  validLaunch(launch) else {
                throw error(path, "The runtime trace launch identity is invalid.")
            }
        }
        if document.version == 2 {
            try validateWindow(document, path: path)
        } else if document.observationWindow != nil || document.evidenceComplete != nil {
            throw error(path, "Observation windows require runtime-trace version 2.")
        } else if document.collectionComplete {
            guard document.collectorActive, document.droppedEvents == 0, document.processExitCode == 0 else {
                throw error(path, "A complete trace has inconsistent collector or process status.")
            }
        }
    }

    private func validateWindow(_ document: RuntimeTraceDocument, path: String) throws {
        guard let window = document.observationWindow, !document.collectionComplete,
              window.trigger == "duration", (1...3_600_000).contains(window.requestedMilliseconds),
              window.elapsedMilliseconds.map({ (0...3_610_000).contains($0) }) ?? true,
              window.sealedEventCount.map({ (0...Self.maximumEvents).contains($0) }) ?? true,
              document.evidenceComplete == (document.collectorActive && window.complete) else {
            throw error(path, "The observation window has invalid or inconsistent completion metadata.")
        }
        if window.complete {
            guard document.collectorActive, document.droppedEvents == 0,
                  let pid = document.launch?.processID, pid > 0,
                  let elapsed = window.elapsedMilliseconds, elapsed >= window.requestedMilliseconds,
                  window.sealedEventCount == document.events.count,
                  window.processOutcome == .stoppedAfterSeal else {
                throw error(path, "A complete observation window requires matching sealed events and process identity.")
            }
        }
    }

    private func validLaunch(_ launch: RuntimeTraceLaunch) -> Bool {
        switch launch.platform {
        case .macOS:
            return launch.simulatorID == nil && launch.bundleID == nil
        case .iOSSimulator:
            guard let simulator = launch.simulatorID, UUID(uuidString: simulator) != nil,
                  let bundle = launch.bundleID, !bundle.isEmpty, bundle.utf8.count <= 255,
                  !bundle.hasPrefix("-") else { return false }
            return bundle.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
                    .contains($0)
            }
        }
    }

    private func validEvent(_ event: RuntimeTraceEvent) -> Bool {
        guard !event.api.isEmpty,
              event.api.utf8.count <= 128,
              event.name.map({ $0.utf8.count <= 1_024 }) ?? true,
              event.receiverClass.map({ $0.utf8.count <= 1_024 }) ?? true,
              event.callerSymbol.map({ $0.utf8.count <= 1_024 }) ?? true,
              event.callerImage.map({ $0.utf8.count <= 4_096 }) ?? true,
              event.calleeSymbol.map({ $0.utf8.count <= 1_024 }) ?? true,
              event.calleeImage.map({ $0.utf8.count <= 4_096 }) ?? true,
              (event.callerImage == nil && event.callerSymbol == nil && event.callerOffset == nil)
                || (event.callerImage != nil && event.callerOffset != nil),
              event.calleeImage != nil || event.calleeSymbol == nil
        else { return false }
        switch (event.api, event.phase) {
        case ("NSClassFromString", "lookup"),
             ("NSSelectorFromString", "lookup"),
             ("NSProtocolFromString", "lookup"):
            return (event.name != nil || event.result == false) && event.result != nil
                && event.receiverClass == nil && event.receiverIsClass == nil
                && event.calleeSymbol == nil && event.calleeImage == nil
                && event.dispatchUncertain == nil
        case ("NSObject.performSelector", "invocation-returned"),
             ("NSObject.performSelector:withObject", "invocation-returned"),
             ("NSObject.performSelector:withObject:withObject", "invocation-returned"),
             ("NotificationCenter.addObserver", "registration"):
            return event.name != nil && event.result == true
                && event.receiverClass != nil && event.receiverIsClass != nil
        case ("cartograph.collector", "overflow"):
            return event.result == false && event.calleeSymbol == nil && event.calleeImage == nil
                && event.dispatchUncertain == nil
        default:
            return false
        }
    }

    private func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func rejectSensitive(_ path: String) throws {
        let name = (path as NSString).lastPathComponent.lowercased()
        let exact: Set<String> = [
            ".env", "auth.json", "auth.plist", "credentials.json", "credentials.plist",
            "secrets.json", "secrets.plist", "secrets.yml", "secrets.yaml",
        ]
        if exact.contains(name) || name.hasPrefix(".env.")
            || [".pem", ".key", ".p12", ".p8", ".mobileprovision"].contains(where: { name.hasSuffix($0) }) {
            throw error(path, "The path points to a credential-like file.")
        }
    }

    private func error(_ path: String, _ reason: String) -> CartographError {
        .invalidConfiguration(path: path, reason: reason)
    }
}
