# Handoff

새 세션이 이어받기 위한 문서다. 작업 규칙은 [AGENTS.md](AGENTS.md), Claude Code 전용 사항은 [CLAUDE.md](CLAUDE.md). 이 파일은 **지금 어디까지 왔고 다음이 무엇인지**만 담는다.

_마지막 갱신: 2026-09-07 (0.8.0 릴리스, Claude). 이 저장소에는 세션이 둘 있었다(Claude 가 0.5.1·0.5.2·0.5.4·0.5.5, Codex 가 0.5.3). 큰 작업 전 `git status --short --branch` 와 `gh pr list` 로 확인할 것._

## Goal

Swift/iOS 코드베이스의 의존성 그래프를 컴파일러 인덱스에서 만들고, 그 위에서 미사용 코드 · 순환 · 레이어 규칙 · 지표를 **근거와 함께** 답하는 오픈소스 CLI. 소비자는 사람보다 코딩 에이전트라 `query` · `skill` · `limitations` 를 갖춘다. 자매 저장소 [kartograph](../kartograph)(Kotlin) · [dartograph](../dartograph)(Dart) · [isthmus](../isthmus)(언어 경계 조인)와 `bridge-facts` / `external-retentions` 교환 형식을 공유하며, cartograph 는 그 형식의 첫 생산자·소비자다.

## Current Progress

**릴리스**: 0.1.0 → … → 0.5.5 (2026-09-03~05) → 0.6.0 → 0.7.0 (2026-09-06) → 0.8.0 (2026-09-07). 전부 GitHub Release + Homebrew tap(`ictechgy/tap`, `HOMEBREW_TAP_TOKEN` 이 없어 손 갱신) + `brew upgrade` 확인. `main` 은 깨끗하다.

**0.5.x 에서 들어간 것** (자세한 것은 CHANGELOG)
- `bridges --format json|text --target flutter|react-native`: Swift 소스와 `.m` 파일에서 언어 경계 사실(`channel-register`, `method-handle`, `module-export`, `component-export`)을 뽑아 인덱스의 USR 을 붙여 `bridge-facts` v1 로 낸다. 한계를 실제로 세어 싣는다(`dynamic-*`, `inferred-channels`, `unattributed-method-handles`, `missing-handler-usrs`, `objc-named-classes`, `objective-c-handlers`, `objective-c-sources`, `unscanned-event/message-channels`, `mixed-targets`, `target-filter`).
- `--external-retentions <path>` / `external_retentions_path`: isthmus 가 돌려준 근거로 `RetentionReason.externalBridge` 보존. `dead --explain` 이 근거를 문장으로, `query` 가 파일 출처·미매치·모호·낡음을 `limitations` 로.
- `dead --report-format json` 에 `query` 와 같은 `limitations`.
- 코퍼스에 Objective-C 타깃, Flutter 클로저·FlutterPlugin 위임·메서드 참조 세 형태, `external-retentions.json` 왕복. `verify-fixtures.sh` 가 진짜 인덱스로 전부 고정.
- 저장소 자체가 Claude Code 플러그인(`.claude-plugin/`). `Skills/` 를 그대로 가리켜 세 번째 사본이 없다. 매니페스트 `version` 은 릴리스 태그와 같이 올린다.
- `docs/scans/2026-09-flutter-plugins.md`: 공개 저장소 14개의 Swift/ObjC 쪽 첫 실측과 plus_plugins 7개의 실제 Dart↔Swift 조인. `Scripts/scan-public-plugins.sh` 로 재현(커밋 고정).
- `docs/demo/agent-deletes-native-handler/`: 재현 패키지 **초안**. Flutter SDK 가 없어 끝까지 못 돌렸다.

**리뷰**: 4 트랙(GLM packet-ask · Codex · Antigravity · Grok) 리뷰 1회 + GLM max 리뷰 다수. 지적과 반응은 PR #11 · #15 · #18 · #24 · #27 코멘트에 있다. 거절한 지적은 이유와 함께 거기 있다.

**환경**: 이 머신에 Dart SDK(brew `dart-sdk` 3.13)와 dartograph 0.2.0(`~/.pub-cache/bin`), isthmus 로컬 빌드(`../isthmus/dist/cli/main.js`, 0.1.4)가 있다. **Flutter SDK 는 없다.**

## 2026-09-06 세션 — 감사와 결함 수정 6건

다중 렌즈 감사(전략 3안 + 성능·CLI 사용성·에이전트 UX·코드 건전성·배포 5렌즈, 지적마다 반박 검증)를
돌리고 그 결과를 순서대로 고쳤다. 전부 머지되어 **0.6.0 으로 나갔다.**

| PR | 무엇 |
|---|---|
| #31 | 빈 인덱스가 `--strict` 를 통과하던 것, 제외 글롭이 프로젝트 루트의 조상에 걸리던 것, 심볼릭 링크 루트에서 순회가 비던 것 |
| #32 | DerivedData 이름을 폴더가 아니라 `.xcodeproj`·`.xcworkspace` 에서 만든다. Flutter·RN 의 `ios/` 가 전부 여기 걸려 있었다 |
| #33 | README 의 `from: "0.5.5"` 가 해석되지 않는다. `revision:` 이어야 한다 |
| #34 | 자기 분석의 `cycles --strict` 가 모듈 레벨이라 구조적으로 발화할 수 없었다. 타입 레벨을 게이트에 추가하고 걸리는 결합 둘을 끊었다 |
| #35 | 한계 목록이 상시 경보였고(네 프로젝트 전부) JSON 리포터만 렌더링했다. 조용하게 만든 뒤 text·xcode·github-actions·SARIF 로 내보낸다 |
| #36 | 라이브러리 패키지의 첫 실행이 공개 API 전체를 미사용으로 냈다. 기본값은 그대로 두고 한계로 알린다 |

**순서가 설계의 일부였다.** #35 의 두 커밋은 상시 경보를 먼저 끄고 그다음에 CI 형식으로 내보낸다.
반대로 했으면 모든 CI 실행에 영구 알림이 붙는다. #36 은 #35 뒤에야 보이는 자리를 갖는다.
#31 도 경로 수정 둘이 가드보다 먼저여야 `DerivedData` 아래 정상 프로젝트가 하드 실패로 뒤집히지 않는다.

각 PR 본문에 재현 명령과 실측 수치가 있다. 반박 리뷰에서 기각한 지적과 그 이유도 코멘트에 남겼다.

## 0.8.0 — 감사의 남은 항목을 전부 (2026-09-06~07)

| PR | 무엇 | 실측 |
|---|---|---|
| #42 | 타입은 미사용인데 그 멤버는 `retained` 라고 답하던 모순. 증인 보존이 소유 타입의 도달성을 기다린다 | 네 프로젝트에서 발견·테스트 전용 목록 바이트 동일, 도달 수만 감소 |
| #43 | 경로 필터를 심볼마다가 아니라 파일마다 판정 | `graph --level symbol` 0.71~0.75 → 0.64~0.65 초 |
| #44 | 인덱스에서 나오는 참조를 정렬하지 않는다. `extensionTargets` 의 순서 의존도 함께 닫음 | 명령마다 약 0.13 초. `dead` 0.64 → 0.48 초. 28/28 출력 바이트 동일 |
| #45 | #42 가 고친 한계를 두 README 와 스킬 규칙 6 에서 내림 | 실제 앱으로 동작 변화 확인 |
| #46 | `query --batch` (F37). 인덱스를 한 번만 읽고 최대 1000건에 답한다 | 43건 스윕 **19.6 → 0.47 초.** 답 43/43 동일 |
| #47 | 모호한 이름의 후보를 고를 수 있게 (F12) + `타입.멤버` 조회 | `body` 후보 127개 중 122개가 같은 글자 → 127개가 서로 다름 |

#43 의 벽시계 이득이 프로파일 비중(3분의 1)보다 작다. 인덱스 읽기가 지배적이기 때문이고,
그 사실을 CHANGELOG 에 적었다. "3분의 1" 만 인용하면 다음 사람이 잘못된 기대를 갖는다.

GLM 리뷰가 #42 에서 **테스트 전용 목록을 만드는 두 번째 순회가 걸러진 근거 목록을 조건 없이
다시 씨앗으로 쓴다**는 것을 잡았다. 지금은 맞지만 우연이고, 그 목록을 바꾸는 다음 사람에게
증인과 호출자가 쏟아진다. 같은 조건을 걸고 테스트 전용 수가 그대로임을 실측했다.
내가 쓴 부분집합 단언이 실제로 물지 않는다는 지적도 되돌려 확인하고 도달 수 단언으로 바꿨다.

**GLM 리뷰가 네 PR 에서 각각 무언가를 잡았고, 매번 코드로 확인한 뒤 반영하거나 기각했다.**
잡힌 것 중 가장 값진 셋: #44 에서 참조 정렬을 없애면 `extensionTargets` 의 "마지막이 이긴다" 가
"인덱스가 정한다" 로 바뀐다는 것(계측해서 중복 0건을 확인했지만 그래도 닫았다), #46 에서
베이스라인을 요청마다 다시 읽고 있다는 것, #47 에서 **`타입.멤버` 를 받게 만들어 놓고 그 타입
이름을 답에 싣지 않아 되물을 수가 없다**는 것. 마지막 것이 이 세션에서 리뷰가 만든 가장 큰
차이다. 기각한 것도 매번 이유를 PR 코멘트에 남겼다.

**리뷰가 낸 지적 중 내 테스트가 물지 않는다는 것이 두 번 있었고 두 번 다 맞았다.**
크기 검사가 파싱보다 먼저 도는 것을 고정하려던 테스트는 유효한 JSON 을 써서 순서를 바꿔도
같은 오류가 났고, `타입.멤버` 테스트의 픽스처는 USR 을 `Detail.body` 로 지어 정확 일치가 먼저
걸렸다. **새 테스트는 반드시 되돌려서 실패를 본다.** 이 세션에서 그렇게 확인한 것이 스물 넘는다.

## 타입 recall — 끝났다 (0.7.0)

같은 인덱스에서 Periphery 가 잡던 미사용 타입 7개를 이 도구는 0개 잡고 있었다. 원인은 버그가
아니라 문서화된 트레이드오프 둘이 겹친 것이었다 — 외부 준수·오버라이드 멤버와 합성 선언이
각각 소유 타입까지 살렸다.

선행 PR(#39)이 먼저 들어갔다. 인덱서가 열거형 케이스의 연관 값 타입, 타입 별칭의 우변,
`associatedtype` 증인에 관계를 달지 않아 그 타입들에 들어오는 간선이 하나도 없었다. 그 상태로
보존을 좁혔으면 지우면 컴파일이 깨지는 오탐이 나갔다. 원시 인덱스를 열어 확인했고, 위치로
소유자를 찾아 붙이되 **좁게** 잡았다 — 넓게 잡았더니 `@Observable` 확장이 앞 타입에 붙어
거짓 순환 두 건이 생겼다.

그다음 #40 이 보존을 멤버까지로 좁혔다. `extension X: View` 표기도 같은 가드를 받는다.
네 프로젝트에서 재고 새 발견 8건을 전부 grep 으로 확인했다(모두 선언 한 줄 외 참조 0).

**남은 비대칭 하나는 #42 에서 닫혔다.** 도달 불가한 타입 안의 멤버가 `retained` 라고
답하던 것이다. `body` 는 "프레임워크가 부른다" 는 이유로 보존되는데 그것은 타입이 살아 있을
때만 참이다. 증인 보존이 이제 소유 타입의 도달성을 기다린다(`pendingWitnesses` 재사용).
두 README 의 알려진 한계와 스킬 규칙 6 도 그에 맞춰 지웠는지 다음 세션이 확인할 것.

## 에이전트 실험 두 판 — 둘 다 차이를 못 냈다 (2026-09-06)

감사가 "2번이 끝난 날 같은 설계로, 그래프가 꼭 필요한 질문에 대해 에이전트 실험을
재실행" 하라고 했다[G502]. 두 판을 돌렸고 **둘 다 두 팔이 만점이었다.** 기록해 둔다.
다음 사람이 같은 설계를 세 번째로 돌리지 않도록.

### 1판 — 통제군이 샜다

실제 앱에서 `grep -rn '\bNAME\b'` 이 자기 선언 한 줄만 내는 선언 다섯을 골랐다.
정답은 2 keep / 3 delete 로 갈린다(`short` 는 CaseIterable 케이스, `readableContentTypes`
는 `FileDocument` 요구사항). 스킬을 읽는 팔과 아무 말도 듣지 않는 팔로 나눠 각 5회.

**결과 5/5 대 5/5, 그리고 열 번 모두 cartograph 를 썼다.** 워크플로 서브에이전트는
메인 루프의 cwd 에서 돌고 그게 이 저장소다. 대조군이 도구의 소스 트리 안에 서 있었고
빌드된 바이너리와 HealthMap 의 DerivedData 를 스스로 찾아 썼다. 대조군이 아니었다.

### 2판 — 통제군을 격리하고 문항을 다시 짰다

텍스트 팔에 분석기·빌드·컴파일러 금지를 명시하고 소스와 git 만 쓰게 했다. 문항은
**첫 grep 이 적극적으로 오도하도록** 다시 골랐다. 셋 다 HealthMap 실제 선언이다.

| 문항 | 정답 | grep 이 보여 주는 것 |
|---|---|---|
| `exportRecord` (WorkoutHealthExportStore.swift:83) | delete | 같은 파일 88행에 진짜 호출부. 그런데 그 `alreadySaved` 도 호출자가 없다 |
| `healthMapSafeMediaImage` (MediaGallery.swift:685) | delete | 호출부 둘. 둘 다 형제 오버로드 `(fileURL:)` 로 간다 |
| `newRequestID` (FirebasePrivacyGateway.swift:56) | delete | 히트 6개. 전부 `PrivacyStore` 의 동명 저장 프로퍼티다 |

여기에 텍스트 참조가 아예 없는 keep 두 문항을 남겨 균형을 맞췄다. 각 셀 2회, 팔당 10회.

**결과 10/10 대 10/10. 텍스트 팔의 분석기 사용 0회(자기 보고).**

비용도 차이가 없었다. 하네스가 기록한 값이다.

| 팔 | 토큰 중앙값 | 도구 호출 중앙값 | 초 중앙값 |
|---|---|---|---|
| 스킬 | 66,097 | 20.5 | 149.6 |
| 텍스트 | 58,232 | 20.0 | 111.2 |

스킬 팔이 더 비쌌다. 스킬 문서를 읽는 호출이 얹히기 때문이다.

### 무엇을 배웠나

**세 함정 모두 같은 한 수로 무력화됐다** — 첫 grep 에서 멈추지 않고 호출부를 한 번 더
읽는 것. 문항을 "첫 grep 이 오도하게" 만드는 데는 성공했지만 **두 번째 수의 비용을
전혀 올리지 못했다.** Opus 급 에이전트에게 그 한 수는 공짜다.

**이 실험은 "분석기 대 텍스트" 가 아니라 "텍스트+분석기 대 텍스트" 였다.** 스킬 팔 10회
전부가 index-staleness 한계(143 중 8)를 보고받고 그 구멍을 텍스트 검색으로 메웠다.
상위집합 대 부분집합이므로 스킬 팔은 오도되지 않는 한 지지 않고, 텍스트만으로 충분한
문항에서는 이길 수도 없다.

**정답 안에도 부실한 단계가 있었다.** 텍스트 팔 하나가 `git log -S` 로 "호출자가 있었던
적이 없다" 를 논증했는데, pickaxe 는 출현 **횟수 변화**만 잡으므로 한 커밋에서 호출부를
추가하며 다른 출현을 지우면 안 걸린다. 결론은 맞고 논증은 성립하지 않는다. 정답률만
보면 이런 것이 전부 가려진다.

### 그래서 README 에 실을 문장은 아직 없다

현재 데이터가 정당화하는 문장은 "두 조건 모두 만점이었고 차이를 관측하지 못했다" 뿐이다.
10/10 의 이항 95% 신뢰구간은 대략 [0.69, 1.0] 이고 두 팔 비교의 Fisher 정확검정은 p = 1 이다.
**어떤 크기의 차이도 배제하지 못한다.** "정밀도 100%" 류의 문구를 이 데이터로 쓰지 말 것.

### 세 번째 판을 돌린다면

같은 설계를 반복하지 말 것. 이번 판이 고친 것은 통제군 격리 하나뿐이고 변별력은 그대로 0이었다.

1. **한 파일 더 읽어서 풀리지 않는 문항.** 모듈을 넘는 긴 도달 체인, 준수자가 여럿인
   프로토콜 witness 디스패치, 빌드 구성에 따라 타깃 소속이 달라지는 심볼.
2. **단계·시간 예산을 걸고 정확도와 비용을 함께 기록한다.** 두 팔이 다 맞히는 세계에서
   남는 유일한 차이는 비용이고, 예산이 없으면 그 차이도 안 보인다.
3. 문항을 5개가 아니라 서로 다른 30개 이상으로. 반복은 군집일 뿐 표본이 아니다.
4. 정답 라벨을 실제 삭제 후 빌드로 검증한다. 프레임워크 사전지식만으로 답이 나오는
   문항(`readableContentTypes` 가 그랬다)은 제외한다.
5. `usedAnalyzer` 를 자기 보고가 아니라 도구 호출 로그로 검증한다.

**전략적으로는 해자 토론의 결론을 오히려 굳힌다.** 한 언어 안에서는 성실한 에이전트가
텍스트만으로 따라온다. 텍스트가 원리적으로 닿지 못하는 곳은 **다른 언어가 부르는 코드**뿐이고,
그 증거는 Swift 트리 안에 없다. isthmus 조인과 재현 데모가 여전히 유일한 후보다.

## 해자 토론 결론 (2026-09-05, GLM max effort 와 함께)

지금 해자는 없다. 설계는 며칠이면 복제되고(이 저장소가 증거), 에이전트 친화는 시점 이득이며, 코퍼스는 규모가 안 된다. 가장 큰 결핍은 **수요 증거 0건**. 1인이 가질 수 있는 유일한 후보는 "다른 언어가 부르는 코드를 에이전트가 지우는 사고" 라는 좁고 자라는 pain 에 대한 **측정되어 공개된 신뢰**. 나머지 기능은 그 pain 의 부품. 폭 확장(지표·리포트 형식·EventChannel)은 멈추고 스캐너 정밀도와 증거에만 쓴다.

30일 계획 상태: (1) 재현 데모 — 초안, Flutter 머신 필요. (2) 외부 도입 — plus_plugins 를 실제로 조인해 봤으나 **불일치가 없어 이슈를 열 근거가 없다**. 제안서(세션 스크래치에만)는 보류. (3) 생태계 스캔 — Swift 쪽 완료, Dart 쪽은 plus_plugins 만. (4) 폭 절단 — 진행 중. (5) 측정된 신뢰 — 스캔 리포트가 첫 공개 수치. (6) 스킬 카탈로그 — 매니페스트 완료, 마켓플레이스 등록은 사용자 계정 행동.

## What Worked

- **남이 쓴 코드가 오탐의 유일한 원천이었다.** 공개 플러그인 스캔이 스캐너 결함 넷을 찾았다: 위임 등록을 사실이 아니라 추측으로 셈(110 중 52), 메서드 참조 핸들러, `setMethodCallHandler(nil)`, `switch (call.method)` 괄호. 코퍼스는 하나도 못 잡았다.
- **실제 조인이 계약의 마찰을 드러냈다.** plus_plugins 는 Dart 채널이 `*_platform_interface` 패키지에 따로 있어 isthmus 의 "모든 문서가 같은 `project`" 요구에 걸렸고, cartograph 는 `/tmp`, dartograph 는 `/private/tmp` 로 쓴다. 두 문서를 공통 루트로 손으로 고쳐야 조인이 돌았다.
- **리뷰 주장을 코드로 확인한 뒤 반영.** 네 트랙은 서로 다른 것을 잡는다(GLM 설계 원칙, Codex 정적 사실, Grok 통합 지점, agy 가독성). 합의 점수가 높은 것부터. 틀린 지적도 매번 있었다(swift-syntax 600 호환, 계약 버전, `init?` 정규화 방향).
- **테스트가 실제로 무는지 확인.** 새 테스트를 옛 스캐너에 돌려 실패를 본 뒤에만 "고정했다" 고 했다.
- **인덱스 없이도 `bridges` 스캔이 된다.** 저장소 루트에 더미 SwiftPM 타깃을 빌드하면 인덱스만 생기고 전체 Swift 를 훑는다(USR 은 안 붙는다).

## What Didn't Work / Avoid

- **"구문만으로 확신할 수 없는 이름은 dynamic" 을 한 곳에만 적용했다.** 수신자 없는 `.name`, 타입을 무시한 상수 표, 파일 전역 지역 상수·별칭, 클로저·중첩 함수를 모르는 스코프, 이름만으로 맞춘 핸들러·위임 표 — 여덟 곳이 같은 형태로 조인 가능한 틀린 리터럴을 냈다. 새 해석 경로마다 "이 이름이 다른 모듈·다른 타입·다른 스코프의 것일 수 있는가" 를 먼저 물을 것. 기록은 원문, 해석은 파일을 다 읽은 2차 패스에서.
- **주석·문자열 제거를 두 패스로 나누면 서로를 깨뜨린다**(`// TODO /* note`). 상태 기계 하나로.
- **테스트가 옛 동작을 옳다고 고정하고 있었다**(`.channelName`). 통과와 정확은 다르다.
- **데모 서사가 틀렸다.** 표준 `FlutterPlugin` 형태에서 `handle` 은 외부 프로토콜 준수라 cartograph 가 이미 살린다. "cartograph 가 핸들러를 죽었다고 한다" 는 이 형태에 거짓이고, 진짜 실패는 텍스트 검색으로 일하는 에이전트가 `case` 가지를 지우는 것이며 그것을 보는 것은 교차 언어 조인뿐이다.
- **Pigeon 파일을 단어 검색으로 셌다**(114 → 헤더 기준 15). 리포트 수치는 방법을 적은 대로만.
- **`verify-fixtures.sh` 는 릴리스 바이너리를 빌드하지 않는다.** 낡은 바이너리로 검증해 헤맸다. `swift build -c release` 먼저.
- **SwiftParser 는 이항 연산자를 접지 않는다.** `SwiftOperators.foldAll` 없이는 `=` 와 `==` 가 안 보인다. `Regex` 는 Sendable 이 아니라 `static let` 로 못 둔다.
- **ultra-review 러너**: `SESSION_ID` 에 `$$` 를 쓰면 source 마다 토큰이 바뀐다. Codex 는 stderr 의 "quota" 로 오분류되니 출력을 직접 본다. Grok 은 `--no-memory` 가 없어 규칙상 skip, 허락 시 "도구 없음, 본문에서 답하라" 머리말이 필요하다. agy 에 `--disable-slash-commands` 를 쓰면 `--mode plan` 이 무효화된다.
- 스택 PR 의 부모를 `--delete-branch` 로 머지하면 자식 PR 이 닫힌다. `packet-ask` 는 스크래치 git 저장소에서 `review --files` 로만.

## Known Limitations (누락 방향, 오탐 아님)

다른 파일의 `@objc(Name)` 익스텐션, 저장 클로저 프로퍼티 핸들러, `if let m = call.method`, 튜플 패턴 `case (Channel.x, _)`, `@IBAction`, `#if 0 … #elif 참`, 파일 자체가 symlink, `handle` 이 `handleAsync(call)` 로 한 홉 더 넘기는 위임(audioplayers 23건), `bridges` 의 구문 캐시 부재, `indexStoreDate` 가 디렉터리 mtime 만 봄(실측 필요). Pigeon `BasicMessageChannel` 은 세기만 한다 — 계약에 kind 가 없다.

## isthmus 에 돌려줄 피드백

`../isthmus/HANDOFF.md` 의 "cartograph 에서 온 계약 피드백" 절에 쌓여 있다. 문서당 하나인 `target`, `null`·추측 채널, Swift `@objc` 와 `.m` 양쪽의 같은 `(channel, method)`, `inferred` 필드 부재, module-export 조인 시 메서드마다 근거, **`project` 동일 요구가 모노레포 플러그인을 막음**, `/tmp` 정규화, `objective-c-sources` 가 있으면 `unhandled-invocation` 을 경고로, 원인을 숨기는 오류 메시지. 그쪽 세션의 차례다.

## Next Steps (2026-09-06 저녁 갱신)

**감사의 Top 10 은 전부 닫혔다.** 7번(형제 멤버 억제, G203)은 별도로 고친 것이 아니라
#40·#42 가 보존을 좁히면서 사라졌다 — HealthMap 에서 `NotificationPreferencesController` 가
이제 타입 자체로 보고되고 멤버 셋은 따로 나오지 않는다. 다음 순위 넷 중 둘도 닫혔다
(#43 경로 필터, #44 참조 정렬).

1. **자매 저장소와 스키마를 맞춘다.** 이 세션이 `Candidate` 에 `kind`·`module`·`location`·
   `container` 를 더했고 `symbol-query-batch` v1 을 그대로 따랐다. 더한 필드는 전부 선택적이고
   옛 문서를 읽는 테스트도 있지만, **kartograph 와 dartograph 는 아직 `{qualifiedName, usr}`
   만 낸다.** 세 저장소가 같은 답을 내지 않으면 에이전트가 언어마다 다른 규칙을 배운다.
   같이 정할 것: 후보의 새 필드, `location` 을 절대 경로로 둘지 프로젝트 상대로 바꿀지
   (바꾸려면 문서에 루트 필드가 필요하다), 그리고 배치의 종료 코드.
2. **배치 종료 코드를 다시 볼지.** 지금은 하나라도 못 찾으면 64 다(dartograph 와 같다).
   GLM 이 반대 논거를 냈고 설득력이 있다 — 낡은 `dead` 리포트에 이름이 빠져 있는 것은 정상이고,
   `set -e` 나 `&&` 로 묶인 스크립트는 답을 다 받고도 버린다. 형식을 바꾸는 것은 세 저장소가
   함께 할 일이라 여기서 하지 않았다. 완충(없는 이름 지목, 도움말에 "표준 출력이 먼저")은 넣었다.
3. **에이전트 실험 3판** — 위 절의 조건을 갖출 수 있을 때만. 같은 설계로 또 돌리지 말 것.
4. **Flutter SDK 가 있는 머신에서** `docs/demo/agent-deletes-native-handler/` 를 끝까지 돌린다.
   위 실험 결과가 이것의 우선순위를 올렸다 — 텍스트가 원리적으로 닿지 못하는 유일한 자리다.
5. **`HOMEBREW_TAP_TOKEN`** 을 넣어 tap 손 갱신을 그만둔다 [F49]. 사용자 계정 행동이다.
6. 감사에서 아직 손대지 않은 것: CLI 오류 메시지 뭉치 [F28~F33], 에이전트 답의 공백
   [F34/F35/F38/F39], GitHub Action [F19], 공증 [F48]. **읽기/쓰기 엣지 신설 [G202] 은
   감사가 "추적만 하고 시작하지 말라" 고 했다** — Periphery 가 잡는 assign-only 40건을 이 도구는
   원리상 0건 잡는다. **두 README 의 알려진 한계에 적었다**(네 줄짜리 패키지로 재현해서
   `dead` 가 아무것도 안 내고 `query` 가 `reachable` 이라고 답하는 것을 확인했다).
   기능 자체는 L 규모라 시작하지 않았다.
7. 아래는 이전 세션의 항목들이다.

### 이전 세션의 Next Steps

1. **Flutter SDK 가 있는 머신에서** `docs/demo/agent-deletes-native-handler/README.md` 의 절차를 끝까지 돌리고 틀린 곳을 고친다. 수요 증거의 첫 건이 될 재현 패키지다.
2. **Dart 쪽 스캔을 넓힌다.** 이 머신에서 가능하다. 스캔 리포트의 나머지 Swift 플러그인(mobile_scanner, flutter_secure_storage, flutter_local_notifications, audioplayers)을 plus_plugins 처럼 조인해 "Dart 가 부르지 않는 핸들러" 수를 낸다. isthmus 가 `project` 요구를 풀기 전까지는 두 문서를 공통 루트로 정규화해야 한다(방법은 스캔 리포트 "The join" 절).
3. **plus_plugins 이슈는 열지 않는다.** 불일치가 없었다. 제안서는 세션 스크래치에만 있고 저장소에 없다. 다시 필요하면 스캔 리포트의 조인 절과 CHANGELOG 0.5.4·0.5.5 항목에서 재구성한다.
4. **`query` 응답에 evidence 를 실을지**는 자매 저장소와 스키마를 맞춰야 해서 보류.
5. **`HOMEBREW_TAP_TOKEN`** 은 사용자 계정 행동. 있으면 `release.yml` 이 tap 을 자동 갱신한다.
6. 새 브리지 kind(EventChannel, BasicMessageChannel)는 isthmus `GRAPH-EXCHANGE.md` 를 먼저, 그다음 생산자 테스트.

## Verification (마지막으로 통과한 것, PR #47 시점)

`Scripts/coverage.sh` 92.98%(테스트 655개) · `Scripts/verify-cli-contract.sh` ·
`Scripts/verify-fixtures.sh`(진짜 인덱스) ·
자기 분석 `dead`/`cycles`/`cycles --level type`/`rules --strict` 전부 0.
실제 프로젝트 셋(HealthMap · ruokay · Gakjaba)이 플래그 없이 분석된다.

**`query` 는 `--since` 를 쓰지 않는다.** `finish()` 도 `measureMetrics()` 도 부르지 않는다.
플래그는 광고되지만 조용히 무시된다 — 감사의 [F30] 에 해당하는 자리다. 이것을 모르고
"`--since` 를 걸고 비교했더니 같더라" 를 증거로 쓴 적이 있다. 통과할 수밖에 없는 비교였다.

### 0.7.0 시점의 기록

`Scripts/coverage.sh` 93.46% · `Scripts/verify-cli-contract.sh` · `Scripts/verify-fixtures.sh` ·
자기 분석 전부 0 · CI 두 잡.

### 0.5.5 시점의 기록

`Scripts/coverage.sh` 92.92%(128 테스트) · `Scripts/verify-cli-contract.sh` · `Scripts/verify-fixtures.sh`(진짜 인덱스, 두 target, 외부 근거 왕복, `objective-c-sources`) · 자기 분석 `dead`/`cycles`/`rules --strict` 전부 0 · CI 두 잡 · 릴리스 워크플로(유니버설 빌드, 압축 푼 바이너리로 CLI 계약 재검증) · `brew upgrade` 0.5.5.

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph` 를 열고 `HANDOFF.md` 와 해당 `AGENTS.md` 를 읽은 뒤, `git status --short --branch` 와 `gh pr list` 로 다른 세션이 남긴 것이 없는지 확인하고, Next Steps 의 1 또는 2 에서 이어간다. 코드를 바꾸기 전에 어느 항목인지 명시한다.
