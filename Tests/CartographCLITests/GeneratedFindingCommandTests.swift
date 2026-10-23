import ArgumentParser
@testable import cartograph
import Foundation
import Testing

@Suite("dead의 파일 요약과 생성 마커 옵션")
struct GeneratedFindingCommandTests {
    @Test("기본 full 동작은 유지하고 생성 제안은 별도로 선택한다")
    func additiveOptions() throws {
        let plain = try DeadCommand.parse([])
        #expect(!plain.fileSummary && !plain.generatedSuggestions)
        let summary = try DeadCommand.parse(["--report-format", "json", "--file-summary"])
        try summary.validate()
        #expect(summary.fileSummary && !summary.generatedSuggestions)
        let generated = try DeadCommand.parse(["--report-format", "json", "--generated-suggestions"])
        try generated.validate()
        #expect(generated.generatedSuggestions)
    }

    @Test("명시적 비JSON 또는 설명과의 혼합을 인덱스 접근 전에 거부한다", arguments: [
        ["--file-summary", "--report-format", "text"],
        ["--generated-suggestions", "--report-format", "sarif"],
        ["--file-summary", "--explain", "A"],
        ["--generated-suggestions", "--explain", "A"]
    ])
    func rejectsConflicts(arguments: [String]) {
        #expect(throws: (any Error).self) {
            let command = try DeadCommand.parse(arguments)
            try command.validate()
        }
    }

    @Test("설정의 text 기본값도 없는 인덱스를 읽기 전에 사용 오류로 거부한다")
    func resolvedFormatValidationPrecedesIndexRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try DeadCommand.parse(["--file-summary", "--project", root.path,
                                             "--index-store", "/missing/index"])
        #expect(throws: ValidationError.self) { try command.run() }
    }
}
