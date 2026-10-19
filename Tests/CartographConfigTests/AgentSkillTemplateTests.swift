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

    /// 앞머리 블록을 `키: 값` 으로 읽는다. 값에 콜론이 있어도 첫 콜론에서만 자른다.
    private func frontmatter() throws -> [String: String] {
        let lines = AgentSkillTemplate.markdown.split(separator: "\n", omittingEmptySubsequences: false)
        try #require(lines.first == "---")
        let closing = try #require(lines.dropFirst().firstIndex(of: "---"))
        var fields: [String: String] = [:]
        for line in lines[1..<closing] {
            let parts = line.split(separator: ":", maxSplits: 1)
            try #require(parts.count == 2, "앞머리 줄이 '키: 값' 형태가 아니다: \(line)")
            fields[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    @Test("앞머리가 기계가 읽을 수 있는 형태다")
    func frontmatterParses() throws {
        // 설명 안에 콜론이 들어가는 순간 YAML 이 깨지고, 깨진 스킬은 설치는 되는데
        // 아무도 부르지 않는 문서가 된다. 지금 콜론이 없는 것은 우연이라 고정한다.
        let fields = try frontmatter()
        #expect(fields["name"] == "cartograph")
        let description = try #require(fields["description"])
        #expect(!description.isEmpty)
        #expect(!description.contains(":"))
        // 설명은 한 줄이어야 한다. 줄바꿈이 들어가면 이어지는 줄이 키로 읽힌다.
        #expect(!description.contains("\n"))
    }

    @Test("설명이 발동 조건을 담고 있다")
    func descriptionCarriesItsTriggers() throws {
        // 사용자가 실제로 쓸 표현으로 발동해야 한다. "dead code 정리해 줘"가
        // 대표적인데, 이 단어가 빠져 있으면 나머지 문서가 아무리 옳아도 안 읽힌다.
        let description = try #require(try frontmatter()["description"])
        for trigger in ["before deleting", "dead", "unused", "who calls", "Swift"] {
            #expect(description.contains(trigger), "발동 조건에 '\(trigger)' 가 없다")
        }
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

    @Test("규칙을 통과한 뒤에 무엇을 할지가 적혀 있다")
    func saysWhatToDoWhenTheRulesPass() {
        // 금지만 적으면 체크리스트가 "통과하면 진행"으로 무너진다. 확인 절차가
        // 오히려 면책 증명서로 소비되면, 이 문서가 없을 때보다 나빠진다.
        #expect(AgentSkillTemplate.markdown.contains("## When the rules pass"))
        #expect(AgentSkillTemplate.markdown.contains("Passing the rules is not permission"))
        #expect(AgentSkillTemplate.markdown.contains("Delete only what the user asked you to delete"))
    }

    @Test("public API 가 기본으로는 보존 뿌리가 아니라는 사실을 알린다")
    func warnsThatPublicApiIsNotRetainedByDefault() {
        // `retain_public` 기본값은 꺼짐이다. 라이브러리에서 이것을 모르면 공개 API
        // 전체가 unreachable 로 나오고, 그대로 지우면 모든 소비자가 깨진다.
        #expect(AgentSkillTemplate.markdown.contains("retain_public` defaults to"))
        #expect(AgentSkillTemplate.markdown.contains("Public API is *not* a root"))
    }

    @Test("일괄 삭제 경로에도 규칙이 적용된다고 말한다")
    func carriesTheRulesIntoTheSweepingSection() {
        // dead 출력 수백 건을 받은 에이전트에게 규칙을 다시 걸어 주지 않으면,
        // 이 문서가 가드레일을 우회하는 더 효율적인 삭제 경로를 준 셈이 된다.
        #expect(AgentSkillTemplate.markdown.contains("every rule above applies to every entry"))
        #expect(AgentSkillTemplate.markdown.contains("A long list is not a mandate"))
    }

    @Test("이 도구가 답할 수 없는 것을 밝힌다")
    func admitsWhatItCannotAnswer() {
        // 특히 자기 편집 직후가 위험하다. 인덱스는 빌드해야 갱신되므로, 방금 지운
        // 호출부가 아직 그래프에 남아 있고 답은 편집 전 상태를 말한다.
        #expect(AgentSkillTemplate.markdown.contains("## Answers this tool cannot give"))
        #expect(AgentSkillTemplate.markdown.contains("Anything you changed in this session"))
        #expect(AgentSkillTemplate.markdown.contains("Objective-C declarations"))
        #expect(AgentSkillTemplate.markdown.contains("Whether a rename is safe"))
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

    /// 펜스 코드 블록 안의 줄. 에이전트가 그대로 실행하는 것은 이 줄들이다.
    private var commandLines: [Substring] {
        var isInsideFence = false
        var lines: [Substring] = []
        for line in AgentSkillTemplate.markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                isInsideFence.toggle()
            } else if isInsideFence {
                lines.append(line)
            }
        }
        return lines
    }

    @Test("명령 예시의 임시 경로는 실행마다 mktemp 가 새로 만든다")
    func commandExamplesCreateTemporaryPathsWithMktemp() {
        // `/tmp/requests.json` 같은 고정 이름은 다른 계정이 미리 만든 파일이나 링크에 그대로
        // 쓰고 읽는다. 같은 머신의 병렬 에이전트 세션끼리도 서로의 요청·trace 를 덮어쓴다.
        // 에이전트는 이 명령을 그대로 실행하므로, 임시 경로는 mktemp 줄에서만 나와야 한다.
        let temporaryPathLines = commandLines.filter { $0.contains("/tmp") || $0.contains("TMPDIR") }
        for line in temporaryPathLines {
            #expect(line.contains("mktemp"), "공유 임시 디렉터리의 고정 경로: \(line)")
        }
    }

    /// 저장소 루트의 README. 스윕 예시의 정본이 있고 `Scripts/verify-cli-contract.sh` 가 실행해 본다.
    private var readme: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        }
    }

    @Test("여러 선언을 묻는 예시가 README 에서 실행으로 검증하는 스윕과 같다")
    func batchSweepMatchesTheVerifiedReadmeExample() throws {
        // README 예시는 계약 스크립트가 진단 종류·빈 리포트·1000건 경계에서 실제로 돌려 본다.
        // 스킬만 다른 형태로 남으면 검증받지 않은 스윕이 에이전트에게 간다. 실제로 README 를
        // 고친 뒤에도 스킬은 모든 진단의 subject 를 /tmp 의 고정 파일로 넘기고 있었다.
        let text = try readme
        let start = try #require(text.range(of: "<!-- dead-to-batch-example -->\n")).upperBound
        let end = try #require(text.range(of: "\n```\n", range: start..<text.endIndex)).upperBound
        let example = text[start..<end]
        #expect(example.hasPrefix("```bash\n"))
        #expect(AgentSkillTemplate.markdown.contains(example), "스킬의 일괄 질의 예시가 README 와 다르다")
    }
}
