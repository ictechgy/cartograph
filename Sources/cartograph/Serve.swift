import ArgumentParser
import CartographCore
import CartographKit
import Foundation

/// MCP JSON-RPC stdio 서버를 실행한다.
struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve Cartograph analysis tools over MCP stdio."
    )

    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("coredata-build-evidence"),
        help: "Fixed project-contained Core Data build evidence for runtime and impact tools.")
    var coreDataBuildEvidencePath: String?
    @Option(name: .customLong("session-freshness-interval"),
        help: "Seconds a verified session may be reused before re-checking inputs (0 checks every request).")
    var sessionFreshnessInterval: Double = 1.0

    func validate() throws {
        guard coreDataBuildEvidencePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw ValidationError("--coredata-build-evidence cannot be empty")
        }
        guard sessionFreshnessInterval >= 0 else {
            throw ValidationError("--session-freshness-interval must be at least 0 seconds")
        }
        guard options.since == nil else {
            throw ValidationError("--since cannot be combined with serve; use the impact tool's file selectors")
        }
        guard options.level == nil else {
            throw ValidationError("--level cannot be combined with serve; tools choose their own graph levels")
        }
        guard options.reportFormat == nil else {
            throw ValidationError("--report-format cannot be combined with serve; MCP responses are structured JSON")
        }
        guard !options.strict else {
            throw ValidationError("--strict cannot be combined with serve; tool results carry their own error state")
        }
        guard options.outputPath == nil else {
            throw ValidationError("--output cannot be combined with serve; stdout is reserved for MCP responses")
        }
    }

    func run() throws {
        // 입력 지문 검증은 소스·인덱스 파일 전부를 다시 stat 하므로 프로젝트에 비례해
        // 커지고, MCP 도구 호출은 연속으로 온다. 창 안의 반복 검증은 같은 세대를
        // 확인할 뿐이라 웜 지연만 키운다 — 1초는 어떤 재빌드보다 짧은 유보 상한이다.
        let tools = CartographMCPTools(makeSession: {
            try AnalysisSession(serviceFactory: {
                try CommandSupport.makeContext(options).service
            }, freshnessCheckInterval: .seconds(sessionFreshnessInterval))
        }, coreDataBuildEvidencePath: coreDataBuildEvidencePath)
        let handler = MCPMessageHandler(
            tools: CartographMCPTools.definitions,
            serverName: Cartograph.toolName,
            serverVersion: Cartograph.version,
            instructions: "Use cartograph_status before analysis tools when you need session metadata.",
            callTool: { name, arguments in try tools.call(name: name, arguments: arguments) }
        )
        do {
            try MCPStdioRunner.run(handler: handler)
        } catch let error as CartographError {
            FileHandle.standardError.write(Data(("error: " + (error.errorDescription ?? "Cartograph server failed") + "\n").utf8))
            throw ExitCode(CommandSupport.failureExitCode)
        } catch let error as AnalysisSessionError {
            FileHandle.standardError.write(Data(("error: " + (error.errorDescription ?? "analysis session failed") + "\n").utf8))
            throw ExitCode(CommandSupport.failureExitCode)
        } catch {
            FileHandle.standardError.write(Data("error: Cartograph MCP server failed\n".utf8))
            throw ExitCode(CommandSupport.failureExitCode)
        }
    }
}
