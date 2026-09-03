import CartographCore
import Foundation

/// 주어진 기준점 이후 바뀐 파일을 git 에게 물어본다.
///
/// git 접근은 CLI 계층에만 둔다. 도메인과 분석 계층이 저장소가 git 인지조차
/// 몰라야 인덱스 스토어도 저장소도 없이 테스트할 수 있다.
enum ChangedFiles {
    /// 기준점 이후 바뀐 파일들의 절대 경로.
    ///
    /// git 이 돌려주는 저장소 루트는 심볼릭 링크를 푼 경로다. macOS 에서
    /// `/var` 는 `/private/var` 의 링크이므로, 호출자가 준 경로와 표기가 다를 수
    /// 있다. 그래서 여기서 나온 경로는 정규화된 것으로 다루어야 하고,
    /// `ReportScope` 가 비교 전에 양쪽을 같은 방식으로 정규화한다.
    ///
    /// 세 가지를 합친다. 하나라도 빠지면 그 파일의 발견이 조용히 숨겨지고,
    /// 사용자는 `--strict` 에서 "문제 없음"을 보게 된다. 가장 비싼 실패 방향이다.
    /// - 기준점과 HEAD 사이의 커밋된 변경
    /// - 아직 커밋하지 않은 추적 파일의 변경(스테이지 여부 무관)
    /// - 추적되지 않는 새 파일
    static func since(_ reference: String, workingDirectory: String) throws -> Set<String> {
        let root = try lines(
            of: ["rev-parse", "--show-toplevel"],
            in: workingDirectory,
            reference: reference
        ).first
        guard let root else {
            throw CartographError.changedFilesUnavailable(
                reference: reference,
                reason: "not a git repository"
            )
        }

        // `<ref>...HEAD` 는 공통 조상 이후만 본다. `<ref>..HEAD` 를 쓰면 기준
        // 브랜치가 앞서 나갔을 때 남의 변경까지 이번 것으로 보고한다.
        let committed = try lines(
            of: ["diff", "--name-only", "--diff-filter=d", "-z", "\(reference)...HEAD"],
            in: workingDirectory,
            reference: reference
        )
        // 작업 트리와 HEAD 의 차이. 추적 파일을 고치고 커밋하지 않은 경우가
        // 미커밋 변경의 가장 흔한 형태인데 위 비교로는 잡히지 않는다.
        let uncommitted = try lines(
            of: ["diff", "--name-only", "--diff-filter=d", "-z", "HEAD"],
            in: workingDirectory,
            reference: reference
        )
        // `--full-name` 이 없으면 하위 디렉터리에서 실행할 때 그 디렉터리 기준
        // 상대 경로가 나와, 저장소 루트에 이어 붙이면 엉뚱한 경로가 된다.
        let untracked = try lines(
            of: ["ls-files", "--others", "--exclude-standard", "--full-name", "-z"],
            in: workingDirectory,
            reference: reference
        )

        return Set((committed + uncommitted + untracked).map { (root as NSString).appendingPathComponent($0) })
    }

    /// git 을 한 번 실행하고 출력을 경로 목록으로 나눈다.
    ///
    /// `-z` 를 준 명령은 NUL 로 구분된다. 기본 출력은 `core.quotePath` 때문에
    /// 비ASCII 이름을 따옴표로 감싸고 8진수로 이스케이프해, 실제 경로와 절대
    /// 일치하지 않는 문자열이 나온다. 한국어 파일명에서 바로 재현된다.
    private static func lines(
        of arguments: [String],
        in workingDirectory: String,
        reference: String
    ) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workingDirectory] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw CartographError.changedFilesUnavailable(reference: reference, reason: "\(error)")
        }
        // 파이프를 먼저 비운 뒤 기다린다. 순서를 바꾸면 출력이 큰 저장소에서 멈춘다.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // git 이 말한 이유를 그대로 전한다. 하드코딩한 문장으로 덮으면 잠금
            // 문제나 권한 문제까지 "없는 리비전"으로 오진하게 된다.
            let reported = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = reported.isEmpty ? "git exited with \(process.terminationStatus)" : reported
            throw CartographError.changedFilesUnavailable(
                reference: reference,
                reason: reason + " — in CI, check out with full history (fetch-depth: 0)"
            )
        }

        let separator: Character = arguments.contains("-z") ? "\0" : "\n"
        return String(decoding: data, as: UTF8.self)
            .split(separator: separator)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
