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
        "-c", "core.hooksPath=/dev/null",
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
        // stat 은 맞지만 인덱스 파일보다 새로운 racy 항목은 refresh 를 꺼도 내용을 다시 읽으므로
        // 필터 무력화가 여전히 필요하다.
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
    /// 발동할 수 있으므로 끈다. 이름 변경 감지는 두 비교 모두 끈다. 작업 트리에서는 내용을
    /// 다시 읽고, 커밋 범위에서는 옛 blob 을 읽는데 partial clone 에는 그 blob 이 없을 수 있으며
    /// 받아 오는 lazy fetch 는 막혀 있다(`gitEnvironment`). `--diff-filter=d` 모드에서도 새 경로는
    /// A 로 남아 출력이 같다. 서브모듈 안에서 git 을 다시 띄우지 않도록 dirty 서브모듈은
    /// 무시한다(gitlink 커밋 변경은 경로로 남는다).
    private static func diffArguments(
        comparedTo revision: String, includingDeleted: Bool, againstWorkingTree: Bool
    ) -> [String] {
        var arguments = ["diff", "--no-relative", "--name-only", "--no-ext-diff", "--no-textconv", "--no-renames"]
        // 이름 변경을 감지하지 않으면 옛 경로는 D, 새 경로는 A 로 갈린다. 영향 분석(includingDeleted)은
        // 현재 인덱스에 없는 옛 선언도 시드로 삼아야 하므로 양쪽 경로를 받고, 그 밖에는 D 를 뺀다.
        if !includingDeleted { arguments.append("--diff-filter=d") }
        if againstWorkingTree { arguments.append("--ignore-submodules=dirty") }
        arguments.append("-z")
        arguments.append(revision)
        return arguments
    }

    /// 저장소가 정의한 콘텐츠 필터 드라이버(clean·smudge·process)를 무력화하는 `-c` 인자.
    ///
    /// 읽기 전용 `git config --name-only --list` 로 키만 모은다. 정규식 조회는 UTF-8 locale 에서
    /// 잘못된 바이트가 든 이름을 아예 건너뛸 수 있다. 이 조회는 명령을 실행하지 않고 include 설정도
    /// 따라간다. 이름마다 네 키를 빈 값으로 덮고 required 를
    /// 끈다 — required 를 끄지 않으면 clean 필터가 비어 실패할 때 git 이 128로 죽는다.
    ///
    /// 이름에 `=` 가 들어가면 `-c filter.<이름>.clean=` 의 키가 첫 `=` 에서 잘려 엉뚱한
    /// 키를 덮으므로 그 드라이버를 끄지 못한다. 그런 이름이 있으면 nil 을 돌려 호출자가
    /// fail-closed 로 멈추게 한다(원칙 1). 설정을 읽지 못하면
    /// 던진다. 인자 순서를 결정적으로 유지하려고 이름을 정렬·중복 제거한다.
    /// 반환한 인자는 runGit 이 바이트를 보존하는 비공개 임시 include 로 바꾼다.
    /// Process 의 argv/환경 전달에 직접 넣으면 macOS 에서 Unicode 이름이 정규화된다.
    static func filterNeutralizationArguments(
        workingDirectory: String, reference: String
    ) throws -> [String]? {
        let result = try runGit(
            arguments: ["config", "-z", "--name-only", "--list"],
            globalOptions: [], in: workingDirectory, reference: reference
        )
        guard result.status == 0 else { throw gitFailure(result: result, reference: reference) }
        // 손실 변환하면 다른 이름을 -c 로 덮고 원래 드라이버는 실행할 수 있다.
        guard let configKeys = String(data: result.standardOutput, encoding: .utf8) else { return nil }
        // Git 의 subsection 은 바이트로 구별한다. Swift String 의 정규화 동등성으로
        // NFC/NFD 이름을 합치면 한 드라이버만 무력화하고 다른 드라이버는 남긴다.
        var names = Set<Data>()
        for key in configKeys.split(separator: "\0") {
            if let name = driverName(fromConfigKey: String(key)) { names.insert(Data(name.utf8)) }
        }
        var arguments: [String] = []
        for bytes in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            if bytes.contains(0x3D) || bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) { return nil }
            let name = String(decoding: bytes, as: UTF8.self)
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
    ///
    /// 그 사이가 비어도(`filter..clean`, 설정 파일의 `[filter ""]`) 이름이 빈 드라이버다. 값이 빈 속성
    /// `filter=` 가 이 드라이버를 고르고 git 은 그 명령을 실행하므로, 빈 이름도 돌려주어 무력화한다
    /// (`-c filter..clean=` 이 그 드라이버를 덮는다). 부분절이 없는 `filter.clean` 은 git 이 드라이버로
    /// 쓰지 않으므로 nil 이다.
    static func driverName(fromConfigKey key: String) -> String? {
        GitFilterOverrides.filterKeyComponents(Array(key.utf8)).map { String(decoding: $0.name, as: UTF8.self) }
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
        let data = try output(of: arguments, in: workingDirectory, reference: reference, globalOptions: globalOptions)
        let separator: Character = arguments.contains("-z") ? "\0" : "\n"
        return String(decoding: data, as: UTF8.self)
            .split(separator: separator)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 경로와 patch 를 손실 없이 해석해야 하는 호출자도 같은 실행 방어를 거친다.
    static func output(
        of arguments: [String], in workingDirectory: String, reference: String, globalOptions: [String] = []
    ) throws -> Data {
        let result = try runGit(
            arguments: arguments, globalOptions: globalOptions, in: workingDirectory, reference: reference)
        guard result.status == 0 else {
            throw gitFailure(result: result, reference: reference)
        }
        return result.standardOutput
    }

    /// 분석용 git 의 환경. 이 프로세스의 환경에 lazy fetch 차단만 더한다.
    ///
    /// partial clone 은 빠진 객체를 promisor 원격에서 그때그때 받아 온다(lazy fetch). 그 fetch 는 분석 대상
    /// 저장소 설정이 고른 원격 명령(`remote.<이름>.uploadpack`, `core.sshCommand`, `ext::` URL 등)을 실행하므로,
    /// `.git` 이 통째로 배포된 저장소가 객체 하나를 빼 두면 읽기 전용 조회가 그 명령을 띄운다.
    /// `GIT_NO_LAZY_FETCH=1` 은 git 2.45 와 2024년 5월 보안 릴리스(2.39.4 등)부터 그 fetch 를 거부한다.
    /// 그보다 오래된 git 은 이 변수를 모른 채 무시할 뿐 실패하지 않는다. 전역 옵션 `--no-lazy-fetch` 는 옛
    /// git 에서 사용 오류가 되므로 환경 변수로 준다. 빠진 객체가 꼭 필요한 조회는 실패하고, 호출자가
    /// fail-closed 로 다룬다(`--since` 는 종료 2, revision 은 생략).
    private static func gitEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_NO_LAZY_FETCH"] = "1"
        // GIT_DIFF_OPTS 는 명령행 -U0 보다 우선할 수 있다. 줄 필터에 문맥 줄이 섞이지 않게 한다.
        environment.removeValue(forKey: "GIT_DIFF_OPTS")
        return environment
    }

    /// git 프로세스 하나를 실행하고 종료 코드와 양쪽 출력을 그대로 돌려준다.
    /// 종료 코드 해석은 호출자가 한다.
    private static func runGit(
        arguments: [String], globalOptions: [String], in workingDirectory: String, reference: String
    ) throws -> (status: Int32, standardOutput: Data, standardError: Data) {
        let overrides = try GitFilterOverrides.prepare(globalOptions, reference: reference)
        defer { overrides.cleanup() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = safeGlobalArguments + overrides.arguments + ["-C", workingDirectory] + arguments
        process.environment = gitEnvironment()
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
    /// 덧붙이는 안내는 CI 의 흔한 두 원인(얕은 클론, 트리를 빼고 받은 partial clone)을 가리킨다.
    /// lazy fetch 를 막으므로(`gitEnvironment`) 빠진 객체를 그때그때 받아 오지 않는다.
    private static func gitFailure(
        result: (status: Int32, standardOutput: Data, standardError: Data), reference: String
    ) -> CartographError {
        let reported = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = reported.isEmpty ? "git exited with \(result.status)" : reported
        return CartographError.changedFilesUnavailable(
            reference: reference,
            reason: reason + " — in CI, check out with full history (fetch-depth: 0) and no tree filter; "
                + "missing objects are not fetched"
        )
    }
}
