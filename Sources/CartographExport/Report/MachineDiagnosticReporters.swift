import CartographCore
import Foundation

/// Xcode 빌드 로그가 인식하는 형식.
///
/// 빌드 페이즈 스크립트에서 그대로 출력하면 이슈 내비게이터에 뜬다.
/// 위치가 없는 진단은 파일 없는 경고로 내보낸다.
public struct XcodeDiagnosticReporter: DiagnosticReporting {
    public init() {}

    public func report(_ diagnostics: [Diagnostic], summary: ReportSummary) -> String {
        var lines = diagnostics.sorted().map { diagnostic -> String in
            let prefix = diagnostic.location.map { "\($0.path):\($0.line):\($0.column): " } ?? ""
            return "\(prefix)\(diagnostic.severity.rawValue): \(diagnostic.message) (\(diagnostic.ruleIdentifier))"
        }
        // 한계는 발견이 아니므로 위치도 규칙 식별자도 붙이지 않는다. `note:` 는 Xcode 가
        // 이슈로 세지 않는 단계라, 게이트의 종료 코드나 발견 수를 건드리지 않는다.
        // 식별자는 이미 문장의 접두사로 들어 있다.
        lines += (summary.limitations ?? []).map { "note: \($0)" }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}

/// GitHub Actions 워크플로 명령 형식.
///
/// 변경된 줄에 주석이 달리고 요약 화면에 집계된다.
public struct GitHubActionsDiagnosticReporter: DiagnosticReporting {
    public init() {}

    public func report(_ diagnostics: [Diagnostic], summary: ReportSummary) -> String {
        var lines = diagnostics.sorted().map { diagnostic -> String in
            var properties = ["title=\(escapeProperty("cartograph \(diagnostic.ruleIdentifier)"))"]
            if let location = diagnostic.location {
                properties.insert("file=\(escapeProperty(location.path))", at: 0)
                properties.insert("line=\(location.line)", at: 1)
                properties.insert("col=\(location.column)", at: 2)
            }
            return "::\(level(for: diagnostic.severity)) \(properties.joined(separator: ","))"
                + "::\(escape(diagnostic.message))"
        }
        // 파일을 붙이지 않은 `::notice` 는 특정 줄이 아니라 실행 요약에 달린다.
        // 한계는 어느 한 줄에 대한 말이 아니므로 그 자리가 맞다.
        lines += (summary.limitations ?? []).map { limitation in
            "::notice title=\(escapeProperty("cartograph limitation"))::\(escape(limitation))"
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private func level(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: "error"
        case .warning: "warning"
        case .info: "notice"
        }
    }

    /// 제어 문자(Cc)와 형식 문자(Cf)를 걸러 터미널과 로그 스푸핑을 방지한다.
    ///
    /// 개행과 복귀 문자는 워크플로 명령 이스케이프(%0A, %0D)로 변환할 대상이므로 유지하고,
    /// ANSI ESC 시퀀스(\u{001B})나 양방향 재정의(U+202E) 등 악성 입력이 유발할 수 있는
    /// 화면 조작 문자는 제거한다.
    private func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar == "\r" || scalar == "\n" || scalar == "\t" { return true }
            return scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format
        }))
    }

    /// 메시지 본문에 필요한 이스케이프. 퍼센트를 먼저 바꿔야 이중 인코딩을 피한다.
    private func escape(_ message: String) -> String {
        sanitize(message)
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// 속성 값에 필요한 이스케이프.
    ///
    /// 속성은 쉼표로 나뉘고 이름과 값은 등호로 갈리므로, 값 안의 쉼표와 콜론까지
    /// 인코딩해야 한다. 경로에 쉼표가 있으면 GitHub 이 주석을 잘못 잘라 버린다.
    private func escapeProperty(_ value: String) -> String {
        escape(value)
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: ":", with: "%3A")
    }
}

/// Checkstyle XML 형식. 대부분의 CI 가 이 형식을 이해한다.
public struct CheckstyleDiagnosticReporter: DiagnosticReporting {
    public init() {}

    public func report(_ diagnostics: [Diagnostic], summary: ReportSummary) -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<checkstyle version=\"4.3\">"]
        let grouped = Dictionary(grouping: diagnostics.sorted()) { $0.location?.path ?? "" }

        for path in grouped.keys.sorted() {
            lines.append("  <file name=\"\(XMLEscaping.escape(path))\">")
            for diagnostic in grouped[path] ?? [] {
                let attributes = [
                    "line=\"\(diagnostic.location?.line ?? 0)\"",
                    "column=\"\(diagnostic.location?.column ?? 0)\"",
                    "severity=\"\(diagnostic.severity.rawValue)\"",
                    "message=\"\(XMLEscaping.escape(diagnostic.message))\"",
                    "source=\"cartograph.\(XMLEscaping.escape(diagnostic.ruleIdentifier))\"",
                ]
                lines.append("    <error \(attributes.joined(separator: " "))/>")
            }
            lines.append("  </file>")
        }
        lines.append("</checkstyle>")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// 기계 소비용 JSON 형식.
public struct JSONDiagnosticReporter: DiagnosticReporting {
    public init() {}

    public func report(_ diagnostics: [Diagnostic], summary: ReportSummary) throws -> String {
        struct Document: Encodable {
            let tool: String
            let version: String
            let command: String
            let subject: String
            let suppressedCount: Int
            /// 값이 없으면 키가 빠진다. `query` 와 같은 계약이다.
            let limitations: [String]?
            let diagnostics: [Diagnostic]
        }
        let document = Document(
            tool: Cartograph.toolName,
            version: Cartograph.version,
            command: summary.command,
            subject: summary.subject,
            suppressedCount: summary.suppressedCount,
            limitations: summary.limitations,
            diagnostics: diagnostics.sorted()
        )
        let encoder = JSONEncoder.cartographDefault()
        return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
    }
}

/// SARIF 2.1.0 형식.
///
/// GitHub code scanning 에 업로드하면 PR 에 인라인 주석이 달리고
/// 보안 탭에서 추이를 볼 수 있다. Periphery 가 끝내 지원하지 않은 형식이다.
public struct SARIFDiagnosticReporter: DiagnosticReporting {
    public static let schemaURL =
        "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json"

    public init() {}

    public func report(_ diagnostics: [Diagnostic], summary: ReportSummary) throws -> String {
        let sorted = diagnostics.sorted()
        let document = SARIFDocument(
            schema: Self.schemaURL,
            version: "2.1.0",
            runs: [
                SARIFDocument.Run(
                    tool: .init(
                        driver: .init(
                            name: Cartograph.toolName,
                            version: Cartograph.version,
                            informationUri: "https://github.com/ictechgy/cartograph",
                            rules: Self.rules(in: sorted)
                        )
                    ),
                    results: sorted.map(Self.result(for:)),
                    invocations: Self.invocations(for: summary.limitations)
                )
            ]
        )
        let encoder = JSONEncoder.cartographDefault()
        return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
    }

    /// 한계를 담는 자리.
    ///
    /// `results` 에 넣으면 코드 스캐닝이 발견으로 세어 경보 수가 늘고, 게이트를 통과했는데도
    /// 보안 탭에 항목이 쌓인다. 한계는 "이 실행이 무엇을 보지 못했는가" 라 실행에 대한
    /// 알림이고, SARIF 에는 그 자리가 따로 있다.
    private static func invocations(for limitations: [String]?) -> [SARIFDocument.Invocation]? {
        guard let limitations, !limitations.isEmpty else { return nil }
        return [
            SARIFDocument.Invocation(
                executionSuccessful: true,
                toolExecutionNotifications: limitations.map {
                    SARIFDocument.Notification(level: "note", message: .init(text: $0))
                }
            )
        ]
    }

    private static func rules(in diagnostics: [Diagnostic]) -> [SARIFDocument.Rule] {
        Set(diagnostics.map(\.ruleIdentifier)).sorted().map { SARIFDocument.Rule(id: $0) }
    }

    private static func result(for diagnostic: Diagnostic) -> SARIFDocument.Result {
        SARIFDocument.Result(
            ruleId: diagnostic.ruleIdentifier,
            level: level(for: diagnostic.severity),
            message: .init(text: diagnostic.message),
            locations: diagnostic.location.map { location in
                [
                    SARIFDocument.Location(
                        physicalLocation: .init(
                            artifactLocation: .init(uri: uriReference(for: location.path)),
                            region: .init(startLine: max(1, location.line), startColumn: max(1, location.column))
                        )
                    )
                ]
            } ?? []
        )
    }

    /// SARIF 의 artifactLocation.uri 는 RFC 3986 URI 참조여야 한다.
    ///
    /// 경로를 그대로 넣으면 공백이나 `#` 이 든 경로에서 문서가 규격을 벗어나고,
    /// GitHub code scanning 업로드가 거부될 수 있다.
    private static func uriReference(for path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("#")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// SARIF 는 warning/error/note 만 인정한다.
    private static func level(for severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: "error"
        case .warning: "warning"
        case .info: "note"
        }
    }
}

/// SARIF 문서 스키마 중 실제로 쓰는 부분만 정의한다.
struct SARIFDocument: Encodable {
    let schema: String
    let version: String
    let runs: [Run]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version
        case runs
    }

    struct Run: Encodable {
        let tool: Tool
        let results: [Result]
        /// 값이 없으면 키가 빠진다. 알릴 것이 없으면 조용해야 한다.
        let invocations: [Invocation]?
    }

    /// 이 실행 자체에 대한 알림. 발견이 아니다.
    struct Invocation: Encodable {
        let executionSuccessful: Bool
        let toolExecutionNotifications: [Notification]
    }

    struct Notification: Encodable {
        let level: String
        let message: Message
    }

    struct Tool: Encodable {
        let driver: Driver
    }

    struct Driver: Encodable {
        let name: String
        let version: String
        let informationUri: String
        let rules: [Rule]
    }

    struct Rule: Encodable {
        let id: String
    }

    struct Result: Encodable {
        let ruleId: String
        let level: String
        let message: Message
        let locations: [Location]
    }

    struct Message: Encodable {
        let text: String
    }

    struct Location: Encodable {
        let physicalLocation: PhysicalLocation
    }

    struct PhysicalLocation: Encodable {
        let artifactLocation: ArtifactLocation
        let region: Region
    }

    struct ArtifactLocation: Encodable {
        let uri: String
    }

    struct Region: Encodable {
        let startLine: Int
        let startColumn: Int
    }
}
