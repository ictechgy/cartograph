import CartographCore

/// 리포트 머리말에 함께 실리는 요약 정보.
public struct ReportSummary: Sendable, Equatable {
    /// 실행한 명령 이름. 예: `cycles`, `dead`.
    public let command: String
    /// 분석 대상 설명. 예: `module graph · 12 nodes · 30 edges`.
    public let subject: String
    /// 베이스라인으로 걸러 낸 진단 수.
    public let suppressedCount: Int
    /// 이 분석이 보지 못한 채널. `dead` 처럼 판정이 한계에 걸리는 명령만 싣는다.
    ///
    /// `query` 와 같은 이유다. 에이전트는 `dead --report-format json` 목록에서 출발해 삭제로
    /// 가는데, 그 목록에 한계가 없으면 Objective-C 소스나 외부 보존 근거 파일의 존재를
    /// 알 길이 없다. nil 이면 리포터가 키를 만들지 않는다.
    public let limitations: [String]?

    public init(command: String, subject: String, suppressedCount: Int = 0, limitations: [String]? = nil) {
        self.command = command
        self.subject = subject
        self.suppressedCount = suppressedCount
        self.limitations = limitations
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
