import ArgumentParser
@testable import cartograph
import Testing

@Suite("런타임 계약 명령")
struct RuntimeCommandTests {
    @Test("Core Data 준비 명령은 모델·앱·생성 소스·모듈·출력을 모두 요구한다")
    func parsesCoreDataPreparation() throws {
        let command = try RuntimePrepareCoreDataCommand.parse([
            "--model", "Store.xcdatamodeld",
            "--container", "Store",
            "--executable", "Probe.app/Contents/MacOS/Probe",
            "--generated-source", "GeneratedRecord+CoreDataClass.swift",
            "--module", "Probe",
            "-o", "coredata-build.json",
        ])
        try command.validate()
        #expect(command.containerName == "Store")
        #expect(command.generatedSources == ["GeneratedRecord+CoreDataClass.swift"])
        let manual = try RuntimePrepareCoreDataCommand.parse([
            "--model", "Manual.xcdatamodel",
            "--container", "Manual",
            "--executable", "Manual.app/Contents/MacOS/Manual",
            "-o", "manual-evidence.json",
        ])
        try manual.validate()
        #expect(manual.generatedSources.isEmpty)
        #expect(manual.module == nil)
        #expect(throws: (any Error).self) {
            let invalid = try RuntimePrepareCoreDataCommand.parse([
                "--model", "Store.xcdatamodeld", "--container", "Store",
                "--executable", "Probe", "--generated-source", "Record.swift",
                "-o", "evidence.json",
            ])
            try invalid.validate()
        }
    }

    @Test("runtime은 Core Data 준비 명령을 명시적으로 등록한다")
    func registersCoreDataPreparation() {
        let names = RuntimeCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names == ["discover", "prepare-coredata", "plan", "check", "collect"])
    }

    @Test("계획에는 계약을 검증에는 계약과 관측을 요구한다")
    func requiresEvidenceInputs() throws {
        let plan = try RuntimePlanCommand.parse([
            "--contracts", "contracts.json", "--executable", "App"
        ])
        try plan.validate()
        let check = try RuntimeCheckCommand.parse([
            "--contracts", "contracts.json", "--observations", "observations.json",
            "--executable", "App", "--strict",
        ])
        try check.validate()
        #expect(check.options.strict)
        #expect(throws: (any Error).self) { try RuntimePlanCommand.parse(["--contracts", "c.json"]) }
        #expect(throws: (any Error).self) {
            try RuntimeCheckCommand.parse(["--contracts", "c.json", "--observations", "o.json"])
        }
        #expect(throws: (any Error).self) {
            var command = try RuntimePlanCommand.parse(["--contracts", "c.json", "--executable", ""])
            try command.validate()
        }
    }

    @Test("런타임 검증을 좁히거나 억제한다고 오해할 옵션을 거부한다")
    func rejectsIgnoredOptions() {
        for option in [["--level", "type"], ["--since", "HEAD"],
                       ["--report-format", "json"], ["--baseline", "baseline.json"]] {
            #expect(throws: (any Error).self) {
                let command = try RuntimePlanCommand.parse(
                    ["--contracts", "c.json", "--executable", "App"] + option
                )
                try command.validate()
            }
        }
    }
}
