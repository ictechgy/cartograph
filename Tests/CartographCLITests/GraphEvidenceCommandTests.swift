import ArgumentParser
@testable import cartograph
import Testing

@Suite("graph occurrence 근거 옵션")
struct GraphEvidenceCommandTests {
    @Test("--evidence는 JSON graph에서만 켜진다")
    func evidenceRequiresJSON() throws {
        let command = try GraphCommand.parse(["--format", "json", "--evidence"])
        try command.validate()
        #expect(command.includeEvidence)

        #expect(throws: (any Error).self) {
            let invalid = try GraphCommand.parse(["--format", "dot", "--evidence"])
            try invalid.validate()
        }
    }

    @Test("declaration projection은 primary module·symbol JSON을 함께 요구한다")
    func projectionRequiresExplicitInputs() throws {
        let command = try GraphCommand.parse([
            "--declaration-projection", "--primary-module", "Core", "--level", "symbol", "--format", "json",
        ])
        try command.validate()
        #expect(command.declarationProjection)
        #expect(command.primaryModule == "Core")

        for arguments in [
            ["--declaration-projection", "--level", "symbol", "--format", "json"],
            ["--primary-module", "Core", "--level", "symbol", "--format", "json"],
            ["--declaration-projection", "--primary-module", "Core", "--level", "module", "--format", "json"],
            ["--declaration-projection", "--primary-module", "Core", "--level", "symbol", "--format", "dot"],
            [
                "--declaration-projection", "--primary-module", "Core",
                "--level", "symbol", "--format", "json", "--evidence",
            ],
            ["--declaration-projection", "--primary-module", "Core", "--format", "json"],
            ["--declaration-projection", "--primary-module", "Core", "--level", "symbol"],
            ["--declaration-projection", "--primary-module", "Bad Module", "--level", "symbol", "--format", "json"],
        ] {
            #expect(throws: (any Error).self) {
                let invalid = try GraphCommand.parse(arguments)
                try invalid.validate()
            }
        }
    }
}
