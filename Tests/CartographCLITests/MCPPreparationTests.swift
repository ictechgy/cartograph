import CartographCore
import CartographKit
import CartographTestSupport
import Dispatch
import Foundation
@testable import cartograph
import Testing

@Suite("MCP background preparation")
struct MCPPreparationTests {
    private static func session(fingerprint: @escaping () throws -> String = { "first" }) throws -> AnalysisSession {
        var builder = SnapshotBuilder(path: "/p/App.swift")
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        let service = CartographService(configuration: .init(projectPath: "/p"),
            environment: .init(fileSystem: InMemoryFileSystem(),
                indexProviderOverride: StaticIndexProvider(builder.build())))
        return try AnalysisSession(serviceFactory: { service }, inputFingerprintProvider: fingerprint)
    }

    private func waitUntil(_ predicate: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WaitFailure() }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private struct WaitFailure: Error {}

    @Test("상태는 준비하지 않고 지연된 네이티브 작업을 기다리지 않는다")
    func coldStatusAndNonblockingPoll() throws {
        let gate = PreparationGate()
        let preparation = MCPPreparation(factory: { try gate.enter(); return try Self.session() })
        defer { gate.release.signal(); preparation.shutdown() }
        #expect(preparation.status().state == .idle)
        #expect(gate.count == 0)
        let started = try preparation.start(refresh: false, timeout: 30)
        #expect(started.state == .queued)
        #expect(started.preparationGeneration == 1)
        #expect(gate.entered.wait(timeout: .now() + 5) == .success)
        let before = ProcessInfo.processInfo.systemUptime
        let running = preparation.status()
        #expect(ProcessInfo.processInfo.systemUptime - before < 1)
        #expect(running.state == .running)
        #expect(running.phase == "creating-session")
        #expect(running.workerActive)
        #expect(running.session == nil)
        #expect(running.inputFreshness == "not-rechecked-by-status")
        #expect(running.limitations.contains { $0.hasPrefix("preparation-cancellation:") })
        #expect(try preparation.start(refresh: true, timeout: 30).preparationGeneration == 1)
        #expect(throws: MCPToolFailure.self) { try preparation.perform { 42 } }
        #expect(gate.count == 1)
        gate.release.signal()
        try waitUntil { preparation.status().state == .ready }
        #expect(preparation.status().session?.generation == 1)
        #expect(!preparation.status().workerActive)
    }

    @Test("동시 시작은 단일 작업만 소유하고 취소한 세대의 늦은 결과를 버린다")
    func concurrentStartsAndCancellation() throws {
        let gate = PreparationGate()
        let preparation = MCPPreparation(factory: { try gate.enter(); return try Self.session() })
        defer { gate.release.signal(); preparation.shutdown() }
        let group = DispatchGroup()
        let generations = LockedValues<Int>()
        for _ in 0..<12 {
            group.enter()
            // 전체 Swift Testing 실행의 공유 pool 예약 지연을 준비기 잠금 실패로 오인하지 않는다.
            // 실제 별도 호출자 12개를 동시에 실행해 준비기의 잠금·세대 규칙을 검증한다.
            Thread.detachNewThread {
                defer { group.leave() }
                do { generations.append(try preparation.start(refresh: false, timeout: 30).preparationGeneration) }
                catch { generations.append(-1) }
            }
        }
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(gate.entered.wait(timeout: .now() + 5) == .success)
        #expect(generations.values == Array(repeating: 1, count: 12))
        #expect(gate.count == 1)
        let cancelled = try preparation.cancel(generation: 1)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.cancellationRequested && cancelled.workerActive)
        #expect(try preparation.start(refresh: false, timeout: 30).state == .cancelled)
        gate.release.signal()
        try waitUntil { !preparation.status().workerActive }
        #expect(preparation.status().state == .cancelled)
        #expect(preparation.status().session == nil)
        let retry = try preparation.start(refresh: false, timeout: 30)
        #expect(retry.preparationGeneration == 2)
        #expect(throws: MCPToolFailure.self) { try preparation.cancel(generation: 1) }
        #expect(gate.entered.wait(timeout: .now() + 5) == .success)
        gate.release.signal()
        try waitUntil { preparation.status().state == .ready }
        #expect(gate.count == 2)
    }

    @Test("기한 초과는 새 작업을 허용하거나 늦은 결과를 게시하지 않는다")
    func deadlineAndShutdown() throws {
        let gate = PreparationGate()
        let clock = PreparationClock()
        let preparation = MCPPreparation(factory: { try gate.enter(); return try Self.session() }, now: { clock.now })
        defer { gate.release.signal(); preparation.shutdown() }
        _ = try preparation.start(refresh: false, timeout: 1)
        #expect(gate.entered.wait(timeout: .now() + 5) == .success)
        clock.advance(by: 2)
        let expired = preparation.status()
        #expect(expired.state == .expired)
        #expect(expired.elapsedMilliseconds == 2_000)
        #expect(expired.workerActive && expired.cancellationRequested)
        #expect(try preparation.start(refresh: false, timeout: 30).preparationGeneration == 1)
        gate.release.signal()
        try waitUntil { !preparation.status().workerActive }
        #expect(preparation.status().state == .expired)
        #expect(preparation.status().session == nil)
        _ = try preparation.start(refresh: false, timeout: 30)
        #expect(gate.entered.wait(timeout: .now() + 5) == .success)
        preparation.shutdown()
        #expect(preparation.status().state == .closed)
        #expect(preparation.status().workerActive)
        #expect(throws: MCPToolFailure.self) { try preparation.start(refresh: false, timeout: 30) }
        #expect(throws: MCPToolFailure.self) { try preparation.perform { 42 } }
        gate.release.signal()
        try waitUntil { !preparation.status().workerActive }
        #expect(preparation.status().state == .closed)
        #expect(preparation.status().session == nil)
    }

    @Test("취소 후 일반 요청으로 복구한 상태에 이전 준비 기한과 취소 표시가 남지 않는다")
    func foregroundRecoveryClearsCancelledJobMetadata() throws {
        let gate = PreparationGate()
        let preparation = MCPPreparation(factory: { try gate.enter(); return try Self.session() })
        defer { gate.release.signal(); preparation.shutdown() }
        _ = try preparation.start(refresh: false, timeout: 30)
        #expect(gate.entered.wait(timeout: .now() + 5) == .success)
        _ = try preparation.cancel(generation: 1)
        gate.release.signal()
        try waitUntil { !preparation.status().workerActive }
        #expect(preparation.status().cancellationRequested)
        #expect(preparation.status().timeoutSeconds == 30)
        gate.release.signal()
        _ = try preparation.perform { try preparation.requireSession().status() }
        let recovered = preparation.status()
        #expect(recovered.state == .ready)
        #expect(!recovered.cancellationRequested)
        #expect(recovered.elapsedMilliseconds == nil)
        #expect(recovered.timeoutSeconds == nil)
        #expect(recovered.preparationGeneration == 1)
        #expect(recovered.session?.generation == 1)
        #expect(gate.count == 2)
    }

    @Test("실패 후 재시도와 강제 갱신은 기존 세션의 신선도 규칙을 유지한다")
    func failureRetryRefreshAndFreshness() throws {
        let counter = LockedValues<Int>()
        let fingerprint = PreparationClock()
        let preparation = MCPPreparation(factory: {
            counter.append(1)
            if counter.values.count == 1 { throw AnalysisSessionError.unavailable }
            return try Self.session(fingerprint: { String(fingerprint.now) })
        })
        defer { preparation.shutdown() }
        _ = try preparation.start(refresh: false, timeout: 30)
        try waitUntil { preparation.status().state == .failed }
        #expect(preparation.status().error?.contains("discarded") == true)
        #expect(preparation.status().session == nil)
        _ = try preparation.start(refresh: false, timeout: 30)
        try waitUntil { preparation.status().state == .ready }
        let original = try #require(preparation.status().session)
        let checked = try preparation.perform { try preparation.requireSession().status() }
        #expect(checked.generation == original.generation)
        #expect(preparation.status().limitations.suffix(checked.limitations.count) == checked.limitations[...])
        fingerprint.advance(by: 1)
        #expect(preparation.status().session?.fingerprint == original.fingerprint)
        let refreshed = try preparation.perform { try preparation.requireSession().status() }
        #expect(refreshed.generation == original.generation + 1)
        #expect(refreshed.fingerprint != original.fingerprint)
        _ = try preparation.start(refresh: true, timeout: 30)
        try waitUntil { preparation.status().state == .ready }
        #expect(preparation.status().session?.generation == refreshed.generation + 1)
        #expect(counter.values.count == 2)
        _ = try preparation.start(refresh: false, timeout: 30)
        try waitUntil { preparation.status().state == .ready }
        #expect(preparation.status().session?.generation == refreshed.generation + 1)
    }

    @Test("일반 요청 중 준비와 두 번째 분석은 세션을 동시에 사용하지 않는다")
    func foregroundSerialization() throws {
        let gate = PreparationGate()
        let preparation = MCPPreparation(factory: { try gate.enter(); return try Self.session() })
        defer { gate.release.signal(); preparation.shutdown() }
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { finished.signal() }
            _ = try? preparation.perform { try preparation.requireSession().status() }
        }
        #expect(gate.entered.wait(timeout: .now() + 5) == .success)
        #expect(preparation.status().analysisInProgress)
        #expect(!preparation.status().workerActive)
        #expect(throws: MCPToolFailure.self) { try preparation.start(refresh: false, timeout: 30) }
        #expect(throws: MCPToolFailure.self) { try preparation.perform { 42 } }
        gate.release.signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(preparation.status().state == .ready)
    }

    @Test("MCP 작업 스키마는 잘못된 요청을 준비 전에 거부하고 기존 동기 상태 호출을 보존한다")
    func toolValidationAndCompatibility() throws {
        let calls = LockedValues<Int>()
        let tools = CartographMCPTools(makeSession: { calls.append(1); return try Self.session() })
        let idle = try tools.call(name: "cartograph_prepare", arguments: .object(["action": .string("status")]))
        #expect(idle.structuredContent?.objectValue?["state"] == .string("idle"))
        #expect(!idle.isError && calls.values.isEmpty)
        let invalid: [[String: MCPJSONValue]] = [
            [:], ["action": .string("other")], ["action": .string("cancel")],
            ["action": .string("start"), "timeoutSeconds": .integer(0)],
            ["action": .string("start"), "timeoutSeconds": .integer(601)],
            ["action": .string("start"), "refresh": .string("yes")],
            ["action": .string("status"), "refresh": .boolean(true)],
            ["action": .string("cancel"), "generation": .integer(1)],
        ]
        for arguments in invalid {
            #expect(throws: MCPToolFailure.self) {
                try tools.call(name: "cartograph_prepare", arguments: .object(arguments))
            }
        }
        #expect(calls.values.isEmpty)
        let status = try tools.call(name: "cartograph_status", arguments: .object([:]))
        #expect(status.structuredContent?.objectValue?["generation"] == .integer(1))
        #expect(calls.values.count == 1)
        tools.shutdown()
        let closed = try tools.call(name: "cartograph_prepare", arguments: .object(["action": .string("status")]))
        #expect(closed.isError)
        #expect(closed.structuredContent?.objectValue?["state"] == .string("closed"))
    }

    @Test("summary도 준비 상태와 실패 신호를 바꾸지 않는다")
    func summaryPreservesReadinessFailure() throws {
        let tools = CartographMCPTools(makeSession: { throw AnalysisSessionError.unavailable },
            limitationPresentation: .summary)
        _ = try tools.call(name: "cartograph_prepare", arguments: .object(["action": .string("start")]))
        try waitUntil {
            let result = try? tools.call(name: "cartograph_prepare", arguments: .object(["action": .string("status")]))
            return result?.structuredContent?.objectValue?["state"] == .string("failed")
        }
        let result = try tools.call(name: "cartograph_prepare", arguments: .object(["action": .string("status")]))
        #expect(result.isError)
        #expect(result.structuredContent?.objectValue?["limitationSummary"] != nil)
        #expect(result.structuredContent?.objectValue?["inputFreshness"] == .string("not-rechecked-by-status"))
    }
}

private final class PreparationGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var enteredCount = 0
    var count: Int { lock.withLock { enteredCount } }
    func enter() throws {
        lock.withLock { enteredCount += 1 }
        entered.signal()
        guard release.wait(timeout: .now() + 10) == .success else { throw AnalysisSessionError.unavailable }
    }
}

private final class PreparationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(by delta: TimeInterval) { lock.withLock { value += delta } }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}
