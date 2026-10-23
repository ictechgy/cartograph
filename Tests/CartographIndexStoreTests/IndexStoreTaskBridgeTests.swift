@testable import CartographIndexStore
import Dispatch
import Foundation
import Testing

@Suite("인덱스 로더의 동기·비동기 경계")
struct IndexStoreTaskBridgeTests {
    @Test("로더 오류를 빈 성공으로 바꾸지 않는다")
    func preservesFailure() {
        #expect(throws: Failure.example) {
            try IndexStoreTaskBridge.wait { () -> Int in throw Failure.example }
        }
    }

    @Test("로더가 완료되지 않으면 제한 시간에 실패하고 부분 값을 반환하지 않는다")
    func boundsWait() {
        #expect(throws: IndexStoreTaskBridge.BridgeError.timedOut) {
            try IndexStoreTaskBridge.wait(timeout: .milliseconds(1)) {
                try await Task.sleep(for: .seconds(30))
                return 42
            }
        }
    }

    @Test("취소를 무시하고 늦게 끝나는 로더도 timeout 이후 값을 보관하고 완료 뒤 해제한다")
    func lateCompletionReleasesCapturedState() async throws {
        let released = DispatchSemaphore(value: 0)
        let finishAllowed = DispatchSemaphore(value: 0)
        var probe: LifetimeProbe? = LifetimeProbe(released: released)
        weak var weakProbe = probe
        #expect(throws: IndexStoreTaskBridge.BridgeError.timedOut) {
            try IndexStoreTaskBridge.wait(timeout: .milliseconds(1)) { [probe = probe!] in
                await withCheckedContinuation { continuation in
                    // C 로더처럼 task cancellation을 확인하지 않는 작업이다.
                    DispatchQueue.global().async {
                        _ = finishAllowed.wait(timeout: .now() + 5)
                        continuation.resume(returning: probe.value)
                    }
                }
            }
        }
        probe = nil
        #expect(weakProbe != nil)
        finishAllowed.signal()
        let didRelease = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: released.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(didRelease)
        #expect(weakProbe == nil)
    }

    @Test("여러 동기 대기가 같은 기본 actor 로더의 실행기를 고갈시키지 않는다")
    func concurrentDefaultActorLoads() async throws {
        let registry = Registry()
        let count = min(32, max(8, ProcessInfo.processInfo.activeProcessorCount * 2))
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for value in 0..<count {
                group.addTask {
                    if #available(macOS 15, *) {
                        return try IndexStoreTaskBridge.wait(timeout: .seconds(10)) {
                            await registry.load(value)
                        }
                    }
                    // macOS 14는 blocking API를 dispatch에 두는 제품 async 진입로와 같은 계약이다.
                    return try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global().async {
                            continuation.resume(with: Result {
                                try IndexStoreTaskBridge.wait(timeout: .seconds(10)) {
                                    await registry.load(value)
                                }
                            })
                        }
                    }
                }
            }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values.sorted()
        }
        #expect(values == Array(0..<count))
    }

    private actor Registry {
        func load(_ value: Int) -> Int { value }
    }

    private final class LifetimeProbe: Sendable {
        let released: DispatchSemaphore
        let value = 42
        init(released: DispatchSemaphore) { self.released = released }
        deinit { released.signal() }
    }

    private enum Failure: Error, Equatable { case example }
}
