# AGENTS.md

이 저장소에서 작업하는 코딩 에이전트를 위한 안내입니다.
사람 기여자는 [CONTRIBUTING.md](CONTRIBUTING.md)를, 도구 사용법은
[README.md](README.md)를 보세요.

> This file is written in Korean because it is the maintainer's working language.
> For the project overview in English, see [README.md](README.md);
> for contributor-facing build and style rules, see [CONTRIBUTING.md](CONTRIBUTING.md).

디렉터리별 세부 규칙은 각 디렉터리의 AGENTS.md를 따릅니다.
- [Sources/AGENTS.md](Sources/AGENTS.md) — 모듈 경계와 계층 규칙
- [Tests/AGENTS.md](Tests/AGENTS.md) — 테스트 작성 규칙
- [Fixtures/AGENTS.md](Fixtures/AGENTS.md) — 오탐 코퍼스 규칙
- [Skills/AGENTS.md](Skills/AGENTS.md) — 에이전트 스킬 문서 규칙

**지금 어디까지 왔고 다음이 무엇인지는 [HANDOFF.md](HANDOFF.md)에 있습니다.** 세션을 이어받을 때 먼저 읽으세요.

자매 프로젝트가 바탕화면에 있습니다: [kartograph](../kartograph)(Kotlin/Android) ·
[dartograph](../dartograph)(Dart/Flutter) · [isthmus](../isthmus)(언어 경계 조인).
이들의 `query` 출력 스키마와 스킬 문장은 이 저장소와 같아야 합니다. 여기서 바꾸면 그쪽에도 알리세요.

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
Scripts/verify-cli-contract.sh  # 빌드된 바이너리로 종료 코드 계약 검증
Scripts/verify-fixtures.sh      # 오탐 코퍼스를 진짜 인덱스로 양방향 검증

swift run cartograph query <이름>   # 심볼 하나: 누가 쓰나·무엇을 쓰나·도달 가능한가 (JSON)
swift run cartograph skill         # 에이전트 스킬을 프로젝트에 설치
```

작업을 끝냈다고 말하기 전에 반드시 네 가지를 통과시키세요.

```bash
Scripts/coverage.sh
Scripts/verify-cli-contract.sh
Scripts/verify-fixtures.sh
swift build \
  && swift run cartograph dead   --strict \
  && swift run cartograph cycles --strict \
  && swift run cartograph rules  --strict
```

두 번째가 자기 분석(dogfooding)입니다. 이 도구가 실제로 찾아낸 결함 세 가지(프로토콜 구현 오탐,
`@main` 오탐, 절대/상대 경로 글롭 불일치)는 전부 이 단계에서 드러났습니다. 단위 테스트는 하나도 잡지 못했습니다.

**`-Xswiftc -index-store-path`를 믿지 마세요.** Swift 6.4부터 기본이 된 Xcode 기반 빌드
시스템은 이 플래그를 무시하고 `<스크래치 경로>/out`에 인덱스를 남깁니다. 요청한 경로는
아예 생기지 않습니다. `--index-store`를 생략해 자동 탐색에 맡기세요.

**인덱스는 무언가 컴파일될 때만 만들어집니다.** 이미 최신인 패키지를 빌드하면 새 인덱스
데이터가 생기지 않습니다. **낡은 유닛도 남습니다** — 파일을 옮기거나 지워도 예전 기록이 남아
유령 정점으로 보입니다. 결과가 말이 안 되면 `swift build --scratch-path .build-fresh`로
새 인덱스를 만들어 확인하세요.

## 절대 하지 말 것

- **`CartographCore`에 외부 의존성을 추가하지 마세요.** 도메인이 순수해야 분석 계층 전체를
  인덱스 스토어 없이 테스트할 수 있습니다. 이 특성이 깨지면 커버리지 90%를 유지할 수 없습니다.
- **`IndexStoreDB`를 `CartographIndexStore` 밖에서 import 하지 마세요.** 마찬가지로
  `SwiftSyntax`는 `CartographSyntax`, `Yams`는 `CartographConfig` 안에서만 씁니다.
- **JSON을 인코딩할 때 `.sortedKeys`를 빼지 마세요.** Foundation의 JSONEncoder는 객체 키
  순서를 보장하지 않습니다. 빠뜨리면 같은 입력이 매번 다른 파일이 되어 리포트 diff와 캐시가
  모두 무의미해집니다. 이 특성은 테스트로 고정되어 있습니다.
- **보존 규칙을 느슨하게 만들지 마세요.** 오탐 하나가 도구 전체의 신뢰를 깎습니다.
  확신이 없으면 살리는 쪽을 고르고, 왜 살렸는지 `RetentionReason`으로 남기세요.
- **커버리지 숫자를 올리려고 아무것도 검증하지 않는 테스트를 쓰지 마세요.** CLI 껍데기와
  인덱스 스토어 입출력은 의도적으로 자기 분석 단계에 맡겨 두었습니다.
- **가지치기 목록을 두 벌 만들지 마세요.** 빌드 산출물 디렉터리 이름은 `BuildArtifactDirectories`
  하나뿐입니다. 실제로 두 벌이 있었고 한쪽에만 `node_modules`가 있었습니다.

## 에이전트가 소비하는 출력

`query`·`skill`과 JSON 리포트는 사람이 아니라 코딩 에이전트가 읽는다고 전제합니다.
에이전트는 판정을 곧바로 편집으로 옮기고, 산문보다 데이터를 믿습니다. 그래서 규칙이 다릅니다.

- **삭제 판정을 내지 마세요.** `deletable: true` 같은 필드는 영원히 없습니다. `state`는 그래프
  사실(`retained`·`retainedByMember`·`reachable`·`unreachable`)이고 `reason`은 값입니다.
  CLI 산문이 "지워도 된다"가 아니라 "보존 루트에서 도달할 수 없다"고 말하듯, JSON도 그보다
  확신하면 안 됩니다.
- **분석 한계를 모든 응답에 싣습니다.** `limitations`는 README를 복사하는 것이 아니라 **그 프로젝트에서
  실제로 세어서** 만듭니다(Objective-C 소스 수, IB 문서 수, 인덱스보다 새 소스 수, 설정 필터).
  알릴 것이 없으면 조용해야 합니다. 매번 붙는 경보는 읽히지 않습니다. `notFound`에도 싣습니다 —
  없는 것과 이 도구가 못 보는 것을 소비자가 구분해야 합니다.
- **베이스라인이 억제한 판정은 그렇다고 표시합니다.** 단, 실제로 보고되었을 정점에만.
  도달 가능한 정점에 억제 표시가 붙으면 "도달 가능한데 팀이 억제했다"는 모순이 나갑니다.
- **이웃에 닿는 간선은 전부 줍니다**(`edges: ["call", "overrides"]`). 하나만 고르면 나머지 관계가
  사라지고, 무엇을 고를지가 정렬 타이에 따라 실행마다 달라집니다.
- **담는 관계는 쓰는 관계가 아닙니다.** `members`·`declaredIn`은 `dependsOn`에 섞지 않습니다.
  그렇다고 빼면 클래스의 `dependsOn`이 비어 나오고 그것은 "아무것도 의존하지 않는다"로 읽힙니다.
- **잘렸으면 잘렸다고**(`truncated`), **몇 걸음인지**(`depth`), **어느 레벨인지**(`level`) 씁니다.
  도달성 분석은 설정과 무관하게 항상 심볼 레벨입니다.
- **값이 없는 선택 필드는 키가 빠집니다.** 이것은 문서화된 계약입니다(README `query` 절).
- **스킬 문서는 규칙을 통과한 뒤 무엇을 할지까지 말합니다.** 금지만 적으면 체크리스트가
  "통과하면 진행"으로 무너져, 확인 절차가 면책 증명서가 됩니다. 자세한 것은 [Skills/AGENTS.md](Skills/AGENTS.md).

## 자주 틀리는 지점

**`unusedCode(in:)`는 설정과 무관하게 항상 심볼 레벨 그래프를 만듭니다.** 응답에 `configuration.level`을
실어 보내면 심볼 레벨 답에 `module`이라고 적힙니다. 실제로 그랬고 회귀 테스트가 있습니다.

**인덱스 스토어 루트의 수정 시각은 믿을 수 없습니다.** `.build/out`처럼 스토어를 품은 상위 디렉터리는
처음 만들어진 날짜 그대로이고 레코드는 `v5/units`에 쌓입니다. 루트만 보면 모든 소스가 낡았다고
나옵니다(실제로 71/71). 신선도는 `indexStoreDate()`처럼 `v5/units`까지 봅니다.

**`retain_public`의 기본값은 꺼짐입니다.** 라이브러리에서는 저장소 안에 호출자가 없는 공개 API 전체가
`unreachable`로 나옵니다. 이것을 모르는 소비자(특히 에이전트)에게는 가장 위험한 사실이라 스킬이
규칙 2로 말합니다. 기본값을 바꾸지 말고, 바꾼다면 스킬과 README를 같이 고치세요.

**인덱스 심볼 이름에는 인자 목록이 붙습니다.** `main()`, `describe(_:)`, `buildBlock(_:)`처럼요.
이름으로 규칙을 걸 때는 `GraphNode.baseName`을 쓰세요.

**경로는 절대 경로로 들어오고 설정은 상대 경로로 쓰입니다.** 경로 글롭을 새로 쓰는 곳이 생기면
`PathFilter.matchCandidates(for:relativeTo:)`를 거치세요. 한쪽만 지원하면 같은 패턴이
설정 위치에 따라 다르게 동작합니다.

**`Scripts/verify-fixtures.sh`는 릴리스 바이너리를 빌드하지 않고 경로만 찾습니다.** 낡은 릴리스
바이너리가 있으면 그것으로 검증해 방금 고친 것이 반영되지 않은 결과가 나옵니다. 실제로 그렇게
"수정이 안 먹는다"고 오해한 적이 있습니다. 먼저 `swift build -c release`를 돌리거나, 디버그
바이너리 경로를 첫 인자로 넘기세요.

**`bridges`는 문자열을 읽습니다.** 인덱스는 `FlutterMethodChannel(name: "…")`의 문자열을 모릅니다.
스캐너(`CartographSyntax/BridgeFactScanner`)가 구문에서 리터럴을 뽑고, `CartographKit`의
`BridgeSymbolResolver`가 감싸는 선언의 USR을 인덱스에서 붙입니다. 교환 형식은
`../isthmus/docs/GRAPH-EXCHANGE.md`가 정본이며, 바뀌면 `BridgeFactsDocument`와 자매 저장소가 같이 바뀝니다.
이항 연산자는 `SwiftOperators`로 접어야 `a = b`와 `x == "y"`가 보입니다. 접지 않으면 `SequenceExpr`로 남습니다.

**`CodeGraph`는 양 끝 정점이 모두 있는 간선만 남깁니다.** 분석 범위 밖(SDK 등)으로 향하는
관계는 그래프에 없습니다. 외부 관계를 봐야 하는 규칙은 원본 `IndexSnapshot`을 읽으세요.

**인덱스 관계는 "심볼 발생이 상대 심볼과 맺는 관계"로 읽습니다.**
`baseOf`는 파생→기반, `overrideOf`는 오버라이드→기반, `calledBy`는 호출자→피호출자,
`extendedBy`는 익스텐션→확장 대상입니다. 방향을 뒤집으면 그래프 전체가 조용히 뒤집힙니다.

**심볼 레벨 그래프는 정점이 수만 개가 됩니다.** 재귀 순회와 경로 배열 복사는 실제로 돌려 보면 바로
멈춥니다. 그래서 `CycleDetector`는 반복형 Tarjan과 선행 정점 기반 경로 복원을 씁니다.

## 커밋

Conventional Commits, 본문은 한국어. 스코프는 모듈 이름을 씁니다
(`core`, `config`, `syntax`, `analysis`, `export`, `indexstore`, `kit`, `cli`).

```
feat(analysis): 순환 의존성 탐지 구현
fix(core): 경로 글롭이 절대 경로와 맞지 않던 문제 수정
```

커밋은 작고 한 가지 목적만 담습니다. 본문에는 *왜*를 쓰세요. *무엇을*은 diff가 이미 말합니다.
`main`에 직접 커밋하지 말고 `feature/…`, `fix/…`, `refactor/…` 브랜치에서 작업하세요.

## 코드 스타일

- 들여쓰기 4칸, 최대 120열.
- 주석은 한국어, 식별자는 영어. 사용자에게 보이는 출력 문자열은 영어(오픈소스 대상).
- 모든 public 타입·함수에 문서 주석. *무엇을*이 아니라 *왜*를 적으세요.
- 함수는 하나의 역할만. 본문 10줄을 넘기면 분리를 검토하세요.
- 빈 `catch` 금지. 오류 메시지에는 원인과 해결 방향을 함께 담습니다.
