import CartographCore
import Darwin
import Foundation

/// native collector가 기록을 닫고 불변 파일로 공개한 계수와 구간 길이.
struct RuntimeCheckpointSeal: Equatable {
    static let byteCount = 88
    let processID: Int32
    let emittedEvents: UInt64
    let droppedEvents: UInt64
    let truncatedValues: UInt64
    let hookMask: UInt32
    let elapsedNanoseconds: UInt64

    static func decode(_ data: Data, nonce: String, processID: Int32) -> Self? {
        guard data.count == byteCount, nonce.utf8.count == 32, processID > 0,
              data.prefix(8) == Data("CTSEAL01".utf8), data[16..<48] == Data(nonce.utf8),
              integer(UInt32.self, data, 8) == 1, integer(Int32.self, data, 12) == processID,
              integer(UInt32.self, data, 76) == 1 else { return nil }
        return Self(
            processID: processID, emittedEvents: integer(UInt64.self, data, 48),
            droppedEvents: integer(UInt64.self, data, 56), truncatedValues: integer(UInt64.self, data, 64),
            hookMask: integer(UInt32.self, data, 72), elapsedNanoseconds: integer(UInt64.self, data, 80)
        )
    }

    var status: RuntimeCollectorStatus {
        RuntimeCollectorStatus(
            processID: processID, active: true, complete: false,
            emittedEvents: emittedEvents, droppedEvents: droppedEvents,
            truncatedValues: truncatedValues, hookMask: hookMask
        )
    }

    private static func integer<T: FixedWidthInteger>(_: T.Type, _ data: Data, _ offset: Int) -> T {
        data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}

struct RuntimeTraceWindowExecution: Equatable {
    let requestedMilliseconds: Int
    let seal: RuntimeCheckpointSeal?
    let processOutcome: RuntimeTraceObservationWindow.ProcessOutcome
}

/// 프로세스 종료 신호와 분리된 요청·ack를 사용하여 기록 구간만 닫는다.
struct RuntimeCheckpoint {
    let requestURL: URL
    let ackURL: URL
    let nonce: String

    init(directory: URL) {
        requestURL = directory.appendingPathComponent("seal-request.bin")
        ackURL = directory.appendingPathComponent("seal-ack.bin")
        nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    func environment(prefix: String = "") -> [String: String] {
        [
            prefix + "CARTOGRAPH_RUNTIME_TRACE_SEAL_REQUEST": requestURL.path,
            prefix + "CARTOGRAPH_RUNTIME_TRACE_SEAL_ACK": ackURL.path,
            prefix + "CARTOGRAPH_RUNTIME_TRACE_SEAL_NONCE": nonce,
        ]
    }

    struct Result {
        let processID: Int32?
        let status: RuntimeCollectorStatus?
        let seal: RuntimeCheckpointSeal?
        let issues: [String]
    }

    func capture(
        requestedMilliseconds: Int, deadline: TimeInterval, statusURL: URL,
        isRunning: () -> Bool, resolveProcessID: () throws -> Int32?
    ) -> Result {
        var status: RuntimeCollectorStatus?
        var processID: Int32?
        do {
            while isRunning(), ProcessInfo.processInfo.systemUptime < deadline {
                status = RuntimeCollectorStatus.read(at: statusURL)
                if let candidate = status, candidate.active, let pid = try resolveProcessID(), pid > 0,
                   pid == candidate.processID {
                    processID = pid
                    break
                }
                usleep(10_000)
            }
            guard let processID else {
                return Result(processID: nil, status: status, seal: nil,
                    issues: ["The application did not provide a matching collector/PID handshake before the deadline."])
            }
            let target = ProcessInfo.processInfo.systemUptime + Double(requestedMilliseconds) / 1_000
            while isRunning(), ProcessInfo.processInfo.systemUptime < min(target, deadline) { usleep(10_000) }
            guard isRunning(), ProcessInfo.processInfo.systemUptime >= target,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                return Result(processID: processID, status: status, seal: nil,
                    issues: ["The application exited or timed out before the requested observation interval ended."])
            }
            try request(processID: processID, milliseconds: requestedMilliseconds)
            while ProcessInfo.processInfo.systemUptime < deadline {
                if FileManager.default.fileExists(atPath: ackURL.path) {
                    guard let seal = readSeal(processID: processID) else {
                        return Result(processID: processID, status: status, seal: nil,
                            issues: ["The collector checkpoint acknowledgement is malformed or has the wrong identity."]
                        )
                    }
                    return Result(processID: processID, status: status, seal: seal, issues: [])
                }
                guard isRunning() else { break }
                usleep(10_000)
            }
        } catch {
            return Result(processID: processID, status: status, seal: nil,
                issues: ["The observation checkpoint could not be requested: \(error.localizedDescription)"])
        }
        return Result(processID: processID, status: status, seal: nil,
            issues: ["The collector did not acknowledge a sealed observation window before exit or timeout."])
    }

    private func request(processID: Int32, milliseconds: Int) throws {
        var data = Data("CTREQ001".utf8)
        append(UInt32(1), to: &data)
        append(processID, to: &data)
        data.append(Data(nonce.utf8))
        append(UInt64(milliseconds), to: &data)
        let descriptor = open(requestURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RuntimeCheckpointError.requestUnavailable }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(descriptor) == 0 else { throw RuntimeCheckpointError.requestUnavailable }
    }

    private func readSeal(processID: Int32) -> RuntimeCheckpointSeal? {
        let descriptor = open(ackURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: RuntimeCheckpointSeal.byteCount + 1)
        let count = read(descriptor, &bytes, bytes.count)
        guard count == RuntimeCheckpointSeal.byteCount else { return nil }
        return RuntimeCheckpointSeal.decode(Data(bytes.prefix(count)), nonce: nonce, processID: processID)
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private enum RuntimeCheckpointError: Error, LocalizedError {
    case requestUnavailable

    var errorDescription: String? {
        "Could not create the private checkpoint request; check temporary file permissions and retry collection"
    }
}
