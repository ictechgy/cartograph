@testable import CartographAnalysis
import CartographCore

/// 추천 테스트가 함께 쓰는 기준 거리와 방문 순서를 정하는 진입점. 제품 경로는 이 함수들을 부르지 않는다.
extension GraphQueryIndex {
    /// 사전과 같은 항목을 주어진 순서로 담아 제품과 같은 선택기를 돈다.
    /// 테스트가 항목 방문 순서를 정해 사전의 순회 순서와 무관한 답을 검증한다.
    static func similarCandidates<Names: Sequence>(
        to subject: String,
        limit: Int,
        graph: CodeGraph,
        names: Names
    ) -> [GraphNode] where Names.Element == (key: String, value: [NodeID]) {
        guard let query = SimilarNameQuery(subject) else { return [] }
        // 그래프에 없는 정점은 대표가 될 수 없다. 제품의 이름 사전은 그래프 정점으로만 만든다.
        let present = names.map { (key: $0.key, value: $0.value.filter { graph.node($0) != nil }) }
        var work = SimilarNameWork()
        let index = SimilarNameIndex(names: present)
        return query.candidates(in: index.buckets(lengths: query.lengths), limit: limit, graph: graph, work: &work)
    }

    /// 두 문자열의 전체 편집 거리(Levenshtein, 유니코드 스칼라 단위). 추천 비교의 기준이다.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs.unicodeScalars)
        let rhs = Array(rhs.unicodeScalars)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
