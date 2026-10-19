import CartographCore
import Foundation

/// 주어진 기준점 이후 바뀐 파일을 git 에게 물어본다.
///
/// git 접근은 CLI 계층에만 둔다. 도메인과 분석 계층이 저장소가 git 인지조차
/// 몰라야 인덱스 스토어도 저장소도 없이 테스트할 수 있다.
enum ChangedFiles {
    /// 분석 대상 저장소에서 git 을 실행할 때 항상 붙이는 전역 인자.
    ///
    /// 분석 대상 저장소의 `.git` 은 공격자가 고른 것일 수 있다(템플릿 배포처럼
    /// `.git` 이 통째로 오는 저장소). 읽기 전용 조회가 저장소가 정의한 명령을
    /// 실행하지 않도록 막는다.
    /// - `--no-optional-locks`: 부수적 인덱스 갱신이 분석 대상에 자물쇠를 채우지 않게 한다.
    /// - `core.fsmonitor=false`: 인덱스 갱신 시 저장소가 정의한 fsmonitor 명령을 실행하지 않게 한다.
    /// - `log.showSignature=false`: 로그 계열이 서명 검증 프로그램(`gpg.program` 등)을 띄우지 않게 한다.
    private static let safeGlobalArguments = [
        "--no-optional-locks",
        "-c", "core.fsmonitor=false",
        "-c", "log.showSignature=false",
    ]

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
    /// - `includingDeleted` 가 true 면 삭제된 경로와 이름 변경의 양쪽 경로도 포함한다.
    static func since(
        _ reference: String,
        workingDirectory: String,
        includingDeleted: Bool = false
    ) throws -> Set<String> {
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

        // 작업 트리를 읽는 호출은 저장소가 정의한 콘텐츠 필터를 실행할 수 있다.
        // 먼저 필터 드라이버를 무력화할 인자를 모은다. `-c` 로 끌 수 없는 이름이
        // 있으면(이름에 `=` 포함) 깨끗하게 막을 수 없으므로 fail-closed 로 멈춘다.
        guard let neutralizing = try filterNeutralizationArguments(
            workingDirectory: workingDirectory, reference: reference
        ) else {
            throw CartographError.changedFilesUnavailable(
                reference: reference,
                reason: "the repository configures a git filter driver whose name cannot be safely "
                    + "disabled; analyze a fresh checkout instead (for example 'git clone --no-local') "
                    + "so the lookup does not run repository-defined filters"
            )
        }

        // 리비전처럼 받은 문자열이 diff 옵션이 되지 않도록 먼저 커밋 ID로 해결한다.
        // --output=...도 여기서는 파일을 쓰는 지시가 아니라 찾을 리비전일 뿐이다.
        guard let commit = try lines(
            of: ["rev-parse", "--verify", "--end-of-options", "\(reference)^{commit}"],
            in: workingDirectory, reference: reference
        ).first else {
            throw CartographError.changedFilesUnavailable(reference: reference, reason: "revision has no commit")
        }

        // `<ref>...HEAD` 는 공통 조상 이후만 본다. `<ref>..HEAD` 를 쓰면 기준
        // 브랜치가 앞서 나갔을 때 남의 변경까지 이번 것으로 보고한다.
        // 트리 대 트리 비교라 작업 트리를 읽지 않지만, 무력화 인자는 무해하므로 함께 붙인다.
        let committed = try lines(
            of: diffArguments(
                comparedTo: "\(commit)...HEAD",
                includingDeleted: includingDeleted,
                againstWorkingTree: false
            ),
            in: workingDirectory,
            reference: reference,
            globalOptions: neutralizing
        )
        // 작업 트리와 HEAD 의 차이. 추적 파일을 고치고 커밋하지 않은 경우가
        // 미커밋 변경의 가장 흔한 형태인데 위 비교로는 잡히지 않는다.
        // stat 이 어긋난 추적 파일을 필터로 다시 읽지 않도록 자동 refresh 를 끈다.
        // 그 결과 내용은 같고 stat 만 바뀐 파일도 변경으로 센다(보수적 상위집합).
        let uncommitted = try lines(
            of: diffArguments(comparedTo: "HEAD", includingDeleted: includingDeleted, againstWorkingTree: true),
            in: workingDirectory,
            reference: reference,
            globalOptions: neutralizing + ["-c", "diff.autoRefreshIndex=false"]
        )
        // `--full-name` 이 없으면 하위 디렉터리에서 실행할 때 그 디렉터리 기준
        // 상대 경로가 나와, 저장소 루트에 이어 붙이면 엉뚱한 경로가 된다.
        let untracked = try lines(
            of: ["ls-files", "--others", "--exclude-standard", "--full-name", "-z"],
            in: workingDirectory,
            reference: reference,
            globalOptions: neutralizing
        )

        return Set((committed + uncommitted + untracked).map { (root as NSString).appendingPathComponent($0) })
    }

    /// 변경 파일을 조회할 때 삭제와 이름 변경을 보존할지에 따라 git 옵션을 고른다.
    /// diff.relative 설정과 무관하게 저장소 전체의 루트 기준 경로를 받는다.
    ///
    /// 작업 트리 비교(`againstWorkingTree`)는 저장소가 정의한 필터·외부 diff·textconv 를
    /// 발동할 수 있으므로 끈다. 이름 변경 감지도 내용을 다시 읽으므로 끈다 —
    /// `--diff-filter=d` 모드에서도 새 경로는 A 로 남아 출력이 같다. 서브모듈 안에서
    /// git 을 다시 띄우지 않도록 dirty 서브모듈은 무시한다(gitlink 커밋 변경은 경로로 남는다).
    private static func diffArguments(
        comparedTo revision: String, includingDeleted: Bool, againstWorkingTree: Bool
    ) -> [String] {
        var arguments = ["diff", "--no-relative", "--name-only", "--no-ext-diff", "--no-textconv"]
        if includingDeleted {
            // 이름 변경을 감지하면 옛 경로가 새 경로로 접혀 사라진다. 영향 분석은
            // 현재 인덱스에 없는 옛 선언도 시드로 삼아야 하므로 양쪽 경로를 받는다.
            arguments.append("--no-renames")
        } else {
            arguments.append("--diff-filter=d")
            if againstWorkingTree { arguments.append("--no-renames") }
        }
        if againstWorkingTree { arguments.append("--ignore-submodules=dirty") }
        arguments.append("-z")
        arguments.append(revision)
        return arguments
    }

    /// 저장소가 정의한 콘텐츠 필터 드라이버(clean·smudge·process)를 무력화하는 `-c` 인자.
    ///
    /// 읽기 전용 `git config --get-regexp` 로 드라이버 이름을 모은다. 이 조회는 명령을
    /// 실행하지 않고 include 설정도 따라간다. 이름마다 네 키를 빈 값으로 덮고 required 를
    /// 끈다 — required 를 끄지 않으면 clean 필터가 비어 실패할 때 git 이 128로 죽는다.
    ///
    /// 이름에 `=` 가 들어가면 `-c filter.<이름>.clean=` 의 키가 첫 `=` 에서 잘려 엉뚱한
    /// 키를 덮으므로 그 드라이버를 끄지 못한다. 그런 이름이 있으면 nil 을 돌려 호출자가
    /// fail-closed 로 멈추게 한다(원칙 1). 설정을 읽지 못하면(무일치 종료 1 이 아닌 실패)
    /// 던진다. 인자 순서를 결정적으로 유지하려고 이름을 정렬·중복 제거한다.
    static func filterNeutralizationArguments(
        workingDirectory: String, reference: String
    ) throws -> [String]? {
        let result = try runGit(
            arguments: ["config", "-z", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|smudge|process)$"],
            globalOptions: [], in: workingDirectory, reference: reference
        )
        // `--get-regexp` 는 일치가 없으면 종료 코드 1 이다(오류가 아니다). 그 밖의 0 아닌
        // 종료는 설정을 읽을 수 없는 것이므로 막는 쪽으로 던진다.
        switch result.status {
        case 0: break
        case 1: return []
        default: throw gitFailure(result: result, reference: reference)
        }
        var names = Set<String>()
        for key in String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\0") {
            if let name = driverName(fromConfigKey: String(key)) { names.insert(name) }
        }
        var arguments: [String] = []
        for name in names.sorted() {
            if name.contains("=") { return nil }
            for key in ["clean", "smudge", "process"] {
                arguments.append("-c")
                arguments.append("filter.\(name).\(key)=")
            }
            arguments.append("-c")
            arguments.append("filter.\(name).required=false")
        }
        return arguments
    }

    /// `filter.<이름>.<clean|smudge|process>` 설정 키에서 드라이버 이름만 떼어 낸다.
    /// 이름에는 점이 들어갈 수 있으므로 `filter.` 접두와 마지막 `.` 사이 전체가 이름이다.
    static func driverName(fromConfigKey key: String) -> String? {
        let prefix = "filter."
        guard key.hasPrefix(prefix), let lastDot = key.lastIndex(of: ".") else { return nil }
        let nameStart = key.index(key.startIndex, offsetBy: prefix.count)
        guard nameStart < lastDot else { return nil }
        return String(key[nameStart..<lastDot])
    }

    /// git 을 한 번 실행하고 출력을 경로 목록으로 나눈다.
    ///
    /// `-z` 를 준 명령은 NUL 로 구분된다. 기본 출력은 `core.quotePath` 때문에
    /// 비ASCII 이름을 따옴표로 감싸고 8진수로 이스케이프해, 실제 경로와 절대
    /// 일치하지 않는 문자열이 나온다. 한국어 파일명에서 바로 재현된다.
    ///
    /// `globalOptions` 는 하위 명령 앞에 오는 git 전역 옵션(`-c …` 등)이다.
    /// 필터 무력화와 작업 트리 비교의 `diff.autoRefreshIndex=false` 가 이 채널로 온다.
    static func lines(
        of arguments: [String],
        in workingDirectory: String,
        reference: String,
        globalOptions: [String] = []
    ) throws -> [String] {
        let result = try runGit(
            arguments: arguments, globalOptions: globalOptions, in: workingDirectory, reference: reference)
        guard result.status == 0 else {
            throw gitFailure(result: result, reference: reference)
        }
        let separator: Character = arguments.contains("-z") ? "\0" : "\n"
        return String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: separator)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// git 프로세스 하나를 실행하고 종료 코드와 양쪽 출력을 그대로 돌려준다.
    /// 종료 코드 해석은 호출자가 한다(config 조회는 종료 1 을 빈 결과로 삼는다).
    private static func runGit(
        arguments: [String], globalOptions: [String], in workingDirectory: String, reference: String
    ) throws -> (status: Int32, standardOutput: Data, standardError: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = safeGlobalArguments + globalOptions + ["-C", workingDirectory] + arguments
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
        return (process.terminationStatus, data, errorData)
    }

    /// git 이 0 아닌 코드로 끝났을 때의 오류. git 이 말한 이유를 그대로 전한다.
    /// 하드코딩한 문장으로 덮으면 잠금 문제나 권한 문제까지 "없는 리비전"으로 오진하게 된다.
    private static func gitFailure(
        result: (status: Int32, standardOutput: Data, standardError: Data), reference: String
    ) -> CartographError {
        let reported = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = reported.isEmpty ? "git exited with \(result.status)" : reported
        return CartographError.changedFilesUnavailable(
            reference: reference,
            reason: reason + " — in CI, check out with full history (fetch-depth: 0)"
        )
    }
}
