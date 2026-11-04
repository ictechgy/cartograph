# Handoff

_Last updated: 2026-11-04 by Claude_

작업 규칙은 [AGENTS.md](AGENTS.md), 이전 원문은 [HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 있다
(2026-09-25 기록은 그 파일 끝 절로 옮겼다). 이력의 오래된 버전·Next Steps는 현재 지시로 되살리지 않는다.

## Current Status

- 최신 발행은 **0.30.0**(2026-11-03, CHANGELOG)이다. 0.23.0~0.30.0의 내용은 CHANGELOG의 해당 절이 정본이다.
- 브랜치 `ccr-37904670-hxdjsx`에 계열 9개 저장소 점검(2026-11-03)에서 나온 수정이 있다. CHANGELOG
  `[Unreleased]`에 정리했고 아직 발행하지 않았다. 핵심은 다음과 같다.
  - Git이 무시했지만 컴파일된 소스가 쓰는 선언을 보존한다(`ignoredSourceReference`).
  - 합성 Codable/Equatable/Hashable 준수를 인덱스와 프로젝트 프로토콜로 전이해 판정한다(`codableEnumCase` 포함).
  - `#if`가 있는 파일의 `unused-import`를 보고하지 않는다.
  - 레이어 경로 판정을 프로젝트 상대 경로로 바꿨다. 업그레이드 노트가 필요한 동작 변경이다.
  - Git 선택이 폴백하면 `source-discovery-git-unavailable` 한계를 싣는다.
  - target scope 인벤토리가 `.build-*` 스크래치를 건너뛴다.
  - 스킬에 `cartograph_prepare`를 추가했고, 플러그인 매니페스트 버전 대조를 CI·릴리스에 넣었다.
  - isthmus `c76e105` 적합성 벡터를 다시 벤더링했고 `sql-relations` 벡터 테스트를 추가했다.
- **이 수정을 작성한 세션에는 Swift 툴체인이 없었다**(Linux 컨테이너, Core의 `import Darwin`). 컴파일·테스트·
  `coverage.sh`·`verify-fixtures.sh`·자기 분석 근거는 PR의 macOS CI뿐이다. CI가 실패하면 로컬 macOS에서 재현한다.

| 발행물 | 상태 |
|---|---|
| CLI / GitHub Release | 0.30.0 |
| Homebrew | 릴리스 workflow의 tap 단계는 `HOMEBREW_TAP_TOKEN` 미설정으로 건너뛴다. 발행마다 tap PR과 `brew test`를 따로 확인한다 |
| GitHub Action | `action-v1.0.0` |

## 남은 후보 (사용자가 고른 뒤 착수)

2026-09-25 경쟁 조사의 B·C 후보는 0.23.0~0.30.0 사이에 일부만 다뤄졌다.

- **미구현**
  - B1 매니페스트 수준의 암묵·중복 의존성 검사(Package.swift/xcodeproj 선언과 인덱스 모듈 참조를 대조).
    kartograph의 `dependencies --resolved-dependencies`가 참고 구현이다.
  - B2 연결 안 된 `@IBOutlet`/`@IBAction` 개별 보고. 보존을 좁히는 변경이라 CONTRIBUTING의 "Narrowing one"
    (반대 방향 코퍼스 + 실제 프로젝트 3곳 델타)을 통과해야 한다.
  - B3 redundant protocol conformance.
- **부분 구현**
  - B4 에이전트 플러그인: `.claude-plugin`이 스킬만 담고 MCP 선언은 없다.
  - B5 삭제 가능 LOC 요약: `--file-summary`가 개수만 센다.
  - C 편집 뒤 인덱스 낡음: `cartograph_prepare`와 `index-staleness` 한계까지만 있다.
- **계열 결정(2026-11-04)**: gartograph·rustograph의 `query` 응답 스키마는 맞추지 않고 각자 고유의 공개 계약으로
  둔다. 공유하는 것은 출력 철학뿐이다. AGENTS.md 규칙을 이 현실에 맞게 고쳤다.

## Important Context / Avoid

- `check`는 dead·모듈/타입 cycles·rules만 묶는다. 지표 임계값은 `metrics --strict`에서만 게이트가 된다.
- AGENTS.md "삭제 판정을 내지 마세요" 때문에 삭제 지침형 기능은 만들지 않는다.
- 레이어 규칙 `rationale`·`hint`는 `text`·`json`과 `--explain`에만 나오고, 베이스라인 지문에는 들어가지 않는다.
- 돌연변이 테스트 뒤에는 `swift build`를 다시 돌린다. `swift test`가 실행 파일도 다시 빌드한다.
- 조사 에이전트의 "기능 없음" 주장은 grep과 코드로 확인한 뒤 반영한다(전례 있음).
- 적합성 벡터를 바꾸면 `conformance/conformance.lock`의 해시와 isthmus 커밋을 함께 갱신한다.
  isthmus `scripts/conformance-drift.mjs cartograph=<checkout>`으로 대조한다.

## Resume Prompt

저장소 루트에서 HANDOFF.md와 적용 AGENTS.md를 읽고 Git 상태를 확인해줘. `[Unreleased]`의 수정이 PR로
리뷰·머지됐는지, macOS CI(coverage·fixtures·자기 분석)가 통과했는지 먼저 확인하고, 남은 후보는 내가 고른 뒤 착수해.
발행·태그는 따로 지시가 있을 때만 해.
