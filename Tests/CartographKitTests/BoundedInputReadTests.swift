import CartographCore
@testable import CartographKit
import CartographTestSupport
import CryptoKit
import Foundation
import Testing

/// 저장소가 통제하는 큰 입력(링크로 끌어온 시스템 파일 포함)이 크기 검사 전에 통째로 메모리에 올라가지 않는지.
///
/// 크기 상한이 메모리 상한 역할을 하려면 읽기 자체가 상한+1 바이트에서 멈춰야 한다. 결과 문구만 보는
/// 테스트는 통째로 읽은 뒤 거부하는 구현도 통과시키므로, 실제 디스크 읽기를 기록해 읽은 양을 단언한다.
@Suite("분석 입력 읽기 상한")
struct BoundedInputReadTests {
    private static let mebibyte = 1 << 20

    @Test("런타임 리소스는 8 MiB 상한을 넘는 파일을 통째로 읽지 않고 기존 한계 문구로 알린다")
    func runtimeResourceReadStopsAtLimit() throws {
        let root = try makeProject()
        defer { removeProject(root) }
        let storyboard = root + "/App/Base.lproj/Main.storyboard"
        try makeSparseFile(at: storyboard, byteCount: 64 * Self.mebibyte)
        let fileSystem = ReadRecordingFileSystem()

        let facts = makeService(fileSystem: fileSystem, root: root).runtimeResourceFacts(paths: [storyboard])

        #expect(facts.map(\.limitations) == [
            ["runtime-resource-unreadable: invalid or oversized XML at \(storyboard)"],
        ])
        #expect(fileSystem.unboundedReads.isEmpty)
        #expect(fileSystem.boundedReads == [
            .init(path: storyboard, maximumBytes: 8 * Self.mebibyte, byteCount: 8 * Self.mebibyte + 1),
        ])
    }

    @Test("실행 근거는 2 MiB 상한을 넘으면 통째로 읽지 않고 같은 오류로 거부한다")
    func runtimeEvidenceReadStopsAtLimit() throws {
        let root = try makeProject()
        defer { removeProject(root) }
        let path = root + "/runtime-contracts.json"
        try makeSparseFile(at: path, byteCount: 64 * Self.mebibyte)
        let fileSystem = ReadRecordingFileSystem()

        #expect(throws: CartographError.invalidConfiguration(
            path: path, reason: "Runtime evidence exceeds 2 MiB. Split the scenario set into smaller documents."
        )) {
            try RuntimeEvidenceStore(fileSystem: fileSystem).contracts(at: path)
        }
        #expect(fileSystem.unboundedReads.isEmpty)
        #expect(fileSystem.boundedReads == [
            .init(path: path, maximumBytes: 2 * Self.mebibyte, byteCount: 2 * Self.mebibyte + 1),
        ])
    }

    @Test("Core Data 생성 소스는 4 MiB 상한을 넘으면 통째로 읽지 않고 같은 오류로 거부한다")
    func generatedSourceReadStopsAtLimit() throws {
        let root = try makeProject()
        defer { removeProject(root) }
        let path = root + "/Generated/Record+CoreDataClass.swift"
        try makeSparseFile(at: path, byteCount: 64 * Self.mebibyte)
        let fileSystem = ReadRecordingFileSystem()

        #expect(throws: CartographError.invalidConfiguration(
            path: path, reason: "Generated source must be UTF-8 and no larger than 4 MiB."
        )) {
            try makeService(fileSystem: fileSystem, root: root).generatedSource(at: path)
        }
        #expect(fileSystem.unboundedReads.isEmpty)
        #expect(fileSystem.boundedReads == [
            .init(path: path, maximumBytes: 4 * Self.mebibyte, byteCount: 4 * Self.mebibyte + 1),
        ])
    }

    @Test("세션 지문은 큰 입력을 통째로 읽지 않고 1 MiB 조각으로 해시해 같은 크기·시각의 내용 변경도 잡는다")
    func fingerprintHashesLargeInputInChunks() throws {
        let root = try makeProject()
        defer { removeProject(root) }
        let source = root + "/Big.swift"
        let byteCount = 5 * Self.mebibyte / 2
        try Data(repeating: 0x20, count: byteCount).write(to: URL(fileURLWithPath: source))
        let fileSystem = ReadRecordingFileSystem()
        let service = makeService(fileSystem: fileSystem, root: root, source: source)

        let first = try service.sessionInputFingerprint()

        #expect(!fileSystem.unboundedReads.contains(source))
        let chunks = fileSystem.chunkSizes(for: source)
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0 <= Self.mebibyte })
        #expect(chunks.reduce(0, +) == byteCount)

        // 크기와 수정 시각이 같아도 가운데 한 바이트가 바뀌면 내용 digest 가 지문을 바꿔야 한다.
        let modified = try #require(fileSystem.modificationDate(at: source))
        var changed = Data(repeating: 0x20, count: byteCount)
        changed[byteCount / 2] = 0x41
        try changed.write(to: URL(fileURLWithPath: source))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source)
        #expect(try service.sessionInputFingerprint() != first)
    }

    @Test("세션 캐시 경로의 지문도 큰 입력을 조각으로 해시한다")
    func cachedFingerprintHashesLargeInputInChunks() throws {
        let root = try makeProject()
        defer { removeProject(root) }
        let source = root + "/Big.swift"
        let byteCount = 5 * Self.mebibyte / 2
        try Data(repeating: 0x20, count: byteCount).write(to: URL(fileURLWithPath: source))
        let fileSystem = ReadRecordingFileSystem()

        _ = try AnalysisSession(service: makeService(fileSystem: fileSystem, root: root, source: source))

        // 세션은 지문을 캐시 래퍼로 읽는다. 래퍼가 조각 읽기를 넘기지 않으면 통째로 읽게 된다.
        let chunks = fileSystem.chunkSizes(for: source)
        #expect(chunks.allSatisfy { $0 <= Self.mebibyte })
        #expect(chunks.reduce(0, +) == byteCount)
    }

    @Test("런타임 계획은 실행 파일을 통째로 읽지 않고 1 MiB 조각으로 해시한 표준 SHA-256 을 싣는다")
    func runtimePlanHashesExecutableInChunks() throws {
        let root = try makeProject()
        defer { removeProject(root) }
        let executable = root + "/App"
        // 조각 순서나 경계가 틀리면 값이 바뀌도록 바이트를 고르게 섞는다.
        let contents = Data((0..<(5 * Self.mebibyte / 2)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 12) })
        try contents.write(to: URL(fileURLWithPath: executable))
        let fileSystem = ReadRecordingFileSystem()

        let plan = try makeService(fileSystem: fileSystem, root: root)
            .runtimePlan(contracts: Self.contracts, executablePath: executable)

        #expect(plan.executableFingerprint == SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined())
        #expect(!fileSystem.unboundedReads.contains(executable))
        let chunks = fileSystem.chunkSizes(for: executable)
        #expect(chunks.allSatisfy { $0 <= Self.mebibyte })
        // 계획을 만들 때와 결과를 내기 전 재확인에서 한 번씩 해시한다.
        #expect(chunks.reduce(0, +) == 2 * contents.count)
    }

    @Test("정규 파일이 아닌 실행 파일 경로는 조각으로 읽어도 예전과 같은 읽기 오류로 거부한다")
    func runtimePlanRejectsNonRegularExecutablesAsBefore() throws {
        let root = try makeProject()
        defer { removeProject(root) }
        let service = makeService(fileSystem: ReadRecordingFileSystem(), root: root)

        // 통째 읽기(`Data(contentsOf:)`)도 정규 파일만 읽어 장치를 이 오류로 거부했다. 조각 읽기도 같은 입력만 받는다.
        #expect(throws: CartographError.invalidConfiguration(
            path: "/dev/null", reason: "The executable could not be read. Check its path and permissions."
        )) {
            try service.runtimePlan(contracts: Self.contracts, executablePath: "/dev/null")
        }
    }

    @Test("조각 읽기는 넘긴 조각을 다음 조각 전에 놓아 큰 파일을 읽어도 메모리가 조각 크기 안팎으로 묶인다")
    func chunkedReadReleasesEachChunk() throws {
        let root = try makeProject()
        defer { removeProject(root) }
        let path = root + "/Large.bin"
        let byteCount = 512 * Self.mebibyte
        try makeSparseFile(at: path, byteCount: byteCount)
        let start = try Self.physicalFootprint()
        var peak = start
        var total = 0

        try LocalFileSystem().readChunks(at: path, chunkSize: Self.mebibyte) { chunk in
            total += chunk.count
            if total % (32 * Self.mebibyte) == 0 { peak = max(peak, try Self.physicalFootprint()) }
        }

        #expect(total == byteCount)
        // 조각이 autorelease 로 루프 끝까지 남으면 읽은 만큼(512 MiB 가까이) 는다.
        // 병렬로 도는 다른 테스트 몫은 넉넉히 둔다.
        #expect(peak - start < UInt64(128 * Self.mebibyte))
    }

    private static let contracts = RuntimeContractsDocument(contracts: [
        .init(id: "open", target: "App", mechanism: .selector, requiredScenarios: ["launch"]),
    ])

    /// 지금 프로세스의 물리 메모리 사용량(phys_footprint). 최고점(`ru_maxrss`)이 아니라 현재 값이라
    /// 앞서 돈 테스트가 남긴 최고점에 가려지지 않는다.
    private static func physicalFootprint() throws -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return info.ri_phys_footprint
    }

    private func makeProject() throws -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartograph-bounded-read-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        // 탐색은 실제 경로 철자로 열거하므로 기대 경로도 같은 철자로 만든다.
        return try LocalFileSystem().realPath(at: base)
    }

    private func removeProject(_ root: String) {
        do { try FileManager.default.removeItem(atPath: root) }
        catch { Issue.record("임시 프로젝트를 지우지 못했다: \(error)") }
    }

    /// 디스크를 실제로 채우지 않는 희소 파일. 통째로 읽으면 그 크기만큼 메모리를 쓴다.
    private func makeSparseFile(at path: String, byteCount: Int) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }

    private func makeService(
        fileSystem: ReadRecordingFileSystem, root: String, source: String? = nil
    ) -> CartographService {
        var configuration = CartographConfiguration.default
        configuration.projectPath = root
        configuration.indexStorePath = root + "/index-store"
        var builder = SnapshotBuilder(path: source ?? root + "/App.swift")
        builder.symbol("App", kind: .structType)
        return CartographService(
            configuration: configuration,
            environment: CartographEnvironment(
                fileSystem: fileSystem, indexProviderOverride: StaticIndexProvider(builder.build())
            )
        )
    }
}

/// 실제 디스크를 그대로 읽으면서 상한 없는 읽기·상한 있는 읽기·조각 읽기를 따로 기록한다.
private final class ReadRecordingFileSystem: FileSystem, ChunkedFileReading, @unchecked Sendable {
    struct BoundedRead: Equatable {
        let path: String
        let maximumBytes: Int
        let byteCount: Int
    }

    private let base = LocalFileSystem()
    private let lock = NSLock()
    private var unbounded: [String] = []
    private var bounded: [BoundedRead] = []
    private var chunks: [String: [Int]] = [:]

    var unboundedReads: [String] { lock.withLock { unbounded } }
    var boundedReads: [BoundedRead] { lock.withLock { bounded } }
    func chunkSizes(for path: String) -> [Int] { lock.withLock { chunks[path] ?? [] } }

    func readData(at path: String) throws -> Data {
        lock.withLock { unbounded.append(path) }
        return try base.readData(at: path)
    }

    func readData(at path: String, maximumBytes: Int) throws -> Data {
        let data = try base.readData(at: path, maximumBytes: maximumBytes)
        lock.withLock { bounded.append(.init(path: path, maximumBytes: maximumBytes, byteCount: data.count)) }
        return data
    }

    func readChunks(at path: String, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        try base.readChunks(at: path, chunkSize: chunkSize) { chunk in
            lock.withLock { chunks[path, default: []].append(chunk.count) }
            try consume(chunk)
        }
    }

    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func removeItem(at path: String) throws { try base.removeItem(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    func directoryEntries(at path: String) throws -> [DirectoryEntry] { try base.directoryEntries(at: path) }
    func modificationDate(at path: String) -> Date? { base.modificationDate(at: path) }
    func fingerprintStamp(at path: String) -> FileFingerprintStamp? { base.fingerprintStamp(at: path) }
    func directoryListingStamp(at path: String) -> DirectoryListingStamp? { base.directoryListingStamp(at: path) }
    var currentDirectoryPath: String { base.currentDirectoryPath }
}
