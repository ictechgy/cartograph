import CartographCore
import CartographKit
import Dispatch
import Foundation

/// 상태 잠금은 짧게, AnalysisSession 접근은 전용 직렬 큐에서만 수행한다.
/// 동기 인덱스 읽기를 강제로 중단하지 않으며 취소·만료된 세대는 결과를 게시하지 않는다.
final class MCPPreparation: @unchecked Sendable {
    enum State: String, Codable, Sendable {
        case idle, queued, running, ready, failed, cancelled, expired, closed
    }

    struct Status: Codable, Sendable {
        let state: State
        let phase: String
        let preparationGeneration: Int
        let workerActive: Bool
        let analysisInProgress: Bool
        let cancellationRequested: Bool
        let elapsedMilliseconds: Int?
        let timeoutSeconds: Int?
        let session: AnalysisSession.Metadata?
        let error: String?
        let inputFreshness: String
        let limitations: [String]
    }

    private let queue = DispatchQueue(label: "cartograph.mcp.analysis")
    private let lock = NSLock()
    private let factory: () throws -> AnalysisSession
    private let now: () -> TimeInterval
    // 이 세션과 접근 표시는 queue 안에서만 읽고 쓴다.
    private var session: AnalysisSession?
    private var sessionAccessed = false
    // 아래 상태는 lock 안에서만 읽고 쓴다. status는 queue를 기다리지 않는다.
    private var state: State = .idle
    private var phase = "idle"
    private var generation = 0
    private var workerActive = false
    private var analysisInProgress = false
    private var cancellationRequested = false
    private var startedAt: TimeInterval?
    private var endedAt: TimeInterval?
    private var timeoutSeconds: Int?
    private var cachedMetadata: AnalysisSession.Metadata?
    private var failure: String?
    private var deadlineWork: DispatchWorkItem?

    init(factory: @escaping () throws -> AnalysisSession,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.factory = factory
        self.now = now
    }

    func status() -> Status {
        lock.withLock {
            expireIfNeeded()
            return snapshot()
        }
    }

    /// 하나의 백그라운드 작업만 소유한다. 재요청은 실행 중인 동일 세대를 돌려준다.
    func start(refresh: Bool, timeout: Int) throws -> Status {
        try lock.withLock {
            expireIfNeeded()
            guard state != .closed else { throw MCPToolFailure(message: "MCP preparation is closed") }
            guard (1...600).contains(timeout), generation < Int.max else {
                throw MCPToolFailure(message: "Preparation timeout must be 1...600 seconds; "
                    + "restart an exhausted session")
            }
            if workerActive { return snapshot() }
            guard !analysisInProgress else {
                throw MCPToolFailure(message: "An analysis request is running; retry preparation after it completes")
            }
            generation += 1
            let acceptedGeneration = generation
            state = .queued
            phase = "queued"
            workerActive = true
            cancellationRequested = false
            startedAt = now()
            endedAt = nil
            timeoutSeconds = timeout
            cachedMetadata = nil
            failure = nil
            let deadline = DispatchWorkItem { [weak self] in self?.expire(generation: acceptedGeneration) }
            deadlineWork?.cancel()
            deadlineWork = deadline
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: deadline)
            queue.async { [weak self] in self?.prepare(generation: acceptedGeneration, refresh: refresh) }
            return snapshot()
        }
    }

    func cancel(generation expected: Int) throws -> Status {
        try lock.withLock {
            expireIfNeeded()
            guard expected > 0, expected == generation else {
                throw MCPToolFailure(message: "Preparation generation changed; read status before cancelling")
            }
            if workerActive, state == .queued || state == .running {
                cancellationRequested = true
                state = .cancelled
                phase = "cancellation-requested"
                endedAt = now()
                deadlineWork?.cancel()
                deadlineWork = nil
            }
            return snapshot()
        }
    }

    /// 기존 동기 도구의 검증 순서와 신선도 확인을 유지하되 세션 접근은 겹치지 않게 한다.
    func perform<Value>(_ operation: () throws -> Value) throws -> Value {
        try lock.withLock {
            expireIfNeeded()
            guard state != .closed else { throw MCPToolFailure(message: "MCP preparation is closed") }
            guard !workerActive, !analysisInProgress else {
                throw MCPToolFailure(message: "Analysis preparation or another request is still running; "
                    + "poll cartograph_prepare with action status before retrying")
            }
            analysisInProgress = true
            state = .running
            phase = "analysis-request"
            failure = nil
            cancellationRequested = false
            startedAt = nil
            endedAt = nil
            timeoutSeconds = nil
        }
        return try queue.sync {
            sessionAccessed = false
            defer {
                let completedSession = session
                lock.withLock {
                    analysisInProgress = false
                    guard state != .closed else { session = nil; return }
                    cachedMetadata = session?.metadata
                    state = cachedMetadata != nil ? .ready : (sessionAccessed ? .failed : .idle)
                    phase = state.rawValue
                }
                // 큰 그래프의 마지막 해제는 상태 잠금 밖에서 일어난다.
                withExtendedLifetime(completedSession) {}
            }
            do { return try operation() }
            catch {
                if sessionAccessed, session?.metadata == nil {
                    lock.withLock { failure = Self.message(for: error) }
                }
                throw error
            }
        }
    }

    func requireSession() throws -> AnalysisSession {
        dispatchPrecondition(condition: .onQueue(queue))
        sessionAccessed = true
        if let session { return session }
        lock.withLock { if state != .closed { phase = "creating-session" } }
        let created = try factory()
        session = created
        return created
    }

    /// EOF 이후에도 늦게 돌아온 동기 읽기 결과를 게시하지 않는다. 기다리거나 임의 중단하지 않는다.
    func shutdown() {
        lock.withLock {
            state = .closed
            phase = "closed"
            cancellationRequested = workerActive
            cachedMetadata = nil
            endedAt = now()
            deadlineWork?.cancel()
            deadlineWork = nil
        }
    }

    private func prepare(generation expected: Int, refresh: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        let accepted = lock.withLock {
            expireIfNeeded()
            guard generation == expected, state == .queued else { return false }
            state = .running
            phase = session == nil ? "creating-session" : (refresh ? "refreshing-session" : "checking-inputs")
            return true
        }
        guard accepted else { finish(generation: expected, candidate: nil, error: nil); return }
        do {
            let candidate: AnalysisSession
            if let session {
                candidate = session
                if refresh { _ = try candidate.refresh() } else { _ = try candidate.status() }
            } else {
                candidate = try factory()
            }
            guard candidate.metadata != nil else { throw AnalysisSessionError.unavailable }
            finish(generation: expected, candidate: candidate, error: nil)
        } catch {
            finish(generation: expected, candidate: nil, error: error)
        }
    }

    private func finish(generation expected: Int, candidate: AnalysisSession?, error: (any Error)?) {
        let previousSession = session
        lock.withLock {
            expireIfNeeded()
            guard generation == expected else { return }
            workerActive = false
            deadlineWork?.cancel()
            deadlineWork = nil
            if state == .running, let candidate, error == nil {
                session = candidate
                cachedMetadata = candidate.metadata
                state = .ready
                phase = "ready"
            } else {
                session = nil
                cachedMetadata = nil
                if state == .running {
                    state = .failed
                    phase = "failed"
                    failure = error.map(Self.message(for:)) ?? "Session preparation did not produce metadata"
                }
            }
            if endedAt == nil { endedAt = now() }
        }
        withExtendedLifetime(previousSession) {}
    }

    private func expire(generation expected: Int) {
        lock.withLock {
            guard generation == expected else { return }
            expireIfNeeded()
        }
    }

    private func expireIfNeeded() {
        guard workerActive, state == .queued || state == .running,
              let startedAt, let timeoutSeconds, now() - startedAt >= Double(timeoutSeconds) else { return }
        state = .expired
        phase = "deadline-exceeded"
        cancellationRequested = true
        endedAt = now()
        cachedMetadata = nil
    }

    private func snapshot() -> Status {
        var limitations = ["preparation-status: cached metadata only; analysis requests retain their configured "
            + "input freshness checks. Readiness does not mean the analysis is complete or safe."]
        if workerActive {
            limitations.append("preparation-cancellation: cancellation or expiry discards late results; "
                + "a synchronous index read may continue until it returns. No replacement worker starts meanwhile.")
        }
        if let cachedMetadata { limitations += cachedMetadata.limitations }
        return Status(state: state, phase: phase, preparationGeneration: generation,
            workerActive: workerActive, analysisInProgress: analysisInProgress,
            cancellationRequested: cancellationRequested,
            elapsedMilliseconds: startedAt.map { Int(max(0, ((endedAt ?? now()) - $0) * 1000)) },
            timeoutSeconds: timeoutSeconds, session: cachedMetadata, error: failure,
            inputFreshness: "not-rechecked-by-status", limitations: limitations)
    }

    private static func message(for error: any Error) -> String {
        let message: String
        if let error = error as? CartographError {
            message = error.errorDescription ?? "Cartograph preparation failed; check analysis inputs and retry"
        } else if let error = error as? AnalysisSessionError {
            message = error.errorDescription ?? "Session preparation failed; check analysis inputs and retry"
        } else if let error = error as? MCPToolFailure {
            message = error.message
        } else {
            message = "Cartograph preparation failed; check analysis inputs and retry"
        }
        return MCPToolFailure(message: message).message
    }
}
