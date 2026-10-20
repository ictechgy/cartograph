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
            // 작업 트리를 읽는 status 는 저장소가 정의한 콘텐츠 필터를 실행할 수 있다.
            // `-c` 로 끌 수 없는 필터 이름이 있으면 깨끗함을 증명할 수 없으므로 싣지 않는다.
            guard let neutralizing = try ChangedFiles.filterNeutralizationArguments(
                workingDirectory: projectPath, reference: "HEAD"
            ) else { return nil }
            // 서브모듈(gitlink)이 있으면 그 내부 상태를 서브모듈 git 을 띄우지 않고는 알 수 없다.
            // 작업 트리를 읽지 않는 `ls-files -s` 로 gitlink(mode 160000) 유무만 보고, 있으면
            // 깨끗함을 주장하지 않는다. 서브모듈이 있으면 `--revision` 으로 직접 주어야 한다.
            let tracked = try ChangedFiles.lines(
                of: ["ls-files", "-s", "-z", "--", "."], in: projectPath, reference: "HEAD",
                globalOptions: neutralizing)
            if tracked.contains(where: { $0.hasPrefix("160000 ") }) { return nil }
            // 경로 명세 `.` 은 `-C` 로 옮긴 프로젝트 디렉터리다. 저장소의 다른 곳의 변경은 이 분석과 무관하다.
            // status 는 `--no-ext-diff` 를 거부하므로 붙이지 않는다. 서브모듈 상태는 위에서 다뤘으니 무시한다.
            // 이름 변경 감지는 blob 을 읽는데 partial clone 에는 없을 수 있고 받아 오지도 않으므로 끈다.
            // 빈 결과인지만 보므로 의미는 같다. HEAD 트리 같은 객체가 빠져 있으면 status 가 실패해 nil 이 된다.
            let dirty = try ChangedFiles.lines(
                of: ["status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=all", "--no-renames",
                     "-z", "--", "."],
                in: projectPath, reference: "HEAD", globalOptions: neutralizing)
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
