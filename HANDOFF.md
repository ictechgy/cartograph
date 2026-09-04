# HANDOFF

새 세션이 이어받기 위한 문서다. 작업 규칙은 [AGENTS.md](AGENTS.md), Claude Code 전용 사항은 [CLAUDE.md](CLAUDE.md)에 있다. 이 파일은 **지금 어디까지 왔고 다음이 무엇인지**만 담는다.

마지막 갱신: 2026-09-04 (`bridges` · `--external-retentions` · Objective-C 코퍼스 PR 직후)

## 목표

Swift/iOS 코드베이스의 의존성 그래프를 컴파일러 인덱스에서 만들고, 그 위에서 미사용 코드 · 순환 · 레이어 규칙 · 지표를 **근거와 함께** 답하는 오픈소스 CLI. Periphery 가 상업화되며 남긴 자리를 채운다. 소비자가 사람이 아니라 에이전트일 때를 전제로 `query` 와 `skill` 을 갖춘다.

## 현재 상태

- **0.4.0 릴리스 완료** (2026-09-04). GitHub Release + Homebrew tap(`ictechgy/tap`) 갱신 + `brew upgrade` 로 설치 확인. 이력: 0.1.0 → 0.2.0 → 0.3.0(2026-09-03) → 0.4.0
- `main` 은 깨끗하다. 자기 분석 findings 0 (1,296 노드), 커버리지 92.86%, 테스트 8 스위트 전부 통과
- 최근 머지: PR #7 `query` 명령 · PR #8 `skill` 명령 · PR #9 버전 범프. 각 PR 의 코멘트에 GLM 리뷰 대응(반박 · 반영 · 거절)이 형식의 예로 남아 있다
- 자매 프로젝트 셋이 바탕화면에 계획 문서만 있는 상태로 생겼다: [kartograph](../kartograph)(Kotlin) · [dartograph](../dartograph)(Dart) · [isthmus](../isthmus)(언어 경계 조인)
- **isthmus 선행 작업 완료**(PR #11). `bridges --format json|text` 가 `bridge-facts` 버전 1 (isthmus Phase 0 의 `expected/swift.json` 과 같은 모양: Swift 는 `channel-register` 와 `method-handle` 만, `symbol.qualifiedName` 은 `CameraPlugin.register` 표기, 한계 키 `dynamic-channel-names` · `missing-handler-usrs`)을 내고, `--external-retentions` / `external_retentions_path` 가 `external-retentions` 초안 0 을 읽어 `RetentionReason.externalBridge` 로 보존하며 `dead --explain` 이 evidence 를 문장으로 만든다. 코퍼스에 Flutter 형태의 핸들러와 `external-retentions.json` 이 있어 진짜 인덱스로 왕복이 검증된다
- **Objective-C 혼합 검증 완료**. 코퍼스에 `CorpusObjC` 타깃(`.m` + RN 매크로 스텁)을 넣었다. `query` 의 `limitations` 에 `objective-c-sources: 1 file(s)` 가 실제로 세어져 나오는 것을 `verify-fixtures.sh` 가 고정한다. 인덱스 공급자는 `.swift` 만 읽으므로 `.m` 심볼은 그래프에 들어오지 않는다(`IndexStoreProvider.swift:69`)

## 다음 할 일 (우선순위 순)

1. **isthmus 에 계약 피드백을 전달할 것** — 구현하면서 드러난 계약의 빈 곳. `GRAPH-EXCHANGE.md` 를 고치는 쪽은 isthmus 다. **계약이 작업 도중 초안 0 → 버전 1 로 바뀌었다.** 다시 읽고 맞췄지만, 다음 세션은 시작할 때 `git -C ../isthmus log -- docs/GRAPH-EXCHANGE.md` 를 먼저 볼 것
   - `target` 이 문서당 하나인데 Swift 프로젝트는 Flutter 와 RN 을 함께 품을 수 있다. 지금은 다수를 적고 `limitations` 에 `mixed-targets` 로 알린다. 사실마다 `target` 을 두거나 문서를 둘로 쪼개는 쪽이 낫다
   - `FlutterPlugin` 스타일(`handle(_:result:)` 메서드)에서는 파일에 채널이 하나일 때만 채널을 붙이고(`inferred-channels` 로 셈) 아니면 `null` 이다. isthmus 가 `null` 채널을 어떻게 셀지 정해야 한다
   - Swift RN 모듈은 `@objc(Name)` 클래스와 `.m` 의 `RCT_EXTERN_METHOD` 양쪽에서 같은 `(channel, method)` 가 위치만 다르게 두 번 나온다. 둘 다 사실이라 합치지 않았다. isthmus 는 위치가 아니라 `(channel, method)` 집합으로 조인해야 한다
   - `bridges` 는 인덱스 스토어가 있어야 돈다(USR 을 붙이려고). 없으면 종료 코드 2. Dart 쪽처럼 인덱스 없이도 돌게 할지는 수요를 보고 정한다
   - (완료) `dead --report-format json` 에 `query` 와 같은 `limitations` 를 실었다. isthmus 피드백은 `../isthmus/HANDOFF.md` 의 "cartograph 에서 온 계약 피드백" 절에 적어 두었다(그 저장소는 리모트가 없고 다른 세션이 브랜치에서 작업 중이라 커밋하지 않았다)
2. **`query` 응답에 evidence 를 실을지** — 지금은 `reason: "externalBridge"` 값만 간다(스키마를 자매 저장소와 맞춰야 해서 보류). 에이전트가 `--explain` 을 한 번 더 부르면 된다. 넣는다면 `reachability.evidence` 선택 필드로, 자매 저장소에 알리고 스킬 문장을 같이 고칠 것
3. **`HOMEBREW_TAP_TOKEN` 시크릿** — 없어서 릴리스마다 tap 을 손으로 갱신한다. 계정 설정이라 사용자가 만들어야 한다. 만들면 `release.yml` 이 자동으로 formula 를 고친다
4. 선택: `FlutterEventChannel(name:)` / `setStreamHandler` 를 `bridges` 에 추가. 계약에 없어 뺐다. `metrics --explain`(어느 간선이 I·A·D 를 만들었는지), 최신 Xcode 베타 스모크 테스트 — GLM 개선 목록에서 나온 것. 수요 근거는 없다

## 효과가 있었던 방식

- **리뷰 주장을 코드로 확인한 뒤 반영.** GLM 이 "가장 중요한 체크" 라고 한 것(`impliesUsage` 집합 일치)은 `ReachabilityAnalyzer.swift:290` 한 줄로 반박됐고, "정의 없이 쓰인 retained root" 지적은 `retainPublic` 기본값 `false` 를 드러내 스킬의 가장 중요한 문장이 됐다. 둘 다 확인 없이는 못 가른다
- **테스트가 실제로 무는지 일부러 부순다.** 코퍼스는 수정을 끄고 돌려 실패를 봤고(첫 코퍼스는 통과해서 아무것도 증명 못 했다), 스킬 드리프트 테스트는 사본에 한 줄 덧붙여 실패를 봤다
- **실제 프로젝트 도그푸딩이 오탐의 유일한 원천이었다.** 단위 테스트는 손으로 만든 스냅샷을 보므로 컴파일러가 실제로 무엇을 기록하는지 검증하지 못한다. 바탕화면의 AnbuRadar(`ruokay/ios`), HealthMap(`health_map_project/health_map/native/ios`, DerivedData 있음), 골목골목(`골목골목/ios`, 스킴 `GolmokGolmok`)이 대상이었다
- **에이전트용 출력은 "답하지 않는 것"이 설계다.** 삭제 판정 없음 · 한계를 응답에 · 베이스라인 반영 · 잘림 표시 · 규칙 통과 후 무엇을 할지. `docs` 가 아니라 `AGENTS.md` 의 "에이전트가 소비하는 출력" 절에 규칙으로 올렸다
- 인덱스 스토어 기반이 옳았다는 외부 근거: MobileNativeFoundation 논의(#156)에서 Lyft 의 인덱스 스토어 도구가 130만 줄을 30초, SourceKit 기반 SwiftLint 가 3시간

## 효과가 없었거나 틀렸던 것 (반복 금지)

- **`verify-fixtures.sh` 는 릴리스 바이너리를 빌드하지 않는다.** 경로만 찾아 실행한다. 낡은 릴리스 바이너리로 검증해 "고쳤는데 안 먹는다"고 20분을 헤맸다. `swift build -c release` 먼저, 또는 디버그 바이너리 경로를 첫 인자로
- **SwiftParser 는 이항 연산자를 접지 않는다.** `channel = FlutterMethodChannel(…)` 과 `call.method == "x"` 가 `SequenceExpr` 로 남아 `InfixOperatorExpr` 방문자가 아무것도 못 봤다. `SwiftOperators` 의 `foldAll` 을 거쳐야 한다. `BridgeFactScanner` 에 있다
- **`Regex` 는 Sendable 이 아니다.** `static let` 으로 두면 Swift 6 이 거부한다. 계산 프로퍼티로 뒀다(`ReactNativeMacroScanner`)
- **GLM 리뷰가 옳았던 것 셋.** `.m` 블록 주석 안의 매크로가 살아 있는 모듈로 나갔고, 멤버 접근의 수신자를 무시해 다른 타입의 동명 상수를 이 파일의 리터럴로 풀었고, `FlutterMethodCall` 과 무관한 `.method` 비교가 파일의 유일한 채널에 붙었다. 셋 다 "dynamic 은 안전하지만 틀린 리터럴은 조인을 오염시킨다" 는 같은 형태다. 반대로 "swift-syntax 600 에 `ExpressionPatternSyntax` 가 없다" 와 "계약 버전이 1 인데 코드가 0" 은 확인하니 전자는 틀렸고 후자는 문서가 리뷰 도중 바뀐 것이었다
- **합성된 memberwise init 이 `--report-test-only` 오탐을 만들었다.** 아무도 쓰지 않는 public 구조체가 "테스트만 붙잡고 있다"로 나왔다. 코퍼스에 스텁 구조체를 넣다가 잡혔고 `ReachabilityAnalyzer.testOnlyCode` 에서 고쳤다

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
