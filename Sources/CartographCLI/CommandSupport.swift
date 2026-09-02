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
        if !options.quiet {
            for warning in context.warnings {
                FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8))
            }
        }

        if let path = options.outputPath {
            try context.fileSystem.write(text: outcome.output, to: path)
            if !options.quiet {
                print("Wrote \(path)")
            }
        } else {
            print(outcome.output, terminator: "")
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
