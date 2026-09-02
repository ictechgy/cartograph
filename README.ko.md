# Cartograph

**질의할 수 있는 Swift·iOS 코드 의존성 그래프.**

[English](README.md)

Cartograph 는 컴파일러가 이미 만들어 둔 인덱스 스토어를 읽어, 질문을 던질 수 있는 그래프로 바꿉니다.
미사용 코드, 순환 의존성, 아키텍처 지표, 레이어 규칙은 네 개의 다른 도구가 아니라 하나의 그래프에
던지는 네 가지 질문입니다.

```console
$ cartograph cycles --strict
Sources/Features/Home/HomeCoordinator.swift:14:1: error: Circular dependency: App.Home → App.Session → App.Home
    weakest link: App.Session → App.Home (reference, 2 references)

cycles: 1 error — module graph · 9 nodes · 36 edges
```

---

## 왜 또 만드나

[Periphery](https://github.com/peripheryapp/periphery) 는 Swift 진영 최고의 미사용 코드 탐지기였고,
보관된 소스는 지금도 이 문제에 대한 가장 좋은 문서입니다. 2026년에 상업 제품으로 바뀌었습니다.
Cartograph 는 포크가 아니라, 같은 기계장치를 다르게 규정한 도구입니다.

Periphery 의 한 문장은 *"미사용 선언을 찾는다"* 였고 그래프는 그 목적을 위한 내부 수단이었습니다.
Cartograph 의 한 문장은 *"여기 당신의 의존성 그래프가 있다"* 이고, 데드코드는 그 위의 첫 번째 질의입니다.

| | Periphery (OSS, 보관됨) | Cartograph |
|---|---|---|
| 데드코드 | ✅ 제품 그 자체 | ✅ 표식된 뿌리로부터의 도달 가능성 |
| 왜 살아남았나? | 답할 수 없음 | `dead --explain` 이 근거나 경로를 알려 줌 |
| 순환 의존성 | — | ✅ 끊을 후보 간선까지 |
| 아키텍처 지표 | — | ✅ Ca, Ce, 불안정도, 추상도, 주계열 거리 |
| CI 에서 레이어 규칙 강제 | — | ✅ YAML 로 쓰는 ArchUnit 방식 규칙 |
| 그래프 내보내기 | — | ✅ DOT, Mermaid, JSON, 단일 HTML |
| SARIF (code scanning) | — | ✅ |
| `@objc` 기본 보존 | ❌ 옵트인 | ✅ 기본 켜짐 |

"안 쓰는 것처럼 보이지만 지우면 안 되는" 목록 — 이 문제에서 진짜 어렵게 얻어진 지식 — 은
그대로 흡수했습니다. [보존 규칙](#보존-규칙)을 보세요.

## 설치

macOS 14 이상, Swift 6.4 툴체인(Xcode 27)이 필요합니다.

```bash
git clone https://github.com/coden/cartograph
cd cartograph
swift build -c release
cp .build/release/cartograph /usr/local/bin/
```

## 빠른 시작

Cartograph 는 빌드를 대신 돌리지 않습니다. 컴파일러가 이미 기록한 인덱스를 읽기 때문에 실제로
컴파일된 것과 어긋날 수 없고, DerivedData 를 두고 Xcode 와 다투지도 않습니다.

**Swift Package Manager**

```bash
swift build -Xswiftc -index-store-path -Xswiftc .index-store
cartograph graph --index-store .index-store
```

**Xcode 프로젝트/워크스페이스**

```bash
xcodebuild build -scheme MyApp \
  COMPILER_INDEX_STORE_ENABLE=YES \
  -derivedDataPath DerivedData
cartograph graph --index-store DerivedData/Index.noindex/DataStore
```

`--index-store` 를 생략하면 흔한 위치를 모두 찾습니다. `.build/index/store`,
`.build/debug/index/store`, `.build/out`, `~/Library/Developer/Xcode/DerivedData/<project>-*`.
여러 개가 있으면 가장 최근에 갱신된 것을 씁니다. 오래된 인덱스로 분석하면 결과가 조용히
틀리기 때문입니다.

```bash
cartograph init          # 주석 달린 .cartograph.yml 생성
```

## 명령

### `graph` — 의존성 그래프 내보내기

```bash
cartograph graph --level module --format dot   -o graph.dot
cartograph graph --level type   --format mermaid            # PR 본문에 그대로 붙여넣기
cartograph graph --level symbol --format json  -o graph.json
cartograph graph --level module --format html  -o graph.html
```

해상도는 `module`, `file`, `type`, `symbol` 네 가지입니다. HTML 은 외부 CDN 을 전혀 쓰지 않는
단일 파일이라 폐쇄망에서도 열리고 보안 검토를 통과합니다.

### `cycles` — 순환 의존성 찾기

```bash
cartograph cycles --level module --strict
```

강결합 요소마다 대표 최단 순환 경로를 보여 주고, 참조 횟수가 가장 적은 간선을 끊을 후보로
제시합니다. "이 스무 개가 서로 얽혀 있다"는 사실은 정확하지만 행동으로 옮길 수 없고,
구체적인 순환 하나는 옮길 수 있습니다.

### `dead` — 미사용 선언 찾기

```bash
cartograph dead --report-format xcode
cartograph dead --explain UserRepository
```

데드코드를 *참조 0건*이 아니라 *보존 뿌리에서 도달 불가능*으로 정의합니다. 서로만 참조하는
선언 덩어리는 참조가 많지만 여전히 죽은 코드입니다.

`--explain` 은 Periphery 가 답하지 못하던 질문에 답합니다.

```console
$ cartograph dead --explain HomeViewController
Presentation.HomeViewController is retained because it is connectable from Interface Builder.

$ cartograph dead --explain UserRepository
Data.UserRepository is reachable:
  Presentation.HomeView → Domain.UserService → Data.UserRepository
```

### `metrics` — 아키텍처 지표

```bash
cartograph metrics --level module
```

Robert C. Martin 의 패키지 지표를 당신의 그래프 위에서 계산합니다. 이 저장소에 돌린 결과:

```
NODE                   Ca  Ce     I     A     D           ZONE
---------------------  --  --  ----  ----  ----  -------------
CartographCore          8   0  0.00  0.05  0.95   zone-of-pain
CartographAnalysis      2   1  0.33  0.00  0.67   zone-of-pain
CartographKit           1   5  0.83  0.00  0.17  main-sequence
CartographCLI           0   3  1.00  0.00  0.00  main-sequence
```

`CartographCore` 가 고통의 영역 깊숙이 있는 것은 정직한 결과입니다. 모두가 의존하는 구체적인
도메인 모델이기 때문입니다. 지표는 따라야 할 규칙이 아니라 답해야 할 질문입니다.

### `rules` — CI 에서 아키텍처 강제

```yaml
# .cartograph.yml
layers:
  - name: Presentation
    match: ["Features/**", "*ViewController"]
  - name: Domain
    match: ["Domain/**"]
  - name: Data
    match: ["Data/**", "*Repository"]

rules:
  - name: 프레젠테이션은 데이터 계층에 직접 접근하지 않는다
    from: Presentation
    deny: [Data]
  - from: Domain
    allow: []          # 도메인 계층은 아무것에도 의존하지 않는다
```

레이어는 정점 이름·모듈명·파일 경로를 모두 후보로 판정합니다. 팀마다 레이어를 디렉터리로
정의하기도 하고 이름 규칙으로 정의하기도 하기 때문입니다. 어느 레이어에도 속하지 않는 정점은
`info` 로 보고합니다. 규칙이 무엇을 덮지 못하는지 모르면 "통과"라는 결과를 믿을 수 없습니다.

### `baseline` — 기존 코드베이스에 도입하기

```bash
cartograph baseline --write .cartograph-baseline.json
```

오늘의 문제를 기록해 *새로 생긴* 것만 빌드를 실패시킵니다. 지문은 USR 기반이라 코드를 파일 안에서
위아래로 옮겨도 억제된 문제가 되살아나지 않습니다.

## 설정

프로젝트 루트의 `.cartograph.yml` 입니다. `cartograph init` 으로 주석 달린 템플릿을 만드세요.
커맨드라인 옵션이 언제나 파일보다 우선합니다.

알 수 없는 키는 오류가 아니라 경고로 알립니다. 오타 하나는 무엇이 무시되었는지 알려 줘야지
빌드를 멈춰서는 안 됩니다.

## 보존 규칙

인덱스 스토어에는 컴파일러가 본 것만 기록됩니다. 런타임 셀렉터, 합성된 `Codable`,
Interface Builder 연결, 원시값 열거형의 동적 생성은 전부 보이지 않습니다. 아래 규칙이 그 공백을
메우고, 각 규칙은 *왜* 살렸는지를 함께 남겨 `--explain` 이 답할 수 있게 합니다.

| 보존 대상 | 근거 |
|---|---|
| `@main`, `@UIApplicationMain`, `@NSApplicationMain` 과 그 타입의 `main()` | 진입점 |
| `XCTestCase` 하위 클래스와 인자 없는 `test…()` | XCTest |
| `@Test`, `@Suite` | swift-testing |
| `retain_public` 일 때 `public`/`open` | 공개 API |
| `@objc`, `@objcMembers`(멤버로 전파), Clang `c:` USR | Objective-C 런타임 |
| `@IBOutlet`, `@IBAction`, `@IBInspectable`, `@IBSegueAction` | Interface Builder |
| 원시값 열거형의 케이스 | `init(rawValue:)` 가 동적 |
| `CodingKeys` 케이스 | 합성된 `Codable` |
| `@propertyWrapper` 의 `wrappedValue`, `projectedValue` | 래퍼 규약 |
| `@resultBuilder` 의 `build*` | 빌더 규약 |
| `Codable` 타입의 저장 프로퍼티 | 합성된 인코딩이 참조를 남기지 않음 |
| 분석 범위 밖 선언의 오버라이드·프로토콜 구현 | 프레임워크가 호출 |
| `subscript(dynamicMember:)`, `@_dynamicReplacement`, `dynamic` | 동적 디스패치 |
| 컴파일러 합성 선언 | 지울 수 없음 |
| `// cartograph:ignore`, `// cartograph:ignore:all` | 사용자가 지정 |
| `retained_names`, `retained_files` 글롭 | 사용자가 지정 |

**`retain_objc_accessible` 은 기본 켜짐입니다.** Periphery 는 기본 꺼짐이었고, 그것이 혼합 언어
UIKit 프로젝트에서 거짓 양성의 가장 큰 원인이었습니다. 아무도 믿지 않는 데드코드 도구는 도구가
없는 것보다 나쁩니다.

프로토콜 요구사항은 오버라이드 관계를 역방향으로 따라가 처리합니다. 요구사항이 호출되면 그
구현체 전부가 도달 가능해집니다. 이 규칙 하나가 없으면 프로토콜 뒤의 모든 타입이 죽은 것처럼
보입니다. 실제로 이 도구가 자기 자신을 처음 분석했을 때 그렇게 나왔습니다.

## CI

종료 코드로 "코드에 문제가 있음"과 "도구가 못 돌았음"을 구분할 수 있습니다.

| 코드 | 의미 |
|---|---|
| `0` | 정상 |
| `1` | `--strict` 상태에서 문제 발견, 또는 설정한 임계값 초과 |
| `2` | 도구 실패 — 인덱스 스토어 없음, 읽기 실패, 설정 오류 |
| `64` | 사용 오류 — 알 수 없는 옵션·하위 명령·값 |

```yaml
- run: swift build -Xswiftc -index-store-path -Xswiftc .index-store
- run: cartograph dead   --index-store .index-store --strict --report-format github-actions
- run: cartograph cycles --index-store .index-store --strict
- run: cartograph rules  --index-store .index-store --strict
```

## 구조

의존은 한 방향으로만 흐릅니다.

```
CartographCore  ←  Config · Syntax · Analysis · Export · IndexStore  ←  Kit  ←  CLI
```

도메인과 알고리즘 계층은 IndexStoreDB 가 존재한다는 사실조차 모릅니다. 그래서 픽스처 Xcode
프로젝트 하나 없이도 90% 커버리지 게이트를 지킬 수 있습니다. 분석은 손으로 만든 스냅샷 위에서
돌아갑니다.

`CartographKit` 은 공개 라이브러리 제품이라 CLI 를 호출하는 대신 파이프라인을 직접 임베드할 수
있습니다. 질의 API 는 렌더링된 텍스트가 아니라 값을 돌려줍니다.

```swift
import CartographKit

let service = CartographService(configuration: configuration)
let context = try service.loadContext()          // 인덱스를 한 번만 읽는다

let (graph, cycles) = service.cycles(in: context)
let (_, unused) = service.unusedCode(in: context)
let (_, metrics, _) = service.metrics(in: context)
```

베이스라인·임계값·출력 형식은 CI 정책이라 별도의 명령 API(`detectCycles()` 등)에 있습니다.
프로그램에서 호출하는 쪽이 표를 파싱할 일은 없습니다.

## 프로젝트 언어

문서와 사용자에게 보이는 출력은 영어, 소스 주석은 메인테이너의 작업 언어인 한국어,
식별자는 항상 영어입니다. PR 은 두 언어 중 아무거나 써도 됩니다.

## 기여

[CONTRIBUTING.md](CONTRIBUTING.md) 를 보세요. 이 저장소에서 작업하는 에이전트는
[AGENTS.md](AGENTS.md) 를 먼저 읽어야 합니다.

## 라이선스

MIT. [LICENSE](LICENSE) 를 보세요.

Cartograph 는 독립 프로젝트이며 Periphery 나 Apple 과 관련이 없습니다.
