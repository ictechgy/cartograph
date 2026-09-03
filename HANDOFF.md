# HANDOFF

새 세션이 이어받기 위한 문서다. 작업 규칙은 [AGENTS.md](AGENTS.md), Claude Code 전용 사항은 [CLAUDE.md](CLAUDE.md)에 있다. 이 파일은 **지금 어디까지 왔고 다음이 무엇인지**만 담는다.

마지막 갱신: 2026-09-04 (0.4.0 릴리스 직후)

## 목표

Swift/iOS 코드베이스의 의존성 그래프를 컴파일러 인덱스에서 만들고, 그 위에서 미사용 코드 · 순환 · 레이어 규칙 · 지표를 **근거와 함께** 답하는 오픈소스 CLI. Periphery 가 상업화되며 남긴 자리를 채운다. 소비자가 사람이 아니라 에이전트일 때를 전제로 `query` 와 `skill` 을 갖춘다.

## 현재 상태

- **0.4.0 릴리스 완료** (2026-09-04). GitHub Release + Homebrew tap(`ictechgy/tap`) 갱신 + `brew upgrade` 로 설치 확인. 이력: 0.1.0 → 0.2.0 → 0.3.0(2026-09-03) → 0.4.0
- `main` 은 깨끗하다. 자기 분석 findings 0 (1,296 노드), 커버리지 92.86%, 테스트 8 스위트 전부 통과
- 최근 머지: PR #7 `query` 명령 · PR #8 `skill` 명령 · PR #9 버전 범프. 각 PR 의 코멘트에 GLM 리뷰 대응(반박 · 반영 · 거절)이 형식의 예로 남아 있다
- 자매 프로젝트 셋이 바탕화면에 계획 문서만 있는 상태로 생겼다: [kartograph](../kartograph)(Kotlin) · [dartograph](../dartograph)(Dart) · [isthmus](../isthmus)(언어 경계 조인). 이 저장소에 **선행 작업**이 걸려 있다(아래)

## 다음 할 일 (우선순위 순)

1. **isthmus 선행 작업** — `../isthmus/docs/GRAPH-EXCHANGE.md` 가 계약이다
   - `bridges --format json`: `CartographSyntax` 에 `BridgeFactScanner` 를 두고 `FlutterMethodChannel(name:)` · `setMethodCallHandler` · `switch call.method { case "…" }` · `RCT_EXPORT_MODULE/METHOD` · `@objc(…)` 리터럴을 위치와 함께 낸다. 한 단계 상수 추적(`static let name = "…"`)까지
   - `--external-retentions <path>`: isthmus 가 돌려주는 보존 근거 파일을 읽어 `RetentionReason.externalBridge` 로 매핑하고 `dead --explain` 이 evidence 를 문장으로 만든다
   - 둘 다 이 저장소의 규칙대로: 테스트 · 커버리지 · CLI 계약 · 픽스처 · CHANGELOG · GLM 리뷰 · PR
2. **Objective-C 혼합 프로젝트 검증** — 아직 못 했다. 바탕화면 iOS 프로젝트 전부 순수 Swift 라 `.m` 이 하나도 없다. 공개 프로젝트를 찾거나 코퍼스에 `.m` 타깃을 추가해 `limitations` 의 `objective-c-sources` 가 실제 프로젝트에서 뜨는 것까지 확인할 것
3. **`HOMEBREW_TAP_TOKEN` 시크릿** — 없어서 릴리스마다 tap 을 손으로 갱신한다. 계정 설정이라 사용자가 만들어야 한다. 만들면 `release.yml` 이 자동으로 formula 를 고친다
4. 선택: `metrics --explain`(어느 간선이 I·A·D 를 만들었는지), 최신 Xcode 베타 스모크 테스트 — GLM 개선 목록에서 나온 것. 수요 근거는 없다

## 효과가 있었던 방식

- **리뷰 주장을 코드로 확인한 뒤 반영.** GLM 이 "가장 중요한 체크" 라고 한 것(`impliesUsage` 집합 일치)은 `ReachabilityAnalyzer.swift:290` 한 줄로 반박됐고, "정의 없이 쓰인 retained root" 지적은 `retainPublic` 기본값 `false` 를 드러내 스킬의 가장 중요한 문장이 됐다. 둘 다 확인 없이는 못 가른다
- **테스트가 실제로 무는지 일부러 부순다.** 코퍼스는 수정을 끄고 돌려 실패를 봤고(첫 코퍼스는 통과해서 아무것도 증명 못 했다), 스킬 드리프트 테스트는 사본에 한 줄 덧붙여 실패를 봤다
- **실제 프로젝트 도그푸딩이 오탐의 유일한 원천이었다.** 단위 테스트는 손으로 만든 스냅샷을 보므로 컴파일러가 실제로 무엇을 기록하는지 검증하지 못한다. 바탕화면의 AnbuRadar(`ruokay/ios`), HealthMap(`health_map_project/health_map/native/ios`, DerivedData 있음), 골목골목(`골목골목/ios`, 스킴 `GolmokGolmok`)이 대상이었다
- **에이전트용 출력은 "답하지 않는 것"이 설계다.** 삭제 판정 없음 · 한계를 응답에 · 베이스라인 반영 · 잘림 표시 · 규칙 통과 후 무엇을 할지. `docs` 가 아니라 `AGENTS.md` 의 "에이전트가 소비하는 출력" 절에 규칙으로 올렸다
- 인덱스 스토어 기반이 옳았다는 외부 근거: MobileNativeFoundation 논의(#156)에서 Lyft 의 인덱스 스토어 도구가 130만 줄을 30초, SourceKit 기반 SwiftLint 가 3시간

## 효과가 없었거나 틀렸던 것 (반복 금지)

- **손으로 만든 프로퍼티 래퍼는 `$name` 분할을 재현하지 못한다.** SwiftUI 의 `@State` 만 그렇다. 코퍼스는 SwiftUI 기반이어야 한다
- **인덱스 스토어 루트의 mtime 은 낡았다.** `.build/out` 은 처음 만든 날짜 그대로이고 레코드는 `v5/units` 에 쌓인다. 루트만 보면 "71 of 71 파일이 낡음" 오탐. `indexStoreDate()` 가 `v5/units` 까지 본다
- **가지치기 목록이 두 벌이었다.** `IndexStoreProvider` 와 `CartographService` 가 각자 들고 있었다. `BuildArtifactDirectories` 하나로 합쳤다. 두 번째 목록을 만들지 말 것
- **`query` 의 `level` 에 설정값을 실었다.** `unusedCode` 는 항상 심볼 레벨이다. 모듈 레벨 설정 저장소에서 심볼 답에 `module` 이라고 적혔다. 회귀 테스트 있음
- **스택 PR 의 부모를 `--delete-branch` 로 머지하면 자식 PR 이 닫힌다.** 닫힌 PR 은 못 연다. 자식의 base 를 `main` 으로 먼저 바꾸고 부모를 머지할 것
- **GLM `research` 모드(첨부 없음)는 tool-call 조각만 돌려보냈다.** 질문 파일을 `--files` 로 첨부한 `review` 모드로 재시도하니 답이 왔다. 그리고 SUB CLI 는 실제 저장소가 아니라 스크래치 git 저장소 안에서, 파일은 그 안으로 복사해서 돌려야 한다(`--files` 는 worktree 밖 경로를 거부한다)
- **RN/Flutter 는 이 도구의 대상이 아니다.** `골목골목/mobile` 은 Expo managed 라 `ios/` 자체가 없다. 브라운필드(네이티브 앱에 임베드)만 유효

## 알아 두면 시간이 절약되는 것

- 증분 빌드 ~2초, 전체 ~15초. 인덱스는 `.build/out/v5`. `-Xswiftc -index-store-path` 는 무시된다
- HealthMap 인덱스: `~/Library/Developer/Xcode/DerivedData/HealthMap-fwqvvyfqngyopcdehpcxlhivybcf/Index.noindex/DataStore`. 7,466 심볼, `dead` 2.7초
- 검증 4종은 한 번에: `swift test`, `Scripts/coverage.sh`, `Scripts/verify-cli-contract.sh`, `Scripts/verify-fixtures.sh`. 백그라운드로 묶어 돌리고 `.done` 파일로 기다린다
- 릴리스: `Sources/CartographCore/Cartograph.swift` 의 버전 상수 · README 두 개의 설치 버전 · 이슈 템플릿 placeholder · CHANGELOG 링크. 태그를 밀면 `release.yml` 이 유니버설 바이너리를 만들고 **압축 푼 바이너리로 CLI 계약을 재검증**한다. tap 은 `HOMEBREW_TAP_TOKEN` 이 없으면 로그의 url/sha256 으로 직접 갱신
