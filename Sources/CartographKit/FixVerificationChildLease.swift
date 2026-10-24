import Darwin
import Foundation

/// 직접 spawn한 자식의 wait 상태를 유지하고 PID를 회수하기 전에 그룹 권한을 영구히 닫는다.
final class FixVerificationChildLease {
    enum LeaseError: Error, Equatable {
        case signalingClosed
        case observationFailed(Int32)
        case invalidObservation
        case groupUnavailable
        case signalFailed(Int32)
        case reapFailed(Int32)
    }

    let pid: pid_t
    private(set) var signalingOpen = true

    /// 호출자는 직접 spawn한 자식만 넘기며 다른 waiter에 회수를 위임하지 않는다.
    init(pid: pid_t) { self.pid = pid }

    /// WNOWAIT는 종료를 관측해도 PID를 회수하지 않는다. 기존 waitid_capability.py와 같은 경계다.
    func terminalObserved() throws -> Bool {
        guard signalingOpen else { throw LeaseError.signalingClosed }
        var info = siginfo_t()
        let status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        guard status == 0 else {
            if errno == EINTR { return false }
            if errno == ECHILD { signalingOpen = false }
            throw LeaseError.observationFailed(errno)
        }
        if info.si_pid == 0 { return false }
        guard info.si_pid == pid, info.si_signo == SIGCHLD,
              [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(info.si_code) else {
            throw LeaseError.invalidObservation
        }
        return true
    }

    /// 좀비 리더를 제외한 같은 그룹 구성원만 본다. 시스템 전체 PID 목록은 조회하지 않는다.
    func hasOtherGroupMembers() throws -> Bool {
        guard signalingOpen else { throw LeaseError.signalingClosed }
        let terminal = try terminalObserved()
        var members = [pid_t](repeating: 0, count: 4096)
        errno = 0
        let count = members.withUnsafeMutableBytes {
            proc_listpgrppids(pid, $0.baseAddress, Int32($0.count))
        }
        guard count >= 0, count < Int32(members.count),
              count > 0 || errno == 0 || (terminal && errno == ESRCH) else {
            throw LeaseError.groupUnavailable
        }
        return members.prefix(Int(count)).contains { $0 > 0 && $0 != pid }
    }

    func stopGroup() throws {
        if try terminalObserved(), !(try hasOtherGroupMembers()) { return }
        try signalGroup(SIGTERM)
        Thread.sleep(forTimeInterval: 0.1)
        if try terminalObserved(), !(try hasOtherGroupMembers()) { return }
        try signalGroup(SIGKILL)
    }

    func signalGroup(_ number: Int32) throws {
        guard signalingOpen else { throw LeaseError.signalingClosed }
        let terminal = try terminalObserved()
        // Darwin은 waitable 좀비의 getpgid도 ESRCH로 거부한다. WNOWAIT 관측은 PID lease를 유지한다.
        if !terminal, getpgid(pid) != pid { throw LeaseError.groupUnavailable }
        guard kill(-pid, number) == 0 || errno == ESRCH else { throw LeaseError.signalFailed(errno) }
    }

    /// 그룹을 사용할 수 없을 때에도 아직 waitable 한 직접 소유 자식 하나만 정리한다.
    func stopLeader() throws {
        guard signalingOpen else { throw LeaseError.signalingClosed }
        _ = try terminalObserved()
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw LeaseError.signalFailed(errno) }
    }

    /// 이 지점 이후에는 성공·실패와 관계없이 numeric group signalling을 다시 허용하지 않는다.
    func reap(using waiter: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = Darwin.waitpid) throws -> Int32 {
        guard signalingOpen else { throw LeaseError.signalingClosed }
        signalingOpen = false
        var status: Int32 = 0
        while true {
            let found = waiter(pid, &status, 0)
            if found == pid { return status }
            if found < 0, errno == EINTR { continue }
            throw LeaseError.reapFailed(errno)
        }
    }
}
