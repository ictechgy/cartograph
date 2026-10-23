import ArgumentParser
@testable import cartograph
import CartographCore
import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("quiet의 한계 요약과 실패 신호")
struct QuietLimitationNotesTests {
    @Test("알려진 한계는 코드별 note 수로 요약하고 숫자나 경로를 해석하지 않는다")
    func summarizesKnownCodesWithoutRewritingEvidence() {
        let notes = [
            "unindexed-sources: 1 of 8 sources; paths [\"A1.swift\"]",
            "index-staleness: 200 sources changed after build",
            "unindexed-sources: 7 of 20 sources; paths [\"A2.swift\"]",
        ]
        let result = CommandSupport.notesForDisplay(notes, quiet: true)
        #expect(result.count == 1)
        #expect(result[0].contains("3 note(s) across 2 known code(s)"))
        #expect(result[0].contains("index-staleness=1, unindexed-sources=2"))
        #expect(result[0].contains("incomplete or stale"))
        #expect(result[0].contains("empty result is not a safety guarantee"))
        #expect(result[0].contains("rerun without --quiet"))
        #expect(result[0].contains("JSON limitation fields are unchanged"))
        #expect(!result[0].contains("A1.swift"))
        #expect(CommandSupport.notesForDisplay(notes, quiet: false) == notes)
    }

    @Test("새 코드와 일반 안내는 quiet에서도 중복 제거 없이 그대로 보존한다")
    func preservesUnknownNotesVerbatim() {
        let unknown = ["future-limitation: source 1 is unknown", "future-limitation: source 2 is unknown",
                       "custom warning", "index-staleness-extra: not a recognized code", "C:\\project\\source.swift"]
        #expect(CommandSupport.notesForDisplay(unknown, quiet: true) == unknown)
        let mixed = CommandSupport.notesForDisplay(["empty-index: no definitions"] + unknown, quiet: true)
        #expect(mixed.count == 1 + unknown.count)
        #expect(Array(mixed.dropFirst()) == unknown)
        #expect(mixed[0].contains("empty-index=1"))
        #expect(CommandSupport.notesForDisplay([], quiet: true).isEmpty)
    }

    @Test("긴 반복 한계는 짧아져도 불완전 실패 코드 2와 원문 오류 및 JSON은 유지한다")
    func quietStillFailsIncompleteAnalysis() throws {
        let notes = (0..<64).map { "unindexed-sources: \($0) sources; " + String(repeating: "path,", count: 80) }
        let output = "{\"limitations\":[\"unindexed-sources: exact original\"],\"status\":\"incomplete\"}\n"
        let result = try emit(CommandOutcome(output: output, incompleteAnalysis: "Index evidence is incomplete.", notes: notes))
        #expect((result.error as? ExitCode)?.rawValue == CommandSupport.failureExitCode)
        #expect(result.output == output)
        #expect(result.stderr.contains("unindexed-sources=64"))
        #expect(result.stderr.contains("error: Index evidence is incomplete.\n"))
        #expect(result.stderr.utf8.count < 800)
    }

    @Test("quiet 요약은 strict와 임계값 및 이름 누락의 기존 종료 판단을 바꾸지 않는다")
    func preservesOtherExitDecisions() throws {
        let notes = ["index-staleness: sources newer than build"]
        let strict = try emit(CommandOutcome(output: "{}", findingCount: 1, notes: notes), strict: true)
        #expect((strict.error as? ExitCode)?.rawValue == CommandSupport.findingsExitCode)
        let threshold = try emit(CommandOutcome(output: "{}",
            thresholdFailure: .thresholdExceeded(rule: "cycles", message: "2 > 1"), notes: notes))
        #expect((threshold.error as? ExitCode)?.rawValue == CommandSupport.findingsExitCode)
        #expect(threshold.stderr.contains("error: Threshold exceeded for 'cycles': 2 > 1"))
        let missing = try emit(CommandOutcome(output: "{}", subjectNotFound: true,
            notFoundMessage: "Missing requested declaration.", notes: notes))
        #expect((missing.error as? ValidationError)?.message == "Missing requested declaration.")
        let success = try emit(CommandOutcome(output: "{}", notes: notes))
        #expect(success.error == nil)
        #expect(success.stderr.contains("index-staleness=1"))
    }

    private struct Emitted {
        let output: String
        let stderr: String
        let error: (any Error)?
    }

    private func emit(_ outcome: CommandOutcome, strict: Bool = false) throws -> Emitted {
        let fileSystem = InMemoryFileSystem(currentDirectoryPath: "/p")
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.strict = strict
        let service = CartographService(configuration: configuration,
            environment: CartographEnvironment(fileSystem: fileSystem))
        let context = CommandContext(service: service, configuration: configuration, fileSystem: fileSystem)
        let options = try GlobalOptions.parse(["--project", "/p", "--output", "/p/result.json", "--quiet"])
        // 요약 회귀로 원문이 길게 출력돼도 pipe 용량 때문에 테스트가 멈추지 않는다.
        let diagnostics = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-quiet-notes-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: diagnostics.path, contents: nil))
        let sink = try FileHandle(forUpdating: diagnostics)
        defer {
            try? sink.close()
            try? FileManager.default.removeItem(at: diagnostics)
        }
        var failure: (any Error)?
        do {
            try CommandSupport.emit(outcome, options: options, context: context,
                diagnosticSink: sink)
        } catch { failure = error }
        try sink.seek(toOffset: 0)
        let stderr = String(decoding: sink.readDataToEndOfFile(), as: UTF8.self)
        return Emitted(output: String(decoding: try fileSystem.readData(at: "/p/result.json"), as: UTF8.self),
            stderr: stderr, error: failure)
    }
}
