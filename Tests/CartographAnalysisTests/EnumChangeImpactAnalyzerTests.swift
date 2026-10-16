import CartographCore
@testable import CartographAnalysis
import Foundation
import Testing

@Suite("enum case 추가 검토 후보")
struct EnumChangeImpactAnalyzerTests {
    @Test("새 case를 직접 다루지 않는 default와 리터럴 집합을 함께 보고한다")
    func reportsLocatedCandidates() {
        let before = snapshot(cases: ["a", "b"])
        let current = snapshot(cases: ["a", "b", "c"], decisions: [
            decision(.switchDefault, line: 10),
            decision(.switchUnknownDefault, line: 20),
            decision(.literalMembership, line: 30),
            decision(.negatedLiteralMembership, line: 40),
        ])
        let result = analyze(before, current)
        #expect(result.status == "review")
        #expect(result.changes.first?.addedCases.map(\.usr) == ["E.c"])
        #expect(result.candidates.map(\.kind) == [
            .switchDefault, .switchUnknownDefault, .literalMembership, .negatedLiteralMembership,
        ])
        #expect(result.candidates.allSatisfy { $0.addedCaseUSRs == ["E.c"] && $0.ownerUSR == "f" })
        #expect(result.candidates[2].reason == "added-case-outside-explicit-literal-set")
        #expect(result.candidates[3].location.line == 40)
    }

    @Test("where가 붙은 case는 무조건 처리한 것으로 세지 않는다")
    func distinguishesGuardedHandling() {
        let current = snapshot(cases: ["a", "b", "c"], decisions: [
            decision(.switchDefault, line: 10, explicit: ["E.a", "E.b", "E.c"]),
            decision(.switchDefault, line: 20, guarded: ["E.c"]),
        ])
        let result = analyze(snapshot(cases: ["a", "b"]), current)
        #expect(result.candidateCount == 1)
        #expect(result.candidates.first?.location.line == 20)
        #expect(result.candidates.first?.guardedCaseUSRs == ["E.c"])
    }

    @Test("오래된 사실과 불완전한 case 목록을 빈 완전 목록으로 취급하지 않는다")
    func missingAndPartialInventories() {
        var old = snapshot(cases: ["a"])
        old.enumImpactFiles = nil
        let current = snapshot(cases: ["a", "b"])
        let legacy = analyze(old, current)
        #expect(legacy.status == "partial")
        #expect(legacy.changeCount == 0)
        #expect(legacy.issues.contains { $0.kind == "baseline-enum-facts-unavailable" })
        let incomplete = analyze(snapshot(cases: ["a"], complete: false), current)
        #expect(incomplete.changeCount == 0)
        #expect(incomplete.issues.contains { $0.kind == "incomplete-enum-inventory" })
        var missing = snapshot(cases: ["a"])
        missing.symbols.removeAll { $0.usr == "E" }
        #expect(analyze(missing, current).issues.contains { $0.kind == "unmatched-enum-identity" })
    }

    @Test("사용자 contains와 근거 부족은 위치를 보존한 미해결 항목이다")
    func unresolvedMembershipRetainsEvidence() {
        let unresolved = EnumDecisionFact(kind: .literalMembership,
            location: location(30), endLocation: location(30, column: 30),
            enumUSR: "E", ownerUSR: "f", explicitCaseUSRs: ["E.a"],
            evidenceLocations: [location(30, column: 4)], operationTargetUSRs: ["custom.contains"],
            status: "unresolved", limitations: ["unsupported-or-unresolved-membership-target"])
        let result = analyze(snapshot(cases: ["a"]), snapshot(cases: ["a", "b"], decisions: [unresolved]))
        #expect(result.status == "partial")
        #expect(result.candidateCount == 0)
        #expect(result.unresolvedDecisionCount == 1)
        #expect(result.unresolvedDecisions.first?.location.line == 30)
        #expect(result.unresolvedDecisions.first?.explicitCaseUSRs == ["E.a"])
        #expect(result.unresolvedDecisions.first?.operationTargetUSRs == ["custom.contains"])
    }

    @Test("partial 파일의 결정은 후보로 올리지 않고 위치와 제한을 보존한다")
    func partialConsumerKeepsLocatedReasons() {
        var current = snapshot(cases: ["a", "b"])
        let site = CartographCore.SourceLocation(path: "/p/Consumer.swift", line: 10, column: 3)
        current.symbols.append(.init(usr: "f", name: "f()", kind: .function, module: "App", location: site))
        current.enumImpactFiles?.append(.init(path: site.path, status: "partial",
            decisions: [.init(kind: .literalMembership, location: site, endLocation: site,
                enumUSR: "E", explicitCaseUSRs: ["E.a"], evidenceLocations: [site], status: "resolved")],
            limitations: ["enum-decision-unexpanded-macro"]))
        let result = analyze(snapshot(cases: ["a"]), current)
        #expect(result.candidateCount == 0)
        #expect(result.unresolvedDecisionCount == 1)
        #expect(result.unresolvedDecisions.first?.location == site)
        #expect(result.unresolvedDecisions.first?.evidenceLocations == [site])
        #expect(result.unresolvedDecisions.first?.limitations.contains("enum-decision-unexpanded-macro") == true)
    }

    @Test("선택하지 않은 enum 확장은 섞지 않고 JSON과 한도 순서는 결정적이다")
    func selectionAndDeterminism() throws {
        let before = snapshot(cases: ["a"]).merging(snapshot(cases: ["a"], id: "Other"))
        let decisions = [
            decision(.switchDefault, line: 20, explicit: ["E.a"]),
            decision(.literalMembership, line: 10, explicit: ["E.a"]),
        ]
        let current = snapshot(cases: ["a", "b", "c"], decisions: decisions)
            .merging(snapshot(cases: ["a", "b"], id: "Other"))
        let result = analyze(before, current, limit: 1)
        #expect(result.changeCount == 1)
        #expect(result.changes.first?.enumUSR == "E")
        #expect(result.candidateCount == 2)
        #expect(result.candidates.first?.location.line == 10)
        #expect(result.candidates.first?.addedCaseCount == 2)
        #expect(result.candidates.first?.addedCaseUSRs.count == 1)
        #expect(result.truncated)
        var reordered = current
        reordered.symbols.reverse()
        reordered.enumImpactFiles?.reverse()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(result) == encoder.encode(analyze(before, reordered, limit: 1)))
        let unselected = EnumChangeImpactAnalyzer().analyze(
            before: before, current: current, selected: [NodeID("unrelated")], limit: 100)
        #expect(unselected.changeCount == 0)
        #expect(unselected.candidateCount == 0)
    }

    private func analyze(_ before: IndexSnapshot, _ current: IndexSnapshot, limit: Int = 100) -> EnumChangeReview {
        EnumChangeImpactAnalyzer().analyze(before: before, current: current,
            selected: [NodeID("E")], limit: limit)
    }

    private func location(_ line: Int, column: Int = 1, id: String = "E") -> CartographCore.SourceLocation {
        .init(path: "/p/\(id).swift", line: line, column: column)
    }

    private func decision(_ kind: EnumDecisionFact.Kind, line: Int,
                          explicit: [String] = ["E.a", "E.b"], guarded: [String] = []) -> EnumDecisionFact {
        .init(kind: kind, location: location(line), endLocation: location(line, column: 30),
            enumUSR: "E", ownerUSR: "f", explicitCaseUSRs: explicit, guardedCaseUSRs: guarded,
            evidenceLocations: [location(line, column: 4)], status: "resolved")
    }

    private func snapshot(cases: [String], id: String = "E",
                          decisions: [EnumDecisionFact] = [], complete: Bool = true) -> IndexSnapshot {
        let owner = IndexedSymbol(usr: id, name: id, kind: .enumType, module: "App",
            location: location(1, id: id))
        let members = cases.enumerated().map { offset, name in
            IndexedSymbol(usr: "\(id).\(name)", name: name, kind: .enumCase, module: "App",
                location: location(offset + 2, id: id), parentUSR: id)
        }
        let file = EnumImpactFileFacts(path: owner.location.path, status: "fresh",
            inventories: [.init(enumUSR: id, caseUSRs: members.map(\.usr),
                location: owner.location, complete: complete)], decisions: decisions)
        return IndexSnapshot(symbols: [owner] + members, enumImpactFiles: [file])
    }
}
