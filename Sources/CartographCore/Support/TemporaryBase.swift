import Foundation

/// 도구가 소유한 임시 파일(구문 캐시, 인덱스 판독기 DB)의 기준 디렉터리.
///
/// `NSTemporaryDirectory()` 는 macOS 에서 `TMPDIR` 환경 변수를 무시하고
/// `confstr(DARWIN_USER_TEMP_DIR)` 의 값을 돌려준다. 대개 둘은 같은 곳이지만,
/// 사용자 임시 디렉터리를 가려 둔 실행기 아래에서는 그 경로가 아예 열려 있지
/// 않다. POSIX 관례인 `TMPDIR` 를 먼저 보면 그런 환경에서도 캐시가 정해진
/// 한 자리에 모인다. 구문 캐시와 인덱스 DB 가 서로 다른 근원을 쓰면 같은
/// 실행에서 둘이 갈라져 앉는다.
///
/// 보통의 macOS 에서 `TMPDIR` 은 `NSTemporaryDirectory()` 와 같은 경로이므로
/// 이 우선순위는 아무것도 옮기지 않는다.
public enum TemporaryBase {
    public static func directory() -> String {
        let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"]
        if let tmpdir, !tmpdir.isEmpty {
            return tmpdir.hasSuffix("/") ? String(tmpdir.dropLast()) : tmpdir
        }
        return NSTemporaryDirectory()
    }
}
