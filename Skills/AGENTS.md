# Skills/AGENTS.md

에이전트 스킬 문서 규칙입니다. 루트 [AGENTS.md](../AGENTS.md)를 먼저 읽으세요.

## `Skills/cartograph/SKILL.md`는 직접 편집하지 않습니다

이 파일은 **생성물**입니다. 원본은 `Sources/CartographConfig/AgentSkillTemplate.swift`의 `markdown` 상수이고, `cartograph skill`이 그것을 설치합니다. 저장소의 사본은 사람이 GitHub에서 읽기 위한 것이며, `AgentSkillTemplateTests`의 드리프트 테스트가 둘이 같은지 비교합니다.

고치는 순서:

```bash
# 1. 템플릿을 고친다
$EDITOR Sources/CartographConfig/AgentSkillTemplate.swift
# 2. 사본을 다시 생성한다
swift build && .build/debug/cartograph skill --project . --force \
  && cp .claude/skills/cartograph/SKILL.md Skills/cartograph/SKILL.md \
  && rm -rf .claude/skills && rmdir .claude 2>/dev/null
# 3. 드리프트 테스트를 돌린다
swift test --filter AgentSkillTemplateTests
```

이 저장소 자체에 `.claude/skills/`를 남기지 마세요. 두 사본이 되는 순간 드리프트 문제가 다시 생깁니다.

## 이 문서가 지키는 것

에이전트는 판정을 곧바로 편집으로 옮깁니다. 사람은 `unreachable`을 보면 한 번 더 확인하지만 에이전트는 지웁니다. 그래서 이 문서의 절반은 "무엇을 실행하라"가 아니라 **"무엇을 근거로 삼지 말라"** 이고, 그 절들은 테스트로 고정되어 있습니다. 지우면 테스트가 실패합니다.

- `state`는 판정이 아니다 — "It is not \"safe to delete\""
- public API는 기본으로 보존 뿌리가 아니다 — `retain_public` 기본값이 **꺼짐**이라 라이브러리에서 공개 API 전체가 unreachable로 나온다. 이 문서가 낼 수 있는 가장 큰 사고라 규칙 2에 있다
- `limitations`를 같은 응답에서 읽어라
- `suppressedByBaseline`은 팀이 이미 내린 결정이다
- 타입의 `dependsOn: []`은 "아무것도 의존하지 않는다"가 아니다 — `members`를 따라가라
- **규칙을 통과한 뒤 무엇을 할지** — 금지만 적으면 체크리스트가 "통과하면 진행"으로 무너진다. `## When the rules pass` 절이 그 답이고, 이것이 없으면 이 문서는 없을 때보다 나쁘다
- `dead` 일괄 목록에도 규칙이 적용된다 — "A long list is not a mandate"
- 이 도구가 답할 수 없는 것 — Objective-C 선언, 이 세션에서 바꾼 코드(인덱스는 빌드해야 갱신), rename의 안전성

## 자매 프로젝트와의 관계

kartograph · dartograph 의 스킬은 이 문서를 출발점으로 삼고, 위 절들을 그대로 유지한 채 플랫폼 고유 절만 더합니다. `query` 스키마가 같으므로 같은 문장으로 가르칠 수 있어야 합니다. 여기서 절을 바꾸면 자매 프로젝트에도 알리세요.

## 앞머리(frontmatter)

`name`과 `description`은 발동 조건입니다. 설명에 콜론을 넣으면 YAML이 깨지고, 깨진 스킬은 설치되지만 아무도 부르지 않는 문서가 됩니다. 테스트가 `키: 값` 파싱과 발동 키워드("before deleting", "dead", "unused", "who calls", "Swift")를 확인합니다. 사용자가 실제로 쓰는 말로 발동하지 않으면 나머지 문서가 아무리 옳아도 읽히지 않습니다.
