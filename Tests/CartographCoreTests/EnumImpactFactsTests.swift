import CartographCore
import Foundation
import Testing

@Suite("enum 사실의 보존과 호환")
struct EnumImpactFactsTests {
    @Test("옛 snapshot은 미수집 상태이고 빈 새 수집과 구별된다")
    func legacyAndEmptyCoverage() throws {
        let old = try JSONDecoder().decode(IndexSnapshot.self,
            from: Data(#"{"symbols":[],"references":[]}"#.utf8))
        #expect(old.enumImpactFiles == nil)
        let scanned = IndexSnapshot(enumImpactFiles: [])
        let decoded = try JSONDecoder().decode(IndexSnapshot.self, from: JSONEncoder().encode(scanned))
        #expect(decoded.enumImpactFiles == [])
        #expect(old.merging(old).enumImpactFiles == nil)
    }

    @Test("동일 파일의 충돌은 완전한 case 목록으로 합쳐지지 않는다")
    func conflictingCaptures() {
        let first = IndexSnapshot(enumImpactFiles: [facts(cases: ["E.a"])])
        let second = IndexSnapshot(enumImpactFiles: [facts(cases: ["E.a", "E.b"])])
        #expect(first.merging(first).enumImpactFiles == first.enumImpactFiles)
        let merged = first.merging(second)
        #expect(merged.enumImpactFiles == second.merging(first).enumImpactFiles)
        #expect(merged.enumImpactFiles?.first?.status == "conflicted")
        #expect(merged.enumImpactFiles?.first?.inventories.isEmpty == true)
        #expect(merged.enumImpactFiles?.first?.limitations == ["conflicting-file-captures"])
    }

    @Test("같은 파일의 미수집 문맥은 병합 양방향에서 partial이고 다른 파일은 보존한다")
    func overlappingLegacyCaptureDoesNotBorrowCoverage() {
        let known = IndexSnapshot(enumImpactFiles: [facts(cases: ["E.a"])])
        let legacy = IndexSnapshot(symbols: [
            .init(usr: "E", name: "E", kind: .enumType, module: "App",
                location: .init(path: "/old/E.swift", line: 1, column: 1)),
        ])
        for merged in [known.merging(legacy), legacy.merging(known)] {
            #expect(merged.enumImpactFiles?.first?.status == "partial")
            #expect(merged.enumImpactFiles?.first?.limitations.contains("overlapping-unscanned-file-capture") == true)
        }
        let disjoint = IndexSnapshot(symbols: [
            .init(usr: "Other", name: "Other", kind: .enumType, module: "App",
                location: .init(path: "/old/Other.swift", line: 1, column: 1)),
        ])
        #expect(known.merging(disjoint).enumImpactFiles == known.enumImpactFiles)
        #expect(disjoint.merging(known).enumImpactFiles == known.enumImpactFiles)
    }

    @Test("왕복과 루트 이동은 모든 위치를 옮기고 USR은 보존한다")
    func roundTripAndRebase() throws {
        let snapshot = IndexSnapshot(enumImpactFiles: [facts(cases: ["E.a"])])
        let decoded = try JSONDecoder().decode(IndexSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        let moved = try #require(decoded.enumImpactFiles?.first).rebased {
            $0.replacingOccurrences(of: "/old/", with: "/new/")
        }
        #expect(moved.path == "/new/E.swift")
        #expect(moved.inventories.first?.location.path == "/new/E.swift")
        #expect(moved.decisions.first?.location.path == "/new/E.swift")
        #expect(moved.decisions.first?.endLocation.path == "/new/E.swift")
        #expect(moved.decisions.first?.evidenceLocations.first?.path == "/new/E.swift")
        #expect(moved.decisions.first?.enumUSR == "E")
        #expect(moved.decisions.first?.operationTargetUSRs == ["standard.contains"])
    }

    private func facts(cases: [String]) -> EnumImpactFileFacts {
        let location = SourceLocation(path: "/old/E.swift", line: 1, column: 1)
        return .init(path: location.path, status: "fresh",
            inventories: [.init(enumUSR: "E", caseUSRs: cases, location: location, complete: true)],
            decisions: [.init(kind: .literalMembership, location: location, endLocation: location,
                enumUSR: "E", ownerUSR: "f", explicitCaseUSRs: cases,
                evidenceLocations: [location], operationTargetUSRs: ["standard.contains"], status: "resolved")])
    }
}
