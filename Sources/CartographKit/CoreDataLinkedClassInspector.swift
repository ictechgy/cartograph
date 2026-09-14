import CartographCore
import Foundation

/// 생성 클래스가 제시된 인덱스에만 있고 앱에는 링크되지 않은 경우를 거부한다.
struct CoreDataLinkedClassInspector {
    static let maximumOutputBytes = 16 * 1_024 * 1_024
    static let maximumSymbols = 200_000

    func symbols(in executablePath: String) throws -> Set<String> {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-gjU", "--", executablePath]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw invalid(executablePath, "Could not inspect linked app symbols with nm.") }
        let timeout = CoreDataSymbolProcessTimeout(process: process)
        timeout.start(after: 15)
        defer { timeout.cancel() }
        let data = try readBounded(output.fileHandleForReading, process: process, path: executablePath)
        process.waitUntilExit()
        guard !timeout.didExpire else {
            throw invalid(executablePath, "nm timed out while reading the app executable symbols.")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            throw invalid(executablePath, "nm could not read the built app executable symbols.")
        }
        let values = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard values.count <= Self.maximumSymbols,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }) else {
            throw invalid(executablePath, "The executable symbol table exceeds the supported bounds.")
        }
        return Set(values)
    }

    private func readBounded(
        _ handle: FileHandle,
        process: Process,
        path: String
    ) throws -> Data {
        defer { try? handle.close() }
        var result = Data()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                result.append(chunk)
                guard result.count <= Self.maximumOutputBytes else {
                    process.terminate()
                    throw invalid(path, "The executable symbol table exceeds 16 MiB.")
                }
            }
        } catch let error as CartographError {
            throw error
        } catch {
            process.terminate()
            throw invalid(path, "Could not read the executable symbol table.")
        }
        return result
    }

    private func invalid(_ path: String, _ reason: String) -> CartographError {
        .invalidConfiguration(path: path, reason: reason)
    }
}

private final class CoreDataSymbolProcessTimeout: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var workItem: DispatchWorkItem?
    private var expired = false

    init(process: Process) { self.process = process }

    var didExpire: Bool { lock.withLock { expired } }

    func start(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.withLock { expired = true }
            if process.isRunning { process.terminate() }
        }
        lock.withLock { workItem = item }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() {
        lock.withLock {
            workItem?.cancel()
            workItem = nil
        }
    }
}
