import ArgumentParser
import CartographCore
import CartographKit
import Foundation

/// 명령 실행에 필요한 것들을 한 번에 준비한다.
struct CommandContext {
    let service: CartographService
    let configuration: CartographConfiguration
    let fileSystem: any FileSystem
    let warnings: [String]
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

        return CommandContext(
            service: CartographService(
                configuration: resolved.configuration,
                environment: .live()
            ),
            configuration: resolved.configuration,
            fileSystem: fileSystem,
            warnings: resolved.warnings
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
