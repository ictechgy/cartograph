import CartographCore
import Darwin
import Foundation
import Testing

@testable import CartographKit

@Suite("선택한 수정 검증과 복구")
struct MechanicalFixVerificationTests {
    private func fixture(_ body: (URL, URL, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fix-transaction-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let physical = try LocalFileSystem().realPath(at: project.path)
        try body(root, root.appendingPathComponent("recovery"), physical)
    }

    private func transaction(
        _ project: String, _ recovery: URL, command: [String], timeout: Double = 3,
        interruption: @escaping @Sendable () -> Int32? = { nil }
    ) throws -> MechanicalFixTransaction {
        let path = project + "/A.swift"
        try Data("// user's unstaged original\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: path)
        return try MechanicalFixTransaction(
            edits: [
                .init(
                    path: path,
                    original: Data("// user's unstaged original\n".utf8), replacement: Data("// edited\n".utf8))
            ],
            project: project, fileSystem: LocalFileSystem(),
            verification: .init(
                arguments: command,
                timeoutSeconds: timeout, recoveryDirectory: recovery.path, interruption: interruption))
    }

    @Test("명령은 셸 없이 지정한 argv와 프로젝트 cwd 및 환경을 사용한다")
    func argvCwdAndEnvironment() throws {
        try fixture { _, recovery, project in
            let result = try transaction(
                project, recovery,
                command: [
                    "/usr/bin/python3", "-c",
                    """
                    import os,sys
                    assert os.path.realpath(os.getcwd()) == os.environ['CARTOGRAPH_FIX_PROJECT']
                    assert os.environ['CARTOGRAPH_FIX_RECOVERY_DIRECTORY'] == sys.argv[2]
                    assert sys.argv[1] == ';$(touch should-not-exist) 한글'
                    print('verified')
                    """, ";$(touch should-not-exist) 한글", recovery.path,
                ]
            ).perform()
            #expect(result.status == "passed")
            #expect(result.exitCode == 0)
            #expect(result.rollback == "not-needed")
            #expect(try String(contentsOfFile: project + "/A.swift", encoding: .utf8) == "// edited\n")
            #expect(!FileManager.default.fileExists(atPath: project + "/should-not-exist"))
            #expect(
                try String(contentsOf: recovery.appendingPathComponent("verification.stdout"), encoding: .utf8)
                    == "verified\n")
            #expect(
                try FileManager.default.attributesOfItem(atPath: project + "/A.swift")[.posixPermissions] as? Int
                    == 0o751)
        }
    }

    @Test("검증 실패는 이전 dirty 바이트와 실행 권한을 복원하고 비공개 원본을 남긴다")
    func failedVerificationRestoresOriginal() throws {
        try fixture { _, recovery, project in
            let result = try transaction(project, recovery, command: ["/usr/bin/false"]).perform()
            #expect(result.status == "failed")
            #expect(result.exitCode == 1)
            #expect(result.rollback == "restored")
            #expect(
                try String(contentsOfFile: project + "/A.swift", encoding: .utf8) == "// user's unstaged original\n")
            #expect(
                try FileManager.default.attributesOfItem(atPath: project + "/A.swift")[.posixPermissions] as? Int
                    == 0o751)
            #expect(try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? Int == 0o700)
            #expect(
                try FileManager.default.attributesOfItem(atPath: recovery.appendingPathComponent("original-0").path)[
                    .posixPermissions] as? Int == 0o600)
            let journal =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: recovery.appendingPathComponent("recovery.json"))) as? [String: Any]
            #expect(journal?["status"] as? String == "failed")
            #expect((journal?["files"] as? [[String: Any]])?.first?["originalSHA256"] != nil)
        }
    }

    @Test("실행할 수 없는 명령도 소스를 복원한다")
    func launchFailureRestores() throws {
        try fixture { _, recovery, project in
            let result = try transaction(project, recovery, command: ["/definitely/not/a/command"]).perform()
            #expect(result.status == "launch-failed")
            #expect(result.rollback == "restored")
        }
    }

    @Test("검증기나 사용자가 추가로 고친 파일은 덮지 않고 원본 백업을 유지한다")
    func concurrentChangeIsPreserved() throws {
        try fixture { _, recovery, project in
            let result = try transaction(
                project, recovery,
                command: [
                    "/usr/bin/python3", "-c",
                    "from pathlib import Path; Path('A.swift').write_text('// concurrent user edit\\n'); raise SystemExit(1)",
                ]
            ).perform()
            #expect(result.status == "failed")
            #expect(result.rollback == "conflict")
            #expect(try String(contentsOfFile: project + "/A.swift", encoding: .utf8) == "// concurrent user edit\n")
            #expect(
                try String(contentsOf: recovery.appendingPathComponent("original-0"), encoding: .utf8)
                    == "// user's unstaged original\n")
        }
    }

    @Test("검증 중 삭제한 파일을 추측해서 재생성하지 않는다")
    func removedFileRequiresManualRecovery() throws {
        try fixture { _, recovery, project in
            let result = try transaction(
                project, recovery,
                command: [
                    "/usr/bin/python3", "-c",
                    "from pathlib import Path; Path('A.swift').unlink(); raise SystemExit(1)",
                ]
            ).perform()
            #expect(result.rollback == "restore-failed")
            #expect(!FileManager.default.fileExists(atPath: project + "/A.swift"))
            #expect(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("original-0").path))
        }
    }

    @Test("시간 초과는 자신이 시작한 자식 그룹만 중단하고 복원한다")
    func timeoutStopsOwnedChildren() throws {
        try fixture { root, recovery, project in
            let marker = root.appendingPathComponent("late-write")
            let code =
                "import time,pathlib; time.sleep(0.5); pathlib.Path(\(String(reflecting: marker.path))).write_text('late')"
            let command = [
                "/usr/bin/python3", "-c",
                "import subprocess,time; subprocess.Popen(['/usr/bin/python3','-c',\(String(reflecting: code))]); time.sleep(10)",
            ]
            let result = try transaction(project, recovery, command: command, timeout: 0.1).perform()
            #expect(result.status == "timed-out")
            #expect(result.rollback == "restored")
            Thread.sleep(forTimeInterval: 0.6)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test("과도한 검증 출력은 예산을 넘기면 실패하고 복원한다")
    func boundedOutputRestores() throws {
        try fixture { _, recovery, project in
            let result = try transaction(
                project, recovery, command: ["/usr/bin/python3", "-c", "print('x' * (2 * 1024 * 1024))"]
            ).perform()
            #expect(result.status == "output-limit")
            #expect(result.rollback == "restored")
            #expect(try Data(contentsOf: recovery.appendingPathComponent("verification.stdout")).count <= 1024 * 1024)
        }
    }

    @Test("후속 파일 적용 실패는 앞서 쓴 파일도 복원한다")
    func partialWriteFailureRestoresEarlierFiles() throws {
        try fixture { _, recovery, project in
            let directory = project + "/locked"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
            let paths = [project + "/A.swift", directory + "/B.swift"]
            for path in paths { try Data("original".utf8).write(to: URL(fileURLWithPath: path)) }
            let edits = paths.map {
                PreparedMechanicalEdit(path: $0, original: Data("original".utf8), replacement: Data("edited".utf8))
            }
            let transaction = try MechanicalFixTransaction(
                edits: edits, project: project, fileSystem: LocalFileSystem(),
                verification: .init(arguments: ["/usr/bin/true"], recoveryDirectory: recovery.path))
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
            let result = transaction.perform()
            #expect(result.status == "apply-failed")
            #expect(result.rollback == "restored")
            for path in paths { #expect(try String(contentsOfFile: path, encoding: .utf8) == "original") }
        }
    }

    @Test("적용 전 종료 요청은 검증 명령을 실행하지 않는다")
    func interruptionBeforeApply() throws {
        try fixture { _, recovery, project in
            let result = try transaction(project, recovery, command: ["/usr/bin/true"], interruption: { SIGINT })
                .perform()
            #expect(result.status == "interrupted")
            #expect(result.signal == SIGINT)
            #expect(result.rollback == "restored")
            #expect(
                !FileManager.default.fileExists(atPath: recovery.appendingPathComponent("verification.stdout").path))
        }
    }

    @Test("계획 뒤 바뀐 원본은 쓰지 않고 현재 편집을 보존한다")
    func changedBeforeApplyIsPreserved() throws {
        try fixture { _, recovery, project in
            let transaction = try transaction(project, recovery, command: ["/usr/bin/true"])
            try Data("new user content".utf8).write(to: URL(fileURLWithPath: project + "/A.swift"))
            let result = transaction.perform()
            #expect(result.status == "input-changed")
            #expect(result.rollback == "restored")
            #expect(try String(contentsOfFile: project + "/A.swift", encoding: .utf8) == "new user content")
        }
    }

    @Test("복구 경로의 기존 데이터나 프로젝트 내부 경로는 쓰기 전에 거부한다")
    func recoveryLocationIsChecked() throws {
        try fixture { _, recovery, project in
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            try Data("preserve me".utf8).write(to: recovery.appendingPathComponent("existing"))
            #expect(throws: (any Error).self) {
                _ = try transaction(project, recovery, command: ["/usr/bin/true"])
            }
            #expect(
                try String(contentsOf: recovery.appendingPathComponent("existing"), encoding: .utf8) == "preserve me")
            #expect(throws: (any Error).self) {
                _ = try transaction(project, URL(fileURLWithPath: project + "/recovery"), command: ["/usr/bin/true"])
            }
        }
    }

    @Test("검증 argv의 정규화 형태가 다른 유니코드 바이트를 보존한다")
    func unicodeArgumentsKeepTheirBytes() throws {
        try fixture { _, recovery, project in
            let result = try transaction(
                project, recovery,
                command: [
                    "/usr/bin/python3", "-c",
                    "import sys; assert [a.encode().hex() for a in sys.argv[1:]] == ['c3a9','65cc81']",
                    "\u{e9}", "e\u{301}",
                ]
            ).perform()
            #expect(result.status == "passed")
        }
    }

    @Test("성공 종료 뒤 남긴 자식은 별도 실패로 처리하고 owned 편집을 복원한다")
    func backgroundChildrenFailVerification() throws {
        try fixture { root, recovery, project in
            let marker = root.appendingPathComponent("background-write")
            let code =
                "import time,pathlib; time.sleep(0.5); pathlib.Path(\(String(reflecting: marker.path))).write_text('late')"
            let result = try transaction(
                project, recovery,
                command: [
                    "/usr/bin/python3", "-c",
                    "import subprocess; subprocess.Popen(['/usr/bin/python3','-c',\(String(reflecting: code))])",
                ]
            ).perform()
            #expect(result.status == "background-processes")
            #expect(result.rollback == "restored")
            Thread.sleep(forTimeInterval: 0.6)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test("원본 백업 예산을 넘으면 소스와 복구 디렉터리를 쓰기 전에 거부한다")
    func sourceBudgetFailsBeforeWriting() throws {
        try fixture { _, recovery, project in
            let path = project + "/A.swift"
            try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
            let tooLarge = Data(repeating: 32, count: MechanicalFixVerification.maximumSourceBytes + 1)
            #expect(throws: (any Error).self) {
                _ = try MechanicalFixTransaction(
                    edits: [.init(path: path, original: tooLarge, replacement: Data())],
                    project: project, fileSystem: LocalFileSystem(),
                    verification: .init(arguments: ["/usr/bin/true"], recoveryDirectory: recovery.path))
            }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
            #expect(!FileManager.default.fileExists(atPath: recovery.path))
        }
    }

    @Test("쓰기 뒤 소유 식별을 얻지 못하면 같은 바이트여도 자동 복구하지 않는다", arguments: [false, true])
    func missingAppliedIdentityRequiresManualRecovery(replaceInode: Bool) throws {
        try fixture { _, recovery, project in
            let path = project + "/A.swift"
            let original = Data("original user's bytes".utf8)
            let replacement = Data("Cartograph replacement".utf8)
            try original.write(to: URL(fileURLWithPath: path))
            let fileSystem = LocalFileSystem()
            var injected = false
            var inodeReplaced = false
            let transaction = try MechanicalFixTransaction(
                edits: [.init(path: path, original: original, replacement: replacement)],
                project: project, fileSystem: fileSystem,
                verification: .init(arguments: ["/usr/bin/true"], recoveryDirectory: recovery.path),
                identityReader: { candidate in
                    if !injected, (try? Data(contentsOf: URL(fileURLWithPath: candidate))) == replacement {
                        injected = true
                        if replaceInode {
                            let before = fileSystem.fingerprintStamp(at: candidate)
                            do {
                                try replacement.write(to: URL(fileURLWithPath: candidate), options: .atomic)
                                inodeReplaced = before?.inode != fileSystem.fingerprintStamp(at: candidate)?.inode
                            } catch { Issue.record(error) }
                        }
                        return nil
                    }
                    return fileSystem.fingerprintStamp(at: candidate)
                })
            let result = transaction.perform()
            #expect(injected)
            #expect(!replaceInode || inodeReplaced)
            #expect(result.status == "apply-failed")
            #expect(result.rollback == "conflict")
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == replacement)
            #expect(try Data(contentsOf: recovery.appendingPathComponent("original-0")) == original)
            #expect(!FileManager.default.fileExists(
                atPath: recovery.appendingPathComponent("verification.stdout").path))
            let journal = try JSONSerialization.jsonObject(
                with: Data(contentsOf: recovery.appendingPathComponent("recovery.json"))) as? [String: Any]
            let row = (journal?["files"] as? [[String: Any]])?.first
            #expect(row?["writeAttempted"] as? Bool == true)
            #expect(row?["ownedIdentityAvailable"] as? Bool == false)
        }
    }

    @Test("즉시 종료 직전 꼬리 출력에도 stdout stderr 각각 정확한 바이트 예산을 적용한다",
          arguments: [(1, -1), (1, 0), (1, 1), (2, -1), (2, 0), (2, 1)])
    func immediateExitOutputBoundary(descriptor: Int, delta: Int) throws {
        try fixture { _, recovery, project in
            let maximum = 1024 * 1024
            let command = ["/usr/bin/python3", "-c", """
                import os,sys,time
                fd=int(sys.argv[1]); tail=int(sys.argv[2])+1
                data=memoryview(b'x' * (1024*1024-1))
                while data:
                    data=data[os.write(fd,data):]
                time.sleep(0.15)
                if tail: os.write(fd,b'y' * tail)
                os._exit(0)
                """, String(descriptor), String(delta)]
            let result = try transaction(project, recovery, command: command).perform()
            let log = recovery.appendingPathComponent(descriptor == 1 ? "verification.stdout" : "verification.stderr")
            let count = try Data(contentsOf: log).count
            #expect(count <= maximum)
            if delta <= 0 {
                #expect(result.status == "passed")
                #expect(count == maximum + delta)
            } else {
                #expect(result.status == "output-limit")
                #expect(result.rollback == "restored")
                #expect(try String(contentsOfFile: project + "/A.swift", encoding: .utf8)
                    == "// user's unstaged original\n")
            }
        }
    }
}
