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
보관된 소스는 지금도 이 문제를 가장 잘 설명한 자료입니다. 오픈소스 저장소는 MIT 상태로 보관되었고,
개발은 [상용 제품](https://periphery.pro)으로 이어지고 있습니다. 개인·취미 프로젝트와 규모를 가리지
않는 오픈소스에는 무료이므로, 필요한 것이 미사용 코드뿐이라면 그쪽을 쓰세요. Cartograph는 포크도,
무료 대체품도 아닙니다. 같은 재료를 쓰되 목적을 다르게 잡았습니다.

Periphery를 한 문장으로 줄이면 *"미사용 선언을 찾는다"*였고, 그래프는 그 목적을 이루기 위한 내부 수단이었습니다.
Cartograph를 한 문장으로 줄이면 *"의존성 그래프를 내놓는다"*이고, 미사용 코드는 그 위에 던지는 첫 번째 질문입니다.

| | Periphery (보관된 OSS) | Cartograph |
|---|---|---|
| 미사용 코드 | ✅ 이것이 곧 제품 | ✅ 보존 루트에서 도달 가능 여부로 판정 |
| 왜 살아남았나? | 답할 수 없음 | `dead --explain`이 근거와 경로를 알려 줌 |
| 순환 의존성 | — | ✅ 끊을 후보 간선까지 |
| 아키텍처 지표 | — | ✅ Ca, Ce, 불안정도, 추상도, 주계열 거리 |
| CI에서 레이어 규칙 강제 | — | ✅ YAML로 쓰는 ArchUnit 방식 규칙 |
| 이 심볼을 누가 쓰나? | 답할 수 없음 | `query`가 양방향을 JSON으로 답함 |
| Dart·JavaScript 쪽 호출자 | 보이지 않음 | `bridges`가 플랫폼 채널의 Swift 쪽을 내보내고 `--external-retentions`가 조인 결과를 읽어 옴 |
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
mint install ictechgy/cartograph@0.4.0
```

**설치 없이 쓰기** — Swift 패키지라면 의존성으로 넣고 커맨드 플러그인을 쓰면 됩니다.
팀원과 CI가 같은 버전을 쓰게 됩니다.

```swift
// Package.swift
.package(url: "https://github.com/ictechgy/cartograph", from: "0.4.0"),
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

`--report-test-only`는 다른 질문에 답합니다. 테스트나 프리뷰**에서만** 도달하는 생산 선언이
무엇인가입니다. 죽은 코드가 아닙니다. 지우면 테스트가 깨집니다. 다만 테스트가 유일한
호출자라는 사실은 팀이 알아야 합니다. `info`로 보고하므로 빌드를 실패시키지 않습니다.

```console
$ cartograph dead --report-test-only
Sources/Models/Policy.swift:31:9: info: property 'App.isDenied' is reached only from tests or previews
```

테스트 타깃 안의 선언은 제외합니다. *테스트* 선언이 들어 있는 모듈은 테스트 타깃이고, 그
안의 도우미는 이 질문의 답이 아니기 때문입니다. 프리뷰는 이 판정에 넣지 않습니다. `#Preview`
는 미리 보는 뷰와 같은 생산 모듈에 살기 때문에, 그것을 표식으로 삼으면 앱 모듈 전체가
분석에서 빠집니다.

`--explain`은 Periphery가 답하지 못하던 질문에 답합니다.

```console
$ cartograph dead --explain HomeViewController
Presentation.HomeViewController is retained because it is connectable from Interface Builder.

$ cartograph dead --explain UserRepository
Data.UserRepository is reachable:
  Presentation.HomeView → Domain.UserService → Data.UserRepository
```

### `query` — 선언 하나에 대해 되묻기

```bash
cartograph query UserService
cartograph query 's:3App11UserServiceC' --depth 2 --limit 20
```

심볼 하나에 대한 세 가지 질문 — 누가 쓰는가, 무엇을 쓰는가, 보존 루트에서 도달 가능한가 —
을 표준 출력에 JSON으로 답한다. 다른 명령이 프로젝트 전체를 훑어 문제를 보고하는 것과 달리,
이 명령은 이미 갖고 있는 질문에 답한다.

```console
$ cartograph query UserService
{
  "level" : "symbol",
  "limitations" : [
    "objective-c-sources: 12 file(s) are not analysed, so a Swift declaration used only from Objective-C looks unreached",
    "index-staleness: 3 of 214 source file(s) changed after the index store was written, so a call added since the last build is not here yet",
    "single-configuration: the index store knows only the configuration that was built, ..."
  ],
  "requested" : "UserService",
  "result" : {
    "dependsOn" : [
      { "qualifiedName" : "Data.UserRepository", "module" : "Data", "kind" : "class",
        "edges" : [ "call", "reference" ], "depth" : 1, ... }
    ],
    "members" : [
      { "qualifiedName" : "Domain.fetch(id:)", "edges" : [ "member" ], "depth" : 1, ... }
    ],
    "reachability" : {
      "path" : [ "Presentation.HomeView", "Domain.UserService" ],
      "state" : "reachable",
      "suppressedByBaseline" : false
    },
    "truncated" : { "dependsOn" : false, "members" : false, "usedBy" : false },
    "usedBy" : [
      { "qualifiedName" : "Presentation.HomeView", "module" : "Presentation", "kind" : "struct",
        "edges" : [ "call" ], "depth" : 1, ... }
    ]
  },
  "status" : "found"
}
```

이 출력이 일부러 지키는 다섯 가지가 있다.

- **지워도 된다고 말하지 않는다.** `state`는 그래프에 대한 사실이다 — `retained`,
  `retainedByMember`, `reachable`, `unreachable`. 그것이 삭제해도 된다는 뜻인지는 판단이고,
  보존 근거는 값으로 준다(`"reason": "interfaceBuilder"`). 판단은 받는 쪽의 몫이다.
- **모든 답에 이 분석이 보지 못한 채널을 싣는다.** `notFound`에도 싣는다. Objective-C로
  선언된 이름을 물었는데 "그런 것 없다"는 답만 받으면, 없는 것과 이 도구가 못 보는 것을
  구분할 수 없다. `limitations`는 문서의 일반론이 아니라 **당신의 프로젝트를** 그래프와
  같은 include/exclude 범위 안에서 세어 만든다. 알릴 것이 없으면 조용하다. Objective-C 소스,
  Interface Builder 문서, 마지막 빌드 뒤에 바뀐 소스, 그리고 `usedBy`가 빈 이유일 수도 있는
  경로·간선 필터 설정을 알린다.
- **팀이 이미 받아들인 베이스라인은 그렇다고 표시한다**(`suppressedByBaseline`). 팀이 알고
  남겨 둔 것을 다시 심사하지 않게 한다. 실제로 보고되었을 선언에만 표시가 붙는다.
- **이웃에 닿는 관계를 하나만 고르지 않고 전부 준다.** 호출하면서 동시에 오버라이드하는
  서브클래스는 `"edges": ["call", "overrides"]`로 온다. 하나만 보고하면 절반만 보고 지우게 된다.
- **이름이 여럿에 걸리면 하나를 고르지 않고 후보를 돌려준다.** USR로 다시 물으면 된다.

```console
$ cartograph query Client
{
  "candidates" : [
    { "qualifiedName" : "Network.Client", "usr" : "s:7Network6ClientC" },
    { "qualifiedName" : "Storage.Client", "usr" : "s:7Storage6ClientC" }
  ],
  "level" : "symbol",
  "limitations" : [ ... ],
  "requested" : "Client",
  "status" : "ambiguous"
}
```

`members`와 `declaredIn`은 담는 관계다. 쓰는 관계가 아니다. 심볼 레벨 그래프에서 타입의
의존은 전부 멤버가 들고 있으므로, 클래스의 `dependsOn`이 비어 있는 것은 정상이고 "아무것도
의존하지 않는다"는 뜻이 아니다. `members`를 따라가면 된다.

`--depth`는 각 방향으로 간선을 몇 개까지 따라갈지, `--limit`은 이웃을 몇 개까지 담을지 정한다.
이웃마다 붙은 `depth`가 몇 걸음 떨어져 있는지 알려 주고, 제한에 걸리면 `truncated`가 알려 준다.
도달성은 `--level` 설정과 무관하게 항상 심볼 레벨 그래프에서 계산하며, 그래서 응답에 `level`이
들어 있다. 이웃의 `location`은 그 이웃이 **선언된** 자리이지 대상을 쓰는 자리가 아니다. 값이 없는 필드는 `null`이 아니라 키 자체가 빠진다. 최상위
선언의 `declaredIn`, 보존되지 않은 선언의 `reason`, 도달하지 않은 선언의 `path`, 그리고
`status`에 따라 `result` 또는 `candidates`가 그렇다.

없는 이름을 물으면 종료 코드 64로 끝난다. 스크립트의 오타가 "아무도 안 씀"으로 조용히
넘어가지 않게 하기 위해서다.

### `bridges` — 언어 경계의 Swift 쪽 내보내기

```bash
cartograph bridges                       # bridge-facts JSON 을 표준 출력으로
cartograph bridges --format text         # 사실마다 한 줄, 훑어보기용
cartograph dead --external-retentions .isthmus/retentions.cartograph.json
```

Flutter 메서드 채널 핸들러나 React Native 모듈은 Dart 나 JavaScript 가 부릅니다. 컴파일러 인덱스는
그것을 보지 못하므로 도달 불가로 보고합니다. 두 쪽을 잇는 유일한 끈은 문자열입니다.
`FlutterMethodChannel(name:)` 의 채널 이름, 핸들러 안의 `case "takePhoto":`, 클래스의
`@objc(CalendarManager)`, `.m` 파일의 `RCT_EXPORT_METHOD(addEvent:)`. `bridges` 는 그 리터럴을
SwiftSyntax 로(Objective-C 는 텍스트로) 소스에서 읽고, 감싸는 선언의 USR 을 인덱스에서 붙여,
[isthmus](../isthmus) 가 다른 플랫폼의 사실과 조인하는 `bridge-facts` 교환 형식으로 씁니다.

```console
$ cartograph bridges
{
  "facts" : [
    {
      "channel" : "com.example/camera",
      "dynamic" : false,
      "kind" : "method-handle",
      "location" : { "column" : 18, "line" : 26, "path" : "/app/ios/CameraPlugin.swift" },
      "method" : "takePhoto",
      "symbol" : { "qualifiedName" : "App.handle(_:result:)", "usr" : "s:3App12CameraPlugin…" }
    }
  ],
  "format" : "bridge-facts",
  "generatedAt" : "2026-09-04T00:00:00Z",
  "limitations" : [ ],
  "platform" : "swift",
  "project" : "/app/ios",
  "target" : "flutter",
  "tool" : { "name" : "cartograph", "version" : "0.5.0" },
  "version" : 0
}
```

판정이 아니라 사실을 냅니다. 반대쪽에서 실제로 핸들러를 부르는지는 모릅니다. 리터럴이 아닌
이름은 버리지 않고 원문 표현식과 `dynamic: true` 로 남겨, 소비자가 조인하지 못한 수를 셀 수 있게
합니다. 상수는 한 단계만 따라갑니다(`static let name = "…"` 을 `FlutterMethodChannel(name: Self.name)`
에 쓰는 경우). 그보다 깊으면 `dynamic` 입니다. 핸들러 클로저 밖의 `case "…"` 는 파일에 채널이
정확히 하나일 때 그 채널에 붙고, 아니면 `null` 입니다. `limitations` 에는 동적 이름의 수,
채널을 못 정한 핸들의 수, USR 이 없는 사실의 수(Objective-C 소스, 또는 빌드 뒤 편집된 Swift),
Flutter 와 React Native 가 섞인 프로젝트를 셉니다.

isthmus 는 `external-retentions` 를 돌려줍니다. 호출자를 찾은 Swift 선언마다 USR 과 근거입니다.
`--external-retentions <경로>`(또는 설정의 `external_retentions_path`)는 각각을 이유가
`externalBridge` 인 보존 루트로 만들고, `--explain` 은 파일을 가리키는 대신 근거를 문장으로 인용합니다.

```console
$ cartograph dead --external-retentions .isthmus/retentions.cartograph.json --explain CameraPlugin
App.CameraPlugin is retained because its member App.init(messenger:) is called from another platform across a bridge, per the external retentions file.
  evidence: dart lib/camera.dart:42 invokes 'takePhoto' on channel 'com.example/camera'
```

지정했는데 없는 파일은 조용히 넘어가지 않고 도구 실패(종료 코드 2)입니다. 파일을 준 사람은 그것이
반영되기를 기대합니다. `query` 는 `limitations` 에 파일의 출처와, 인덱스의 어느 선언과도 맞지 않는
근거의 수를 싣습니다. 이름을 바꾼 핸들러는 버그가 되기 전에 거기서 먼저 드러납니다.

### `skill` — 코딩 에이전트에게 이 도구 쓰는 법 설치하기

```bash
cartograph skill
```

프로젝트에 `.claude/skills/cartograph/SKILL.md`를 쓴다. 먼저 읽어 보고 싶으면 저장소의
[`Skills/cartograph/SKILL.md`](Skills/cartograph/SKILL.md)에 같은 파일이 있다. 둘이 갈라지면
테스트가 실패하므로, 사람이 검토한 것과 에이전트가 실제로 받는 것이 다를 수 없다.
`--project ~`로 설치하면 한 프로젝트가 아니라 전체에 적용된다.

이 문서의 대부분은 어떤 명령을 실행하라는 내용이 아니다. 에이전트는 판정을 망설임 없이
편집으로 옮기기 때문에, 답이 **증명하지 않는 것**에 분량을 쓴다. `unreachable`은 그래프에 대한
사실이지 삭제 허가가 아니라는 것, `limitations`를 같은 호흡에 읽어야 한다는 것,
`suppressedByBaseline`은 팀이 이미 내린 결정이라는 것, 그리고 `graph --format json`을 통째로
컨텍스트에 밀어 넣어 봐야 `query`로 답할 수 없는 질문에 답하지 못한다는 것.

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
| `--external-retentions` 가 지목한 선언 | 다른 플랫폼이 브리지를 넘어 호출. `--explain` 이 근거를 인용 |

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
- **Objective-C 소스는 분석하지 않습니다.** `.m`/`.h`는 그래프에 보이지 않으며, 그쪽에서 참조되는 Swift
  선언은 기본값이 켜진 `retain_objc_accessible`이 덮습니다. `bridges` 는 `.m` 을 읽지만 React Native
  내보내기 매크로만 텍스트로 봅니다.
- **다른 언어의 호출자는 isthmus 를 통해서만 압니다.** `bridges` 는 Swift 가 선언한 것을 내보낼 뿐이고,
  Dart 나 JavaScript 가 실제로 부르는지는 이 도구가 하지 않는 조인입니다.
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
