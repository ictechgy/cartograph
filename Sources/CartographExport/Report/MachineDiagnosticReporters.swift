import CartographCore
import Foundation

/// Xcode 빌드 로그가 인식하는 형식.
///
/// 빌드 페이즈 스크립트에서 그대로 출력하면 이슈 내비게이터에 뜬다.
/// 위치가 없는 진단은 파일 없는 경고로 내보낸다.
public struct XcodeDiagnosticReporter: DiagnosticReporting {
    public init() {}

    public func report(_ diagnostics: [Diagnostic], summary: ReportSummary) -> String {
        let lines = diagnostics.sorted().map { diagnostic -> String in
            let prefix = diagnostic.location.map { "\($0.path):\($0.line):\($0.column): " } ?? ""
            return "\(prefix)\(diagnostic.severity.rawValue): \(diagnostic.message) (\(diagnostic.ruleIdentifier))"
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}

/// GitHub Actions 워크플로 명령 형식.
///
/// 변경된 줄에 주석이 달리고 요약 화면에 집계된다.
public struct GitHubActionsDiagnosticReporter: DiagnosticReporting {
    public init() {}

    public func report(_ diagnostics: [Diagnostic], summary: ReportSummary) -> String {
        let lines = diagnostics.sorted().map { diagnostic -> String in
            var properties = ["title=cartograph \(diagnostic.ruleIdentifier)"]
            if let location = diagnostic.location {
                properties.insert("file=\(location.path)", at: 0)
                properties.insert("line=\(location.line)", at: 1)
                properties.insert("col=\(location.column)", at: 2)
            }
            return "::\(level(for: diagnostic.severity)) \(properties.joined(separator: ","))"
                + "::\(escape(diagnostic.message))"
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

    /// 워크플로 명령은 개행과 콜론을 퍼센트 인코딩으로 받는다.
    private func escape(_ message: String) -> String {
        message
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
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
            let diagnostics: [Diagnostic]
        }
        let document = Document(
            tool: Cartograph.toolName,
            version: Cartograph.version,
            command: summary.command,
            subject: summary.subject,
            suppressedCount: summary.suppressedCount,
            diagnostics: diagnostics.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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
                    results: sorted.map(Self.result(for:))
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
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
                            artifactLocation: .init(uri: location.path),
                            region: .init(startLine: max(1, location.line), startColumn: max(1, location.column))
                        )
                    )
                ]
            } ?? []
        )
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
