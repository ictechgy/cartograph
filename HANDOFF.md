# Handoff

_Last updated: 2026-09-17 by Devin_

## Goal

경쟁 강화(warm 질의·dead 경고 3종·온보딩 안내), **0.17.0 릴리스와 Homebrew 배포**,
bridge-facts EventChannel·FFI interop 한계·Expo Modules, README 영·한 퇴고까지
**전부 머지·배포 완료**했다. 새 제품 구현·커밋은 요청되지 않았다.

## Current Status

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
- 워크트리는 `/Users/jinhongan/Desktop/cartograph`(이 브랜치)와
  `/Users/jinhongan/Desktop/cartograph-p1`(main) 두 개.
- 로컬·원격의 낡은 브랜치는 전부 삭제 완료(머지 확인 후 정리).

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

| 검사 | 결과 |
| --- | --- |
| `swift test` (PR #93 헤드) | **1,479 tests** 전부 통과 |
| `Scripts/coverage.sh` | **92.99%** (기준 90%) |
| `Scripts/verify-cli-contract.sh` | 통과 (0/64/2 종료 코드 전 구간) |
| `Scripts/verify-fixtures.sh` | 통과 — 골든 갱신 후 재검증 |
| strict 자기 분석 | dead **0 경고**·cycles·type cycles·rules 모두 findings 없음 |
| CI (PR #93~#100) | Build/test/coverage gate + 자기 분석 전부 SUCCESS |
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

1. `git status --short --branch`, `git worktree list`, `git log --oneline -3 origin/main`으로 확인.
2. 이 브랜치의 guidance 재배치 + HANDOFF 압축을 PR로 올려 머지한다.
3. 새 제품 변경에는 관련 하위 지침과 필수 검사를 적용한다. 배포·태그 생성을 자동 재개하지 않는다.

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph`에서 `HANDOFF.md`와 적용되는 `AGENTS.md`를 읽으세요.
0.17.0 배포·Homebrew 갱신·PR #90~#100 머지와 브랜치 정리는 완료됐습니다. Git 상태를
확인한 뒤 최신 사용자 요청만 이어가세요. 완료된 배포나 정리를 반복하지 마세요.
