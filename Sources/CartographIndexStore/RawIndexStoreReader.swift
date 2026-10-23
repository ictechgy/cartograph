import CartographCore
import Foundation
import class IndexStore.IndexStore
import struct IndexStore.IndexStoreLibrary
import class IndexStore.IndexStoreUnit
import class IndexStore.IndexStoreRecord
import struct IndexStore.IndexStoreOccurrence
import struct IndexStore.IndexStoreSymbol
import struct IndexStore.IndexStoreLanguage
import struct IndexStoreDB.Symbol
import struct IndexStoreDB.SymbolOccurrence
import struct IndexStoreDB.SymbolLocation
import struct IndexStoreDB.SymbolRelation
import struct IndexStoreDB.SymbolProperty
import struct IndexStoreDB.SymbolRole
import enum IndexStoreDB.IndexSymbolKind
import enum IndexStoreDB.IndexSymbolSubKind
import enum IndexStoreDB.Language
import enum IndexStoreDB.SymbolProviderKind

private typealias RawStore = IndexStore
private typealias RawStoreLibrary = IndexStoreLibrary
private typealias RawStoreUnit = IndexStoreUnit
private typealias RawStoreRecord = IndexStoreRecord
private typealias RawStoreOccurrence = IndexStoreOccurrence
private typealias RawStoreSymbol = IndexStoreSymbol
private typealias DBSymbol = Symbol
private typealias DBSymbolOccurrence = SymbolOccurrence
private typealias DBSymbolLocation = SymbolLocation
private typealias DBSymbolRelation = SymbolRelation
private typealias DBSymbolProperty = SymbolProperty
private typealias DBSymbolRole = SymbolRole
private typealias DBIndexSymbolKind = IndexSymbolKind
private typealias DBIndexSymbolSubKind = IndexSymbolSubKind
private typealias DBSymbolProviderKind = SymbolProviderKind

/// 소스 파일을 포함하는 모든 프로젝트 레코드를 읽는다.
///
/// `IndexStoreDB.symbolOccurrences(inFilePath:)` 는 보이는 첫 공급자에서 멈춘다.
/// 공유 Swift 파일은 컴파일 대상마다 레코드가 하나씩 있으므로, 대상 문맥을 보존하려면
/// raw IndexStore 계층을 거쳐야 한다.
struct RawReadResult {
    let occurrences: [SymbolOccurrence]
    let indexedFileDates: [String: Date]
    let oldestIndexedFileDates: [String: Date]
    let admittedHeaderPaths: [String]
    let sourceRecordAdmissions: [SourceRecordAdmission]
}

struct RawIndexStoreReader {
    let storePath: String
    let libraryPath: String
    let fileSystem: any FileSystem

    /// 요청한 파일의 레코드를 모든 컴파일 문맥에서 읽는다.
    ///
    /// `recordCachePeak` 와 `occurrenceKeyPeak` 는 테스트용 관측 지점이다. 레코드 캐시와 발생 중복 제거가
    /// 인덱스 크기가 아니라 레코드 하나 크기로 묶이는지 확인한다.
    func read(
        in paths: Set<String>, trackedSourcePath: ((String) -> Bool)? = nil,
        includeProjectHeaderRecords: Bool = false,
        recordCachePeak: ((Int, Int) -> Void)? = nil,
        occurrenceKeyPeak: ((Int) -> Void)? = nil
    ) throws -> RawReadResult {
        let session = try Session(storePath: storePath, libraryPath: libraryPath)
        let allowedPaths = Set(paths.map(fileSystem.canonicalPath))
        var records: [Record] = []
        var indexedFileDates: [String: Date] = [:]
        var oldestIndexedFileDates: [String: Date] = [:]
        var systemHeaderPaths: Set<String> = []
        var fileOnlyHeaderUnits: [String: Set<String>] = [:]
        let unitNames = session.store.unitNames(sorted: true).map { $0.string }
        for unitName in unitNames {
            let unit: RawStoreUnit
            do {
                unit = try session.store.unit(named: unitName)
            } catch {
                throw RawIndexStoreReaderError.unit(unitName, underlying: error)
            }
            let module = unit.moduleName.string
            let workingDirectory = unit.workingDirectory.string
            let timestamp = unit.modificationDate
            let dependencies = unit.dependencies.map { dependency in
                (
                    kind: dependency.kind,
                    path: dependency.filePath.string,
                    module: dependency.moduleName.string,
                    name: dependency.name.string,
                    isSystem: dependency.isSystem
                )
            }
            var unitProvider: DBSymbolProviderKind?
            for dependency in dependencies where dependency.kind == .record || dependency.kind == .file {
                let path = canonicalDependencyPath(dependency.path, relativeTo: workingDirectory)
                let directlyAllowed = allowedPaths.contains(path)
                let tracked = !directlyAllowed && trackedSourcePath?(path) == true
                // 헤더 admission은 신선도 추적과 별개다. 삭제·외부 경로를 선언으로 되살리지 않는다.
                let readsHeader = includeProjectHeaderRecords && tracked && path.hasSuffix(".h")
                    && fileSystem.fileExists(at: path) && !fileSystem.directoryExists(at: path)
                let readsOccurrences = directlyAllowed || readsHeader
                guard readsOccurrences || tracked else { continue }
                // Foundation 정규화는 /private/var를 /var로 바꾼다. 선언 위치는
                // 다른 인덱스 소비자와 같이 실제 경로를 써야 정확히 결합된다.
                let locationPath = Self.sourceLocationPath(path, fileSystem: fileSystem)
                if path.hasSuffix(".h") {
                    if unit.isSystemUnit || dependency.isSystem { systemHeaderPaths.insert(locationPath) }
                    if dependency.kind == .file {
                        fileOnlyHeaderUnits[locationPath, default: []].insert(unitName)
                    }
                }
                indexedFileDates[locationPath] = max(indexedFileDates[locationPath] ?? timestamp, timestamp)
                oldestIndexedFileDates[locationPath] = min(oldestIndexedFileDates[locationPath] ?? timestamp, timestamp)
                guard readsOccurrences, dependency.kind == .record else { continue }
                let provider: DBSymbolProviderKind
                if let unitProvider {
                    provider = unitProvider
                } else {
                    let parsed = try providerKind(unit.providerIdentifier.string, unit: unitName)
                    unitProvider = parsed
                    provider = parsed
                }
                let dependencyModule = dependency.module
                let recordModule = Self.recordModule(dependencyModule: dependencyModule,
                                                     unitModule: module, sourcePath: path)
                records.append(Record(
                    unit: unitName,
                    record: dependency.name,
                    path: locationPath,
                    module: recordModule,
                    timestamp: timestamp,
                    isSystem: unit.isSystemUnit || dependency.isSystem,
                    provider: provider,
                    unitOutputIdentity: unit.outputFile.string,
                    unitTargetTriple: unit.target.string
                ))
            }
        }

        records.sort { $0.sortKey < $1.sortKey }
        var result: [DBSymbolOccurrence] = []
        var admissions: [SourceRecordAdmission] = []
        var deduplicator = OccurrenceDeduplicator()
        var loadedRecords = RecordCache(capacity: 64)
        var remainingUses = Dictionary(records.map { ($0.record, 1) }, uniquingKeysWith: +)
        for record in records {
            if deduplicator.begin(unit: record.unit, record: record.record) {
                let rawRecord: RawStoreRecord
                do {
                    rawRecord = try loadedRecords.record(
                        named: record.record, from: session.store, onPeak: recordCachePeak
                    )
                } catch {
                    throw RawIndexStoreReaderError.record(record.unit, record.record, underlying: error)
                }
                try rawRecord.occurrences.forEach { rawOccurrence in
                    let occurrence = try convert(rawOccurrence, record: record)
                    if deduplicator.admit(occurrence) { result.append(occurrence) }
                    return .continue
                }
                occurrenceKeyPeak?(deduplicator.retainedKeyCount)
                if record.path.hasSuffix(".swift"), !record.isSystem, record.provider == .swift {
                    admissions.append(.init(path: record.path, module: record.module, unit: record.unit,
                        record: record.record, timestamp: record.timestamp,
                        unitOutputIdentity: record.unitOutputIdentity, unitTargetTriple: record.unitTargetTriple))
                }
            }
            remainingUses[record.record, default: 1] -= 1
            if remainingUses[record.record] == 0 {
                loadedRecords.removeValue(forKey: record.record)
            }
        }
        // 모든 유닛·레코드·발생을 읽기 전에는 성공한 헤더 admission을 반환하지 않는다.
        // 같은 레코드를 공유하는 여러 문맥도 위의 unit/record 키로 각각 처리한다.
        let headerContexts = Dictionary(grouping: records.filter { $0.path.hasSuffix(".h") }, by: \.path)
        // 시스템 문맥은 기본 그래프에서 외부 정점으로 걸러질 수 있다. 한 문맥이라도 그러면 경고를 유지한다.
        let headers = headerContexts.filter { path, contexts in
            // 다른 유닛의 record는 file-only 문맥의 선언·호출을 증명하지 않는다.
            // 같은 유닛에 중복 file/record 항목이 있다면 성공한 record로 그 문맥만 확인한다.
            let recordUnits = Set(contexts.map(\.unit))
            return !systemHeaderPaths.contains(path)
                && (fileOnlyHeaderUnits[path] ?? []).isSubset(of: recordUnits)
        }.keys.sorted()
        return RawReadResult(occurrences: result, indexedFileDates: indexedFileDates,
            oldestIndexedFileDates: oldestIndexedFileDates, admittedHeaderPaths: headers,
            sourceRecordAdmissions: SourceRecordAdmission.sorted(admissions))
    }

    /// 삭제된 파일도 남아 있는 조상의 실제 경로를 사용해 /var와 /private/var의 식별자를 유지한다.
    static func sourceLocationPath(_ path: String, fileSystem: any FileSystem) -> String {
        var ancestor = path
        var suffix: [String] = []
        while !ancestor.isEmpty {
            if let resolved = try? fileSystem.realPath(at: ancestor) {
                return suffix.reversed().reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard parent != ancestor else { break }
            suffix.append((ancestor as NSString).lastPathComponent)
            ancestor = parent
        }
        return path
    }

    /// 구현 파일은 컴파일 unit의 모듈을 사용할 수 있다. 공유 헤더는 소비자 모듈에 귀속하지 않는다.
    static func recordModule(dependencyModule: String, unitModule: String, sourcePath: String) -> String {
        if !dependencyModule.isEmpty { return dependencyModule }
        let ownedImplementation = [".swift", ".m", ".mm"].contains { sourcePath.hasSuffix($0) }
        return ownedImplementation ? unitModule : ""
    }

    private func canonicalDependencyPath(_ path: String, relativeTo workingDirectory: String) -> String {
        let absolutePath: String
        if path.hasPrefix("/") || workingDirectory.isEmpty {
            absolutePath = path
        } else {
            absolutePath = URL(fileURLWithPath: workingDirectory).appendingPathComponent(path).path
        }
        return fileSystem.canonicalPath(absolutePath)
    }

    private func convert(
        _ rawOccurrence: RawStoreOccurrence,
        record: Record
    ) throws -> DBSymbolOccurrence {
        let rawSymbol = rawOccurrence.symbol
        let symbol = DBSymbol(
            usr: rawSymbol.usr.string,
            name: rawSymbol.name.string,
            kind: symbolKind(rawSymbol.kind),
            subKind: symbolSubKind(rawSymbol.subKind),
            properties: DBSymbolProperty(rawValue: rawSymbol.properties.rawValue),
            language: try Self.language(rawSymbol.language)
        )
        var relations: [DBSymbolRelation] = []
        try rawOccurrence.relations.forEach { rawRelation in
            let relationSymbol = rawRelation.symbol
            relations.append(DBSymbolRelation(
                symbol: DBSymbol(
                    usr: relationSymbol.usr.string,
                    name: relationSymbol.name.string,
                    kind: symbolKind(relationSymbol.kind),
                    subKind: symbolSubKind(relationSymbol.subKind),
                    properties: DBSymbolProperty(rawValue: relationSymbol.properties.rawValue),
                    language: try Self.language(relationSymbol.language)
                ),
                roles: DBSymbolRole(rawValue: rawRelation.roles.rawValue)
            ))
            return .continue
        }
        var roles = DBSymbolRole(rawValue: rawOccurrence.roles.rawValue)
        if isCanonical(rawSymbol, roles: roles) {
            roles.insert(.canonical)
        }
        let position = rawOccurrence.position
        let location = DBSymbolLocation(
            path: record.path,
            timestamp: record.timestamp,
            moduleName: record.module,
            isSystem: record.isSystem,
            line: position.line,
            utf8Column: position.column
        )
        return DBSymbolOccurrence(
            symbol: symbol,
            location: location,
            roles: roles,
            symbolProvider: record.provider,
            relations: relations
        )
    }

    private func isCanonical(_ symbol: RawStoreSymbol, roles: DBSymbolRole) -> Bool {
        if symbol.language == .objectiveC {
            let prefersDeclaration = symbol.kind == .class
                || symbol.kind == .extension
                || symbol.kind == .instanceProperty
                || symbol.kind == .classProperty
            return roles.contains(prefersDeclaration ? .declaration : .definition)
        }
        return roles.contains(.definition)
    }

    private func providerKind(_ identifier: String, unit: String) throws -> DBSymbolProviderKind {
        switch identifier {
        case "swift": return .swift
        case "clang": return .clang
        default: throw RawIndexStoreReaderError.provider(unit, identifier)
        }
    }

    private func symbolKind(_ kind: RawStoreSymbol.Kind) -> DBIndexSymbolKind {
        switch kind {
        case .unknown: return .unknown
        case .module: return .module
        case .namespace: return .namespace
        case .namespaceAlias: return .namespaceAlias
        case .macro: return .macro
        case .enum: return .enum
        case .struct: return .struct
        case .class: return .class
        case .protocol: return .protocol
        case .extension: return .extension
        case .union: return .union
        case .typealias: return .typealias
        case .function: return .function
        case .variable: return .variable
        case .field: return .field
        case .enumConstant: return .enumConstant
        case .instanceMethod: return .instanceMethod
        case .classMethod: return .classMethod
        case .staticMethod: return .staticMethod
        case .instanceProperty: return .instanceProperty
        case .classProperty: return .classProperty
        case .staticProperty: return .staticProperty
        case .constructor: return .constructor
        case .destructor: return .destructor
        case .conversionFunction: return .conversionFunction
        case .parameter: return .parameter
        case .using: return .using
        case .concept: return .concept
        case .commentTag: return .commentTag
        default: return .unknown
        }
    }

    private func symbolSubKind(_ subKind: RawStoreSymbol.SubKind) -> DBIndexSymbolSubKind {
        switch subKind {
        case .none: return .none
        case .cxxCopyConstructor: return .cxxCopyConstructor
        case .cxxMoveConstructor: return .cxxMoveConstructor
        case .accessorGetter: return .accessorGetter
        case .accessorSetter: return .accessorSetter
        case .swiftAccessorWillSet: return .swiftAccessorWillSet
        case .swiftAccessorDidSet: return .swiftAccessorDidSet
        case .swiftAccessorAddressor: return .swiftAccessorAddressor
        case .swiftAccessorMutableAddressor: return .swiftAccessorMutableAddressor
        case .swiftExtensionOfStruct: return .swiftExtensionOfStruct
        case .swiftExtensionOfClass: return .swiftExtensionOfClass
        case .swiftExtensionOfEnum: return .swiftExtensionOfEnum
        case .swiftExtensionOfProtocol: return .swiftExtensionOfProtocol
        case .swiftPrefixOperator: return .swiftPrefixOperator
        case .swiftPostfixOperator: return .swiftPostfixOperator
        case .swiftInfixOperator: return .swiftInfixOperator
        case .swiftSubscript: return .swiftSubscript
        case .swiftAssociatedtype: return .swiftAssociatedType
        case .swiftGenericTypeParam: return .swiftGenericTypeParam
        default: return .none
        }
    }

    static func language(_ language: IndexStoreLanguage) throws -> Language {
        switch language {
        case .c: return .c
        case .objectiveC: return .objc
        case .cxx: return .cxx
        case .swift: return .swift
        default: throw RawIndexStoreReaderError.language(language.rawValue)
        }
    }

    private struct Record {
        let unit: String
        let record: String
        let path: String
        let module: String
        let timestamp: Date
        let isSystem: Bool
        let provider: DBSymbolProviderKind
        let unitOutputIdentity: String
        let unitTargetTriple: String

        var sortKey: (String, String, String, String) {
            (unit, record, path, module)
        }
    }

    /// 레코드 항목마다 같은 발생을 한 번만 남긴다.
    ///
    /// 서로 다른 (유닛, 레코드) 쌍의 발생은 원래 키가 겹치지 않았다. 그래서 읽기 전체에 걸친 집합 대신 처리한 쌍만
    /// 기억해 다시 나온 항목을 통째로 건너뛰고, 키 집합은 레코드 하나 안의 중복만 거른다. 다시 나온 항목은 경로·모듈
    /// 표기만 다른 같은 레코드라 예전에도 발생이 전부 버려졌다. 전체 집합은 발생마다 수백 바이트의 키를 읽기가 끝날
    /// 때까지 붙잡아, 큰 인덱스에서 읽기 단계의 최대 메모리를 두 배 가까이 늘렸다.
    struct OccurrenceDeduplicator {
        private var readContexts: Set<RecordContext> = []
        private var seen: Set<OccurrenceKey> = []

        /// 처음 보는 (유닛, 레코드) 쌍이면 참을 돌려주고 레코드 안 중복 집합을 비운다.
        mutating func begin(unit: String, record: String) -> Bool {
            guard readContexts.insert(RecordContext(unit: unit, record: record)).inserted else { return false }
            seen.removeAll(keepingCapacity: true)
            return true
        }

        /// 지금 레코드에서 처음 보는 발생이면 참.
        mutating func admit(_ occurrence: SymbolOccurrence) -> Bool {
            seen.insert(OccurrenceKey(occurrence)).inserted
        }

        /// 지금 붙잡고 있는 발생 키 수. 레코드 하나의 발생 수를 넘지 않는다.
        var retainedKeyCount: Int { seen.count }

        private struct RecordContext: Hashable {
            let unit: String
            let record: String
        }

        /// 레코드 하나 안에서 같은 발생인지 가르는 키.
        ///
        /// 관계는 순서와 무관하게 (USR, 역할) 쌍의 정렬된 배열로 비교한다. 예전 서명은 발생마다 관계를 문자열로
        /// 보간·정렬·연결해 새로 할당했고, 구분자가 든 USR 이면 서로 다른 관계 집합이 같은 서명이 될 수 있었다.
        private struct OccurrenceKey: Hashable {
            let usr: String
            let line: Int
            let column: Int
            let roles: UInt64
            let relations: [RelationKey]

            init(_ occurrence: SymbolOccurrence) {
                usr = occurrence.symbol.usr
                line = occurrence.location.line
                column = occurrence.location.utf8Column
                roles = occurrence.roles.rawValue
                var relations = occurrence.relations.map {
                    RelationKey(usr: $0.symbol.usr, roles: $0.roles.rawValue)
                }
                if relations.count > 1 { relations.sort() }
                self.relations = relations
            }
        }

        private struct RelationKey: Hashable, Comparable {
            let usr: String
            let roles: UInt64

            static func < (lhs: Self, rhs: Self) -> Bool {
                (lhs.usr, lhs.roles) < (rhs.usr, rhs.roles)
            }
        }
    }

    private struct RecordCache {
        private struct Entry {
            let record: RawStoreRecord
            let token: Int
        }

        private struct Token {
            let name: String
            let value: Int
        }

        let capacity: Int
        private var entries: [String: Entry] = [:]
        private var order: [Token] = []
        private var nextToken = 0

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        mutating func record(
            named name: String,
            from store: RawStore,
            onPeak: ((Int, Int) -> Void)?
        ) throws -> RawStoreRecord {
            if let cached = entries[name] { return cached.record }
            evictIfNeeded()
            let record = try store.record(named: name)
            nextToken += 1
            let token = Token(name: name, value: nextToken)
            entries[name] = Entry(record: record, token: token.value)
            order.append(token)
            onPeak?(entries.count, order.count)
            return record
        }

        mutating func removeValue(forKey name: String) {
            guard let entry = entries.removeValue(forKey: name) else { return }
            if let index = order.firstIndex(where: { $0.name == name && $0.value == entry.token }) {
                order.remove(at: index)
            }
        }

        private mutating func evictIfNeeded() {
            while entries.count >= capacity, !order.isEmpty {
                let candidate = order.removeFirst()
                guard let current = entries[candidate.name], current.token == candidate.value else {
                    continue
                }
                entries.removeValue(forKey: candidate.name)
                break
            }
        }
    }

    private final class Session: @unchecked Sendable {
        let store: RawStore

        init(storePath: String, libraryPath: String) throws {
            let storeURL = URL(fileURLWithPath: storePath)
            let libraryURL = URL(fileURLWithPath: libraryPath)
            self.store = try IndexStoreTaskBridge.wait {
                let library: RawStoreLibrary
                do {
                    library = try await RawStoreLibrary.at(dylibPath: libraryURL)
                } catch {
                    throw CartographError.indexStoreLibraryNotFound(searchedPaths: [libraryPath])
                }
                return try library.indexStore(at: storeURL)
            }
        }
    }
}

private enum RawIndexStoreReaderError: Error, LocalizedError {
    case unit(String, underlying: Error)
    case record(String, String, underlying: Error)
    case provider(String, String)
    case language(UInt8)

    var errorDescription: String? {
        switch self {
        case .unit(let unit, let error): return "Could not read index unit \(unit): \(error)"
        case .record(let unit, let record, let error):
            return "Could not read index record \(record) from unit \(unit): \(error)"
        case .provider(let unit, let identifier):
            return "Unsupported index provider \(identifier) in unit \(unit)"
        case .language(let value): return "Unsupported index symbol language \(value)"
        }
    }
}
