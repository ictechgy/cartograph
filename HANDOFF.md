# Handoff

_Last updated: 2026-09-18 by devin_

## Goal

경쟁 강화(warm 질의·dead 경고 3종·온보딩 안내), **0.17.0 릴리스와 Homebrew 배포**,
bridge-facts EventChannel·FFI interop 한계·Expo Modules, README 영·한 퇴고까지
**전부 머지·배포 완료**했다. 0.18.0(Expo Modules + impact 인접 목록)도 릴리스됐다.
이후 경쟁 갭 분석(`docs/evaluation/2026-09-18-competitive-gaps.md`, PR #107에 포함)을
거쳐 사용자가 "순차적으로" 갭을 닫기를 요청했다. 순서: ①웜 query 지연 →
②불필요 ignore 감지 → ③불필요 public 경고 → ④impact --before 제거 간선 →
⑤기계적 fix → ⑥impact 입도 → ⑦테스트 영향 질의 → ⑧공식 GitHub Action →
⑨equatable/hashable 옵션 → ⑩런타임 텔레메트리(연구 전용 보류).

컨테이너 확장 인접-목록 개선은
[PR #104](https://github.com/ictechgy/cartograph/pull/104)로 **스쿼시 머지 완료**했다
(`6bbf766`, 리뷰 head `be7af2a`, CI 녹색). 브리지 `sourceCache` 최적화는 미착수 보류다.

## Current Status

### 완료 — ② 불필요 `cartograph:ignore` 감지

[PR #107](https://github.com/ictechgy/cartograph/pull/107) 스쿼시 머지(`66037f8`, 2026-09-18).
ultra-review 3라운드 반영까지 전 게이트·CI 통과 후 머지. 아래는 구현 기록이다.

- **구현:** `ReachabilityAnalyzer.superfluousIgnores`가 반사실 판정을 한다.
  자기 주석이 있는 `.ignoreComment` 정점(`.ignoreInherited`가 아닌 것)마다
  단위를 세우고, 단위는 `.member` 간선(같은 파일 한정)으로 덮는 무시 자손을
  함께 묶는다 — 조상 주석이 물려준 무시(`.ignoreInherited`)는 자기 단위를
  만들지 않고 덮는 주석의 판정에 접힌다. 그 단위만 뗀 도달성을 다시 돌려
  새 발견이 없으면 `superfluous-ignore` 경고로 보고한다. 파일 범위 단위는
  `.ignoreAllComment` 표식이 있을 때만 만든다 — `SnapshotEnricher`가
  `ignore:all` 파일의 심볼에 `.ignoreComment`와 함께 출처 표식을 단다.
  겹친 단위는 커버리지 중복도로 처리하고, **확정된 단위의 주석은 뒤 판정에서
  뗀 채로 누적한다** — 서로만 참조하는 무시 덩어리에서 앞 주석 하나만 보고해
  "보고된 주석을 모두 떼어도 새 발견이 없다"는 보장이 성립한다.
  `RetentionPolicy`의 `retainedNodesWithoutIgnoreComments`로 같은 규칙의
  보존을 재계산하고, `findsTestOnlyCode`가 켜져 있으면 반사실 세계의
  test-only 보고 변화도, assign-only·미사용 import 발견 변화도 필요 조건으로
  본다. 진단은 `dead` 전용 경고(strict 미포함), 베이스라인 키는
  `usr|ignore`·`ignore:file:<path>`.
- **성능:** 단위별 반사실은 `traverse`의 `alreadyReached` 시드로 무시 영역만
  걷는다. 시드 정점은 큐에 들어가지 않아 역방향 오버라이드 증인이 누락될 수
  있어, 시드의 incoming `.overrides` 간선만 따로 검사한다(회귀 테스트 고정).
- **그 과정에서 찾아 고친 버그:**
  - `CommentCommand.parse`가 부분 문자열 매칭이라 문서 주석이 명령을 *언급*만
    해도 `.ignoreComment`가 붙던 기존 오탐 — 주석 맨 앞 접두사+경계 매칭으로.
  - 영속 IndexStoreDB 캐시가 지워진 유닛을 잊지 않아 파일 발생을 통째로
    삼키던 결함 — 유닛 집합 지문(FNV-1a)을 DB 경로에 섞고, 지문 실패 시
    `-unverified` 전용 경로(버전 없는 낡은 경로 재사용 금지), 열 때 형제 DB를
    정리한다(`prepareReaderDatabase`/`pruneStaleReaderDatabases`,
    `FileSystem.removeItem` 추가로 모든 래퍼 갱신).
- **ultra-review 1라운드 반영:** claude×2·codex 전부 CHANGES_REQUESTED, agy
  6/16샤드(3 APPROVE·3 CR, 나머지 headless 권한 거부 무출력), grok 무효.
  반영: strict-weak-ordering 비교자(`locationThenID` 통일), 크로스파일 멤버
  흡수 차단, `.ignoreAllComment` 출처, testOnly 반사실, -unverified+형제 정리,
  누적 판정(상호 의존), 시드 오버라이드, `#require` 안전 단언.
- **ultra-review 2라운드 반영:** claude-A 10건·claude-B 8건·codex 6건(전부 CR),
  agy·grok 재시도 무효(타임아웃·무출력). 합의 블로커: `-unverified` 재사용
  (실행 간 유령 재현) → 열기 전 삭제로, `baseName-*` 광범위 정리 → 접미가
  `unverified`|16진인 항목만, 빈 `fileIgnored` 가드. 단독 트랙 실결함: 중첩
  주석 독립 단위화, 위치 없는 정점 nil==nil 그룹화 → 단일 단위,
  `FileSystem.removeItem` 필수 메서드 → 기본 구현으로 소스 호환성 유지,
  assign-only·unused-import 반사실 누락 → `honoringIgnoreComments`·
  `exposesIgnoredImport` 추가. 기각: 조건부 증인(기존 처리)·InMemory 모델 일치·
  문서화 한계·스냅샷 캐치 없음.
- **2라운드 반영이 드러낸 근본 문제:** 중첩 단위화가 전파 무시와 자기 주석을
  구별하지 못해 fixture가 깨졌다 — 선언 주석은 `context.isIgnored`로 멤버에
  `.ignoreComment`를 물려주므로, 자기 주석 없는 멤버가 유령 단위를 만들어
  `ping()` 발견과 `IgnoredAndDead` 필요 주석의 불필요 오판을 냈다. 신규
  `.ignoreInherited` 표식으로 전파 무시를 구별해 자기 주석이 있는 정점만
  단위로 세운다 — 부모 주석은 서브트리 전체를 덮는 것이 실제 의미다.
- **ultra-review 3라운드 반영(수정분 대상):** claude·codex 전부 CHANGES_REQUESTED
  (agy·grok은 지속 무효로 미투입 — 커버리지 갭 기록). 합의: 형제 정리 접미가
  임의 길이 16진을 지움(`db-2024` 등) → 지문을 고정폭 16자로 두고 접미도 정확히
  그 형태만; `-unverified` 삭제 실패 삼킴 → 없음 외 실패 시 일회용
  `-unverified-<uuid>` 경로(낡은 DB 재사용 금지). 단독 실결함: 무시 부모 없는
  `.ignoreInherited` 고아가 어느 단위에도 못 들어가 주석이 영구 미판정 → 고아를
  단위 꼭대기로 승격(이전 동작 복원); `exposesIgnoredImport`가 자기 `ignore`
  있는 import까지 풂 → `IndexedImport.isIgnoredOnlyByFileComment` 출처 추가.
  LOW 반영: prune의 동시 실행 경쟁 → `modificationDate` 유예(300초),
  구문 계층 `.ignoreInherited` 핀 테스트, 죽은 부모+자기 주석 멤버·삼단 중첩
  핀 테스트, README에 멤버→부모 보존 규칙 한 문장. 부수 수정: `.ignoreInherited`
  도입 때 누락된 SourceFactsCache schemaVersion 12→13(낡은 캐시의 상속 표식
  없는 facts가 유령 단위를 되살림).
- **검증:** SuperfluousIgnoreTests 28개 + ReaderDatabasePathTests 11개 +
  구문 핀 테스트. 변이 확인: 고아 승격 제거·`isIgnoredOnlyByFileComment`→`isIgnored`·
  지문 길이 제한 제거·unverified 폴백 `try?`·prune 유예 제거 각각 해당 테스트 실패.
  전 게이트 통과(테스트·커버리지 93.05%·fixture·CLI 계약·strict 자기 분석).
- **남은 것:** 없음 — 2026-09-18 머지 완료.

### 완료 — ① 웜 query 지연

[PR #106](https://github.com/ictechgy/cartograph/pull/106) 스쿼시 머지(`72f3be0`).
웜 `query`/`status` ~9ms → ~0.1ms. ultra-review 6라운드로 수렴, serve에
`--session-freshness-interval`(기본 1초, [0, 86400]) 추가.

<details><summary>① 상세(완료 기록)</summary>

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

</details>

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

현재 브랜치(`feat/superfluous-ignore-warning`) 변경의 통과 근거(전부 직접 실행):

| 검사 | 결과 |
| --- | --- |
| `swift test` | 8번들 전부 통과 — SuperfluousIgnore 28·ReaderDatabasePath 11(3라운드 반영 후) |
| `Scripts/coverage.sh` | **93.05%** (기준 90%, 계측 CLI 통합 포함) |
| `Scripts/verify-cli-contract.sh` | 통과 |
| `Scripts/verify-fixtures.sh` | 통과 — 디버그 바이너리 경로 지정, superfluous-ignore 2건 골든 일치(수정 전 유령 발견으로 실패 후 복구) |
| strict 자기 분석 | dead·cycles·type cycles·rules 모두 findings 없음 — 자기 분석이 잔재 `effectiveDatabasePath`를 잡아 삭제 |
| 변이 확인 | 파일단위 휴리스틱·누적 제거·시드 스캔 제거·`honoringIgnoreComments: true`·`exposesIgnoredImport` 제거·고아 승격·import 출처·지문 길이·unverified 폴백·prune 유예 각각 해당 테스트 실패 |

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
- `$TMPDIR/cartograph-index-db`가 6.9GB까지 누적됐다(2026-09-18 정리). 형제 정리는 같은
  baseName만 보니 서로 다른 스토어의 판독기 DB는 영구히 남는다 — 전역 상한이나 오래된
  항목 GC가 없다. 개선 후보.
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

## 경쟁 조사 — codegraph 대비 개선점 (2026-09-18)

조사 대상: [colbymchenry/codegraph](https://github.com/colbymchenry/codegraph) v1.6.0 (스타 71,337, tree-sitter+Rust 커널,
SQLite+FTS5, MCP 단일 툴 `codegraph_explore`, 파일 감시 자동 동기화, `codegraph install`로 9개 에이전트
배선, 텔레메트리 기본 on, 호스팅 유료 플랫폼 예고). 판정: **경쟁이 아니라 보완 관계** — codegraph는
"에이전트가 어디를 읽을까"에, cartograph는 "지워도 되나·무엇이 깨지나"에 답한다. 자매 저장소
(kartograph·dartograph·isthmus)에도 같은 날짜의 동일 섹션이 있고, 아래 "공통" 항목은 네 곳에서 겹친다.
Goal 섹션의 갭 순서(③~⑩)는 그대로 두고, 아래는 그 순서에 끼워 넣을 **후보**다.

### 실측 사실
- `gh api repos/ictechgy/cartograph`: 스타 3 · 포크 1 · 열린 이슈 0. PR 105개 머지, 릴리스 18회,
  테스트 1,505건, 커버리지 93.03%. 엔지니어링 품질과 도달 범위의 격차가 모든 기능 갭보다 크다.
- `Sources/` 전체에 `snippet|verbatim|sourceText` 0건 — `query`는 메타데이터만 반환한다.
- `CartographMCPTools.swift`: MCP 툴 5개(status·query·impact·check·runtime_discover).
- `cartograph skill`은 `.claude/skills/cartograph/SKILL.md` 하나만 쓴다(README:924).
- `docs/evaluation/2026-09-16-harder-comparison.md`의 LSP 대조(H1 브리지 42ms 정확 vs LSP 290ms 실패,
  H2 전이 디스패치에서 LSP `UploadRequest` 누락, H5 지역 함수 LSP `references` 0건)가 README에 없다.
- `docs/evaluation/2026-09-18-competitive-gaps.md`의 "Periphery Pro는 setup polish만, 분석 모델 불변"은
  현재 periphery.pro 광고(`agent-prompt` 출력 형식, 스캔 3× 단축, GitHub Actions 재사용 워크플로,
  VS Code 확장, 인디 무료)와 어긋난다.

### 공통 (네 저장소 동일)
| # | 부족한 점 | 근거 | 제안 | 난이도 |
|---|---|---|---|---|
| C1 | 에이전트 배선이 Claude Code 단일 타깃 | `cartograph skill`·`.claude-plugin/` 전용. codegraph `install`은 9개 에이전트 감지 + MCP 설정 + AGENTS.md 마커 블록. 마커 블록 이유: **서브에이전트·non-MCP 하네스는 MCP 초기화 지시를 못 받는다** | `cartograph install`(다중 에이전트 감지 + AGENTS.md 블록) + `curl \| sh` 설치 스크립트 | 중 |
| C2 | MCP 툴 5개 — 에이전트가 고르고 예산을 계산해야 함 | SKILL.md가 툴 선택과 `symbols × limit ≤ 1000` 예산을 문단째 가르치는 것이 증상. codegraph는 8개 중 `explore` 1개만 노출하고 `_meta.anthropic/alwaysLoad: true`로 Claude Code 툴 지연 로딩을 우회 | 디스패처 `cartograph_explore` 신설(판정+근거+경로+영향), 기존 5개는 env opt-in, `alwaysLoad` 부착 | 중 |
| C3 | 근거를 가리키기만 하고 보여주지 않음 | 소스 원문 반환 0건. codegraph의 "파일 읽기 0회" 주장은 원문을 한 페이로드에 담는 데서 나옴 | `--include-source`(기본 off)로 상위 N 심볼 라인 범위 스니펫. codegraph 스스로 이 방식이 세션 잔류 컨텍스트를 80% 늘린다고 공개 → 기본 off가 맞음 | 중 |
| C4 | 검증된 강점이 README 밖에 묻힘 | 위 LSP 대조표 · 동결 오라클 · 컴파일러 변이 · 바이너리 해시 검증 전부 README 부재. codegraph는 불리한 수치(잔류 컨텍스트 +80%, 대조군 오염 통제)까지 상단 공개 | README 상단에 대조표 1개 + 2026-09-15 파일럿이 **이점을 못 찾은** 과제도 같이 게재. 고칠 것은 문장이 아니라 **순서** | 소 |
| C5 | 채택 퍼널 부재 | 스타 3, 이슈 0, GitHub Action 없음(갭 ⑧). 에러가 이탈을 가르침 — codegraph AGENTS.md "Errors teach abandonment" | Action(⑧) 승격 + "오탐 신고" 이슈 템플릿 + `notFound`류를 오류톤 대신 `suggestions` 동봉 중립 응답으로 | 소 |

### cartograph 고유
| # | 부족한 점 | 근거 | 제안 | 난이도 |
|---|---|---|---|---|
| S1 | 경쟁 갭 문서가 stale — Periphery Pro가 에이전트 레인에 진입 | 위 실측. README "Why another tool" 표는 아카이브 OSS Periphery만 상대 | 갭 문서 갱신 + 비교축을 Pro가 못 따라오는 impact·dataflow·cycles·bridges로 이동 | 소 |
| S2 | Swift MCP 서버 카테고리가 경쟁 인식에서 빠짐 | SwiftLens · swiftadopt-mcp · anvyxhq/swift-mcp-server · XcodeBuildMCP · Apple `xcrun mcpbridge` — 전부 sourcekit-lsp 기반. 갭 문서는 Serena·ios-agent-mcp만 다룸 | (추측) Apple 1st-party 심볼 MCP가 정식화되면 심볼 질의는 범용화 → 방어선은 LSP가 못 답하는 그래프 질문(H2·H5가 이미 증명). 포지셔닝 문구를 그 축으로 | 소 |
| S3 | 인덱스 신선도를 "사람이 빌드하라"는 문단으로 넘김 | SKILL.md가 편집 후 빌드를 **부탁**. `limitations`에 `index-staleness: 3 of 214` 집계는 이미 계산 중 | 질의된 심볼의 **자기 파일**이 stale이면 심볼 단위 플래그(프로젝트 전역 한 줄이 아니라). 워처는 선택적 opt-in | 중(플래그)/대(워처) |
| S4 | README 1,281줄·73KB, 한·영 수동 동기화, 문서 사이트 없음 | PR #98이 통째로 퇴고 작업. 평가자가 30초에 "뭐고 되는가"를 못 읽음 | ~200줄(문제·벤치 표·설치·5줄 퀵스타트·정직성 문단)로 축소, 레퍼런스는 GitHub Pages | 중 |
| S5 | 추론 간선 provenance 축이 명령마다 다른 필드로 흩어짐 | proven/dynamic 채널, `automaticRuntime`/`observedRuntime`, `RetentionReason` 각각. codegraph는 `provenance:'heuristic'`+`synthesizedBy` 단일 축(단, 코드상 synthesizer 4종에만 실제 부착) | 모든 간선·사실에 `provenance: compiler\|syntax\|heuristic\|observed` 단일 축. isthmus 조인이 기계 판독 신뢰도를 얻음 | 중 |
| S6 | 테스트 영향 질의(갭 ⑦) | codegraph `affected` + 복붙 CI 스니펫으로 출시. cartograph는 역방향 도달성과 impact `tests` 필드 보유 | `cartograph affected --since` 승격 + 동일 CI 레시피 | 소~중 |

### 지킬 것 (따라가면 안 되는 것)
1. **기본 on 텔레메트리·호스팅 유료 티어.** "100% 로컬·계정 없음·MIT·유료 티어 없음"은 Periphery Pro
   라이선스 게이트에 맞선 가장 날카로운 차별점이다.
2. **추측으로 산 폭.** codegraph는 이름 일치·관행(`View`/`Manager` 접미사, Cocoa 전치사)으로 해소하고
   태깅한다. cartograph는 컴파일러가 기록한 것만 읽고 `deletable: true`를 영원히 내지 않는다(AGENTS.md).
   provenance 태그 아이디어는 빌리되, 증명 못 한 간선을 합성하려는 의지는 빌리지 않는다.

### 권장 착수 순서
C4(소) → S1·S2(소, 문서) → C1(중) → C2(중) → S3 플래그(중) → C3(중). 기존 갭 ③~⑩과의 병합은 메인테이너 판단.

## Next Steps

1. `git status --short --branch`, `git worktree list`, `git diff`로 미커밋 변경을 확인한다.
2. ②불필요 ignore: PR #107 스쿼시 머지 완료(`66037f8`). 다음 기본 순서는 ③이지만,
   아래 "경쟁 조사 — codegraph 대비 개선점" 섹션의 후보(C1~C5·S1~S6)와 병합 여부는
   메인테이너 판단이다 — 권장 착수 순서는 그 섹션 끝에 있다.
3. 이후 순서: ③불필요 public → ④impact --before 제거 간선 →
   ⑤기계적 fix → ⑥impact 입도 → ⑦테스트 영향 → ⑧GitHub Action → ⑨equatable 옵션.
   ⑩런타임 텔레메트리는 연구 전용 보류.
4. 브리지 `sourceCache` 최적화는 동일 소스 스냅샷 보존 조건에서 검토한다. 근거 없이 제거하지
   않으며, 입증되지 않으면 메모리 계측 결과부터 확보한다.

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph`에서 `HANDOFF.md`와 적용되는 `AGENTS.md`를 읽으세요.
0.18.0 릴리스와 PR #104·#106·#107은 전부 머지·배포됐습니다. 경쟁 갭 목록의
②불필요 ignore 감지는 PR #107 스쿼시 머지(`66037f8`)로 완료됐습니다.
다음은 ③불필요 public 경고입니다 — 아직 브랜치가 없습니다. 단, HANDOFF의
"경쟁 조사 — codegraph 대비 개선점" 섹션에 메인테이너가 정리한 우선 후보
(C1~C5·S1~S6와 권장 착수 순서)가 있으니 ③과의 병합 순서를 먼저 확인하세요.
완료된 배포·검증을 반복하지 마세요. 나머지 갭 순서는 Goal 섹션에 있습니다.
