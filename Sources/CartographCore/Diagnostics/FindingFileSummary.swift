/// 파일별 집계는 원래 진단을 대신하거나 억제하지 않고 검토 순서를 돕는다.
public struct FindingFileSummary: Sendable, Equatable, Codable {
    public let path: String
    public let findingCount: Int
    public let ruleCounts: [String: Int]
    public let severityCounts: [String: Int]
    public let generatedMarker: GeneratedMarkerReview?

    /// 파일 이름이나 진단 수만으로 생성 여부를 추측하지 않는다.
    public init(path: String, findingCount: Int, ruleCounts: [String: Int], severityCounts: [String: Int],
                generatedMarker: GeneratedMarkerReview? = nil) {
        self.path = path
        self.findingCount = findingCount
        self.ruleCounts = ruleCounts
        self.severityCounts = severityCounts
        self.generatedMarker = generatedMarker
    }

    /// 관측한 헤더 근거만 더하고 집계는 그대로 둔다.
    public func withGeneratedMarker(_ review: GeneratedMarkerReview) -> Self {
        .init(path: path, findingCount: findingCount, ruleCounts: ruleCounts, severityCounts: severityCounts,
              generatedMarker: review)
    }
}

/// 읽은 앞부분에서 관측한 마커이며, 생성기를 실행했다는 증명은 아니다.
public struct GeneratedMarkerEvidence: Sendable, Equatable, Codable {
    public let line: Int
    public let text: String

    /// 인용 위치와 원문을 보존해 제안을 사람이 확인할 수 있게 한다.
    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

/// 보지 못한 헤더를 마커 없음으로 합치지 않는다.
public struct GeneratedMarkerReview: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case markerObserved, noMarkerInHeader, prefixLimit, unsupportedHeader
        case fileBudget, byteBudget, unreadable, outsideProject, changedDuringRead, invalidUTF8
    }

    public let status: Status
    public let bytesRead: Int
    public let evidence: GeneratedMarkerEvidence?
    /// 헤더를 읽는 사이 파일 지문이 같았는지이며 인덱스 신선도는 아니다.
    public let fileStableDuringRead: Bool?

    /// 결과는 제안용 근거일 뿐 보존 설정이나 그래프를 수정하지 않는다.
    public init(status: Status, bytesRead: Int = 0, evidence: GeneratedMarkerEvidence? = nil,
                fileStableDuringRead: Bool? = nil) {
        self.status = status
        self.bytesRead = bytesRead
        self.evidence = evidence
        self.fileStableDuringRead = fileStableDuringRead
    }

    /// 글롭을 자동 생성하지 않아 특수문자가 다른 파일까지 보존하게 만들지 않는다.
    public var suggestion: String? {
        guard status == .markerObserved else { return nil }
        return "Review the observed header and generator ownership. If appropriate, configure "
            + "retention.retained_files explicitly; this review changes no findings or graph edges."
    }

    private enum CodingKeys: String, CodingKey {
        case status, bytesRead, evidence, fileStableDuringRead, suggestion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        bytesRead = try container.decode(Int.self, forKey: .bytesRead)
        evidence = try container.decodeIfPresent(GeneratedMarkerEvidence.self, forKey: .evidence)
        fileStableDuringRead = try container.decodeIfPresent(Bool.self, forKey: .fileStableDuringRead)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(bytesRead, forKey: .bytesRead)
        try container.encodeIfPresent(evidence, forKey: .evidence)
        try container.encodeIfPresent(fileStableDuringRead, forKey: .fileStableDuringRead)
        try container.encodeIfPresent(suggestion, forKey: .suggestion)
    }
}

/// 전체 진단을 보존하는 선택적 부가 문서. 요약 생략은 진단 생략이 아니다.
public struct FindingReviewDocument: Sendable, Equatable, Codable {
    public let diagnostics: [Diagnostic]
    public let files: [FindingFileSummary]
    public let totalFileCount: Int
    public let unlocatedFindingCount: Int
    public let markerReviewRequested: Bool
    /// 성공적으로 반환된 바이트만 센다. 읽기 실패 중 IO 양은 알 수 없다.
    public let markerBytesRead: Int
    /// 실패한 읽기는 예약한 상한을 소비하므로 관측 바이트 수와 별도로 남긴다.
    public let markerReadBudgetConsumed: Int
    public let limitations: [String]
    public var findingCount: Int { diagnostics.count }
    public var omittedFileCount: Int { totalFileCount - files.count }

    /// 입력 진단의 순서와 중복도 보존해 기존 full 결과와 대조할 수 있다.
    public init(diagnostics: [Diagnostic], files: [FindingFileSummary], totalFileCount: Int,
                unlocatedFindingCount: Int, markerReviewRequested: Bool = false, markerBytesRead: Int = 0,
                markerReadBudgetConsumed: Int = 0, limitations: [String] = []) {
        self.diagnostics = diagnostics
        self.files = files
        self.totalFileCount = totalFileCount
        self.unlocatedFindingCount = unlocatedFindingCount
        self.markerReviewRequested = markerReviewRequested
        self.markerBytesRead = markerBytesRead
        self.markerReadBudgetConsumed = markerReadBudgetConsumed
        self.limitations = limitations
    }

    private enum CodingKeys: String, CodingKey {
        case diagnostics, files, totalFileCount, unlocatedFindingCount, markerReviewRequested, markerBytesRead
        case markerReadBudgetConsumed, limitations, findingCount, omittedFileCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        diagnostics = try container.decode([Diagnostic].self, forKey: .diagnostics)
        files = try container.decode([FindingFileSummary].self, forKey: .files)
        totalFileCount = try container.decode(Int.self, forKey: .totalFileCount)
        unlocatedFindingCount = try container.decode(Int.self, forKey: .unlocatedFindingCount)
        markerReviewRequested = try container.decode(Bool.self, forKey: .markerReviewRequested)
        markerBytesRead = try container.decode(Int.self, forKey: .markerBytesRead)
        markerReadBudgetConsumed = try container.decode(Int.self, forKey: .markerReadBudgetConsumed)
        limitations = try container.decode([String].self, forKey: .limitations)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(diagnostics, forKey: .diagnostics)
        try container.encode(files, forKey: .files)
        try container.encode(totalFileCount, forKey: .totalFileCount)
        try container.encode(unlocatedFindingCount, forKey: .unlocatedFindingCount)
        try container.encode(markerReviewRequested, forKey: .markerReviewRequested)
        try container.encode(markerBytesRead, forKey: .markerBytesRead)
        try container.encode(markerReadBudgetConsumed, forKey: .markerReadBudgetConsumed)
        try container.encode(limitations, forKey: .limitations)
        try container.encode(findingCount, forKey: .findingCount)
        try container.encode(omittedFileCount, forKey: .omittedFileCount)
    }
}
