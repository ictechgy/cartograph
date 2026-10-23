import ArgumentParser
@testable import cartograph
import CartographCore
import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("한계 요약 CLI 계약")
struct LimitationPresentationTests {
    @Test("full 기본값과 명시적 모드 및 잘못된 값 거부를 고정한다")
    func parsesDetail() throws {
        #expect(try GlobalOptions.parse([]).limitations == .full)
        #expect(try GlobalOptions.parse(["--limitations", "full"]).limitations == .full)
        #expect(try GlobalOptions.parse(["--limitations", "summary"]).limitations == .summary)
        #expect(throws: (any Error).self) { try GlobalOptions.parse(["--limitations", "hidden"]) }
        let original = "{  \"limitations\": [] }\n"
        #expect(try CommandSupport.outputForDisplay(original, limitations: .full) == original)
    }

    @Test("미지원 명령은 설정 파일이나 인덱스를 읽기 전에 summary를 거부한다")
    func rejectsUnsupportedBeforeIO() throws {
        let options = try GlobalOptions.parse(["--limitations", "summary", "--config", "/not-present/config.yml"])
        do {
            _ = try CommandSupport.makeContext(options)
            Issue.record("summary를 거부해야 한다")
        } catch let error as ValidationError {
            #expect(error.message.contains("snapshot, exchange and write commands require"))
        }
        #expect(throws: ValidationError.self) {
            try CommandSupport.outputForDisplay("text report", limitations: .summary)
        }
    }

    @Test("quiet summary라도 불완전 rc2와 strict rc1 및 이름 누락 오류는 보존한다")
    func preservesExitDecisionsAndOutput() throws {
        let input = "{\"limitations\":[\"index-staleness: 3 files\"],\"status\":\"incomplete\","
            + "\"truncated\":{\"depth\":true}}\n"
        let incomplete = try emit(.init(output: input, incompleteAnalysis: "Unknown coverage.",
                                        notes: ["index-staleness: 3 files"]))
        #expect((incomplete.error as? ExitCode)?.rawValue == 2)
        #expect(incomplete.output["status"] as? String == "incomplete")
        #expect((incomplete.output["truncated"] as? [String: Any])?["depth"] as? Bool == true)
        #expect((incomplete.output["limitationSummary"] as? [String: Any])?["noteCount"] as? Int == 1)
        #expect(incomplete.stderr.contains("error: Unknown coverage."))
        #expect(incomplete.stderr.contains("JSON uses summary detail"))
        #expect(!incomplete.stderr.contains("JSON limitation fields are unchanged"))
        let strict = try emit(.init(output: input, findingCount: 1), strict: true)
        #expect((strict.error as? ExitCode)?.rawValue == 1)
        let missing = try emit(.init(output: input, subjectNotFound: true, notFoundMessage: "Missing declaration."))
        #expect((missing.error as? ValidationError)?.message == "Missing declaration.")
        let threshold = try emit(.init(output: input,
            thresholdFailure: .thresholdExceeded(rule: "cycles", message: "2 > 1")))
        #expect((threshold.error as? ExitCode)?.rawValue == 1)
    }

    private func emit(_ outcome: CommandOutcome, strict: Bool = false) throws
        -> (output: [String: Any], stderr: String, error: (any Error)?) {
        let fileSystem = InMemoryFileSystem(currentDirectoryPath: "/p")
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        configuration.strict = strict
        let service = CartographService(configuration: configuration,
            environment: CartographEnvironment(fileSystem: fileSystem))
        let context = CommandContext(service: service, configuration: configuration, fileSystem: fileSystem)
        let options = try GlobalOptions.parse(["--project", "/p", "--output", "/p/result.json",
                                               "--quiet", "--limitations", "summary"])
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-limitations-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: path.path, contents: nil))
        let sink = try FileHandle(forUpdating: path)
        defer { try? sink.close(); try? FileManager.default.removeItem(at: path) }
        var failure: (any Error)?
        do { try CommandSupport.emit(outcome, options: options, context: context, diagnosticSink: sink) }
        catch { failure = error }
        try sink.seek(toOffset: 0)
        let stderr = String(decoding: sink.readDataToEndOfFile(), as: UTF8.self)
        let output = try #require(JSONSerialization.jsonObject(with: fileSystem.readData(at: "/p/result.json"))
            as? [String: Any])
        return (output, stderr, failure)
    }
}
