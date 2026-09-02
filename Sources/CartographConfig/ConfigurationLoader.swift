import CartographCore
import Foundation
import Yams

/// `.cartograph.yml` 을 찾아 읽어 설정 값으로 바꾼다.
///
/// 알 수 없는 키는 오류가 아니라 경고로 처리한다. 오타 하나 때문에 CI 가
/// 통째로 멈추는 것보다, 무엇이 무시되었는지 알려 주는 편이 낫기 때문이다.
public struct ConfigurationLoader: Sendable {
    /// 설정 로드 결과. 경고는 사용자에게 그대로 출력한다.
    public struct LoadResult: Sendable, Equatable {
        public let configuration: CartographConfiguration
        public let warnings: [String]
        /// 실제로 읽은 파일 경로. 설정 파일이 없으면 nil.
        public let path: String?

        public init(configuration: CartographConfiguration, warnings: [String] = [], path: String? = nil) {
            self.configuration = configuration
            self.warnings = warnings
            self.path = path
        }
    }

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// 디렉터리에서 설정 파일을 찾는다. `.yml` 을 `.yaml` 보다 먼저 본다.
    public func discoverConfigurationFile(in directory: String) -> String? {
        let candidates = [Cartograph.defaultConfigurationFileName, ".cartograph.yaml"]
        for candidate in candidates {
            let path = (directory as NSString).appendingPathComponent(candidate)
            if fileSystem.fileExists(at: path) { return path }
        }
        return nil
    }

    /// 명시 경로가 있으면 그 파일을, 없으면 디렉터리에서 찾은 파일을 읽는다.
    ///
    /// 설정 파일이 아예 없으면 기본 설정을 돌려준다. 설정 없이도 도구가
    /// 동작해야 첫 사용 장벽이 낮아진다.
    public func load(explicitPath: String?, searchDirectory: String) throws -> LoadResult {
        guard let path = explicitPath ?? discoverConfigurationFile(in: searchDirectory) else {
            return LoadResult(configuration: .default)
        }
        let contents: String
        do {
            contents = try fileSystem.readText(at: path)
        } catch {
            throw CartographError.invalidConfiguration(path: path, reason: "file could not be read")
        }
        return try load(yaml: contents, path: path)
    }

    /// YAML 문자열을 설정으로 해석한다.
    public func load(yaml: String, path: String) throws -> LoadResult {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LoadResult(configuration: .default, warnings: [], path: path)
        }

        let configuration: CartographConfiguration
        do {
            configuration = try YAMLDecoder().decode(CartographConfiguration.self, from: yaml)
        } catch let error as DecodingError {
            throw CartographError.invalidConfiguration(path: path, reason: Self.describe(error))
        } catch {
            throw CartographError.invalidConfiguration(path: path, reason: "\(error)")
        }

        try configuration.validate()
        return LoadResult(
            configuration: configuration,
            warnings: try Self.unknownKeyWarnings(in: yaml, path: path),
            path: path
        )
    }

    // MARK: - 알 수 없는 키 경고

    /// 설정 스키마에서 인정하는 키 목록. 중첩 매핑은 별도로 검사한다.
    private static let knownTopLevelKeys: Set<String> = [
        "index_store_path", "project_path", "derived_data_path", "level", "include", "exclude",
        "edge_kinds", "retention", "layers", "rules", "thresholds", "baseline_path",
        "report_format", "graph_format", "strict",
    ]
    private static let knownRetentionKeys: Set<String> = [
        "retain_public", "retain_objc_accessible", "retain_interface_builder", "retain_tests",
        "retain_previews", "retain_codable_properties", "retain_raw_representable_enum_cases",
        "retained_names", "retained_files", "external_test_case_classes",
    ]
    private static let knownThresholdKeys: Set<String> = [
        "max_cycles", "max_unused_symbols", "max_rule_violations", "max_instability", "max_distance",
    ]

    static func unknownKeyWarnings(in yaml: String, path: String) throws -> [String] {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else { return [] }
        var warnings = unknown(keys: root.keys, allowed: knownTopLevelKeys, scope: nil, path: path)
        if let retention = root["retention"] as? [String: Any] {
            warnings += unknown(keys: retention.keys, allowed: knownRetentionKeys, scope: "retention", path: path)
        }
        if let thresholds = root["thresholds"] as? [String: Any] {
            warnings += unknown(keys: thresholds.keys, allowed: knownThresholdKeys, scope: "thresholds", path: path)
        }
        return warnings.sorted()
    }

    private static func unknown(
        keys: some Collection<String>,
        allowed: Set<String>,
        scope: String?,
        path: String
    ) -> [String] {
        keys.filter { !allowed.contains($0) }.map { key in
            let qualified = scope.map { "\($0).\(key)" } ?? key
            return "\(path): unknown configuration key '\(qualified)' was ignored"
        }
    }

    /// 디코딩 오류를 사용자가 고칠 수 있는 문장으로 바꾼다.
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .typeMismatch(type, context):
            return "expected \(type) at '\(Self.path(of: context))'"
        case let .valueNotFound(type, context):
            return "missing value of type \(type) at '\(Self.path(of: context))'"
        case let .keyNotFound(key, context):
            let prefix = Self.path(of: context)
            return "missing required key '\(prefix.isEmpty ? key.stringValue : "\(prefix).\(key.stringValue)")'"
        case let .dataCorrupted(context):
            let location = Self.path(of: context)
            return location.isEmpty ? context.debugDescription : "\(context.debugDescription) at '\(location)'"
        @unknown default:
            return "\(error)"
        }
    }

    private static func path(of context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}
