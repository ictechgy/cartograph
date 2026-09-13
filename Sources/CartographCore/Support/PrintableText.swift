/// 저장소 소유자가 통제하는 문자열이 흘러 가는 출력의 문자를 가른다.
///
/// 진단의 경로·메시지·규칙 식별자와 외부 근거 문장은 전부 분석 대상 저장소가
/// 통제하는 값이다. 줄바꿈 한 개로 한 줄짜리 진단이 여러 줄로 위장하고(로그
/// 위조), ANSI ESC(U+001B)나 양방향 재정의(U+202E)는 터미널 화면을 바꾼다.
/// 제어(Cc)와 형식(Cf) 일반 범주를 통째로 뺀다 — 개별 문자를 허용 목록으로
/// 관리하면 유니코드가 늘 때마다 구멍이 난다.
///
/// 이 규칙은 한 곳에만 둔다. 출력 경로마다 조금씩 다른 필터를 두면 새 리포터가
/// 늘 때 하나만 빠지는 것이 아니라 규칙 자체가 갈라진다.
public enum PrintableText {
    /// 제어·형식 문자를 뺀다. 개행도 한 줄 출력의 위장 수단이므로 예외로 두지 않는다.
    ///
    /// 개행을 인코딩할 수 있는 형식(GitHub Actions 명령의 `%0A` 등)은
    /// `keepingLineBreaks: true` 로 탭·개행·복귀를 살린다. 살아남은 개행은
    /// 부르는 쪽이 자기 형식의 이스케이프로 바꿔야 한다 — 그래야 로그 스트림에
    /// 진짜 줄바꿈이 생기지 않는다.
    public static func printable(_ text: String, keepingLineBreaks: Bool = false) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if keepingLineBreaks, scalar == "\r" || scalar == "\n" || scalar == "\t" { return true }
            return scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format
        }))
    }
}
