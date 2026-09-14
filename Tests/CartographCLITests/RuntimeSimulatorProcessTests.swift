import CartographCore
import Foundation
@testable import cartograph
import Testing

@Suite("시뮬레이터 런타임 프로세스 경계")
struct RuntimeSimulatorProcessTests {
    @Test("기기 목록이 malformed이면 준비 실패를 명시한다")
    func rejectsMalformedDeviceList() throws {
        let fixture = try Fixture(deviceOutput: "{not-json")
        defer { fixture.remove() }

        let error = #expect(throws: RuntimeTraceProcessError.self) {
            try fixture.process().run(
                simulator: fixture.simulator, bundleID: fixture.bundleID,
                executablePath: fixture.source.path, arguments: [], timeout: 1
            )
        }
        #expect(error?.localizedDescription.contains("malformed device data") == true)
        #expect(fixture.runner.requests.count == 1)
    }

    @Test("booted 목록에서 unavailable 기기는 선택하지 않는다")
    func rejectsUnavailableDevice() throws {
        let fixture = try Fixture(deviceOutput: Fixture.deviceJSON(state: "Shutdown", available: false))
        defer { fixture.remove() }

        let error = #expect(throws: RuntimeTraceProcessError.self) {
            try fixture.process().run(
                simulator: fixture.simulator, bundleID: fixture.bundleID,
                executablePath: fixture.source.path, arguments: [], timeout: 1
            )
        }
        #expect(error?.localizedDescription.contains("booted, available") == true)
    }

    @Test("설치 앱의 bundle identity와 executable 경로를 함께 검증한다")
    func rejectsIdentityAndPathEscape() throws {
        let wrongBundle = try Fixture(info: [
            "CFBundleIdentifier": "dev.other.app", "CFBundleExecutable": "Probe"
        ])
        defer { wrongBundle.remove() }
        let wrongBundleError = #expect(throws: RuntimeTraceProcessError.self) {
            try wrongBundle.process().run(
                simulator: wrongBundle.simulator, bundleID: wrongBundle.bundleID,
                executablePath: wrongBundle.source.path, arguments: [], timeout: 1
            )
        }
        #expect(wrongBundleError?.localizedDescription.contains("matching bundle/executable identity") == true)

        let escaped = try Fixture(info: [
            "CFBundleIdentifier": "dev.cartograph.simulator-test", "CFBundleExecutable": "../outside"
        ])
        defer { escaped.remove() }
        let escapedError = #expect(throws: RuntimeTraceProcessError.self) {
            try escaped.process().run(
                simulator: escaped.simulator, bundleID: escaped.bundleID,
                executablePath: escaped.source.path, arguments: [], timeout: 1
            )
        }
        #expect(escapedError?.localizedDescription.contains("matching bundle/executable identity") == true)

        let linked = try Fixture(escapeInstalledExecutable: true)
        defer { linked.remove() }
        let linkedError = #expect(throws: RuntimeTraceProcessError.self) {
            try linked.process().run(
                simulator: linked.simulator, bundleID: linked.bundleID,
                executablePath: linked.source.path, arguments: [], timeout: 1
            )
        }
        #expect(linkedError?.localizedDescription.contains("escapes its bundle") == true)
    }

    @Test("설치 executable의 fingerprint가 다르면 launch 전에 중단한다")
    func rejectsInstalledBinaryMismatch() throws {
        let fixture = try Fixture(installedExecutableSource: URL(fileURLWithPath: "/bin/echo"))
        defer { fixture.remove() }

        let error = #expect(throws: RuntimeTraceProcessError.self) {
            try fixture.process().run(
                simulator: fixture.simulator, bundleID: fixture.bundleID,
                executablePath: fixture.source.path, arguments: [], timeout: 1
            )
        }
        #expect(error?.localizedDescription.contains("differs from --executable") == true)
        #expect(fixture.runner.requests.allSatisfy { !$0.arguments.contains(where: { $0 == "launch" }) })
    }

    @Test("동일 PID만 종료하고 다른 프로세스는 건드리지 않는다")
    func terminatesOnlyMatchingProcess() throws {
        let fixture = try Fixture(postLaunchProcessLists: [[42], []])
        defer { fixture.remove() }

        let execution = try fixture.process().run(
            simulator: fixture.simulator, bundleID: fixture.bundleID,
            executablePath: fixture.source.path, arguments: [], timeout: 1
        )

        #expect(execution.processID == 42)
        #expect(execution.runtimeIssues.contains {
            $0.contains("outlived the simulator launch session")
        })
        #expect(fixture.runner.terminationRequests.count == 1)

        let mismatched = try Fixture(postLaunchProcessLists: [[99]])
        defer { mismatched.remove() }
        let mismatchedExecution = try mismatched.process().run(
            simulator: mismatched.simulator, bundleID: mismatched.bundleID,
            executablePath: mismatched.source.path, arguments: [], timeout: 1
        )
        #expect(mismatchedExecution.runtimeIssues.contains {
            $0.contains("without the collected process identity")
        })
        #expect(mismatched.runner.terminationRequests.isEmpty)
    }

    @Test("복수 bundle PID는 임의의 하나를 종료하지 않는다")
    func refusesAmbiguousProcessIdentity() throws {
        let fixture = try Fixture(postLaunchProcessLists: [[42, 43]])
        defer { fixture.remove() }

        let execution = try fixture.process().run(
            simulator: fixture.simulator, bundleID: fixture.bundleID,
            executablePath: fixture.source.path, arguments: [], timeout: 1
        )

        #expect(execution.processID == 42)
        #expect(execution.runtimeIssues.contains {
            $0.contains("Multiple simulator processes match")
        })
        #expect(fixture.runner.terminationRequests.isEmpty)
    }

    @Test("launch 실패와 timeout은 PID와 종료 코드 근거 없이 부분 결과로 남긴다")
    func preservesLaunchFailureAndTimeout() throws {
        let failure = try Fixture(launchResult: .init(
            output: "", exitCode: 74, timedOut: false, issues: []
        ), status: nil)
        defer { failure.remove() }
        let failed = try failure.process().run(
            simulator: failure.simulator, bundleID: failure.bundleID,
            executablePath: failure.source.path, arguments: [], timeout: 1
        )
        #expect(failed.processID == nil)
        #expect(failed.processExitCode == nil)
        #expect(failed.runtimeIssues.contains { $0.contains("launch session failed") })
        #expect(failed.runtimeIssues.contains { $0.contains("did not identify exactly one") })

        let timeout = try Fixture(launchResult: .init(
            output: "", exitCode: nil, timedOut: true, issues: []
        ), status: nil)
        defer { timeout.remove() }
        let timedOut = try timeout.process().run(
            simulator: timeout.simulator, bundleID: timeout.bundleID,
            executablePath: timeout.source.path, arguments: [], timeout: 1
        )
        #expect(timedOut.timedOut)
        #expect(timedOut.runtimeIssues.contains { $0.contains("exceeded the collection timeout") })
    }

    @Test("종료 명령 성공 뒤에도 같은 PID가 남으면 cleanup 실패를 숨기지 않는다")
    func reportsTerminationTimeout() throws {
        let clock = TestClock()
        let fixture = try Fixture(postLaunchProcessLists: [[42], [42]], clock: clock)
        defer { fixture.remove() }

        let execution = try fixture.process().run(
            simulator: fixture.simulator, bundleID: fixture.bundleID,
            executablePath: fixture.source.path, arguments: [], timeout: 1
        )

        #expect(execution.runtimeIssues.contains {
            $0.contains("did not terminate")
        })
        #expect(clock.sleptIntervals.count >= 1)
        #expect(fixture.runner.terminationRequests.count == 1)
    }

    @Test("terminate 명령 실패도 실행 결과의 shutdown 문제로 남긴다")
    func reportsTerminationCommandFailure() throws {
        let fixture = try Fixture(
            postLaunchProcessLists: [[42]],
            terminationError: NSError(domain: "FixtureTerminate", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "fixture terminate denied"
            ])
        )
        defer { fixture.remove() }

        let execution = try fixture.process().run(
            simulator: fixture.simulator, bundleID: fixture.bundleID,
            executablePath: fixture.source.path, arguments: [], timeout: 1
        )

        #expect(execution.runtimeIssues.contains {
            $0.contains("shutdown could not be verified") && $0.contains("fixture terminate denied")
        })
        #expect(fixture.runner.terminationRequests.count == 1)
    }

    @Test("임시 경로 정리 실패는 반환된 실행 결과에 기록한다")
    func reportsCleanupFailure() throws {
        let fixture = try Fixture(postLaunchProcessLists: [], failRemoval: true)
        defer { fixture.remove() }

        let execution = try fixture.process().run(
            simulator: fixture.simulator, bundleID: fixture.bundleID,
            executablePath: fixture.source.path, arguments: [], timeout: 1
        )

        #expect(execution.runtimeIssues.contains {
            $0.contains("temporary directory could not be removed")
        })
        #expect(execution.runtimeIssues.contains {
            $0.contains("trace directory could not be removed")
        })
    }

    @Test("준비 실패 중 cleanup도 실패하면 두 원인을 함께 보존한다")
    func preservesPreparationAndCleanupFailures() throws {
        let fixture = try Fixture(
            preparationError: NSError(domain: "FixtureCommand", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "fixture command unavailable"
            ]),
            failRemoval: true
        )
        defer { fixture.remove() }

        let error = #expect(throws: RuntimeTraceProcessError.self) {
            try fixture.process().run(
                simulator: fixture.simulator, bundleID: fixture.bundleID,
                executablePath: fixture.source.path, arguments: [], timeout: 1
            )
        }
        #expect(error?.localizedDescription.contains("follow-up cleanup failed") == true)
        #expect(error?.localizedDescription.contains("fixture cleanup denied") == true)
    }

    @Test("launch 후 명령 판독이 실패해도 검증된 동일 PID만 복구 종료한다")
    func recoversOwnedProcessAfterLaunchError() throws {
        let fixture = try Fixture(
            postLaunchProcessLists: [[42], [42], []],
            launchError: NSError(domain: "FixtureLaunch", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "fixture launch output unavailable"
            ])
        )
        defer { fixture.remove() }

        let error = #expect(throws: (any Error).self) {
            try fixture.process().run(
                simulator: fixture.simulator, bundleID: fixture.bundleID,
                executablePath: fixture.source.path, arguments: [], timeout: 1
            )
        }
        #expect(error?.localizedDescription.contains("fixture launch output unavailable") == true)
        #expect(fixture.runner.terminationRequests.count == 1)
    }

    @Test("launch 후 collector PID가 없으면 남은 앱을 추측해 종료하지 않는다")
    func doesNotTerminateUnverifiedProcessAfterLaunchError() throws {
        let fixture = try Fixture(
            postLaunchProcessLists: [[42]],
            launchError: NSError(domain: "FixtureLaunch", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "fixture launch failed before collector status"
            ]),
            status: nil
        )
        defer { fixture.remove() }

        let error = #expect(throws: (any Error).self) {
            try fixture.process().run(
                simulator: fixture.simulator, bundleID: fixture.bundleID,
                executablePath: fixture.source.path, arguments: [], timeout: 1
            )
        }
        #expect(error?.localizedDescription.contains("fixture launch failed before collector status") == true)
        #expect(fixture.runner.terminationRequests.isEmpty)
    }

    @Test("launchctl 출력은 정확히 일치하는 bundle PID만 정렬해 반환한다")
    func parsesProcessListingWithoutGuessing() {
        let output = """
            99 0 UIKitApplication:other.app[abc]
            43 0 UIKitApplication:dev.cartograph.simulator-test[def]
            malformed row
            42 0 UIKitApplication:dev.cartograph.simulator-test[ghi]
            0 0 UIKitApplication:dev.cartograph.simulator-test[bad]
            """
        #expect(RuntimeSimulatorProcess.runningProcessIDs(
            from: output, bundleID: "dev.cartograph.simulator-test"
        ) == [42, 43])
    }

    @Test("실제 xcrun 명령마다 독립된 출력 파일을 보존한다")
    func realCommandRunnerUsesUniqueOutputFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-simulator-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = XCRunRuntimeSimulatorCommandRunner()
        let request = RuntimeSimulatorCommandRequest(
            arguments: ["--find", "swift"], directory: directory, environment: nil,
            timeout: 10, forwardOutput: false, waitForProcess: nil
        )

        let first = try runner.run(request)
        let second = try runner.run(request)

        #expect(first.exitCode == 0)
        #expect(second.exitCode == 0)
        #expect(!first.timedOut && !second.timedOut)
        #expect(!first.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!second.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let logs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("command-") && $0.pathExtension == "log" }
        #expect(logs.count == 2)
        #expect(logs[0].lastPathComponent != logs[1].lastPathComponent)
    }
}

private final class Fixture {
    let root: URL
    let app: URL
    let data: URL
    let source: URL
    let simulator = "EF6654D7-B424-446C-98B1-F9163912AF01"
    let bundleID = "dev.cartograph.simulator-test"
    let runner: ScenarioRunner
    let fileSystem: FixtureFileOperations
    let clock: TestClock

    init(
        deviceOutput: String? = nil,
        info: [String: Any]? = nil,
        installedExecutableSource: URL? = nil,
        escapeInstalledExecutable: Bool = false,
        postLaunchProcessLists: [[Int32]] = [],
        launchResult: RuntimeSimulatorCommandResult? = nil,
        preparationError: Error? = nil,
        launchError: Error? = nil,
        terminationError: Error? = nil,
        status: RuntimeCollectorStatus? = Fixture.successStatus,
        clock: TestClock? = nil,
        failRemoval: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-simulator-process-\(UUID().uuidString)", isDirectory: true)
        app = root.appendingPathComponent("Probe.app", isDirectory: true)
        data = root.appendingPathComponent("Data", isDirectory: true)
        source = root.appendingPathComponent("SourceProbe")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: data.appendingPathComponent("tmp"), withIntermediateDirectories: true
        )
        let defaultBundleID = "dev.cartograph.simulator-test"
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sh"), to: source)
        try FileManager.default.copyItem(
            at: installedExecutableSource ?? source, to: app.appendingPathComponent("Probe")
        )
        if escapeInstalledExecutable {
            try FileManager.default.removeItem(at: app.appendingPathComponent("Probe"))
            try FileManager.default.createSymbolicLink(
                at: app.appendingPathComponent("Probe"), withDestinationURL: source
            )
        }
        let plist = info ?? ["CFBundleIdentifier": defaultBundleID, "CFBundleExecutable": "Probe"]
        let infoData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try infoData.write(to: app.appendingPathComponent("Info.plist"))

        self.runner = ScenarioRunner(
            simulator: "EF6654D7-B424-446C-98B1-F9163912AF01", bundleID: defaultBundleID, app: app, data: data,
            deviceOutput: deviceOutput ?? Self.deviceJSON(),
            postLaunchProcessLists: postLaunchProcessLists,
            launchResult: launchResult,
            preparationError: preparationError,
            launchError: launchError,
            terminationError: terminationError
        )
        self.fileSystem = FixtureFileOperations(failRemoval: failRemoval)
        self.clock = clock ?? TestClock()
        self.runner.status = status
    }

    func process() -> RuntimeSimulatorProcess {
        RuntimeSimulatorProcess(
            fileSystem: fileSystem,
            commandRunner: runner,
            collectorCompiler: FixtureCollectorCompiler(source: source),
            traceReader: FixtureTraceReader(status: runner.status),
            clock: clock,
            environmentProvider: { [:] }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        if let temporaryDirectory = fileSystem.temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    static func deviceJSON(state: String = "Booted", available: Bool = true) -> String {
        let udid = "EF6654D7-B424-446C-98B1-F9163912AF01"
        return """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[{"udid":"\(udid)","state":"\(state)",
        "isAvailable":\(available)}]}}
        """
    }

    private static let successStatus = RuntimeCollectorStatus(
        recordedExitCode: 0, processID: 42, active: true, complete: true,
        emittedEvents: 0, droppedEvents: 0, truncatedValues: 0,
        hookMask: RuntimeCollectorStatus.expectedHookMask
    )

}

private final class ScenarioRunner: RuntimeSimulatorCommandRunning {
    let simulator: String
    let bundleID: String
    let app: URL
    let data: URL
    let deviceOutput: String
    let postLaunchProcessLists: [[Int32]]
    let launchResult: RuntimeSimulatorCommandResult?
    let preparationError: Error?
    let launchError: Error?
    let terminationError: Error?
    var status: RuntimeCollectorStatus?
    var requests: [RuntimeSimulatorCommandRequest] = []
    var terminationRequests: [[String]] = []
    private var processListIndex = 0

    init(
        simulator: String, bundleID: String, app: URL, data: URL, deviceOutput: String,
        postLaunchProcessLists: [[Int32]], launchResult: RuntimeSimulatorCommandResult?,
        preparationError: Error?, launchError: Error?, terminationError: Error?
    ) {
        self.simulator = simulator
        self.bundleID = bundleID
        self.app = app
        self.data = data
        self.deviceOutput = deviceOutput
        self.postLaunchProcessLists = postLaunchProcessLists
        self.launchResult = launchResult
        self.preparationError = preparationError
        self.launchError = launchError
        self.terminationError = terminationError
    }

    func run(_ request: RuntimeSimulatorCommandRequest) throws -> RuntimeSimulatorCommandResult {
        requests.append(request)
        let arguments = request.arguments
        if arguments == ["simctl", "list", "devices", "booted", "--json"] {
            if let preparationError { throw preparationError }
            return .init(output: deviceOutput, exitCode: 0, timedOut: false, issues: [])
        }
        if arguments.contains("--show-sdk-path") {
            return .init(output: "/sdk", exitCode: 0, timedOut: false, issues: [])
        }
        if arguments.contains("get_app_container") {
            return .init(
                output: arguments.last == "app" ? app.path : data.path,
                exitCode: 0, timedOut: false, issues: []
            )
        }
        if arguments.contains("launchctl") {
            let pids: [Int32]
            if processListIndex == 0 {
                pids = []
            } else {
                let offset = processListIndex - 1
                pids = postLaunchProcessLists.indices.contains(offset)
                    ? postLaunchProcessLists[offset] : postLaunchProcessLists.last ?? []
            }
            processListIndex += 1
            return .init(
                output: Self.processListing(pids, bundleID: bundleID), exitCode: 0,
                timedOut: false, issues: []
            )
        }
        if arguments.contains("terminate") {
            terminationRequests.append(arguments)
            if let terminationError { throw terminationError }
            return .init(output: "", exitCode: 0, timedOut: false, issues: [])
        }
        if arguments.contains("launch") {
            if let launchError { throw launchError }
            return launchResult ?? .init(
                output: "\(bundleID): 42\n", exitCode: 0, timedOut: false, issues: []
            )
        }
        return .init(output: "", exitCode: 0, timedOut: false, issues: [])
    }

    private static func processListing(_ pids: [Int32], bundleID: String) -> String {
        pids.map { "\($0) 0 UIKitApplication:\(bundleID)[fixture]" }.joined(separator: "\n")
    }
}

private struct FixtureCollectorCompiler: RuntimeSimulatorCollectorCompiling {
    let source: URL

    func compile(in directory: URL, simulatorSDK: String) throws -> URL {
        source
    }
}

private struct FixtureTraceReader: RuntimeSimulatorTraceReading {
    let status: RuntimeCollectorStatus?
    private let native: RuntimeTraceProcess

    init(status: RuntimeCollectorStatus?) {
        self.status = status
        self.native = RuntimeTraceProcess()
    }

    func status(at url: URL) -> RuntimeCollectorStatus? {
        guard let status else { return nil }
        try? write(status: status, to: url)
        return native.readStatus(at: url)
    }

    func log(at url: URL) -> RuntimeTraceLogParseResult {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
        return native.readLog(at: url)
    }

    private func write(status: RuntimeCollectorStatus, to url: URL) throws {
        var data = Data("CTTRACE1".utf8)
        append(UInt32(1), to: &data)
        append(status.processID, to: &data)
        append(status.active ? UInt32(1) : UInt32(0), to: &data)
        append(status.complete ? UInt32(1) : UInt32(0), to: &data)
        append(status.emittedEvents, to: &data)
        append(status.droppedEvents, to: &data)
        append(status.truncatedValues, to: &data)
        append(status.hookMask, to: &data)
        let exitMarker = status.recordedExitCode.map { UInt32($0 + 1) } ?? 0
        append(exitMarker, to: &data)
        try data.write(to: url)
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private final class FixtureFileOperations: RuntimeSimulatorFileOperations {
    private let local = LocalRuntimeSimulatorFileOperations()
    private let failRemoval: Bool
    private(set) var temporaryDirectory: URL?

    init(failRemoval: Bool) {
        self.failRemoval = failRemoval
    }

    func makeTemporaryDirectory() throws -> URL {
        let directory = try local.makeTemporaryDirectory()
        temporaryDirectory = directory
        return directory
    }

    func removeItem(at url: URL) throws {
        if failRemoval {
            throw NSError(domain: "FixtureFileOperations", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fixture cleanup denied"
            ])
        }
        try local.removeItem(at: url)
    }

    func createDirectory(at url: URL, attributes: [FileAttributeKey: Any]?) throws {
        try local.createDirectory(at: url, attributes: attributes)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try local.copyItem(at: source, to: destination)
    }

    func readData(at url: URL) throws -> Data { try local.readData(at: url) }
}

private final class TestClock: RuntimeSimulatorClock {
    private(set) var current: TimeInterval = 0
    private(set) var sleptIntervals: [TimeInterval] = []

    var uptime: TimeInterval { current }

    func sleep(for interval: TimeInterval) {
        sleptIntervals.append(interval)
        current += interval
    }
}
