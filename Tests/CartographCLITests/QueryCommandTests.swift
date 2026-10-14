import ArgumentParser
@testable import cartograph
import CartographCore
import CartographKit
import Foundation
import Testing

/// `query` 인자 검증.
///
/// `--since` 는 진단 목록에 거는 범위 렌즈인데 `query` 는 선언 하나에 답하므로
/// 닿을 자리가 없다. 조용히 받으면 비교 실험이 통과할 수밖에 없는 증거가 된다.
/// 거부는 파싱 단계(`validate()`)에서 나며 종료 코드 64 로 끝난다.
@Suite("query 인자 검증")
struct QueryCommandTests {
    @Test("--since 를 받으면 사용 오류를 낸다")
    func sinceIsRejected() {
        do {
            _ = try QueryCommand.parse(["Foo", "--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with query"))
        }
    }

    @Test("배치 질의에서도 --since 를 받으면 사용 오류를 낸다")
    func sinceIsRejectedForBatch() {
        do {
            _ = try QueryCommand.parse(["--batch", "requests.json", "--since", "HEAD"])
            Issue.record("오류가 발생해야 한다")
        } catch {
            #expect("\(error)".contains("--since cannot be combined with query"))
        }
    }

    @Test("--since 없이는 그대로 통과한다")
    func passesWithoutSince() throws {
        let single = try QueryCommand.parse(["Foo"])
        try single.validate()
        let batch = try QueryCommand.parse(["--batch", "requests.json"])
        try batch.validate()
    }

    @Test("일반 파일과 정확히 1 MiB인 파일은 심볼릭 링크를 통해서도 색인 단계까지 간다")
    func acceptsRegularBatchFilesThroughTheByteLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for size in [Data("[\"한글\"]".utf8).count, SymbolQueryBatchRequests.maximumByteCount] {
            let file = directory.appendingPathComponent("requests-\(size).json")
            try requests(byteCount: size).write(to: file)
            let link = directory.appendingPathComponent("linked-\(size).json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            for path in [file.path, link.path] {
                let missingIndex = directory.appendingPathComponent("missing-index").path
                do {
                    try runBatch(at: path, project: directory)
                    Issue.record("없는 색인 오류가 발생해야 한다")
                } catch let error as CartographError {
                    #expect(error == .indexStoreNotFound(searchedPaths: [missingIndex]))
                }
            }
        }
    }

    @Test("상한보다 1 byte 또는 훨씬 큰 배치는 색인 전에 거부하고 파일 전체 크기를 추측하지 않는다")
    func oversizedBatchIsAUsageErrorBeforeOpeningTheIndex() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit = SymbolQueryBatchRequests.maximumByteCount
        for size in [limit + 1, limit * 4] {
            let file = directory.appendingPathComponent("requests-\(size).json")
            try requests(byteCount: size).write(to: file)
            do {
                try runBatch(at: file.path, project: directory)
                Issue.record("상한을 넘는 배치 파일이 통과했다")
            } catch let error as ValidationError {
                let message = String(describing: error)
                #expect(message.contains("the file exceeds \(limit) bytes"))
                #expect(!message.contains("the file is \(limit + 1) bytes"))
                #expect(message.contains(file.path))
            }
        }
    }

    @Test("디렉터리와 장치 파일은 JSON 파싱과 색인 열기 전에 사용 오류로 거부한다")
    func nonRegularBatchFilesAreUsageErrors() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("device-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/null")
        // FIFO 회귀는 verify-cli-contract.sh의 제한 시간 있는 자식 프로세스에서 검증한다.
        for path in [directory.path, "/dev/null", link.path] {
            do {
                try runBatch(at: path, project: directory)
                Issue.record("일반 파일이 아닌 배치 입력이 통과했다")
            } catch let error as ValidationError {
                let message = String(describing: error)
                #expect(message.contains("Cannot read the batch requests at \(path):"))
                #expect(!message.contains("not a JSON array"))
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func requests(byteCount: Int) -> Data {
        var data = Data("[\"한글\"]".utf8)
        data.append(Data(repeating: 0x20, count: byteCount - data.count))
        return data
    }

    private func runBatch(at path: String, project: URL) throws {
        let command = try QueryCommand.parse([
            "--batch", path, "--project", project.path,
            "--index-store", project.appendingPathComponent("missing-index").path,
        ])
        try command.run(diagnosticEnvironment: [:], diagnosticSink: .standardError)
    }
}
