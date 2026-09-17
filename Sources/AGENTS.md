# Sources/AGENTS.md

모듈 경계 규칙입니다. 루트 [AGENTS.md](../AGENTS.md)를 먼저 읽으세요.

## Scoped Guidance Index

다음 링크는 탐색용입니다. 하위 지침은 해당 모듈 디렉터리와 그 아래에서만 적용됩니다.

- [CartographIndexStore/AGENTS.md](CartographIndexStore/AGENTS.md) — 인덱스 관계 변환과 소유자 귀속

타깃 안에 지침 문서를 추가하면 `Package.swift`의 해당 타깃 `exclude`에 넣어 미처리 파일 경고를 막습니다.

## 의존 방향

의존은 아래에서 위로만 흐릅니다. 역방향 참조는 `cartograph rules`가 CI에서 막습니다.

```
CartographCore
  ↑
CartographConfig · CartographSyntax · CartographAnalysis ← CartographExport · CartographIndexStore
  ↑
CartographKit
  ↑
cartograph
```

> **수평 의존 예외**: `CartographExport`는 `MetricsRenderer`가 지표 모델(`NodeMetrics`)을 렌더링하기 위해 `CartographAnalysis`를 import합니다. `.cartograph.yml`의 `Feature` 레이어 규칙은 동일 레이어 내 의존(`source == target`)을 허용하므로 `rules` 검사를 통과하지만, 기능 계층 내부의 유일한 수평 의존입니다.

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

## 그래프·경로 구현 주의점

**`unusedCode(in:)`는 설정과 무관하게 항상 심볼 레벨 그래프를 만듭니다.** 응답에 `configuration.level`을
실어 보내면 심볼 레벨 답에 `module`이라고 적힙니다. 실제로 그랬고 회귀 테스트가 있습니다.

**인덱스 심볼 이름에는 인자 목록이 붙습니다.** `main()`, `describe(_:)`, `buildBlock(_:)`처럼요.
이름으로 규칙을 걸 때는 `GraphNode.baseName`을 쓰세요.

**경로는 절대 경로로 들어오고 설정은 상대 경로로 쓰입니다.** 경로 글롭을 새로 쓰는 곳이 생기면
`PathFilter.matchCandidates(for:relativeTo:)`를 거치세요. 한쪽만 지원하면 같은 패턴이
설정 위치에 따라 다르게 동작합니다.

**단, 대조하는 형태는 방향마다 다릅니다.** include 는 절대·상대 두 형태를 모두 보고, exclude 는
프로젝트 안의 경로면 상대 경로만 봅니다(절대 경로로 쓴 패턴은 예외). 두 방향의 실패 비용이 다르기
때문입니다. include 를 좁히면 아무것도 안 골라 "정점 0개"가 되고, exclude 를 넓히면 프로젝트 루트의
조상 디렉터리 이름 하나로 프로젝트 전체가 사라집니다. 실제로 `~/DerivedData/App` 아래 있는
프로젝트가 기본 제외에 통째로 걸려 `--strict` 가 0줄을 분석하고 통과했습니다.

**`CodeGraph`는 양 끝 정점이 모두 있는 간선만 남깁니다.** 분석 범위 밖(SDK 등)으로 향하는
관계는 그래프에 없습니다. 외부 관계를 봐야 하는 규칙은 원본 `IndexSnapshot`을 읽으세요.

**심볼 레벨 그래프는 정점이 수만 개가 됩니다.** 재귀 순회와 경로 배열 복사는 실제로 돌려 보면 바로
멈춥니다. 그래서 `CycleDetector`는 반복형 Tarjan과 선행 정점 기반 경로 복원을 씁니다.

## 브리지 구문과 인덱스 결합

**`bridges`는 문자열을 읽습니다.** 인덱스는 `FlutterMethodChannel(name: "…")`의 문자열을 모릅니다.
스캐너(`CartographSyntax/BridgeFactScanner`)가 구문에서 리터럴을 뽑고, `CartographKit`의
`BridgeSymbolResolver`가 감싸는 선언의 USR을 인덱스에서 붙입니다.
이항 연산자는 `SwiftOperators`로 접어야 `a = b`와 `x == "y"`가 보입니다. 접지 않으면 `SequenceExpr`로 남습니다.

## 질의 근거와 지역 함수

[질의 근거 계약](../docs/QUERY-EVIDENCE.md)을 따릅니다. 선언 위치를 빠진 호출 위치로 대신 쓰거나,
구문으로 복원한 지역 함수 ID(`cartograph:local-function:`)를 컴파일러 USR로 표현하지 마세요.
소스가 신선하고 소유자·참조 사슬이 유일하게 입증될 때만 지역 함수 소유권을 정밀화합니다.

MCP 배치는 `QueryEvidenceBudget`으로 선택 근거를 **배치 전체**에서 제한합니다. 단건 한도만 지키면
큰 배치가 전송 한도를 넘습니다. 요청 순서·중복·이웃·상태와 전체/생략 개수는 유지하세요.
