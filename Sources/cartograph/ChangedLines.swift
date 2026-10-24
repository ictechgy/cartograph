import CartographCore
import CartographKit
import Foundation

/// 커밋별 줄 번호를 합치지 않고 merge-base 와 현재 파일을 직접 비교한다.
/// 중간 커밋과 staged 변경 뒤에 줄이 삽입되어도 진단의 현재 좌표와 맞아야 한다.
enum ChangedLines {
    struct Selection {
        let scope: ReportScope
        let notes: [String]
    }

    private struct Repository {
        let root: String
        let base: String
        let global: [String]
    }

    private static let diffOptions = [
        "diff", "--no-relative", "--no-ext-diff", "--no-textconv", "--no-renames",
        "--ignore-submodules=dirty", "--no-color", "--diff-algorithm=myers", "--no-indent-heuristic",
        "--inter-hunk-context=0",
    ]

    private static func repository(_ reference: String, workingDirectory: String) throws -> Repository {
        let data = try ChangedFiles.output(of: ["rev-parse", "--show-toplevel"],
                                          in: workingDirectory, reference: reference)
        // 마지막 구분자 하나만 떼어 내야 루트 이름 안의 공백·개행도 보존한다.
        guard let output = String(data: data, encoding: .utf8), output.hasSuffix("\n"), output.count > 1 else {
            throw unavailable(reference, "--since-lines requires a UTF-8 repository root")
        }
        let root = String(output.dropLast())
        guard let neutralizing = try ChangedFiles.filterNeutralizationArguments(
                workingDirectory: root, reference: reference) else {
            throw unavailable(reference,
                              "repository or safely disabled content filters unavailable; use a fresh checkout")
        }
        let global = neutralizing + ["--literal-pathspecs", "-c", "diff.autoRefreshIndex=false"]
        let commit = try ChangedFiles.lines(of: ["rev-parse", "--verify", "--end-of-options", "\(reference)^{commit}"],
                                           in: root, reference: reference).first
        guard let commit else { throw unavailable(reference, "revision has no commit") }
        let bases = try ChangedFiles.lines(of: ["merge-base", "--all", commit, "HEAD"],
                                          in: root, reference: reference)
        guard bases.count == 1 else {
            throw unavailable(reference, "--since-lines requires one unambiguous merge-base; use file-level --since")
        }
        let conflicts = try ChangedFiles.output(of: ["ls-files", "--unmerged", "-z"],
                                               in: root, reference: reference, globalOptions: global)
        guard conflicts.isEmpty else {
            throw unavailable(reference,
                              "--since-lines cannot map unmerged files; resolve conflicts or use file-level --since")
        }
        return Repository(root: root, base: bases[0], global: global)
    }

    static func since(_ reference: String, workingDirectory: String) throws -> Selection {
        let repository = try repository(reference, workingDirectory: workingDirectory)
        let (root, base, global) = (repository.root, repository.base, repository.global)
        let tracked = try paths(diffOptions + ["--name-only", "--diff-filter=d", "-z", base, "--"],
                                root: root, reference: reference, global: global)
        let untracked = try paths(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"],
                                  root: root, reference: reference, global: global)
        var ranges: [String: [ClosedRange<Int>]] = [:]
        var wholeFiles = Set(untracked.map {
            LocalFileSystem.canonicalPath((root as NSString).appendingPathComponent($0))
        })
        var notes: [String] = []
        for path in Set(tracked).subtracting(untracked).sorted() {
            let data = try ChangedFiles.output(
                of: diffOptions + ["--patch", "--unified=0", "--no-prefix", "--submodule=short",
                    "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= ",
                    base, "--", path],
                in: root, reference: reference, globalOptions: global)
            let absolute = (root as NSString).appendingPathComponent(path)
            if let selected = Self.ranges(in: data) {
                ranges[absolute] = selected
            } else {
                wholeFiles.insert(LocalFileSystem.canonicalPath(absolute))
                notes.append("since-lines: whole-file fallback for \(String(reflecting: path)); "
                    + "the diff has no reliable textual current-line mapping")
            }
        }
        let files = Set((tracked + untracked).map { (root as NSString).appendingPathComponent($0) })
        // 같은 물리 파일의 symlink 별칭 하나라도 전체 파일이면 더 좁은 별칭의 줄 범위로 덮지 않는다.
        ranges = ranges.filter { !wholeFiles.contains(LocalFileSystem.canonicalPath($0.key)) }
        return Selection(scope: ReportScope(files: files, changedLines: ranges), notes: notes)
    }

    private static func paths(_ arguments: [String], root: String, reference: String,
                              global: [String]) throws -> [String] {
        let data = try ChangedFiles.output(of: arguments, in: root, reference: reference, globalOptions: global)
        guard let text = String(data: data, encoding: .utf8) else {
            throw unavailable(reference, "--since-lines requires UTF-8 paths; use file-level --since")
        }
        return text.split(separator: "\0").map(String.init)
    }

    /// nil 이면 줄을 확정할 수 없어 파일 전체를 남긴다. 삭제만 있는 hunk 는 빈 범위다.
    static func ranges(in data: Data) -> [ClosedRange<Int>]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // symlink/gitlink 의 patch 좌표는 분석 대상 소스의 좌표가 아니다.
        if lines.contains(where: { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch"
            || $0.hasSuffix(" 120000") || $0.hasSuffix(" 160000") }) { return nil }
        var result: [ClosedRange<Int>] = []
        var sawHunk = false
        for line in lines where line.hasPrefix("@@") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count >= 4, parts[0] == "@@", parts[1].hasPrefix("-"),
                  parts[2].hasPrefix("+"), parts[3] == "@@",
                  let old = position(parts[1]), let current = position(parts[2]),
                  old.start > 0 || old.count == 0,
                  current.start > 0 || current.count == 0 else { return nil }
            sawHunk = true
            if current.count > 0 {
                guard current.start <= Int.max - (current.count - 1) else { return nil }
                result.append(current.start...(current.start + current.count - 1))
            }
        }
        return sawHunk ? result : nil
    }

    private static func position(_ field: Substring) -> (start: Int, count: Int)? {
        let values = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(values.count), let start = Int(values[0]), start >= 0 else { return nil }
        let count = values.count == 1 ? 1 : Int(values[1])
        guard let count, count >= 0 else { return nil }
        return (start, count)
    }

    private static func unavailable(_ reference: String, _ reason: String) -> CartographError {
        .changedFilesUnavailable(reference: reference, reason: reason)
    }
}
