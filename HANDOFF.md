# Handoff

_Last updated: 2026-09-05 01:41 KST by Codex_

## Goal

- Swift/iOS 의존성 그래프와 브리지 사실을 근거와 함께 제공하고, isthmus가 돌려준 외부
  retention으로 문자열 경계 너머의 실제 Swift 심볼을 보존한다.

## Current Status

- `main`의 기준 커밋은 `a6e773d`(PR #21 squash merge)다.
- cartograph `0.5.3` 릴리스와 macOS universal 자산이 공개됐다.
- Homebrew tap은 `ictechgy/homebrew-tap@70f0c7f`로 갱신됐고 로컬 설치도 0.5.3이다.
- 필수 후속 구현이나 배포 blocker는 없다.

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
- Optional follow-up: decide whether one symbol should retain and explain multiple bridge evidence records.
- Optional follow-up: add EventChannel/BasicMessageChannel only after GRAPH-EXCHANGE adds explicit semantics.

## What Worked

- Contract changes were fixed with failing tests before implementation and checked against a real compiler index.
- Synthetic dead-suppression and public-plugin evidence tests cover different sides of the integration.

## What Did Not Work / Avoid

- Do not run fixture verification against an old release binary; pass the freshly built binary explicitly.
- macOS `/var` and `/private/var` normalize differently across Swift and Dart producers. Shared-project
  integration fixtures should use a path without that alias or canonicalize both producers identically.
- Do not emit an unfiltered mixed-target document to isthmus v1.

## Next Steps

1. No required work remains for the 0.5.3/isthmus bridge milestone.
2. For a new bridge kind, update isthmus `docs/GRAPH-EXCHANGE.md` first, then producer tests.
3. Add `HOMEBREW_TAP_TOKEN` only if automatic tap updates are worth the broader credential setup.

## Resume Prompt

Open this repository at `/Users/jinhongan/Desktop/cartograph`, read `HANDOFF.md` and applicable
`AGENTS.md` files, then continue from: `No required 0.5.3 work remains; choose an explicit optional
follow-up before changing code.`
