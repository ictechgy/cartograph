import Darwin
import Foundation
@testable import CartographIndexStore
import Testing

@Suite("판독기 DB 사용 중 정리 방지")
struct ReaderDatabaseLeaseTests {
    @Test("스냅샷 수명 동안 배타적 정리가 거부되고 해제 뒤 허용된다")
    func leaseProtectsDatabaseLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try ReaderDatabaseLease(parent: root.path)
        let descriptor = open(root.appendingPathComponent(".cartograph-reader.lock").path, O_RDWR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        withExtendedLifetime(lease) {
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK)
        }
    }

    @Test("리더가 종료되면 같은 잠금 파일에서 정리를 다시 허용한다")
    func releasedLeaseAllowsMaintenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try holdAndRelease(parent: root.path)
        let descriptor = open(root.appendingPathComponent(".cartograph-reader.lock").path, O_RDWR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    }

    private func holdAndRelease(parent: String) throws {
        let lease = try ReaderDatabaseLease(parent: parent)
        withExtendedLifetime(lease) {}
    }

    @Test("잠금 경로가 링크이면 외부 파일을 열지 않는다")
    func refusesLockSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".cartograph-reader.lock"), withDestinationURL: target
        )
        #expect(throws: POSIXError.self) { try ReaderDatabaseLease(parent: root.path) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "preserve")
    }
}
