import Darwin
import Foundation

/// 관리 도구의 전역 정리가 스냅샷을 읽는 동안 DB를 지우지 못하게 한다.
/// 잠금 파일은 삭제하지 않는다. inode가 바뀌면 기존 독자와 새 독자의 잠금이 갈라진다.
final class ReaderDatabaseLease {
    private let descriptor: Int32

    init(parent: String) throws {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let path = (parent as NSString).appendingPathComponent(".cartograph-reader.lock")
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_SH) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit {
        close(descriptor)
    }
}
