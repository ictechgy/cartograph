# Handoff

_Last updated: 2026-09-18 by devin_

## Goal

경쟁 강화(warm 질의·dead 경고 3종·온보딩 안내), **0.17.0 릴리스와 Homebrew 배포**,
bridge-facts EventChannel·FFI interop 한계·Expo Modules, README 영·한 퇴고까지
**전부 머지·배포 완료**했다. 0.18.0(Expo Modules + impact 인접 목록)도 릴리스됐다.
이후 경쟁 갭 분석(`docs/evaluation/2026-09-18-competitive-gaps.md`, **미커밋**)을
거쳐 사용자가 "순차적으로" 갭을 닫기를 요청했다. 순서: ①웜 query 지연 →
②불필요 ignore 감지 → ③불필요 public 경고 → ④impact --before 제거 간선 →
⑤기계적 fix → ⑥impact 입도 → ⑦테스트 영향 질의 → ⑧공식 GitHub Action →
⑨equatable/hashable 옵션 → ⑩런타임 텔레메트리(연구 전용 보류).

컨테이너 확장 인접-목록 개선은
[PR #104](https://github.com/ictechgy/cartograph/pull/104)로 **스쿼시 머지 완료**했다
(`6bbf766`, 리뷰 head `be7af2a`, CI 녹색). 브리지 `sourceCache` 최적화는 미착수 보류다.

## Current Status

### 진행 중 — ① 웜 query 지연 (브랜치 `perf/session-freshness-window`)

- **병목 규명:** `describeQuery`는 이미 완전히 bounded(explain + `GraphNeighborhood`
  BFS 2개 + containment 2개 + 증거 예산 200)이고, `QuerySession`은 세션당 한 번 만들어
  캐시된다. 웜 호출의 실질 비용은 `ensurePrepared`의 **매 요청 입력 지문 재계산** —
  이 저장소에서 ~9ms(status≈query로 분리 측정), 소스+인덱스 파일 전부 stat.
- **구현:** `AnalysisSession`에 `freshnessCheckInterval`(기본 `.zero` = 기존 동작인
  요청마다 검증)과 주입 가능한 `now` 시각 소스를 추가하고, 창 안의 연속 요청은
  마지막 검증 세대를 그대로 쓴다. `serve`는 `--session-freshness-interval`로
  창을 받는다(기본 1초, `[0, 86400]` 밖은 거부 — inf/nan 포함). 성공한 reload도
  검증 시각으로 간주해 관측 시작 시각을 찍는다. `cartograph_status`의
  `refresh: true`는 `session.refresh()`로 창을 우회한다. `runtimeContext`의
  Core Data 증거 검증은 명시적이므로 창과 무관하게 매번 수행.
- **계측**(release, 이 저장소): 창 안 웜 status/query **~0.0-0.1ms**(이전 ~9ms),
  창 경과 후 첫 호출 ~9-11ms(재검증 정상), 첫 요청 ~0.7-1.9s(세션 준비, 무관).
- **계약 검사:** `verify-mcp.py`는 기본 창 경로를 측정 구간이 창 안인 시도만
  단언하며 최대 세 번 재시도하고, 창 메커니즘은 `--session-freshness-interval 300`
  별도 서버에서 재사용·우회·편집 감지를 스케줄러 지연과 무관하게 단언한다.
- **테스트 8개(주입 시계로 수면 없이 결정적):** 창 안 미재독+이전 세대 사용,
  창 경과 후 재검증, 명시 refresh 우회+창 재시작, `.zero`·음수 기본값, 변경 없는
  재검증의 창 재시작, refresh 실패 폐기, 창 만료 후 지문 실패 폐기·복구.
- **남은 것:** 커밋·푸시·PR·리뷰(머지 승인 전까지 머지하지 않음), HANDOFF의
  Verification 표는 이 변경 기준으로 갱신함.

### 완료된 개선 — 2026-09-18

- [PR #104](https://github.com/ictechgy/cartograph/pull/104) 스쿼시 머지(`6bbf766`,
  2026-09-18). ultra-review 3라운드 — 라운드 1에서 상대 타이밍 상한·진짜 순환
  픽스처·생성기 확장·계약 고정 테스트를 반영했고, 라운드 2·3은 블로커 0건으로
  수렴했다(사용 가능 트랙: Claude·Codex·Antigravity; Grok은 출력 계약 무효로 제외).
  agy 단독 HIGH("방문 집합 재사용이 비컨테이너 시드 자식을 생략")는 기준 구현과
  동일한 상속 계약이라 기각하고 테스트로 고정했다. CI에서만 드러난 `Expander`
  memberwise init 접근 수준 오류는 명시 init으로 고쳤다(`be7af2a`).
  변경 파일: `Sources/CartographKit/ImpactService.swift`(위임으로 축소), 신규
  `Sources/CartographAnalysis/ImpactSelectionExpansion.swift`·
  `Tests/CartographAnalysisTests/ImpactSelectionExpansionTests.swift`,
  `CHANGELOG.md`(`Unreleased`의 Changed에 impact 확장 개선 항목).
- **초안의 동등성 갭을 찾아 고쳤다.** 초안은 도달한 정점이 컨테이너(타입·익스텐션)일
  때만 이웃을 수집해, 도달된 메서드 아래 지역 선언(인덱스는 parentUSR로 남기고
  `LocalFunctionBinder`도 `?? owner.usr`로 단다)과 그 하위 트리를 빠뜨렸다.
  최종 구현은 도달한 **모든** 정점의 자식 집합을 방문 시점에 인접 목록으로
  계산한다(pull 모델): 어휘 멤버 + `semanticParent`가 그 정점인 멤버 + 그 정점을
  확장하는 익스텐션. 다중 member 부모·다중 extends 같은 비정상 그래프까지
  원 구현의 `children[X]` 집합과 정확히 같다.
- **Codex 독립 리뷰 1건 확정·수정.** 익스텐션 하나가 도달된 타입 여럿을 확장하면
  멤버 목록을 타입마다 다시 훑어 `semanticParent` 조회까지 곱해지는 최악
  (병적 그래프에서 원 구현보다 나쁨). `Expander`가 익스텐션 멤버를 의미 부모별로
  한 번만 그룹핑해 캐시하게 고쳤다. LOW 2건도 반영: 순환 테스트를 진짜 순환
  (익스텐션 둘의 상호 extends)으로 교체, "익스텐션 시드는 확장 대상 타입을
  포함하지 않는다" 계약을 문서·테스트로 고정. 30ms 상한의 한계(간선 방문 횟수가
  아닌 타이밍 단언)는 인정하나 저장소 관례와 CodeGraph API 범위 안에서는 유지.
- **계측**(디버그, 44k 정점/140k 간선): 좁은 선택 58.3ms → 0.15ms(~400×),
  넓은 선택(22k 정점 도달) 78.9ms → 38.1ms(~2×). 두 결과 집합은 동일했다.
- 테스트 9개: 지역 선언 하위 트리, 익스텐션·의미 부모, 익스텐션 시드 계약,
  진짜 순환 종료, 비컨테이너 시드, 기준 구현 대조, **시드 고정 무작위
  프로퍼티**(40 그래프×12 시드 — 초안에서는 114건 불일치로 실패 확인),
  좁은 선택 상한 30ms(기준 구현은 ~58ms라 분리됨; 노이즈 간선은 도달 범위 밖
  정점끼리 둬야 상한이 의미 있다).
- 실 저장소 스모크: `cartograph impact CodeGraph` → changeScope 39 · affected 260
  (신규 파일이 인덱스에 들어와 +2; 리뷰 수정 후 재실행도 동일).
- 브리지 원문 캐시(`CartographService.swift`의 `sourceCache`)는 **변경하지 않았다**.
  재읽기로 메모리를 줄이면 2패스가 서로 다른 소스 상태를 볼 수 있다. 일관성을 유지하는
  작은 개선이 입증되지 않으면 보류하고 메모리 계측 결과부터 확보한다.
- 보안: Codex 읽기 전용 정적 검토에서 MCP·런타임 경계의 확정 취약점 없음.
  전체 저장소/의존성 감사나 동적 보안 검증은 아니며 보안 수정은 없다.
- 리뷰 오탐: `GraphQueryIndex.similarCandidates`가 동명 정점 전부를 추천한다는 제안은 기각.
  실제 70행은 이름별 `.first`를 이미 고른다. 이 제안을 근거로 수정하지 말 것.

### 이미 완료된 릴리스 이력

- 지침 재배치·HANDOFF 압축 [PR #101](https://github.com/ictechgy/cartograph/pull/101) 머지(`b468541`).
  루트 `AGENTS.md`는 색인, 구현 주의점은 `Sources/AGENTS.md`, 인덱스 규칙은
  `Sources/CartographIndexStore/AGENTS.md`(신규, 타깃 exclude 등록)에 있다.
- 워크트리는 `/Users/jinhongan/Desktop/cartograph` 하나(main). `cartograph-p1` 제거,
  로컬·원격 낡은 브랜치 전부 삭제, 바탕화면의 날짜별 산출물 디렉터리(~6.4GB) 정리 완료.
- [0.17.0 릴리스](https://github.com/ictechgy/cartograph/releases/tag/0.17.0) 공개.
  버전 범프 [PR #95](https://github.com/ictechgy/cartograph/pull/95)(`5582341`), 태그 `0.17.0`,
  릴리스 워크플로 `35169960516` 성공. Homebrew는 `HOMEBREW_TAP_TOKEN` 부재로 워크플로가
  건너뛰어 [tap PR #46](https://github.com/ictechgy/homebrew-tap/pull/46)을 수동으로 냈고 머지됐다.
  `brew upgrade` 0.16.0→0.17.0, `brew test` 통과.
- 0.17.0에 포함된 작업: warm 질의 69→12ms, `impact --before`의 `scopeDiff`, 브리지 스캐너
  상수 해석·init 주입·한 홉 위임, 자기 경고 181→0, 세션 캐시 정확성 수정(버려진 링크
  재지정·열거 실패 감지). [PR #93](https://github.com/ictechgy/cartograph/pull/93) 스쿼시 머지.
- Expo Modules 지원 [PR #97](https://github.com/ictechgy/cartograph/pull/97)(`513cbef`),
  README 영·한 퇴고 [PR #98](https://github.com/ictechgy/cartograph/pull/98)(`8a09625`) 머지.

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
- **0.17.0 (PR #93~#100)**: Codex 독립 리뷰로 확정된 결함 9건 수정 후 머지 — `constantString`
  `+` 연결 지수 폭발(메모·4096자 상한), 지역 `channel` 파라미터가 `injectedChannel`로 새던
  문제, `Type.init`/무 레이블 생성자 호출 미기록, 비-self 대입 무효화 누락, 위임 인자 위치
  대조, 버려진 심볼릭 링크 스탬프, 실패 열거 미캐시, `inclusions` 상한, scopeDiff 인접 수집.
  CI 전용 `verify-analysis-blindspots.py`의 concat 기대치는 의도된 개선이라 갱신(`556c5b3`).

## Key Files & State

| 경로 | 읽는 이유 |
| --- | --- |
| [AGENTS.md](AGENTS.md), [Sources/AGENTS.md](Sources/AGENTS.md) | 필수 검사, 공통 계약과 모듈 경계; 하위 지침 색인 |
| [Sources/CartographIndexStore/AGENTS.md](Sources/CartographIndexStore/AGENTS.md) | `receivedBy`를 호출자로 읽지 않는 규칙, 제한적 소유자 귀속 |
| [Sources/CartographSyntax/BridgeFactScanner.swift](Sources/CartographSyntax/BridgeFactScanner.swift) | 채널 종류 증명(`provenChannelKind`), 상수 해석·init 주입·한 홉 위임 2패스 |
| [Sources/CartographKit/BridgeFacts.swift](Sources/CartographKit/BridgeFacts.swift) | v2 문서·전송별 limitation 집계 |
| [Sources/CartographKit/CartographService.swift](Sources/CartographKit/CartographService.swift) | `bridgeFacts` 공개 경계 검증, `isScopedDocument`(기본 문서 표식) |
| [Sources/CartographKit/AnalysisSession.swift](Sources/CartographKit/AnalysisSession.swift) | 세션 캐시 — walk 레코드, 링크·디렉터리 스탬프, 입력 지문 재사용 |
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
- **확정:** 브리지 채널 추론은 보수적이다 — 지역 바인딩이 있으면 init 주입을 보지 않고,
  위임은 인자 위치·레이블이 같은 한 홉만 인정한다. Expo 모듈의 컴포넌트 채널은 뷰 클래스가
  아니라 모듈 이름이다(`requireNativeViewManager` 계약).
- **미입증:** 한정 코퍼스·커버리지 수치는 전체 정확도나 에이전트 생산성의 증거가 아니다.
- **가정/후보:** `ImportScanner`의 `importKind`→`importKindSpecifier` 이전은 swift-syntax 하한을
  603+로 올릴 때.

## Verification

현재 브랜치(`perf/session-freshness-window`) 변경의 통과 근거(전부 직접 실행):

| 검사 | 결과 |
| --- | --- |
| `swift test`(coverage.sh 내 번들) | 전부 통과 — 세션 테스트 37개(창 테스트 8개, 주입 시계로 수면 없음) |
| `Scripts/coverage.sh` | **93.04%** (기준 90%, 계측 CLI 통합·MCP 검사 포함 전부 통과) |
| `Scripts/verify-cli-contract.sh` | 통과 |
| `Scripts/verify-fixtures.sh` | 통과 — **반드시 디버그 바이너리 경로를 첫 인자로** 넘길 것 |
| strict 자기 분석 | dead·cycles·type cycles·rules 모두 findings 없음 |
| 변이 확인 | `ensurePrepared`의 창 조기 반환을 끄면 새 테스트가 2개 단언 모두 실패함을 확인 |
| 성능 계측 | 창 안 웜 status/query ~0.0-0.1ms(이전 ~9ms, release·MCP stdio); 창 경과 후 재검증 ~9-11ms 정상 |

아래 표는 **PR #104의 근거**다.

| 검사 | 결과 |
| --- | --- |
| `swift test`(coverage.sh 내 8번들) | **1,505 tests** 전부 통과, 이슈 0(리뷰 수정 후 재실행도 통과) |
| `Scripts/coverage.sh` | **93.03%** (기준 90%, 리뷰 수정 후 재측정) |
| `Scripts/verify-cli-contract.sh` | 통과 |
| `Scripts/verify-fixtures.sh` | 통과 — 디버그 바이너리 경로 지정 |
| strict 자기 분석 | dead·cycles·type cycles·rules 모두 findings 없음 |
| 동등성 | 무작위 프로퍼티 480 비교·고정 케이스가 기준 구현과 일치; 초안은 114건 불일치로 실패 확인(테스트가 실제로 뭄); Codex 측 독립 모델 25,216 비교도 불일치 없음 |
| 성능 계측 | 좁은 선택 58.3→0.15ms, 넓은 선택 78.9→38.1ms(디버그, 44k/140k) |

아래 표는 **이전 릴리스의 근거**다.

| 검사 | 결과 |
| --- | --- |
| `swift test` (PR #93 헤드) | **1,479 tests** 전부 통과 |
| `Scripts/coverage.sh` | **92.99%** (기준 90%) |
| `Scripts/verify-cli-contract.sh` | 통과 (0/64/2 종료 코드 전 구간) |
| `Scripts/verify-fixtures.sh` | 통과 — 골든 갱신 후 재검증 |
| strict 자기 분석 | dead **0 경고**·cycles·type cycles·rules 모두 findings 없음 |
| CI (PR #93~#101) | Build/test/coverage gate + 자기 분석 전부 SUCCESS |
| Release `35169960516` | 성공; 공개 asset 해시·universal·버전 직접 검증 |
| Homebrew | formula 0.17.0 + 검증된 sha256(`ff1bbbc6…7087cb`); `brew upgrade`·`brew test` 통과 |
| 변이 확인 | 새 테스트 9종이 수정 전 코드에서 실패함을 확인 |

## Blockers & Open Questions

- `HOMEBREW_TAP_TOKEN`이 없어 탭 갱신은 계속 수동 PR. 자동화하려면 저장소 시크릿 추가 필요.
- 리뷰 인프라: Grok은 quota-exhausted로 두 번 연속 사용 불가. agy는 headless에서 도구 호출이
  자동 거부돼 프롬프트에 "도구 사용 금지" 문구가 필요하고, 가끔 그래도 무출력.
- `run-external`은 세션 디렉터리가 `mktemp -d` 수준(700)의 사설 디렉터리여야 하고, 재시도 전에
  stale `attempts/w001-<출력명>-` 디렉터리를 지워야 한다.
- 실기기·임의 DI/heap/반사의 완전성과 Core Data dynamic-framework-only 정의는 미지원/미검증.
- 브리지 스캐너의 남은 공백: 파일 스코프 `let`을 `var` 프로퍼티 외 경로(비-init 대입)로
  채우는 형태, Objective-C 전용 플러그인 핸들러.

## What Worked / Avoid

- 규칙마다 "그 규칙이 없으면 실패하는" 테스트 + 변이로 실제 무는지 확인.
- 리뷰 발견은 전부 코드·계약 문서와 대조해 검증 — 합의 ≠ 정답(agy의 `isScopedDocument` 오독,
  Claude의 `--retain-public`→`retain_public` 제안도 실제 플래그라 기각), 단독 트랙이라도
  실증된 정확성 버그(순환 폐포)는 고친다.
- `git checkout`으로 변이를 되돌리면 미커밋 수정까지 날아간다 — `git stash`/수동 복원 사용.
- CI `success`만으로 탭 갱신·머지 상태를 주장하지 않는다 — formula 내용과 PR 메타데이터를 본다.
- 커밋 메시지 히어독에 백틱이 있으면 셸이 먹는다 — 메시지를 파일로 쓰거나 이스케이프한다.
- CI에는 로컬 필수 게이트에 없는 검증 스크립트가 있다(`verify-analysis-blindspots.py` 등).
  CI 실패 시 로컬에서 같은 스크립트를 직접 돌려 재현한다.

## Next Steps

1. `git status --short --branch`, `git worktree list`, `git diff`로 미커밋 변경을 확인한다.
   (이 문서 갱신과 `docs/evaluation/2026-09-18-competitive-gaps.md`는 미커밋 —
   커밋은 요청 시에만.)
2. ①웜 query: `perf/session-freshness-window`를 커밋·푸시·PR로 만들고 리뷰한다.
   머지는 사용자 승인 후.
3. 이후 순서: ②불필요 ignore 감지 → ③불필요 public → ④impact --before 제거 간선 →
   ⑤기계적 fix → ⑥impact 입도 → ⑦테스트 영향 → ⑧GitHub Action → ⑨equatable 옵션.
   ⑩런타임 텔레메트리는 연구 전용 보류.
4. 브리지 `sourceCache` 최적화는 동일 소스 스냅샷 보존 조건에서 검토한다. 근거 없이 제거하지
   않으며, 입증되지 않으면 메모리 계측 결과부터 확보한다.

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph`에서 `HANDOFF.md`와 적용되는 `AGENTS.md`를 읽으세요.
0.18.0 릴리스와 PR #104는 전부 머지·배포됐습니다. 진행 중인 것은 경쟁 갭 목록의
①웜 query 지연 — `perf/session-freshness-window` 브랜치에 구현·검증이 끝났고
커밋·PR·리뷰가 남았습니다(머지는 승인 후). 완료된 배포·검증을 반복하지 마세요.
나머지 갭 순서는 Goal 섹션에 있습니다.
