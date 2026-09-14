import CartographCore
import Foundation

/// 실행 시에만 확인할 수 있는 계약과 애플리케이션이 제출한 관측을 대조한다.
///
/// 이 타입은 프로세스를 실행하거나 관측 파일을 신뢰한다고 증명하지 않는다. 관측은
/// 호출자가 준비한 테스트의 주장이고, 이 검증기는 현재 그래프의 선언과 그 주장을
/// 결정적으로 비교할 뿐이다.
public struct RuntimeContractValidator: Sendable {
    public init() {}

    /// 계약의 선언·관측 상태를 계산한다.
    public func validate(
        contracts: [RuntimeContract],
        observations: [RuntimeObservation]? = nil,
        observationsMatchPlan: Bool = true,
        freshness: [NodeID: RuntimeFreshness]? = nil,
        in graph: CodeGraph
    ) -> RuntimeContractReport {
        let lookup = GraphQueryIndex(graph: graph)
        let idCounts = contracts.reduce(into: [String: Int]()) { counts, contract in
            counts[contract.id, default: 0] += 1
        }
        let duplicateIDs = Set(idCounts.compactMap { $0.value > 1 ? $0.key : nil })
        let knownIDs = Set(contracts.map(\.id))
        let groupedObservations = observations.map { Self.group($0, knownIDs: knownIDs) }
        let unexpected = Set((observations ?? []).map(\.contract).filter { !knownIDs.contains($0) }).sorted()
        let results = contracts.map { contract in
            validate(
                contract,
                duplicate: duplicateIDs.contains(contract.id),
                lookup: lookup,
                observations: observations == nil ? nil : (groupedObservations?[contract.id] ?? []),
                observationsMatchPlan: observationsMatchPlan,
                freshness: freshness,
                graph: graph
            )
        }
        return RuntimeContractReport(results: results, unexpectedContracts: unexpected)
    }

    private func validate(
        _ contract: RuntimeContract,
        duplicate: Bool,
        lookup: GraphQueryIndex,
        observations: [RuntimeObservation]?,
        observationsMatchPlan: Bool,
        freshness: [NodeID: RuntimeFreshness]?,
        graph: CodeGraph
    ) -> RuntimeContractResult {
        guard Self.isValid(contract), !duplicate else {
            return .init(contractID: contract.id, status: .invalidContract)
        }

        let source = contract.source.map(lookup.resolve)
        let target = lookup.resolve(contract.target)
        let sourceStatus = Self.bindingStatus(source, source: true)
        let targetStatus = Self.bindingStatus(target, source: false)
        let sourceNode = Self.node(from: source)
        let targetNode = Self.node(from: target)
        let sourceCandidates = Self.candidates(from: source)
        let targetCandidates = Self.candidates(from: target)
        let sourceFreshness = sourceNode.map { node in
            freshness.map { entries in entries[node.id] ?? .unknownIndexDate } ?? .notChecked
        } ?? .notApplicable
        let targetFreshness = targetNode.map { node in
            freshness.map { entries in entries[node.id] ?? .unknownIndexDate } ?? .notChecked
        } ?? .notChecked
        guard sourceStatus == nil, targetStatus == nil else {
            return .init(
                contractID: contract.id,
                source: sourceNode,
                target: targetNode,
                status: sourceStatus ?? targetStatus ?? .declared,
                sourceCandidates: sourceCandidates,
                targetCandidates: targetCandidates,
                sourceFreshness: sourceFreshness,
                targetFreshness: targetFreshness
            )
        }
        if Self.hasInvalidMechanism(contract.mechanism, target: targetNode, in: graph) {
            return .init(
                contractID: contract.id,
                source: sourceNode,
                target: targetNode,
                status: .invalidMechanism,
                sourceCandidates: sourceCandidates,
                targetCandidates: targetCandidates,
                sourceFreshness: sourceFreshness,
                targetFreshness: targetFreshness
            )
        }
        if freshness != nil {
            if sourceFreshness != .fresh, sourceFreshness != .notApplicable {
                return .init(
                    contractID: contract.id,
                    source: sourceNode,
                    target: targetNode,
                    status: .unverifiedSource,
                    sourceCandidates: sourceCandidates,
                    targetCandidates: targetCandidates,
                    sourceFreshness: sourceFreshness,
                    targetFreshness: targetFreshness
                )
            }
            if targetFreshness != .fresh {
                return .init(
                    contractID: contract.id,
                    source: sourceNode,
                    target: targetNode,
                    status: .unverifiedTarget,
                    sourceCandidates: sourceCandidates,
                    targetCandidates: targetCandidates,
                    sourceFreshness: sourceFreshness,
                    targetFreshness: targetFreshness
                )
            }
        }
        guard let supplied = observations else {
            return .init(
                contractID: contract.id,
                source: sourceNode,
                target: targetNode,
                status: .declared,
                sourceCandidates: sourceCandidates,
                targetCandidates: targetCandidates,
                sourceFreshness: sourceFreshness,
                targetFreshness: targetFreshness
            )
        }
        guard observationsMatchPlan else {
            return .init(
                contractID: contract.id,
                source: sourceNode,
                target: targetNode,
                status: .staleObservations,
                sourceCandidates: sourceCandidates,
                targetCandidates: targetCandidates,
                sourceFreshness: sourceFreshness,
                targetFreshness: targetFreshness,
                missingScenarios: contract.requiredScenarios.sorted()
            )
        }
        var observed: [String] = []
        var missing: [String] = []
        var failed: [String] = []
        let byScenario = Dictionary(grouping: supplied, by: \.scenario)
        for scenario in contract.requiredScenarios.sorted() {
            guard let events = byScenario[scenario], !events.isEmpty else {
                missing.append(scenario)
                continue
            }
            if events.contains(where: { $0.outcome == .failed })
                || events.contains(where: { event in
                    event.outcome == .observed && contract.expectedValue != nil
                        && event.value != contract.expectedValue
                }) {
                failed.append(scenario)
            } else {
                observed.append(scenario)
            }
        }
        let status: RuntimeContractResult.Status
        if !failed.isEmpty {
            status = .failed
        } else if missing.isEmpty {
            status = .observed
        } else {
            status = .unobserved
        }
        return .init(
            contractID: contract.id,
            source: sourceNode,
            target: targetNode,
            status: status,
            sourceCandidates: sourceCandidates,
            targetCandidates: targetCandidates,
            sourceFreshness: sourceFreshness,
            targetFreshness: targetFreshness,
            observedScenarios: observed,
            missingScenarios: missing,
            failedScenarios: failed
        )
    }

    private static func hasInvalidMechanism(
        _ mechanism: RuntimeContract.Mechanism,
        target: GraphNode?,
        in graph: CodeGraph
    ) -> Bool {
        guard let target else { return false }
        switch mechanism {
        case .selector:
            return !isSelectorEligible(target, in: graph)
        case .classLookup:
            return target.kind != .classType
        default:
            return false
        }
    }

    private static func isSelectorEligible(_ target: GraphNode, in graph: CodeGraph) -> Bool {
        let callableKinds: Set<SymbolKind> = [
            .method, .initializer, .deinitializer, .subscriptDeclaration,
        ]
        guard callableKinds.contains(target.kind) else { return false }
        // Swift의 dynamic/replacement 표식만으로는 Objective-C 메서드가 생성되지 않는다.
        let objcAttributes: Set<SymbolAttribute> = [.objc, .objcMembers, .objcAccessible]
        if !target.attributes.isDisjoint(with: objcAttributes) || target.usr?.hasPrefix("c:") == true {
            return true
        }

        var current = graph.semanticParent(of: target.id)
        var visited: Set<NodeID> = []
        while let parent = current, visited.insert(parent).inserted {
            guard let node = graph.node(parent) else { break }
            if node.attributes.contains(.objcMembers) { return true }
            current = graph.semanticParent(of: parent)
        }
        return false
    }

    private static func isValid(_ contract: RuntimeContract) -> Bool {
        let idValid = !contract.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let targetValid = !contract.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let scenarios = contract.requiredScenarios
        return idValid && targetValid && !scenarios.isEmpty
            && scenarios.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && Set(scenarios).count == scenarios.count
    }

    private static func group(
        _ observations: [RuntimeObservation],
        knownIDs: Set<String>
    ) -> [String: [RuntimeObservation]] {
        Dictionary(grouping: observations.filter { knownIDs.contains($0.contract) }, by: \.contract)
    }

    private static func bindingStatus(
        _ lookup: GraphNodeLookup?,
        source: Bool
    ) -> RuntimeContractResult.Status? {
        switch lookup {
        case nil, .some(.found): return nil
        case .some(.ambiguous): return source ? .ambiguousSource : .ambiguousTarget
        case .some(.notFound): return source ? .missingSource : .missingTarget
        }
    }

    private static func node(from lookup: GraphNodeLookup?) -> GraphNode? {
        guard case let .found(node)? = lookup else { return nil }
        return node
    }

    private static func candidates(from lookup: GraphNodeLookup?) -> [GraphNode] {
        guard case let .ambiguous(nodes)? = lookup else { return [] }
        return nodes.sorted { lhs, rhs in
            let left = (lhs.location?.path ?? "", lhs.location?.line ?? 0, lhs.id.rawValue)
            let right = (rhs.location?.path ?? "", rhs.location?.line ?? 0, rhs.id.rawValue)
            return left < right
        }
    }
}

/// 계약 하나의 현재 그래프 결합과 실행 근거 상태.
public struct RuntimeContractResult: Sendable, Equatable, Codable {
    /// 결과 상태. `unobserved`와 `declared`는 삭제 안전성을 뜻하지 않는다.
    public enum Status: String, Sendable, Equatable, Codable, CaseIterable {
        case declared
        case observed
        case unobserved
        case failed
        case missingSource
        case ambiguousSource
        case missingTarget
        case ambiguousTarget
        case staleObservations
        case invalidContract
        case invalidMechanism
        case unverifiedSource
        case unverifiedTarget
    }

    public let contractID: String
    public let source: GraphNode?
    public let target: GraphNode?
    public let status: Status
    public let sourceFreshness: RuntimeFreshness
    public let targetFreshness: RuntimeFreshness
    public let sourceCandidates: [GraphNode]
    public let targetCandidates: [GraphNode]
    public let observedScenarios: [String]
    public let missingScenarios: [String]
    public let failedScenarios: [String]

    public init(
        contractID: String,
        source: GraphNode? = nil,
        target: GraphNode? = nil,
        status: Status,
        sourceCandidates: [GraphNode] = [],
        targetCandidates: [GraphNode] = [],
        sourceFreshness: RuntimeFreshness = .notChecked,
        targetFreshness: RuntimeFreshness = .notChecked,
        observedScenarios: [String] = [],
        missingScenarios: [String] = [],
        failedScenarios: [String] = []
    ) {
        self.contractID = contractID
        self.source = source
        self.target = target
        self.status = status
        self.sourceFreshness = sourceFreshness
        self.targetFreshness = targetFreshness
        self.sourceCandidates = sourceCandidates
        self.targetCandidates = targetCandidates
        self.observedScenarios = observedScenarios
        self.missingScenarios = missingScenarios
        self.failedScenarios = failedScenarios
    }
}

/// 런타임 계약 검증 결과 전체.
public struct RuntimeContractReport: Sendable, Equatable, Codable {
    public let results: [RuntimeContractResult]
    public let unexpectedContracts: [String]

    public init(results: [RuntimeContractResult], unexpectedContracts: [String] = []) {
        self.results = results.sorted { $0.contractID < $1.contractID }
        self.unexpectedContracts = unexpectedContracts.sorted()
    }
}
