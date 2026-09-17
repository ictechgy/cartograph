# Handoff

_Last updated: 2026-09-16 19:30 KST by Devin_

## Goal

경쟁 강화(warm 질의·dead 경고 3종·온보딩 안내), **0.16.0 릴리스와 Homebrew 배포**,
bridge-facts EventChannel 생산자·FFI interop 한계까지 **전부 머지·배포 완료**했다.
새 제품 구현·커밋은 요청되지 않았다.

## Current Status

- [0.16.0 릴리스](https://github.com/ictechgy/cartograph/releases/tag/0.16.0) 공개.
  소스는 PR [#90](https://github.com/ictechgy/cartograph/pull/90)(스쿼시 `5d7fd8f`)과
  버전 범프 [#91](https://github.com/ictechgy/cartograph/pull/91)(`05631e2`), 태그 `0.16.0`.
  Homebrew는 워크플로가 `HOMEBREW_TAP_TOKEN` 부재로 조용히 건너뛰어
  [tap PR #45](https://github.com/ictechgy/homebrew-tap/pull/45)를 수동으로 냈고 머지됐다.
  `brew upgrade` 0.15.1→0.16.0, `brew test` 통과.
- [PR #92](https://github.com/ictechgy/cartograph/pull/92) 머지(`9c3bd52`, 스쿼시):
  EventChannel `stream-handle` 사실 + `--events` v2 문서 + `unscanned-ffi-interop` 한계.
  isthmus 측 계약은 `docs/BRIDGE-EVENTS.md`에 이미 명세돼 있어 구현과 일치 확인.
- `origin/main`은 `9c3bd52`. 워크트리는 `/Users/jinhongan/Desktop/cartograph` 하나.
- 현재 브랜치는 `refactor/agent-guidance-0.14.0`(main 대비 4 뒤처짐). 미커밋 문서 변경
  (AGENTS.md·HANDOFF.md·Package.swift·Skills/AGENTS.md·Sources/AGENTS.md + 신규
  `Sources/CartographIndexStore/AGENTS.md`)은 다른 세션의 진행 중 작업 — 보존.
- 로컬 낡은 브랜치 15개 삭제 완료(전부 머지 확인: PR 원천·patch-equivalent·내용 대조).
  **원격에는 아직 12개 남아 있음** — 사용자에게 정리 여부를 물었으나 답 전에 화제가 바뀜.
  목록: `chore/release-0.10.0`, `chore/release-0.8.2`, `docs/release-090-status`,
  `feat/bridge-coverage-scopes`, `feat/interprocedural-value-flow`, `feature/bridge-facts-v2`,
  `feature/change-impact-workflow`, `fix/analysis-query-reliability`,
  `fix/analysis-reliability-and-query-performance`, `fix/bridge-constant-resolution`,
  `fix/bridge-flow-diagnostics`, `fix/bridge-project-realpath`, `fix/release-architecture-check`.

## Completed

- **경쟁 강화 (PR #90)**: warm 질의 단축, 미사용 파라미터/assign-only 프로퍼티/미사용 import
  경고 3종, 프로젝트 형태 맞춤 인덱스 없음 안내. 리뷰 루프(4라운드)에서 확인된 정확성 버그 4건
  수정: 외부 심볼 지연 귀속(`externalOnlyUSRs`), 다중 워크스페이스 선택+셸 인용,
  `AnalysisInputFingerprintCache` NSLock, 순환 재수출 폐포 고정점 반복.
- **0.16.0 배포**: release 워크플로 `35074750840` 성공(18m25s). asset SHA-256 독립 재계산
  일치(`4b423f7b…be57d31`), 압축 해제 바이너리 `--version` 0.16.0, universal 확인.
- **브리지 (PR #92)**: `setStreamHandler` non-nil 등록 → `stream-handle`; `--events` 문서는
  transport `event-channel`·version 2; `messages`/`events` 동시 지정은 CLI·공개 API 모두 거절;
  전송별 문서는 자신의 관측 공백(`unscanned-event/message-channels`)을 싣고 ObjC 소스 수는 공통.
  리뷰 루프(3라운드) 수정: 증명된 비-event 수신자 스킵, `==` 정확 일치만 분기 근거,
  `channel:` 인자보다 수신자 증명 우선, `dlsym` 공백 허용, 죽은 `stream` 한계 항목 제거,
  픽스처 골든에 dependencies·handlerScope 반영.

## Key Files & State

| 경로 | 읽는 이유 |
| --- | --- |
| [AGENTS.md](AGENTS.md), [Sources/AGENTS.md](Sources/AGENTS.md) | 필수 검사, 공통 계약과 모듈 경계; 하위 지침 색인 |
| [Sources/CartographIndexStore/AGENTS.md](Sources/CartographIndexStore/AGENTS.md) | `receivedBy`를 호출자로 읽지 않는 규칙, 제한적 소유자 귀속 |
| [Sources/CartographSyntax/BridgeFactScanner.swift](Sources/CartographSyntax/BridgeFactScanner.swift) | 채널 종류 증명(`provenChannelKind`), 분기 근거 극성 |
| [Sources/CartographKit/BridgeFacts.swift](Sources/CartographKit/BridgeFacts.swift) | v2 문서·전송별 limitation 집계 |
| [Sources/CartographKit/CartographService.swift](Sources/CartographKit/CartographService.swift) | `bridgeFacts` 공개 경계 검증, `isScopedDocument`(기본 문서 표식) |
| [Fixtures/FalsePositiveCorpus/expected-bridges.json](Fixtures/FalsePositiveCorpus/expected-bridges.json) | 브리지 골든 — 출력 필드 추가 시 갱신 필요 |
| [.github/workflows/release.yml](.github/workflows/release.yml) | 태그 검증, universal archive, 탭 갱신(토큰 없으면 조용히 건너뜀) |
| [docs/evaluation/2026-09-16-harder-comparison.md](docs/evaluation/2026-09-16-harder-comparison.md) | 어려운 작업 재측정 근거 |

## Important Context / Decisions

- **확정:** 미증명 수신자의 `setStreamHandler`는 동적 이름의 사실로 남긴다 — 메시지 경로와 같은
  dynamic 허용이고, 지우면 isthmus가 핸들러 존재를 모른다. **다른 종류로 증명된** 수신자만 거른다.
- **확정:** FFI 표식(`@_cdecl`·`@_silgen_name`·`dlsym`·`Dart_PostCObject`·`dart_native_api.h`)은
  어휘 증거라 사실이 아니라 파일 수준 `unscanned-ffi-interop` 한계다.
- **확정:** `isScopedDocument`는 "전송 문서"가 아니라 `includesFlutter && !messages && !events`인
  기본 문서 표식. 전송 문서의 카운트 조건은 `isScopedDocument || <flag>` 형태다.
- **미입증:** 한정 코퍼스·커버리지 수치는 전체 정확도나 에이전트 생산성의 증거가 아니다.
- **가정/후보:** `ImportScanner`의 `importKind`→`importKindSpecifier` 이전은 swift-syntax 하한을
  603+로 올릴 때. 원격 낡은 브랜치 12개 삭제는 사용자 확인 대기.

## Verification

| 검사 | 결과 |
| --- | --- |
| `swift test` (PR #92 헤드) | **1,454 tests** 전부 통과 |
| `Scripts/coverage.sh` | **92.92%** (기준 90%) |
| `Scripts/verify-cli-contract.sh` | 통과 (0/64/2 종료 코드 전 구간) |
| `Scripts/verify-fixtures.sh` | 통과 — 골든 갱신 후 재검증 |
| strict 자기 분석 | dead 181 경고(2 한계)·cycles·type cycles·rules 모두 findings 없음 |
| PR #92 CI | Build/test/coverage gate + 자기 분석 둘 다 SUCCESS |
| Release `35074750840` | 성공; 공개 asset 해시·universal·버전 직접 검증 |
| Homebrew | formula 0.16.0 + 검증된 sha256; `brew upgrade`·`brew test` 통과 |
| 변이 확인 | 새 테스트 5종이 해당 수정을 끄면 실패함을 확인 |

## Blockers & Open Questions

- `HOMEBREW_TAP_TOKEN`이 없어 탭 갱신은 계속 수동 PR. 자동화하려면 저장소 시크릿 추가 필요.
- 리뷰 인프라: Grok은 quota-exhausted로 두 번 연속 사용 불가. agy는 headless에서 도구 호출이
  자동 거부돼 프롬프트에 "도구 사용 금지" 문구가 필요하고, 가끔 그래도 무출력.
- `run-external`은 세션 디렉터리가 `mktemp -d` 수준(700)의 사설 디렉터리여야 하고, 재시도 전에
  stale `attempts/w001-<출력명>-` 디렉터리를 지워야 한다.
- 실기기·임의 DI/heap/반사의 완전성과 Core Data dynamic-framework-only 정의는 미지원/미검증.

## What Worked / Avoid

- 규칙마다 "그 규칙이 없으면 실패하는" 테스트 + 변이로 실제 무는지 확인.
- 리뷰 발견은 전부 코드·계약 문서와 대조해 검증 — 합의 ≠ 정답(agy의 `isScopedDocument` 오독),
  단독 트랙이라도 실증된 정확성 버그(순환 폐포)는 고친다.
- `git checkout`으로 변이를 되돌리면 미커밋 수정까지 날아간다 — `git stash`/수동 복원 사용.
- CI `success`만으로 탭 갱신·머지 상태를 주장하지 않는다 — formula 내용과 PR 메타데이터를 본다.
- 커밋 메시지 히어독에 백틱이 있으면 셸이 먹는다 — 메시지를 파일로 쓰거나 이스케이프한다.

## Next Steps

1. `git status --short --branch`, `git worktree list`, `git log --oneline -3 origin/main`으로 확인.
2. `refactor/agent-guidance-0.14.0`의 미커밋 guidance 리팩터는 다른 세션 작업 — 임의로 건드리지 않는다.
3. 원격 낡은 브랜치 12개 삭제는 사용자 확인 후 `git push origin --delete <branch>`로.
4. 새 제품 변경에는 관련 하위 지침과 필수 검사를 적용한다. 배포·태그 생성을 자동 재개하지 않는다.

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph`에서 `HANDOFF.md`와 적용되는 `AGENTS.md`를 읽으세요.
0.16.0 배포·Homebrew 갱신·PR #90/#91/#92 머지와 로컬 정리는 완료됐습니다. 현재
`refactor/agent-guidance-0.14.0`의 미커밋 문서·설정 변경을 보존하고 Git 상태를 확인한 뒤
최신 사용자 요청만 이어가세요. 완료된 배포나 정리를 반복하지 마세요.
