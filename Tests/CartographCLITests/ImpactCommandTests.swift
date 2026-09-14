import ArgumentParser
@testable import cartograph
import Testing

@Suite("impact 인자 검증")
struct ImpactCommandTests {
    @Test("Core Data 내용과 버전 선택 변경도 since 영향 분석의 입력이다")
    func includesCoreDataChangesInImpactSeeds() {
        #expect(ImpactCommand.isModeledChange("Sources/Store.xcdatamodel/contents"))
        #expect(ImpactCommand.isModeledChange("Sources/Store.xcdatamodeld/.xccurrentversion"))
        #expect(!ImpactCommand.isModeledChange("Documentation/contents"))
        #expect(!ImpactCommand.isModeledChange("Documentation/.xccurrentversion"))
    }

    @Test("심볼 선택 모드와 기본값을 파싱한다")
    func parsesSymbolSelectorAndDefaults() throws {
        let command = try ImpactCommand.parse(["HomeView", "UserService"])
        try command.validate()
        #expect(command.symbols == ["HomeView", "UserService"])
        #expect(command.files.isEmpty)
        #expect(command.options.since == nil)
        #expect(command.depth == nil)
        #expect(command.limit == 200)
        #expect(command.format == .text)
    }

    @Test("Core Data 빌드 근거는 현재 영향 분석에서만 선택하고 trace와 섞지 않는다")
    func parsesCoreDataBuildEvidence() throws {
        let command = try ImpactCommand.parse([
            "--file", "Store.xcdatamodel/contents",
            "--coredata-build-evidence", "coredata.json",
        ])
        try command.validate()
        #expect(command.coreDataBuildEvidence == "coredata.json")
        #expect(throws: (any Error).self) {
            let mixed = try ImpactCommand.parse([
                "Record", "--trace", "trace.json", "--executable", "App",
                "--coredata-build-evidence", "coredata.json",
            ])
            try mixed.validate()
        }
    }

    @Test("파일 선택을 반복하고 git 기준점을 선택한다")
    func parsesFileAndSinceSelectors() throws {
        let fileCommand = try ImpactCommand.parse([
            "--file", "Sources/App.swift", "--file", "Sources/Feature.swift",
            "--format", "json", "--depth", "8", "--limit", "1000",
        ])
        try fileCommand.validate()
        #expect(fileCommand.files == ["Sources/App.swift", "Sources/Feature.swift"])
        #expect(fileCommand.format == .json)
        #expect(fileCommand.depth == 8)
        #expect(fileCommand.limit == 1000)

        let sinceCommand = try ImpactCommand.parse(["--since", "origin/main"])
        try sinceCommand.validate()
        #expect(sinceCommand.options.since == "origin/main")
    }

    @Test("선택 모드를 비우거나 둘 이상 고르면 거부한다")
    func rejectsMissingOrMixedSelectors() {
        for arguments in [
            [],
            ["HomeView", "--file", "Sources/App.swift"],
            ["--file", "Sources/App.swift", "--since", "HEAD"],
            ["HomeView", "--since", "HEAD"],
            ["--since", ""],
            ["--file", ""],
        ] {
            do {
                let command = try ImpactCommand.parse(arguments)
                try command.validate()
                Issue.record("오류가 발생해야 한다: \(arguments)")
            } catch {
                #expect(!"\(error)".isEmpty)
            }
        }
    }

    @Test("깊이와 결과 수 제한은 계약 범위 안에서만 허용한다")
    func rejectsOutOfRangeLimits() {
        for arguments in [
            ["HomeView", "--depth", "0"],
            ["HomeView", "--depth", "129"],
            ["HomeView", "--limit", "0"],
            ["HomeView", "--limit", "10001"],
        ] {
            do {
                let command = try ImpactCommand.parse(arguments)
                try command.validate()
                Issue.record("오류가 발생해야 한다: \(arguments)")
            } catch {
                #expect(!"\(error)".isEmpty)
            }
        }
    }

    @Test("사실 보고서에 의미 없는 전역 옵션을 거부한다")
    func rejectsIgnoredGlobalOptions() {
        for arguments in [
            ["HomeView", "--level", "symbol"],
            ["HomeView", "--report-format", "json"],
            ["HomeView", "--strict"],
        ] {
            do {
                let command = try ImpactCommand.parse(arguments)
                try command.validate()
                Issue.record("오류가 발생해야 한다: \(arguments)")
            } catch {
                #expect(!"\(error)".isEmpty)
            }
        }
    }
}
