# Cartograph

**질문을 던질 수 있는 Swift·iOS 의존성 그래프.**

[English](README.md)

Cartograph는 컴파일러가 이미 만들어 둔 인덱스 스토어를 읽어 하나의 그래프로 바꿉니다.
미사용 코드, 순환 의존성, 아키텍처 지표, 레이어 규칙은 네 개의 다른 도구가 아니라 하나의 그래프에
던지는 네 가지 질문입니다.

```console
$ cartograph cycles --strict
Sources/Features/Home/HomeCoordinator.swift:14:1: error: Circular dependency: App.Home → App.Session → App.Home
    weakest link: App.Session → App.Home (reference, 2 references)

cycles: 1 error — module graph · 9 nodes · 36 edges
```

---

## 왜 새로 만들었나

[Periphery](https://github.com/peripheryapp/periphery)는 Swift 진영 최고의 미사용 코드 탐지기였고,
보관된 소스는 지금도 이 문제를 가장 잘 설명한 자료입니다. 2026년에 상업 제품으로 바뀌었습니다.
Cartograph는 Periphery의 포크가 아닙니다. 같은 재료를 쓰되 목적을 다르게 잡았습니다.

Periphery를 한 문장으로 줄이면 *"미사용 선언을 찾는다"*였고, 그래프는 그 목적을 이루기 위한 내부 수단이었습니다.
Cartograph를 한 문장으로 줄이면 *"의존성 그래프를 내놓는다"*이고, 미사용 코드는 그 위에 던지는 첫 번째 질문입니다.

| | Periphery (OSS, 보관됨) | Cartograph |
|---|---|---|
| 미사용 코드 | ✅ 이것이 곧 제품 | ✅ 보존 루트에서 도달 가능 여부로 판정 |
| 왜 살아남았나? | 답할 수 없음 | `dead --explain`이 근거와 경로를 알려 줌 |
| 순환 의존성 | — | ✅ 끊을 후보 간선까지 |
| 아키텍처 지표 | — | ✅ Ca, Ce, 불안정도, 추상도, 주계열 거리 |
| CI에서 레이어 규칙 강제 | — | ✅ YAML로 쓰는 ArchUnit 방식 규칙 |
| 그래프 내보내기 | — | ✅ DOT, Mermaid, JSON, 단일 HTML |
| SARIF (code scanning) | — | ✅ |
| `@objc` 기본 보존 | ❌ 옵트인 | ✅ 기본 켜짐 |

"안 쓰는 것처럼 보이지만 지우면 안 되는" 목록은 그대로 가져왔습니다. 이 문제를 오래 다뤄 봐야
알게 되는 것들입니다. [보존 규칙](#보존-규칙)을 보세요.

## 설치

macOS 14 이상이 필요합니다. 실행할 때는 Swift 툴체인(Xcode 또는 Command Line Tools)이 있어야 합니다.
`libIndexStore`를 거기서 불러오기 때문입니다. CI는 Swift 6.3.3, 개발은 6.4에서 돌아갑니다.

**Homebrew** — 미리 빌드된 유니버설 바이너리이며, 수 초면 끝납니다.

```bash
brew install ictechgy/tap/cartograph
```

**Mint** — tap 추가 없이 소스에서 빌드합니다.

```bash
mint install ictechgy/cartograph@0.2.0
```

**설치 없이 쓰기** — Swift 패키지라면 의존성으로 넣고 커맨드 플러그인을 쓰면 됩니다.
팀원과 CI가 같은 버전을 쓰게 됩니다.

```swift
// Package.swift
.package(url: "https://github.com/ictechgy/cartograph", from: "0.2.0"),
```

```bash
swift package cartograph dead --strict
swift package cartograph graph --format mermaid > graph.mmd
```

플러그인은 쓰기 권한을 선언하지 않아 승인 절차가 없습니다. 결과를 파일로 남기려면
리다이렉션을 쓰세요.

**소스에서 빌드:**

```bash
git clone https://github.com/ictechgy/cartograph
cd cartograph
swift build -c release
cp "$(swift build -c release --show-bin-path)/cartograph" /usr/local/bin/
```

## 빠른 시작

Cartograph는 빌드를 대신 돌리지 않습니다. 컴파일러가 이미 기록한 인덱스를 읽기 때문에 실제로
컴파일된 것과 어긋날 수 없고, DerivedData를 놓고 Xcode와 충돌하지도 않습니다.

**Swift Package Manager**

```bash
swift build          # SwiftPM이 부산물로 인덱스 스토어를 남깁니다
cartograph graph     # 자동으로 찾습니다
```

> `-Xswiftc -index-store-path`는 SwiftPM의 native 빌드 시스템에서만 동작합니다. Swift 6.4부터
> 기본이 된 Xcode 기반 빌드 시스템은 이 플래그를 **무시**하고 `<스크래치 경로>/out`에 인덱스를 남깁니다.
> 자동 탐색에 맡기거나 `--index-store .build/out`을 쓰세요.

**Xcode 프로젝트/워크스페이스**

```bash
xcodebuild build -scheme MyApp \
  COMPILER_INDEX_STORE_ENABLE=YES \
  -derivedDataPath DerivedData
cartograph graph --index-store DerivedData/Index.noindex/DataStore
```

`--index-store`를 생략하면 흔한 위치를 모두 찾습니다. `.build/index/store`,
`.build/debug/index/store`, `.build/out`, `~/Library/Developer/Xcode/DerivedData/<project>-*`.
여러 개가 있으면 가장 최근에 갱신된 것을 씁니다. 오래된 인덱스로 분석하면 결과가 조용히
틀리기 때문입니다. 최근 SwiftPM은 인덱스를 자동으로 남기므로, Swift 패키지라면
`cartograph graph`만으로도 대개 동작합니다.

> **인덱스는 무언가 컴파일될 때만 만들어집니다.** 이미 최신인 패키지를 빌드하면 새 인덱스
> 데이터가 생기지 않습니다. CI에서는 새 체크아웃이라 항상 컴파일되므로 문제가 없습니다.
>
> **인덱스 스토어에는 낡은 유닛이 남습니다.** 파일을 옮기거나 지워도 예전 기록이 남아, 지운
> 타입이 유령 정점으로 보일 수 있습니다. 결과가 말이 안 될 때는 새 스크래치 경로로
> 빌드하세요(`swift build --scratch-path .build-fresh`).

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

레벨은 `module`, `file`, `type`, `symbol` 네 가지입니다. HTML은 외부 CDN을 전혀 쓰지 않는
단일 파일이라 폐쇄망에서도 열리고 보안 검토를 통과합니다.

### `cycles` — 순환 의존성 찾기

```bash
cartograph cycles --level module --strict
```

`--explain <노드>` 는 그다음 질문에 답합니다. 이 정점이 어떤 순환에 끼어 있고 각각을
어디서 끊어야 하는지입니다.

```console
$ cartograph cycles --level type --explain Alpha
App.Alpha is part of 1 cycle(s):
  App.Beta → App.Gamma → App.Alpha → App.Beta
      weakest link: App.Gamma → App.Alpha (call, 1 references)
```

강한 연결 요소마다 그중 가장 짧은 순환을 대표로 보여 주고, 참조 횟수가 가장 적은 간선을 끊을 후보로
제시합니다. "이 스무 개가 서로 얽혀 있다"는 말은 정확하지만 어디부터 손대야 할지는 알려 주지
않습니다. 구체적인 순환 하나는 알려 줍니다.

`--explain <노드>` 는 그다음 질문에 답합니다. 이 정점이 어떤 순환에 끼어 있고 각각을 어디서
끊어야 하는지입니다.

```console
$ cartograph cycles --level type --explain Alpha
App.Alpha is part of 1 cycle(s):
  App.Beta → App.Gamma → App.Alpha → App.Beta
      weakest link: App.Gamma → App.Alpha (call, 1 references)
```

### `dead` — 미사용 선언 찾기

```bash
cartograph dead --report-format xcode
cartograph dead --explain UserRepository
```

미사용 코드를 *참조 0건*이 아니라 *보존 루트에서 도달할 수 없음*으로 정의합니다. 서로만 참조하는
선언 덩어리는 참조가 많지만 여전히 죽은 코드입니다.

`--explain`은 Periphery가 답하지 못하던 질문에 답합니다.

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

Robert C. Martin의 패키지 지표를 이 그래프 위에서 계산합니다. 이 저장소에서 돌린 결과:

```
NODE                   Ca  Ce     I     A     D           ZONE
---------------------  --  --  ----  ----  ----  -------------
CartographCore          8   0  0.00  0.05  0.95   zone-of-pain
CartographAnalysis      2   1  0.33  0.00  0.67   zone-of-pain
CartographKit           1   5  0.83  0.00  0.17  main-sequence
cartograph              0   3  1.00  0.00  0.00  main-sequence
```

`CartographCore`가 zone-of-pain 깊숙이 자리한 것은 예상대로입니다. 모두가 의존하는 구체적인
도메인 모델이기 때문입니다. 지표는 따라야 할 규칙이 아니라 답해야 할 질문입니다.

### `rules` — CI에서 아키텍처 강제

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

레이어 판정은 정점 이름·모듈 이름·파일 경로를 모두 대상으로 삼습니다. 팀마다 레이어를 디렉터리로
정의하기도 하고 이름 규칙으로 정의하기도 하기 때문입니다. 어느 레이어에도 속하지 않는 정점은
`info`로 보고합니다. 규칙이 무엇을 덮지 못하는지 모르면 "통과"라는 결과를 믿을 수 없습니다.

`--explain <노드>` 는 그 정점이 어느 레이어에 들어갔는지, 어느 패턴이 그렇게 만들었는지,
그 레이어에서 출발하는 규칙이 무엇인지 보여 줍니다. 설정을 디버깅할 때 실제로 던지는
질문들입니다.

```console
$ cartograph rules --explain CartographKit
CartographKit is in layer 'Assembly'.
  matched: CartographKit against 'CartographKit'
  rules from 'Assembly':
    조립 계층은 인터페이스를 알지 못한다
```

### `baseline` — 기존 코드베이스에 도입하기

```bash
cartograph baseline --write .cartograph-baseline.json
```

지금 있는 문제를 기록해 두고 *새로 생긴* 것만 빌드를 실패시킵니다. 기록해 둔 문제의 지문(fingerprint)은 USR 기반이라, 코드를 파일 안에서 위아래로 옮겨도
억제한 문제가 되살아나지 않습니다.

### `--since` — 이번 PR 이 건드린 자리만 보기

```bash
cartograph dead --since origin/main --strict
```

주어진 git 기준점 이후 바뀐 파일**에 위치한** 발견만 보고합니다. 커밋된 변경, 추적 파일의
미커밋 변경, 아직 추가하지 않은 새 파일을 모두 포함합니다. 그래프는 여전히 프로젝트 전체로
만듭니다. 좁힌 그래프에서 나온 도달성 판정은 그냥 틀린 값이기 때문입니다. 좁히는 것은
보고뿐입니다.

이것은 "이번 변경이 무엇을 건드렸나"에 답하지, "이번 변경이 무엇을 만들었나"에 답하지
않습니다. 건드리지 않은 파일에 선언된 심볼의 마지막 호출을 이번 커밋이 지웠다면 그 심볼은
죽지만, 발견의 위치는 건드리지 않은 파일이라 보고되지 않습니다. 그 경우는 다음 전체 실행에서
베이스라인이 잡습니다. `--since` 는 렌즈이지 증명이 아닙니다. 그래서 `baseline` 은 `--since`
를 거부합니다. 일부만 기록해 두면 나중에 범위 밖 부채가 전부 신규로 보이기 때문입니다.

`baseline` 과 `--since` 는 다른 질문에 답하며 함께 쓸 수 있습니다. 베이스라인은 오늘의 빚이
늘지 않게 하는 CI 래칫이고, `--since` 는 PR 을 보는 렌즈입니다. CI 에서는 전체 이력을
받아야 합니다(`fetch-depth: 0`). 그러지 않으면 기준점을 찾지 못합니다.

## 설정

프로젝트 루트의 `.cartograph.yml`입니다. `cartograph init`으로 주석 달린 템플릿을 만드세요.
커맨드라인 옵션이 언제나 파일보다 우선합니다.

모르는 키는 오류 대신 경고로 알립니다. 오타 하나 때문에 빌드가 멈춰서는 안 되지만, 무엇이
무시됐는지는 알려 줘야 하기 때문입니다.

## 보존 규칙

인덱스 스토어에는 컴파일러가 본 것만 기록됩니다. 런타임 셀렉터, 합성된 `Codable`,
Interface Builder 연결, 원시값 열거형의 동적 생성은 전부 보이지 않습니다. 아래 규칙이 그 공백을 메웁니다.
각 규칙은 *왜* 살렸는지를 함께 남기므로 `--explain`이 답할 수 있습니다.

| 보존 대상 | 근거 |
|---|---|
| `@main`, `@UIApplicationMain`, `@NSApplicationMain`과 그 타입의 `main()` | 진입점 |
| `XCTestCase` 하위 클래스와 인자 없는 `test…()` | XCTest |
| `@Test`, `@Suite` | swift-testing |
| `retain_public`일 때 `public`/`open` | 공개 API |
| `@objc`, `@objcMembers`(멤버로 전파), Clang `c:` USR | Objective-C 런타임 |
| `@IBOutlet`, `@IBAction`, `@IBInspectable`, `@IBSegueAction` | Interface Builder |
| `.xib`/`.storyboard`의 `customClass`로 지정된 타입 | Interface Builder만 참조 |
| 원시값 열거형의 케이스 | `init(rawValue:)`가 동적 |
| `CodingKeys` 케이스 | 합성된 `Codable` |
| `@propertyWrapper`의 `wrappedValue`, `projectedValue` | 래퍼 규약 |
| `@resultBuilder`의 `build*` | 빌더 규약 |
| `Codable` 타입의 저장 프로퍼티 | 합성된 인코딩이 참조를 남기지 않음 |
| 분석 범위 밖 선언의 오버라이드·프로토콜 구현 | 프레임워크가 호출 |
| `subscript(dynamicMember:)`, `@_dynamicReplacement`, `dynamic` | 동적 디스패치 |
| 컴파일러 합성 선언 | 지울 수 없음 |
| `// cartograph:ignore`, `// cartograph:ignore:all` | 사용자가 지정 |
| `retained_names`, `retained_files` 글롭 | 사용자가 지정 |

**`retain_objc_accessible`은 기본값으로 켜져 있습니다.** Periphery는 기본값이 꺼져 있었고, 그것이 혼합 언어
UIKit 프로젝트에서 오탐(거짓 양성)의 가장 큰 원인이었습니다. 아무도 믿지 않는 미사용 코드 탐지기는
아예 없는 것보다 나쁩니다.

프로토콜 요구사항은 오버라이드 관계를 역방향으로 따라가며 처리합니다. 요구사항이 호출되면 그
구현체가 도달 가능해지는데, 구현체를 소유한 타입이 살아 있을 때만 그렇습니다. 한 번도
만들어지지 않는 타입의 구현이 호출하는 것까지 되살리면 미사용 코드가 경고 없이 숨어 버립니다.
앞의 "요구사항이 호출되면" 조건이 없으면 프로토콜 뒤의 타입이 전부 죽은 것처럼 보입니다.
뒤의 "타입이 살아 있을 때만" 조건이 없으면 죽은 코드가 실제로 쓰이지 않는 프로토콜 준수 뒤에
숨어 버립니다. 둘 다 이 도구로 이 저장소를 분석하는 과정(도그푸딩)과 외부 리뷰에서 드러났습니다.

### 알려진 한계

- **`#Preview` 매크로 본문.** `#Preview` 안에서만 쓰이는 타입은 매크로 확장 시 컴파일러가
  참조를 남긴 경우에만 보존됩니다. `PreviewProvider` 준수는 직접 인식하지만 `#Preview` 매크로는 그렇지 않습니다.
- **Interface Builder 연결을 개별로 대조하지 않습니다.** `retain_interface_builder`가 켜져 있으면
  실제 연결 여부와 무관하게 모든 `@IBOutlet`·`@IBAction`을 보존하므로, 연결이 끊긴 아웃렛은
  보고되지 않습니다. 커스텀 클래스는 이름으로 대조합니다.
- **Objective-C 소스는 분석하지 않습니다.** `.m`/`.h`는 보이지 않으며, 그쪽에서 참조되는 Swift
  선언은 기본값이 켜진 `retain_objc_accessible`이 덮습니다.
- **컴파일되지 않은 `#if` 분기는 존재하지 않습니다.** 인덱스 스토어는 실제로 빌드한 구성만 압니다.

## CI

종료 코드로 "코드에 문제가 있음"과 "도구가 실패했음"을 구분할 수 있습니다.

| 코드 | 의미 |
|---|---|
| `0` | 정상 |
| `1` | `--strict` 상태에서 문제 발견, 또는 설정한 임계값 초과 |
| `2` | 도구 실패 — 인덱스 스토어 없음, 읽기 실패, 설정 오류 |
| `64` | 사용 오류 — 알 수 없는 옵션·하위 명령·값 |

```yaml
- run: swift build
- run: cartograph dead   --strict --report-format github-actions
- run: cartograph cycles --strict
- run: cartograph rules  --strict
```

## 구조

의존은 한 방향으로만 흐릅니다.

```
CartographCore  ←  Config · Syntax · Analysis · Export · IndexStore  ←  Kit  ←  CLI
```

도메인과 알고리즘 계층은 IndexStoreDB가 존재한다는 사실조차 모릅니다. 그래서 픽스처 Xcode
프로젝트 하나 없이도 90% 커버리지 게이트를 지킬 수 있습니다. 분석은 손으로 만든 스냅샷 위에서
돌아갑니다.

`CartographKit`은 공개 라이브러리 제품이라, CLI를 호출하는 대신 파이프라인을 그대로 가져다
쓸 수 있습니다. 질의 API는 렌더링된 텍스트가 아니라 값을 돌려줍니다.

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
식별자는 항상 영어입니다. PR은 두 언어 중 아무거나 써도 됩니다.

## 기여

[CONTRIBUTING.md](CONTRIBUTING.md)를 보세요. 이 저장소에서 작업하는 에이전트는
[AGENTS.md](AGENTS.md)를 먼저 읽어야 합니다.

## 라이선스

MIT. [LICENSE](LICENSE)를 보세요.

Cartograph는 독립 프로젝트이며 Periphery나 Apple과 관련이 없습니다.
