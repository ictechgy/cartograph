import CartographCore
import Foundation

/// 이미 알고 있는 문제 목록.
///
/// 기존 코드베이스에 도구를 처음 붙이면 수백 건이 한꺼번에 나온다.
/// 그 상태에서 CI 를 켜면 아무도 쓰지 않게 되므로, 현재 상태를 고정하고
/// "새로 생긴 문제"만 실패로 다루는 경로가 반드시 필요하다.
public struct Baseline: Sendable, Codable, Equatable {
    /// 파일 포맷 버전. 앞으로 스키마가 바뀌어도 읽을 수 있게 한다.
    public let version: Int
    public let generatedBy: String
    /// 진단 지문 목록. 정렬되어 있어 파일 diff 가 안정적이다.
    public let fingerprints: [String]

    public static let currentVersion = 1

    public init(fingerprints: some Sequence<String>, generatedBy: String = Cartograph.toolName) {
        self.version = Self.currentVersion
        self.generatedBy = generatedBy
        self.fingerprints = Set(fingerprints).sorted()
    }

    public var isEmpty: Bool { fingerprints.isEmpty }

    public func contains(_ diagnostic: Diagnostic) -> Bool {
        fingerprints.contains(diagnostic.fingerprint)
    }

    /// 베이스라인에 없는 진단만 남긴다.
    public func filtering(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        let known = Set(fingerprints)
        return diagnostics.filter { !known.contains($0.fingerprint) }
    }

    /// 진단 목록으로 새 베이스라인을 만든다.
    ///
    /// 기존 베이스라인과 합치지 않고 대체한다. 합집합으로만 자라면 이미
    /// 고쳐진 문제가 영원히 남아, 나중에는 무엇이 실제로 남아 있는지 알 수 없게 된다.
    public static func capturing(_ diagnostics: [Diagnostic]) -> Baseline {
        Baseline(fingerprints: diagnostics.map(\.fingerprint))
    }

    /// 두 베이스라인을 합친다. 점진적으로 범위를 넓힐 때 쓴다.
    public func merging(_ other: Baseline) -> Baseline {
        Baseline(fingerprints: fingerprints + other.fingerprints)
    }
}

/// 베이스라인 파일 입출력.
public struct BaselineStore: Sendable {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func load(from path: String) throws -> Baseline {
        guard fileSystem.fileExists(at: path) else {
            throw CartographError.invalidBaseline(path: path, reason: "file not found")
        }
        let baseline: Baseline
        do {
            baseline = try JSONDecoder().decode(Baseline.self, from: fileSystem.readData(at: path))
        } catch let error as CartographError {
            throw error
        } catch {
            throw CartographError.invalidBaseline(path: path, reason: "\(error)")
        }

        // 버전을 기록만 하고 검사하지 않으면, 지문 규칙이 바뀐 뒤 옛 파일이
        // 조용히 엉뚱한 진단을 억제한다. 억제는 침묵이라 아무도 알아채지 못한다.
        guard baseline.version == Baseline.currentVersion else {
            throw CartographError.invalidBaseline(
                path: path,
                reason: "format version \(baseline.version) is not supported "
                    + "(this build writes version \(Baseline.currentVersion)). "
                    + "Regenerate it with `cartograph baseline`."
            )
        }
        return baseline
    }

    /// 베이스라인 파일이 있으면 읽고, 없으면 nil 을 돌려준다.
    public func loadIfPresent(at path: String?) throws -> Baseline? {
        guard let path, fileSystem.fileExists(at: path) else { return nil }
        return try load(from: path)
    }

    public func write(_ baseline: Baseline, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileSystem.write(try encoder.encode(baseline), to: path)
    }
}
