import ArgumentParser
import CartographCore
import CartographKit
import Foundation

/// 테스트 프로세스에서 문자열 기반 Objective-C 런타임 경계를 자동 수집한다.
struct RuntimeCollectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collect",
        abstract: "Collect runtime lookup, selector invocation and registration evidence from a debug executable.",
        discussion: """
            The executable is launched without rebuilding or changing its signature. Hardened applications may reject
            DYLD injection; use a dedicated debug test target rather than weakening a release target. Arguments after
            -- are forwarded to the application. Application stdout and stderr are forwarded to cartograph stderr.
            For an installed iOS Simulator debug scenario app, add --simulator <UUID> and --bundle-id <identifier>.
            The installed executable must match --executable and the app must not already be running. Simulator
            exit mode requires an explicit exit(0) after success; force-closing an app produces a partial trace.
            With --duration, a matching collector seals a timed observation interval before this command stops the
            launched app. This v2 evidence does not claim application or scenario success; --timeout must be longer.
            """
    )

    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("executable"), help: "Debug application executable to launch and fingerprint.")
    var executable: String
    @Option(name: .customLong("simulator"), help: "Booted iOS Simulator UUID; requires --bundle-id.")
    var simulator: String?
    @Option(name: .customLong("bundle-id"), help: "Installed debug app to launch on --simulator.")
    var bundleID: String?
    @Option(
        name: .customLong("timeout"),
        help: "Maximum application runtime in seconds (default: 300, maximum: 3600)."
    )
    var timeout: Double = RuntimeTraceProcess.defaultTimeout
    @Option(name: .customLong("duration"),
        help: "Observe after activation, seal the trace and stop the app; does not verify scenario success.")
    var duration: Double?
    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the application after --.")
    var applicationArguments: [String] = []

    var forwardedApplicationArguments: [String] {
        applicationArguments.first == "--" ? Array(applicationArguments.dropFirst()) : applicationArguments
    }

    func validate() throws {
        guard (simulator == nil) == (bundleID == nil) else {
            throw ValidationError("--simulator and --bundle-id must be supplied together")
        }
        if let simulator, let bundleID {
            guard UUID(uuidString: simulator) != nil else {
                throw ValidationError("--simulator requires an explicit device UUID, not a device name or booted")
            }
            guard !bundleID.isEmpty, bundleID.utf8.count <= 255, !bundleID.hasPrefix("-"),
                  bundleID.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
                          .contains($0)
                  }) else {
                throw ValidationError("--bundle-id must be an installed app bundle identifier")
            }
        }
        guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--executable cannot be empty")
        }
        guard let output = options.outputPath,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ValidationError("runtime collect requires --output <runtime-trace.json>")
        }
        guard timeout.isFinite, timeout > 0, timeout <= 3_600 else {
            throw ValidationError("--timeout must be greater than 0 and at most 3600 seconds")
        }
        if let duration {
            guard duration.isFinite, duration >= 0.001, (duration * 1_000).rounded(.up) < timeout * 1_000 else {
                throw ValidationError("--duration must be at least 0.001 seconds and shorter than --timeout")
            }
        }
        guard applicationArguments.isEmpty || applicationArguments.first == "--" else {
            throw ValidationError("application arguments must follow --")
        }
        guard options.level == nil,
              options.since == nil,
              options.reportFormat == nil,
              options.baselinePath == nil,
              !options.allowEmptyIndex,
              !options.strict
        else {
            throw ValidationError(
                "runtime collect validates the complete current index and writes runtime-trace JSON; --level, --since, "
                    + "--report-format, --baseline, --allow-empty-index and --strict are not supported"
            )
        }
    }

    func run() throws {
        let context = try CommandSupport.makeContext(options)
        let cwd = context.fileSystem.currentDirectoryPath
        let executablePath = GlobalOptions.absolutePath(executable, relativeTo: cwd)
        guard let requestedOutput = options.outputPath else {
            throw ValidationError("runtime collect requires --output <runtime-trace.json>")
        }
        let outputPath = GlobalOptions.absolutePath(requestedOutput, relativeTo: cwd)
        let resolvedExecutable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        let resolvedOutput = URL(fileURLWithPath: outputPath).resolvingSymlinksInPath().path
        guard !RuntimeTraceFingerprint.isSensitivePath(outputPath),
              !RuntimeTraceFingerprint.isSensitivePath(resolvedOutput) else {
            throw ValidationError("--output points to a credential-like file; choose a runtime trace path")
        }
        guard resolvedExecutable != resolvedOutput else {
            throw ValidationError("--output must not overwrite --executable")
        }
        try RuntimeTraceFingerprint.validateExecutable(at: executablePath)
        let inputFingerprint = try context.service.runtimeTraceInputFingerprint()
        let executableFingerprint = try prepareExecutableFingerprint(at: executablePath)
        let execution = try collect(
            executablePath: executablePath,
            arguments: forwardedApplicationArguments,
            workingDirectory: context.configuration.projectPath ?? cwd
        )
        let finalInput = try? context.service.runtimeTraceInputFingerprint()
        let finalExecutable = try? RuntimeTraceFingerprint.executable(at: executablePath)
        let document = RuntimeTraceCompletion.document(
            inputFingerprint: inputFingerprint,
            finalInputFingerprint: finalInput,
            executableFingerprint: executableFingerprint,
            finalExecutableFingerprint: finalExecutable,
            executablePath: executablePath,
            execution: execution,
            launch: RuntimeTraceLaunch(
                platform: simulator == nil ? .macOS : .iOSSimulator,
                processID: execution.processID, simulatorID: simulator, bundleID: bundleID
            )
        )
        let data = try JSONEncoder.cartographDefault().encode(document)
        do {
            try context.fileSystem.write(data, to: outputPath)
        } catch {
            throw CartographError.outputUnwritable(path: outputPath, underlying: "\(error)")
        }
        if !options.quiet {
            FileHandle.standardError.write(Data("Wrote \(outputPath)\n".utf8))
        }
        guard document.hasCompleteEvidence else {
            FileHandle.standardError.write(
                Data("error: runtime collection is incomplete; inspect the output limitations\n".utf8)
            )
            throw ExitCode(CommandSupport.failureExitCode)
        }
    }

    private func prepareExecutableFingerprint(at path: String) throws -> String {
        do {
            return try RuntimeTraceFingerprint.executable(at: path)
        } catch {
            throw CartographError.invalidConfiguration(
                path: path,
                reason: "The executable could not be read for fingerprinting: \(error)"
            )
        }
    }

    private func collect(
        executablePath: String,
        arguments: [String],
        workingDirectory: String
    ) throws -> RuntimeTraceExecution {
        do {
            if let simulator, let bundleID {
                return try RuntimeSimulatorProcess().run(
                    simulator: simulator, bundleID: bundleID, executablePath: executablePath,
                    arguments: arguments, timeout: timeout, duration: duration
                )
            }
            return try RuntimeTraceProcess().run(
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeout: timeout, duration: duration
            )
        } catch {
            throw CartographError.invalidConfiguration(
                path: executablePath,
                reason: "The runtime collector could not be prepared: \(error.localizedDescription)"
            )
        }
    }
}
