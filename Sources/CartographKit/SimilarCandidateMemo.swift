import CartographAnalysis
import CartographCore

extension GraphQueryIndex {
    /// 같은 배치에서 같은 이름의 notFound 추천은 한 번만 계산한다.
    ///
    /// 낡은 요청 파일을 다시 돌리거나 같은 이름을 되풀이해 묻는 배치(`query --batch`, MCP `cartograph_query`,
    /// impact 의 심볼 선택)가 이름마다 같은 비교를 다시 하지 않게 한다. 메모는 부르는 쪽이 배치 하나 동안만
    /// 들고 있다가 버린다. 질의 세션에 두면 서로 다른 이름을 계속 묻는 긴 MCP 세션에서 끝없이 자란다.
    func similarCandidates(to subject: String, memo: inout [String: [GraphNode]]) -> [GraphNode] {
        if let known = memo[subject] { return known }
        let computed = similarCandidates(to: subject)
        memo[subject] = computed
        return computed
    }
}
