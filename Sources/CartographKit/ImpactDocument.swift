import CartographCore

/// 수정 전에 검토할 소비자와 근거를 담는다. 영향 가능성은 실행 결과나 삭제 허가가 아니다.
public struct ImpactDocument: Sendable, Equatable, Codable {
    public let format: String
    public let version: Int
    public let status: String
    public let level: String
    public let requestedSymbols: [String]
    public let requestedFiles: [String]
    /// 이름 또는 파일로 직접 선택한 선언. 실제 편집이 일어났다는 뜻은 아니다.
    public let selected: [SymbolQuery.Subject]
    /// 선택한 타입의 멤버까지 포함한 보수적인 검토 범위.
    public let changeScope: [SymbolQuery.Subject]
    public let affected: [Affected]
    public let summary: Summary
    public let tests: [SymbolQuery.Subject]
    public let entryPoints: [SymbolQuery.Subject]
    public let runtimeReview: [RuntimeReview]
    public let runtimeDependencies: [RuntimeDependency]
    public let automaticRuntime: RuntimeDiscoveryDocument?
    public let observedRuntime: RuntimeTraceReportDocument?
    public let selectionIssues: [SelectionIssue]
    public let limitations: [String]
    public let truncated: Truncation

    /// 경로 배열을 정점마다 복사하지 않고 변경 대상 쪽 선행 정점 한 개로 근거를 공유한다.
    public struct Affected: Sendable, Equatable, Codable {
        public let symbol: SymbolQuery.Subject
        public let depth: Int
        public let via: String
        public let relationship: String
        public let edges: [String]
        /// 실제 호출은 이 요구사항을 향한다. 구현 변경에서 투영한 관계를 직접 호출로 오해하지 않게 한다.
        public let dispatchContract: SymbolQuery.Subject?
        public let runtimeContracts: [String]?
        /// 이 소비자에 연결된 런타임 계약 전체 수. 출력 한도로 생략될 때만 실린다.
        public let runtimeContractsCount: Int?
        /// 이 소비자에 연결된 런타임 계약 중 출력에서 생략한 수.
        public let runtimeContractsOmitted: Int?
        public let runtimeEvidence: [RuntimeEvidenceReference]?
        public let runtimeEvidenceOmitted: Int?
    }

    /// 목록 표시 한도와 무관한 집계. 깊이를 제한했다면 완전한 영향 범위는 아니다.
    public struct Summary: Sendable, Equatable, Codable {
        public let requestedSymbols: Int
        public let requestedFiles: Int
        public let selectedSymbols: Int
        public let changeScopeSymbols: Int
        public let affectedSymbols: Int
        public let fileCount: Int
        public let files: [String]
        public let moduleCount: Int
        public let modules: [String]
        public let testSymbols: Int
        public let entryPoints: Int
        public let runtimeReviewSymbols: Int
        public let runtimeDependencies: Int
        public let unresolvedInputs: Int
    }

    /// 일반 호출 그래프로 다 설명되지 않는 선언은 실행·계약 검토 대상으로 남긴다.
    public struct RuntimeReview: Sendable, Equatable, Codable {
        public let symbol: SymbolQuery.Subject
        public let reasons: [RetentionReason]
        public let externalEvidence: [ExternalRetention.Evidence]
        /// 이 정점의 외부 근거 전체 수. 출력 한도로 생략될 때만 실린다.
        public let externalEvidenceCount: Int?
        /// 이 정점의 외부 근거 중 출력에서 생략한 수.
        public let externalEvidenceOmitted: Int?
        public let runtimeContracts: [String]
        /// 이 정점에 연결된 런타임 계약 전체 수. 출력 한도로 생략될 때만 실린다.
        public let runtimeContractsCount: Int?
        /// 이 정점에 연결된 런타임 계약 중 출력에서 생략한 수.
        public let runtimeContractsOmitted: Int?
    }

    /// 사용자가 선언한 동적 관계. 컴파일러 간선이나 실행 관측인 것처럼 내보내지 않는다.
    public struct RuntimeDependency: Sendable, Equatable, Codable {
        public let contract: String
        public let source: SymbolQuery.Subject?
        public let target: SymbolQuery.Subject?
        public let mechanism: RuntimeContract.Mechanism
        public let status: String
        public let requiredScenarios: [String]
    }

    /// 파일이나 이름이 분석 대상에 없다는 것을 "영향 없음"으로 바꾸지 않는다.
    public struct SelectionIssue: Sendable, Equatable, Codable {
        public let requested: String
        public let kind: String
        public let status: String
        public let candidates: [SymbolQueryDocument.Candidate]?
        public let candidatesOmitted: Int?

        init(requested: String, kind: String, status: String,
             candidates: [SymbolQueryDocument.Candidate]?, candidatesOmitted: Int? = nil) {
            self.requested = requested
            self.kind = kind
            self.status = status
            self.candidates = candidates
            self.candidatesOmitted = candidatesOmitted
        }
    }

    /// 탐색 깊이와 출력 한도를 구분해야 다시 물을 때 무엇을 늘릴지 알 수 있다.
    public struct Truncation: Sendable, Equatable, Codable {
        public let depth: Bool
        public let output: Bool
        public let sections: [String]

        init(depth: Bool, sections: [String]) {
            self.depth = depth
            self.sections = sections.sorted()
            output = !sections.isEmpty
        }
    }

    init(
        status: String,
        requestedSymbols: [String],
        requestedFiles: [String],
        selected: [SymbolQuery.Subject],
        changeScope: [SymbolQuery.Subject],
        affected: [Affected],
        summary: Summary,
        tests: [SymbolQuery.Subject],
        entryPoints: [SymbolQuery.Subject],
        runtimeReview: [RuntimeReview],
        runtimeDependencies: [RuntimeDependency],
        selectionIssues: [SelectionIssue],
        limitations: [String],
        truncated: Truncation,
        automaticRuntime: RuntimeDiscoveryDocument? = nil,
        observedRuntime: RuntimeTraceReportDocument? = nil
    ) {
        format = "change-impact"
        version = 1
        level = "symbol"
        self.status = status
        self.requestedSymbols = requestedSymbols
        self.requestedFiles = requestedFiles
        self.selected = selected
        self.changeScope = changeScope
        self.affected = affected
        self.summary = summary
        self.tests = tests
        self.entryPoints = entryPoints
        self.runtimeReview = runtimeReview
        self.runtimeDependencies = runtimeDependencies
        self.automaticRuntime = automaticRuntime
        self.observedRuntime = observedRuntime
        self.selectionIssues = selectionIssues
        self.limitations = limitations
        self.truncated = truncated
    }
}
