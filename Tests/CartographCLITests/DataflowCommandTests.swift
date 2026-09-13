import ArgumentParser
import CartographCore
@testable import cartograph
import Testing

@Suite("dataflow 인자 검증")
struct DataflowCommandTests {
    @Test("함수 대상과 기본 예산을 파싱한다")
    func parsesSubjectAndDefaults() throws {
        let command = try DataflowCommand.parse(["HomeView.body"])
        try command.validate()
        #expect(command.subject == "HomeView.body")
        // 미지정 예산은 nil 로 남는다. 기본값은 ValueFlowLimits.standard 한 곳이
        // 근원이라 CLI 옵션이 따로 숫자를 기억하지 않는다.
        #expect(command.maxContexts == nil)
        #expect(command.maxIterations == nil)
        #expect(command.maxValues == nil)
        #expect(command.maxHeapCells == nil)
        #expect(command.callDepth == nil)
        let limits = ValueFlowLimits.resolved(
            contexts: command.maxContexts, iterations: command.maxIterations,
            valuesPerNode: command.maxValues, heapCells: command.maxHeapCells,
            callStringDepth: command.callDepth
        )
        #expect(limits == ValueFlowLimits.standard)
    }

    @Test("양수 예산과 제한된 호출 깊이를 허용한다")
    func acceptsBoundedLimits() throws {
        let command = try DataflowCommand.parse([
            "Worker.run", "--max-contexts", "4", "--max-iterations", "9", "--max-values", "3",
            "--max-heap-cells", "12", "--call-depth", "8",
        ])
        try command.validate()
        #expect(command.callDepth == 8)
    }

    @Test("0 이하의 예산과 범위를 벗어난 호출 깊이를 거부한다")
    func rejectsInvalidLimits() {
        for arguments in [
            ["Worker.run", "--max-contexts", "0"],
            ["Worker.run", "--max-iterations", "0"],
            ["Worker.run", "--max-values", "0"],
            ["Worker.run", "--max-heap-cells", "0"],
            ["Worker.run", "--call-depth", "0"],
            ["Worker.run", "--call-depth", "9"],
        ] {
            do {
                let command = try DataflowCommand.parse(arguments)
                try command.validate()
                Issue.record("오류가 발생해야 한다: \(arguments)")
            } catch {
                #expect(!"\(error)".isEmpty)
            }
        }
    }

    @Test("값 그래프에 의미 없는 전역 옵션을 거부한다")
    func rejectsIgnoredGlobalOptions() {
        for arguments in [
            ["Worker.run", "--level", "symbol"],
            ["Worker.run", "--since", "HEAD"],
            ["Worker.run", "--report-format", "text"],
        ] {
            do {
                let command = try DataflowCommand.parse(arguments)
                try command.validate()
                Issue.record("오류가 발생해야 한다: \(arguments)")
            } catch {
                #expect(!"\(error)".isEmpty)
            }
        }
    }
}
