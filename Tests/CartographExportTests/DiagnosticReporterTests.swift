import CartographAnalysis
import CartographCore
@testable import CartographExport
import Foundation
import Testing

@Suite("진단 리포터")
struct DiagnosticReporterTests {
    private let summary = ReportSummary(command: "cycles", subject: "module graph · 3 nodes")

    private var diagnostics: [Diagnostic] {
        [
            Diagnostic(
                ruleIdentifier: "cycle",
                severity: .error,
                message: "Circular dependency: A → B → A",
                location: SourceLocation(path: "/p/A.swift", line: 10, column: 5),
                subject: "A|B",
                details: ["weakest link: B → A"]
            ),
            Diagnostic(
                ruleIdentifier: "unused-symbol",
                severity: .warning,
                message: "struct 'App.Dead' is never used",
                location: SourceLocation(path: "/p/Dead.swift", line: 3, column: 1),
                subject: "s:3App4DeadV"
            ),
            Diagnostic(ruleIdentifier: "unassigned-layer", severity: .info, message: "Shared has no layer"),
        ]
    }

    @Test("텍스트 형식은 위치와 세부 정보를 함께 보여 준다")
    func textIncludesLocationAndDetails() throws {
        let output = try TextDiagnosticReporter().report(diagnostics, summary: summary)
        #expect(output.contains("/p/A.swift:10:5: error: Circular dependency: A → B → A"))
        #expect(output.contains("    weakest link: B → A"))
        #expect(output.contains("cycles: 1 error, 1 warning, 1 info — module graph · 3 nodes"))
    }

    @Test("문제가 없어도 무엇을 검사했는지 알려 준다")
    func textAlwaysPrintsSummary() throws {
        // 아무 출력이 없으면 통과와 오작동을 구분할 수 없다.
        let output = try TextDiagnosticReporter().report([], summary: summary)
        #expect(output.contains("cycles: no findings — module graph · 3 nodes"))
    }

    @Test("베이스라인으로 걸러 낸 수를 보고한다")
    func textReportsSuppressedCount() throws {
        let output = try TextDiagnosticReporter().report(
            [],
            summary: ReportSummary(command: "dead", subject: "symbol graph", suppressedCount: 12)
        )
        #expect(output.contains("(12 suppressed by baseline)"))
    }

    @Test("Xcode 형식은 빌드 로그가 인식하는 접두사를 쓴다")
    func xcodeFormat() throws {
        let output = try XcodeDiagnosticReporter().report(diagnostics, summary: summary)
        #expect(output.contains("/p/A.swift:10:5: error: Circular dependency"))
        #expect(output.contains("(cycle)"))
        #expect(output.contains("info: Shared has no layer"))
    }

    @Test("GitHub Actions 형식은 워크플로 명령을 만든다")
    func githubActionsFormat() throws {
        let output = try GitHubActionsDiagnosticReporter().report(diagnostics, summary: summary)
        #expect(output.contains("::error file=/p/A.swift,line=10,col=5,title=cartograph cycle::"))
        #expect(output.contains("::notice title=cartograph unassigned-layer::"))
    }

    @Test("GitHub Actions 형식은 개행과 퍼센트를 인코딩한다")
    func githubActionsEscapesControlCharacters() throws {
        let diagnostic = Diagnostic(ruleIdentifier: "r", severity: .warning, message: "100% done\nnext")
        let output = try GitHubActionsDiagnosticReporter().report([diagnostic], summary: summary)
        #expect(output.contains("100%25 done%0Anext"))
        #expect(output.split(separator: "\n").count == 1)
    }

    @Test("GitHub Actions 형식은 터미널 제어 문자와 형식 문자를 거른다")
    func githubActionsFiltersTerminalEscapeAndFormatCharacters() throws {
        let diagnostic = Diagnostic(
            ruleIdentifier: "r",
            severity: .warning,
            message: "safe\u{001B}[31m colored \u{202E}reversed",
            location: SourceLocation(path: "/p/test\u{001B}[0m.swift", line: 1, column: 1)
        )
        let output = try GitHubActionsDiagnosticReporter().report([diagnostic], summary: summary)
        #expect(!output.contains("\u{001B}"))
        #expect(!output.contains("\u{202E}"))
        #expect(output.contains("file=/p/test%5B0m.swift") || output.contains("file=/p/test[0m.swift"))
        #expect(output.contains("safe[31m colored reversed"))
    }

    @Test("Checkstyle 형식은 파일별로 묶고 XML 을 이스케이프한다")
    func checkstyleFormat() throws {
        let diagnostic = Diagnostic(
            ruleIdentifier: "cycle",
            severity: .error,
            message: "A & B <broken>",
            location: SourceLocation(path: "/p/A.swift", line: 1, column: 1)
        )
        let output = try CheckstyleDiagnosticReporter().report([diagnostic], summary: summary)
        #expect(output.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>"))
        #expect(output.contains("<file name=\"/p/A.swift\">"))
        #expect(output.contains("message=\"A &amp; B &lt;broken&gt;\""))
        #expect(output.contains("source=\"cartograph.cycle\""))
        #expect(output.contains("</checkstyle>"))
    }

    @Test("JSON 형식은 결정적이고 다시 읽을 수 있다")
    func jsonFormat() throws {
        let reporter = JSONDiagnosticReporter()
        let first = try reporter.report(diagnostics, summary: summary)
        #expect(first == (try reporter.report(diagnostics, summary: summary)))

        struct Document: Decodable {
            let tool: String
            let command: String
            let diagnostics: [Diagnostic]
        }
        let decoded = try JSONDecoder().decode(Document.self, from: Data(first.utf8))
        #expect(decoded.tool == "cartograph")
        #expect(decoded.command == "cycles")
        #expect(decoded.diagnostics.count == 3)
    }

    @Test("JSON 은 한계가 있을 때만 limitations 키를 만든다")
    func jsonCarriesLimitationsOnlyWhenPresent() throws {
        let reporter = JSONDiagnosticReporter()
        let without = try reporter.report(diagnostics, summary: summary)
        #expect(!without.contains("\"limitations\""))

        let withLimits = try reporter.report(
            diagnostics,
            summary: ReportSummary(command: "dead", subject: "s", limitations: ["objective-c-sources: 2 file(s)"])
        )
        struct Document: Decodable { let limitations: [String]? }
        let decoded = try JSONDecoder().decode(Document.self, from: Data(withLimits.utf8))
        #expect(decoded.limitations == ["objective-c-sources: 2 file(s)"])
    }

    @Test("SARIF 형식은 스키마와 규칙 목록을 담는다")
    func sarifFormat() throws {
        let output = try SARIFDiagnosticReporter().report(diagnostics, summary: summary)
        #expect(output.contains("\"$schema\""))
        #expect(output.contains("\"version\" : \"2.1.0\""))
        #expect(output.contains("\"name\" : \"cartograph\""))
        // info 는 SARIF 에서 note 로 매핑된다.
        #expect(output.contains("\"level\" : \"note\""))
        #expect(output.contains("\"level\" : \"error\""))
        #expect(output.contains("\"startLine\" : 10"))
        #expect(output.contains("\"id\" : \"unused-symbol\""))
    }

    @Test("SARIF 는 줄/열이 0 이어도 1 이상으로 보정한다")
    func sarifClampsRegion() throws {
        let diagnostic = Diagnostic(
            ruleIdentifier: "r",
            severity: .warning,
            message: "m",
            location: SourceLocation(path: "/p/A.swift", line: 0, column: 0)
        )
        let output = try SARIFDiagnosticReporter().report([diagnostic], summary: summary)
        #expect(output.contains("\"startLine\" : 1"))
        #expect(output.contains("\"startColumn\" : 1"))
    }

    @Test("팩토리가 모든 형식의 리포터를 만든다")
    func factoryCoversAllFormats() throws {
        for format in ReportFormat.allCases {
            let output = try DiagnosticReporterFactory.make(format).report(diagnostics, summary: summary)
            #expect(!output.isEmpty)
        }
    }

    @Test("진단이 없어도 기계 형식은 유효한 문서를 만든다")
    func machineFormatsHandleEmptyInput() throws {
        for format in ReportFormat.allCases {
            let output = try DiagnosticReporterFactory.make(format).report([], summary: summary)
            switch format {
            case .xcode, .githubActions:
                #expect(output.isEmpty)
            default:
                #expect(!output.isEmpty)
            }
        }
    }

    @Test("XML 이스케이프는 다섯 가지 문자를 모두 처리한다")
    func xmlEscaping() {
        #expect(XMLEscaping.escape("&<>\"'") == "&amp;&lt;&gt;&quot;&apos;")
        #expect(XMLEscaping.escape("plain") == "plain")
    }
}

@Suite("지표 렌더러")
struct MetricsRendererTests {
    private var metrics: [NodeMetrics] {
        [
            NodeMetrics(node: "App", name: "App", afferentCoupling: 0, efferentCoupling: 3,
                        composition: TypeComposition(total: 4, abstract: 0)),
            NodeMetrics(node: "Domain", name: "Domain", afferentCoupling: 3, efferentCoupling: 0,
                        composition: TypeComposition(total: 4, abstract: 2)),
        ]
    }

    @Test("표는 열이 정렬되고 범례를 포함한다")
    func tableIsAlignedAndExplained() {
        let output = MetricsRenderer().renderTable(metrics)
        #expect(output.contains("NODE"))
        #expect(output.contains("ZONE"))
        #expect(output.contains("Ca afferent coupling"))
        #expect(output.contains("main-sequence"))
        let lines = output.split(separator: "\n")
        #expect(lines[1].allSatisfy { $0 == "-" || $0 == " " })
    }

    @Test("측정할 정점이 없으면 그렇다고 말한다")
    func emptyMetricsTable() {
        #expect(MetricsRenderer().renderTable([]) == "No nodes to measure.\n")
    }

    @Test("JSON 은 소수를 반올림해 안정적으로 출력한다")
    func jsonRoundsValues() throws {
        let output = try MetricsRenderer().renderJSON(metrics)
        #expect(output.contains("\"instability\" : 1"))
        #expect(output.contains("\"abstractness\" : 0.5"))
        #expect(output.contains("\"zone\""))
        #expect(output.contains("\"tolerance\" : 0.3"))
    }

    @Test("허용 오차를 바꾸면 영역 분류가 달라진다")
    func toleranceAffectsZone() {
        let strict = MetricsRenderer(tolerance: 0).renderTable(metrics)
        #expect(strict.contains("zone-of-"))
        let lenient = MetricsRenderer(tolerance: 1).renderTable(metrics)
        #expect(!lenient.contains("zone-of-"))
    }
}

@Suite("기계 형식 이스케이프 강화")
struct MachineReporterEscapingTests {
    private let summary = ReportSummary(command: "dead", subject: "symbol graph")

    @Test("GitHub Actions 는 속성 값의 쉼표와 콜론도 인코딩한다")
    func githubActionsEscapesPropertyValues() throws {
        // 경로에 쉼표가 있으면 GitHub 이 속성을 잘못 잘라 주석을 잃는다.
        let diagnostic = Diagnostic(
            ruleIdentifier: "unused-symbol",
            severity: .warning,
            message: "unused",
            location: SourceLocation(path: "/repo/a,b:c.swift", line: 3, column: 1)
        )
        let output = try GitHubActionsDiagnosticReporter().report([diagnostic], summary: summary)
        #expect(output.contains("file=/repo/a%2Cb%3Ac.swift"))
        #expect(!output.contains("a,b"))
    }

    @Test("SARIF 는 경로를 URI 참조로 인코딩한다")
    func sarifEncodesPathAsURIReference() throws {
        let diagnostic = Diagnostic(
            ruleIdentifier: "unused-symbol",
            severity: .warning,
            message: "unused",
            location: SourceLocation(path: "/Users/x/My Project/A#1.swift", line: 1, column: 1)
        )
        let output = try SARIFDiagnosticReporter().report([diagnostic], summary: summary)
        #expect(output.contains("My%20Project"))
        #expect(output.contains("A%231.swift"))
    }
}

@Suite("지표 JSON 의 억제 건수")
struct MetricsSuppressionTests {
    @Test("억제 건수를 JSON 에도 담는다")
    func jsonCarriesSuppressedCount() throws {
        // 텍스트에만 있으면 기계 소비자가 억제 사실을 알 수 없다.
        let output = try MetricsRenderer().renderJSON([], diagnostics: [], suppressedCount: 7)
        #expect(output.contains("\"suppressedCount\" : 7"))
    }
}

@Suite("한계를 나르는 형식")
struct LimitationReportingTests {
    private let limited = ReportSummary(
        command: "dead",
        subject: "symbol graph · 3 nodes",
        limitations: ["objective-c-sources: 2 file(s) are not analysed"]
    )
    private let quiet = ReportSummary(command: "dead", subject: "symbol graph · 3 nodes")

    @Test("텍스트는 요약 줄에 개수를 적고 뒤에 블록을 붙인다")
    func textCarriesLimitations() {
        // CI 로그가 실제로 보여 주는 형식이다. 여기 없으면 이 도구가 무엇을 보지 못했는지는
        // 아무 데도 없는 것과 같고, 게이트는 눈이 먼 채로 통과한다.
        let output = TextDiagnosticReporter().report([], summary: limited)
        #expect(output.contains("(1 limitation)"))
        #expect(output.contains("limitations:"))
        #expect(output.contains("  objective-c-sources: 2 file(s) are not analysed"))
    }

    @Test("알릴 것이 없으면 텍스트에 블록도 개수도 없다")
    func textStaysQuietWithoutLimitations() {
        let output = TextDiagnosticReporter().report([], summary: quiet)
        #expect(!output.contains("limitation"))
    }

    @Test("Xcode 형식은 위치 없는 note 로 싣는다")
    func xcodeCarriesLimitations() {
        // 발견이 아니므로 위치도 규칙 식별자도 붙이지 않는다. `note:` 는 이슈로 세지 않는다.
        let output = XcodeDiagnosticReporter().report([], summary: limited)
        #expect(output == "note: objective-c-sources: 2 file(s) are not analysed\n")
    }

    @Test("GitHub Actions 형식은 파일 없는 notice 로 싣는다")
    func githubActionsCarriesLimitations() {
        // 파일을 붙이지 않은 notice 는 특정 줄이 아니라 실행 요약에 달린다.
        let output = GitHubActionsDiagnosticReporter().report([], summary: limited)
        #expect(output.hasPrefix("::notice title=cartograph limitation::"))
        #expect(!output.contains("file="))
    }

    @Test("SARIF 는 발견이 아니라 실행 알림으로 싣는다")
    func sarifCarriesLimitationsAsNotifications() throws {
        // results 에 넣으면 코드 스캐닝이 발견으로 세어, 게이트를 통과했는데도 보안 탭에
        // 항목이 쌓인다.
        let output = try SARIFDiagnosticReporter().report([], summary: limited)
        let document = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let run = ((document?["runs"] as? [[String: Any]]) ?? []).first
        #expect((run?["results"] as? [Any])?.isEmpty == true)
        let invocations = run?["invocations"] as? [[String: Any]]
        let notifications = invocations?.first?["toolExecutionNotifications"] as? [[String: Any]]
        #expect(notifications?.count == 1)
        #expect((notifications?.first?["message"] as? [String: Any])?["text"] as? String
            == "objective-c-sources: 2 file(s) are not analysed")
    }

    @Test("알릴 것이 없으면 SARIF 에 invocations 키가 없다")
    func sarifStaysQuietWithoutLimitations() throws {
        let output = try SARIFDiagnosticReporter().report([], summary: quiet)
        #expect(!output.contains("invocations"))
    }

    @Test("checkstyle 은 한계를 나르지 않는다")
    func checkstyleIsLeftAlone() {
        // 파일 없는 자리가 없고, `<error>` 로 넣으면 소비자 쪽에서 발견 수가 늘어
        // 게이트의 뜻이 바뀐다. 담을 자리가 없으면 만들지 않는다.
        let output = CheckstyleDiagnosticReporter().report([], summary: limited)
        #expect(!output.contains("objective-c-sources"))
        #expect(!output.contains("<error"))
    }
}
