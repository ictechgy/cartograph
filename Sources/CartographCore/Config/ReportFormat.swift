/// 진단 결과(cycles/dead/rules/metrics)를 내보낼 형식.
public enum ReportFormat: String, Codable, Sendable, CaseIterable {
    /// 사람이 읽는 기본 형식.
    case text
    /// 기계 소비용 JSON.
    case json
    /// `path:line:col: warning: message` — Xcode 빌드 로그에 그대로 뜬다.
    case xcode
    /// Checkstyle XML. 대부분의 CI 가 이해한다.
    case checkstyle
    /// GitHub Actions 워크플로 명령(`::warning file=...`).
    case githubActions = "github-actions"
    /// SARIF 2.1.0. GitHub code scanning 에 업로드할 수 있다.
    case sarif
}

/// 그래프 자체를 내보낼 형식.
public enum GraphFormat: String, Codable, Sendable, CaseIterable {
    /// Graphviz DOT.
    case dot
    /// Mermaid flowchart. 마크다운에 그대로 붙일 수 있다.
    case mermaid
    /// 기계 소비용 JSON.
    case json
    /// 의존성이 없는 단일 HTML(외부 CDN 을 쓰지 않는다).
    case html
}
