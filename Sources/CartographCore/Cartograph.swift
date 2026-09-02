/// Cartograph 도구 전역 상수.
///
/// 버전 문자열은 CLI `--version`, 리포트 메타데이터, 베이스라인 파일 헤더에서
/// 공통으로 사용되므로 한 곳에서만 정의한다.
public enum Cartograph {
    /// 배포 버전(SemVer).
    public static let version = "0.2.0"

    /// 리포트/설정 파일에 기록되는 도구 식별자.
    public static let toolName = "cartograph"

    /// 기본 설정 파일 이름. 프로젝트 루트에서 이 이름을 먼저 찾는다.
    public static let defaultConfigurationFileName = ".cartograph.yml"

    /// 기본 베이스라인 파일 이름.
    public static let defaultBaselineFileName = ".cartograph-baseline.json"
}
