/// 소스 주석으로 도구에 지시하는 명령.
///
/// 정적 분석이 절대 알 수 없는 사용(리플렉션, 문자열 기반 DI, 외부 도구가
/// 호출하는 심볼)은 결국 사람이 알려 주는 수밖에 없다. 설정 파일에 USR 을
/// 나열하는 것보다 코드 옆에 적는 편이 유지보수가 쉽다.
public enum CommentCommand: String, Sendable, CaseIterable {
    /// 바로 아래 선언과 그 하위를 분석에서 제외한다.
    case ignore = "cartograph:ignore"
    /// 파일 전체를 분석에서 제외한다.
    case ignoreAll = "cartograph:ignore:all"

    /// 주석 한 줄에서 명령을 찾는다.
    ///
    /// 더 구체적인 명령(`ignore:all`)을 먼저 확인한다. 그렇지 않으면
    /// `ignore` 가 항상 먼저 걸려 파일 단위 지시가 무시된다.
    public static func parse(comment: String) -> CommentCommand? {
        let normalized = comment.trimmingCharacters(in: .whitespaces)
        if normalized.contains(CommentCommand.ignoreAll.rawValue) { return .ignoreAll }
        if normalized.contains(CommentCommand.ignore.rawValue) { return .ignore }
        return nil
    }
}
