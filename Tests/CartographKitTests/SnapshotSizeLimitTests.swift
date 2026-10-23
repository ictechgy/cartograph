import CartographCore
import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("스냅샷 파일 크기 예산", .serialized)
struct SnapshotSizeLimitTests {
    private func document(revision: String? = nil) -> AnalysisSnapshotDocument {
        var builder = SnapshotBuilder(path: "/p/App.swift")
        builder.symbol("App", kind: .structType)
        return AnalysisSnapshotDocument(projectRoot: "/p", revision: revision, snapshot: builder.build())
    }

    @Test("쓰기와 읽기는 끝 줄바꿈까지 같은 바이트 예산을 적용한다")
    func exactByteBoundary() throws {
        let original = document()
        let data = try original.encoded()
        #expect(data.last == 10)
        #expect(try original.encoded(maximumBytes: data.count) == data)
        #expect(try AnalysisSnapshotDocument.decode(from: data, maximumBytes: data.count) == original)
        #expect(throws: (any Error).self) { try original.encoded(maximumBytes: data.count - 1) }
        #expect(throws: (any Error).self) {
            try AnalysisSnapshotDocument.decode(from: data, maximumBytes: data.count - 1)
        }
    }

    @Test("불가능한 예산은 디코딩이나 인코딩 전에 거부한다")
    func rejectsInvalidBudgets() throws {
        let original = document()
        let data = try original.encoded()
        for limit in [Int.min, -1, 0, AnalysisSnapshotDocument.maximumSupportedByteCount + 1, Int.max] {
            #expect(throws: (any Error).self) { try original.encoded(maximumBytes: limit) }
            #expect(throws: (any Error).self) {
                try AnalysisSnapshotDocument.decode(from: data, maximumBytes: limit)
            }
        }
        try AnalysisSnapshotDocument.validateMaximumBytes(AnalysisSnapshotDocument.maximumSupportedByteCount)
    }

    @Test("한도를 늘려도 손상·잘림·압축 파일이나 알 수 없는 버전을 받아들이지 않는다")
    func rejectsMalformedAndCompressedInputs() throws {
        let original = try document().encoded()
        let object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var unsupported = object
        unsupported["version"] = 999
        // gzip.compress(b"{}", mtime=0): 유효한 gzip도 압축 해제하지 않는다.
        let gzip = Data([31, 139, 8, 0, 0, 0, 0, 0, 2, 10, 171, 174, 5, 0, 67, 191, 166, 163, 2, 0, 0, 0])
        for data in [Data(original.dropLast(2)), Data("{broken}".utf8), Data([0xff]),
                     gzip, Data([0x50, 0x4b, 0x03, 0x04]),
                     try JSONSerialization.data(withJSONObject: unsupported)] {
            #expect(throws: (any Error).self) {
                try AnalysisSnapshotDocument.decode(from: data,
                    maximumBytes: AnalysisSnapshotDocument.maximumSupportedByteCount)
            }
        }
        var legacy = object
        legacy["version"] = 1
        let restored = try AnalysisSnapshotDocument.decode(
            from: JSONSerialization.data(withJSONObject: legacy), maximumBytes: 1024 * 1024)
        #expect(restored.version == 1)
        #expect(restored.limitations.contains(AnalysisSnapshotDocument.missingRuntimeDiscoveryLimitation))
        #expect(restored.snapshot == document().snapshot)
    }

    @Test("실제 128 MiB 초과 JSON 파일은 기본값으로 거부되고 명시적 예산으로 왕복한다")
    func roundTripsFileLargerThanPreviousHardLimit() throws {
        // 크기 경계만 검증하는 합성 데이터이며 앱 그래프의 정확도나 최대 RSS 측정이 아니다.
        let payloadBytes = AnalysisSnapshotDocument.maximumByteCount + 1
        let original = document(revision: String(repeating: "x", count: payloadBytes))
        let limit = 129 * 1024 * 1024
        let encoded = try original.encoded(maximumBytes: limit)
        #expect(encoded.count > AnalysisSnapshotDocument.maximumByteCount)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-large-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("임시 스냅샷 정리 실패: \(error)") }
        }
        let path = directory.appendingPathComponent("before.json").path
        let fs = LocalFileSystem()
        try fs.write(encoded, to: path)
        #expect(throws: (any Error).self) { try original.encoded() }
        #expect(throws: (any Error).self) { try AnalysisSnapshotDocument.decode(from: encoded) }
        let read = try fs.readData(at: path, maximumBytes: limit)
        let restored = try AnalysisSnapshotDocument.decode(from: read, maximumBytes: limit)
        #expect(restored.revision?.utf8.count == payloadBytes)
        #expect(restored.snapshot == original.snapshot)
        #expect(try restored.encoded(maximumBytes: limit).elementsEqual(encoded))
        print("Snapshot size regression: \(encoded.count) bytes round-tripped with \(limit) byte limit; default rejected.")
    }

    @Test("과거 비교 서비스도 명시적 바이트 예산을 사용한다")
    func comparisonUsesRequestedBudget() throws {
        let snapshot = document()
        let data = try snapshot.encoded()
        let fs = InMemoryFileSystem()
        try fs.write(data, to: "/p/before.json")
        let service = CartographService(configuration: .init(projectPath: "/p"),
            environment: .init(fileSystem: fs, indexProviderOverride: StaticIndexProvider(snapshot.snapshot)))
        #expect(throws: (any Error).self) {
            try service.compareImpact(symbols: ["App"], files: [], beforePath: "/p/before.json",
                maxDepth: nil, limit: 20, format: "json", snapshotMaximumBytes: data.count - 1)
        }
        let result = try service.compareImpact(symbols: ["App"], files: [], beforePath: "/p/before.json",
            maxDepth: nil, limit: 20, format: "json", snapshotMaximumBytes: data.count)
        #expect(!result.subjectNotFound)
        #expect(result.incompleteAnalysis == nil)
    }
}
