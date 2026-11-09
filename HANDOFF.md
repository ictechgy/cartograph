# Handoff

_Last updated: 2026-11-09 by Claude (PR #237 최종 상태)_

작업 규칙은 [AGENTS.md](AGENTS.md), 이전 원문은 [HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 있다
(2026-09-25 기록은 그 파일 끝 절로 옮겼다). 이력의 오래된 버전·Next Steps는 현재 지시로 되살리지 않는다.

## Current Status

- 최신 발행은 **0.30.0**(2026-11-03, CHANGELOG)이다. 0.23.0~0.30.0의 내용은 CHANGELOG의 해당 절이 정본이다.
- 계열 9개 저장소 점검(2026-11-03)에서 나온 수정은 브랜치 `ccr-37904670-hxdjsx`의 **PR #237**에 있다.
  CHANGELOG `[Unreleased]`에 정리했고 아직 발행하지 않았다. 아래가 이 PR의 최종 상태다.

### PR #237 — 처리한 것

- **오탐·조용한 누락 수정** (보존을 넓히는 방향이라 결과가 사라질 수는 있어도 새로 생기지 않는다)
  - Git이 무시했지만 컴파일된 소스가 쓰는 선언을 `ignoredSourceReference`로 보존한다(`319d01a`).
    다른 보존 근거가 없을 때만 붙는 마지막 폴백이고, `impact`에서는 런타임 검토 사실로 나온다.
    보조 읽기는 본 분석이 고른 스토어만 쓰고(`--index-store` 준수), 추적 파일로 풀리는 무시 링크는 뺀다(`cbff8a9`).
  - 합성 Codable/Equatable/Hashable 준수를 인덱스와 프로젝트 프로토콜을 거쳐 판정한다(`47c5f9a`).
    `Comparable`(`s:SL`)도 Equatable로 센다. assign-only 판정도 프로토콜을 거친 준수를 따른다(`12f4cb4`).
  - `codableEnumCase`는 열거형이 도달 가능할 때만 케이스를 살리고, 열거형 자체는 살리지 않는다(`4bb5aa5`).
  - `#if`가 있는 파일의 `unused-import`를 보고하지 않는다(`18d6a3d`, README 문구 `9149285`).
  - Git 선택이 폴백하면 `source-discovery-git-unavailable` 한계를 싣는다(`81750c5`).
    선택 결과는 `GitSourceSelection`, 목록은 값 타입 `GitSourceInventory`로 나눴다.
    자기 분석의 타입 순환을 끊으려는 분리다(`51a4765`).
  - target scope 인벤토리가 `.build-*` 스크래치를 건너뛴다(`8dc0060`).
- **동작 변경(업그레이드 노트)**: 레이어 `path` 판정은 프로젝트 안 파일에 상대 경로만 쓴다(`a78831f`).
  의미가 달라진 공개 API `LayerDefinition.matches(candidates:)`는 지우지 않고 deprecated로 표시했다(`a87ceae`).
- **계약·CI·문서**
  - 스킬에 `cartograph_prepare`를 넣었다(`8ac2ce6`).
  - 플러그인 매니페스트 버전을 CI·릴리스에서 대조한다(`a7d1536`, 릴리스 하네스 `352e1df`).
  - iOS preflight를 PR CI에서 돌린다(`e3e6b26`).
  - `query`의 `unknown` 상태를 계약에 적었다(`c1e7ccf`).
  - 단위 테스트만의 커버리지가 기준 아래면 경고한다(`c5ca9df`).
  - isthmus `c76e105` 벡터를 다시 벤더링하고 SQL 관계 벡터를 실행한다(`c7648b4`).
  - AGENTS의 query 스키마 규칙을 실제 계약에 맞췄다(`9d6a1a6`).
- **CI 수정**
  - fix 검증 하네스의 실패 스위치를 `#if` 제외 대상 밖 파일로 옮겼다(`3f9c4a2`).
  - native 관측의 `ci.yml` 고정값(바이트·sha256·blob)을 갱신했다(`f9bca67`). 전례는 `7dc7f74`다.
  - 보존 측정 기준선 어댑터가 `.codableEnumCase`를 남기고 C-P1-3 두 플래그만 되돌린다(`644abc8`).
- **코퍼스**: FalsePositiveCorpus에 다음 오탐 계열을 넣었다. 기대 파일은 바꾸지 않았다(`bc8d1a6`).
  - 프로토콜 상속·별칭으로 얻은 Codable
  - Codable 열거형 케이스
  - `#if`만 있는 import

### PR #237 — 제외한 것과 이유

- **Git 무시 컴파일 소스의 코퍼스 사례**: 빌드 시점에 무시 파일을 만들어야 한다. 그러면 동결된 JSON 기대 파일
  5개의 `limitations`도 바뀐다. 전용 하위 코퍼스와 자체 검증기로 따로 다룬다.
- **보조 인덱스 읽기 비용 측정**: 무시 소스가 있을 때만 한 번 더 읽는다 — 모든 유닛을 열어 의존 목록을 훑고,
  레코드는 무시 파일의 것만 읽는다(`RawIndexStoreReader.swift`). 수치는 macOS CI나
  실제 프로젝트에서 재야 하고, 이 PR에서는 재지 않았다.
- **B1·B3**: 수정 범위를 넘는 새 기능이다.
- **B2**: 보존을 좁히는 변경이라 CONTRIBUTING "Narrowing one" 절차가 필요하다.
- **Core의 Darwin 파일 I/O를 Kit로 옮기기**: 큰 순수 리팩터링이다. 예외로 문서화만 했다.
- **계열 `query` 스키마 통일**: 공개 JSON 계약을 깨므로 하지 않는다(아래 계열 결정).

### 컴파일 근거와 리뷰 방식

- **이 PR을 작성한 세션에는 Swift 툴체인이 없었다**(Linux 컨테이너, Core의 `import Darwin`). 따라서 다음의
  유일한 근거는 PR #237의 macOS CI다. 로컬에서는 Python 하네스와 정적 대조만 돌렸다.
  - 컴파일과 `swift test`
  - `coverage.sh`·`verify-cli-contract.sh`·`verify-fixtures.sh`
  - 자기 분석(dead·cycles·type cycles·rules)
  - 새 테스트의 돌연변이 확인
- **GLM 리뷰 대체**: AGENTS가 요구하는 `packet-ask` GLM 리뷰는 이 환경에서 쓸 수 없었다. 대신 전체 diff를
  독립 Claude 리뷰로 검토했다. 지적과 처리 결과는 PR 본문에 있다. 머지 전에 GLM 리뷰를 받을 수 있으면 받는다.

### 머지 뒤 다음 할 일

1. PR #237의 macOS CI가 모두 녹색인지 확인한다. 실패하면 로컬 macOS에서 재현한다.
   "Measure synthesized-property retention"과 "Analyze this repository with itself"도 포함이다.
2. 로컬 macOS에서 새 보존 테스트의 돌연변이 확인을 한 번 돌린다(CI는 통과만 보여 준다).
3. 무시 컴파일 소스 하위 코퍼스와 검증기를 만든다(위 제외 항목).
4. 보조 인덱스 읽기 비용을 HealthMap 등 실제 프로젝트에서 잰다.
5. 발행은 지시가 있을 때만 한다. 이때 `[Unreleased]`를 버전 절로 옮기고 플러그인 매니페스트 버전도 함께 올린다.

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

저장소 루트에서 HANDOFF.md와 적용 AGENTS.md를 읽고 Git 상태를 확인해줘. PR #237이 머지됐는지,
macOS CI(coverage·fixtures·자기 분석)가 통과했는지 먼저 확인해. 그다음 "머지 뒤 다음 할 일"을 이어 가고,
남은 후보는 내가 고른 뒤 착수해.
발행·태그는 따로 지시가 있을 때만 해.
