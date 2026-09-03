/// 코딩 에이전트에게 이 도구를 어떻게 쓰는지 가르치는 스킬 문서.
///
/// 에이전트는 판정을 곧바로 행동으로 옮긴다. 사람은 `unreachable` 을 보고 한 번
/// 더 확인하지만 에이전트는 지운다. 그래서 이 문서가 가르쳐야 할 것의 절반은
/// "무엇을 실행하라"가 아니라 "무엇을 근거로 삼지 말라"이다.
///
/// 내용을 바이너리 안의 문자열로 두는 이유는 하나다. 저장소의 `Skills/` 아래
/// 파일과 설치되는 내용이 갈라지면, 사람이 GitHub 에서 읽은 것과 에이전트가
/// 실제로 받는 것이 달라진다. 테스트가 둘이 같은지 확인한다.
public enum AgentSkillTemplate {
    /// 설치 경로. Claude Code 는 이 아래의 `SKILL.md` 를 읽는다.
    public static let directory = ".claude/skills/cartograph"
    public static let fileName = "SKILL.md"

    public static let markdown = """
        ---
        name: cartograph
        description: Use when deciding whether Swift code is unused, when asked who calls or \
        depends on a declaration, or before deleting any Swift declaration in an iOS/macOS project. \
        Answers come from the compiler's index, not from text search.
        ---

        # cartograph

        `grep` finds text. The compiler index knows which declaration a name resolved to. Use this
        tool for questions about Swift symbols, and use `grep` only for things that are genuinely
        text — comments, strings, resource names.

        ## Before deleting any declaration

        Run this first and read the whole answer:

        ```bash
        cartograph query <name-or-USR>
        ```

        Then apply these rules. They are the point of this skill.

        1. **`state` is not a verdict.** `unreachable` means "not reachable from any retained root",
           which is a fact about the graph. It is not "safe to delete". Nothing in this tool's
           output ever says a declaration is safe to delete, and you must not infer it.

        2. **Read `limitations` in the same response.** It lists the channels this analysis cannot
           see, counted from the project you are in. If it names Objective-C sources, an
           `unreachable` Swift declaration may be called from a `.m` file the analysis never read.
           If it names Interface Builder documents, connections are matched by class name only. If
           it reports `index-staleness`, the index predates recent edits — rebuild before trusting
           the answer.

        3. **`suppressedByBaseline: true` means the team already decided.** Leave it alone. Do not
           re-litigate a decision that is recorded in the baseline file.

        4. **`dependsOn: []` on a type does not mean it depends on nothing.** On a symbol-level
           graph a type's dependencies are held by its members. Follow `members`.

        5. **`reason` tells you why something survived.** A value like `interfaceBuilder`,
           `objcExposed`, `codingKeys` or `caseIterable` means the compiler index alone would have
           called it dead. Deleting it breaks something the index cannot see.

        ## Answering "who uses X?"

        ```bash
        cartograph query MyType             # direct users and dependencies
        cartograph query MyType --depth 2   # two edges out, in both directions
        ```

        Each neighbour carries `edges` — every relation reaching it, such as
        `["call", "overrides"]` — plus `module`, `depth` and its declaration site. Note that
        `location` is where the neighbour is *declared*, not where it uses your symbol.

        A name matching several declarations comes back as `status: "ambiguous"` with candidate
        USRs. Ask again with one of the USRs rather than guessing.

        `truncated` says the answer hit `--limit`. Raise the limit or narrow the question; do not
        report a truncated list as complete.

        ## Sweeping a whole project

        ```bash
        cartograph dead --report-format json    # every unreachable declaration
        cartograph dead --explain MyType        # why one declaration survived, in prose
        cartograph cycles                       # circular dependencies, with the link to cut
        cartograph rules                        # layering violations
        ```

        Scope a review to what a branch touched:

        ```bash
        cartograph dead --since origin/main
        ```

        ## Do not read the whole graph

        `cartograph graph --format json` emits every node and edge — tens of thousands of edges on
        a real project. Loading that answers no question you could not answer with `query`, and it
        crowds out the context you need to do the actual work. Ask about the symbol you care about.

        ## Exit codes

        `0` success · `1` findings with `--strict` or a threshold exceeded · `2` tool failure, such
        as a missing index store · `64` usage error, including a name that matches nothing.

        A `64` from `query` means the name does not exist in the index. That is not evidence the
        code is unused — check your spelling, and check whether the target was built.

        ## If there is no index store

        The tool reads what the compiler wrote. Build first:

        ```bash
        swift build
        xcodebuild build COMPILER_INDEX_STORE_ENABLE=YES -derivedDataPath <path>
        ```

        Then pass `--index-store <path>` if it is not found automatically.
        """
}
