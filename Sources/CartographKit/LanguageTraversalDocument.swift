import CartographCore

/// isthmus `language-traversal` v1 문서. 한 번의 다중 root 순회와 정점별 root 출처를 담는다.
///
/// 정본 계약은 `../isthmus/docs/LANGUAGE-TRAVERSAL.md` 다. isthmus 는 정의되지 않은 필드를 거부하므로
/// 여기에는 계약의 필드만 둔다. 없는 선택 필드는 키가 빠진다(합성 인코딩이 `encodeIfPresent` 를 쓴다).
/// `dispatch`·`unresolvedCalls` 는 싣지 않는다 — Swift 인덱스는 매개변수·지역 변수에 담긴 클로저
/// 호출을 기록하지 않아 잇지 못한 호출을 빠짐없이 셀 수 없고, `dispatch` 는 그 완전한 신고의 선언이다.
/// 근거 등급 분류는 모든 도달 정점에 `evidence` 를 명시해 선언한다.
public struct LanguageTraversalDocument: Sendable, Equatable, Encodable {
    /// 순회 정점의 신원. `usr` 는 routes·bridges 사실의 `symbol.usr` 와 같은 문자열이다.
    public struct Symbol: Sendable, Equatable, Encodable {
        public let usr: String
        /// 감싸는 타입까지 붙인 구문 표기(`ProfileView.body`). 모듈은 붙이지 않는다.
        public let qualifiedName: String
        public let kind: String
        /// 프로젝트 상대 위치. 프로젝트 밖이면 생략한다.
        public let location: SourceLocation?
    }

    /// 순회의 시작점. 해석하지 못한 요청은 원문을 `id` 에 두고 `symbol` 을 생략한다.
    public struct Root: Sendable, Equatable, Encodable {
        public let id: String
        public let symbol: Symbol?
    }

    /// 순회가 도달한 정점 하나.
    public struct Reached: Sendable, Equatable, Encodable {
        public let symbol: Symbol
        public let via: String
        public let depth: Int
        public let roots: [Int]
        public let relationships: [String]
        public let evidence: String
    }

    public let format = "language-traversal"
    public let version = 1
    public let tool: BridgeFactsDocument.Tool
    public let generatedAt: String
    public let platform = "swift"
    public let project: String
    public let direction: String
    public let roots: [Root]
    public let reached: [Reached]
    /// 정점 하나가 64개를 넘는 root 에 닿아 목록을 잘랐을 때만 `true` 로 싣는다.
    public let rootsTruncated: Bool?
    public let truncated: Bool
    /// `truncated` 가 참일 때만 싣는 정렬된 사유(`depth`·`output`·`root-not-found`).
    public let truncationReasons: [String]?
    public let limitations: [String]

    private enum CodingKeys: String, CodingKey {
        case format, version, tool, generatedAt, platform, project, direction, roots, reached
        case rootsTruncated, truncated, truncationReasons, limitations
    }

    init(
        tool: BridgeFactsDocument.Tool, generatedAt: String, project: String, direction: String,
        roots: [Root], reached: [Reached], rootsTruncated: Bool, truncationReasons: [String], limitations: [String]
    ) {
        self.tool = tool
        self.generatedAt = generatedAt
        self.project = project
        self.direction = direction
        self.roots = roots
        self.reached = reached
        self.rootsTruncated = rootsTruncated ? true : nil
        let reasons = Set(truncationReasons).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        truncated = !reasons.isEmpty
        self.truncationReasons = reasons.isEmpty ? nil : reasons
        self.limitations = limitations
    }
}
