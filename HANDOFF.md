# Handoff

_Last updated: 2026-09-25 by Claude_

작업 규칙은 [AGENTS.md](AGENTS.md), 이전 원문은 [HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 있다
(0.21.0·0.22.0 발행 세부 기록은 그 파일 끝 절로 옮겼다).
이력의 오래된 버전·승인 대기·미발행 표기는 현재 지시로 되살리지 않는다.

## Goal

시중·경쟁 도구 대비 공백을 채운다. 2026-09-25 조사(아래 "경쟁 조사 요약")에서 뽑은
**A 항목(작고 효과 큰 것) 다섯 개는 전부 리뷰·머지 완료**했다. 남은 것은 B·C 후보와,
A 기능을 사용자에게 내보낼 다음 릴리스(0.23.0)다. 무엇을 할지는 사용자가 고른다.

## Current Status

- 저장소 `/Users/jinhongan/Desktop/cartograph`, `main`은 `c52d418`(#145), 로컬 브랜치는 `main` 하나.
- 발행본은 0.22.0이다. 아래 A 기능은 **`main`에만 있고 발행되지 않았다**(CHANGELOG `[Unreleased]`에 4건).

| 발행물 | 현재 버전·상태 |
|---|---|
| CLI / Homebrew | [0.22.0](https://github.com/ictechgy/cartograph/releases/tag/0.22.0), 호스트 설치·`brew test`·바이트 일치 검증 완료 |
| GitHub Action | [action-v1.0.0](https://github.com/marketplace/actions/cartograph-swift-analysis?version=action-v1.0.0) |
| GitLab component | [cartograph-ci 1.0.0](https://gitlab.com/explore/catalog/ictechgy/cartograph-ci), 검증된 CLI 0.20.0 고정 유지 |

## Completed (2026-09-24 ~ 25)

- **0.22.0 발행**: `cartograph schema`(Swift persistence `relation-use` 생산자, #136) 포함. 릴리스 PR #138,
  태그 `df577ad`, Release 성공, 공개 archive SHA256 `442a1940…08414` 독립 검증, Homebrew tap PR #51(`6413c01`),
  호스트 0.21.0→0.22.0 upgrade. 발행 기록 PR #139.
- **정리**: 머지된 로컬 브랜치 13개 삭제(원격 유지)와 재생성 가능한 산출물 약 680 MiB 삭제(#137).
  HANDOFF에 "dartograph 생산자 등은 cartograph 작업이 아님"을 명시(#140).
- **경쟁 조사 A 항목 5건 — 전부 GLM 리뷰(`packet-ask review --effort high`) 반영 후 머지**:

| PR | 내용 | 리뷰 처리 |
|---|---|---|
| #141 | README Known limitations의 낡은 assign-only 설명 정정 | 문서 |
| #143 | MCP `cartograph_affected` 도구(`AnalysisSession.affected`, symbols\|files·depth·limit) | 결함 없음 |
| #144 | 레이어 규칙 `rationale`·`hint` → 위반 `details`·`rules --explain` | 정규화를 공개 init으로 이동 |
| #142 | `affected --format xcodebuild` → `-only-testing:` 인자 | `@objc` 개명 클래스·빈 모듈 거부, 문서 정정 |
| #145 | `thresholds.max_efferent_coupling`(Ce 상한, `efferent-coupling` 경고) | 음수 거부, 공허한 테스트 수정, `check` 범위 명시 |

  각 PR은 로컬에서 `coverage.sh`(92.33–92.39%), `verify-cli-contract`, `verify-fixtures`, strict 자기 분석을
  통과했고, 새 테스트는 구현을 일부러 되돌려 실패하는 것을 확인했다. 리뷰 판단은 PR 코멘트에 남겼다.

## What Worked

- **실제 도구로 실측하고 판단한다.** `affected --format xcodebuild`는 스크래치 SwiftPM 패키지
  (XCTest 클래스·하위 클래스·`@objc` 개명·Swift Testing 혼합)에서 실제 `xcodebuild test`로 검증했다.
  Xcode 27.0 실측: 없는 **클래스**는 0개 실행 후 성공(조용한 누락), 없는 **타깃**은 exit 70 오류,
  상위 클래스 식별자는 하위 클래스의 상속 테스트를 건너뜀. 이 사실들이 설계(증명된 식별자만 좁힘)를 정했다.
- **GLM 리뷰 절차**: PR마다 스크래치 git 저장소에 `pr.diff`와 변경 파일 전체를 복사하고 질문을 파일로 둔 뒤
  `packet-ask review --provider glm --effort high --files … --question-stdin`. 네 개를 병렬로 돌리면 5–12분.
  지적은 코드·실측으로 확인해 반영/거절하고 PR 코멘트에 이유를 남긴다.
- **돌연변이 확인**: 새 테스트마다 구현을 잠시 되돌려 실패를 본 뒤 복원했다.
- **CHANGELOG `[Unreleased]` 충돌**: 여러 PR을 차례로 머지하면 매번 충돌한다. rebase하며 양쪽 항목을 모두
  살리고(`<<<<<<<` 블록을 이어 붙임), 관련 테스트를 돌린 뒤 `--force-with-lease`로 푸시, CI 통과 후 머지.

## What Didn't Work / Pitfalls

- **돌연변이 테스트 뒤 재빌드를 잊으면 `.build/debug/cartograph`가 망가진 코드로 남는다.**
  `swift test`가 실행 파일도 다시 빌드하기 때문이다. 실제로 "하위 클래스 검사가 안 먹는다"는 가짜 결함을 봤다.
  소스를 복원한 뒤 반드시 `swift build`를 다시 돌린다.
- `packet-ask`의 `--line-numbers`는 줄 번호 거터가 전화번호 탐지에 걸려 전송이 거부됐다(exit 12). 빼고 보낸다.
- 조사 에이전트의 주장도 틀릴 수 있다: "metrics 임계값 게이트 없음"(실제로 `max_instability`·`max_distance`
  존재), "IB per-member 지원"(실제로 `dead`는 `retain_interface_builder`로 일괄 보존). 코드로 확인한다.
- 이 저장소의 `.cartograph.yml`은 테스트 경로를 제외하므로 `affected`를 여기서 돌리면 빈 결과다.
  테스트 영향 기능은 스크래치 패키지로 확인한다.
- rebase 도중 `git push`는 이전 브랜치 참조를 민다(효과 없음). 충돌을 끝까지 해결한 뒤 민다.

## Important Context / Avoid

- **`check`는 dead·모듈/타입 cycles·rules만 묶는다. 지표 임계값(`max_instability`·`max_distance`·
  `max_efferent_coupling`)은 `metrics --strict`에서만 게이트가 된다.** README에 명시했다.
- `affected --format xcodebuild`: 모듈 이름을 xcodebuild 타깃 이름으로 쓴다(SwiftPM과 식별자형 Xcode 타깃은 일치).
  잘림·미해결이면 인자 없이 exit 2(이름을 못 찾으면 64). 표준 오류 `note:`는 `CommandOutcome.notes`로 나간다.
- 레이어 규칙 `rationale`·`hint`는 `text`·`json`과 `--explain`에만 나오고, 한 줄 메시지 형식(xcode·
  github-actions·checkstyle·sarif)에는 없다. 베이스라인 지문에는 들어가지 않는다.
- AGENTS.md "삭제 판정을 내지 마세요" 때문에 Periphery Pro식 미사용 코드 삭제 지침은 만들지 않는다.
- 완료된 발행·설치·태그를 반복하거나 옮기지 않는다. Release의 tap 단계는 `HOMEBREW_TAP_TOKEN` 미설정이라
  매번 건너뛴다 — tap PR을 따로 내고 upgrade·`brew test`·바이트 일치를 확인한다.
- schema 스캐너 규약(`escapeQualified`/`escapeName`, `SchemaDeclCollector`→`SchemaFactCollector` 단방향)은 유지한다.

## 경쟁 조사 요약 (2026-09-25)

- 시장 변화: **Periphery OSS가 2026-08-12 보관(archived)**, 개발은 유료 Periphery Pro로 이동.
  Tuist `inspect dependencies`(2025-12)는 import 텍스트 기반이라 조건부 import를 놓친다.
  Tuist 선택적 테스트는 Tuist 생성 프로젝트 전용 — `affected`는 일반 Xcode/SwiftPM에서 동작한다(문서화 후보).
- **B 후보(중간 규모·차별화)**
  1. 매니페스트 수준 암묵·중복 의존성 검사: Package.swift/xcodeproj 선언 의존 vs 인덱스의 실제 모듈 참조.
     인덱스 기반이라 Tuist보다 정확할 수 있다. **가장 큰 기회로 평가.**
  2. 연결 안 된 `@IBOutlet`/`@IBAction` 개별 보고: `runtime discover`는 이미 멤버 단위로 연결을 푼다
     (`RuntimeDiscoveryResolver`), `dead`만 `RetentionPolicy.swift`에서 일괄 보존한다. 보존을 좁히는 일이라
     CONTRIBUTING "Narrowing one"(반대 방향 코퍼스 + 실제 프로젝트 3곳 델타)을 통과해야 한다.
  3. Redundant protocol conformance(Periphery OSS 기능, cartograph에 없음).
  4. Xcode 27 에이전트 플러그인(skills + MCP) 패키징. 5. 삭제 가능 LOC 요약.
- **C 후보(크거나 연구)**: 편집 뒤 인덱스 낡음(watch/백그라운드 인덱싱 — 에이전트 사용성 최대 약점),
  빌드 없는 구문 전용 모드(원칙 충돌 주의), xccov 커버리지 보조 근거, Bazel, VS Code 진단, Reaper 연동.
- MCP에 넣지 않은 것: `since`(서버가 git 실행 필요), `dataflow`(세션 캐시 밖·출력이 커서 4 MiB 한도 설계 필요).
- 범위 밖: 편집/빌드/시뮬레이터, 번들 크기, 빌드 시간, 보안 SAST, 호스팅 대시보드, 자연어·임베딩.

## Next Steps

사용자가 고르기 전에는 착수하지 않는다. 후보:

1. **0.23.0 릴리스**: `[Unreleased]` 4건 발행. 0.22.0 절차(#138·#139·tap #51)를 그대로 따른다 —
   버전 상수·README 예제·CHANGELOG 확정 → PR CI → 머지 → 태그 → Release → archive 독립 검증 → tap PR →
   호스트 upgrade·`brew test`.
2. **자매 저장소 알림**: #143이 스킬 문장(MCP 도구 목록에 `cartograph_affected`)을 바꿨다. AGENTS.md 규칙상
   kartograph·dartograph에 알려야 하는데 아직 하지 않았다.
3. **B 후보 착수**(위 목록). 1번(매니페스트 의존성 검사)이 추천이다.

isthmus 생태계 후보(dartograph persistence 생산자, 도메인 간 상관, 네트워크 도메인)는 cartograph 작업이
아니다 — 구현은 dartograph·isthmus 저장소에서 한다. 정본은
[isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md).

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph`에서 HANDOFF.md와 적용 AGENTS.md를 읽고 Git 상태를 확인해줘.
경쟁 조사 A 항목 5건(#141–#145)은 리뷰·머지까지 끝났고 아직 발행 전이야(`[Unreleased]`).
다음 후보는 0.23.0 릴리스, 자매 저장소에 스킬 문장 변경 알림, B 후보(매니페스트 의존성 검사 추천)야.
내가 고르기 전에는 착수하지 말고, 0.21.0·0.22.0 발행과 A 항목 작업을 반복하지 말 것.
