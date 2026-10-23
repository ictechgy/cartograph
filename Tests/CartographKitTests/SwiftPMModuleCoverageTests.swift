import CartographCore
@testable import CartographKit
import CartographTestSupport
import Foundation
import Testing

@Suite("SwiftPM 로컬 모듈 기대 범위와 관측의 구분")
struct SwiftPMModuleCoverageTests {
    private let store = "/p/.build/triple/debug/index/store"
    private let metadata = "/p/.build/triple/debug/description.json"

    @Test("선택 인덱스에 묶인 실재 로컬 소스의 미관측만 이름을 붙인다")
    func localMissingAndCompleteControl() throws {
        let fs = try fixture()
        let missing = notes(fs, dates: [:])
        #expect(missing.count == 1)
        #expect(missing[0].contains("\"Lib\": missing-observed-source-units"))
        #expect(missing[0].contains("freshness are unverified"))
        #expect(!missing[0].contains("SDK"))
        #expect(notes(fs, dates: ["/p/Lib.swift": Date()]).isEmpty)
    }

    @Test("다른 인덱스 명령이나 SDK·binary의 소스 부재를 missing module로 만들지 않는다")
    func unrelatedBuildAndExternalSourcesRemainUnknown() throws {
        let fs = try fixture(index: "/other/index/store")
        #expect(notes(fs, dates: [:]).first?.hasPrefix("build-module-coverage-unknown:") == true)
        #expect(notes(fs, dates: [:]).allSatisfy { !$0.contains("missing-observed") })
        let external = try fixture(sources: ["/sdk/SDK.swift", "/p/Absent.swift"])
        #expect(notes(external, dates: [:]).first?.contains("no local Swift source command") == true)
    }

    @Test("필터 밖 파일과 source unit 관측 불가는 누락된 target으로 승격하지 않는다")
    func outsideAndUnavailableAreDistinct() throws {
        let fs = try fixture()
        let outside = notes(fs, paths: [], dates: [:])
        #expect(outside.first?.contains("outside-analysis") == true)
        #expect(outside.first?.contains("without observed unit timestamp 0") == true)
        #expect(notes(fs, dates: nil).first?.contains("timestamps unavailable") == true)
    }

    @Test("범위 안 소스가 모두 관측되면 일부 범위 밖 소스를 missing unit이라 부르지 않는다")
    func partiallyExcludedModuleWithCompleteObservedSubset() throws {
        let fs = try fixture(sources: ["/p/Lib.swift", "/p/Generated.swift"])
        try fs.write(text: "struct Generated {}", to: "/p/Generated.swift")
        let complete = notes(fs, dates: ["/p/Lib.swift": Date()])
        #expect(complete.first?.contains("\"Lib\": outside-analysis") == true)
        #expect(complete.first?.contains("outside analysis 1, without observed unit timestamp 0") == true)
        #expect(complete.allSatisfy { !$0.contains("missing-observed-source-units") })
        #expect(notes(fs, dates: [:]).first?.contains("missing-observed-source-units") == true)
    }

    @Test("상충하는 동명 모듈의 source 집합은 임의로 합쳐 확정하지 않는다")
    func conflictingCommandsRemainUnknown() throws {
        let fs = try fixture()
        try fs.write(text: "struct Other {}", to: "/p/Other.swift")
        let data = try JSONSerialization.data(withJSONObject: ["swiftCommands": [
            "first": command(sources: ["/p/Lib.swift"], index: store),
            "second": command(sources: ["/p/Other.swift"], index: store)
        ]])
        try fs.write(data, to: metadata)
        #expect(notes(fs, dates: [:]).first?.contains("unknown conflicting command") == true)
        #expect(notes(fs, dates: [:]).allSatisfy { !$0.contains("missing-observed") })
    }

    @Test("손상·크기 초과·읽기 실패·알 수 없는 schema는 unknown이다", arguments: ["corrupt", "oversize", "read", "schema"])
    func malformedMetadataIsNotCoverage(mode: String) throws {
        let fs = try fixture()
        switch mode {
        case "corrupt": try fs.write(text: "{", to: metadata)
        case "oversize": try fs.write(Data(repeating: 32, count: SwiftPMModuleCoverage.maximumBytes + 1), to: metadata)
        case "read": fs.setReadError(.fileReadNoPermission, for: metadata)
        default: try fs.write(text: "{\"targets\": []}", to: metadata)
        }
        #expect(notes(fs, dates: [:]).first?.hasPrefix("build-module-coverage-unknown:") == true)
    }

    @Test("Xcode·out·프로젝트 밖 표준 index는 설명을 임의 탐색하지 않는다")
    func onlyAdjacentLocalDescription() {
        let fs = InMemoryFileSystem()
        for path in ["/p/.build/out", "/DerivedData/Index.noindex/DataStore", "/other/debug/index/store"] {
            #expect(SwiftPMModuleCoverage.descriptionPath(storePath: path, projectPath: "/p", fileSystem: fs) == nil)
        }
        #expect(SwiftPMModuleCoverage.descriptionPath(storePath: store, projectPath: "/p", fileSystem: fs) == metadata)
    }

    @Test("build metadata 변경도 세션 입력 지문을 바꾼다")
    func metadataChangeInvalidatesFingerprint() throws {
        let fs = try fixture()
        let service = CartographService(configuration: .init(indexStorePath: store, projectPath: "/p"),
            environment: .init(fileSystem: fs, indexProviderOverride: StaticIndexProvider(IndexSnapshot()),
                               usesSyntaxCache: false))
        let before = try service.sessionInputFingerprint()
        try fs.write(text: "{}", to: metadata)
        #expect(try service.sessionInputFingerprint() != before)
    }

    @Test("metadata보다 새로운 소스와 루트 밖 metadata 링크는 확정 누락으로 읽지 않는다")
    func staleAndExternalMetadata() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("module-coverage-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try manager.removeItem(at: root) }
            catch { Issue.record("임시 module coverage 입력 정리 실패: \(error)") }
        }
        let fs = LocalFileSystem()
        let project = root.appendingPathComponent("project").path
        let index = project + "/.build/triple/debug/index/store"
        let description = project + "/.build/triple/debug/description.json"
        try manager.createDirectory(atPath: index, withIntermediateDirectories: true)
        let source = project + "/Lib.swift"
        try fs.write(text: "struct Lib {}", to: source)
        let bytes = try JSONSerialization.data(withJSONObject: ["swiftCommands": [
            "Lib": command(sources: [source], index: index)
        ]])
        try fs.write(bytes, to: description)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: description)
        let warnings = SwiftPMModuleCoverage(fileSystem: fs).limitations(storePath: index, projectPath: project,
            sourcePaths: [source], snapshot: IndexSnapshot(indexedFileDates: [:]))
        #expect(warnings.first?.contains("stale-metadata-expectation") == true)
        #expect(warnings.allSatisfy { !$0.contains("missing-observed-source-units") })
        let outside = root.appendingPathComponent("outside.json").path
        try fs.write(bytes, to: outside)
        try manager.removeItem(atPath: description)
        try manager.createSymbolicLink(atPath: description, withDestinationPath: outside)
        #expect(SwiftPMModuleCoverage.descriptionPath(storePath: index, projectPath: project, fileSystem: fs) == nil)
    }

    @Test("모듈 경고와 경로 예시는 유한하고 생략 수를 남긴다")
    func boundedDiagnosticOutput() throws {
        let fs = try fixture()
        var commands: [String: [String: Any]] = [:]
        for index in 0..<25 {
            let name = "Module\(index)"
            var value = command(sources: ["/p/Lib.swift"], index: store)
            value["moduleName"] = name
            commands[name] = value
        }
        try fs.write(JSONSerialization.data(withJSONObject: ["swiftCommands": commands]), to: metadata)
        let result = notes(fs, dates: [:])
        #expect(result.count == 1)
        #expect(result[0].contains("omitted modules: 5"))
        #expect(result[0].utf8.count < 8000)
    }

    @Test("무효 명령도 다른 정상 모듈 관측 뒤 조용히 사라지지 않는다")
    func invalidCommandRemainsUnknown() throws {
        let fs = try fixture()
        var invalid = command(sources: ["/p/Lib.swift"], index: store)
        invalid["moduleName"] = String(repeating: "L", count: 257)
        try fs.write(JSONSerialization.data(withJSONObject: ["swiftCommands": [
            "ok": command(sources: ["/p/Lib.swift"], index: store), "invalid": invalid
        ]]), to: metadata)
        let warnings = notes(fs, dates: ["/p/Lib.swift": Date()])
        #expect(warnings.first?.contains("unknown invalid/budget-limited commands: 1") == true)
    }

    @Test("세션 지문도 metadata 상한을 지키며 대형 stamp이면 내용을 읽지 않는다", arguments: [false, true])
    func fingerprintReadIsBounded(oversized: Bool) throws {
        let fs = BoundedMetadataFileSystem(base: try fixture(), metadata: metadata, oversized: oversized)
        let service = CartographService(configuration: .init(indexStorePath: store, projectPath: "/p"),
            environment: .init(fileSystem: fs, indexProviderOverride: StaticIndexProvider(IndexSnapshot()),
                               usesSyntaxCache: false))
        _ = try service.sessionInputFingerprint()
        #expect(fs.unboundedMetadataReads == 0)
        #expect(fs.metadataBudgets == (oversized ? [] : [SwiftPMModuleCoverage.maximumBytes]))
    }

    private func command(sources: [String], index: String) -> [String: Any] {
        ["moduleName": "Lib", "sources": sources, "otherArguments": ["-index-store-path", index]]
    }

    private func fixture(sources: [String] = ["/p/Lib.swift"], index: String? = nil) throws -> InMemoryFileSystem {
        let fs = InMemoryFileSystem(files: ["/p/Lib.swift": "struct Lib {}", "/sdk/SDK.swift": "struct SDK {}"])
        let data = try JSONSerialization.data(withJSONObject: ["swiftCommands": [
            "Lib": command(sources: sources, index: index ?? store),
            "SDK": ["moduleName": "SDK", "sources": [String](), "otherArguments": ["-index-store-path", store]]
        ]])
        try fs.write(data, to: metadata)
        return fs
    }

    private func notes(_ fs: any FileSystem, paths: [String] = ["/p/Lib.swift"], dates: [String: Date]?) -> [String] {
        SwiftPMModuleCoverage(fileSystem: fs).limitations(storePath: store, projectPath: "/p",
            sourcePaths: paths, snapshot: IndexSnapshot(indexedFileDates: dates))
    }
}

private final class BoundedMetadataFileSystem: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    let metadata: String
    let oversized: Bool
    var unboundedMetadataReads = 0
    var metadataBudgets: [Int] = []
    init(base: InMemoryFileSystem, metadata: String, oversized: Bool) {
        self.base = base; self.metadata = metadata; self.oversized = oversized
    }
    var currentDirectoryPath: String { base.currentDirectoryPath }
    func realPath(at path: String) throws -> String { try base.realPath(at: path) }
    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func directoryExists(at path: String) -> Bool { base.directoryExists(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    func write(_ data: Data, to path: String) throws { try base.write(data, to: path) }
    func readData(at path: String) throws -> Data {
        if path == metadata { unboundedMetadataReads += 1; throw CocoaError(.fileReadUnknown) }
        return try base.readData(at: path)
    }
    func readData(at path: String, maximumBytes: Int) throws -> Data {
        if path == metadata { metadataBudgets.append(maximumBytes) }
        return try base.readData(at: path, maximumBytes: maximumBytes)
    }
    func fingerprintStamp(at path: String) -> FileFingerprintStamp? {
        guard oversized, path == metadata else { return nil }
        return .init(resolvedPath: path, device: 1, inode: 1,
            size: UInt64(SwiftPMModuleCoverage.maximumBytes + 100), modificationSeconds: 1,
            modificationNanoseconds: 0, changeSeconds: 1, changeNanoseconds: 0, mode: 0o100644)
    }
}
