# Handoff

_Last updated: 2026-09-05 by Claude (PR #24) — 이전 판은 Codex, 2026-09-05 01:41 KST_

## Goal

- Swift/iOS 의존성 그래프와 브리지 사실을 근거와 함께 제공하고, isthmus가 돌려준 외부
  retention으로 문자열 경계 너머의 실제 Swift 심볼을 보존한다.

## Current Status

- 0.5.3 제품 변경 기준은 `a6e773d`(PR #21)이며, 이 문서는 PR #22로 그 위에 merge됐다.
- cartograph `0.5.3` 릴리스와 macOS universal 자산이 공개됐다.
- Homebrew tap은 `ictechgy/homebrew-tap@70f0c7f`로 갱신됐고 로컬 설치도 0.5.3이다.
- 필수 후속 구현이나 배포 blocker는 없다.
- `.claude-plugin/plugin.json` 의 `version` 은 릴리스 태그와 같이 올린다(릴리스 체크리스트 항목).
- PR #24(머지 대기): 공개 플러그인 14개 스캔 리포트, 스캔이 찾은 스캐너 형태 셋 반영, 저장소를
  Claude Code 플러그인으로(`.claude-plugin/`), 재현 패키지 초안. 릴리스는 아직 안 했다(0.5.4 후보).
- 이 저장소에 세션이 둘 있었다(Claude 가 0.5.1·0.5.2, Codex 가 0.5.3). 큰 작업 전 `git status` 와
  `gh pr list` 로 확인할 것.

## 해자 토론 결론과 30일 계획 (2026-09-05, GLM max effort 와 함께)

- 지금 해자는 없다. 설계는 며칠이면 복제되고(이 저장소가 증거), 에이전트 친화는 시점 이득이며,
  코퍼스는 규모가 안 된다. 가장 큰 결핍은 **수요 증거 0건**.
- 1인이 가질 수 있는 유일한 후보: "다른 언어가 부르는 코드를 에이전트가 지우는 사고" 라는 좁고
  자라는 pain 에 대한 **측정되어 공개된 신뢰**. 나머지 기능은 그 pain 의 부품.
- 30일 계획과 상태: (1) 수요 검증 재현 패키지 — `docs/demo/agent-deletes-native-handler/` 초안,
  Flutter SDK 있는 머신에서 끝까지 돌려야 함. (2) 외부 도입 1건 — plus_plugins CI 제안서 작성됨(저장소
  밖), 열기 전 이슈로 물을 것. (3) 생태계 스캔 — `docs/scans/2026-09-flutter-plugins.md`, Dart 쪽은
  dartograph 로 마저 셀 것. (4) 폭 절단 — 지표·형식 확장 중단, 스캐너 정밀도만. (5) 측정된 신뢰 —
  스캔 리포트가 첫 공개 수치. (6) 스킬을 카탈로그에 — 플러그인 매니페스트 완료, 마켓플레이스 등록은
  사용자 계정 행동.

## Completed

- `bridges --target flutter|react-native`로 혼합 프로젝트 사실을 target별로 분리한다.
- bridge 위치는 project-relative path, 생성 시각은 UTC millisecond 형식으로 출력한다.
- target 필터에서 제외한 사실 수를 `target-filter:` limitation으로 남긴다.
- `Fixtures/FalsePositiveCorpus/lib/camera.dart`로 실제 dartograph→isthmus 왕복을 지원한다.
- GLM max 리뷰의 medium 지적을 반영했고 후속 리뷰에서 high/medium blocker 0건을 확인했다.

## Key Files & State

- `Sources/CartographKit/BridgeFacts.swift`: bridge 문서 생성과 target 필터.
- `Sources/CartographKit/CartographService.swift`: bridge export와 external retention 소비.
- `Sources/cartograph/CartographCommand.swift`: `bridges --target` 공개 CLI.
- `Scripts/verify-fixtures.sh`: 실제 인덱스, target 분리, external retention 회귀 게이트.
- `Fixtures/FalsePositiveCorpus/`: Swift/RN/Dart 공통 왕복 fixture.
- `CHANGELOG.md`: 0.5.3 변경 및 비교 링크.

## Important Context / Decisions

- Facts:
  - bridge v1 문서는 fact가 있으면 target 하나만 가질 수 있으므로 생산 단계에서 분리한다.
  - USR을 붙이기 위해 `bridges`는 compiler index store가 필요하며, 없으면 종료 코드 2다.
  - 같은 Swift handler 심볼에 여러 bridge method retention이 연결돼도 현재 `--explain`은
    결정적인 대표 evidence 하나를 보여 준다. retention 자체는 모두 소비된다.
  - GitHub release workflow에는 `HOMEBREW_TAP_TOKEN`이 없어 tap 갱신을 수동 수행했다.
- Assumptions:
  - isthmus 연동은 cartograph 0.5.3 이상과 dartograph 0.1.1 이상을 사용한다.

## Verification

- Ran: `Scripts/coverage.sh`
  - Result: pass, 128 tests, line coverage 92.93%.
- Ran: `Scripts/verify-cli-contract.sh <debug-cartograph>`
  - Result: pass, including invalid target and missing index-store exits.
- Ran: `Scripts/verify-fixtures.sh <debug-cartograph>`
  - Result: pass, including both bridge targets and external retentions.
- Ran: GitHub PR #21 CI
  - Result: both jobs passed.
- Ran: release workflow for tag `0.5.3`
  - Result: universal build, packaged-binary CLI verification, GitHub Release passed.
- Ran: `brew upgrade ictechgy/tap/cartograph` and installed CLI contract
  - Result: 0.5.3 installed; full CLI contract passed.

## Blockers & Open Questions

- No blocker.
- isthmus 에 돌려줄 계약 피드백은 `../isthmus/HANDOFF.md` 의 "cartograph 에서 온 계약 피드백" 절에
  있다: 문서당 하나인 `target`, `null`·추측 채널, Swift `@objc` 와 `.m` 양쪽의 같은 `(channel, method)`,
  `inferred` 필드 부재, module-export 조인 시 메서드마다 근거를 낼 것.
- `query` 응답에 evidence 를 실을지는 자매 저장소와 스키마를 맞춰야 해서 보류.
- 알려진 누락(오탐 아님): 다른 파일의 `@objc(Name)` 익스텐션, 저장 클로저 프로퍼티 핸들러,
  `if let m = call.method`, 튜플 패턴, `@IBAction`, `#elif`, 파일 자체 symlink, `handle` 이 `handleAsync(call)` 로 한 홉 더
  넘기는 위임(audioplayers 23건).
- Optional follow-up: decide whether one symbol should retain and explain multiple bridge evidence records.
- Optional follow-up: add EventChannel/BasicMessageChannel only after GRAPH-EXCHANGE adds explicit semantics.

## What Worked

- Contract changes were fixed with failing tests before implementation and checked against a real compiler index.
- Synthetic dead-suppression and public-plugin evidence tests cover different sides of the integration.

## What Did Not Work / Avoid

- "구문만으로 확신할 수 없는 이름은 dynamic" 을 한 곳에만 적용했다. 수신자 없는 `.name`, 타입을
  무시한 상수 표, 파일 전역 지역 상수·별칭, 클로저·중첩 함수를 모르는 스코프 — 다섯 곳이 같은 형태로
  조인 가능한 틀린 리터럴을 냈다. 새 해석 경로마다 "이 이름이 다른 모듈의 것일 수 있는가" 를 먼저 물을 것.
- 주석·문자열 제거를 두 패스로 나누면 서로를 깨뜨린다(`// TODO /* note`). 상태 기계 하나로.
- 테스트가 옛 동작을 옳다고 고정하고 있었다(`.channelName`). 통과와 정확은 다르다.
- 스캔이 찾은 형태가 코퍼스보다 먼저 스캐너를 고쳤다. 위임 등록을 사실이 아니라 추측으로 세고
  있었다(110 중 52). 남이 쓴 코드가 오탐의 유일한 원천이라는 AGENTS 의 문장이 다시 맞았다.
- ultra-review 러너: `SESSION_ID` 에 `$$` 를 쓰면 source 마다 토큰이 바뀐다. Codex 는 stderr 의 "quota"
  단어로 오분류되니 출력을 직접 본다. Grok 은 `--no-memory` 가 없어 스킬 규칙상 skip, 허락 시 "도구 없음"
  머리말이 필요하다. agy 에 `--disable-slash-commands` 를 쓰면 `--mode plan` 이 무효화된다.

- Do not run fixture verification against an old release binary; pass the freshly built binary explicitly.
- macOS `/var` and `/private/var` normalize differently across Swift and Dart producers. Shared-project
  integration fixtures should use a path without that alias or canonicalize both producers identically.
- Do not emit an unfiltered mixed-target document to isthmus v1.

## Next Steps

0. PR #24 머지 후 0.5.4 릴리스 여부는 사용자 결정. 그 뒤 위 30일 계획의 (1)·(2)·(3 Dart 쪽) 순서.
1. No required work remains for the 0.5.3/isthmus bridge milestone.
2. For a new bridge kind, update isthmus `docs/GRAPH-EXCHANGE.md` first, then producer tests.
3. Add `HOMEBREW_TAP_TOKEN` only if automatic tap updates are worth the broader credential setup.

## Resume Prompt

Open this repository at `/Users/jinhongan/Desktop/cartograph`, read `HANDOFF.md` and applicable
`AGENTS.md` files, then continue from: `No required 0.5.3 work remains; choose an explicit optional
follow-up before changing code.`
