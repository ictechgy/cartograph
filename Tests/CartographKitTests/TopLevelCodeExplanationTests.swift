import CartographAnalysis
import CartographCore
@testable import CartographKit
import CartographTestSupport
import Testing

/// `main.swift` 의 최상위 선언은 쓰이지 않아도 진입점 근거로 남는다(의도된 보존). 설명이 그것을
/// `@main` 이라고 말하면, 사용자는 그 파일의 미사용 도우미가 애초에 보고될 수 없다는 것을 모른다.
@Suite("main.swift 최상위 선언의 보존 설명")
struct TopLevelCodeExplanationTests {
    private func service() -> CartographService {
        var snapshot = SnapshotBuilder()
        snapshot.symbol("helper", name: "helper()", kind: .function, module: "Tool", path: "/p/Sources/Tool/main.swift")
        snapshot.symbol("Options", kind: .structType, module: "Tool", path: "/p/Sources/Tool/main.swift", line: 5)
        snapshot.symbol("Options.verbose", name: "verbose", kind: .property, module: "Tool",
                        path: "/p/Sources/Tool/main.swift", line: 6, parent: "Options")
        snapshot.symbol("Entry", kind: .structType, module: "App", path: "/p/Sources/App/Entry.swift",
                        attributes: [.entryPoint])
        var configuration = CartographConfiguration.default
        configuration.projectPath = "/p"
        return CartographService(configuration: configuration, environment: .init(
            fileSystem: InMemoryFileSystem(files: [
                "/p/Sources/Tool/main.swift": "func helper() {}\nstruct Options { var verbose = false }",
                "/p/Sources/App/Entry.swift": "@main struct Entry {}",
            ]),
            indexProviderOverride: StaticIndexProvider(snapshot.build())
        ))
    }

    @Test("main.swift 최상위 선언은 @main 이 아니라 최상위 선언이라서 남는다고 설명한다")
    func explainsTopLevelDeclarationRetention() throws {
        let service = service()
        for subject in ["helper", "Options"] {
            let output = try service.explainRetention(of: subject).output
            #expect(output.contains("is retained because it is a top-level declaration in main.swift"))
            #expect(output.contains("whether or not top-level code uses it"))
            #expect(!output.contains("(@main)"))
        }
        // `@main` 으로 표시된 진입점의 설명은 그대로다.
        #expect(try service.explainRetention(of: "Entry").output
            .contains("is retained because it is declared as an application entry point (@main)."))
        // 최상위 선언만 그렇다. 그 안의 멤버는 보존 근거가 아니며 위 문장도 붙지 않는다.
        #expect(!(try service.explainRetention(of: "verbose").output.contains("main.swift")))
    }

    @Test("보존 판정과 질의의 근거 값은 바뀌지 않는다")
    func retentionReasonValueIsUnchanged() throws {
        let service = service()
        let context = try service.loadContext()
        let report = service.unusedCode(in: context).report
        let reasons = report.retentions.filter { $0.key.rawValue == "helper" || $0.key.rawValue == "Options" }
        #expect(reasons.count == 2)
        #expect(reasons.values.allSatisfy { $0 == .entryPoint })
    }
}
