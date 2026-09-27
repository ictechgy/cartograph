/// 순회 문서의 `revision` 을 git 에서 확인한다.
///
/// git 접근은 CLI 계층에만 둔다(`ChangedFiles` 와 같은 이유). HEAD 는 작업 트리가 그 커밋과 같을
/// 때만 분석한 소스의 신원이다. 고친 파일이 있는데 HEAD 를 실으면 isthmus 는 다른 분석과 revision 이
/// 같다는 이유로 낡지 않았다고 판단하게 된다. 그래서 분석 대상 경로가 깨끗할 때만 싣고, 아니면 뺀다.
enum GitRevision {
    /// 프로젝트 경로 아래에 커밋하지 않은 변경(추적되지 않는 파일 포함)이 없을 때의 HEAD 커밋 id.
    ///
    /// 저장소가 아니거나 git 이 실패하면 nil 이다. 그때는 revision 을 모르는 것이지 오류가 아니다.
    static func cleanHead(projectPath: String) -> String? {
        do {
            let head = try ChangedFiles.lines(
                of: ["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"], in: projectPath, reference: "HEAD")
            guard head.count == 1, let commit = head.first, isObjectID(commit) else { return nil }
            // 경로 명세 `.` 은 `-C` 로 옮긴 프로젝트 디렉터리다. 저장소의 다른 곳의 변경은 이 분석과 무관하다.
            let dirty = try ChangedFiles.lines(
                of: ["status", "--porcelain", "--untracked-files=normal", "-z", "--", "."],
                in: projectPath, reference: "HEAD")
            return dirty.isEmpty ? commit : nil
        } catch {
            // 저장소가 아니거나 HEAD 가 없는(첫 커밋 전) 경우다. revision 을 모른다고 두고 순회는 계속한다.
            return nil
        }
    }

    /// SHA-1(40자)·SHA-256(64자) 커밋 id 인지.
    static func isObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
