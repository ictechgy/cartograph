# AGENTS.md

이 저장소에서 작업하는 코딩 에이전트를 위한 안내입니다.
사람 기여자는 [CONTRIBUTING.md](CONTRIBUTING.md)를, 도구 사용법은
[README.md](README.md)를 보세요.

> This file is written in Korean because it is the maintainer's working language.
> For the project overview in English, see [README.md](README.md);
> for contributor-facing build and style rules, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Scoped Guidance Index

이 링크는 탐색용 색인입니다. 하위 `AGENTS.md`는 해당 디렉터리와 그 아래에서만 적용됩니다.
여러 범위에 걸친 작업은 각 범위의 지침을 함께 따릅니다.

- [Sources/AGENTS.md](Sources/AGENTS.md) — 모듈 경계, 그래프·경로·브리지 구현 규칙
- [Sources/CartographIndexStore/AGENTS.md](Sources/CartographIndexStore/AGENTS.md) — 인덱스 관계 방향과 소유자 귀속
- [Tests/AGENTS.md](Tests/AGENTS.md) — 테스트 작성 규칙
- [Fixtures/AGENTS.md](Fixtures/AGENTS.md) — 오탐 코퍼스 규칙
- [Skills/AGENTS.md](Skills/AGENTS.md) — 에이전트 스킬 문서 규칙

**지금 어디까지 왔고 다음이 무엇인지는 [HANDOFF.md](HANDOFF.md)에 있습니다.** 세션을 이어받을 때 먼저 읽으세요.

자매 프로젝트가 바탕화면에 있습니다: [kartograph](../kartograph)(Kotlin/Android) ·
[dartograph](../dartograph)(Dart/Flutter) · [isthmus](../isthmus)(언어 경계 조인).
이들의 `query` 출력 스키마와 스킬 문장은 이 저장소와 같아야 합니다. 여기서 바꾸면 그쪽에도 알리세요.
브리지 교환 형식은 `../isthmus/docs/GRAPH-EXCHANGE.md`가 정본입니다. 형식 변경은
`BridgeFactsDocument`와 자매 저장소에 함께 반영합니다.

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

완료를 보고할 때 아래 네 가지의 통과 근거가 있어야 합니다. 입력이 바뀌지 않은 검사는 기존 근거를
재사용합니다. 문서만 바꾸면 구조·링크·적용 범위를 검증하고, 제품 검사를 새로 실행했다고 쓰지 마세요.

```bash
Scripts/coverage.sh
Scripts/verify-cli-contract.sh
Scripts/verify-fixtures.sh
swift build \
  && swift run cartograph dead   --strict \
  && swift run cartograph cycles --strict \
  && swift run cartograph cycles --level type --strict \
  && swift run cartograph rules  --strict
```

**순환 검사는 타입 레벨까지 돌립니다.** Swift 컴파일러가 모듈 간 순환 import를 막으므로,
기본 모듈 검사만으로 "순환 없음"을 주장하지 마세요. 타입 검사가 실제 순환을 잡고,
모듈 검사는 빌드 시스템 이상을 확인하기 위해 함께 유지합니다.

자기 분석도 필수입니다. 프로토콜 구현·`@main` 오탐과 절대/상대 경로 글롭 불일치는
단위 테스트가 통과한 뒤 자기 분석에서 발견됐습니다.

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
  좁혀야 할 근거가 생겼다면 [CONTRIBUTING.md](CONTRIBUTING.md)의 "Narrowing one"이 통과해야 할
  문입니다 — 반대 방향 코퍼스가 먼저, 실제 프로젝트 세 곳 이상의 델타가 PR 본문에.
- **커버리지 숫자를 올리려고 아무것도 검증하지 않는 테스트를 쓰지 마세요.** CLI와 인덱스
  입출력은 실제 하네스로 검증합니다. `coverage.sh`는 단위 비율을 따로 남기고 계측된 CLI의
  계약·자동 발견·실행 수집·MCP 프로파일을 합칩니다. `--unit-only`는 단위 테스트만의 원래 수치입니다.
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

## 분석·검증 시 주의점

**인덱스 스토어 루트의 수정 시각은 믿을 수 없습니다.** `.build/out`처럼 스토어를 품은 상위 디렉터리는
처음 만들어진 날짜 그대로이고 레코드는 `v5/units`에 쌓입니다. 루트만 보면 모든 소스가 낡았다고
나옵니다(실제로 71/71). 신선도는 `indexStoreDate()`처럼 `v5/units`까지 봅니다.

**`retain_public`의 기본값은 꺼짐입니다.** 라이브러리에서는 저장소 안에 호출자가 없는 공개 API 전체가
`unreachable`로 나옵니다. 이것을 모르는 소비자(특히 에이전트)에게는 가장 위험한 사실이라 스킬이
규칙 2로 말합니다. 기본값을 바꾸지 말고, 바꾼다면 스킬과 README를 같이 고치세요.

**`Scripts/verify-fixtures.sh`는 릴리스 바이너리를 빌드하지 않고 경로만 찾습니다.** 낡은 릴리스
바이너리가 있으면 그것으로 검증해 방금 고친 것이 반영되지 않은 결과가 나옵니다. 실제로 그렇게
"수정이 안 먹는다"고 오해한 적이 있습니다. 먼저 `swift build -c release`를 돌리거나, 디버그
바이너리 경로를 첫 인자로 넘기세요.

**릴리스 성공과 Homebrew 갱신은 따로 확인합니다.** `HOMEBREW_TAP_TOKEN`이 없으면 탭 갱신 단계도
exit 0으로 건너뜁니다. 공개 asset의 해시, 실제 formula의 URL·해시, 설치 버전과 `brew test`를 확인하세요.
README가 참조하는 계약 문서도 archive에 포함하고 압축을 푼 파일을 검증합니다.

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
