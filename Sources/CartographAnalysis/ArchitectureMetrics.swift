import CartographCore
import Foundation

/// 정점 하나에 대한 타입 구성. 추상도 계산의 입력이다.
public struct TypeComposition: Sendable, Equatable, Codable {
    /// 이 정점에 속한 타입 선언 수.
    public let total: Int
    /// 그중 추상으로 세는 선언 수(프로토콜, 연관타입).
    public let abstract: Int

    public init(total: Int, abstract: Int) {
        self.total = total
        self.abstract = abstract
    }

    /// A = 추상 타입 / 전체 타입. 타입이 없으면 0 으로 본다.
    public var abstractness: Double {
        total == 0 ? 0 : Double(abstract) / Double(total)
    }
}

/// 주계열(main sequence) 기준으로 본 정점의 위치.
public enum MetricsZone: String, Sendable, Codable, CaseIterable {
    /// 추상도와 불안정도가 균형을 이루는 영역.
    case mainSequence = "main-sequence"
    /// 구체적인데 많은 곳이 의존한다. 바꾸기 어렵고 바꿔야 할 일은 많다.
    case zoneOfPain = "zone-of-pain"
    /// 추상적인데 아무도 의존하지 않는다. 대개 죽은 추상화다.
    case zoneOfUselessness = "zone-of-uselessness"
    /// 들어오는 의존도 나가는 의존도 없다. 결합도 지표가 정의되지 않는다.
    ///
    /// 별도 영역으로 두지 않으면 고립 정점이 D=1 로 계산되어 "고통의 영역" 1위를
    /// 차지한다. 실제로는 아무와도 얽혀 있지 않은 정점이라 정반대 상황이다.
    case isolated
}

/// Robert C. Martin 의 패키지 지표.
public struct NodeMetrics: Sendable, Equatable, Codable {
    public let node: NodeID
    public let name: String
    /// Ca. 이 정점에 의존하는 서로 다른 정점 수.
    public let afferentCoupling: Int
    /// Ce. 이 정점이 의존하는 서로 다른 정점 수.
    public let efferentCoupling: Int
    public let composition: TypeComposition

    public init(node: NodeID, name: String, afferentCoupling: Int, efferentCoupling: Int, composition: TypeComposition) {
        self.node = node
        self.name = name
        self.afferentCoupling = afferentCoupling
        self.efferentCoupling = efferentCoupling
        self.composition = composition
    }

    /// I = Ce / (Ca + Ce). 0 이면 완전히 안정, 1 이면 완전히 불안정하다.
    ///
    /// 아무 관계도 없는 고립 정점은 분모가 0 이 된다. 이때는 "바꿔도 아무 데도
    /// 영향이 없다"는 뜻이므로 가장 불안정한 1 이 아니라 0 으로 둔다.
    /// 그렇지 않으면 고립 모듈이 지표 상위를 차지해 신호를 가린다.
    public var instability: Double {
        let denominator = afferentCoupling + efferentCoupling
        return denominator == 0 ? 0 : Double(efferentCoupling) / Double(denominator)
    }

    public var abstractness: Double { composition.abstractness }

    /// D = |A + I − 1|. 주계열에서 얼마나 벗어났는지를 뜻한다.
    public var distanceFromMainSequence: Double {
        abs(abstractness + instability - 1)
    }

    /// 들어오는 의존도 나가는 의존도 없는 정점인지 여부.
    public var isIsolated: Bool {
        afferentCoupling == 0 && efferentCoupling == 0
    }

    /// 주어진 허용 오차 기준으로 어느 영역에 있는지 판단한다.
    public func zone(tolerance: Double) -> MetricsZone {
        if isIsolated { return .isolated }
        guard distanceFromMainSequence > tolerance else { return .mainSequence }
        return abstractness + instability < 1 ? .zoneOfPain : .zoneOfUselessness
    }
}

/// 그래프에서 아키텍처 지표를 계산한다.
public struct ArchitectureMetricsCalculator: Sendable {
    public struct Options: Sendable, Equatable {
        /// 주계열에서 이만큼까지는 정상으로 본다.
        public var tolerance: Double

        public init(tolerance: Double = 0.3) {
            self.tolerance = tolerance
        }
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public var tolerance: Double { options.tolerance }

    /// 타입 구성이 이미 계산되어 있을 때 쓰는 순수 계산 경로.
    ///
    /// 주계열 거리가 큰 순으로 정렬해 돌려준다. 지표는 "가장 위험한 것부터"
    /// 보는 것이 유일하게 쓸모 있는 순서다.
    /// 결합도로 세는 간선 종류.
    ///
    /// 포함 관계(member)는 의존이 아니라 소유다. 이것을 세면 멤버가 많은 타입일수록
    /// 원심 결합도가 커져 심볼 레벨 지표가 통째로 뒤집힌다. 실제로 모든 멤버가
    /// 소유 타입으로부터 Ca=1 을 받아 "고통의 영역"에 몰려 있었다.
    static let couplingEdgeKinds: Set<EdgeKind> = Set(EdgeKind.allCases.filter(\.impliesUsage))
        .subtracting([.retention])

    public func calculate(graph: CodeGraph, compositions: [NodeID: TypeComposition]) -> [NodeMetrics] {
        graph.sortedNodes
            .map { node in
                NodeMetrics(
                    node: node.id,
                    name: node.qualifiedName,
                    afferentCoupling: graph.inDegree(of: node.id, kinds: Self.couplingEdgeKinds),
                    efferentCoupling: graph.outDegree(of: node.id, kinds: Self.couplingEdgeKinds),
                    composition: compositions[node.id] ?? TypeComposition(total: 0, abstract: 0)
                )
            }
            .sorted { lhs, rhs in
                // 고립 정점은 결합도 이야기가 없으므로 순위 맨 아래로 보낸다.
                // 그러지 않으면 D=1 이 되어 정작 봐야 할 정점을 가린다.
                if lhs.isIsolated != rhs.isIsolated { return rhs.isIsolated }
                if lhs.distanceFromMainSequence != rhs.distanceFromMainSequence {
                    return lhs.distanceFromMainSequence > rhs.distanceFromMainSequence
                }
                return lhs.node < rhs.node
            }
    }

    /// 인덱스 스냅샷에서 타입 구성을 세어 지표를 계산한다.
    public func calculate(result: GraphBuilder.BuildResult, snapshot: IndexSnapshot) -> [NodeMetrics] {
        calculate(
            graph: result.graph,
            compositions: Self.typeCompositions(result: result, snapshot: snapshot)
        )
    }

    /// 정점별 타입 구성을 센다.
    ///
    /// 익스텐션은 타입 수에 포함하지 않는다. 같은 타입을 여러 번 세면
    /// 추상도가 익스텐션 개수에 따라 흔들리기 때문이다.
    public static func typeCompositions(
        result: GraphBuilder.BuildResult,
        snapshot: IndexSnapshot
    ) -> [NodeID: TypeComposition] {
        var totals: [NodeID: Int] = [:]
        var abstracts: [NodeID: Int] = [:]

        for symbol in snapshot.symbols {
            guard symbol.kind.isTypeDeclaration, let node = result.nodeIDByUSR[symbol.usr] else { continue }
            totals[node, default: 0] += 1
            if symbol.kind.isAbstract {
                abstracts[node, default: 0] += 1
            }
        }

        return totals.reduce(into: [:]) { result, entry in
            result[entry.key] = TypeComposition(total: entry.value, abstract: abstracts[entry.key] ?? 0)
        }
    }
}
