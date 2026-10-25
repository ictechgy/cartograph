import Darwin
import Foundation

/// 동기 파일 처리 중 종료 요청을 기록해 복구를 마친 뒤 CLI 실패로 돌려준다.
final class FixSignalGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int32?
    private var sources: [DispatchSourceSignal] = []
    private var previous: [(Int32, sig_t?)] = []

    /// 읽기·분석 중에는 기본 종료 동작을 유지하고, 쓰기 직전에만 복구를 보호한다.
    func activate() {
        guard previous.isEmpty else { return }
        for number in [SIGINT, SIGTERM] {
            previous.append((number, Darwin.signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.received = self.received ?? number
                self.lock.unlock()
            }
            source.resume()
            sources.append(source)
        }
    }

    var interruption: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    deinit {
        for source in sources { source.cancel() }
        for (number, handler) in previous { Darwin.signal(number, handler) }
    }
}
