import Foundation
@testable import cartograph
import Testing

/// 저장소 루트의 `action.yml` 이 GitHub Action 계약과 어긋나지 않는지 고정한다.
///
/// 액션은 스크립트 안에서 입력을 이름으로 참조하므로, 오타 하나가 런타임에야
/// 드러난다. CI의 스모크 단계가 실행까지 검증하지만, 선언과 참조의 드리프트는
/// 여기서 먼저 잡는다.
@Suite("GitHub Action 매니페스트")
struct ActionManifestTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var manifest: String {
        get throws {
            try String(contentsOf: repositoryRoot.appendingPathComponent("action.yml"), encoding: .utf8)
        }
    }

    @Test("컴포지트 액션으로 선언되어 있고 모든 실행 단계가 셸을 지정한다")
    func isCompositeWithShellSteps() throws {
        let text = try manifest
        #expect(text.hasPrefix("name: Cartograph\n"))
        #expect(text.contains("\nruns:\n  using: composite\n"))
        // 컴포지트 단계의 `run` 은 shell 이 없으면 런타임에 거부된다.
        let runSteps = text.split(separator: "\n").count { $0.hasPrefix("      run:") }
        let shellSteps = text.split(separator: "\n").count { $0 == "      shell: bash" }
        #expect(runSteps > 0)
        #expect(runSteps == shellSteps, "run 단계 \(runSteps)개 / shell 단계 \(shellSteps)개")
    }

    @Test("스크립트가 참조하는 입력은 전부 선언되어 있고, 선언한 입력은 전부 쓰인다")
    func inputReferencesMatchDeclarations() throws {
        let text = try manifest
        let declared = Self.declaredInputs(in: text)
        let referenced = Self.referencedInputs(in: text)
        #expect(!declared.isEmpty)
        #expect(declared == referenced, "선언 \(declared.sorted()) / 참조 \(referenced.sorted())")
        // outputs 는 컴포지트에서 값 표현식으로만 쓰인다 — 선언과 노출이 함께 있어야 한다.
        #expect(text.contains("  sarif-file:\n"))
        #expect(text.contains("value: ${{ steps.run.outputs.sarif-file }}"))
        #expect(text.contains("value: ${{ steps.run.outputs.exit-code }}"))
    }

    @Test("액션이 허용하는 게이트는 실제 하위 명령이다")
    func allowlistedCommandsExist() throws {
        #expect(try manifest.contains("check|dead|cycles|rules"))
        let registered = Set(CartographCommand.configuration.subcommands.map { $0.configuration.commandName })
        #expect(registered.isSuperset(of: ["check", "dead", "cycles", "rules"]))
    }

    @Test("README가 액션 사용법을 안내한다")
    func readmeDocumentsTheAction() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8
        )
        #expect(readme.contains("uses: ictechgy/cartograph@"))
        #expect(readme.contains("upload-sarif"))
        #expect(readme.contains("Fail-on-findings") || readme.contains("fail-on-findings"))
    }

    /// `inputs:` 아래 두 칸 들여쓰기의 이름들.
    private static func declaredInputs(in text: String) -> Set<String> {
        var names: Set<String> = []
        var inInputs = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "inputs:" { inInputs = true; continue }
            if inInputs, line.hasPrefix("outputs:") { break }
            guard inInputs, line.hasPrefix("  "), !line.hasPrefix("    "), line.hasSuffix(":") else {
                continue
            }
            names.insert(String(line.dropFirst(2).dropLast()))
        }
        return names
    }

    /// `${{ inputs.이름 }}` 에서 이름만 모은다.
    private static func referencedInputs(in text: String) -> Set<String> {
        var names: Set<String> = []
        var rest = Substring(text)
        while let range = rest.range(of: "${{ inputs.") {
            rest = rest[range.upperBound...]
            let name = rest.prefix { !$0.isWhitespace && $0 != "}" }
            names.insert(String(name))
        }
        return names
    }
}
