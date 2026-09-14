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

    func validate() throws {
        guard coreDataBuildEvidencePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw ValidationError("--coredata-build-evidence cannot be empty")
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
        let tools = CartographMCPTools(makeSession: {
            try AnalysisSession(serviceFactory: {
                try CommandSupport.makeContext(options).service
            })
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
