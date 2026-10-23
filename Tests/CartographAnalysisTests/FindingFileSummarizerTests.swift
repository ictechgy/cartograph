import CartographAnalysis
import CartographCore
import Foundation
import Testing

@Suite("파일별 요약은 진단을 억제하지 않는다")
struct FindingFileSummarizerTests {
    @Test("디자인 토큰의 315개 진단과 알 수 없는 규칙 및 중복도 원문 그대로 보존한다")
    func preservesEveryFinding() throws {
        let diagnostics = (0..<315).map { index in
            finding("Tokens.swift", rule: index < 272 ? "unused-symbol" : "redundant-public", subject: "t\(index)")
        } + [finding("NeedleGenerated.swift", rule: "future-rule", subject: "g"),
             finding("NeedleGenerated.swift", rule: "future-rule", subject: "g"),
             Diagnostic(ruleIdentifier: "unknown", severity: .error, message: "No source location")]
        let result = try FindingFileSummarizer.summarize(diagnostics)
        #expect(result.diagnostics == diagnostics)
        #expect(result.findingCount == 318)
        #expect(result.unlocatedFindingCount == 1)
        #expect(result.files.map(\.path) == ["Tokens.swift", "NeedleGenerated.swift"])
        #expect(result.files[0].ruleCounts == ["unused-symbol": 272, "redundant-public": 43])
        #expect(result.files[1].ruleCounts == ["future-rule": 2])
        #expect(result.files.allSatisfy { $0.generatedMarker == nil })
    }

    @Test("상한은 파일 요약에만 적용하고 동률 경로는 정렬한다")
    func boundedDeterministicSummary() throws {
        let diagnostics = [finding("Z.swift"), finding("A.swift"), finding("B.swift")]
        let result = try FindingFileSummarizer.summarize(diagnostics, maximumFiles: 2)
        #expect(result.files.map(\.path) == ["A.swift", "B.swift"])
        #expect(result.totalFileCount == 3)
        #expect(result.omittedFileCount == 1)
        #expect(result.diagnostics == diagnostics)
        #expect(result.limitations.first?.hasPrefix("finding-summary-limit:") == true)
        #expect(try FindingFileSummarizer.summarize(Array(diagnostics.reversed()), maximumFiles: 2).files == result.files)
    }

    @Test("파일 위치가 빈 진단과 심각도도 사라지지 않는다")
    func emptyLocationAndSeverity() throws {
        let result = try FindingFileSummarizer.summarize([
            finding(""), finding("A.swift"),
            Diagnostic(ruleIdentifier: "custom", severity: .error, message: "error",
                location: .init(path: "A.swift", line: 1, column: 1))
        ])
        #expect(result.unlocatedFindingCount == 1)
        #expect(result.files.first?.severityCounts == ["warning": 1, "error": 1])
        #expect(try FindingFileSummarizer.summarize([]).files.isEmpty)
        #expect(throws: (any Error).self) { try FindingFileSummarizer.summarize([], maximumFiles: 0) }
        #expect(throws: (any Error).self) { try FindingFileSummarizer.summarize([], maximumFiles: 10_001) }
    }

    private func finding(_ path: String, rule: String = "unused-symbol", subject: String = "s") -> Diagnostic {
        .init(ruleIdentifier: rule, severity: .warning, message: subject,
            location: .init(path: path, line: 1, column: 1), subject: subject)
    }
}
