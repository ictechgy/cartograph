import CartographCore
import Foundation
import Testing

@Suite("런타임 관측 완전성 값")
struct RuntimeTraceTests {
    @Test("public 모델도 저장된 플래그만으로 잘못된 구간을 완전하다고 하지 않는다")
    func checksStructuralWindowInvariants() throws {
        let valid = windowDocument()
        #expect(valid.hasCompleteEvidence)
        let encoded = try JSONEncoder.cartographDefault().encode(valid)
        let baseline = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let replacements: [[String: Any]] = [
            ["version": 99, "collectionComplete": true], ["droppedEvents": 9], ["collectorActive": false],
            ["collectionComplete": true], ["launch": NSNull()],
            ["launch": ["platform": "macOS", "processID": -1]],
            ["evidenceComplete": true, "observationWindow": [
                "trigger": "duration", "requestedMilliseconds": 1000, "elapsedMilliseconds": 100,
                "complete": true, "sealedEventCount": 0, "processOutcome": "stoppedAfterSeal",
            ]],
        ]
        for replacement in replacements {
            let corrupted = baseline.merging(replacement) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: corrupted, options: .sortedKeys)
            let decoded = try JSONDecoder().decode(RuntimeTraceDocument.self, from: data)
            #expect(!decoded.hasCompleteEvidence)
        }
        #expect(!windowDocument(dropped: 1).hasCompleteEvidence)
    }

    private func windowDocument(dropped: Int = 0) -> RuntimeTraceDocument {
        RuntimeTraceDocument(
            version: 2, inputFingerprint: "input", executableFingerprint: "binary", executablePath: "/tmp/Probe",
            collectorActive: true, collectionComplete: false, processExitCode: nil,
            events: [], droppedEvents: dropped, limitations: [], launch: .init(platform: .macOS, processID: 72),
            observationWindow: .init(requestedMilliseconds: 1000, elapsedMilliseconds: 1001,
                complete: true, sealedEventCount: 0, processOutcome: .stoppedAfterSeal)
        )
    }
}
