import CartographCore
@testable import CartographIndexStore
import Foundation
import IndexStoreDB
import Testing

// 이 파일과 세 판독기 사본은 버려지는 검증 checkout의 테스트 타깃에만 넣는다.
struct DependencyMetadataCounts: Codable, Equatable {
    var dependencies = 0
    var recordOrFile = 0
    var admittedContexts = 0
    var admittedRecords = 0
    var pathStrings = 0
    var moduleStrings = 0
    var nameStrings = 0
    var systemReads = 0

    mutating func path(_ value: String) -> String { pathStrings += 1; return value }
    mutating func module(_ value: String) -> String { moduleStrings += 1; return value }
    mutating func name(_ value: String) -> String { nameStrings += 1; return value }
    mutating func system(_ value: Bool) -> Bool { systemReads += 1; return value }
}

private struct DependencyParityEvidence: Encodable {
    let schema: String
    let eager: DependencyMetadataCounts
    let streaming: DependencyMetadataCounts
    let eagerCacheOpenEvents: Int
    let streamingCacheOpenEvents: Int
}

private struct DependencyTrackedPath: Equatable {
    let path: String
    let tracked: Bool
}

private func expectDependencySymbol(_ actual: Symbol, _ expected: Symbol) {
    // 라이브러리 Equatable이 USR만 비교하더라도 메타데이터 누락을 감추지 않는다.
    #expect(actual.usr == expected.usr)
    #expect(actual.name == expected.name)
    #expect(actual.kind == expected.kind)
    #expect(actual.subKind == expected.subKind)
    #expect(actual.properties.rawValue == expected.properties.rawValue)
    #expect(actual.language == expected.language)
}

private func expectDependencyRawResult(_ actual: RawReadResult, _ expected: RawReadResult) {
    #expect(actual.indexedFileDates == expected.indexedFileDates)
    #expect(actual.oldestIndexedFileDates == expected.oldestIndexedFileDates)
    #expect(actual.admittedHeaderPaths == expected.admittedHeaderPaths)
    #expect(actual.occurrences.count == expected.occurrences.count)
    for (a, b) in zip(actual.occurrences, expected.occurrences) {
        expectDependencySymbol(a.symbol, b.symbol)
        #expect(a.roles.rawValue == b.roles.rawValue)
        #expect(a.symbolProvider == b.symbolProvider)
        #expect(a.location.path == b.location.path)
        #expect(a.location.timestamp == b.location.timestamp)
        #expect(a.location.moduleName == b.location.moduleName)
        #expect(a.location.isSystem == b.location.isSystem)
        #expect(a.location.line == b.location.line)
        #expect(a.location.utf8Column == b.location.utf8Column)
        #expect(a.relations.count == b.relations.count)
        for (ar, br) in zip(a.relations, b.relations) {
            expectDependencySymbol(ar.symbol, br.symbol)
            #expect(ar.roles.rawValue == br.roles.rawValue)
        }
    }
}

private func dependencySnapshot(
    _ result: RawReadResult, external: Bool, selfReferences: Bool
) -> IndexSnapshot {
    var snapshot = IndexStoreProvider.snapshot(from: result.occurrences,
        includeExternalSymbols: external, includeSelfReferences: selfReferences)
    snapshot.indexedFileDates = result.indexedFileDates
    snapshot.oldestIndexedFileDates = result.oldestIndexedFileDates
    snapshot.admittedHeaderPaths = result.admittedHeaderPaths
    return snapshot
}

private func expectDependencySnapshots(_ actual: RawReadResult, _ expected: RawReadResult) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for external in [false, true] {
        for selfReferences in [false, true] {
            let a = dependencySnapshot(actual, external: external, selfReferences: selfReferences)
            let b = dependencySnapshot(expected, external: external, selfReferences: selfReferences)
            // 배열을 정렬하거나 Set으로 접지 않는다. 같은 발생 순서의 전체 값을 비교한다.
            #expect(a == b)
            #expect(a.sourceFreshnessDates == b.sourceFreshnessDates)
            #expect(try encoder.encode(a) == encoder.encode(b))
        }
    }
}

private func expectDependencyOutcome(
    _ actual: Result<RawReadResult, any Error>, _ expected: Result<RawReadResult, any Error>
) throws {
    switch (actual, expected) {
    case (.success(let a), .success(let b)):
        expectDependencyRawResult(a, b)
        try expectDependencySnapshots(a, b)
    case (.failure(let a), .failure(let b)):
        #expect(a.localizedDescription == b.localizedDescription)
    default:
        Issue.record("The eager and streaming readers disagree on success versus failure.")
    }
}

private struct DependencyStoreFile: Equatable {
    let bytes: Data
    let modified: Date?
}

private func dependencyStoreFiles(_ path: String) throws -> [String: DependencyStoreFile] {
    let root = URL(fileURLWithPath: path)
    let enumerator = try #require(FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]))
    var files: [String: DependencyStoreFile] = [:]
    for case let file as URL in enumerator {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        if values.isRegularFile == true {
            files[file.path] = DependencyStoreFile(bytes: try Data(contentsOf: file),
                modified: values.contentModificationDate)
        }
    }
    return files
}

struct DependencyParityRawReader {
    let storePath: String
    let libraryPath: String
    let fileSystem: any FileSystem

    func read(
        in paths: Set<String>, trackedSourcePath: ((String) -> Bool)? = nil,
        includeProjectHeaderRecords: Bool = false,
        recordCachePeak: ((Int, Int) -> Void)? = nil
    ) throws -> RawReadResult {
        let before = try dependencyStoreFiles(storePath)
        var eagerPaths: [DependencyTrackedPath] = []
        var streamingPaths: [DependencyTrackedPath] = []
        var eagerOpens: [[Int]] = []
        var streamingOpens: [[Int]] = []
        let eagerTracked: ((String) -> Bool)? = trackedSourcePath.map { predicate in
            { path in
                let tracked = predicate(path)
                eagerPaths.append(DependencyTrackedPath(path: path, tracked: tracked))
                return tracked
            }
        }
        let streamingTracked: ((String) -> Bool)? = trackedSourcePath.map { predicate in
            { path in
                let tracked = predicate(path)
                streamingPaths.append(DependencyTrackedPath(path: path, tracked: tracked))
                return tracked
            }
        }
        let eager = Result {
            try EagerDependencyRawIndexStoreReader(storePath: storePath, libraryPath: libraryPath,
                fileSystem: fileSystem).read(in: paths, trackedSourcePath: eagerTracked,
                    includeProjectHeaderRecords: includeProjectHeaderRecords,
                    recordCachePeak: { eagerOpens.append([$0, $1]) })
        }
        let streaming = Result {
            try RawIndexStoreReader(storePath: storePath, libraryPath: libraryPath,
                fileSystem: fileSystem).read(in: paths, trackedSourcePath: streamingTracked,
                    includeProjectHeaderRecords: includeProjectHeaderRecords,
                    recordCachePeak: {
                        streamingOpens.append([$0, $1])
                        recordCachePeak?($0, $1)
                    })
        }
        try expectDependencyOutcome(streaming, eager)
        #expect(streamingPaths == eagerPaths)
        // 기존 callback은 매 cache miss의 성공한 store.record open마다 호출된다.
        #expect(streamingOpens == eagerOpens)
        #expect(streamingOpens.allSatisfy { $0[0] <= 64 && $0[1] <= 64 })

        var eagerMetadata: DependencyMetadataCounts?
        var streamingMetadata: DependencyMetadataCounts?
        let countedEager = Result {
            try CountedEagerDependencyRawIndexStoreReader(storePath: storePath, libraryPath: libraryPath,
                fileSystem: fileSystem).read(in: paths, trackedSourcePath: trackedSourcePath,
                    includeProjectHeaderRecords: includeProjectHeaderRecords,
                    metadataResult: { eagerMetadata = $0 })
        }
        let countedStreaming = Result {
            try CountedStreamingDependencyRawIndexStoreReader(storePath: storePath, libraryPath: libraryPath,
                fileSystem: fileSystem).read(in: paths, trackedSourcePath: trackedSourcePath,
                    includeProjectHeaderRecords: includeProjectHeaderRecords,
                    metadataResult: { streamingMetadata = $0 })
        }
        try expectDependencyOutcome(countedEager, eager)
        try expectDependencyOutcome(countedStreaming, streaming)
        let e = try #require(eagerMetadata)
        let s = try #require(streamingMetadata)
        // 실패한 유닛의 eager 복사는 앞서 끝나므로 접근 수 공식은 성공한 읽기에만 적용한다.
        if case .success = streaming, case .success = eager {
            #expect(s.dependencies == e.dependencies)
            #expect(s.recordOrFile == e.recordOrFile)
            #expect(s.admittedContexts == e.admittedContexts)
            #expect(s.admittedRecords == e.admittedRecords)
            #expect(e.pathStrings == e.dependencies)
            #expect(e.moduleStrings == e.dependencies)
            #expect(e.nameStrings == e.dependencies)
            #expect(e.systemReads == e.dependencies)
            #expect(s.pathStrings == s.recordOrFile)
            #expect(s.moduleStrings == s.admittedRecords)
            #expect(s.nameStrings == s.admittedRecords)
            #expect(s.systemReads == s.admittedContexts)
            #expect(s.pathStrings + s.moduleStrings + s.nameStrings
                <= e.pathStrings + e.moduleStrings + e.nameStrings)
            #expect(streamingOpens.count <= s.admittedRecords)
            #expect(s.admittedRecords == 0 || !streamingOpens.isEmpty)
        }
        let storeStable = try dependencyStoreFiles(storePath) == before
        #expect(storeStable)
        if case .success = streaming, case .success = eager {
            let evidence = DependencyParityEvidence(schema: "cartograph-streaming-dependency-parity-v1",
                eager: e, streaming: s, eagerCacheOpenEvents: eagerOpens.count,
                streamingCacheOpenEvents: streamingOpens.count)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print("cartograph-streaming-dependency-parity-v1 "
                + String(decoding: try encoder.encode(evidence), as: UTF8.self))
        }
        return try streaming.get()
    }
}

// 실제 공급자의 성공·오류 반환은 그대로 두고, 각 기존 fixture 상태에 독립 oracle을 덧댄다.
struct DependencyParityProvider {
    typealias Configuration = IndexStoreProvider.Configuration
    typealias ReaderMode = IndexStoreProvider.ReaderMode
    let configuration: Configuration
    let fileSystem: any FileSystem

    init(configuration: Configuration, fileSystem: any FileSystem = LocalFileSystem()) {
        self.configuration = configuration
        self.fileSystem = fileSystem
    }

    private var provider: IndexStoreProvider {
        IndexStoreProvider(configuration: configuration, fileSystem: fileSystem)
    }

    func sourceFilePaths() -> [String] { provider.sourceFilePaths() }
    func trackedSourcePathPredicate() -> (String) -> Bool { provider.trackedSourcePathPredicate() }

    func loadSnapshot() throws -> IndexSnapshot {
        let actual = Result { try provider.loadSnapshot() }
        let raw = Result {
            try DependencyParityRawReader(storePath: configuration.storePath,
                libraryPath: configuration.libraryPath, fileSystem: fileSystem).read(
                    in: Set(sourceFilePaths()), trackedSourcePath: trackedSourcePathPredicate(),
                    includeProjectHeaderRecords: configuration.includeObjectiveCSources)
        }
        if case .success(let result) = raw, case .success(let snapshot) = actual,
           configuration.readerMode == .raw {
            #expect(snapshot == dependencySnapshot(result, external: configuration.includeExternalSymbols,
                selfReferences: configuration.includeSelfReferences))
        }
        if configuration.readerMode == .raw {
            switch (actual, raw) {
            case (.success, .success), (.failure, .failure): break
            default: Issue.record("The raw provider and the parity reader disagree on success versus failure.")
            }
        }
        return try actual.get()
    }

    static func snapshot(from occurrences: [SymbolOccurrence], includeExternalSymbols: Bool) -> IndexSnapshot {
        IndexStoreProvider.snapshot(from: occurrences, includeExternalSymbols: includeExternalSymbols)
    }
}
