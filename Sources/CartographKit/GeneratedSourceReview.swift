import CartographAnalysis
import CartographCore
import Foundation

/// 부가 요약의 예산. 기본값은 헤더를 읽지 않아 기존 분석의 IO를 늘리지 않는다.
public struct FindingReviewOptions: Sendable, Equatable {
    public var maximumFiles: Int
    public var inspectGeneratedHeaders: Bool
    public var maximumMarkerFiles: Int
    public var maximumPrefixBytes: Int
    public var maximumTotalBytes: Int

    /// 마커 검사는 반환되는 파일 요약에만 적용하며 나머지 진단은 그대로 보존한다.
    public init(maximumFiles: Int = 200, inspectGeneratedHeaders: Bool = false,
                maximumMarkerFiles: Int = 100, maximumPrefixBytes: Int = 8192,
                maximumTotalBytes: Int = 1024 * 1024) {
        self.maximumFiles = maximumFiles
        self.inspectGeneratedHeaders = inspectGeneratedHeaders
        self.maximumMarkerFiles = maximumMarkerFiles
        self.maximumPrefixBytes = maximumPrefixBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    func validate() throws {
        guard (1...10_000).contains(maximumFiles), (1...2000).contains(maximumMarkerFiles),
              (64...65_536).contains(maximumPrefixBytes), (65...16_777_216).contains(maximumTotalBytes) else {
            throw CartographError.invalidConfiguration(path: "finding-summary",
                reason: "Finding review limits: files 1...10000, marker files 1...2000, "
                    + "prefix bytes 64...65536, total read bytes 65...16777216.")
        }
    }
}

extension CartographService {
    /// 기존 루트 필드는 그대로 두고, 이미 루트에 있는 진단 배열을 중복하지 않는다.
    func appendingFindingReview(_ review: FindingReviewDocument, toJSON output: String) throws -> String {
        let encoded = try JSONEncoder.cartographDefault().encode(review)
        guard var document = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              var annotation = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CartographError.invalidConfiguration(path: projectPath,
                reason: "Finding review requires a JSON object report.")
        }
        annotation.removeValue(forKey: "diagnostics")
        document["findingReview"] = annotation
        let data = try JSONSerialization.data(withJSONObject: document,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// 이미 계산한 진단을 요약한다. 생성 마커 제안은 명시 요청 때만 읽고 설정을 수정하지 않는다.
    ///
    /// 진단 생성 시점과 현재 헤더를 결합한 빌드 근거가 아니다. 커스텀 FileSystem은
    /// maximumBytes 읽기를 실제 IO 전에 제한해야 디스크 메모리 상한도 유지된다.
    public func findingReviewDocument(diagnostics: [Diagnostic], options: FindingReviewOptions = .init()) throws
        -> FindingReviewDocument {
        try options.validate()
        let summary = try FindingFileSummarizer.summarize(diagnostics, maximumFiles: options.maximumFiles)
        guard options.inspectGeneratedHeaders else { return summary }
        var reader = GeneratedHeaderReader(fileSystem: environment.fileSystem, projectPath: projectPath,
            options: options)
        let files = summary.files.map { file in file.withGeneratedMarker(reader.review(file.path)) }
        let limits = summary.limitations + [
            "generated-marker-scope: only leading ordinary // comments in bounded UTF-8 prefixes are inspected; "
                + "block/doc comments and unrecognized markers remain unassessed.",
            "generated-marker-provenance: a marker is a source assertion, not proof of generator execution, "
                + "current index freshness, or permission to remove code. All findings and graph edges are preserved.",
            "generated-marker-budget: at most \(options.maximumMarkerFiles) files, "
                + "\(options.maximumPrefixBytes) prefix bytes per file, \(options.maximumTotalBytes) total read bytes "
                + "including one lookahead byte per read."
        ]
        return .init(diagnostics: summary.diagnostics, files: files, totalFileCount: summary.totalFileCount,
            unlocatedFindingCount: summary.unlocatedFindingCount, markerReviewRequested: true,
            markerBytesRead: reader.bytesRead, markerReadBudgetConsumed: reader.budgetConsumed, limitations: limits)
    }
}

private struct GeneratedHeaderReader {
    let fileSystem: any FileSystem
    let projectPath: String
    let options: FindingReviewOptions
    let root: String?
    var attempts = 0
    var bytesRead = 0
    var budgetConsumed = 0

    init(fileSystem: any FileSystem, projectPath: String, options: FindingReviewOptions) {
        self.fileSystem = fileSystem
        self.projectPath = projectPath
        self.options = options
        root = try? fileSystem.realPath(at: projectPath)
    }

    mutating func review(_ path: String) -> GeneratedMarkerReview {
        guard attempts < options.maximumMarkerFiles else { return .init(status: .fileBudget) }
        let remaining = options.maximumTotalBytes - budgetConsumed
        guard remaining > 1 else { return .init(status: .byteBudget) }
        attempts += 1
        let input = path.hasPrefix("/") ? path : (projectPath as NSString).appendingPathComponent(path)
        guard let root, let resolved = try? fileSystem.realPath(at: input) else {
            return .init(status: .unreadable)
        }
        let boundary = root.hasSuffix("/") ? root : root + "/"
        guard resolved.hasPrefix(boundary) else { return .init(status: .outsideProject) }
        let limit = min(options.maximumPrefixBytes, remaining - 1)
        let before = fileSystem.fingerprintStamp(at: resolved)
        do {
            let data = try fileSystem.readData(at: resolved, maximumBytes: limit)
            bytesRead += data.count
            budgetConsumed += min(data.count, remaining)
            // 과도하게 반환하는 커스텀 파일 시스템도 문서의 예산을 넘겨 처리하지 않는다.
            guard data.count <= limit + 1 else {
                return .init(status: .unreadable, bytesRead: data.count)
            }
            let after = fileSystem.fingerprintStamp(at: resolved)
            guard before == after, (try? fileSystem.realPath(at: input)) == resolved else {
                return .init(status: .changedDuringRead, bytesRead: data.count, fileStableDuringRead: false)
            }
            guard let prefix = String(data: data.prefix(limit), encoding: .utf8) else {
                return .init(status: .invalidUTF8, bytesRead: data.count)
            }
            let result = GeneratedSourceMarker.inspect(prefix: prefix, hasMoreBytes: data.count > limit)
            return .init(status: result.status, bytesRead: data.count, evidence: result.evidence,
                fileStableDuringRead: before == nil ? nil : true)
        } catch {
            // 실패한 읽기도 요청 예산을 소비해 반복 오류로 IO 상한을 늘리지 않는다.
            budgetConsumed += limit + 1
            return .init(status: .unreadable)
        }
    }
}
