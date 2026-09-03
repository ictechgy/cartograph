# Tests/AGENTS.md

테스트 작성 규칙입니다. 루트 [AGENTS.md](../AGENTS.md)를 먼저 읽으세요.

## 기본 규칙

- 프레임워크는 swift-testing (`import Testing`, `@Test`, `@Suite`, `#expect`).
- 테스트 이름은 한국어 문장으로, **무엇을 보장하는지**를 씁니다.
  `@Test("순환이 없으면 아무것도 보고하지 않는다")`처럼요.
  `testDetectCycles` 같은 이름은 실패했을 때 아무것도 알려 주지 않습니다.
- 테스트 타깃은 소스 모듈과 1:1로 대응합니다.
- 픽스처 Xcode 프로젝트를 만들지 마세요. 인덱스 스토어가 필요해 보이는 테스트는 대개
  스냅샷을 손으로 만들면 됩니다.

## 도구

`CartographTestSupport`에 세 가지가 있습니다.

```swift
// 인덱스 스냅샷을 손으로 조립
var builder = SnapshotBuilder()
builder.symbol("HomeView", kind: .structType, module: "App", attributes: [.entryPoint])
builder.reference(from: "HomeView", to: "UserService", kind: .call)

// 위상만 중요한 알고리즘 테스트
let graph = TestGraph.make(["A": ["B"], "B": ["A"]])

// 디스크를 건드리지 않는 파일 시스템
let fileSystem = InMemoryFileSystem(files: ["/p/.cartograph.yml": "level: type"])
```

`IndexStoreDB`의 `Symbol`과 `SymbolOccurrence`는 공개 이니셜라이저가 있습니다.
인덱스 어댑터의 변환 규칙도 실제 스토어 없이 테스트하세요
(`Tests/CartographIndexStoreTests/IndexStoreMappingTests.swift` 참고).

## 무엇을 테스트할 것인가

**규칙마다 그 규칙이 없으면 실패하는 테스트를 붙이세요.** 특히 보존 규칙은 하나하나가
"이것을 지우면 사용자 앱이 깨진다"는 주장이므로 근거가 남아야 합니다.

**재발한 버그는 회귀 테스트로 고정하세요.** 지금까지 고정한 것들:
- 순환 탐지의 O(V²) 경로 복사와 O(V·(V+E)) 시작점 전수 탐색 → 정점 2만 개 사슬 테스트
- JSON 키 순서 비결정성 → 두 번 인코딩해 같은지 비교
- 인덱스 관계 방향(`baseOf`, `overrideOf`, `calledBy`, `extendedBy`) → 각각 방향 테스트
- 프로토콜 구현 오탐 → 요구사항 호출이 구현까지 도달하는지
- 절대/상대 경로 글롭 → 두 형태 모두 매칭되는지
- `query`의 `level`에 설정값이 실리던 문제 → 모듈 레벨 설정에서도 `symbol`인지
- 같은 두 정점 사이의 다중 간선 → `edges`에 종류가 전부 담기는지
- 도달 가능한 정점에 베이스라인 억제 표시가 붙던 모순 → `reachable`이면 `suppressedByBaseline`이 거짓인지
- 인덱스 신선도 → 스토어 시각보다 새 파일 수가 정확히 세어지는지, 시각을 모르면 침묵하는지
- 스킬 문서 드리프트 → 저장소 사본과 템플릿이 바이트까지 같은지 (`AgentSkillTemplateTests`)
- 스킬 설치기 → 실제 임시 디렉터리에 정해진 경로로 쓰고 `--force` 없이는 덮어쓰지 않는지

**테스트가 실제로 무는지 한 번은 확인하세요.** 고치려는 것을 잠시 되돌리거나 검증 대상을 일부러
망가뜨려 실패를 봐야 합니다. 첫 오탐 코퍼스는 수정을 껐는데도 통과했고, 스킬 드리프트 테스트는
사본에 한 줄을 덧붙여 실패를 확인했습니다. 통과만 하는 테스트는 커버리지 숫자일 뿐입니다.

**커버리지 숫자를 위한 테스트는 쓰지 마세요.** 기준은 90%이고 현재 93%대입니다.
CLI 껍데기와 인덱스 스토어 입출력은 의도적으로 비워 두고 CI의 자기 분석 잡에 맡깁니다.

## 결정성

출력은 항상 정렬되어야 하고, 테스트는 그 특성을 확인해야 합니다.
같은 입력을 두 번 처리해 결과가 같은지 보는 테스트가 여러 곳에 있습니다.
정렬을 빼먹으면 CI에서만 간헐적으로 실패하는 테스트가 됩니다.
