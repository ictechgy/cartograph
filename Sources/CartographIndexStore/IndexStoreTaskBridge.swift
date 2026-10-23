import Dispatch
import Foundation

/// 동기 API가 기다리는 async 로더를 대기 중인 cooperative pool과 분리한다.
enum IndexStoreTaskBridge {
    static func wait<Value: Sendable>(
        timeout: DispatchTimeInterval = .seconds(30),
        operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = ResultBox<Value>()
        let work: @Sendable () async -> Void = {
            do { box.result = .success(try await operation()) }
            catch { box.result = .failure(error) }
            box.completed.signal()
        }
        let task: Task<Void, Never>
        if #available(macOS 15, *) {
            // 기본 actor인 upstream 라이브러리 registry도 이 task executor를 이어받는다.
            task = Task.detached(executorPreference: LoaderExecutor.shared, operation: work)
        } else {
            // macOS 14의 CLI 호환 경로다. async 임베더는 loadSnapshotAsync()를 사용한다.
            task = Task.detached(operation: work)
        }
        guard box.completed.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            // 취소는 협조적이다. 로더 종료를 보장하거나 부분 결과를 성공으로 반환하지 않는다.
            throw BridgeError.timedOut
        }
        guard let result = box.result else { throw BridgeError.missingResult }
        return try result.get()
    }

    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        let completed = DispatchSemaphore(value: 0)
        // 작업 하나만 쓰고 semaphore가 성공한 뒤에만 읽는다. timeout 경로는 읽지 않는다.
        var result: Result<Value, Error>?
    }

    @available(macOS 15, *)
    private final class LoaderExecutor: TaskExecutor {
        static let shared = LoaderExecutor()
        private let queue = DispatchQueue(label: "org.cartograph.indexstore-loader", qos: .userInitiated)

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            let executor = asUnownedTaskExecutor()
            queue.async { job.runSynchronously(on: executor) }
        }
    }

    enum BridgeError: Error, LocalizedError, Equatable {
        case timedOut
        case missingResult

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Index-store loader did not finish within its wait budget; no snapshot was returned. "
                    + "On macOS 14, async callers should use IndexStoreProvider.loadSnapshotAsync(). "
                    + "Loader cancellation is cooperative and its termination is not confirmed."
            case .missingResult:
                return "Index-store loader finished without a result; no snapshot was returned."
            }
        }
    }
}
