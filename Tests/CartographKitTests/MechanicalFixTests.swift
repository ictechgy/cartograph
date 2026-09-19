import CartographAnalysis
import CartographCore
import CartographTestSupport
@testable import CartographKit
import Foundation
import Testing

@Suite("기계적 수정 계획")
struct MechanicalFixTests {
    private static let sourcePath = "/p/Sources/A.swift"

    /// `import Combine` 하나와 쓰이지 않는 `retry` 파라미터를 가진 파일.
    private static let source = """
        import Combine

        func caller(retry: Int) -> Int {
            return 1
        }
        """

    /// 구문 위치와 일치하는 인덱스 스냅샷.
    private func snapshot(parameterLine: Int = 3, parameterColumn: Int = 13) -> IndexSnapshot {
        var builder = SnapshotBuilder(path: Self.sourcePath)
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("caller", name: "caller()", kind: .function, path: Self.sourcePath,
            line: 3, column: 6)
        builder.reference(from: "App", to: "caller", kind: .call, path: Self.sourcePath)
        builder.parameter("param", name: "retry", functionUSR: "caller", path: Self.sourcePath,
            line: parameterLine, column: parameterColumn, isReferenced: false)
        builder.fileModuleUsage(path: Self.sourcePath, owningModule: "App")
        return builder.build()
    }

    private func service(
        snapshot: IndexSnapshot,
        fileSystem: InMemoryFileSystem,
        reportScope: ReportScope? = nil
    ) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return CartographService(
            configuration: configuration,
            environment: .init(
                fileSystem: fileSystem,
                indexProviderOverride: StaticIndexProvider(snapshot),
                usesSyntaxCache: false
            ),
            reportScope: reportScope
        )
    }

    private func fileSystem(_ source: String = MechanicalFixTests.source) -> InMemoryFileSystem {
        InMemoryFileSystem(files: [Self.sourcePath: source])
    }

    private func document(_ outcome: CommandOutcome) throws -> MechanicalFixDocument {
        try JSONDecoder().decode(MechanicalFixDocument.self, from: Data(outcome.output.utf8))
    }

    private func contents(_ fileSystem: InMemoryFileSystem) throws -> String {
        try fileSystem.readText(at: Self.sourcePath)
    }

    @Test("드라이런은 계획만 세우고 파일을 건드리지 않는다")
    func dryRunPlansWithoutWriting() throws {
        let fileSystem = fileSystem()
        let outcome = try service(snapshot: snapshot(), fileSystem: fileSystem)
            .mechanicalFixes(apply: false, format: "json")
        let document = try document(outcome)

        #expect(!document.applied)
        #expect(document.editCount == 2)
        #expect(document.fileCount == 1)
        #expect(document.skippedCount == 0)
        #expect(document.edits.map(\.rule) == ["unused-import", "unused-parameter"])
        let importEdit = try #require(document.edits.first)
        #expect(importEdit.file == Self.sourcePath)
        #expect(importEdit.line == 1)
        #expect(importEdit.column == 1)
        #expect(importEdit.replacement.isEmpty)
        let parameterEdit = try #require(document.edits.last)
        #expect(parameterEdit.line == 3)
        #expect(parameterEdit.column == 13)
        #expect(parameterEdit.replacement == "retry _")
        // 계획 단계에서도 파일은 그대로다.
        #expect(try contents(fileSystem) == Self.source)
        // 드라이런의 남은 작업이 --strict 의 실패 사유다.
        #expect(outcome.findingCount == 2)
    }

    @Test("적용하면 import 줄을 지우고 파라미터 레이블을 남긴다")
    func applyWritesEdits() throws {
        let fileSystem = fileSystem()
        let outcome = try service(snapshot: snapshot(), fileSystem: fileSystem)
            .mechanicalFixes(apply: true, format: "text")
        #expect(outcome.output.contains("applied"))
        #expect(try contents(fileSystem) == """

            func caller(retry _: Int) -> Int {
                return 1
            }
            """)
        // 다 적용했으므로 strict 에 남는 발견이 없다.
        #expect(outcome.findingCount == 0)
    }

    @Test("적용 뒤 다시 돌려도 인덱스가 낡았으면 눈으로 보고 멈춘다")
    func appliesOnceWithoutBlindSecondEdit() throws {
        let fileSystem = fileSystem()
        let service = service(snapshot: snapshot(), fileSystem: fileSystem)
        _ = try service.mechanicalFixes(apply: true, format: "json")

        // 인덱스는 아직 import 와 3행의 파라미터를 가리킨다. 소스는 이미 바뀌었다.
        // import 발견은 다시 파싱한 소스에서 사라지고, 파라미터는 자리가 어긋나
        // 건너뛴다 — 낡은 인덱스로 두 번째 편집을 추측하지 않는다.
        let second = try document(try service.mechanicalFixes(apply: false, format: "json"))
        #expect(second.editCount == 0)
        #expect(second.skippedCount == 1)
        #expect(second.skipped.first?.reason == "notFound")
    }

    @Test("자리가 어긋난 파라미터는 건너뛰고 이유를 남긴다")
    func skipsMismatchedParameterLocation() throws {
        let fileSystem = fileSystem()
        // 인덱스가 다른 줄을 가리키면 그 자리의 토큰을 파라미터로 오인하지 않는다.
        let outcome = try service(snapshot: snapshot(parameterLine: 9), fileSystem: fileSystem)
            .mechanicalFixes(apply: false, format: "json")
        let document = try document(outcome)
        #expect(document.editCount == 1)
        #expect(document.edits.first?.rule == "unused-import")
        #expect(document.skippedCount == 1)
        #expect(document.skipped.first?.reason == "notFound")
    }

    @Test("스코프 밖 발견은 보고에서 빠지고 계획에도 들어오지 않는다")
    func respectsReportScope() throws {
        let fileSystem = fileSystem()
        let outcome = try service(
            snapshot: snapshot(), fileSystem: fileSystem,
            reportScope: ReportScope(files: ["/p/Sources/Other.swift"])
        ).mechanicalFixes(apply: false, format: "json")
        let document = try document(outcome)
        #expect(document.editCount == 0)
        #expect(document.skippedCount == 0)
        // 스코프는 렌즈이지 베이스라인 억제가 아니다 — 억제 수에는 세지 않는다.
        #expect(document.suppressedCount == 0)
        #expect(try contents(fileSystem) == Self.source)
    }

    @Test("베이스라인이 억제한 발견은 건드리지 않는다")
    func respectsBaseline() throws {
        let fileSystem = fileSystem()
        let baseline = Baseline(fingerprints: [
            "unused-import|import:\(Self.sourcePath):Combine",
        ])
        try fileSystem.write(
            JSONEncoder.cartographDefault().encode(baseline), to: "/p/.cartograph-baseline.json"
        )
        let outcome = try service(snapshot: snapshot(), fileSystem: fileSystem)
            .mechanicalFixes(apply: false, format: "json")
        let document = try document(outcome)
        #expect(document.edits.map(\.rule) == ["unused-parameter"])
        #expect(document.suppressedCount == 1)
    }

    @Test("text 출력은 계획과 요약을 사람이 읽을 수 있게 적는다")
    func rendersTextPlan() throws {
        let fileSystem = fileSystem()
        let outcome = try service(snapshot: snapshot(), fileSystem: fileSystem)
            .mechanicalFixes(apply: false, format: "text")
        #expect(outcome.output.contains("\(Self.sourcePath):1:1:"))
        #expect(outcome.output.contains("\(Self.sourcePath):3:13:"))
        #expect(outcome.output.contains("2 fix(es) in 1 file(s) — dry run; pass --apply to write"))
        #expect(try contents(fileSystem) == Self.source)
    }

    @Test("고칠 것이 없으면 계획이 비고 파일을 만들지 않는다")
    func reportsNoFixes() throws {
        var builder = SnapshotBuilder(path: Self.sourcePath)
        builder.symbol("App", kind: .structType, attributes: [.entryPoint])
        builder.symbol("caller", name: "caller()", kind: .function, path: Self.sourcePath,
            line: 1, column: 6)
        builder.reference(from: "App", to: "caller", kind: .call, path: Self.sourcePath)
        builder.fileModuleUsage(path: Self.sourcePath, owningModule: "App")
        let fileSystem = InMemoryFileSystem(files: [Self.sourcePath: "func caller() {}\n"])
        let outcome = try service(snapshot: builder.build(), fileSystem: fileSystem)
            .mechanicalFixes(apply: false, format: "text")
        #expect(outcome.output.contains("no mechanical fixes found"))
        #expect(outcome.findingCount == 0)
    }
}
