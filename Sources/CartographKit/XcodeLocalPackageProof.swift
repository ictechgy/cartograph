import CartographCore
import Foundation

/// v2 선택 한 번의 관측 경계. 파일 시각이나 generic 입력 지문만으로 record/object를 재사용하지 않는다.
struct XcodeLocalPackageProof {
    let path: String
    let root: String
    let fingerprint: String
    let receiptDigest: String
    let indexStore: String

    func verify(fileSystem: any FileSystem) throws {
        let before = try XcodeLocalPackageIO.bounded(path, maximum: 8 * 1_024 * 1_024, fileSystem: fileSystem)
        guard TargetScopeStore.digest(before) == receiptDigest else {
            throw XcodeLocalPackageIO.invalid("Package receipt changed during fresh analysis.")
        }
        let verified = try XcodeTargetScopeStore(fileSystem: fileSystem).read(path: path, root: root, fingerprint: fingerprint)
        guard [2, 3].contains(verified.receipt.version), !verified.receipt.packages.isEmpty,
              before == (try XcodeLocalPackageIO.bounded(path, maximum: 8 * 1_024 * 1_024, fileSystem: fileSystem)) else {
            throw XcodeLocalPackageIO.invalid("Package receipt or proof inputs changed during fresh analysis.")
        }
    }
}

extension CartographService {
    /// 먼저 전체 proof를 검증한 후에만 새 raw 문맥을 읽도록 v2를 식별한다. v1에는 비용을 추가하지 않는다.
    func localPackageProof(path: String, fingerprint: String) throws -> XcodeLocalPackageProof? {
        let fileSystem = environment.fileSystem
        // Preserve the existing v1 SDK path semantics while probing the version. Canonical
        // absolute paths are a v2 proof requirement, enforced by verify() only after admission.
        let resolved = (try? fileSystem.realPath(at: path)) ?? path
        guard !isSensitiveAnalysisEvidencePath(path), !isSensitiveAnalysisEvidencePath(resolved) else {
            throw AnalysisSessionError.sensitiveInput
        }
        guard fileSystem.fingerprintStamp(at: path)?.isRegularFile != false else {
            throw XcodeLocalPackageIO.invalid("Target scope inputs must be regular files.")
        }
        let data = try fileSystem.readData(at: path, maximumBytes: 8 * 1_024 * 1_024)
        guard data.count <= 8 * 1_024 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XcodeLocalPackageIO.invalid("Invalid or oversized target scope receipt.")
        }
        guard object["format"] as? String == "cartograph-xcode-target-scope",
              [2, 3].contains(object["version"] as? Int ?? 0) else { return nil }
        let packages = (object["localPackages"] as? [[String: Any]]) ?? (object["localPackage"] as? [String: Any]).map { [$0] } ?? []
        if object["version"] as? Int == 3 && packages.isEmpty { return nil }
        guard environment.indexProviderOverride == nil else {
            throw XcodeLocalPackageIO.invalid("Version 2 requires a fresh native raw index read; custom snapshot providers are unsupported.")
        }
        guard let indexStore = packages.first?["indexStore"] as? String,
              packages.allSatisfy({ $0["indexStore"] as? String == indexStore }) else {
            throw XcodeLocalPackageIO.invalid("Version 2 requires an explicit captured package index store.")
        }
        let proof = XcodeLocalPackageProof(path: XcodeEvidencePath.physicalTemporaryAlias(path, fileSystem: fileSystem), root: try fileSystem.realPath(at: projectPath),
            fingerprint: fingerprint, receiptDigest: TargetScopeStore.digest(data), indexStore: indexStore)
        try proof.verify(fileSystem: fileSystem)
        return proof
    }
}
