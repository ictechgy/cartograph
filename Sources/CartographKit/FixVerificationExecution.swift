import Darwin
import Foundation

/// 검증 자식만 별도 프로세스 그룹에 놓아 timeout/중단이 기존 프로세스에 닿지 않게 한다.
struct FixVerificationExecution {
    private static let outputMaximumBytes = 1024 * 1024
    let status: String
    var exitCode: Int32? = nil
    var signal: Int32? = nil
    let detail: String

    static func run(_ verification: MechanicalFixVerification, project: String, directory: URL) throws -> Self {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var output = [Int32](repeating: -1, count: 2)
        var errors = [Int32](repeating: -1, count: 2)
        guard pipe(&output) == 0, pipe(&errors) == 0 else {
            for descriptor in output + errors where descriptor >= 0 { close(descriptor) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { for descriptor in output + errors where descriptor >= 0 { close(descriptor) } }
        for pair in [(output, STDOUT_FILENO), (errors, STDERR_FILENO)] {
            try checked(posix_spawn_file_actions_adddup2(&actions, pair.0[1], pair.1))
            try checked(posix_spawn_file_actions_addclose(&actions, pair.0[0]))
            try checked(posix_spawn_file_actions_addclose(&actions, pair.0[1]))
            guard fcntl(pair.0[0], F_SETFL, O_NONBLOCK) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checked(posix_spawn_file_actions_addchdir_np(&actions, project))
        var mask = sigset_t()
        sigemptyset(&mask)
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        sigaddset(&mask, SIGINT)
        sigaddset(&mask, SIGTERM)
        try checked(posix_spawnattr_setsigdefault(&attributes, &mask))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        var environment = ProcessInfo.processInfo.environment
        environment["CARTOGRAPH_FIX_PROJECT"] = project
        environment["CARTOGRAPH_FIX_RECOVERY_DIRECTORY"] = directory.path
        var child: pid_t = 0
        let started = verification.arguments[0].withCString { executable in
            cStrings(verification.arguments) { argv in
                cStrings(environment.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value }) { env in
                    posix_spawnp(&child, executable, &actions, &attributes, argv, env)
                }
            }
        }
        close(output[1])
        output[1] = -1
        close(errors[1])
        errors[1] = -1
        guard started == 0 else {
            return .init(status: "launch-failed", detail: "Verification executable could not start (errno \(started)).")
        }
        var stdout = Data()
        var stderr = Data()
        let lease = FixVerificationChildLease(pid: child)
        var result: Self?
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(verification.timeoutSeconds * 1_000_000_000)
        while true {
            do {
                if try lease.terminalObserved() { break }
            } catch {
                result = .init(status: "wait-failed",
                    detail: "Could not observe verification without reaping: \(error).")
                break
            }
            let oversized = drain(output[0], into: &stdout) || drain(errors[0], into: &stderr)
            if let signal = verification.interruption() {
                result = .init(
                    status: "interrupted", signal: signal,
                    detail: "Verification interrupted; restoring owned edits.")
            } else if oversized {
                result = .init(status: "output-limit", detail: "Verification exceeded the 1 MiB stdout/stderr budget.")
            } else if DispatchTime.now().uptimeNanoseconds >= deadline {
                result = .init(status: "timed-out", detail: "Verification timed out; restoring owned edits.")
            }
            if result != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // 리더를 회수하기 전까지만 같은 group에 신호를 보낼 권한을 유지한다.
        do {
            if result == nil, try lease.hasOtherGroupMembers() {
                result = .init(status: "background-processes", detail: "Verifier left child processes running.")
            }
        } catch {
            result = result ?? .init(status: "cleanup-failed", detail: "Owned group census failed: \(error).")
        }
        do {
            try lease.stopGroup()
        } catch {
            result = result ?? .init(status: "cleanup-failed", detail: "Could not clean the owned group: \(error).")
            do { try lease.stopLeader() } catch {
                result = .init(status: "cleanup-failed",
                    detail: "Owned leader cleanup could not be verified: \(error).")
            }
        }
        var waitStatus: Int32 = 0
        do { waitStatus = try lease.reap() } catch {
            result = .init(status: "wait-failed", detail: "Verification could not be reaped safely: \(error).")
        }
        // 종료 직전 파이프 꼬리도 같은 예산으로 판정한다. 두 채널 모두 반드시 비운다.
        let finalReads = outputMaximumBytes / (16 * 1024) + 1
        let finalOutputOverflow = drain(output[0], into: &stdout, maximumReads: finalReads)
        let finalErrorOverflow = drain(errors[0], into: &stderr, maximumReads: finalReads)
        if finalOutputOverflow || finalErrorOverflow {
            result = result ?? .init(status: "output-limit",
                detail: "Verification exceeded the 1 MiB stdout/stderr budget.")
        }
        try stdout.write(to: directory.appendingPathComponent("verification.stdout"), options: .atomic)
        try stderr.write(to: directory.appendingPathComponent("verification.stderr"), options: .atomic)
        for name in ["verification.stdout", "verification.stderr"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        if let result { return result }
        let signal = waitStatus & 0x7f
        if signal != 0 {
            return .init(status: "failed", signal: signal, detail: "Verifier terminated by signal \(signal).")
        }
        let code = (waitStatus >> 8) & 0xff
        return .init(
            status: code == 0 ? "passed" : "failed", exitCode: code,
            detail: code == 0 ? "Selected verification command passed." : "Verification exited \(code).")
    }

    private static func checked(_ result: Int32) throws {
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    }

    private static func drain(_ descriptor: Int32, into data: inout Data, maximumReads: Int = 16) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<maximumReads {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            guard data.count + count <= outputMaximumBytes else { return true }
            data.append(contentsOf: buffer.prefix(count))
        }
        return false
    }

    private static func cStrings<T>(
        _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
