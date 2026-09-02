import CartographCore

/// 리포트 머리말에 함께 실리는 요약 정보.
public struct ReportSummary: Sendable, Equatable {
    /// 실행한 명령 이름. 예: `cycles`, `dead`.
    public let command: String
    /// 분석 대상 설명. 예: `module graph · 12 nodes · 30 edges`.
    public let subject: String
    /// 베이스라인으로 걸러 낸 진단 수.
    public let suppressedCount: Int

    public init(command: String, subject: String, suppressedCount: Int = 0) {
        self.command = command
        self.subject = subject
        self.suppressedCount = suppressedCount
    }
}

/// 진단 목록을 출력 형식으로 바꾼다.
public protocol DiagnosticReporting: Sendable {
    func report(_ diagnostics: [Diagnostic], summary: ReportSummary) throws -> String
}

public enum DiagnosticReporterFactory {
    public static func make(_ format: ReportFormat) -> any DiagnosticReporting {
        switch format {
        case .text: TextDiagnosticReporter()
        case .json: JSONDiagnosticReporter()
        case .xcode: XcodeDiagnosticReporter()
        case .checkstyle: CheckstyleDiagnosticReporter()
        case .githubActions: GitHubActionsDiagnosticReporter()
        case .sarif: SARIFDiagnosticReporter()
        }
    }
}

/// XML 특수문자 이스케이프. Checkstyle 리포터가 쓴다.
enum XMLEscaping {
    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}
