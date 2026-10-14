import ArgumentParser
import CartographKit
@testable import cartograph
import Dispatch
import Foundation
import Testing

@Suite("질의 단계 진단 출력")
struct QueryPhaseDiagnosticsTests {
    private let key = "CARTOGRAPH_DIAGNOSTIC_QUERY_PHASES"
    private let names = [
        "cli_setup", "input_preparation", "raw_snapshot", "syntax_context", "graph_query_setup",
        "found_facts", "answer", "serialization", "cli_output",
    ]

    @Test("환경 값이 정확히 1일 때만 관측자와 진단 줄을 만든다")
    func optInIsExact() throws {
        for environment in [[:], [key: ""], [key: "0"], [key: "true"], [key: "01"],
                            [key: "1 "], [key: " 1"], [key: "1\n"], [key.lowercased(): "1"]] {
            var bodyCalls = 0
            let text = try capture { sink in
                let value = QueryPhaseDiagnostics.withDiagnostics(environment: environment, sink: sink) { observer in
                    #expect(observer == nil)
                    bodyCalls += 1
                    return 42
                }
                #expect(value == 42)
            }
            #expect(text.isEmpty)
            #expect(bodyCalls == 1)
        }
        let enabled = try capture { sink in
            QueryPhaseDiagnostics.withDiagnostics(environment: [key: "1"], sink: sink) { observer in
                #expect(observer != nil)
                observer?(.answer, .zero)
            }
        }
        #expect(enabled == expectedLine(values: ["answer": "0.000000000"]))
    }

    @Test("아홉 단계는 고정 순서로 나오고 반복 관측은 합산한다")
    func orderingAndAggregationAreFixed() {
        let diagnostics = QueryPhaseDiagnostics()
        diagnostics.record(.cliOutput, duration: .milliseconds(3))
        diagnostics.record(.answer, duration: .seconds(1))
        diagnostics.record(.answer, duration: .milliseconds(250))
        diagnostics.record(.cliSetup, duration: .nanoseconds(1))
        diagnostics.record(.rawSnapshot, duration: .seconds(2))
        #expect(diagnostics.line() == expectedLine(values: [
            "cli_setup": "0.000000001", "raw_snapshot": "2.000000000",
            "answer": "1.250000000", "cli_output": "0.003000000",
        ]))
    }

    @Test("실행하지 않은 단계와 실행 시간이 0인 단계는 구별된다")
    func skippedAndZeroAreDifferent() {
        let diagnostics = QueryPhaseDiagnostics()
        #expect(diagnostics.line() == expectedLine(values: [:]))
        diagnostics.record(.foundFacts, duration: .zero)
        #expect(diagnostics.line() == expectedLine(values: ["found_facts": "0.000000000"]))
    }

    @Test("병렬 관측도 누락 없이 잠금 아래 합산한다")
    func concurrentEventsAreNotLost() {
        let diagnostics = QueryPhaseDiagnostics()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            diagnostics.observer(.answer, .nanoseconds(1))
        }
        #expect(diagnostics.line() == expectedLine(values: ["answer": "0.000000100"]))
    }

    @Test("정상 반환에서도 진단 줄을 한 번만 쓰며 원래 값을 돌려준다")
    func successWritesOneRecord() throws {
        let expected = CommandOutcome(output: "original output\n", notes: ["original note"])
        var bodyCalls = 0
        let text = try capture { sink in
            let value = QueryPhaseDiagnostics.withDiagnostics(environment: [key: "1"], sink: sink) { observer in
                bodyCalls += 1
                observer?(.answer, .milliseconds(2))
                observer?(.answer, .milliseconds(3))
                return expected
            }
            #expect(value == expected)
        }
        #expect(bodyCalls == 1)
        #expect(text == expectedLine(values: ["answer": "0.005000000"]))
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test("던진 오류도 바꾸지 않고 실행한 단계만 담은 진단 줄을 한 번 쓴다")
    func failureWritesOneRecord() throws {
        let failure = DiagnosticTestError()
        let text = try capture { sink in
            do {
                try QueryPhaseDiagnostics.withDiagnostics(environment: [key: "1"], sink: sink) { observer in
                    observer?(.rawSnapshot, .milliseconds(4))
                    throw failure
                }
                Issue.record("원래 오류가 나와야 한다")
            } catch {
                #expect((error as? DiagnosticTestError) === failure)
            }
        }
        #expect(text == expectedLine(values: ["raw_snapshot": "0.004000000"]))
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test("닫힌 진단 출력 핸들은 성공 결과를 실패로 바꾸지 않는다")
    func closedSinkPreservesSuccess() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        let expected = CommandOutcome(output: "original output\n")
        let value = QueryPhaseDiagnostics.withDiagnostics(
            environment: [key: "1"], sink: pipe.fileHandleForWriting
        ) { observer in
            observer?(.answer, .zero)
            return expected
        }
        #expect(value == expected)
    }

    @Test("닫힌 진단 출력 핸들의 쓰기 오류는 원래 질의 오류를 가리지 않는다")
    func closedSinkPreservesError() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        let failure = DiagnosticTestError()
        do {
            try QueryPhaseDiagnostics.withDiagnostics(
                environment: [key: "1"], sink: pipe.fileHandleForWriting
            ) { _ in
                throw failure
            }
            Issue.record("원래 오류가 나와야 한다")
        } catch {
            #expect((error as? DiagnosticTestError) === failure)
        }
    }

    @Test("실제 query의 배치 읽기 오류에도 setup만 기록하고 원래 오류는 그대로다")
    func queryRunReportsSetupFailure() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-query-name-\(UUID().uuidString).json").path
        let command = try QueryCommand.parse(["--batch", path])
        var originalError = ""
        let disabled = try capture { sink in
            do {
                try command.run(diagnosticEnvironment: [:], diagnosticSink: sink)
                Issue.record("없는 배치 파일은 실패해야 한다")
            } catch {
                #expect(error is ValidationError)
                originalError = String(describing: error)
            }
        }
        #expect(disabled.isEmpty)
        #expect(!originalError.isEmpty)
        let enabled = try capture { sink in
            do {
                try command.run(diagnosticEnvironment: [key: "1"], diagnosticSink: sink)
                Issue.record("없는 배치 파일은 실패해야 한다")
            } catch {
                #expect(String(describing: error) == originalError)
            }
        }
        let fields = enabled.trimmingCharacters(in: .newlines).split(separator: " ").map(String.init)
        #expect(fields.count == 10)
        #expect(fields.first == "cartograph-query-phases-v1")
        let setup = try #require(fields.dropFirst().first)
        #expect(setup.range(of: #"^cli_setup=[0-9]+\.[0-9]{9}$"#, options: .regularExpression) != nil)
        #expect(Array(fields.dropFirst(2)) == names.dropFirst().map { "\($0)=not_run" })
        #expect(enabled.split(separator: "\n").count == 1)
        #expect(!enabled.contains(path))
        #expect(!enabled.contains("private-query-name"))
    }

    private func expectedLine(values: [String: String]) -> String {
        "cartograph-query-phases-v1 " + names.map { "\($0)=\(values[$0] ?? "not_run")" }.joined(separator: " ") + "\n"
    }

    private func capture(_ body: (FileHandle) throws -> Void) throws -> String {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try body(pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        return String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
    }
}

private final class DiagnosticTestError: Error {}
