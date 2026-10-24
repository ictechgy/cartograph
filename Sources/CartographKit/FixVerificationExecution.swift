import Darwin
import Foundation

/// 검증 자식만 별도 프로세스 그룹에 놓아 timeout/중단이 기존 프로세스에 닿지 않게 한다.
struct FixVerificationExecution {
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
        var waitStatus: Int32 = 0
        var result: Self?
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(verification.timeoutSeconds * 1_000_000_000)
        while true {
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
            let waited = waitpid(child, &waitStatus, WNOHANG)
            if waited == child { break }
            if waited < 0, errno != EINTR {
                result = .init(status: "wait-failed", detail: "Could not wait for verification; restoring owned edits.")
            }
            if result != nil {
                stopGroup(child)
                while waitpid(child, &waitStatus, 0) < 0, errno == EINTR {}
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // 종료한 리더의 background 자식이 복구 뒤 소스를 다시 쓰지 못하게 한다.
        if kill(-child, 0) == 0 {
            stopGroup(child)
            result = result ?? .init(status: "background-processes", detail: "Verifier left child processes running.")
        }
        _ = drain(output[0], into: &stdout)
        _ = drain(errors[0], into: &stderr)
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

    private static func stopGroup(_ child: pid_t) {
        _ = kill(-child, SIGTERM)
        Thread.sleep(forTimeInterval: 0.1)
        _ = kill(-child, SIGKILL)
    }

    private static func checked(_ result: Int32) throws {
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    }

    private static func drain(_ descriptor: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<16 {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            guard data.count + count <= 1024 * 1024 else { return true }
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
