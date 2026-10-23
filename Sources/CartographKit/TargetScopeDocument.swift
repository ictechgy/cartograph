import CartographCore
import CryptoKit
import Foundation

/// 명시 캡처와 현재 입력을 대조한 경로별 소속. SwiftPM은 진단 전용이며 Xcode 근거는 별도 필드로 구분한다.
public struct TargetScopeDocument: Sendable, Equatable, Codable {
    public let format: String
    public let version: Int
    public let evidenceStatus: String
    public let selectedTargets: [String]
    public let dependencyTargets: [String]
    public let schemeIdentity: String
    public let paths: [Path]
    public let pathCount: Int
    public let omittedPaths: Int
    public let limitations: [String]
    /// Xcode 전용 캡처 범위. SwiftPM 진단에는 없으며 다른 실행 문맥에 재사용할 수 없다.
    public var xcode: Xcode? = nil

    public struct Xcode: Sendable, Equatable, Codable {
        public let project: String
        public let scheme: String
        public let testPlan: String?
        public let configuration: String
        public let destination: String
        public let architecture: String
        public let selectionStatus: String
        public let blockers: [String]
        /// xctestrun BlueprintName과 프로젝트 target 신원이 일치한 선택 이름.
        public let selectorTargetByModule: [String: String]
        public let selectedSourcePaths: [String]
        public let coveredBlockerCodes: [String]
        /// 선택 이름의 근거를 제품 파일명과 구분한다. 이전 문서에는 없을 수 있다.
        public var selectorIdentity: String? = nil
        /// 선택 이름과 별개로 검증한 실제 test bundle 제품 파일명.
        public var testBundleByModule: [String: String]? = nil
        /// 빈 package metadata 디렉터리의 capture 관측. 서명된 이력이나 생성 주체 증명은 아니다.
        public var generatedMetadataOrigin: String? = nil
    }

    /// 제외된 경로도 원래 blocker 원인과 함께 남긴다. outside는 실행 생략 허가가 아니다.
    public struct Path: Sendable, Equatable, Codable {
        public let path: String
        public let classification: String
        public let targets: [String]
        public let blockers: [String]
    }
}

/// 캡처 생산자의 주장이다. 해시 일치는 서명이나 빌드 성공 인증이 아니다.
struct TargetScopeReceipt: Codable {
    let format: String
    let version: Int
    let projectRoot: String
    let inputFingerprint: String
    let descriptionJSON: String
    let descriptionSHA256: String
    let selectedTargets: [String]
    let before: [String: String]
    let after: [String: String]
    let buildExitCode: Int
}

/// 설명만으로 현재 소속을 승격하지 않고 전체 소스 목록·바이트와 같은 캡처 지문을 요구한다.
struct TargetScopeStore {
    let fileSystem: any FileSystem
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumFiles = 10_000
    static let sourceBytes = 4 * 1_024 * 1_024

    struct Verified {
        let selected: [String]
        let closure: Set<String>
        let owners: [String: [String]]
    }

    func read(path: String, projectPath: String, fingerprint: String) throws -> Verified {
        let data = try bounded(path, maximum: Self.maximumBytes)
        let receipt = try JSONDecoder().decode(TargetScopeReceipt.self, from: data)
        let root = try fileSystem.realPath(at: projectPath)
        guard receipt.format == "cartograph-swiftpm-target-scope", receipt.version == 1,
              receipt.projectRoot == root, receipt.buildExitCode == 0,
              receipt.inputFingerprint == fingerprint, receipt.before == receipt.after,
              receipt.descriptionSHA256 == Self.digest(Data(receipt.descriptionJSON.utf8)),
              receipt.after.count <= Self.maximumFiles,
              receipt.after == (try inventory(root: root)) else {
            throw invalid("The capture, source inventory, manifest or resolution state no longer matches.")
        }
        let description = try JSONDecoder().decode(Description.self, from: Data(receipt.descriptionJSON.utf8))
        guard try fileSystem.realPath(at: description.path) == root, description.dependencies.isEmpty,
              !description.targets.isEmpty, description.targets.count <= 1_000,
              description.targets.reduce(0, { $0 + $1.sources.count }) <= Self.maximumFiles else {
            throw invalid("Only bounded local SwiftPM targets without external package dependencies are supported.")
        }
        let names = description.targets.map(\.name)
        let modules = description.targets.map(\.c99name)
        guard Set(names).count == names.count, Set(modules).count == modules.count,
              !receipt.selectedTargets.isEmpty, receipt.selectedTargets.count <= 1_000,
              Set(receipt.selectedTargets).count == receipt.selectedTargets.count else {
            throw invalid("Target names, modules or selected target identities are ambiguous.")
        }
        var owners: [String: [String]] = [:]
        let byName = Dictionary(uniqueKeysWithValues: description.targets.map { ($0.name, $0) })
        for target in description.targets {
            guard !target.name.isEmpty, target.name.utf8.count <= 256,
                  !target.c99name.isEmpty, target.c99name.utf8.count <= 256,
                  target.module_type == "SwiftTarget", ["test", "library", "executable"].contains(target.type),
                  target.product_dependencies?.isEmpty ?? true,
                  target.resources?.isEmpty ?? true,
                  (target.target_dependencies ?? []).count <= 1_000,
                  (target.target_dependencies ?? []).allSatisfy({ byName[$0] != nil }),
                  Self.relative(target.path), Set(target.sources).count == target.sources.count else {
                throw invalid("Unsupported target kind, dependency or path leaves membership unknown.")
            }
            for source in target.sources {
                guard Self.relative(source) else { throw invalid("A source path escapes the package root.") }
                let relative = target.path + "/" + source
                let absolute = root + "/" + relative
                guard receipt.after[relative] != nil, try fileSystem.realPath(at: absolute) == absolute else {
                    throw invalid("A declared target source is absent, symlinked or outside the captured inventory.")
                }
                owners[absolute, default: []].append(target.name)
            }
        }
        guard owners.values.allSatisfy({ $0.count == 1 }), receipt.selectedTargets.allSatisfy({
            byName[$0]?.type == "test"
        }) else { throw invalid("Shared source owners or selected non-test targets are unsupported.") }
        var closure: Set<String> = []
        var pending = receipt.selectedTargets
        while let name = pending.popLast() {
            if closure.insert(name).inserted { pending += byName[name]?.target_dependencies ?? [] }
        }
        // 파일을 읽는 동안의 편집도 일치로 보고하지 않는다.
        guard receipt.after == (try inventory(root: root)), data == (try bounded(path, maximum: Self.maximumBytes))
        else { throw invalid("Inputs changed while target membership was being verified.") }
        return Verified(selected: receipt.selectedTargets.sorted(), closure: closure, owners: owners)
    }

    /// Git ignore와 분석 filter를 적용하지 않는다. 빌드 산출물 두 디렉터리 외의 새 소스도 무효화한다.
    func inventory(root: String) throws -> [String: String] {
        var paths: [String] = []
        var pending = [root]
        var entriesSeen = 0
        while let directory = pending.popLast() {
            // 일반 분석 walk는 읽기 실패를 한계로 남긴다. 소속 검증에서는 그 실패를 누락된 빈 목록으로 읽지 않는다.
            for entry in try fileSystem.directoryEntries(at: directory) {
                entriesSeen += 1
                guard entriesSeen <= 50_000 else { throw invalid("Inventory entry budget exceeded.") }
                let name = (entry.path as NSString).lastPathComponent
                guard !entry.isSymbolicLink else { throw invalid("Symlinked inventories are unsupported.") }
                if entry.isDirectory && [".build", ".git"].contains(name) { continue }
                if entry.isDirectory { pending.append(entry.path); continue }
                let source = [".swift", ".m", ".mm", ".h", ".xib", ".storyboard"].contains {
                    entry.path.hasSuffix($0)
                } || name == "Package.resolved"
                if source {
                    guard entry.isRegularFile else { throw invalid("Source inventory contains a nonregular file.") }
                    paths.append(entry.path)
                    guard paths.count <= Self.maximumFiles else { throw invalid("Source file budget exceeded.") }
                }
            }
        }
        var result: [String: String] = [:]
        var bytes = 0
        for path in paths.sorted() {
            guard path.hasPrefix(root + "/"), try fileSystem.realPath(at: path) == path else {
                throw invalid("Noncanonical or symlinked source inventories are unsupported.")
            }
            let data = try bounded(path, maximum: Self.sourceBytes)
            bytes += data.count
            guard bytes <= 64 * 1_024 * 1_024 else { throw invalid("Source inventory exceeds its 64 MiB budget.") }
            result[String(path.dropFirst(root.count + 1))] = Self.digest(data)
        }
        return result
    }

    private struct Description: Decodable {
        let path: String
        let dependencies: [Dependency]
        let targets: [Target]
        struct Dependency: Decodable {}
        struct Target: Decodable {
            let name: String
            let c99name: String
            let module_type: String
            let type: String
            let path: String
            let sources: [String]
            let target_dependencies: [String]?
            let product_dependencies: [String]?
            let resources: [Dependency]?
        }
    }

    private func bounded(_ path: String, maximum: Int) throws -> Data {
        if let stamp = fileSystem.fingerprintStamp(at: path), !stamp.isRegularFile {
            throw invalid("Target scope inputs must be regular files.")
        }
        let data = try fileSystem.readData(at: path, maximumBytes: maximum)
        guard data.count <= maximum else { throw invalid("A target scope input exceeds its byte budget.") }
        return data
    }

    private static func relative(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/") && !path.contains("\\")
            && path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func invalid(_ reason: String) -> CartographError {
        .invalidConfiguration(path: "target-scope", reason: reason)
    }
}

extension CartographService {
    /// 필터 밖 경로도 분류하지만 기존 coverage 경고나 선택 실행 거부를 제거하지 않는다.
    func targetScope(path: String, fingerprint: String?, context: AnalysisContext, limit: Int) -> TargetScopeDocument {
        let probeFileSystem = environment.fileSystem
        let probeResolved = (try? probeFileSystem.realPath(at: path)) ?? path
        if isSensitiveAnalysisEvidencePath(path) || isSensitiveAnalysisEvidencePath(probeResolved) {
            return .init(format: "target-scope-review", version: 1, evidenceStatus: "unknown", selectedTargets: [],
                dependencyTargets: [], schemeIdentity: "unverified", paths: [], pathCount: 0, omittedPaths: 0,
                limitations: ["target-scope-unknown: credential-like evidence path is refused; run the whole suite."])
        }
        if probeFileSystem.fingerprintStamp(at: path)?.isRegularFile != false,
           let data = try? probeFileSystem.readData(at: path, maximumBytes: TargetScopeStore.maximumBytes),
           data.count <= TargetScopeStore.maximumBytes,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["format"] as? String == "cartograph-xcode-target-scope" {
            return xcodeTargetScope(path: path, fingerprint: fingerprint, context: context, limit: limit)
        }
        let fileSystem = environment.fileSystem
        let root = (try? fileSystem.realPath(at: projectPath)) ?? projectPath
        var verified: TargetScopeStore.Verified?
        var notes = ["target-scope: source membership is a capture-bound producer claim, not a signed build receipt, "
            + "test execution, Xcode scheme identity or permission to omit tests; existing coverage blockers remain.",
            "target-scope-inputs: source inventory, manifests, resolution state and the selected snapshot fingerprint "
                + "are compared. Arbitrary resources and build environment are not current completeness evidence; "
                + "resource targets, external dependencies and unsupported target kinds remain unknown."]
        do {
            guard let fingerprint else { throw AnalysisSessionError.unavailable }
            let candidate = try TargetScopeStore(fileSystem: fileSystem).read(path: path, projectPath: root,
                                                                             fingerprint: fingerprint)
            guard fingerprint == (try sessionInputFingerprint()) else {
                throw AnalysisSessionError.inputChangedDuringRefresh(attempts: 1)
            }
            verified = candidate
        } catch {
            verified = nil
            notes.append("target-scope-unknown: \(error). Rebuild and recapture target scope; run the whole suite.")
        }
        let inventory = context.projectFileInventory ?? projectFileInventory()
        let indexed = Set(context.snapshot.sourceFreshnessDates?.keys.map(fileSystem.canonicalPath) ?? [])
        let included = Set(inventory.sourceFiles.map(fileSystem.canonicalPath))
        let excluded = Set(inventory.discoveryExclusions.map(fileSystem.canonicalPath))
        let candidates = Set(inventory.allSourceFiles + inventory.limitationFiles + inventory.discoveryExclusions
            + context.missingSourcePaths + context.unreadableSourcePaths)
        let rows: [TargetScopeDocument.Path] = candidates.sorted().compactMap { original in
            let canonical = fileSystem.canonicalPath(original)
            var blockers: [String] = []
            if !indexed.contains(canonical) { blockers.append("no-observed-index-unit") }
            if !included.contains(canonical) { blockers.append("outside-analysis-source-filter") }
            if excluded.contains(canonical) { blockers.append("source-discovery-exclusion") }
            if context.missingSourcePaths.contains(original) { blockers.append("missing-source") }
            if context.unreadableSourcePaths.contains(original) { blockers.append("unreadable-source") }
            guard !blockers.isEmpty else { return nil }
            let physical = (try? fileSystem.realPath(at: original)) ?? original
            let owners = verified?.owners[physical] ?? []
            let classification: String
            if owners.count == 1, let owner = owners.first, let verified {
                classification = verified.closure.contains(owner) ? "within-selected-targets" : "outside-selected-targets"
            } else { classification = "unknown" }
            return .init(path: physical.hasPrefix(root + "/") ? String(physical.dropFirst(root.count + 1)) : physical,
                         classification: classification, targets: owners.sorted(), blockers: blockers)
        }
        return .init(format: "target-scope-review", version: 1,
            evidenceStatus: verified == nil ? "unknown" : "matched-capture", selectedTargets: verified?.selected ?? [],
            dependencyTargets: verified?.closure.sorted() ?? [], schemeIdentity: "unverified",
            paths: Array(rows.prefix(limit)), pathCount: rows.count, omittedPaths: max(0, rows.count - limit),
            limitations: notes)
    }
}
