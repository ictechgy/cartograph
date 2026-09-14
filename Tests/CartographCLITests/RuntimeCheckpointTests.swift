import CartographCore
import Foundation
@testable import cartograph
import Testing

@Suite("런타임 관측 구간 봉인")
struct RuntimeCheckpointTests {
    @Test("봉인된 기록은 사용할 수 있지만 프로세스 성공으로 바꾸지 않는다")
    func completeWindowIsNotSuccessfulProcessExit() {
        let document = completeDocument()
        #expect(document.version == 2)
        #expect(document.hasCompleteEvidence)
        #expect(!document.collectionComplete)
        #expect(document.processExitCode == nil)
        #expect(document.observationWindow?.sealedEventCount == 1)
        #expect(document.observationWindow?.processOutcome == .stoppedAfterSeal)
    }

    @Test("봉인 ack가 있어도 잘못된 계수·시간·PID·훅·정리 결과를 통과시키지 않는다")
    func sealRequiresConsistentEvidence() {
        let failures = [
            completeDocument(seal: seal(processID: 99)),
            completeDocument(seal: seal(events: 2)),
            completeDocument(seal: seal(dropped: 1)),
            completeDocument(seal: seal(truncated: 1)),
            completeDocument(seal: seal(hookMask: 0)),
            completeDocument(seal: seal(elapsed: 1)),
            completeDocument(outcome: .unverified),
            completeDocument(timedOut: true),
            completeDocument(finalInput: "different"),
        ]
        #expect(failures.allSatisfy { !$0.hasCompleteEvidence && $0.observationWindow?.complete == false })
        #expect(failures.allSatisfy { !$0.events.isEmpty })
    }

    @Test("ack는 동일 요청 nonce·PID의 완전한 불변 레코드만 읽는다")
    func sealDecoderRejectsForeignOrMalformedAcknowledgements() {
        let nonce = String(repeating: "a", count: 32)
        var data = Data("CTSEAL01".utf8)
        append(UInt32(1), to: &data)
        append(Int32(72), to: &data)
        data.append(Data(nonce.utf8))
        for count: UInt64 in [1, 0, 0] { append(count, to: &data) }
        append(UInt32(127), to: &data)
        append(UInt32(1), to: &data)
        append(UInt64(30_000_000), to: &data)
        #expect(RuntimeCheckpointSeal.decode(data, nonce: nonce, processID: 72) == seal())
        #expect(RuntimeCheckpointSeal.decode(data, nonce: nonce, processID: 99) == nil)
        #expect(RuntimeCheckpointSeal.decode(data, nonce: String(repeating: "b", count: 32), processID: 72) == nil)
        #expect(RuntimeCheckpointSeal.decode(data.dropLast(), nonce: nonce, processID: 72) == nil)
        data.append(0)
        #expect(RuntimeCheckpointSeal.decode(data, nonce: nonce, processID: 72) == nil)
    }

    private func completeDocument(
        seal: RuntimeCheckpointSeal? = nil,
        outcome: RuntimeTraceObservationWindow.ProcessOutcome = .stoppedAfterSeal,
        timedOut: Bool = false,
        finalInput: String = "input"
    ) -> RuntimeTraceDocument {
        let seal = seal ?? self.seal()
        let execution = RuntimeTraceExecution(
            processID: 72, processExitCode: nil, timedOut: timedOut, status: self.seal().status,
            log: .init(events: [.init(api: "NSClassFromString", phase: "lookup", name: "Missing", result: false)],
                issues: [], reportedDroppedEvents: 0),
            window: .init(requestedMilliseconds: 20, seal: seal, processOutcome: outcome)
        )
        return RuntimeTraceCompletion.document(
            inputFingerprint: "input", finalInputFingerprint: finalInput,
            executableFingerprint: "binary", finalExecutableFingerprint: "binary", executablePath: "/tmp/Probe",
            execution: execution, launch: .init(platform: .macOS, processID: 72)
        )
    }

    private func seal(
        processID: Int32 = 72, events: UInt64 = 1, dropped: UInt64 = 0,
        truncated: UInt64 = 0, hookMask: UInt32 = 127, elapsed: UInt64 = 30_000_000
    ) -> RuntimeCheckpointSeal {
        .init(processID: processID, emittedEvents: events, droppedEvents: dropped,
            truncatedValues: truncated, hookMask: hookMask, elapsedNanoseconds: elapsed)
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
