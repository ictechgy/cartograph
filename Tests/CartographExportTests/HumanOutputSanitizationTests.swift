import CartographCore
@testable import CartographExport
import Testing

/// 사람과 터미널이 읽는 형식(text 리포터, DOT, Mermaid)도 기계 형식과 같은 필터를 지나는지.
///
/// 경로·이름·메시지·규칙 설명은 분석 대상 저장소가 통제하는 값이다. 파일 이름의 개행 하나면
/// 위조 진단 줄이 붙고, ESC 는 터미널 화면을, OSC 52 는 클립보드를, U+202E 는 표시 순서를 바꾼다.
@Suite("사람용 출력의 제어·형식 문자 정화")
struct HumanOutputSanitizationTests {
    /// 터미널에 클립보드를 바꾸라고 시키는 OSC 52 시퀀스. 파일 이름에 넣으면 출력만으로 클립보드가 바뀐다.
    private static let clipboard = "\u{1B}]52;c;ZWNobyBwd25lZA==\u{07}"

    /// 개행 말고 제어(Cc)·형식(Cf) 문자가 남았는지. 개행은 사람용 형식이 줄을 나누는 데 쓴다.
    private static func hasHiddenScalars(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            return scalar != "\n" && (category == .control || category == .format)
        }
    }

    @Test("텍스트 형식은 경로·메시지·세부 정보의 제어·형식 문자를 빼고 진단마다 한 줄을 지킨다")
    func textReporterKeepsOneLinePerDiagnostic() {
        // 규칙의 이유와 안내는 개행만 접히고 ESC 는 그대로 세부 정보에 실린다.
        let rule = LayerRule(
            name: "no data", from: "UI", deny: ["Data"],
            rationale: "keep \u{1B}[31mviews\u{1B}[0m testable", hint: "inject \u{1B}[2Ka use case"
        )
        let diagnostics = [
            Diagnostic(
                ruleIdentifier: "layer-violation", severity: .error,
                message: "Home (UI) depends on Store (Data) — no data",
                location: SourceLocation(path: "Sources/\(Self.clipboard)Api.swift", line: 1, column: 1),
                details: rule.violationDetails
            ),
            Diagnostic(
                ruleIdentifier: "unused-symbol", severity: .warning,
                message: "struct 'App.\u{202E}txt.exe' is never used",
                location: SourceLocation(
                    path: "Sources/a\nApp.swift:1:1: warning: ok\u{1B}[2J.swift", line: 3, column: 1
                )
            ),
        ]
        let summary = ReportSummary(
            command: "rules",
            subject: "module graph\u{1B}[1A · 2 nodes",
            limitations: ["objective-c-sources: \u{1B}[2K2 file(s) are not analysed"],
            caveat: "analysed \u{202E}nothing"
        )

        let output = TextDiagnosticReporter().report(diagnostics, summary: summary)

        #expect(!Self.hasHiddenScalars(output))
        // 빈 줄 앞의 들여쓰지 않은 줄이 곧 진단이다. 위조 줄이 붙으면 진단 수보다 많아진다.
        let body = output.split(separator: "\n", omittingEmptySubsequences: false).prefix { !$0.isEmpty }
        #expect(body.filter { !$0.hasPrefix("    ") }.count == diagnostics.count)
        #expect(output == """
            Sources/]52;c;ZWNobyBwd25lZA==Api.swift:1:1: error: Home (UI) depends on Store (Data) — no data
                rule: no data
                rationale: keep [31mviews[0m testable
                hint: inject [2Ka use case
            Sources/aApp.swift:1:1: warning: ok[2J.swift:3:1: warning: struct 'App.txt.exe' is never used

            rules: 1 error, 1 warning (analysed nothing) (1 limitation) — module graph[1A · 2 nodes
            limitations:
              objective-c-sources: [2K2 file(s) are not analysed

            """)
    }

    @Test("DOT 은 라벨의 제어·형식 문자는 빼고 식별자·클러스터 이름의 것은 보이는 글자로 바꿔 한 줄을 지킨다")
    func dotStripsHiddenScalars() {
        // 따옴표·역슬래시 탈출은 이미 막혀 있다. 남은 구멍은 파일 레벨 정점의 식별자와 이름이 그대로
        // 옮겨 오는 파일 경로의 개행·복귀·ESC·양방향 재정의다. 식별자는 지우면 다른 정점과 겹치므로
        // `\u{1B}` 같은 글자로 바꾼다.
        let path = NodeID("Sources/a\r\n\u{1B}[2J.swift")
        let module = "App\(Self.clipboard)"
        let graph = CodeGraph(
            level: .file,
            nodes: [
                GraphNode(id: path, name: "a\r\n\u{1B}[2J.swift", kind: .file, module: module),
                GraphNode(id: "Sources/b.swift", name: "b\u{202E}txt.swift", kind: .file, module: module),
            ],
            edges: [GraphEdge(source: path, target: "Sources/b.swift", kind: .reference)]
        )

        let output = DOTGraphRenderer().render(graph)

        #expect(!Self.hasHiddenScalars(output))
        #expect(output.contains("\n  subgraph \"cluster_App\\u{1B}]52;c;ZWNobyBwd25lZA==\\u{7}\" {\n"))
        #expect(output.contains("\n    label=\"App]52;c;ZWNobyBwd25lZA==\";\n"))
        #expect(output.contains(
            "\n    \"Sources/a\\u{D}\\u{A}\\u{1B}[2J.swift\" [label=\"a[2J.swift\", shape=note];\n"
        ))
        #expect(output.contains("\n    \"Sources/b.swift\" [label=\"btxt.swift\", shape=note];\n"))
        #expect(output.contains("\n  \"Sources/a\\u{D}\\u{A}\\u{1B}[2J.swift\" -> \"Sources/b.swift\" ["))
    }

    @Test("DOT 은 제어·형식 문자 하나만 다른 파일들을 다른 정점과 다른 간선으로 남긴다")
    func dotKeepsNodesApartWhenOnlyHiddenScalarsDiffer() {
        // 식별자에서 U+200B(Cf)를 지우면 두 경로가 같은 ID 가 된다. DOT 에서 같은 ID 의 문장은 한 정점이라
        // Graphviz 가 둘을 합치고 숨은 파일의 의존을 정상 파일에 붙인다. 원래 `\u{200B}` 라고 적힌
        // 이름(역슬래시 글자)과도 겹치지 않아야 이스케이프가 단사다.
        let plain = NodeID("Sources/A.swift")
        let hidden = NodeID("Sources/A\u{200B}.swift")
        let spelled = NodeID("Sources/A\\u{200B}.swift")
        let target = NodeID("Sources/B.swift")
        let graph = CodeGraph(
            level: .file,
            nodes: [plain, hidden, spelled, target].map { id in
                GraphNode(id: id, name: String(id.rawValue.dropFirst("Sources/".count)), kind: .file)
            },
            edges: [GraphEdge(source: hidden, target: target, kind: .reference)]
        )

        let output = DOTGraphRenderer().render(graph)

        #expect(!Self.hasHiddenScalars(output))
        let identifiers = output.split(separator: "\n")
            .filter { $0.contains("shape=note") }
            .map { $0.prefix { $0 != "[" } }
        #expect(identifiers.count == 4)
        #expect(Set(identifiers).count == 4)
        #expect(output.contains("\n    \"Sources/A\\u{200B}.swift\" [label=\"A.swift\", shape=note];\n"))
        #expect(output.contains("\n    \"Sources/A\\\\u{200B}.swift\" [label=\"A\\\\u{200B}.swift\", shape=note];\n"))
        // 숨은 파일의 의존은 숨은 파일에 남는다. 정상 파일에 붙으면 그래프가 거짓말을 한다.
        #expect(output.contains("\n  \"Sources/A\\u{200B}.swift\" -> \"Sources/B.swift\" ["))
        #expect(!output.contains("\"Sources/A.swift\" ->"))
    }

    @Test("Mermaid 는 라벨의 개행을 공백으로 접고 나머지 제어·형식 문자는 뺀다")
    func mermaidStripsHiddenScalars() {
        // 개행을 공백으로 접는 것은 원래 규칙이다. 복귀·ESC·BEL·양방향 재정의는 그대로 지나가고 있었다.
        let graph = CodeGraph(
            level: .file,
            nodes: [GraphNode(id: "a", name: "a\nb\r\u{1B}[2K\u{202E}c\(Self.clipboard).swift", kind: .file)],
            edges: []
        )

        let output = MermaidGraphRenderer().render(graph)

        #expect(!Self.hasHiddenScalars(output))
        #expect(output == "flowchart LR\n    n0[/\"a b[2Kc]52;c;ZWNobyBwd25lZA==.swift\"/]\n")
    }
}
