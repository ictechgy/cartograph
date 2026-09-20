import CartographConfig
import CartographCore
import CartographKit
import CryptoKit
import Darwin
import Foundation

// 이 실행 파일만 계측한다. 제품에는 진단 출력이나 소스 재읽기 경로를 추가하지 않는다.
final class MeasuringFileSystem: FileSystem, @unchecked Sendable {
    let base = LocalFileSystem()
    private var sizes: [String: Int] = [:]
    private var reads: [String: Int] = [:]
    private(set) var peakBeforeFirstSourceBytes: Int?
    var sourceBytes: Int { sizes.values.reduce(0, +) }
    var sourceFiles: Int { sizes.count }
    var sourceReads: Int { reads.values.reduce(0, +) }
    var maxReadsPerSource: Int { reads.values.max() ?? 0 }
    var currentDirectoryPath: String { base.currentDirectoryPath }

    func readData(at path: String) throws -> Data {
        let isSource = ["swift", "m", "mm"].contains((path as NSString).pathExtension)
        if isSource && peakBeforeFirstSourceBytes == nil { peakBeforeFirstSourceBytes = peakRSS() }
        let data = try base.readData(at: path)
        if isSource {
            let key = try base.realPath(at: path)
            sizes[key] = String(decoding: data, as: UTF8.self).utf8.count
            reads[key, default: 0] += 1
        }
        return data
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
}

func peakRSS() -> Int {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Int(usage.ru_maxrss)
}

let project = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
let fileSystem = MeasuringFileSystem()
var configuration = try ConfigurationLoader(fileSystem: fileSystem)
    .load(explicitPath: nil, searchDirectory: project).configuration
configuration.projectPath = project
var environment = CartographEnvironment.live()
environment.fileSystem = fileSystem
let service = CartographService(configuration: configuration, environment: environment)
let started = Date()
let document = try service.bridgeFacts(generatedAt: Date(timeIntervalSince1970: 0))
let elapsed = Date().timeIntervalSince(started)
let peak = peakRSS()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let encoded = try encoder.encode(document)
let result: [String: Any] = [
    "sourceCacheUTF8Bytes": fileSystem.sourceBytes,
    "sourceFiles": fileSystem.sourceFiles,
    "sourceReads": fileSystem.sourceReads,
    "maxReadsPerSource": fileSystem.maxReadsPerSource,
    "peakBeforeFirstSourceBytes": fileSystem.peakBeforeFirstSourceBytes ?? 0,
    "peakRSSBytes": peak,
    "elapsedSeconds": elapsed,
    "factCount": document.facts.count,
    "documentSHA256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
