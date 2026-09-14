import Darwin
import Foundation

/// Simulator 수집이 운영체제 경계와 분리되어 실패 조합을 재현할 수 있게 하는 단조 시계.
protocol RuntimeSimulatorClock {
    var uptime: TimeInterval { get }
    func sleep(for interval: TimeInterval)
}

struct SystemRuntimeSimulatorClock: RuntimeSimulatorClock {
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(for interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}

/// `RuntimeSimulatorProcess`가 사용하는 파일 작업 경계.
protocol RuntimeSimulatorFileOperations {
    func makeTemporaryDirectory() throws -> URL
    func removeItem(at url: URL) throws
    func createDirectory(at url: URL, attributes: [FileAttributeKey: Any]?) throws
    func copyItem(at source: URL, to destination: URL) throws
    func readData(at url: URL) throws -> Data
}

struct LocalRuntimeSimulatorFileOperations: RuntimeSimulatorFileOperations {
    func makeTemporaryDirectory() throws -> URL {
        try RuntimeTraceProcess().makeTemporaryDirectory()
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func createDirectory(at url: URL, attributes: [FileAttributeKey: Any]?) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: attributes
        )
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

}

/// `xcrun simctl` 한 번의 결과.
/// 표준 오류는 실행 중 바로 전달할 수 있지만 판정은 이 값으로 한다.
struct RuntimeSimulatorCommandResult {
    let output: String
    let exitCode: Int?
    let timedOut: Bool
    let issues: [String]
}

struct RuntimeSimulatorCommandRequest {
    let arguments: [String]
    let directory: URL
    let environment: [String: String]?
    let timeout: TimeInterval
    let forwardOutput: Bool
    let waitForProcess: ((Process) -> Bool)?
}

/// Simulator 명령을 외부 프로세스에서 분리한다.
/// 테스트는 simctl의 실제 출력과 상태 전이를 제공한다.
protocol RuntimeSimulatorCommandRunning {
    func run(_ request: RuntimeSimulatorCommandRequest) throws -> RuntimeSimulatorCommandResult
}

/// 앱에 주입할 native collector의 생성 경계.
protocol RuntimeSimulatorCollectorCompiling {
    func compile(in directory: URL, simulatorSDK: String) throws -> URL
}

struct NativeRuntimeSimulatorCollectorCompiler: RuntimeSimulatorCollectorCompiling {
    private let native: RuntimeTraceProcess

    init(native: RuntimeTraceProcess = RuntimeTraceProcess()) {
        self.native = native
    }

    func compile(in directory: URL, simulatorSDK: String) throws -> URL {
        try native.compileCollector(in: directory, simulatorSDK: simulatorSDK)
    }
}

/// trace 파일 판독을 주입해 실행 수명주기 테스트가 collector 자체에 의존하지 않게 한다.
protocol RuntimeSimulatorTraceReading {
    func status(at url: URL) -> RuntimeCollectorStatus?
    func log(at url: URL) -> RuntimeTraceLogParseResult
}

struct NativeRuntimeSimulatorTraceReader: RuntimeSimulatorTraceReading {
    private let native: RuntimeTraceProcess

    init(native: RuntimeTraceProcess = RuntimeTraceProcess()) {
        self.native = native
    }

    func status(at url: URL) -> RuntimeCollectorStatus? {
        native.readStatus(at: url)
    }

    func log(at url: URL) -> RuntimeTraceLogParseResult {
        native.readLog(at: url)
    }
}

struct XCRunRuntimeSimulatorCommandRunner: RuntimeSimulatorCommandRunning {
    static let maxOutputBytes = 16 * 1_024 * 1_024

    private let clock: any RuntimeSimulatorClock

    init(clock: any RuntimeSimulatorClock = SystemRuntimeSimulatorClock()) {
        self.clock = clock
    }

    func run(_ request: RuntimeSimulatorCommandRequest) throws -> RuntimeSimulatorCommandResult {
        let outputURL = request.directory.appendingPathComponent(
            "command-" + UUID().uuidString + ".log"
        )
        guard FileManager.default.createFile(
            atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else {
            throw RuntimeTraceProcessError.simulatorPreparationFailed(
                "Could not create private simulator command output; check the temporary directory"
            )
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardOutput = handle
        process.standardError = FileHandle.standardError
        try process.run()
        let timedOut = request.waitForProcess?(process) ?? wait(for: process, timeout: request.timeout)
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: Self.maxOutputBytes + 1) ?? Data()
        let bounded = data.prefix(Self.maxOutputBytes)
        if request.forwardOutput { FileHandle.standardError.write(bounded) }
        return RuntimeSimulatorCommandResult(
            output: String(decoding: bounded, as: UTF8.self),
            exitCode: process.terminationReason == .exit ? Int(process.terminationStatus) : nil,
            timedOut: timedOut,
            issues: data.count > Self.maxOutputBytes
                ? ["Simulator console output exceeded the collection limit."] : []
        )
    }

    private func wait(for process: Process, timeout: TimeInterval) -> Bool {
        let deadline = clock.uptime + timeout
        while process.isRunning, clock.uptime < deadline {
            clock.sleep(for: 0.01)
        }
        guard process.isRunning else {
            process.waitUntilExit()
            return false
        }
        process.terminate()
        let grace = clock.uptime + 1
        while process.isRunning, clock.uptime < grace {
            clock.sleep(for: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return true
    }
}
