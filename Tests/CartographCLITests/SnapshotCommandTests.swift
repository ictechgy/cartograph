import ArgumentParser
import CartographKit
@testable import cartograph
import Testing

@Suite("snapshot 인자 검증")
struct SnapshotCommandTests {
    @Test("스냅샷 파일 예산은 기본값을 유지하며 유한한 명시적 상한만 받는다")
    func boundedSnapshotSizeOption() throws {
        #expect(try SnapshotCommand.parse([]).snapshotMaxMiB == 128)
        #expect(try SnapshotCommand.parse(["--snapshot-max-mib", "512"]).snapshotMaxMiB == 512)
        for value in ["0", "-1", "1025", String(Int.max)] {
            #expect(throws: (any Error).self) {
                try SnapshotCommand.parse(["--snapshot-max-mib", value]).validate()
            }
        }
        let command = try SnapshotCommand.parse(["--snapshot-max-mib", "1024"])
        try command.validate()
    }

    @Test("새 스냅샷 명령은 런타임 발견 근거를 담는 v2를 기록한다")
    func writesVersionTwo() {
        #expect(AnalysisSnapshotDocument.version == 2)
    }

    @Test("스냅샷은 심볼 레벨 JSON 캡처 옵션을 파싱한다")
    func parsesSnapshotOptions() throws {
        let command = try SnapshotCommand.parse([
            "--revision", "base",
            "--runtime-contracts", "contracts.json",
            "--coredata-build-evidence", "coredata.json",
        ])
        try command.validate()
        #expect(command.revision == "base")
        #expect(command.runtimeContracts == "contracts.json")
        #expect(command.coreDataBuildEvidence == "coredata.json")
    }

    @Test("스냅샷 사실과 충돌하는 전역 옵션을 거부한다")
    func rejectsMeaninglessOptions() {
        for arguments in [
            ["--since", "HEAD"],
            ["--level", "module"],
            ["--report-format", "json"],
            ["--strict"],
            ["--baseline", "baseline.json"],
            ["--revision", ""],
        ] {
            do {
                let command = try SnapshotCommand.parse(arguments)
                try command.validate()
                Issue.record("오류가 발생해야 한다: \(arguments)")
            } catch {
                #expect(!"\(error)".isEmpty)
            }
        }
    }
}
