import CartographCore
import CryptoKit
import Darwin
import Foundation

/// 명시적으로 선택한 검증만 실행한다. 문자열을 셸 코드로 해석하지 않는다.
public struct MechanicalFixVerification: Sendable {
    package static let maximumSourceBytes = 64 * 1024 * 1024
    package static let maximumFiles = 10_000
    public let arguments: [String]
    public let timeoutSeconds: Double
    public let recoveryDirectory: String?
    package let interruption: @Sendable () -> Int32?
    package let beginInterruptionHandling: @Sendable () -> Void

    /// 검증은 프로젝트 루트에서 현재 환경을 상속한다. 명령 자체의 부작용은 샌드박싱하지 않는다.
    public init(arguments: [String], timeoutSeconds: Double = 600, recoveryDirectory: String? = nil) {
        self.init(
            arguments: arguments, timeoutSeconds: timeoutSeconds, recoveryDirectory: recoveryDirectory,
            interruption: { nil })
    }

    package init(
        arguments: [String], timeoutSeconds: Double, recoveryDirectory: String?,
        interruption: @escaping @Sendable () -> Int32?,
        beginInterruptionHandling: @escaping @Sendable () -> Void = {}
    ) {
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.recoveryDirectory = recoveryDirectory
        self.interruption = interruption
        self.beginInterruptionHandling = beginInterruptionHandling
    }

    package func validate() throws {
        guard !arguments.isEmpty, !arguments[0].isEmpty,
            arguments.allSatisfy({ !$0.utf8.contains(0) }),
            timeoutSeconds.isFinite, (0.1...86_400).contains(timeoutSeconds)
        else {
            throw CartographError.invalidConfiguration(
                path: "fix",
                reason:
                    "Verification requires a nonempty argv array without NUL and a timeout of 0.1...86400 seconds.")
        }
    }
}

/// 성공 여부와 복구 상태를 분리한다. 일부 충돌이 있으면 적용 완료로 오인하지 않게 한다.
public struct MechanicalFixVerificationReport: Sendable, Equatable, Codable {
    public let status: String
    public let exitCode: Int32?
    public let signal: Int32?
    public let rollback: String
    public let recoveryDirectory: String
    public let detail: String
    public var passed: Bool { status == "passed" }
}

package struct PreparedMechanicalEdit {
    let path: String
    let original: Data
    let replacement: Data
}

/// Git reset/stash를 쓰지 않고 자신이 기록한 파일만 바이트·inode 대조 뒤 복원한다.
package final class MechanicalFixTransaction {
    private struct Entry {
        let edit: PreparedMechanicalEdit
        let stamp: FileFingerprintStamp
        var written = false
        var appliedStamp: FileFingerprintStamp?
    }

    private let fileSystem: any FileSystem
    private let project: String
    private let verification: MechanicalFixVerification
    private let directory: URL
    private let identityReader: (String) -> FileFingerprintStamp?
    private var entries: [Entry] = []

    package init(
        edits: [PreparedMechanicalEdit], project: String, fileSystem: any FileSystem,
        verification: MechanicalFixVerification,
        identityReader: ((String) -> FileFingerprintStamp?)? = nil
    ) throws {
        try verification.validate()
        guard edits.count <= MechanicalFixVerification.maximumFiles,
            edits.reduce(0, { $0 + $1.original.count }) <= MechanicalFixVerification.maximumSourceBytes
        else {
            throw CartographError.invalidConfiguration(
                path: project,
                reason: "Verified fixes are bounded to 10000 files and 64 MiB of original source; narrow the scope.")
        }
        guard fileSystem is LocalFileSystem else {
            throw CartographError.invalidConfiguration(
                path: project,
                reason: "Command verification requires a local file system; no files were changed.")
        }
        self.fileSystem = fileSystem
        self.project = try fileSystem.realPath(at: project)
        self.verification = verification
        self.identityReader = identityReader ?? { fileSystem.fingerprintStamp(at: $0) }
        directory =
            verification.recoveryDirectory.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("cartograph-fix-" + UUID().uuidString)
        guard !FileManager.default.fileExists(atPath: directory.path),
            !(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/").hasPrefix(self.project + "/")
        else {
            throw CartographError.invalidConfiguration(
                path: directory.path,
                reason: "Recovery directory must be new and outside the project; no files were changed.")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for (index, edit) in edits.enumerated() {
            guard edit.path.hasPrefix(self.project + "/"),
                try fileSystem.realPath(at: edit.path) == edit.path,
                let stamp = fileSystem.fingerprintStamp(at: edit.path), stamp.isRegularFile,
                try fileSystem.readData(at: edit.path) == edit.original,
                fileSystem.fingerprintStamp(at: edit.path) == stamp
            else {
                throw CartographError.invalidConfiguration(
                    path: edit.path,
                    reason: "Source identity changed or is not a regular project file; no files were changed.")
            }
            let backup = directory.appendingPathComponent("original-\(index)")
            try edit.original.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            entries.append(Entry(edit: edit, stamp: stamp))
        }
        try journal(status: "prepared", detail: "No files changed yet.")
        verification.beginInterruptionHandling()
    }

    package func perform() -> MechanicalFixVerificationReport {
        var result = FixVerificationExecution(status: "apply-failed", detail: "Could not apply every planned edit.")
        do {
            for index in entries.indices {
                if let signal = verification.interruption() {
                    result = .init(status: "interrupted", signal: signal, detail: "Interrupted before verification.")
                    throw TransactionStopped()
                }
                let entry = entries[index]
                guard try fileSystem.readData(at: entry.edit.path) == entry.edit.original,
                    fileSystem.fingerprintStamp(at: entry.edit.path) == entry.stamp
                else {
                    result = .init(
                        status: "input-changed",
                        detail: "Source changed before applying: \(entry.edit.path)")
                    throw TransactionStopped()
                }
                entries[index].written = true
                try fileSystem.write(entry.edit.replacement, to: entry.edit.path)
                try FileManager.default.setAttributes(
                    [.posixPermissions: entry.stamp.mode & 0o7777],
                    ofItemAtPath: entry.edit.path)
                guard let appliedStamp = identityReader(entry.edit.path) else {
                    result = .init(status: "apply-failed",
                        detail: "Could not establish the written file identity; retain backups for manual recovery.")
                    throw TransactionStopped()
                }
                entries[index].appliedStamp = appliedStamp
                try journal(status: "applying", detail: "Partial application; retain original backups.")
            }
            result = try FixVerificationExecution.run(verification, project: project, directory: directory)
            if result.status == "passed" {
                for entry in entries {
                    guard try fileSystem.readData(at: entry.edit.path) == entry.edit.replacement,
                        fileSystem.fingerprintStamp(at: entry.edit.path) == entry.appliedStamp
                    else {
                        result = .init(
                            status: "input-changed",
                            detail: "Verifier or another editor changed an edited file.")
                        throw TransactionStopped()
                    }
                }
                if let signal = verification.interruption() {
                    result = .init(
                        status: "interrupted", signal: signal,
                        detail: "Interrupted before committing edits.")
                    throw TransactionStopped()
                }
                try journal(status: "passed", detail: "Verification succeeded; edits retained.")
                return report(result, rollback: "not-needed")
            }
        } catch is TransactionStopped {
            // 실패 상태와 복구 결과를 하나의 문서로 보존한다.
        } catch {
            result = .init(status: "apply-failed", detail: "Apply/verification I/O failed: \(error)")
        }
        let rollback = restore()
        do { try journal(status: result.status, detail: result.detail + " Rollback: " + rollback) } catch {
            return report(result, rollback: rollback + "; journal-write-failed")
        }
        return report(result, rollback: rollback)
    }

    private func restore() -> String {
        var conflicts = false
        var failures = false
        for entry in entries.reversed() where entry.written {
            do {
                let data = try fileSystem.readData(at: entry.edit.path)
                if data == entry.edit.original { continue }
                guard data == entry.edit.replacement,
                    try fileSystem.realPath(at: entry.edit.path) == entry.edit.path,
                    let ownedStamp = entry.appliedStamp,
                    let stamp = identityReader(entry.edit.path), stamp.isRegularFile,
                    stamp == ownedStamp
                else {
                    conflicts = true
                    continue
                }
                try fileSystem.write(entry.edit.original, to: entry.edit.path)
                try FileManager.default.setAttributes(
                    [.posixPermissions: entry.stamp.mode & 0o7777],
                    ofItemAtPath: entry.edit.path)
                guard try fileSystem.readData(at: entry.edit.path) == entry.edit.original else {
                    failures = true
                    continue
                }
            } catch { failures = true }
        }
        if failures { return conflicts ? "conflict-and-restore-failed" : "restore-failed" }
        return conflicts ? "conflict" : "restored"
    }

    private func report(_ result: FixVerificationExecution, rollback: String) -> MechanicalFixVerificationReport {
        .init(
            status: result.status, exitCode: result.exitCode, signal: result.signal, rollback: rollback,
            recoveryDirectory: directory.path, detail: result.detail)
    }

    private func journal(status: String, detail: String) throws {
        let rows: [[String: Any]] = entries.enumerated().map { index, entry in
            [
                "path": entry.edit.path, "backup": "original-\(index)", "mode": entry.stamp.mode & 0o7777,
                "originalSHA256": SHA256.hash(data: entry.edit.original).map { String(format: "%02x", $0) }.joined(),
                "replacementSHA256": SHA256.hash(data: entry.edit.replacement).map { String(format: "%02x", $0) }
                    .joined(),
                "writeAttempted": entry.written,
                "ownedIdentityAvailable": entry.appliedStamp != nil,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "project": project, "status": status, "detail": detail, "files": rows],
            options: [.prettyPrinted, .sortedKeys])
        let path = directory.appendingPathComponent("recovery.json")
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private struct TransactionStopped: Error {}
}
