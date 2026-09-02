# AGENTS.md

이 저장소에서 작업하는 코딩 에이전트를 위한 안내입니다.
사람 기여자는 [CONTRIBUTING.md](CONTRIBUTING.md) 를, 도구 사용법은
[README.md](README.md) 를 보세요.

> This file is written in Korean because it is the maintainer's working language.
> For the project overview in English, see [README.md](README.md);
> for contributor-facing build and style rules, see [CONTRIBUTING.md](CONTRIBUTING.md).

디렉터리별 세부 규칙은 각 디렉터리의 AGENTS.md 를 따릅니다.
- [Sources/AGENTS.md](Sources/AGENTS.md) — 모듈 경계와 계층 규칙
- [Tests/AGENTS.md](Tests/AGENTS.md) — 테스트 작성 규칙

---

## 이 프로젝트가 하는 일

컴파일러가 만든 인덱스 스토어를 읽어 Swift 코드의 의존성 그래프를 만들고, 그 위에서
미사용 코드·순환 의존성·아키텍처 지표·레이어 규칙을 질의합니다.

핵심 설계는 한 문장입니다. **그래프가 산출물이고, 나머지는 전부 그 위의 질의입니다.**
새 기능을 넣을 때 "이것도 그래프 질의로 표현되는가"를 먼저 물어보세요.

## 명령

```bash
swift build                     # 빌드
swift test                      # 전체 테스트
swift test --filter <타깃명>     # 특정 타깃만
Scripts/coverage.sh             # 테스트 + 커버리지 게이트(기준 90%)
Scripts/coverage.sh --report    # 파일별 커버리지
```

작업을 끝냈다고 말하기 전에 반드시 두 가지를 통과시키세요.

```bash
Scripts/coverage.sh
swift build -Xswiftc -index-store-path -Xswiftc .index-store \
  && swift run cartograph dead   --index-store .index-store --strict \
  && swift run cartograph cycles --index-store .index-store --strict \
  && swift run cartograph rules  --index-store .index-store --strict
```

두 번째가 자기 분석(dogfooding)입니다. 이 도구가 실제로 발견한 결함 세 가지 —
프로토콜 구현 오탐, `@main` 오탐, 절대/상대 경로 글롭 불일치 — 는 전부 이 단계에서만
드러났습니다. 단위 테스트는 하나도 잡지 못했습니다.

**인덱스는 무언가 컴파일될 때만 만들어집니다.** 이미 최신인 빌드에서
`-index-store-path` 를 붙여 돌리면 아무 일도 일어나지 않고 그 디렉터리는 생기지 않습니다.
그 상태로 도구를 돌리면 "인덱스 스토어를 찾지 못했다"(종료 코드 2)가 나오는데,
분석이 실패한 것으로 오해하기 쉽습니다. 로컬에서는 `--index-store` 를 생략해
평소 빌드가 남긴 `.build/out` 을 쓰는 편이 간단합니다.

## 절대 하지 말 것

- **`CartographCore` 에 외부 의존성을 추가하지 마세요.** 도메인이 순수해야 분석 계층 전체를
  인덱스 스토어 없이 테스트할 수 있습니다. 이 성질이 깨지면 커버리지 90% 는 유지 불가능합니다.
- **`IndexStoreDB` 를 `CartographIndexStore` 밖에서 import 하지 마세요.** 마찬가지로
  `SwiftSyntax` 는 `CartographSyntax`, `Yams` 는 `CartographConfig` 안에서만 씁니다.
- **JSON 을 인코딩할 때 `.sortedKeys` 를 빼지 마세요.** Foundation 의 JSONEncoder 는 객체 키
  순서를 보장하지 않습니다. 빠뜨리면 같은 입력이 매번 다른 파일이 되어 리포트 diff 와 캐시가
  모두 무의미해집니다. 이 성질은 테스트로 고정되어 있습니다.
- **보존 규칙을 느슨하게 만들지 마세요.** 거짓 양성 하나가 도구 전체의 신뢰를 깎습니다.
  확신이 없으면 살리는 쪽을 고르고, 왜 살렸는지 `RetentionReason` 으로 남기세요.
- **커버리지 숫자를 올리려고 아무것도 검증하지 않는 테스트를 쓰지 마세요.** CLI 껍데기와
  인덱스 스토어 입출력은 의도적으로 자기 분석 단계에 맡겨 두었습니다.

## 자주 틀리는 지점

**인덱스 심볼 이름에는 인자 목록이 붙습니다.** `main()`, `describe(_:)`, `buildBlock(_:)` 처럼요.
이름으로 규칙을 걸 때는 `GraphNode.baseName` 을 쓰세요.

**경로는 절대 경로로 들어오고 설정은 상대 경로로 쓰입니다.** 경로 글롭을 새로 쓰는 곳이 생기면
`PathFilter.matchCandidates(for:relativeTo:)` 를 거치세요. 한쪽만 지원하면 같은 패턴이
설정 위치에 따라 다르게 동작합니다.

**`CodeGraph` 는 양 끝 정점이 모두 있는 간선만 남깁니다.** 분석 범위 밖(SDK 등)으로 향하는
관계는 그래프에 없습니다. 외부 관계를 봐야 하는 규칙은 원본 `IndexSnapshot` 을 읽으세요.

**인덱스 관계 역할은 "발생 심볼이 관련 심볼에 대해 갖는 관계"로 읽습니다.**
`baseOf` 는 파생→기반, `overrideOf` 는 오버라이드→기반, `calledBy` 는 호출자→피호출자,
`extendedBy` 는 익스텐션→확장 대상입니다. 방향을 뒤집으면 그래프 전체가 조용히 거꾸로 섭니다.

**심볼 레벨 그래프는 정점이 수만 개가 됩니다.** 재귀 순회와 경로 배열 복사는 실측에서 바로
멈춥니다. `CycleDetector` 의 반복형 Tarjan 구현과 선행 정점 기반 경로 복원이 그 이유입니다.

## 커밋

Conventional Commits, 본문은 한국어. 스코프는 모듈 이름을 씁니다
(`core`, `config`, `syntax`, `analysis`, `export`, `indexstore`, `kit`, `cli`).

```
feat(analysis): 순환 의존성 탐지 구현
fix(core): 경로 글롭이 절대 경로와 맞지 않던 문제 수정
```

커밋은 작고 한 가지 목적만 담습니다. 본문에는 *왜* 를 쓰세요. *무엇을* 은 diff 가 이미 말합니다.
`main` 에 직접 커밋하지 말고 `feature/…`, `fix/…`, `refactor/…` 브랜치에서 작업하세요.

## 코드 스타일

- 들여쓰기 4칸, 최대 120열.
- 주석은 한국어, 식별자는 영어. 사용자에게 보이는 출력 문자열은 영어(오픈소스 대상).
- 모든 public 타입·함수에 문서 주석. *무엇을* 이 아니라 *왜* 를 적으세요.
- 함수는 하나의 역할만. 본문 10줄을 넘기면 분리를 검토하세요.
- 빈 `catch` 금지. 오류 메시지에는 원인과 해결 방향을 함께 담습니다.
