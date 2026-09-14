import CartographCore
import Foundation

/// 이미 설치된 시뮬레이터 앱의 신원을 확인하고 전용 임시 경로에만 수집기를 둔다.
struct RuntimeSimulatorProcess {
    private let fileSystem: any RuntimeSimulatorFileOperations
    private let commandRunner: any RuntimeSimulatorCommandRunning
    private let collectorCompiler: any RuntimeSimulatorCollectorCompiling
    private let traceReader: any RuntimeSimulatorTraceReading
    private let clock: any RuntimeSimulatorClock
    private let environmentProvider: () -> [String: String]

    init(
        fileSystem: any RuntimeSimulatorFileOperations = LocalRuntimeSimulatorFileOperations(),
        commandRunner: (any RuntimeSimulatorCommandRunning)? = nil,
        collectorCompiler: (any RuntimeSimulatorCollectorCompiling)? = nil,
        traceReader: (any RuntimeSimulatorTraceReading)? = nil,
        clock: any RuntimeSimulatorClock = SystemRuntimeSimulatorClock(),
        environmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        let native = RuntimeTraceProcess()
        self.fileSystem = fileSystem
        self.commandRunner = commandRunner ?? XCRunRuntimeSimulatorCommandRunner(clock: clock)
        self.collectorCompiler = collectorCompiler ?? NativeRuntimeSimulatorCollectorCompiler(native: native)
        self.traceReader = traceReader ?? NativeRuntimeSimulatorTraceReader(native: native)
        self.clock = clock
        self.environmentProvider = environmentProvider
    }

    func run(
        simulator: String,
        bundleID: String,
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        duration: TimeInterval? = nil
    ) throws -> RuntimeTraceExecution {
        try RuntimeTraceProcess.validateInjectionEnvironment(environmentProvider(), simulator: true)
        let directory = try fileSystem.makeTemporaryDirectory()
        var traceDirectory: URL?
        var launchStarted = false
        do {
            try validateDevice(simulator, in: directory)
            try requireStoppedApp(simulator: simulator, bundleID: bundleID, in: directory)
            let installed = try installedExecutable(simulator: simulator, bundleID: bundleID, in: directory)
            let fingerprint = try RuntimeTraceFingerprint.executable(at: executablePath)
            guard try RuntimeTraceFingerprint.executable(at: installed.path) == fingerprint else {
                throw RuntimeTraceProcessError.simulatorPreparationFailed(
                    "The installed simulator executable differs from --executable; "
                        + "install the matching debug build first"
                )
            }
            let dataContainer = try container(simulator: simulator, bundleID: bundleID, kind: "data", in: directory)
            let directoryURL = dataContainer.appendingPathComponent("tmp/cartograph-runtime-\(UUID().uuidString)")
            try fileSystem.createDirectory(
                at: directoryURL, attributes: [.posixPermissions: 0o700]
            )
            traceDirectory = directoryURL
            let sdk = try command(["--sdk", "iphonesimulator", "--show-sdk-path"], in: directory)
            let builtCollector = try collectorCompiler.compile(in: directory, simulatorSDK: sdk)
            let collector = directoryURL.appendingPathComponent("Collector.dylib")
            try fileSystem.copyItem(at: builtCollector, to: collector)
            launchStarted = true
            let execution = try launch(
                simulator: simulator, bundleID: bundleID, arguments: arguments, timeout: timeout,
                collector: collector, traceDirectory: directoryURL, directory: directory, duration: duration
            )
            var issues = cleanup(traceDirectory: traceDirectory, directory: directory)
            if (try? RuntimeTraceFingerprint.executable(at: installed.path)) != fingerprint {
                issues.append("The installed simulator executable changed during collection.")
            }
            return RuntimeTraceExecution(
                processID: execution.processID, processExitCode: execution.processExitCode,
                timedOut: execution.timedOut, status: execution.status, log: execution.log,
                runtimeIssues: execution.runtimeIssues + issues, window: execution.window
            )
        } catch {
            let recoveryIssues = launchStarted
                ? recoverApplicationAfterLaunchFailure(
                    simulator: simulator, bundleID: bundleID, directory: directory, traceDirectory: traceDirectory
                ) : []
            let cleanupIssues = cleanup(traceDirectory: traceDirectory, directory: directory)
            let issues = recoveryIssues + cleanupIssues
            guard !issues.isEmpty else { throw error }
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "The simulator collection failed: \(error.localizedDescription); "
                    + "follow-up cleanup failed: \(issues.joined(separator: "; "))"
            )
        }
    }

    static func launchedProcessID(from output: String, bundleID: String) -> Int32? {
        let prefix = bundleID + ": "
        let lines = output.split(separator: "\n").filter { $0.hasPrefix(prefix) }
        guard lines.count == 1, let line = lines.first,
              let pid = Int32(line.dropFirst(prefix.count)), pid > 0 else { return nil }
        return pid
    }

    static func runningProcessIDs(from output: String, bundleID: String) -> [Int32] {
        let marker = "UIKitApplication:\(bundleID)["
        return output.split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, fields[2].hasPrefix(marker),
                  let pid = Int32(fields[0]), pid > 0 else { return nil }
            return pid
        }.sorted()
    }

    private func validateDevice(_ simulator: String, in directory: URL) throws {
        let output = try command(["simctl", "list", "devices", "booted", "--json"], in: directory)
        let list: DeviceList
        do {
            list = try JSONDecoder().decode(DeviceList.self, from: Data(output.utf8))
        } catch {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "simctl returned malformed device data; verify the selected Simulator and Xcode installation"
            )
        }
        let devices = list.devices.filter {
            guard let version = $0.key.components(separatedBy: ".iOS-").last,
                  $0.key.contains(".iOS-"), let major = Int(version.split(separator: "-").first ?? "") else {
                return false
            }
            return major >= 15
        }.flatMap(\.value)
        guard devices.contains(where: {
            $0.udid.caseInsensitiveCompare(simulator) == .orderedSame && $0.state == "Booted" && $0.isAvailable
        }) else {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "--simulator must identify a booted, available iOS 15 or later Simulator; boot it before collecting"
            )
        }
    }

    private func requireStoppedApp(simulator: String, bundleID: String, in directory: URL) throws {
        guard try runningProcessIDs(simulator: simulator, bundleID: bundleID, in: directory).isEmpty else {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "The simulator app is already running; stop that debug session before collecting"
            )
        }
    }

    private func runningProcessIDs(simulator: String, bundleID: String, in directory: URL) throws -> [Int32] {
        let processes = try command(["simctl", "spawn", simulator, "launchctl", "list"], in: directory)
        return Self.runningProcessIDs(from: processes, bundleID: bundleID)
    }

    private func runningProcessID(simulator: String, bundleID: String, in directory: URL) throws -> Int32? {
        let processes = try runningProcessIDs(simulator: simulator, bundleID: bundleID, in: directory)
        return processes.count == 1 ? processes[0] : nil
    }

    private func container(
        simulator: String, bundleID: String, kind: String, in directory: URL
    ) throws -> URL {
        let path = try command(["simctl", "get_app_container", simulator, bundleID, kind], in: directory)
        guard path.hasPrefix("/"), !path.contains("\n"), !path.utf8.contains(0) else {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "simctl returned an invalid app container; reinstall the matching debug app"
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }

    private func installedExecutable(simulator: String, bundleID: String, in directory: URL) throws -> URL {
        let app = try container(simulator: simulator, bundleID: bundleID, kind: "app", in: directory)
        let info = try PropertyListSerialization.propertyList(
            from: fileSystem.readData(at: app.appendingPathComponent("Info.plist")), format: nil
        ) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              let name = info?["CFBundleExecutable"] as? String,
              !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.utf8.contains(0),
              name != ".", name != ".." else {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "The installed app has no matching bundle/executable identity; reinstall the debug app"
            )
        }
        let executable = app.appendingPathComponent(name).resolvingSymlinksInPath()
        guard executable.deletingLastPathComponent() == app else {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "The installed app executable escapes its bundle; use a regular debug app bundle"
            )
        }
        try RuntimeTraceFingerprint.validateExecutable(at: executable.path)
        return executable
    }

    private func launch(
        simulator: String, bundleID: String, arguments: [String], timeout: TimeInterval,
        collector: URL, traceDirectory: URL, directory: URL, duration: TimeInterval?
    ) throws -> RuntimeTraceExecution {
        let trace = traceDirectory.appendingPathComponent("events.jsonl")
        let statusURL = traceDirectory.appendingPathComponent("status.bin")
        var environment = environmentProvider()
        environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = collector.path
        environment["SIMCTL_CHILD_CARTOGRAPH_RUNTIME_TRACE_FILE"] = trace.path
        environment["SIMCTL_CHILD_CARTOGRAPH_RUNTIME_TRACE_STATUS"] = statusURL.path
        for key in ["REQUEST", "ACK", "NONCE"] {
            environment.removeValue(forKey: "SIMCTL_CHILD_CARTOGRAPH_RUNTIME_TRACE_SEAL_" + key)
        }
        if let duration {
            return try launchWindow(simulator: simulator, bundleID: bundleID, arguments: arguments,
                environment: environment, duration: duration, timeout: timeout,
                trace: trace, statusURL: statusURL, directory: directory, traceDirectory: traceDirectory)
        }
        let result = try commandRunner.run(.init(
            arguments: ["simctl", "launch", "--console", simulator, bundleID] + arguments,
            directory: directory, environment: environment, timeout: timeout, forwardOutput: true,
            waitForProcess: nil
        ))
        var processID = Self.launchedProcessID(from: result.output, bundleID: bundleID)
        let status = traceReader.status(at: statusURL)
        var issues = result.issues
        if processID == nil, status?.active == true,
           let running = try? runningProcessID(simulator: simulator, bundleID: bundleID, in: directory),
           running == status?.processID {
            processID = running
            issues.append(
                "simctl omitted the application PID; the collector PID was verified against the running bundle."
            )
        }
        if processID == nil {
            issues.append("simctl did not identify exactly one launched application process.")
        }
        if result.exitCode != 0 {
            issues.append("The simulator launch session failed; inspect the application diagnostics.")
        }
        if result.timedOut {
            issues.append("The simulator launch exceeded the collection timeout.")
        }
        if status?.recordedExitCode == nil {
            issues.append("The simulator app did not record an explicit exit code; simctl success is not app success.")
        }
        issues += stopRemainingApplication(
            simulator: simulator, bundleID: bundleID, processID: processID ?? status?.processID, directory: directory
        )
        return RuntimeTraceExecution(
            processID: processID, processExitCode: status?.recordedExitCode,
            timedOut: result.timedOut, status: status, log: traceReader.log(at: trace), runtimeIssues: issues
        )
    }

    private func stopRemainingApplication(
        simulator: String, bundleID: String, processID: Int32?, directory: URL, expectedStop: Bool = false
    ) -> [String] {
        do {
            let runningProcesses = try runningProcessIDs(simulator: simulator, bundleID: bundleID, in: directory)
            guard !runningProcesses.isEmpty else {
                return []
            }
            guard runningProcesses.count == 1 else {
                return [
                    "Multiple simulator processes match the application bundle; none was terminated."
                ]
            }
            let running = runningProcesses[0]
            guard running == processID else {
                return [
                    "A simulator app is still running without the collected process identity; it was not terminated."
                ]
            }
            _ = try command(["simctl", "terminate", simulator, bundleID], in: directory)
            let deadline = clock.uptime + 3
            while clock.uptime < deadline {
                let remaining = try runningProcessIDs(simulator: simulator, bundleID: bundleID, in: directory)
                guard remaining.count == 1, remaining[0] == running else {
                    if remaining.isEmpty {
                        return expectedStop ? [] : [
                            "The application outlived the simulator launch session and was terminated.",
                        ]
                    }
                    return [
                        "The simulator application shutdown could not be verified because its process identity "
                            + "changed.",
                    ]
                }
                clock.sleep(for: 0.1)
            }
            return ["The collected simulator application did not terminate; stop that debug session manually."]
        } catch {
            return ["The simulator application shutdown could not be verified: \(error.localizedDescription)"]
        }
    }

    private func launchWindow(
        simulator: String, bundleID: String, arguments: [String], environment: [String: String],
        duration: TimeInterval, timeout: TimeInterval, trace: URL, statusURL: URL,
        directory: URL, traceDirectory: URL
    ) throws -> RuntimeTraceExecution {
        let checkpoint = RuntimeCheckpoint(directory: traceDirectory)
        var environment = environment
        environment.merge(checkpoint.environment(prefix: "SIMCTL_CHILD_")) { _, new in new }
        let milliseconds = Int((duration * 1_000).rounded(.up))
        var capture: RuntimeCheckpoint.Result?
        var cleanupIssues: [String] = []
        let result = try commandRunner.run(.init(
            arguments: ["simctl", "launch", "--console", simulator, bundleID] + arguments,
            directory: directory, environment: environment, timeout: timeout, forwardOutput: true,
            waitForProcess: { process in
                let deadline = clock.uptime + timeout
                capture = checkpoint.capture(
                    requestedMilliseconds: milliseconds, deadline: deadline, statusURL: statusURL,
                    isRunning: { process.isRunning },
                    resolveProcessID: {
                        try runningProcessID(simulator: simulator, bundleID: bundleID, in: directory)
                    }
                )
                let timedOut = capture?.seal == nil && clock.uptime >= deadline
                cleanupIssues = stopRemainingApplication(
                    simulator: simulator, bundleID: bundleID,
                    processID: capture?.processID ?? capture?.status?.processID,
                    directory: directory, expectedStop: true
                )
                // 앱 신원 검증/정리 후에는 이 명령의 console 프로세스만 끝낸다.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return timedOut
            }
        ))
        let status = capture?.status ?? traceReader.status(at: statusURL)
        let processID = capture?.processID ?? Self.launchedProcessID(from: result.output, bundleID: bundleID)
        let seal = capture?.seal
        let outcome: RuntimeTraceObservationWindow.ProcessOutcome = seal != nil && cleanupIssues.isEmpty
            ? .stoppedAfterSeal : .unverified
        return RuntimeTraceExecution(
            processID: processID, processExitCode: traceReader.status(at: statusURL)?.recordedExitCode,
            timedOut: result.timedOut, status: status, log: traceReader.log(at: trace),
            runtimeIssues: (capture?.issues ?? ["The observation window was not started."])
                + cleanupIssues + result.issues,
            window: .init(requestedMilliseconds: milliseconds, seal: seal, processOutcome: outcome)
        )
    }

    private func command(_ arguments: [String], in directory: URL) throws -> String {
        let result: RuntimeSimulatorCommandResult
        do {
            result = try commandRunner.run(.init(
                arguments: arguments, directory: directory, environment: nil,
                timeout: 30, forwardOutput: false, waitForProcess: nil
            ))
        } catch {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "The simulator preparation command could not run: \(error.localizedDescription)"
            )
        }
        guard result.exitCode == 0, !result.timedOut, result.issues.isEmpty else {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "The simulator preparation command failed; verify Xcode, the device and installed app"
            )
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanup(traceDirectory: URL?, directory: URL) -> [String] {
        var issues: [String] = []
        if let traceDirectory {
            do {
                try fileSystem.removeItem(at: traceDirectory)
            } catch {
                issues.append(
                    "The private simulator trace directory could not be removed: \(error.localizedDescription)"
                )
            }
        }
        do {
            try fileSystem.removeItem(at: directory)
            } catch {
                issues.append(
                    "The private simulator temporary directory could not be removed: \(error.localizedDescription)"
                )
        }
        return issues
    }

    private func recoverApplicationAfterLaunchFailure(
        simulator: String, bundleID: String, directory: URL, traceDirectory: URL?
    ) -> [String] {
        guard let traceDirectory else { return [] }
        let statusURL = traceDirectory.appendingPathComponent("status.bin")
        guard let status = traceReader.status(at: statusURL), status.active, status.processID > 0 else {
            return [
                "The simulator launch failed before its collector identity could be verified; "
                    + "any app left running was not terminated."
            ]
        }
        do {
            let running = try runningProcessIDs(simulator: simulator, bundleID: bundleID, in: directory)
            guard !running.isEmpty else { return [] }
            guard running.count == 1, running[0] == status.processID else {
                return running.count > 1
                    ? ["Multiple simulator processes matched after launch failure; none was terminated."]
                    : ["The simulator process identity differed after launch failure; it was not terminated."]
            }
            return stopRemainingApplication(
                simulator: simulator, bundleID: bundleID, processID: status.processID,
                directory: directory, expectedStop: true
            )
        } catch {
            return [
                "The simulator app could not be inspected after launch failure; it was not terminated: "
                    + error.localizedDescription
            ]
        }
    }

    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let state: String
        let isAvailable: Bool
    }
}
