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
}

struct RawIndexStoreReader {
    let storePath: String
    let libraryPath: String
    let fileSystem: any FileSystem

    func read(
        in paths: Set<String>, recordCachePeak: ((Int, Int) -> Void)? = nil
    ) throws -> RawReadResult {
        let session = try Session(storePath: storePath, libraryPath: libraryPath)
        let allowedPaths = Set(paths.map(fileSystem.canonicalPath))
        var records: [Record] = []
        var indexedFileDates: [String: Date] = [:]
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
                guard allowedPaths.contains(path) else { continue }
                // Foundation 정규화는 /private/var를 /var로 바꾼다. 선언 위치는
                // 다른 인덱스 소비자와 같이 실제 경로를 써야 정확히 결합된다.
                let locationPath = (try? fileSystem.realPath(at: path)) ?? path
                indexedFileDates[locationPath] = max(indexedFileDates[locationPath] ?? timestamp, timestamp)
                guard dependency.kind == .record else { continue }
                let provider: DBSymbolProviderKind
                if let unitProvider {
                    provider = unitProvider
                } else {
                    let parsed = try providerKind(unit.providerIdentifier.string, unit: unitName)
                    unitProvider = parsed
                    provider = parsed
                }
                let dependencyModule = dependency.module
                let recordModule = dependencyModule.isEmpty && path.hasSuffix(".swift") ? module : dependencyModule
                records.append(Record(
                    unit: unitName,
                    record: dependency.name,
                    path: locationPath,
                    module: recordModule,
                    timestamp: timestamp,
                    isSystem: unit.isSystemUnit || dependency.isSystem,
                    provider: provider
                ))
            }
        }

        records.sort { $0.sortKey < $1.sortKey }
        var result: [DBSymbolOccurrence] = []
        var seen: Set<OccurrenceKey> = []
        var loadedRecords = RecordCache(capacity: 64)
        var remainingUses = Dictionary(records.map { ($0.record, 1) }, uniquingKeysWith: +)
        for record in records {
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
                let key = OccurrenceKey(occurrence: occurrence, unit: record.unit, record: record.record)
                guard seen.insert(key).inserted else { return .continue }
                result.append(occurrence)
                return .continue
            }
            remainingUses[record.record, default: 1] -= 1
            if remainingUses[record.record] == 0 {
                loadedRecords.removeValue(forKey: record.record)
            }
        }
        return RawReadResult(occurrences: result, indexedFileDates: indexedFileDates)
    }

    func occurrences(in paths: Set<String>) throws -> [SymbolOccurrence] {
        try read(in: paths).occurrences
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

        var sortKey: (String, String, String, String) {
            (unit, record, path, module)
        }
    }

    private struct OccurrenceKey: Hashable {
        let unit: String
        let record: String
        let usr: String
        let line: Int
        let column: Int
        let roles: UInt64
        let relationSignature: String

        init(occurrence: DBSymbolOccurrence, unit: String, record: String) {
            self.unit = unit
            self.record = record
            self.usr = occurrence.symbol.usr
            self.line = occurrence.location.line
            self.column = occurrence.location.utf8Column
            self.roles = occurrence.roles.rawValue
            self.relationSignature = occurrence.relations
                .map { "\($0.symbol.usr):\($0.roles.rawValue)" }
                .sorted()
                .joined(separator: ",")
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
            let box = StoreBox()
            let storeURL = URL(fileURLWithPath: storePath)
            let libraryURL = URL(fileURLWithPath: libraryPath)
            Task.detached {
                do {
                    let library = try await RawStoreLibrary.at(dylibPath: libraryURL)
                    do {
                        box.store = try library.indexStore(at: storeURL)
                    } catch {
                        box.error = error
                    }
                } catch {
                    box.error = CartographError.indexStoreLibraryNotFound(searchedPaths: [libraryPath])
                }
                box.semaphore.signal()
            }
            box.semaphore.wait()
            if let error = box.error { throw error }
            guard let store = box.store else {
                throw RawIndexStoreReaderError.openStore("raw IndexStore returned no store")
            }
            self.store = store
        }
    }

    private final class StoreBox: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var store: RawStore?
        var error: Error?
    }
}

private enum RawIndexStoreReaderError: Error, LocalizedError {
    case openStore(String)
    case unit(String, underlying: Error)
    case record(String, String, underlying: Error)
    case provider(String, String)
    case language(UInt8)

    var errorDescription: String? {
        switch self {
        case .openStore(let message): return message
        case .unit(let unit, let error): return "Could not read index unit \(unit): \(error)"
        case .record(let unit, let record, let error):
            return "Could not read index record \(record) from unit \(unit): \(error)"
        case .provider(let unit, let identifier):
            return "Unsupported index provider \(identifier) in unit \(unit)"
        case .language(let value): return "Unsupported index symbol language \(value)"
        }
    }
}
