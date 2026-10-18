import CartographCore
import CryptoKit
import Foundation

/// 저장된 생성 시점의 소속 주장을 현재의 명시 입력 바이트와 주어진 인덱스에 대조한다.
/// 목록에 없는 새 소스나 현재 패키지 전체의 완전성을 증명하지 않으며 명령을 실행하지 않는다.
struct SwiftPMTargetEvidenceStore {
    private let fileSystem: any FileSystem
    private static let documentLimit = 4 * 1_024 * 1_024
    private static let maximumSources = 10_000
    private static let sourceLimit = 4 * 1_024 * 1_024

    init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// 원시 describe만 있으면 소속 판정 근거가 없다.
    func read(at path: String?, snapshot: IndexSnapshot) throws -> [SwiftPMDeclaredTarget]? {
        guard let path else { return nil }
        let bytes = try readBounded(path, limit: Self.documentLimit)
        let receipt = try JSONDecoder().decode(SwiftPMTargetEvidenceDocument.self, from: bytes)
        return try verify(receipt, snapshot: snapshot)
    }

    func verify(_ receipt: SwiftPMTargetEvidenceDocument, snapshot: IndexSnapshot) throws -> [SwiftPMDeclaredTarget] {
        guard receipt.format == "swiftpm-target-evidence", receipt.version == 1,
              receipt.before == receipt.after, receipt.snapshotBefore == receipt.snapshotAfter,
              receipt.snapshotAfter == (try Self.snapshotIdentity(snapshot)),
              !receipt.toolchain.isEmpty, receipt.configuration == "debug",
              receipt.describeArguments == ["swift", "package", "describe", "--type", "json"],
              receipt.buildArguments == [
                  "swift", "build", "--package-path", receipt.packageRoot,
                  "--scratch-path", receipt.packageRoot + "/.build", "--configuration", "debug",
                  "--build-tests", "--enable-index-store", "--jobs", "2"
              ],
              receipt.before.files.count <= Self.maximumSources + 2,
              try fileSystem.realPath(at: receipt.packageRoot) == receipt.packageRoot
        else { throw invalid("The producer receipt is incomplete, unsupported or belongs to another snapshot.") }
        let descriptionPath = try containedPath(receipt.descriptionPath, root: receipt.packageRoot)
        let description = try readBounded(descriptionPath, limit: Self.documentLimit)
        guard Self.digest(description) == receipt.before.descriptionSHA256 else {
            throw invalid("The supplied description changed.")
        }
        let targets = try parse(description, root: receipt.packageRoot)
        guard try inputs(description: description, root: receipt.packageRoot) == receipt.before else {
            throw invalid("A manifest, resolution state or source input changed.")
        }
        // 다른 프로세스가 파일을 바꾸는 짧은 창도 첫 읽기의 성공으로 숨기지 않는다.
        guard try readBounded(descriptionPath, limit: Self.documentLimit) == description,
              (try inputs(description: description, root: receipt.packageRoot)) == receipt.before else {
            throw invalid("The description changed while reading.")
        }
        return targets
    }

    /// 통제된 빌드 생산자가 실행 전후 바이트를 기록할 때 쓴다. 이것만으로 생산자 실행을 인증하지 않는다.
    func inputs(description: Data, root: String) throws -> SwiftPMTargetEvidenceDocument.Inputs {
        let targets = try parse(description, root: root)
        let paths = Set(targets.flatMap(\.sourcePaths)).union([root + "/Package.swift", root + "/Package.resolved"])
        var files: [String: String?] = [:]
        var totalBytes = 0
        for path in paths {
            _ = try containedPath(path, root: root)
            let relative = String(path.dropFirst(root.count + 1))
            if relative == "Package.resolved", !fileSystem.fileExists(at: path) {
                files.updateValue(nil, forKey: relative)
            } else {
                let data = try readBounded(path, limit: Self.sourceLimit)
                totalBytes += data.count
                guard totalBytes <= 64 * 1_024 * 1_024 else {
                    throw invalid("The combined source inputs exceed their size limit.")
                }
                files[relative] = Self.digest(data)
            }
        }
        return .init(descriptionSHA256: Self.digest(description), files: files)
    }

    private struct Description: Decodable {
        let path: String
        let targets: [Target]
        struct Target: Decodable {
            let name: String
            let type: String
            let c99name: String?
            let module_type: String?
            let path: String
            let sources: [String]
        }
    }

    private func parse(_ data: Data, root: String) throws -> [SwiftPMDeclaredTarget] {
        guard data.count <= Self.documentLimit else { throw invalid("The description exceeds its limit.") }
        let description = try JSONDecoder().decode(Description.self, from: data)
        guard root.hasPrefix("/"), root != "/",
              URL(fileURLWithPath: root).standardizedFileURL.path == root,
              try fileSystem.realPath(at: root) == root,
              (try fileSystem.realPath(at: description.path)) == root,
              !description.targets.isEmpty, description.targets.count <= 1_000,
              description.targets.reduce(0, { $0 + $1.sources.count }) <= Self.maximumSources else {
            throw invalid("The description has another package root or exceeds its target/source limit.")
        }
        return try description.targets.map { target in
            guard ["library", "test", "executable"].contains(target.type),
                  target.module_type == "SwiftTarget", let module = target.c99name,
                  !module.isEmpty, !target.name.isEmpty,
                  !target.sources.isEmpty, Set(target.sources).count == target.sources.count,
                  relativePath(target.path), target.sources.allSatisfy(relativePath) else {
                throw invalid("Only explicit bounded Swift source targets are supported.")
            }
            let paths = try Set(target.sources.map {
                try containedPath(root + "/" + target.path + "/" + $0, root: root)
            })
            return .init(packageRoot: root, name: target.name, module: module,
                         isTest: target.type == "test", sourcePaths: paths)
        }
    }

    private func relativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/") && !path.contains("\\")
            && path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func containedPath(_ path: String, root: String) throws -> String {
        guard path.hasPrefix(root + "/"),
              relativePath(String(path.dropFirst(root.count + 1))) else {
            throw invalid("A declared path escapes the package root.")
        }
        if !fileSystem.fileExists(at: path) {
            guard path == root + "/Package.resolved",
                  !fileSystem.directoryExists(at: path),
                  !(try fileSystem.contentsOfDirectory(at: root)).contains(path) else {
                throw invalid("A declared source is absent or Package.resolved is a nonregular entry.")
            }
            return path
        }
        let resolved = try fileSystem.realPath(at: path)
        guard resolved == path else { throw invalid("Symlinked or noncanonical evidence paths are unsupported.") }
        return resolved
    }

    private func readBounded(_ path: String, limit: Int) throws -> Data {
        if let stamp = fileSystem.fingerprintStamp(at: path), !stamp.isRegularFile {
            throw invalid("Evidence inputs must be regular files.")
        }
        let data = try fileSystem.readData(at: path, maximumBytes: limit)
        guard data.count <= limit else { throw invalid("An evidence input exceeds its size limit.") }
        return data
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// symbols 등 순서가 의미 있는 배열은 보존한다. 참조와 속성 집합만 정규화한다.
    static func snapshotIdentity(_ snapshot: IndexSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot))
        func canonical(_ value: Any, key: String? = nil) throws -> Any {
            if let dictionary = value as? [String: Any] {
                return try Dictionary(uniqueKeysWithValues: dictionary.map {
                    ($0.key, try canonical($0.value, key: $0.key))
                })
            }
            if let array = value as? [Any] {
                let values = try array.map { try canonical($0) }
                guard key == "attributes" || key == "references" else { return values }
                return try values.map { value in
                    (value, try JSONSerialization.data(withJSONObject: value,
                        options: [.sortedKeys, .fragmentsAllowed]))
                }.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
            }
            return value
        }
        return digest(try JSONSerialization.data(withJSONObject: canonical(object), options: [.sortedKeys]))
    }

    private func invalid(_ reason: String) -> CartographError {
        .invalidConfiguration(path: "swiftpm-target-evidence", reason: reason)
    }
}
