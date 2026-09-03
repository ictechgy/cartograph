import CartographCore
import Foundation

/// 주어진 기준점 이후 바뀐 파일을 git 에게 물어본다.
///
/// git 접근은 CLI 계층에만 둔다. 도메인과 분석 계층이 저장소가 git 인지조차
/// 몰라야 인덱스 스토어도 저장소도 없이 테스트할 수 있다.
enum ChangedFiles {
    /// 기준점 이후 바뀐 파일들의 절대 경로.
    ///
    /// 추적되지 않는 파일도 포함한다. 새로 만든 파일이야말로 이번 변경의 핵심인데
    /// `git diff` 는 그것을 보여 주지 않는다.
    static func since(_ reference: String, workingDirectory: String) throws -> Set<String> {
        let root = try run(
            ["rev-parse", "--show-toplevel"],
            in: workingDirectory,
            reference: reference,
            failureHint: "not a git repository"
        )
        guard let root = root.first else {
            throw CartographError.changedFilesUnavailable(
                reference: reference,
                reason: "not a git repository"
            )
        }

        // `<ref>...HEAD` 는 공통 조상 이후의 변경만 본다. `<ref>..HEAD` 를 쓰면
        // 기준 브랜치가 앞서 나갔을 때 남의 변경까지 이번 것으로 보고한다.
        let changed = try run(
            ["diff", "--name-only", "--diff-filter=d", "\(reference)...HEAD"],
            in: workingDirectory,
            reference: reference,
            failureHint: "unknown revision — in CI, check out with full history (fetch-depth: 0)"
        )
        let untracked = try run(
            ["ls-files", "--others", "--exclude-standard"],
            in: workingDirectory,
            reference: reference,
            failureHint: "could not list untracked files"
        )

        return Set((changed + untracked).map { (root as NSString).appendingPathComponent($0) })
    }

    /// git 을 한 번 실행하고 줄 단위로 나눈 출력을 준다.
    private static func run(
        _ arguments: [String],
        in workingDirectory: String,
        reference: String,
        failureHint: String
    ) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workingDirectory] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CartographError.changedFilesUnavailable(reference: reference, reason: "\(error)")
        }
        // 파이프를 먼저 비운 뒤 기다린다. 순서를 바꾸면 출력이 큰 저장소에서 멈춘다.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CartographError.changedFilesUnavailable(reference: reference, reason: failureHint)
        }

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
