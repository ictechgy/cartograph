import CartographCore
import Foundation
import Testing

@Suite("실제로 읽은 source record 신원")
struct SourceRecordAdmissionTests {
    @Test("구 snapshot은 record 근거가 없고 합쳐도 완전성을 빌리지 않는다")
    func legacyAndMerge() throws {
        let old = try JSONDecoder().decode(IndexSnapshot.self, from: Data(#"{"symbols":[],"references":[]}"#.utf8))
        #expect(old.sourceRecordAdmissions == nil)
        let first = SourceRecordAdmission(path: "/p/a.swift", module: "A", unit: "u", record: "r", timestamp: .distantPast)
        let second = SourceRecordAdmission(path: "/p/a.swift", module: "B", unit: "v", record: "s", timestamp: .distantFuture)
        let snapshot = IndexSnapshot(sourceRecordAdmissions: [second, first, first])
        #expect(snapshot.sourceRecordAdmissions == [first, second])
        #expect(snapshot.merging(old).sourceRecordAdmissions == nil)
        #expect(snapshot.merging(snapshot).sourceRecordAdmissions == [first, second])
        #expect(first.rebased { $0.replacingOccurrences(of: "/p/", with: "/q/") }.path == "/q/a.swift")
        let same = SourceRecordAdmission(path: first.path, module: first.module, unit: first.unit, record: first.record, timestamp: .distantFuture)
        #expect(SourceRecordAdmission.sorted([same, first]) == [first, same])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try JSONDecoder().decode(IndexSnapshot.self, from: encoder.encode(snapshot)) == snapshot)
    }
}
