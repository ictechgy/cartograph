import Darwin
import Foundation
import Testing
@testable import CartographKit

@Suite("검증 자식 PID 수명")
struct FixVerificationChildLeaseTests {
    private func withChild(_ seconds: Int? = nil, body: (FixVerificationChildLease) throws -> Void) throws {
        var attributes: posix_spawnattr_t?
        try #require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        try #require(posix_spawnattr_setpgroup(&attributes, 0) == 0)
        try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0)
        let command = seconds.map { ["/bin/sleep", String($0)] } ?? ["/usr/bin/true"]
        var arguments = command.map { strdup($0) } + [nil]
        defer { for argument in arguments { free(argument) } }
        var child: pid_t = 0
        let status = arguments.withUnsafeMutableBufferPointer {
            posix_spawn(&child, command[0], nil, &attributes, $0.baseAddress!, nil)
        }
        try #require(status == 0)
        let lease = FixVerificationChildLease(pid: child)
        defer {
            if lease.signalingOpen {
                try? lease.stopGroup()
                _ = try? lease.reap()
            }
        }
        try body(lease)
    }

    @Test("WNOWAIT 종료 관측은 PID를 유지하고 그룹 정리 후 한 번만 회수한다")
    func terminalObservationPreservesLease() throws {
        try withChild { lease in
            let deadline = Date().addingTimeInterval(3)
            while try !lease.terminalObserved(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(try lease.terminalObserved())
            #expect(try lease.terminalObserved())
            #expect(!(try lease.hasOtherGroupMembers()))
            try lease.stopGroup()
            let status = try lease.reap { child, output, options in
                #expect(!lease.signalingOpen)
                do {
                    try lease.signalGroup(SIGTERM)
                    Issue.record("waitpid를 호출하기 전에도 그룹 권한이 닫혀야 한다")
                } catch let error as FixVerificationChildLease.LeaseError {
                    #expect(error == .signalingClosed)
                } catch { Issue.record(error) }
                return Darwin.waitpid(child, output, options)
            }
            #expect(status == 0)
            #expect(!lease.signalingOpen)
            do {
                try lease.signalGroup(SIGTERM)
                Issue.record("회수한 PID의 숫자 그룹을 다시 사용하면 안 된다")
            } catch let error as FixVerificationChildLease.LeaseError {
                #expect(error == .signalingClosed)
            }
            do {
                _ = try lease.reap()
                Issue.record("두 번째 회수를 허용하면 안 된다")
            } catch let error as FixVerificationChildLease.LeaseError {
                #expect(error == .signalingClosed)
            }
        }
    }

    @Test("실행 중인 소유 그룹 정리는 다른 별도 소유 그룹을 건드리지 않는다")
    func ownedGroupCleanupIsSeparate() throws {
        try withChild(10) { peer in
            try withChild(10) { target in
                #expect(!(try target.terminalObserved()))
                try target.stopGroup()
                let deadline = Date().addingTimeInterval(3)
                while try !target.terminalObserved(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                #expect(try target.terminalObserved())
                let status = try target.reap()
                #expect([SIGTERM, SIGKILL].contains(status & 0x7f))
                #expect(!(try peer.terminalObserved()))
                #expect(getpgid(peer.pid) == peer.pid)
            }
        }
    }
}
