# Handoff

새 세션이 이어받기 위한 문서다. 작업 규칙은 [AGENTS.md](AGENTS.md), Claude Code 전용 사항은 [CLAUDE.md](CLAUDE.md). 이 파일은 **지금 어디까지 왔고 다음이 무엇인지**만 담는다.

_마지막 갱신: 2026-09-05 (0.5.5 릴리스 직후, Claude). 이 저장소에는 세션이 둘 있었다(Claude 가 0.5.1·0.5.2·0.5.4·0.5.5, Codex 가 0.5.3). 큰 작업 전 `git status --short --branch` 와 `gh pr list` 로 확인할 것._

## Goal

Swift/iOS 코드베이스의 의존성 그래프를 컴파일러 인덱스에서 만들고, 그 위에서 미사용 코드 · 순환 · 레이어 규칙 · 지표를 **근거와 함께** 답하는 오픈소스 CLI. 소비자는 사람보다 코딩 에이전트라 `query` · `skill` · `limitations` 를 갖춘다. 자매 저장소 [kartograph](../kartograph)(Kotlin) · [dartograph](../dartograph)(Dart) · [isthmus](../isthmus)(언어 경계 조인)와 `bridge-facts` / `external-retentions` 교환 형식을 공유하며, cartograph 는 그 형식의 첫 생산자·소비자다.

## Current Progress

**릴리스**: 0.1.0 → … → 0.5.5 (2026-09-03~05). 전부 GitHub Release + Homebrew tap(`ictechgy/tap`, `HOMEBREW_TAP_TOKEN` 이 없어 손 갱신) + `brew upgrade` 확인. 로컬 설치는 0.5.5. `main` 은 깨끗하다.

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

## Next Steps

1. **Flutter SDK 가 있는 머신에서** `docs/demo/agent-deletes-native-handler/README.md` 의 절차를 끝까지 돌리고 틀린 곳을 고친다. 수요 증거의 첫 건이 될 재현 패키지다.
2. **Dart 쪽 스캔을 넓힌다.** 이 머신에서 가능하다. 스캔 리포트의 나머지 Swift 플러그인(mobile_scanner, flutter_secure_storage, flutter_local_notifications, audioplayers)을 plus_plugins 처럼 조인해 "Dart 가 부르지 않는 핸들러" 수를 낸다. isthmus 가 `project` 요구를 풀기 전까지는 두 문서를 공통 루트로 정규화해야 한다(방법은 스캔 리포트 "The join" 절).
3. **plus_plugins 이슈는 열지 않는다.** 불일치가 없었다. 제안서는 세션 스크래치에만 있고 저장소에 없다. 다시 필요하면 스캔 리포트의 조인 절과 CHANGELOG 0.5.4·0.5.5 항목에서 재구성한다.
4. **`query` 응답에 evidence 를 실을지**는 자매 저장소와 스키마를 맞춰야 해서 보류.
5. **`HOMEBREW_TAP_TOKEN`** 은 사용자 계정 행동. 있으면 `release.yml` 이 tap 을 자동 갱신한다.
6. 새 브리지 kind(EventChannel, BasicMessageChannel)는 isthmus `GRAPH-EXCHANGE.md` 를 먼저, 그다음 생산자 테스트.

## Verification (마지막으로 통과한 것, 0.5.5)

`Scripts/coverage.sh` 92.92%(128 테스트) · `Scripts/verify-cli-contract.sh` · `Scripts/verify-fixtures.sh`(진짜 인덱스, 두 target, 외부 근거 왕복, `objective-c-sources`) · 자기 분석 `dead`/`cycles`/`rules --strict` 전부 0 · CI 두 잡 · 릴리스 워크플로(유니버설 빌드, 압축 푼 바이너리로 CLI 계약 재검증) · `brew upgrade` 0.5.5.

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph` 를 열고 `HANDOFF.md` 와 해당 `AGENTS.md` 를 읽은 뒤, `git status --short --branch` 와 `gh pr list` 로 다른 세션이 남긴 것이 없는지 확인하고, Next Steps 의 1 또는 2 에서 이어간다. 코드를 바꾸기 전에 어느 항목인지 명시한다.
