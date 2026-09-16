import ArgumentParser
import CartographCore
import CryptoKit
import Darwin
import Foundation

struct RuntimeTraceLogParseResult: Equatable {
    let events: [RuntimeTraceEvent]
    let issues: [String]
    let reportedDroppedEvents: UInt64
}

enum RuntimeTraceLogParser {
    static let maxLogBytes = 84 * 1_024 * 1_024
    static let maxEventBytes = 4_096
    static let maxEvents = 20_000

    static func parse(
        _ data: Data,
        maxEventBytes: Int = maxEventBytes,
        maxEvents: Int = maxEvents
    ) -> RuntimeTraceLogParseResult {
        var events: [RuntimeTraceEvent] = []
        var issues: [String] = []
        var reportedDropped: UInt64 = 0
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            guard line.count <= maxEventBytes else {
                addIssue("trace line \(lineNumber) exceeds \(maxEventBytes) bytes", to: &issues)
                continue
            }
            guard events.count < maxEvents else {
                addIssue("trace contains more than \(maxEvents) events", to: &issues)
                continue
            }
            do {
                let wire = try JSONDecoder().decode(RuntimeTraceWireEvent.self, from: Data(line))
                guard let event = validated(wire) else {
                    addIssue("trace line \(lineNumber) has an unsupported event shape", to: &issues)
                    continue
                }
                events.append(event)
                if wire.phase == "overflow" {
                    reportedDropped = max(reportedDropped, wire.droppedEvents ?? 1)
                }
            } catch {
                addIssue("trace line \(lineNumber) is not valid runtime-trace JSON", to: &issues)
            }
        }
        return RuntimeTraceLogParseResult(
            events: events,
            issues: issues,
            reportedDroppedEvents: reportedDropped
        )
    }

    private static func validated(_ wire: RuntimeTraceWireEvent) -> RuntimeTraceEvent? {
        guard !wire.api.isEmpty,
              wire.api.utf8.count <= 128,
              wire.name.map({ $0.utf8.count <= 1_024 }) ?? true,
              wire.receiverClass.map({ $0.utf8.count <= 1_024 }) ?? true,
              wire.callerSymbol.map({ $0.utf8.count <= 1_024 }) ?? true,
              wire.callerImage.map({ $0.utf8.count <= 4_096 }) ?? true,
              wire.calleeSymbol.map({ $0.utf8.count <= 1_024 }) ?? true,
              wire.calleeImage.map({ $0.utf8.count <= 4_096 }) ?? true,
              (wire.callerImage == nil && wire.callerSymbol == nil && wire.callerOffset == nil)
                || (wire.callerImage != nil && wire.callerOffset != nil),
              wire.calleeImage != nil || wire.calleeSymbol == nil
        else { return nil }

        switch (wire.api, wire.phase) {
        case ("NSClassFromString", "lookup"),
             ("NSSelectorFromString", "lookup"),
             ("NSProtocolFromString", "lookup"):
            guard wire.name != nil || wire.result == false, wire.result != nil,
                  wire.receiverClass == nil, wire.receiverIsClass == nil,
                  wire.calleeSymbol == nil, wire.calleeImage == nil, wire.dispatchUncertain == nil
            else { return nil }
        case ("NSObject.performSelector", "invocation-returned"),
             ("NSObject.performSelector:withObject", "invocation-returned"),
             ("NSObject.performSelector:withObject:withObject", "invocation-returned"),
             ("NotificationCenter.addObserver", "registration"):
            guard wire.name != nil, wire.result == true,
                  wire.receiverClass != nil, wire.receiverIsClass != nil
            else { return nil }
        case ("cartograph.collector", "overflow"):
            guard wire.result == false, (wire.droppedEvents ?? 0) > 0,
                  wire.calleeSymbol == nil, wire.calleeImage == nil, wire.dispatchUncertain == nil
            else { return nil }
        default:
            return nil
        }
        return RuntimeTraceEvent(
            api: wire.api,
            phase: wire.phase,
            name: wire.name,
            result: wire.result,
            receiverClass: wire.receiverClass,
            receiverIsClass: wire.receiverIsClass,
            callerSymbol: wire.callerSymbol,
            callerImage: wire.callerImage,
            callerOffset: wire.callerOffset,
            calleeSymbol: wire.calleeSymbol,
            calleeImage: wire.calleeImage,
            dispatchUncertain: wire.dispatchUncertain
        )
    }

    private static func addIssue(_ issue: String, to issues: inout [String]) {
        if issues.count < 10 {
            issues.append(issue)
        } else if issues.count == 10 {
            issues.append("additional trace parsing errors were omitted")
        }
    }
}

private struct RuntimeTraceWireEvent: Decodable {
    let api: String
    let phase: String
    let name: String?
    let result: Bool?
    let receiverClass: String?
    let receiverIsClass: Bool?
    let callerSymbol: String?
    let callerImage: String?
    let callerOffset: UInt64?
    let calleeSymbol: String?
    let calleeImage: String?
    let dispatchUncertain: Bool?
    let droppedEvents: UInt64?
}

struct RuntimeCollectorStatus: Equatable {
    var recordedExitCode: Int? = nil
    static let expectedHookMask: UInt32 = 0x7f
    static let byteCount = 56

    let processID: Int32
    let active: Bool
    let complete: Bool
    let emittedEvents: UInt64
    let droppedEvents: UInt64
    let truncatedValues: UInt64
    let hookMask: UInt32

    static func read(at url: URL) -> Self? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteCount + 1), data.count == byteCount else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> RuntimeCollectorStatus? {
        guard data.count >= byteCount,
              String(data: data[0..<8], encoding: .utf8) == "CTTRACE1",
              integer(UInt32.self, in: data, at: 8) == 1,
              let processID = integer(Int32.self, in: data, at: 12),
              let active = integer(UInt32.self, in: data, at: 16),
              let complete = integer(UInt32.self, in: data, at: 20),
              let emitted = integer(UInt64.self, in: data, at: 24),
              let dropped = integer(UInt64.self, in: data, at: 32),
              let truncated = integer(UInt64.self, in: data, at: 40),
              let hookMask = integer(UInt32.self, in: data, at: 48),
              let exitMarker = integer(UInt32.self, in: data, at: 52), exitMarker <= 256
        else { return nil }
        return RuntimeCollectorStatus(
            recordedExitCode: exitMarker == 0 ? nil : Int(exitMarker - 1),
            processID: processID,
            active: active == 1,
            complete: complete == 1,
            emittedEvents: emitted,
            droppedEvents: dropped,
            truncatedValues: truncated,
            hookMask: hookMask
        )
    }

    private static func integer<T: FixedWidthInteger>(
        _: T.Type,
        in data: Data,
        at offset: Int
    ) -> T? {
        guard offset + MemoryLayout<T>.size <= data.count else { return nil }
        return data.withUnsafeBytes { bytes in
            T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }
}

struct RuntimeTraceExecution: Equatable {
    let processID: Int32?
    let processExitCode: Int?
    let timedOut: Bool
    let status: RuntimeCollectorStatus?
    let log: RuntimeTraceLogParseResult
    let runtimeIssues: [String]
    let window: RuntimeTraceWindowExecution?

    init(
        processID: Int32?,
        processExitCode: Int?,
        timedOut: Bool,
        status: RuntimeCollectorStatus?,
        log: RuntimeTraceLogParseResult,
        runtimeIssues: [String] = [],
        window: RuntimeTraceWindowExecution? = nil
    ) {
        self.processID = processID
        self.processExitCode = processExitCode
        self.timedOut = timedOut
        self.status = status
        self.log = log
        self.runtimeIssues = runtimeIssues
        self.window = window
    }
}

enum RuntimeTraceCompletion {
    static let scopeLimitations = [
        "The trace covers only code paths executed by this process and APIs supported by collector v1.",
        "Events from descendant processes are excluded from this main-process trace.",
        "A lookup result reports name resolution only; selector lookup does not prove a receiver implements it.",
        "A registration event proves registration returned; only invocation-returned proves a selector call returned.",
    ]

    static func document(
        inputFingerprint: String,
        finalInputFingerprint: String?,
        executableFingerprint: String,
        finalExecutableFingerprint: String?,
        executablePath: String,
        execution: RuntimeTraceExecution,
        launch: RuntimeTraceLaunch? = nil
    ) -> RuntimeTraceDocument {
        var failures = execution.runtimeIssues + execution.log.issues
        let collectorActive = statusIsActive(execution, failures: &failures)
        let dropped = droppedEvents(execution)
        let completionStatus = execution.window?.seal?.status ?? execution.status
        validate(status: completionStatus, requireShutdown: execution.window == nil,
            parsedEventCount: execution.log.events.count, failures: &failures)
        if dropped > 0, !(completionStatus.map { $0.droppedEvents > 0 } ?? false) {
            failures.append("The trace reports dropped events that are missing from the collector status.")
        }
        if execution.timedOut {
            failures.append("The application exceeded the collection timeout and was terminated.")
        }
        if execution.window != nil {
            validateWindow(execution, failures: &failures)
        } else if let exitCode = execution.processExitCode, exitCode != 0 {
            failures.append("The application did not exit successfully (exit \(exitCode)).")
        } else if execution.processExitCode == nil, execution.runtimeIssues.isEmpty {
            failures.append("The application did not provide a normal process exit code.")
        }
        if finalInputFingerprint != inputFingerprint {
            failures.append("Source, index or configuration inputs changed during collection.")
        }
        if finalExecutableFingerprint != executableFingerprint {
            failures.append("The executable changed during collection.")
        }
        let uniqueFailures = Array(Set(failures)).sorted()
        let evidenceComplete = collectorActive && uniqueFailures.isEmpty
        let window = execution.window.map { window in
            RuntimeTraceObservationWindow(
                requestedMilliseconds: window.requestedMilliseconds,
                elapsedMilliseconds: window.seal.flatMap {
                    $0.elapsedNanoseconds <= 3_610_000_000_000 ? Int($0.elapsedNanoseconds / 1_000_000) : nil
                },
                complete: evidenceComplete,
                sealedEventCount: window.seal.flatMap {
                    $0.emittedEvents <= RuntimeTraceLogParser.maxEvents ? Int($0.emittedEvents) : nil
                },
                processOutcome: window.processOutcome
            )
        }
        return RuntimeTraceDocument(
            version: window == nil ? 1 : 2,
            inputFingerprint: inputFingerprint,
            executableFingerprint: executableFingerprint,
            executablePath: executablePath,
            collectorActive: collectorActive,
            collectionComplete: window == nil && evidenceComplete,
            processExitCode: execution.processExitCode,
            events: execution.log.events,
            droppedEvents: dropped,
            limitations: scopeLimitations + uniqueFailures + (window == nil ? [] : [
                "The observation window includes only events completed before sealing; "
                    + "application scenario success was not verified.",
            ]),
            launch: launch,
            observationWindow: window
        )
    }

    private static func statusIsActive(
        _ execution: RuntimeTraceExecution,
        failures: inout [String]
    ) -> Bool {
        guard let status = execution.status else {
            failures.append("The runtime collector did not become active in the application process.")
            return false
        }
        guard status.active, status.processID > 0, status.processID == execution.processID else {
            failures.append("The collector handshake does not identify the launched application process.")
            return false
        }
        return true
    }

    private static func validate(
        status: RuntimeCollectorStatus?,
        requireShutdown: Bool,
        parsedEventCount: Int,
        failures: inout [String]
    ) {
        guard let status else { return }
        if requireShutdown && !status.complete {
            failures.append("The collector did not record a normal process shutdown.")
        }
        if status.hookMask != RuntimeCollectorStatus.expectedHookMask {
            failures.append("One or more Objective-C runtime hooks could not be installed.")
        }
        if status.droppedEvents > 0 {
            failures.append(
                "The collector dropped \(status.droppedEvents) events after reaching a limit or write failure."
            )
        }
        if status.truncatedValues > 0 {
            failures.append("The collector omitted oversized metadata from \(status.truncatedValues) values.")
        }
        if status.emittedEvents != UInt64(parsedEventCount) {
            failures.append("The collector event count does not match the parsed trace.")
        }
    }

    private static func validateWindow(_ execution: RuntimeTraceExecution, failures: inout [String]) {
        guard let window = execution.window, let seal = window.seal else {
            failures.append("The requested observation window has no collector seal.")
            return
        }
        if seal.processID != execution.processID {
            failures.append("The checkpoint seal does not identify the collected application process.")
        }
        if window.requestedMilliseconds < 1 || window.requestedMilliseconds > 3_600_000
            || seal.elapsedNanoseconds / 1_000_000 < window.requestedMilliseconds
            || seal.elapsedNanoseconds > 3_610_000_000_000 {
            failures.append("The checkpoint seal does not cover the requested observation interval.")
        }
        if window.processOutcome != .stoppedAfterSeal {
            failures.append("The collected process was not confirmed stopped after sealing.")
        }
    }

    private static func droppedEvents(_ execution: RuntimeTraceExecution) -> Int {
        let count = max(execution.window?.seal?.droppedEvents ?? execution.status?.droppedEvents ?? 0,
            execution.log.reportedDroppedEvents)
        return count > UInt64(Int.max) ? Int.max : Int(count)
    }

}

enum RuntimeTraceFingerprint {
    static func validateExecutable(at path: String) throws {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !isSensitivePath(path), !isSensitivePath(resolved) else {
            throw ValidationError("--executable points to a credential-like file; pass a built debug application")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ValidationError("--executable does not name a file; build the debug application first")
        }
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw ValidationError("--executable is not executable; pass the built application binary")
        }
    }

    static func executable(at path: String) throws -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let exact: Set<String> = [
            ".env", "auth.json", "auth.plist", "credentials.json", "credentials.plist",
            "secrets.json", "secrets.plist", "secrets.yml", "secrets.yaml",
        ]
        return exact.contains(name)
            || name.hasPrefix(".env.")
            || [".pem", ".key", ".p12", ".p8", ".mobileprovision"].contains { name.hasSuffix($0) }
    }
}

struct RuntimeTraceProcess {
    static let defaultTimeout = 300.0

    static func validateInjectionEnvironment(_ environment: [String: String], simulator: Bool = false) throws {
        let keys = simulator
            ? ["DYLD_INSERT_LIBRARIES", "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] : ["DYLD_INSERT_LIBRARIES"]
        guard keys.allSatisfy({ environment[$0]?.isEmpty ?? true }) else {
            throw RuntimeTraceProcessError.competingInjection
        }
    }

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        timeout: TimeInterval,
        duration: TimeInterval? = nil
    ) throws -> RuntimeTraceExecution {
        try Self.validateInjectionEnvironment(ProcessInfo.processInfo.environment)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collectorURL = try compileCollector(in: directory)
        let traceURL = directory.appendingPathComponent("events.jsonl")
        let statusURL = directory.appendingPathComponent("status.bin")
        return launch(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            collectorURL: collectorURL,
            traceURL: traceURL,
            statusURL: statusURL,
            duration: duration
        )
    }

    func makeTemporaryDirectory() throws -> URL {
        let base = URL(fileURLWithPath: TemporaryBase.directory(), isDirectory: true)
        let directory = base.appendingPathComponent("cartograph-runtime-trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    func compileCollector(in directory: URL, simulatorSDK: String? = nil) throws -> URL {
        let sourceURL = directory.appendingPathComponent("RuntimeCollector.m")
        let collectorURL = directory.appendingPathComponent("libCartographRuntimeCollector.dylib")
        try RuntimeCollectorSource.source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = [
            "clang", "-O2", "-fno-objc-arc", "-dynamiclib", sourceURL.path,
            "-framework", "Foundation", "-o", collectorURL.path,
        ]
        if let simulatorSDK {
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            arguments += ["-target", "\(architecture)-apple-ios15.0-simulator", "-isysroot", simulatorSDK]
        } else {
            arguments += ["-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=14.0"]
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.prefix(16_384), as: UTF8.self)
            throw RuntimeTraceProcessError.collectorCompilationFailed(message)
        }
        return collectorURL
    }

    private func launch(
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        timeout: TimeInterval,
        collectorURL: URL,
        traceURL: URL,
        statusURL: URL,
        duration: TimeInterval?
    ) -> RuntimeTraceExecution {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = collectorURL.path
        environment["CARTOGRAPH_RUNTIME_TRACE_FILE"] = traceURL.path
        environment["CARTOGRAPH_RUNTIME_TRACE_STATUS"] = statusURL.path
        let checkpoint = duration.map { _ in RuntimeCheckpoint(directory: traceURL.deletingLastPathComponent()) }
        for key in ["REQUEST", "ACK", "NONCE"] {
            environment.removeValue(forKey: "CARTOGRAPH_RUNTIME_TRACE_SEAL_" + key)
        }
        if let checkpoint { environment.merge(checkpoint.environment()) { _, new in new } }
        process.environment = environment

        do {
            try process.run()
        } catch {
            return RuntimeTraceExecution(
                processID: nil,
                processExitCode: nil,
                timedOut: false,
                status: nil,
                log: .init(events: [], issues: [], reportedDroppedEvents: 0),
                runtimeIssues: ["The application could not be launched: \(error)"]
            )
        }
        if let duration, let checkpoint {
            return collectWindow(process: process, checkpoint: checkpoint, statusURL: statusURL,
                traceURL: traceURL, milliseconds: Int((duration * 1_000).rounded(.up)), timeout: timeout)
        }
        let timedOut = wait(for: process, timeout: timeout)
        let status = readStatus(at: statusURL)
        let log = readLog(at: traceURL)
        let exitCode = process.terminationReason == .exit ? Int(process.terminationStatus) : nil
        let runtimeIssues = process.terminationReason == .uncaughtSignal
            ? ["The application terminated from signal \(process.terminationStatus)."]
            : []
        return RuntimeTraceExecution(
            processID: process.processIdentifier,
            processExitCode: exitCode,
            timedOut: timedOut,
            status: status,
            log: log,
            runtimeIssues: runtimeIssues
        )
    }

    private func collectWindow(
        process: Process, checkpoint: RuntimeCheckpoint, statusURL: URL,
        traceURL: URL, milliseconds: Int, timeout: TimeInterval
    ) -> RuntimeTraceExecution {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let result = checkpoint.capture(
            requestedMilliseconds: milliseconds, deadline: deadline, statusURL: statusURL,
            isRunning: { process.isRunning }, resolveProcessID: { process.processIdentifier }
        )
        let timedOut = result.seal == nil && ProcessInfo.processInfo.systemUptime >= deadline
        let exitedBeforeCleanup = !process.isRunning
        if process.isRunning { _ = wait(for: process, timeout: 0) }
        else { process.waitUntilExit() }
        let outcome: RuntimeTraceObservationWindow.ProcessOutcome = result.seal != nil && !process.isRunning
            ? .stoppedAfterSeal : (exitedBeforeCleanup ? .exitedBeforeSeal : .unverified)
        return RuntimeTraceExecution(
            processID: process.processIdentifier,
            processExitCode: process.terminationReason == .exit ? Int(process.terminationStatus) : nil,
            timedOut: timedOut, status: result.status ?? readStatus(at: statusURL),
            log: readLog(at: traceURL), runtimeIssues: result.issues,
            window: .init(requestedMilliseconds: milliseconds, seal: result.seal, processOutcome: outcome)
        )
    }

    func wait(for process: Process, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        guard process.isRunning else {
            process.waitUntilExit()
            return false
        }
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning, ProcessInfo.processInfo.systemUptime < grace {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return true
    }

    func readStatus(at url: URL) -> RuntimeCollectorStatus? {
        RuntimeCollectorStatus.read(at: url)
    }

    func readLog(at url: URL) -> RuntimeTraceLogParseResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .init(
                events: [],
                issues: ["runtime trace file was not created or could not be opened"],
                reportedDroppedEvents: 0
            )
        }
        defer { try? handle.close() }
        do {
            let data = try handle.read(upToCount: RuntimeTraceLogParser.maxLogBytes + 1) ?? Data()
            var parsed = RuntimeTraceLogParser.parse(Data(data.prefix(RuntimeTraceLogParser.maxLogBytes)))
            if data.count > RuntimeTraceLogParser.maxLogBytes {
                parsed = RuntimeTraceLogParseResult(
                    events: parsed.events,
                    issues: parsed.issues + ["runtime trace exceeds the maximum file size"],
                    reportedDroppedEvents: parsed.reportedDroppedEvents
                )
            }
            return parsed
        } catch {
            return .init(
                events: [],
                issues: ["runtime trace could not be read: \(error)"],
                reportedDroppedEvents: 0
            )
        }
    }
}

enum RuntimeTraceProcessError: Error, LocalizedError {
    case collectorCompilationFailed(String)
    case simulatorPreparationFailed(String)
    case competingInjection

    var errorDescription: String? {
        switch self {
        case let .collectorCompilationFailed(message):
            return "Could not compile the runtime collector with xcrun clang: \(message)"
        case let .simulatorPreparationFailed(message):
            return message
        case .competingInjection:
            return "Existing DYLD injection can hide runtime events; "
                + "collect in a debug environment without other injected libraries"
        }
    }
}
