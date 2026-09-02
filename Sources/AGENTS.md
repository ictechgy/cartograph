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
| `CartographCore` | 그래프 모델, 인덱스 추상화, 설정 값 타입, 글롭, 진단, 파일 시스템 프로토콜 | **모든 외부 의존성.** 파일·프로세스·네트워크 접근 |
| `CartographConfig` | `.cartograph.yml` 로딩과 CLI 덮어쓰기 | 분석 로직 |
| `CartographSyntax` | SwiftSyntax로 접근 수준·속성·주석 명령 읽기 | 인덱스 스토어 접근 |
| `CartographAnalysis` | 순환, 도달 가능성, 보존, 지표, 레이어 규칙, 베이스라인 | 파일 읽기(베이스라인은 주입된 FileSystem 사용), 출력 형식 |
| `CartographExport` | 그래프 렌더러와 진단 리포터 | 분석 로직 |
| `CartographIndexStore` | IndexStoreDB 어댑터, 스토어·라이브러리 경로 탐색 | 도메인 판단 |
| `CartographKit` | 파이프라인 조립, 환경 주입 | 알고리즘 |
| `cartograph` | 인자 파싱, 종료 코드, 표준 출력 | 그 외 모든 것 |
| `CartographTestSupport` | 테스트용 빌더와 메모리 파일 시스템 | 프로덕션 코드가 이것을 참조하는 일 |

## 새 코드를 어디에 둘지

- **순수 계산이고 인덱스만 있으면 되는가** → `CartographAnalysis`
- **출력 모양만 바꾸는가** → `CartographExport`
- **파일이나 프로세스를 건드려야 하는가** → `CartographKit` 이상. 그 아래 계층에 넣지 말고
  `FileSystem` 프로토콜로 주입받으세요.
- **여러 모듈이 함께 쓰는 값 타입인가** → `CartographCore`. 단, 외부 의존성이 필요하면 아닙니다.

## 라이브러리 API를 건드릴 때

`CartographKit`은 임베드용 공개 제품이다. 두 층을 섞지 마세요.

- **질의 API** (`cycles(in:)`, `unusedCode(in:)`, `metrics(in:)`, `layerViolations(in:)`):
  값을 그대로 돌려줍니다. 렌더링·베이스라인·임계값을 여기 넣지 마세요.
- **명령 API** (`detectCycles()` 등): 질의 결과에 CI 정책과 출력 형식을 얹습니다.

인덱스 읽기는 파이프라인에서 가장 느립니다. 여러 분석을 묶어 돌리는 코드는
`loadContext()`로 스냅샷을 한 번만 읽고 문맥을 넘겨 쓰세요.

패키지의 `CartographKit` 제품에는 구성 타깃이 모두 들어 있어야 합니다. Kit만 내보내면
임베더가 반환 타입의 이름조차 부를 수 없습니다.

## 새 분석을 추가할 때

1. `CartographAnalysis`에 `(CodeGraph, IndexSnapshot) -> 결과` 형태의 순수 타입을 만듭니다.
2. `AnalysisDiagnostics`에 결과 → `Diagnostic` 변환을 추가합니다. 규칙 식별자는 베이스라인
   키가 되므로 한 번 정하면 바꾸기 어렵습니다.
3. `CartographService`에 명령을 추가합니다. 베이스라인·임계값·리포터 처리는 `finish(...)`가
   이미 담당하므로 다시 쓰지 마세요.
4. `cartograph` 실행 타깃에 하위 명령을 추가합니다.
5. 임계값이 필요하면 `Thresholds`와 `ConfigurationTemplate` 양쪽에 넣고 두 README에 적습니다.

## 새 출력 형식을 추가할 때

`GraphFormat` 또는 `ReportFormat`에 케이스를 넣고 팩토리에 연결합니다.
두 팩토리 모두 `allCases`를 도는 테스트가 있어, 케이스만 추가하고 구현을 빠뜨리면 컴파일이
실패하거나 테스트가 잡습니다.
