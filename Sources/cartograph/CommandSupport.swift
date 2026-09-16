import ArgumentParser
import CartographCore
import CartographKit
import Foundation

/// 명령 실행에 필요한 것들을 한 번에 준비한다.
struct CommandContext {
    let service: CartographService
    let configuration: CartographConfiguration
    let fileSystem: any FileSystem
}

enum CommandSupport {
    /// 종료 코드 규약.
    ///
    /// 0 정상, 1 `--strict` 상태에서 문제 발견, 2 도구 오류.
    /// CI 스크립트가 "문제 있음"과 "도구가 죽음"을 구분할 수 있어야 한다.
    static let findingsExitCode: Int32 = 1
    static let failureExitCode: Int32 = 2

    static func makeContext(_ options: GlobalOptions) throws -> CommandContext {
        let fileSystem = LocalFileSystem()
        let resolved = try options.resolveConfiguration(fileSystem: fileSystem)

        // 경고를 출력 단계까지 들고 가면, 명령이 실패했을 때 통째로 사라진다.
        // 설정 오타 때문에 실패한 사용자가 정작 그 오타를 못 보게 된다.
        if !options.quiet {
            for warning in resolved.warnings {
                FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8))
            }
        }

        // 변경 목록은 실행마다 달라지는 값이라 설정 파일이 아니라 여기서 구한다.
        let scope = try options.since.map {
            ReportScope(
                files: try ChangedFiles.since(
                    $0,
                    workingDirectory: resolved.configuration.projectPath
                        ?? fileSystem.currentDirectoryPath
                )
            )
        }

        return CommandContext(
            service: CartographService(
                configuration: resolved.configuration,
                environment: .live(),
                reportScope: scope,
                allowsEmptyIndex: options.allowEmptyIndex
            ),
            configuration: resolved.configuration,
            fileSystem: fileSystem
        )
    }

    /// 결과를 내보내고 종료 코드를 결정한다.
    static func emit(
        _ outcome: CommandOutcome,
        options: GlobalOptions,
        context: CommandContext
    ) throws {
        if let path = options.outputPath {
            // 여기서 나는 파일 시스템 오류를 그대로 던지면 ArgumentParser 가 1 로
            // 끝낸다. 그것은 "코드에 문제가 있음"에 예약된 코드다. 파일을 못 쓴 것과
            // 순환을 찾은 것이 CI 에서 같은 신호가 되어서는 안 된다.
            do {
                try context.fileSystem.write(text: outcome.output, to: path)
            } catch {
                throw CartographError.outputUnwritable(path: path, underlying: "\(error)")
            }
            if !options.quiet {
                print("Wrote \(path)")
            }
        } else {
            print(outcome.output, terminator: "")
        }

        // 없는 이름을 물어본 것은 코드의 문제가 아니라 인자의 문제다. 사용 오류로
        // 끝내야 CI 스크립트의 오타가 드러난다. 설명은 이미 출력한 뒤다.
        if outcome.subjectNotFound {
            // 단일 경로는 이름과 비슷한 이름 추천을 담은 문구를 준비해 온다.
            guard !outcome.missingSubjects.isEmpty else {
                throw ValidationError(
                    outcome.notFoundMessage ?? "no declaration matches the requested name"
                )
            }
            let shown = outcome.missingSubjects.prefix(10).joined(separator: ", ")
            let rest = outcome.missingSubjects.count - min(10, outcome.missingSubjects.count)
            // 배치에서는 어느 이름이 없었는지 말한다. 불리언 하나만 던지면 1000건 중
            // 셋이 없었을 때 사용자가 JSON 을 다시 훑어야 한다. 답은 이미 다 나갔다.
            throw ValidationError(
                "no declaration matches \(outcome.missingSubjects.count) of the requested names: "
                    + shown + (rest > 0 ? " and \(rest) more" : "")
                    + ". Every other answer is already in the output above."
            )
        }

        if let reason = outcome.incompleteAnalysis {
            FileHandle.standardError.write(Data(("error: " + reason + "\n").utf8))
            throw ExitCode(failureExitCode)
        }

        // 임계값 초과는 코드에 대한 판정이지 도구의 실패가 아니다.
        // 리포트를 다 보여 준 뒤에 사유를 알리고 "문제 발견" 코드로 끝낸다.
        if let failure = outcome.thresholdFailure {
            FileHandle.standardError.write(Data(("error: " + describe(failure) + "\n").utf8))
            throw ExitCode(findingsExitCode)
        }
        if context.configuration.strict, outcome.hasFindings {
            throw ExitCode(findingsExitCode)
        }
    }

    /// 사용자에게 보여 줄 오류 메시지로 바꾼다.
    static func describe(_ error: any Error) -> String {
        (error as? CartographError)?.errorDescription ?? "\(error)"
    }
}

/// 정해진 자리에 템플릿 파일을 깐다.
///
/// `skill` 과 `init` 이 절차를 따로 두면 존재 확인 문구와 오류 감싸기가 두
/// 벌로 갈라진다 — 실제로 그랬다. 새 하위 명령이 템플릿을 깔 일이 생기면
/// 여기 하나만 고쳐진다.
enum TemplateInstaller {
    /// 내용을 쓰고 안내 줄을 출력한다. 덮어쓰기는 `--force` 를 요구한다.
    static func install(
        _ content: String,
        to path: String,
        force: Bool,
        fileSystem: any FileSystem
    ) throws {
        guard force || !fileSystem.fileExists(at: path) else {
            throw ValidationError("\(path) already exists. Pass --force to overwrite it.")
        }
        do {
            try fileSystem.write(text: content, to: path)
        } catch {
            throw CartographError.outputUnwritable(path: path, underlying: "\(error)")
        }
        print("Wrote \(path)")
    }
}
