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
    ///
    /// - Parameter baseVariants: 프로젝트 루트의 표기들(`PathFilter.variants(of:)`). 주면 루트 안 파일을
    ///   가리키는 `unused-import` 지문을 루트 기준 상대 경로로 적는다. 그 주체는 파일 절대 경로를 품어서,
    ///   그대로 적으면 커밋하는 파일에 기록한 기계의 경로(사용자 홈 포함)가 남고 체크아웃 경로가 다른 CI 에서는
    ///   하나도 맞지 않는다. 읽는 쪽은 `resolvingRelativePaths(againstBaseVariants:)` 로 맞춘다. 루트 밖 파일은
    ///   상대화할 수 없어 그대로 둔다. 비워 두면 예전과 같은 지문이다.
    public static func capturing(
        _ diagnostics: [Diagnostic], relativeToBaseVariants baseVariants: [String] = []
    ) -> Baseline {
        Baseline(fingerprints: diagnostics.map { portableFingerprint(of: $0, baseVariants: baseVariants) })
    }

    /// 상대 경로로 적힌 `unused-import` 지문마다, 이 체크아웃의 루트 표기로 펼친 절대 지문을 더한 사본.
    ///
    /// 진단 주체는 그대로 절대 경로를 품는다(리포트 출력이 바뀌지 않는다). 그래서 대조하는 자리마다 키를 바꾸는
    /// 대신 읽은 베이스라인을 이 루트에 맞춰 펼친다 — 지문을 대조하는 모든 자리가 그대로 맞는다. 절대 경로로 적은
    /// 예전 지문은 건드리지 않으므로 같은 자리에서는 계속 맞는다. 펼칠 지문이 없으면 그대로 돌려준다.
    public func resolvingRelativePaths(againstBaseVariants baseVariants: [String]) -> Baseline {
        let prefix = Self.importFingerprintPrefix
        let resolved = fingerprints.flatMap { fingerprint -> [String] in
            guard fingerprint.hasPrefix(prefix) else { return [] }
            let path = fingerprint.dropFirst(prefix.count)
            guard !path.hasPrefix("/") else { return [] }
            return baseVariants.map { prefix + Self.directoryPrefix($0) + path }
        }
        guard !resolved.isEmpty else { return self }
        return Baseline(fingerprints: fingerprints + resolved, generatedBy: generatedBy)
    }

    /// `unused-import` 지문의 머리. 그 뒤에 파일 경로, `:`, import 표기가 온다.
    private static let importFingerprintPrefix =
        AnalysisDiagnostics.Rule.unusedImport + "|" + AnalysisDiagnostics.unusedImportSubjectPrefix

    /// 루트 안 파일을 가리키는 `unused-import` 지문의 경로를 루트 기준 상대 경로로 바꾼다. 다른 지문은 그대로다.
    ///
    /// 경로는 진단 위치에서 얻는다. 주체에서 경로를 잘라 내면 `:` 가 든 경로를 표기와 가를 수 없다. 루트 밖
    /// 파일은 상대화가 경로를 그대로 돌려주므로 원래 지문과 같다.
    private static func portableFingerprint(of diagnostic: Diagnostic, baseVariants: [String]) -> String {
        guard diagnostic.ruleIdentifier == AnalysisDiagnostics.Rule.unusedImport,
              let location = diagnostic.location, let subject = diagnostic.subject
        else { return diagnostic.fingerprint }
        let absoluteHead = AnalysisDiagnostics.unusedImportSubjectPrefix + location.path + ":"
        guard subject.hasPrefix(absoluteHead) else { return diagnostic.fingerprint }
        let relativePath = location.relative(toBaseVariants: baseVariants).path
        return importFingerprintPrefix + relativePath + ":" + subject.dropFirst(absoluteHead.count)
    }

    /// 상대 경로를 이어 붙일 루트 표기. `SourceLocation.relative(toBaseVariants:)` 처럼 끝 `/` 를 하나로 맞춘다.
    private static func directoryPrefix(_ base: String) -> String {
        base.hasSuffix("/") ? base : base + "/"
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
    ///
    /// 상대 경로가 주어지고 `basePath` 가 있으면 `basePath` 를 기준으로 해결한다.
    /// `path` 가 없고 `basePath` 가 주어지면 기본 베이스라인 파일(`.cartograph-baseline.json`)이
    /// 존재하는지 확인하여 읽는다.
    public func loadIfPresent(at path: String?, basePath: String? = nil) throws -> Baseline? {
        let candidate: String? = if let path {
            (basePath != nil && !path.hasPrefix("/"))
                ? (basePath! as NSString).appendingPathComponent(path)
                : path
        } else if let basePath {
            (basePath as NSString).appendingPathComponent(Cartograph.defaultBaselineFileName)
        } else {
            nil
        }
        guard let resolved = candidate, fileSystem.fileExists(at: resolved) else { return nil }
        return try load(from: resolved)
    }

    public func write(_ baseline: Baseline, to path: String) throws {
        let encoder = JSONEncoder.cartographDefault()
        do {
            try fileSystem.write(try encoder.encode(baseline), to: path)
        } catch {
            // 래핑하지 않으면 파일 쓰기 실패가 종료 코드 1 로 나간다. CI 는 그것을
            // "코드에 문제가 있음"으로 읽는다. 도구가 실패한 것은 2 여야 한다.
            throw CartographError.outputUnwritable(path: path, underlying: "\(error)")
        }
    }
}
