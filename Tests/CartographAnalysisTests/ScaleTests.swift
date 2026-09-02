import CartographAnalysis
import CartographCore
import CartographTestSupport
import Foundation
import Testing

/// 대규모 그래프에서 파이프라인이 선형에 가깝게 동작하는지 확인한다.
///
/// 실제 iOS 앱은 심볼이 수만 개다. 작은 픽스처만으로는 알고리즘에 숨은
/// 이차 비용을 절대 발견할 수 없고, 발견될 때는 이미 사용자가 겪은 뒤다.
@Suite("대규모 입력")
struct ScaleTests {
    /// 타입 2,000개와 각 타입당 멤버 9개, 타입 사이 참조가 있는 스냅샷.
    private func makeLargeSnapshot(typeCount: Int, membersPerType: Int) -> IndexSnapshot {
        var builder = SnapshotBuilder()
        builder.symbol("App", kind: .structType, module: "App", attributes: [.entryPoint])

        for typeIndex in 0..<typeCount {
            let type = "T\(typeIndex)"
            builder.symbol(
                type, kind: .classType, module: "M\(typeIndex % 20)",
                path: "/p/M\(typeIndex % 20)/\(type).swift", line: 1
            )
            for memberIndex in 0..<membersPerType {
                let member = "\(type).m\(memberIndex)"
                builder.symbol(
                    member, name: "m\(memberIndex)()", kind: .method,
                    module: "M\(typeIndex % 20)", path: "/p/M\(typeIndex % 20)/\(type).swift",
                    line: memberIndex + 2, parent: type
                )
                // 첫 멤버가 다음 타입의 첫 멤버를 호출해 2,000 단계 사슬을 만든다.
                // 포함 관계는 사용을 뜻하지 않으므로 사슬은 멤버를 통해서만 이어진다.
                if memberIndex == 0, typeIndex + 1 < typeCount {
                    builder.reference(from: member, to: "T\(typeIndex + 1)", kind: .reference)
                    builder.reference(from: member, to: "T\(typeIndex + 1).m0", kind: .call)
                }
            }
            if typeIndex == 0 {
                builder.reference(from: "App", to: type, kind: .reference)
                builder.reference(from: "App", to: "\(type).m0", kind: .call)
            }
        }
        return builder.build()
    }

    @Test("심볼 2만 개 규모에서 전체 분석이 완료된다", .timeLimit(.minutes(1)))
    func fullPipelineHandlesTwentyThousandSymbols() {
        let snapshot = makeLargeSnapshot(typeCount: 2_000, membersPerType: 9)
        #expect(snapshot.symbols.count == 20_001)

        let symbolGraph = GraphBuilder(options: .init(level: .symbol)).buildResult(from: snapshot)
        #expect(symbolGraph.graph.nodeCount == 20_001)

        let unused = ReachabilityAnalyzer().analyze(graph: symbolGraph.graph, snapshot: snapshot)
        // App → T0.m0 → T1.m0 → … 사슬로 모든 타입과 첫 멤버가 도달 가능하다.
        #expect(unused.reachableCount == 1 + 2_000 * 2)
        // 나머지 멤버는 도달할 수 없고, 조상 타입은 살아 있으므로 각각 보고된다.
        #expect(unused.unused.count == 2_000 * 8)

        let moduleGraph = GraphBuilder(options: .init(level: .module)).buildResult(from: snapshot)
        #expect(moduleGraph.graph.nodeCount == 21)
        #expect(CycleDetector().detectCycles(in: moduleGraph.graph).isEmpty == false)

        let metrics = ArchitectureMetricsCalculator()
            .calculate(result: moduleGraph, snapshot: snapshot)
        #expect(metrics.count == 21)
    }

    @Test("타입 레벨 롤업이 멤버 수에 선형으로 동작한다", .timeLimit(.minutes(1)))
    func typeRollupScalesLinearly() {
        let snapshot = makeLargeSnapshot(typeCount: 1_000, membersPerType: 20)
        let graph = GraphBuilder(options: .init(level: .type)).build(from: snapshot)
        // 멤버는 전부 소유 타입으로 접힌다.
        #expect(graph.nodeCount == 1_001)
    }
}
