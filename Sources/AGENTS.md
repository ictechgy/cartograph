# Sources/AGENTS.md

모듈 경계 규칙입니다. 루트 [AGENTS.md](../AGENTS.md)를 먼저 읽으세요.

## 의존 방향

의존은 아래에서 위로만 흐릅니다. 역방향 참조는 `cartograph rules`가 CI에서 막습니다.

```
CartographCore
  ↑
CartographConfig · CartographSyntax · CartographAnalysis · CartographExport · CartographIndexStore
  ↑
CartographKit
  ↑
cartograph
```

## 모듈별 책임과 금지 사항

| 모듈 | 담는 것 | 담으면 안 되는 것 |
|---|---|---|
| `CartographCore` | 그래프 모델, 인덱스 추상화, 설정 값 타입, 글롭, 진단, 파일 시스템 프로토콜, 빌드 산출물 가지치기 목록(`BuildArtifactDirectories`) | **모든 외부 의존성.** 파일·프로세스·네트워크 접근 |
| `CartographConfig` | `.cartograph.yml` 로딩과 CLI 덮어쓰기, 설정 템플릿, 에이전트 스킬 템플릿(`AgentSkillTemplate`) | 분석 로직 |
| `CartographSyntax` | SwiftSyntax로 접근 수준·속성·주석 지시어 읽기 | 인덱스 스토어 접근 |
| `CartographAnalysis` | 순환, 도달 가능성, 보존, 지표, 레이어 규칙, 베이스라인, 외부 보존 근거 | 파일 읽기(베이스라인과 외부 근거 파일은 주입된 FileSystem 사용), 출력 형식 |
| `CartographExport` | 그래프 렌더러와 진단 리포터 | 분석 로직 |
| `CartographIndexStore` | IndexStoreDB 어댑터, 스토어·라이브러리 경로 탐색 | 도메인 판단 |
| `CartographKit` | 파이프라인 조립, 환경 주입, 에이전트용 응답 타입(`SymbolQuery`·`SymbolQueryDocument`) | 알고리즘 |
| `cartograph` | 인자 파싱, 종료 코드, 표준 출력 | 그 외 모든 것 |
| `CartographTestSupport` | 테스트용 빌더와 메모리 파일 시스템 | 프로덕션 코드가 이것을 참조하는 일 |

## 새 코드를 어디에 둘지

- **순수 계산이고 인덱스만 있으면 되는가** → `CartographAnalysis`
- **출력 모양만 바꾸는가** → `CartographExport`
- **파일이나 프로세스를 건드려야 하는가** → `CartographKit` 이상. 그 아래 계층에 넣지 말고
  `FileSystem` 프로토콜로 주입받으세요.
- **여러 모듈이 함께 쓰는 값 타입인가** → `CartographCore`. 단, 외부 의존성이 필요하면 아닙니다.

## 라이브러리 API를 건드릴 때

`CartographKit`은 임베드용 공개 제품입니다. 다음 두 층을 섞지 마세요.

- **질의 API** (`cycles(in:)`, `unusedCode(in:)`, `metrics(in:)`, `layerViolations(in:)`,
  `queryDocument(symbol:)`): 값을 그대로 돌려줍니다. 렌더링·베이스라인·임계값을 여기 넣지 마세요.
  단 `queryDocument`는 예외로 베이스라인을 읽습니다 — 억제 여부가 답의 일부라서,
  이것을 위층에 두면 같은 사실을 두 번 계산하게 됩니다.
- **명령 API** (`detectCycles()`, `query(symbol:)` 등): 질의 결과에 CI 정책과 출력 형식을 얹습니다.

인덱스 읽기는 파이프라인에서 가장 느립니다. 여러 분석을 묶어 돌리는 코드는
`loadContext()`로 스냅샷을 한 번만 읽고 문맥을 넘겨 쓰세요.

패키지의 `CartographKit` 제품에는 구성 타깃이 모두 들어 있어야 합니다. Kit만 내보내면
가져다 쓰는 쪽이 반환 타입의 이름조차 쓸 수 없습니다.

## 새 분석을 추가할 때

1. `CartographAnalysis`에 `(CodeGraph, IndexSnapshot) -> 결과` 형태의 순수 타입을 만듭니다.
2. `AnalysisDiagnostics`에 결과 → `Diagnostic` 변환을 추가합니다. 규칙 식별자는 베이스라인
   키가 되므로 한 번 정하면 바꾸기 어렵습니다.
3. `CartographService`에 명령을 추가합니다. 베이스라인·임계값·리포터 처리는 `finish(...)`가
   이미 담당하므로 중복 구현하지 마세요.
4. `cartograph` 실행 타깃에 하위 명령을 추가합니다.
5. 임계값이 필요하면 `Thresholds`와 `ConfigurationTemplate` 양쪽에 넣고 두 README에 적습니다.

## 새 하위 명령을 추가할 때

`query`와 `skill`을 넣으면서 매번 같은 곳을 빠뜨렸습니다. 한 PR에서 전부 고치세요.

1. `CartographCommand.configuration.subcommands` 배열에 등록합니다.
2. `Tests/CartographCLITests`의 `CommandConfigurationTests`가 등록된 이름 목록을 통째로 단언합니다.
   빠뜨리면 여기서 실패합니다 — 그 용도입니다.
3. `Scripts/verify-cli-contract.sh`의 `--help` 루프에 이름을 넣고, 사용 오류(64)가 나야 하는
   인자 조합(대상 누락, 범위 밖 값)을 추가합니다.
4. `README.md`와 `README.ko.md`에 절을 쓰고 비교표에 행을 넣습니다. 둘의 내용이 같아야 합니다.
5. `CHANGELOG.md`의 `[Unreleased]`에 **왜** 이 명령이 있는지를 적습니다.
6. 없는 대상을 물으면 `CommandOutcome.subjectNotFound`를 세워 `emit`이 64로 끝내게 합니다.
   조용히 0으로 끝나면 스크립트의 오타가 "아무도 안 씀"으로 읽힙니다.

## 새 출력 형식을 추가할 때

`GraphFormat` 또는 `ReportFormat`에 케이스를 넣고 팩토리에 연결합니다.
두 팩토리 모두 `allCases`를 도는 테스트가 있어, 케이스만 추가하고 구현을 빠뜨리면 컴파일이
실패하거나 테스트가 잡습니다.
