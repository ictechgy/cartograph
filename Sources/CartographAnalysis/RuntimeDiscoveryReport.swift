import CartographCore

/// 정적 발견의 확실성과 미해결 원인을 분리한다. 실행 관측을 뜻하는 상태는 없다.
public enum RuntimeDiscoveryStatus: String, Codable, Sendable, CaseIterable {
    case resolved, alreadyIndexed, lookupOnly, unresolved, ambiguous, dynamic, shadowed, stale, unindexed
}

/// 인식한 경계는 반드시 하나의 판정을 남겨 조용히 빠진 입력을 숨기지 않는다.
public struct RuntimeDiscoveryFinding: Codable, Sendable, Equatable {
    public let boundary: RuntimeBoundary
    public let status: RuntimeDiscoveryStatus
    public let source: NodeID?
    public let targets: [NodeID]
    public let candidates: [NodeID]
    public let reason: String?

    /// 확정한 연결과 아직 검토해야 하는 후보를 다른 필드에 담는다.
    public init(boundary: RuntimeBoundary, status: RuntimeDiscoveryStatus, source: NodeID? = nil,
                targets: [NodeID] = [], candidates: [NodeID] = [], reason: String? = nil) {
        self.boundary = boundary
        self.status = status
        self.source = source
        self.targets = Array(Set(targets)).sorted()
        self.candidates = Array(Set(candidates)).sorted()
        self.reason = reason
    }
}

/// 일반 컴파일러 간선과 구분해서 영향 질의에만 더하는 자동 발견 관계.
public struct RuntimeStaticConnection: Codable, Sendable, Equatable {
    public let boundaryID: String
    public let kind: RuntimeBoundaryKind
    public let source: NodeID?
    public let target: NodeID
    public let location: SourceLocation
}

/// 전체 경계의 상태와 근거를 고정한 순수 분석 결과.
public struct RuntimeDiscoveryReport: Codable, Sendable, Equatable {
    public let findings: [RuntimeDiscoveryFinding]
    public let limitations: [String]

    /// 입력 순서에 따라 리포트가 달라지지 않도록 출처 순으로 정렬한다.
    public init(findings: [RuntimeDiscoveryFinding], limitations: [String] = []) {
        self.findings = findings.sorted { $0.boundary.id < $1.boundary.id }
        self.limitations = Array(Set(limitations)).sorted()
    }

    /// 확인한 정적 연결만 꺼낸다. 후보·조회 문자열은 간선으로 승격하지 않는다.
    public var connections: [RuntimeStaticConnection] {
        findings.filter { $0.status == .resolved }.flatMap { finding in
            finding.targets.map { target in
                .init(boundaryID: finding.boundary.id, kind: finding.boundary.kind,
                    source: finding.source, target: target, location: finding.boundary.location)
            }
        }
    }
}
