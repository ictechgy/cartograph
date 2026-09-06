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
    /// 이 실행의 결과를 그대로 믿으면 안 되는 이유. 요약 줄에 함께 찍는다.
    ///
    /// CI 로그가 보여 주는 것은 텍스트 요약 한 줄이라, 거기 나타나지 않는 사실은 없는 것과
    /// 같다. 아무것도 분석하지 않은 실행이 평범한 초록으로 보이면 이 도구가 막으려는 바로
    /// 그 상태가 된다. `limitations` 도 같은 이유로 text·xcode·github-actions·SARIF 가
    /// 함께 렌더링한다. checkstyle 만 예외다 — 파일 없는 자리가 없고, `<error>` 로 넣으면
    /// 소비자 쪽에서 발견 수가 늘어 게이트의 뜻이 바뀐다.
    public let caveat: String?

    public init(
        command: String,
        subject: String,
        suppressedCount: Int = 0,
        limitations: [String]? = nil,
        caveat: String? = nil
    ) {
        self.command = command
        self.subject = subject
        self.suppressedCount = suppressedCount
        self.limitations = limitations
        self.caveat = caveat
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
