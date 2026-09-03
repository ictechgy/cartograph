@testable import CartographConfig
import Foundation
import Testing

@Suite("에이전트 스킬 문서")
struct AgentSkillTemplateTests {
    /// 저장소에 커밋된 사본. 사람은 GitHub 에서 이것을 읽는다.
    private var shippedFile: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let path = root.appendingPathComponent("Skills/cartograph/SKILL.md")
            return try String(contentsOf: path, encoding: .utf8)
        }
    }

    @Test("저장소의 사본과 설치되는 내용이 같다")
    func shippedCopyMatchesWhatGetsInstalled() throws {
        // 둘이 갈라지면 사람이 읽고 검토한 문서와 에이전트가 실제로 받는 지시가
        // 달라진다. 검토를 통과한 적 없는 지시가 조용히 배포되는 셈이다.
        #expect(try shippedFile == AgentSkillTemplate.markdown + "\n")
    }

    @Test("스킬을 찾게 하는 앞머리가 갖춰져 있다")
    func carriesTheFrontmatterThatMakesItDiscoverable() throws {
        // 이름과 설명이 없으면 에이전트가 이 스킬을 언제 써야 할지 모른다.
        // 설치는 되는데 아무도 부르지 않는 문서가 된다.
        let lines = AgentSkillTemplate.markdown.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "---")
        #expect(lines.contains { $0.hasPrefix("name: cartograph") })
        #expect(lines.contains { $0.hasPrefix("description: Use when") })
        #expect(lines.dropFirst().contains("---"))
    }

    @Test("삭제 판정을 내리지 말라는 지시가 들어 있다")
    func tellsTheAgentNotToTreatUnreachableAsAVerdict() {
        // 이 스킬이 존재하는 이유다. 에이전트는 판정을 곧바로 편집으로 옮기므로,
        // "실행법"만 가르치고 "무엇을 근거로 삼지 말라"를 빠뜨리면 도구가 오히려
        // 잘못된 삭제를 가속한다.
        #expect(AgentSkillTemplate.markdown.contains("It is not \"safe to delete\""))
        #expect(AgentSkillTemplate.markdown.contains("limitations"))
        #expect(AgentSkillTemplate.markdown.contains("suppressedByBaseline"))
    }

    @Test("그래프 전체를 읽지 말라고 분명히 말한다")
    func warnsAgainstDumpingTheWholeGraph() {
        // 이것을 적지 않으면 스킬이 가르칠 수 있는 최선이 "graph --format json 을
        // 읽어라"가 되는데, 실제 프로젝트에서 간선이 수만 개다.
        #expect(AgentSkillTemplate.markdown.contains("Do not read the whole graph"))
    }

    @Test("설치 경로는 스킬이 실제로 읽히는 자리다")
    func installsWhereSkillsAreRead() {
        #expect(AgentSkillTemplate.directory == ".claude/skills/cartograph")
        #expect(AgentSkillTemplate.fileName == "SKILL.md")
    }
}
