import CartographCore

/// 보고할 발견의 범위를 좁힌다.
///
/// 기존 저장소에 도구를 처음 넣을 때 가장 큰 장벽은 전면 보고의 소음이다.
/// 베이스라인이 "오늘 있는 문제를 기록하고 새 것만 실패시키는" CI 래칫이라면,
/// 이 타입은 "이번 변경이 건드린 자리만 보는" PR 범위다. 둘은 함께 쓸 수 있다.
///
/// 분석 자체는 좁히지 않는다. 그래프는 프로젝트 전체를 봐야 도달성이 맞고,
/// 좁힌 그래프에서 나온 미사용 판정은 그냥 틀린 값이다. 좁히는 것은 보고뿐이다.
public struct ReportScope: Sendable, Equatable {
    /// 보고 대상 파일의 정규화된 절대 경로.
    public let files: Set<String>

    /// 키가 없는 파일은 전체를 남긴다. 빈 배열은 현재 파일에 선택된 줄이 없다는 뜻이다.
    public let changedLines: [String: [ClosedRange<Int>]]

    /// 기존 파일 단위 생성자와 그 함수 참조의 타입을 유지한다.
    public init(files: Set<String>) {
        self.init(files: files, changedLines: [:])
    }

    /// 줄 범위는 현재 소스의 1-based 위치다. nil 위치나 알 수 없는 줄은 숨기지 않는다.
    public init(files: Set<String>, changedLines: [String: [ClosedRange<Int>]]) {
        self.files = Set(files.map(Self.normalized))
        self.changedLines = changedLines.reduce(into: [:]) { result, entry in
            result[Self.normalized(entry.key), default: []].append(contentsOf: entry.value)
        }
    }

    /// 양쪽을 같은 방식으로 정규화한다.
    ///
    /// macOS 에서 `/tmp` 와 `/private/tmp` 는 같은 곳을 가리키고, git 이 주는 루트는
    /// 심볼릭 링크를 푼 경로다. 한쪽만 정규화하면 단 하나도 일치하지 않아 발견이
    /// 전부 사라지고, 사용자는 `--strict` 에서 "문제 없음"을 보게 된다.
    static func normalized(_ path: String) -> String {
        LocalFileSystem.canonicalPath(path)
    }

    /// 이 발견을 보고할지 판단한다.
    ///
    /// 위치가 없는 발견은 남긴다. 어느 파일의 것인지 알 수 없다고 해서 숨기면,
    /// 사용자는 무엇이 걸러졌는지도 모른 채 "문제 없음"을 보게 된다.
    public func includes(_ diagnostic: Diagnostic) -> Bool {
        guard let location = diagnostic.location else { return true }
        let path = Self.normalized(location.path)
        guard files.contains(path) else { return false }
        guard location.line > 0, let ranges = changedLines[path] else { return true }
        return ranges.contains { $0.contains(location.line) }
    }

    /// 범위 안의 발견만 남긴다.
    public func filtering(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        diagnostics.filter(includes)
    }
}
