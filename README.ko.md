# Cartograph

**Swift·iOS 코드베이스의 의존성 그래프에 질문을 던지는 도구.**

[English](README.md)

Cartograph는 컴파일러가 이미 만들어 둔 인덱스 스토어를 읽어, 질문을 던질 수 있는 그래프로
바꿉니다. 미사용 코드, 순환 의존성, 아키텍처 지표, 레이어 규칙은 네 개의 다른 도구가 아니라
하나의 그래프에 던지는 네 가지 질의입니다.

```console
$ cartograph cycles --strict
Sources/Features/Home/HomeCoordinator.swift:14:1: error: Circular dependency: App.Home → App.Session → App.Home
    weakest link: App.Session → App.Home (reference, 2 references)

cycles: 1 error — module graph · 9 nodes · 36 edges
```

---

## 왜 새로 만들었나

[Periphery](https://github.com/peripheryapp/periphery)는 Swift 진영 최고의 미사용 코드
탐지기였고, 아카이브된 소스는 지금도 이 문제를 가장 잘 설명한 자료입니다. 그 저장소는 MIT
라이선스로 공개된 채 보관되어 있으며, 현재 개발은 별도의 [상용 제품](https://periphery.pro)이
자체 약관으로 이어가고 있습니다. Cartograph는 MIT 라이선스이며, 상용 프로젝트를 포함해
유료 라이선스나 계정이 필요 없습니다. Cartograph는 Periphery의 포크도 아니고, 기능 대
기능으로 대응하는 무료판을 표방하지도 않습니다 — 컴파일러 그래프로 더 넓은 질문에 답하는
도구입니다.

Periphery의 제품 문장은 *"미사용 선언을 찾는다"*였고, 그래프는 그 목적을 위한 내부 수단이었습니다.
Cartograph의 문장은 *"의존성 그래프를 내놓는다"*이며, 미사용 코드는 그 위에 던지는 첫 번째
질의입니다.

그 차이가 주는 것:

| | Periphery(보관된 OSS) | Cartograph |
|---|---|---|
| 미사용 코드 | ✅ 제품 그 자체 | ✅ 보존 루트에서의 도달성 |
| 왜 살아남았나? | 답할 수 없음 | `dead --explain`이 이유나 경로를 출력 |
| 순환 의존성 | — | ✅ 끊기에 가장 약한 간선까지 표시 |
| 아키텍처 지표 | — | ✅ Ca, Ce, 불안정도, 추상도, 주계열 거리 |
| CI에서 레이어 규칙 강제 | — | ✅ YAML로 쓰는 ArchUnit 방식 규칙 |
| 이 심볼을 누가 쓰나? | 답할 수 없음 | `query`가 양방향을 JSON으로 답함 |
| 이 변경이 무엇에 영향을 주나? | — | `impact`가 편집 전에 직접·전이 소비자를 찾음 |
| 이 값이 이 함수까지 어떻게 오나? | 답할 수 없음 | `dataflow`가 한정된 함수 간 문맥을 JSON으로 답함 |
| Dart·JavaScript 쪽 호출자 | 보이지 않음 | `bridges`가 플랫폼 채널의 Swift 쪽을 내보내고 `--external-retentions`가 조인 결과를 읽어 옴 |
| 런타임·디스패치 전용 위험 | — | `impact`가 런타임 검토 대상과 디스패치 계약을 표시함 |
| 그래프 내보내기 | — | ✅ DOT, Mermaid, JSON, 단일 HTML |
| SARIF(code scanning) | — | ✅ |
| `@objc` 기본 보존 | ❌ 옵트인 | ✅ 기본 켜짐 |

보존 규칙 — *미사용처럼 보이지만 지우면 안 되는* 것에 대한, 오랜 시간에 걸쳐 얻은 지식 — 은
통째로 가져왔습니다. [보존 규칙](#보존-규칙)을 보세요.

## 설치

macOS 14 이상과 Swift 툴체인(Xcode 또는 Command Line Tools)이 필요합니다 — Cartograph가
실행 시 `libIndexStore`를 그 툴체인에서 불러오기 때문입니다. 개발은 Swift 6.4로 하며, CI는
러너에 설치된 최신 Xcode를 골라 그 툴체인으로 만든 컴파일러 픽스처를 검증합니다.
도구 프로세스와 `libIndexStore`의 아키텍처는 같아야 합니다. Apple Silicon의 arm64 전용
툴체인에서는 Cartograph도 네이티브로 실행하세요 — Rosetta로 Intel 슬라이스를 돌리면 그
라이브러리를 불러올 수 없습니다.
Swift 5 언어 모드 프로젝트도 지원합니다. Swift 6 툴체인으로 빌드하면 됩니다 — 언어 모드는
컴파일러 옵션이고 그렇게 쓰인 인덱스도 같은 방식으로 읽힙니다. 분석은 평소대로 하면 됩니다.

**Homebrew** — 미리 빌드한 유니버설 바이너리라 몇 초면 설치됩니다.

```bash
brew install ictechgy/tap/cartograph
```

**Mint** — 소스에서 빌드되며, tap을 추가할 필요가 없습니다.

```bash
mint install ictechgy/cartograph@0.17.0
```

**아예 설치하지 않기** — Swift 패키지라면 의존성으로 추가해 커맨드 플러그인을 씁니다.
팀 전원과 CI가 같은 버전을 쓰게 됩니다.

```swift
// Package.swift
.package(url: "https://github.com/ictechgy/cartograph", revision: "0.17.0"),
```

```bash
swift package cartograph dead --strict
swift package cartograph graph --format mermaid > graph.mmd
```

`from:`이 아니라 `revision:`이어야 합니다. Cartograph는 `indexstore-db`에 의존하는데, 그쪽은
semver 태그를 붙이지 않아 릴리스 브랜치로 고정돼 있습니다. SwiftPM은 안정 버전을 요구받은
패키지가 불안정 버전 패키지에 의존하는 것을 거부합니다.

```
error: … package 'cartograph' is required using a stable-version but 'cartograph'
depends on an unstable-version package 'indexstore-db'.
```

`revision:`은 태그 이름을 받으므로 고정 값은 여전히 버전처럼 읽히고, 릴리스마다 손으로
올려야 하는 점도 같습니다. 플러그인은 쓰기 권한을 선언하지 않으므로 권한 요청창이 뜨지
않습니다. 출력을 남기려면 표준 출력을 파일로 리다이렉션하세요.

**소스에서 빌드:**

```bash
git clone https://github.com/ictechgy/cartograph
cd cartograph
swift build -c release
cp "$(swift build -c release --show-bin-path)/cartograph" /usr/local/bin/
```

## 빠른 시작

Cartograph는 빌드를 대신 돌리지 않습니다. 컴파일러가 이미 써 둔 인덱스 스토어를 읽으므로
실제로 컴파일된 결과와 어긋날 수 없고, DerivedData를 두고 Xcode와 다투지도 않습니다.

**Swift Package Manager**

```bash
swift build          # SwiftPM이 부산물로 인덱스 스토어를 남깁니다
cartograph graph     # 자동으로 찾습니다
```

> `-Xswiftc -index-store-path`는 SwiftPM의 네이티브 빌드 시스템에서만 동작합니다. Swift 6.4부터
> 기본이 된 Xcode 기반 빌드 시스템은 이 플래그를 **무시**하고 `<스크래치 경로>/out`에 인덱스를 남깁니다.
> 자동 탐색에 맡기거나 `--index-store .build/out`을 쓰세요.

**Xcode 프로젝트/워크스페이스**

```bash
xcodebuild build -scheme MyApp \
  COMPILER_INDEX_STORE_ENABLE=YES \
  -derivedDataPath DerivedData
cartograph graph --index-store DerivedData/Index.noindex/DataStore
```

`--index-store`를 생략하면 흔한 위치를 모두 찾습니다 — `.build/index/store`,
`.build/debug/index/store`, `.build/out`, `~/Library/Developer/Xcode/DerivedData`.

DerivedData 아래에서 Xcode는 `<이름>-<해시>` 디렉터리를 그 디렉터리를 담은 폴더가 아니라
**연 문서**의 이름으로 짓습니다. 그래서 Cartograph는 프로젝트 루트가 제공하는 모든 이름을
시도합니다 — 루트 바로 아래의 각 `.xcodeproj`·`.xcworkspace`와 폴더 자신의 이름입니다.
Flutter나 React Native 프로젝트의 `ios/` 디렉터리에서 `cartograph dead`가 도는 것이 이
때문입니다 — 폴더는 `ios`이고 프로젝트는 `Runner.xcodeproj`이니까요. 루트 한 단계만 훑으므로
`Pods/Pods.xcodeproj`는 이름이 되지 않습니다.

이름으로 맞은 디렉터리의 `info.plist`가 `WorkspacePath`로 이 프로젝트를 가리키면 그것이
선택되고, 다른 워크스페이스를 가리키는 디렉터리는 아예 쓰지 않습니다. 남은 후보가 여럿이면
가장 최근에 쓰인 것을 고릅니다 — 낡은 인덱스로 분석하면 조용히 틀리기 때문입니다. 예외는
모호한 경우뿐입니다. 이름으로 맞은 디렉터리가 둘 이상 남았는데 `WorkspacePath`로 소유를
증명한 것이 하나도 없으면, 추측하는 대신 목록을 알립니다 — 모호한 이름에 후보를 돌려주는
`query`와 같은 규칙입니다. 최근 SwiftPM은 인덱스를 자동으로 남기므로, Swift 패키지라면
`cartograph graph`만으로 대개 충분합니다.

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

강한 연결 요소마다 그중 가장 짧은 순환을 대표로 보여 주고, 참조 횟수가 가장 적은 간선을 끊을
후보로 제시합니다. 스무 개의 타입이 서로 얽혀 있다는 말은 정확하지만 실용적이지 않습니다.
손댈 수 있는 구체적인 순환 하나는 다릅니다.

`--explain <노드>`는 그다음 질문에 답합니다 — 이 정점이 어떤 순환에 끼어 있고 각각을 어디서
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

미사용 코드를 *참조 0건*이 아니라 *보존 루트에서 도달할 수 없음*으로 정의합니다. 서로만
참조하는 선언 덩어리는 참조가 많아도 여전히 죽은 코드입니다.

`dead`는 살아 있는 함수의 본문이 한 번도 읽지 않는 파라미터도 `unused-parameter` 규칙의
경고로 보고합니다:

```console
Sources/Net/Client.swift:42:30: warning: parameter 'retry' of 'Net.Client.fetch(_:retry:)' is never used
```

인덱스는 지역 심볼의 참조를 기록하지 않으므로, 사용 여부는 함수 본문을 직접 스캔해
증명합니다. 파라미터는 그 함수가 도달 가능할 때만 보고하고, 본문이 없는 프로토콜
요구사항과 스캔하지 못한 파일의 파라미터는 보고하지 않습니다. `unused-parameter` 경고는
`--strict` 계산에 넣지 않습니다 — 고치는 방법은 삭제가 아니라 `_` 표기입니다.

`dead`는 대입은 되지만 한 번도 읽히지 않는 프로퍼티도 `assign-only` 규칙의 경고로
보고합니다:

```console
Sources/Net/Client.swift:17:9: warning: property 'cacheKey' of 'Net.Client' is assigned but never read
```

인덱스가 프로퍼티 참조마다 read/write 역할을 남기므로 이 검사는 소스 스캔이 필요 없습니다.
프로퍼티는 도달 가능할 때만, 그리고 관측된 접근이 전부 쓰기일 때만 보고합니다 —
멤버와이즈 이니셜라이저의 인자 라벨도 쓰기로 셉니다. 프로토콜 요구사항과 증인(프로토콜
경유의 읽기는 요구사항 심볼에 기록됨), 오버라이드, 런타임이 관리하는 선언(`@NSManaged`,
`@Observable`), Objective-C·Interface Builder 노출 멤버, 암시적 선언은 제외합니다. 합성
`Equatable`/`Hashable`/`Codable` 준수가 저장 프로퍼티를 인덱스에 흔적 없이 읽는 타입의
프로퍼티도 제외합니다. `&x`·동적 디스패치·매크로가 펼친 참조·암시적 참조처럼 방향을 알 수
없는 접근이 하나라도 있으면 추측하지 않고 보고를 억제합니다. `unused-parameter`와 마찬가지로
이 경고는 `--strict` 계산에 넣지 않습니다 — 고치는 방법이 삭제가 아니라 관측 지점일 수
있기 때문입니다.

`dead`는 파일의 참조가 한 번도 쓰지 않는 `import` 선언도 `unused-import` 규칙의 경고로
보고합니다:

```console
Sources/Net/Client.swift:3:1: warning: import 'Combine' is never used
```

Swift USR은 소유 모듈을 담고 있으므로, 파일이 실제로 참조한 모듈 집합을 인덱스에서
복원합니다. `import` 자체가 남기는 `c:@M@M` 표식은 사용으로 세지 않습니다. 사용이 재수출을
타고 올 수도 있기 때문에 보고는 보수적입니다 — 귀속하지 못한 참조(clang/Objective-C USR은
모듈을 담지 않음)가 있거나, import 없이 참조된 모듈이 있는 파일처럼 사용 근거가
불완전하면 억제합니다. 조건부(`#if`) import, 재수출하는 import(`@_exported`,
`public import`), `// cartograph:ignore` 표시가 붙은 import는 보고하지 않습니다.
`import struct Foundation.Bundle`처럼 종류를 좁힌 import는 탑레벨 모듈 기준으로 판정합니다 —
`Foundation`의 무엇이든 쓰면 사용으로 셉니다 — 그리고 진단에는 좁힌 형태 그대로를 적습니다.
다른 경고 규칙과 마찬가지로 `unused-import`는 `--strict` 계산에 넣지 않습니다.

`dead`는 아무것도 억제하지 않는 `cartograph:ignore` 주석도 `superfluous-ignore` 규칙의
경고로 보고합니다:

```console
Sources/Net/Client.swift:41:1: warning: ignore comment on 'Net.Client' and 2 declaration(s) it covers is superfluous — removing it would report nothing
```

일반 참조가 이미 살려 두는 선언에 붙은 주석은 아무 일도 하지 않지만, 그 코드가 죽었다는
잘못된 인상을 남깁니다. 판정은 반사실적입니다 — 그 주석만 뗀 상태로 도달성을 다시 돌려
새 발견이 하나도 생기지 않을 때만 보고합니다. 그래서 실제로 죽은 선언의 주석은 억제를
계속하고, 떼면 도달 불가 선언이 드러날 주석은 절대 표시하지 않습니다. 반사실은 데드코드만이
아닙니다 — 테스트 전용·assign-only 프로퍼티·미사용 import 발견도 모두 셉니다. 선언별 주석은
그 멤버 서브트리 전체를 덮습니다 — 주석이 무시하는 멤버는 자기 코멘트가 있는 것으로 오인하지
않고 그 주석의 판정에 접고, 자기 코멘트가 있는 멤버는 따로 판정합니다. 보존된 멤버는
자신을 담은 타입을 살리므로, 참조가 없는 타입의 자기 주석도 멤버의 주석이 살려 주고 있으면
불필요로 판정될 수 있습니다. 파일 범위
`cartograph:ignore:all` 주석은 한 단위로 판정해 한 건으로 보고하고, 선언별 주석은
파일의 모든 선언에 붙어 있어도 각각 따로 판정합니다. 다른 경고 규칙과 마찬가지로
`superfluous-ignore`는 `--strict` 계산에 넣지 않습니다.

`dead`는 참조가 전부 자기 모듈 안에 있는 public 선언도 `redundant-public` 규칙의 경고로
보고합니다:

```console
Sources/Net/Client.swift:12:12: warning: class 'Net.Client' is referenced only within its own module (3 references) — it could be internal
```

모듈 자신이 유일한 사용자인 public 선언은 public일 필요가 없습니다. 판정은 보수적인 두
질문입니다. 다른 모듈에서 온 참조가 있는가? 출처 모듈이 선언 모듈임을 증명할 수 없는 참조가
있으면 보고하지 않습니다. 다른 공개 선언의 인터페이스가 이 선언을 참조하는가? 시그니처·상속
절·제네릭 제약·기본값의 타입 표기는 대상을 public으로 유지하고, 함수나 접근자 본문 안의
사용은 그렇지 않습니다 — 구문 분석이 참조마다 어느 쪽인지 분류하고, 자리를 판단하지 못한
참조는 인터페이스 사용으로 셉니다. 오버라이드, 프로토콜 요구사항, 프로토콜 증인, 열거형
케이스, `@objc`/`@objcMembers`/`@IBOutlet`/`dynamic`/`@NSManaged` 표식이 이미 붙은 선언은
보고하지 않습니다. 참조가 아예 없는 선언도 보고하지 않습니다 — 미사용 여부는
`unused-symbol`이 따로 답합니다. `retain_public`이 켜져 있으면 이 규칙은 침묵합니다 — 그
설정은 공개 표면이 의도적이라고 선언한 것이고, 모듈이 자기 공개 API를 읽는다는 이유로 표면
전체가 보고되기 때문입니다. 기본 모드(`retain_public` 꺼짐)에서 이 질문을 던지세요. 멤버는
각각 판정하므로, 타입이 모듈 밖에서 쓰여도 모듈 안에서만 불리는 public 메서드는 보고됩니다.
인덱스에 있는 모듈만 증거입니다 — 워크스페이스 밖 소비자는 보이지 않으므로 이 발견은 판정이
아니라 질문으로 읽어야 합니다. 다른 경고 규칙과 마찬가지로 `redundant-public`은 `--strict`
계산에 넣지 않습니다.

`--report-test-only`는 다른 질문에 답합니다 — **테스트나 프리뷰에서만** 도달하는 생산
선언이 무엇인가입니다. 죽은 코드가 아닙니다. 지우면 테스트가 깨집니다. 다만 테스트가 유일한
호출자라는 사실은 팀이 알아야 합니다. `info`로 보고하므로 빌드를 실패시키지 않습니다.

```console
$ cartograph dead --report-test-only
Sources/Models/Policy.swift:31:9: info: property 'App.isDenied' is reached only from tests or previews
```

테스트 타깃 안의 선언은 제외합니다. *테스트* 선언이 들어 있는 모듈은 테스트 타깃이고, 그
안의 도우미는 이 질문의 답이 아니기 때문입니다. 프리뷰는 이 판정에 넣지 않습니다.
`#Preview`는 미리 보는 뷰와 같은 생산 모듈에 살기 때문에, 그것을 표식으로 삼으면 앱 모듈
전체가 분석에서 빠집니다.

`--explain`은 Periphery가 답하지 못하던 질문에 답합니다.

```console
$ cartograph dead --explain HomeViewController
Presentation.HomeViewController is retained because it is connectable from Interface Builder.

$ cartograph dead --explain UserRepository
Data.UserRepository is reachable:
  Presentation.HomeView → Domain.UserService → Data.UserRepository
```

### `fix` — 안전한 기계적 수정 적용

```bash
cartograph fix                      # 계획만 출력; 파일을 쓰지 않음
cartograph fix --apply              # 수정을 기록
cartograph fix --since origin/main  # 바뀐 파일의 발견만
```

기계적으로 고칠 수 있는 경고는 딱 두 종류입니다. `unused-import`는 import 선언을 지우고,
`unused-parameter`는 파라미터의 내부 이름을 없애되 인자 레이블은 유지합니다
(`func f(retry:)`는 `func f(retry _:)`가 됩니다 — 레이블은 절대 떨어지지 않습니다).
`dead`가 보고하는 나머지는 사람의 판단이 필요합니다.

기본은 드라이런입니다. 편집은 위치로 밀어 넣지 않고 **지금 소스**에서 다시 찾습니다:
기록된 자리의 선언이 요청과 일치해야 하고, import 줄에 다른 코드가 없어야 하며,
고쳐 쓴 파일이 다시 파싱되어야 씁니다. 이 검사를 통과하지 못한 편집은 추측하지 않고
이유와 함께 건너뜁니다. 쓰기는 파일 단위로 원자적이고, 베이스라인이 이미 받아들였거나
`--since` 범위 밖인 발견은 건드리지 않습니다. `--apply` 없이 `--strict`를 주면 계획이
남아 있는 동안 실패하고, `--apply`와 함께면 건너뛴 편집이 있을 때만 실패합니다.

```console
$ cartograph fix
Sources/Net/Client.swift:3:1: import 'Combine' is never used
Sources/Net/Client.swift:42:30: parameter 'retry' of 'Net.Client.fetch(_:retry:)' is never used
2 fix(es) in 1 file(s) — dry run; pass --apply to write
```

새로 빌드한 인덱스에서 돌리세요. 계획은 `dead`가 읽는 같은 인덱스에서 나오고, 인덱스가
낡으면 편집이 잘못된 자리에 가지 않고 건너뛰어집니다. `--format json`은 각 편집의 파일·위치·
규칙·대체 텍스트를 담은 `mechanical-fixes` 문서를 돌려줍니다.

### `query` — 선언 하나에 대해 되묻기

```bash
cartograph query UserService
cartograph query 's:3App11UserServiceC' --depth 2 --limit 20
cartograph query --batch requests.json
```

심볼 하나에 대한 세 가지 질문 — 누가 쓰는가, 무엇을 쓰는가, 보존 루트에서 도달 가능한가 —
에 표준 출력의 JSON으로 답합니다. 다른 명령이 프로젝트 전체를 훑어 발견을 보고하는 것과
달리, 이 명령은 이미 갖고 있는 질문에 답합니다.

```console
$ cartograph query UserService
{
  "level" : "symbol",
  "limitations" : [
    "objective-c-sources: 12 file(s) are not analysed, so a Swift declaration used only from Objective-C looks unreached",
    "index-staleness: 3 of 214 source file(s) changed after the file's index unit was written, so a call added since the last build is not here yet"
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

이 출력이 일부러 지키는 다섯 가지가 있습니다.

- **지워도 된다고 말하지 않습니다.** `state`는 그래프에 대한 사실입니다 — `retained`,
  `retainedByMember`, `reachable`, `unreachable`. 그것이 삭제 가능을 뜻하는지는 판단의
  영역이며, 보존 근거는 값으로 줍니다(`"reason": "interfaceBuilder"`). 판단은 받는 쪽의
  몫입니다.
- **모든 답에 이 분석이 보지 못한 것을 싣습니다** — `notFound`에도 싣습니다. Objective-C로
  선언된 이름을 물었는데 "그런 것 없다"는 답만 받으면, 없는 것과 이 도구가 못 보는 것을
  구분할 수 없습니다. `limitations`는 일반론을 나열하는 것이 아니라 *당신의 프로젝트*를
  그래프와 같은 include/exclude 범위 안에서 세어 만듭니다. 알릴 것이 없으면 조용합니다.
  알리는 것은 Objective-C 소스, Interface Builder 문서, 인덱스 유닛이 쓰인 뒤 편집된 소스,
  `retain_public`이 꺼진 채 라이브러리 제품을 내보내는 패키지, 기본보다 좁힌 경로 필터,
  간선 종류 필터입니다 — 어느 것이든 `usedBy`가 빈 이유일 수 있습니다. 기본 제외만으로는
  세지 않습니다 — 그것은 선택한 범위 축소가 아니라 잡음 제거 장치이고, 모든 프로젝트에서
  울리는 경보는 무시됩니다. 파일별 시각 비교로 다른 타깃의 빌드가 편집된 파일을
  가리지 않게 합니다. `unindexed-sources`는 유닛을 찾지 못한 파일을, `missing-sources`는
  인덱스에 있지만 사라진 파일을 셉니다. `unreadable-sources`는 나머지 읽기 실패를 알립니다.
  그 파일의 선언은 접근을 복구하고 다시 분석할 때까지 `sourceUnavailable` 근거로 보존합니다.
  이 한계들은 `dead` 리포트에도, 나머지 발견 게이트에도 실립니다 — `cycles`와 `rules`는
  내보내는 모든 형식에 함께 싣고, `metrics`는 JSON의 같은 `limitations` 키와 표 아래
  `Limitation:` 줄로 실습니다. 분석이 눈먼 채 통과하는 게이트는 게이트가 해서는 안 되는
  단 하나의 일입니다.
- **팀이 이미 받아들인 베이스라인은 그렇다고 표시합니다**(`suppressedByBaseline`). 이미
  내린 결정을 다시 심사하지 않게 합니다. 실제로 보고되었을 선언에만 붙습니다.
- **이웃에 닿는 관계는 하나만 고르지 않고 전부 줍니다.** 호출하면서 동시에 오버라이드하는
  서브클래스는 `"edges": ["call", "overrides"]`로 옵니다. 하나만 보고하면 절반의 그림으로
  지우게 됩니다.
- **이름이 여러 선언에 걸리면 추측하지 않고 후보를 돌려줍니다.** USR이나 `타입.멤버`로 다시
  물으면 됩니다.

```console
$ cartograph query Client
{
  "candidates" : [
    {
      "kind" : "class", "module" : "Network", "qualifiedName" : "Network.Client",
      "location" : { "column" : 7, "line" : 12, "path" : "/p/Network/Client.swift" },
      "usr" : "s:7Network6ClientC"
    },
    {
      "kind" : "class", "module" : "Storage", "qualifiedName" : "Storage.Client",
      "location" : { "column" : 7, "line" : 4, "path" : "/p/Storage/Client.swift" },
      "usr" : "s:7Storage6ClientC"
    }
  ],
  "level" : "symbol",
  "limitations" : [ ... ],
  "requested" : "Client",
  "status" : "ambiguous"
}
```

후보에는 종류·모듈·선언 위치가 실립니다. `qualifiedName`이 `모듈.이름`이라 소유 타입이 빠지기
때문입니다. 실제 앱에 `body`를 물으면 후보 127개가 나오고 그중 122개가 글자까지 같은
`HealthMap.body`입니다 — 그것들을 가르는 것이 위치입니다. 그다음 USR을 통째로 복사하는 대신
`타입.멤버`로 되물을 수 있습니다 — `cartograph query PersistentMapTabHost.body`. 중첩은 깊이
제한 없이 되고(`Outer.Inner.leaf`), 가장 바깥 부분은 모듈 이름이어도 되며, 중간 컨테이너는
빼도 됩니다. 그래도 여럿에 걸리면 추측하는 대신 다시 후보를 줍니다. 익스텐션에 선언된
멤버는 확장 대상 타입의 이름으로 답합니다. `container`는 답을 그 자체로 완결되게 합니다 —
`qualifiedName`을 그대로 다시 물으면 122개가 다시 나오지만, `container`에 멤버 이름을 붙이면
정확히 하나가 됩니다. 후보는 파일과 줄 순서로 옵니다 — 사람이 후보를 가를 때 보는 것이
위치이기 때문입니다. `dead --explain`은 앞의 20개만 찍고 몇 개를 접었는지 말합니다.

`members`와 `declaredIn`은 포함 관계를 싣습니다. 사용 관계가 아닙니다. 심볼 레벨 그래프에서
타입 자신의 의존은 멤버가 들고 있으므로, 클래스의 `dependsOn: []`은 정상이며 그 클래스가
아무것도 의존하지 않는다는 뜻이 아닙니다 — `members`를 따라가면 됩니다.

`--depth`는 각 방향으로 간선을 몇 개까지 따라갈지, `--limit`은 이웃을 몇 개까지 담을지
정합니다. 각 이웃의 `depth`는 몇 걸음 떨어져 있었는지를, `truncated`는 한도에 걸렸는지를
알려 줍니다. 도달성은 항상 심볼 레벨 그래프에서 계산합니다 — `query`는 `--level`을 받지
않으므로 응답의 `level`은 항상 `"symbol"`입니다. 이웃의 `location`은 대상을 쓰는 자리가 아니라
그 이웃이 *선언된* 자리입니다. 값이 없는 필드는 `null`로 두지 않고 키 자체를 뺍니다 —
최상위 선언의 `declaredIn`, 보존되지 않은 선언의 `reason`, 도달하지 않은 선언의 `path`,
그리고 `status`에 따른 `result`와 `candidates`가 그렇습니다.

`usedBy`·`dependsOn` 이웃의 선택 필드 `referenceEvidence`는 실제 참조 위치, 간선의 양끝점,
중간 심볼 `viaUSR`, 근거 출처를 제공합니다. 모든 최단 홉 근거를 유지하므로, 간접 이웃이
대상을 직접 참조한 것처럼 표시하지 않습니다. 위치를 모르면 키가 없는 채로 둡니다. 이웃당
최대 20개, 결과당 최대 200개의 근거를 담으며, `totalCount`·`omittedCount`는 이웃 절단과
별도로 셉니다.

선택 필드 `localFunctionDiagnostics`는 구분되지 않은 지역 함수를 이름·선언 위치·소유자·
원인·권장 조치로 알려 줍니다. 상세가 있으면 모든 `status` 응답에 실리며, 최대 50개와
전체·생략 개수를 함께 싣습니다. 선택 근거가 없다는 것은 생산자가 제공하지 않았다는 뜻이지
완전성의 증명이 아닙니다. [전체 계약](docs/QUERY-EVIDENCE.md)을 보세요.

없는 이름을 물으면 종료 코드 64로 끝납니다 — 스크립트의 오타가 "아무도 안 씀"으로 조용히
넘어가지 않게 하기 위해서입니다.

#### `--batch` — 인덱스를 한 번만 읽고 여러 선언을 묻습니다

```bash
cartograph query --batch requests.json
```

`requests.json`은 이름이나 USR을 담은 JSON 배열입니다 — 1~1000개, 최대 1 MiB. 미사용 목록을
하나씩 훑으면 이름마다 프로세스 하나와 인덱스 읽기 한 번이 듭니다 — 답은 싸고 준비가
비쌉니다. 7,466개 심볼의 앱에서 발견 43건을 전부 물었을 때, 하나씩은 19.6초, 배치는
0.47초였고 답은 같았습니다.

```console
$ cartograph dead --report-format json | jq '[.diagnostics[].subject]' > requests.json
$ cartograph query --batch requests.json
{
  "format" : "symbol-query-batch",
  "results" : [ { "level" : "symbol", "requested" : "s:3App4FooV", "status" : "found", ... } ],
  "version" : 1
}
```

결과는 요청 순서대로, 중복을 그대로 두고 옵니다 — 부르는 쪽이 두 배열을 인덱스로 짝지을 수
있어야 하기 때문입니다. 각 원소는 단일 `query`가 내는 것과 똑같습니다. `ambiguous` 이름은
실패가 아니라 정상 결과입니다. `notFound` 결과에도 `candidates`가 실립니다 — 그래프에서
가장 가까운 이름들에 `qualifiedName`·USR·위치를 얹어 주므로, 오타는 다른 검색 없이 되물을 수
있습니다. 단건 질의는 표준 오류에 요청한 이름과 그 추천을 보여 줍니다. 하나라도 찾지 못하면
종료 코드는 64지만 **모든** 결과는 돌려줍니다 — 오타 하나가 나머지 마흔둘의 답을 버리게
하지 않습니다. 잘못된 요청 파일은 인덱스를 열기 전에 거부되고 2가 아니라 64로 끝납니다 —
분석 실패가 아니라 인자의 문제이기 때문입니다. 찾지 못한 이름들은 표준 오류에 적히므로,
실패한 스윕 때문에 JSON을 다시 diff하지 않아도 됩니다.

배치는 하나의 스냅샷으로 모든 요청에 답합니다. 하나씩 도는 스윕은 재빌드를 가로질러 절반의
질문을 다른 인덱스로 답할 수 있습니다.

이 형식은 dartograph가 쓰는 `symbol-query-batch` v1입니다 — 에이전트가 언어마다 다른 응답
모양을 배우지 않게 하기 위해서입니다.

`dead --report-format json`에도 같은 `limitations` 목록이 실립니다 — 미사용 목록에서 출발하는
스윕이 항목마다 `query`를 부르지 않고도 그래프가 보지 못한 것을 봅니다. `cycles`·`rules`·
`metrics`도 마찬가지입니다 — 이들 역시 CI 게이트입니다. CI가 읽는 형식들은 같은 방법으로
목록을 싣습니다 — `text`는 요약 줄에 개수를 세고 그 뒤에 `limitations:` 블록을 붙이고,
`xcode`는 위치 없는 `note:`를 내고, `github-actions`는 파일 없는 `::notice`를 내어 실행
요약에 달리게 하고, `sarif`는 `runs[].invocations[].toolExecutionNotifications`에 담습니다.
종료 코드도 발견 수도 바뀌지 않습니다. `checkstyle`만 예외입니다 — 스키마에 파일의 오류가
아닌 자리가 없고, 억지로 넣으면 소비자가 보는 발견 수가 늘어납니다. 한계가 필요하면 다른
형식과 함께 쓰세요.

### `impact` — 수정 전에 영향 범위 검토

```bash
cartograph impact UserService
cartograph impact UserService --depth 3 --limit 500 --format json
cartograph impact --file Sources/Features/Home.swift --file Sources/Router.swift
cartograph impact --since origin/main --format json
cartograph impact UserService --before .cartograph/before.json --format json
```

선택 모드는 정확히 하나만 고릅니다 — 선언 하나 이상, `--file` 경로 하나 이상, 또는
`--since <revision>`. 파일 경로는 현재 작업 디렉터리를 기준으로 풉니다. Git 모드는 커밋·
미커밋 추적 변경과 새 파일을 모두 포함하며, 삭제된 경로와 이름 변경의 양쪽 경로도 시드로
남깁니다 — 사후 트리만 남은 인덱스가 삭제를 `noChanges`로 바꾸지 않게 하기 위해서입니다.
모델링된 경로에는 Swift/Objective-C 소스, Interface Builder 문서, Core Data 모델 contents와
`.xccurrentversion`이 포함됩니다. 다른 변경 파일은 `limitations`에 남깁니다.

그래프는 프로젝트 전체에서 소비자를 계속 따라갑니다. `selected`는 직접 선택자와 맞은
선언이고, `changeScope`는 선택한 타입을 의미 있는 멤버와 익스텐션 멤버까지 확장한 범위입니다.
둘 다 실제로 편집했다는 뜻은 아닙니다. `affected`는 그 범위 밖의 직접·전이 소비자입니다.
항목의 `via`는 선택 범위로 향하는 바로 앞 정점이지 원래 시드와 항상 같지는 않습니다.
`depth`는 의미상 영향 단계이며 오버라이드나 프로토콜 디스패치 사슬을 접을 수 있습니다. 각
항목은 관련된 모든 간선을 싣습니다. 선택 필드 `dispatchContract`는 투영에 사용한 계약을
표시할 뿐입니다 — 직접 호출이 아니며 그 런타임 호출이 일어났다는 증명도 아닙니다.

JSON은 `change-impact` v1 문서입니다. `status`, `selected`, `changeScope`, `affected`, `tests`,
`entryPoints`, `runtimeReview`, `summary`, `selectionIssues`, `limitations`, `truncated`를 함께
읽으세요. `selected`는 직접 선택자와 맞은 선언이고, `changeScope`는 선택한 타입을 의미 있는
멤버와 익스텐션 멤버까지 확장한 범위입니다. 둘 다 실제 편집을 뜻하지 않습니다.
`runtimeReview`는 Objective-C, Interface Builder, 동적 디스패치, 외부 브리지, 프로퍼티 래퍼,
Codable, preview와 기타 런타임 관리 경로를 수동 또는 런타임 검증 대상으로 남깁니다. 이것은
영향 가능성에 대한 근거이지 삭제 승인이나 런타임 커버리지 완전성의 증명이 아닙니다.
`--limit`은 selected/change-scope 심볼, 파일, 모듈, 선택 이슈를 포함한 각 출력 섹션에
적용되며 summary에 생략된 항목의 전체 집계를 남깁니다. `truncated.sections`가 어떤 섹션이
잘렸는지 가리키고, 깊이 절단은 별도로 표시합니다.

해결하지 못한 심볼이나 선택한 소스 파일이 있으면 문서는 `status: "incomplete"`가 되고 부분
결과를 출력한 뒤 종료 코드 64를 냅니다. 관련 타깃을 다시 빌드하거나 삭제·이름 변경 선언에
대해 변경 전 인덱스를 확인하세요. 변경 경로가 하나도 없는 기준점은 선택 배열이 비어 있는
`status: "noChanges"`를 냅니다. `impact`는 사실 보고서이므로 `--strict`, `--report-format`,
`--level`을 거부합니다. `--format`은 기본 `text` 또는 `json`, `--depth`는 1부터 128,
`--limit`은 1부터 10000입니다. `--runtime-contracts <path>`는 계약 문서를 검증한 뒤 이 영향
실행의 선언된 런타임 의존성으로만 사용합니다 — dead/query 그래프나 보존 정책을 바꾸지
않습니다.

`--before <analysis-snapshot>`을 주면 현재와 과거 그래프를 각각 분석해 `current`와 `before`
아래에 담습니다. 삭제된 선언은 과거 스냅샷에서, 새 선언은 현재 스냅샷에서 해소할 수
있습니다. 명시한 입력이 양쪽에 없거나 어느 한쪽에서 모호하면 비교는 미해결로 남습니다.
명시적 미해결은 종료 코드 64, Git에서 유도한 선택과 미해결 런타임 근거는 불완전한 분석으로
종료 코드 2입니다. 두 그래프의 간선을 합쳐 경로를 만들지 않습니다.

영향 탐색은 변경 집합의 소비자만 걷기 때문에, 변경된 두 파일 사이에서 사라진 간선은
`affected`에 나타나지 않습니다 — 양 끝점이 전부 변경 범위 안에 들어가기 때문입니다.
`scopeDiff` 절이 양쪽 변경 범위의 합집합 위에 유도된 서브그래프를 대조해 이 공백을 메웁니다.
`addedSymbols`/`removedSymbols`는 한쪽 스냅샷의 범위에만 있는 선언이고,
`addedEdges`/`removedEdges`는 한쪽 그래프에만 있는 간선 삼중(출발, 도착, 종류)입니다.
상대 그래프의 필터가 담을 수 없던 간선 종류는 보고하지 않으며, 필터가 다르면 `limitations`에
그 사실을 적습니다. 각 목록은 `--limit`으로 잘리고 `*Count` 필드와 `scopeDiff.truncated`가
잘리지 않은 실제 개수를 보존합니다.

중첩된 런타임 검토 근거와 계약 ID 목록도 출력 한도를 지킵니다. 생략하면
`externalEvidenceCount`/`externalEvidenceOmitted` 또는
`runtimeContractsCount`/`runtimeContractsOmitted`로 전체/생략 개수를 표시합니다. 호출자
생략은 생산자의 기존 `callersOmitted`에 더하며, `truncated.sections`에 `runtimeEvidence`나
`runtimeContracts`를 표시합니다.

### `affected` — 이 변경에 도달하는 테스트

```bash
cartograph affected --since origin/main            # 이 브랜치 변경에 닿는 테스트
cartograph affected UserService                    # 선언 하나에 닿는 테스트
cartograph affected --file Sources/Net/Client.swift --format json
```

CI가 반복해서 묻는 질문은 impact보다 좁습니다 — **이 변경에 어떤 테스트를 돌려야 하나?** 이
명령은 `impact`와 같은 시드(선언·파일·`--since`)에서 출발해 소비자를 따라가다 테스트 선언
(XCTest 또는 swift-testing)을 만나면 그 거리와 도달 경로를 보고합니다:

```console
$ cartograph affected UserService
affected: 2 test declaration(s) reach this change — 11 affected symbol(s), 1 test file(s), 3 in change scope
  Tests/UserServiceTests.swift:42 App.UserServiceTests.testSelectsData() (depth 2 via App.Loader, dependent [call])
  Tests/UserServiceTests.swift:77 App.UserServiceTests.testRefresh() (depth 3 via App.Loader, dependent [call])
```

변경이 직접 건드린 테스트 파일은 depth 0의 `changed`로 올라옵니다. 테스트가 하나도 닿지 않으면
그 사실을 명시합니다 — 빈 목록은 그래프에 대한 진술이지 기존 테스트가 그 동작을 덮는다는 증거가
아니며, 모든 응답에 그 문장과 분석 한계가 함께 실립니다. 시드 선택·컨테이너 확장·디스패치 투영·
깊이 제한은 `impact`와 같은 배관을 쓰므로, 같은 변경에 대해 두 명령이 다른 답을 내지 않습니다.

### `snapshot` — 분석 입력 캡처

```bash
cartograph snapshot --revision before-change -o .cartograph/before.json
cartograph snapshot --runtime-contracts runtime-contracts.json -o .cartograph/before.json
```

v2 스냅샷은 자동 런타임 사실과 캡처 시점의 신선도, 보강된 컴파일러 인덱스, 간선 선택, 측정한
한계, 외부 보존 근거와 선택적 런타임 계약 선언을 저장합니다. `--revision`은 사용자가 주는
라벨이며 Git이나 네트워크를 조회하지 않습니다. 과거 소스 파일은 다시 읽지 않습니다.
스냅샷은 심볼 그래프와 JSON으로 고정되므로 `--level`, `--report-format`, `--strict`,
`--since`, `--baseline`을 거부합니다.

이전 v1 스냅샷도 읽을 수 있으며 자동 런타임 근거가 없다는 한계를 명시합니다. 스냅샷은
128 MiB로 제한하고 런타임 `expectedValue`는 저장하지 않습니다. 현재 런타임 계약이 삭제한
대상을 계속 요구한다면 과거 호출자가 확인되어도 그 계약 오류는 남습니다.

### `check` — 한 문맥에서 CI 점검

```bash
cartograph check --strict
cartograph check --since origin/main --strict
cartograph check --report-format json
```

`check`는 인덱스 문맥 하나를 읽고 미사용 코드, 모듈 순환, 타입 순환, 설정된 레벨의 규칙을
실행합니다. 모듈 그래프가 깨끗해도 타입 순환은 항상 검사합니다. `--since`는 이 명령에서도
발견 위치를 거르는 렌즈이며 증분 분석이 아닙니다. JSON에는 점검별 요약, 정렬된 진단 목록,
공통 한계와 모든 임계값 초과가 담깁니다.
전체 CI 게이트에서는 `--since` 없이 `check --strict`를 사용하세요. 범위를 지정한 순환 진단은
구성원 파일 중 하나가 바뀌었을 때 그 순환을 포함하지만, 범위 지정 진단이 PR의 모든 영향을
검사했다는 뜻은 아닙니다.

### `serve` — MCP로 에이전트 도구 제공

```json
{
  "mcpServers": {
    "cartograph": {
      "command": "cartograph",
      "args": ["serve", "--project", "."]
    }
  }
}
```

`serve`는 stdio만 사용하며 네트워크나 서버 주도 요청을 만들지 않습니다. 최신 `2026-07-28`
요청의 요청별 `_meta` 프로토콜·클라이언트 능력 필드와 지원되는 레거시 초기화를 함께
받습니다. 세션은 늦게 만들어 빌드 전에도 discover와 도구 목록을 제공합니다.
`cartograph_status`, `cartograph_query`, `cartograph_impact`, `cartograph_check`,
`cartograph_runtime_discover`는 `{ "session": ..., "result": ... }` 봉투를 쓰고(status는
메타데이터를 직접 반환), 인덱스 입력이 바뀌면 다시 준비합니다. 입력 지문은 자동으로
최대 1초에 한 번만 다시 검증하며, 그 창 안의 호출은 마지막으로 검증된 세대로 응답합니다.
창 길이는 `--session-freshness-interval <초>`로 조절하고(`0`이면 요청마다 다시 검증,
`[0, 86400]` 밖의 값은 거부), 편집 직후 즉시 반영이 필요하면 `cartograph_status`에
`refresh: true`를 넘겨 창을 우회할 수 있고, 이어지는 도구 호출은 새로 만든 세대로
응답합니다. 서버가 빌드를 시작하지는 않습니다. query는 `symbols × limit` 공통 예산을
1000으로 제한하고, MCP 배치는 추가로 모든
결과에 걸쳐 참조 근거 200개와 지역 함수 상세 50개의 예산을 공유합니다 — 결과별 전체·생략
개수는 유지되며, 더 필요한 근거는 해당 심볼을 다시 질의해 확인할 수 있습니다. check는
limit을 받으며 진단이 잘려도 전체 발견 수를 보고합니다.
요청은 1 MiB, 인코딩한 응답은 4 MiB로 제한합니다. 너무 큰 응답은 범위나 limit을 줄이라는
명시적 오류를 내며 조용히 자르지 않습니다. 런타임 계약 라벨은 UTF-8 256바이트, 심볼·값은
4096바이트가 상한이므로 비ASCII 문자에도 바이트 제한이 적용됩니다. 빈 기대 값은 허용합니다.

준비된 세션은 장치·inode·크기·나노초 수정/변경 시각·권한·실제 경로를 확인하고 파일 digest를
재사용합니다. 이 정보를 주지 못하는 파일 시스템은 내용을 다시 해시합니다. 소스와 인덱스
유닛 시각도 입력 지문에 포함해 신선도 보고를 갱신합니다. 파일 목록 조회는 매번 수행하며,
이는 준비 과정의 캐시이지 증분 그래프 분석이나 자동 빌드가 아닙니다.

### `runtime` — 연결 자동 발견과 실행 근거 수집

```bash
cartograph runtime discover
cartograph impact ScreenController --format json
```

계약 파일 없이 컴파일러 참조, Swift 구문, Interface Builder 객체 연결을 함께 분석합니다.
클래스·프로토콜 이름 조회, selector, `perform`, target/action, 타이머, 알림 등록/게시,
storyboard/XIB 클래스·action·outlet을 다룹니다. 불변 이름과 단순 문자열 조합을 따라가며,
동적이거나 모호한 경계는 미해결로 남깁니다. 해결된 관계, 기존 컴파일러 참조, selector 토큰,
사용자 동명 API, 낡은 입력을 구분해 보고합니다. `analyzed`라는 말이 모든 런타임 경로를
안다는 뜻은 아닙니다. `--strict`는 검토가 필요한 경계가 남으면 실패합니다.
알림 이름은 리터럴, 증명된 로컬 상수, 설치된 SDK 선언과 exact compiler USR이 일치하는
제한된 SDK 상수만 연결합니다. SDK처럼 보이는 임의 멤버와 컬렉션을 거친 이름은 미해결로
남깁니다.
기본 센터와 `NSWorkspace.shared.notificationCenter`는 안정된 신원으로 다룹니다. 지역에서 만든
센터나 nil이 아닌 object 필터는 한 직선 스코프에서 같은 불변 클래스 생성값을 사용하고
등록이 게시보다 앞선 경우만 연결합니다. 프로퍼티·매개변수 USR이 같다는 것은 객체 신원이
아닙니다.
불변 observer 토큰 별칭, 같은 분기 안의 제거와 게시, 이미 빠져나온 일반 `do`의 `defer`는
lifecycle 근거로 씁니다. 직접 `AnyCancellable.cancel()`한 검증된 publisher 구독도 종료된
것으로 봅니다. 가변·재할당 토큰, 합류 결과가 불명확한 분기, 함수 스코프 `defer`, 다른 센터,
사용자 정의 cancel은 잠재 관계를 유지합니다. 등록·구독은 여전히 콜백 실행 기록이 아닙니다.

알림 publisher는 컴파일러가 확인한 `sink`/`onReceive` 소비가 필요합니다. 직접
`NotificationCenter.notifications` 시퀀스를 쓰는 경우에는 컴파일러가 확인한 `for await`가
필요하며, 소비되지 않은 시퀀스는 검토 대상으로 남습니다. 두 형태 모두 호환되는 이름·센터·
object 근거를 요구합니다.

KVC의 리터럴 단일 키는 접근자 선택이 명확한 final `NSObject` 하위 클래스의 명시적 `@objc`
프로퍼티와 연결합니다. 점 경로는 별도 `keyPathRead`/`keyPathWrite` 연산으로 최대 16세그먼트를
전부 해소하거나 모두 미결로 둡니다. 각 중간 프로퍼티는 명시한 타입 annotation의 exact
compiler reference가 가리키는 final `NSObject`여야 합니다. 쓰기 가능성은 마지막 세그먼트에서만
요구합니다. 모든 반환 대상은 한 경로의 의존성이므로, write 결과의 중간 대상은 그 setter가
실행됐다는 뜻이 아닙니다. inline 또는 불변 local `NSPredicate(format:)`은 제한 문법이 전체
format을 소비하고, `%K`의 같은 인자 위치에 리터럴 문자열이 있고, 평가 root 타입과 predicate
생성·`evaluate(with:)` API를 컴파일러가 확인한 경우만 경로를 냅니다. collection operator,
`SUBQUERY`, 동적 format과 사용자 동명 API는 미결로 남깁니다.

표준 `Swift.Dictionary`의 불변 factory/router 레지스트리는 리터럴 문자열 키와 이름 있는
top-level 함수 값만 지원합니다. 불변 별칭은 같은 레지스트리 신원을 전달할 수 있지만
선언·함수 reference와 표준 `Dictionary` subscript를 컴파일러가 모두 확인해야 합니다. 범용
DI 규칙은 아닙니다 — 클로저, 인스턴스 메서드, 가변/동적 맵, 중복 키, 사용자 dictionary 타입,
외부 레지스트리 프레임워크는 미결로 남깁니다.

수동 Core Data 모델의 entity는 유일하게 인덱싱된 Swift `NSManagedObject` 하위 클래스와
연결합니다.
`.xcdatamodeld`는 범위 안의 contents가 하나뿐이어도 반드시 `.xccurrentversion`으로 활성 모델을
고릅니다. marker는 64 KiB 이하의 일반 비심볼릭링크 파일인 binary plist 또는 UTF-8 XML plist만
받으며, 선택이 없거나 잘못됐거나 제외됐거나 파일이 없으면 fallback하지 않습니다. 독립
`.xcdatamodel`에는 marker가 필요 없고, 비활성 버전은 migration 검토 대상으로 유지합니다.
`category` 생성은 기존 Swift 클래스의 Swift 이름과 Objective-C 런타임 이름이 모두 맞을 때만
연결합니다. 자동 생성 클래스, `customClass` fallback, 지원하지 않는 `manual` 문자열, 모호한
모듈, entity 이름만 있는 fetch 문자열은 추측하지 않습니다. 모델 내용과 `.xccurrentversion`은
세션 지문, 스냅샷, `impact --file`, `impact --since`, 과거 경로 재배치에 포함됩니다.

클래스 자동 생성 entity는 현재 빌드에 대한 명시적 근거가 필요합니다. 선택한 소스 모델과
리터럴 container 이름, main app 실행 파일, 정확한 생성 class 파일과 module로 근거를 만듭니다.

```bash
cartograph runtime prepare-coredata --model Model.xcdatamodeld --container Store \
  --executable Build/MyApp.app/Contents/MacOS/MyApp \
  --generated-source Generated/Record+CoreDataClass.swift --module MyApp \
  -o .cartograph/coredata-build-evidence.json
cartograph runtime discover --coredata-build-evidence .cartograph/coredata-build-evidence.json
```

`coredata-build-evidence` v1은 소스 모델, 선택 버전, current-version marker, main bundle의
컴파일 모델, bundle, 실행 파일, 생성 소스의 내용을 지문화합니다. 생성 USR은 정확한
파일·module에 속해야 하고 `/usr/bin/nm`이 Swift metadata symbol 정의를 main 실행 파일에서
찾아야 합니다. 동적 로드 framework에만 있는 class는 link-chain 근거가 없어 지원하지
않습니다. 이 opt-in 근거가 있으면 불변 local `NSPersistentContainer(name:)` → `viewContext` →
리터럴 `NSFetchRequest<NSManagedObject>` 경로의 fetch를 검증된 entity와 기본 포함
subentity에 연결합니다. request/entity/context를 바꾸거나 흘려내면 미결로 남깁니다.

현재 빌드의 `impact`와 `snapshot`도 같은 근거 옵션을 받으며, snapshot은 검증된 생성 소스를
과거 비교용으로 보존합니다. `--trace`와 함께 쓸 수 없고 기본 `query`·`dead` 그래프는 바꾸지
않습니다. MCP server는 `cartograph serve --coredata-build-evidence <path>`로 프로젝트 안 JSON
하나를 고정할 수 있습니다. client는 그 경로를 바꿀 수 없고 `coreDataBuildEvidence` metadata는
기본 session과 별도로 나갑니다.

`impact`는 검증한 정적 런타임 연결을 자동으로 따라가고 `automaticRuntime`에 근거를
표시합니다. 리소스 파일을 선택하면 그 연결이 참조하는 Swift 선언도 선택합니다. 이름·수신자를
모르면 간선을 추측하지 않고 한계로 알립니다.

**macOS 디버그 실행 파일**에서는 수동 계약 없이 실제 사건을 수집할 수 있습니다.

```bash
cartograph runtime collect --executable .build/debug/MyApp --output /tmp/runtime-trace.json -- app-arguments
cartograph runtime discover --trace /tmp/runtime-trace.json --executable .build/debug/MyApp
cartograph impact ScreenController --trace /tmp/runtime-trace.json --executable .build/debug/MyApp --format json
```

`collect`는 설치된 Clang으로 로컬 수집기를 빌드한 뒤 지정한 실행 파일을 실행합니다.
Foundation 클래스·프로토콜·selector 조회, `performSelector` 세 형태, selector 기반 알림
등록을 수집합니다. 앱의 인자나 반환 payload는 기록하지 않으며 앱 stdout/stderr는 stderr로
전달합니다. 하위 프로세스에 상속된 계측 사건은 제외합니다. 조회·등록·정상 반환한 호출은
서로 다른 근거이며, selector 생성이 메서드 실행을, 등록이 실제 알림 전달을 증명하지
않습니다.

소스·인덱스와 실행 파일 내용이 수집 당시와 맞아야 합니다. 주입 실패, 시간 초과, 앱 오류,
사건 유실/손상, 입력 변경은 부분 결과와 종료 코드 2로 알립니다. 서명이나 entitlement를
바꾸지 않으며 hardened 앱은 주입을 거부할 수 있습니다.
설치된 **iOS 15 이상 시뮬레이터 디버그 테스트 앱**에서도 수집할 수 있습니다.

```bash
cartograph runtime collect --simulator <booted-device-UUID> --bundle-id <app-bundle-id> \
  --executable <matching-build/MyApp.app/MyApp> --output /tmp/simulator-trace.json -- test-arguments
```

기기 UUID를 명시하며 기기 부팅이나 앱 설치는 하지 않습니다. 이미 실행 중인 앱은 거부하고,
설치된 실행 파일과 `--executable`이 수집 전후 같은지 검사합니다. 기본 종료 모드에서는
시나리오 뒤 `exit(0)`을 호출하는 전용 테스트 앱을 사용하세요. 앱이 충돌해도 `simctl`은 성공을
반환할 수 있으므로 앱 종료 코드와 수집 로그의 정상 완료 근거를 모두 요구합니다. 대화형 앱
강제 종료, `_exit`, 충돌, 시간 초과는 부분 결과입니다. iOS 실기기와 임의 API 전체 계측은
아직 지원하지 않습니다.

대화형 디버그 앱에서는 `--duration 30`을 추가하면 수집기 활성화 뒤 지정한 구간을 관측하고,
기록을 봉인한 다음 시작한 앱을 종료합니다. macOS와 시뮬레이터 모두 앱에 exit 호출을 추가할
필요가 없습니다. v2 trace는 `collectionComplete: false`를 유지하고 `evidenceComplete`와
`observationWindow`를 별도로 표시합니다. 봉인된 구간을 근거로 쓸 수 있다는 뜻이며 앱이나
시나리오의 성공 판정은 아닙니다. 조기 종료·봉인 실패·사건 유실·입력 변경은 미완료입니다.
봉인 뒤 반환한 호출은 구간 밖입니다. `--timeout`은 수집 상한이며 duration보다 길어야 합니다.
다른 DYLD 주입 라이브러리가 있으면 훅 충돌로 사건을 놓칠 수 있어 거부합니다. 실행 플랫폼·PID와
시뮬레이터 기기 UUID·bundle ID도 trace에 기록합니다. 실행한 경로와 계측한 API만 관측합니다.
`observedRuntime`에 근거를 분리하고 다른 빌드의 `impact --before`와 섞지 않습니다.

시나리오와 기대 결과를 명시적으로 검사하는 기존 계약 검증도 유지합니다.

```bash
cartograph runtime plan --contracts runtime-contracts.json --executable .build/debug/MyApp --strict
cartograph runtime check --contracts runtime-contracts.json --observations runtime-observations.json \
  --executable .build/debug/MyApp --strict
```

[발견·수집·계약 형식](docs/RUNTIME-CONTRACTS.md),
[알림·런타임 코퍼스](Fixtures/RuntimeDiscoveryCorpus/README.md),
[key-path 코퍼스](Fixtures/RuntimeKeyPathCorpus/README.md),
[불변 registry 코퍼스](Fixtures/RuntimeRegistryCorpus/README.md)를 참고하세요. 각 한정 집합의
지원 양성 관계는 현재 59건, 12건, 7건입니다. 서로 더해 범용 런타임 완성률로 표현할 수
없으며, 각 반례 집합의 회귀 결과일 뿐입니다.

### `dataflow` — 함수 경계를 넘는 값 흐름 추적

```bash
cartograph dataflow UserService.fetch
cartograph dataflow Worker.run --max-contexts 1024 --max-iterations 20000
cartograph dataflow 'Worker.run()' --call-depth 4
```

`dataflow`는 `query`와 다른 질문에 답합니다. 심볼 그래프와 `dependsOn` 간선의 의미는 그대로
두고, 요청한 함수 하나에 대해 제한된 별도 값 그래프를 만들어 항상 JSON으로 내보냅니다.
응답에는 호출 문맥 요약, 인자와 매개변수·반환과 호출 지점의 연결, 콜백, `inout` 쓰기, 필드
별칭이 담깁니다. 지원하지 않는 외부 호출이나 모호한 외부 선언을 건넌 값은 미상으로 남고,
오래된 선언과 문맥·반복·값·힙 예산으로 잘린 결과도 그렇게 표시됩니다. 함수를 찾지 못하면
명시적인 `notFound` 결과와 종료 코드 64를 내며, 알려진 진입 문맥이 없으면 입력과 외부
상태를 미상으로 둔 명시적인 요청 문맥을 만듭니다.

`selectedContexts`가 근거 그래프 안에서 요청한 함수의 문맥을 가리킵니다. 각 문맥에는 호출
전후의 메모리 효과가 담깁니다. 동적 class 디스패치, 가변 값 타입, 상속 초기화, 관찰자·매크로,
미해결 리터럴 타입은 미상으로 남깁니다. `bridges`는 소스 표현식의 모든 분석 문맥이 같은
문자열일 때만 계산된 이름을 사용합니다. 서로 다른 이름으로 호출한 wrapper는 bridge-facts
v1에서 동적으로 남습니다. [실측 범위와 비교](docs/scans/2026-09-value-flow-comparison.md)를
참고하세요.

기본값은 문맥 512개, 반복 10,000회, 노드당 값 32개, 힙 셀 10,000개, 추적할 호출 경로 깊이
2입니다. `--call-depth`는 1부터 8까지 받습니다. `--level`, `--since`, `--report-format`,
`--strict`는 거부합니다 — 값 분석에는 별도 문맥 그래프가 있고 한 대상에 답하며 출력 형식은
JSON으로 고정되어 있기 때문입니다. 이 정책은 CLI 전체의 것입니다 — 자기가 못 받는 플래그는
조용히 무시하지 않고 종료 코드 64로 거부합니다. `query`는 `--report-format`과 `--strict`를
거부하고(답은 언제나 JSON이고 발견 목록이 아니라 사실입니다), `graph`와 `bridges`는
`--report-format`(문서 형식은 거기서 `--format`입니다)과 `--strict`를 거부합니다.

### `bridges` — 언어 경계의 Swift 쪽 내보내기

```bash
cartograph bridges                       # bridge-facts JSON을 표준 출력으로
cartograph bridges --format text         # 사실마다 한 줄, 훑어보기용
cartograph bridges --target flutter      # 혼합 프로젝트에서 한 메커니즘만 분리
cartograph dead --external-retentions .isthmus/retentions.cartograph.json
```

Flutter 메서드 채널 핸들러나 React Native 모듈은 Dart나 JavaScript가 부릅니다. 컴파일러
인덱스는 그것을 보지 못하므로 도달 불가로 보고합니다. 두 쪽을 잇는 유일한 끈은 문자열입니다 —
`FlutterMethodChannel(name:)`의 채널 이름, 핸들러 안의 `case "takePhoto":`, 클래스의
`@objc(CalendarManager)`, `.m` 파일의 `RCT_EXPORT_METHOD(addEvent:)`. `bridges`는 그
리터럴을 SwiftSyntax(와 Objective-C Flutter 핸들러·React Native export 매크로용 스캐너)로
소스에서 읽고, 감싸는 선언의 USR을 인덱스에서 붙여, [isthmus](../isthmus)가 다른 플랫폼의
사실과 조인하는 `bridge-facts` 교환 형식으로 씁니다.

출력의 `project`는 루트의 POSIX `realpath`입니다. 심볼릭 링크를 해결해 `/tmp`와
`/private/tmp`가 생산자 사이에서 같은 프로젝트를 가리키게 합니다. 해결할 수 없는 루트는
오류입니다. 사실의 위치는 프로젝트 상대 경로를 유지합니다. 소비자는 여전히 `project` 문자열의
정확한 일치를 요구하며, 정규화가 서로 다른 플러그인이나 모노레포 루트를 합치지는 않습니다.

0.9.0의 v1 확장은 선택적 `limitationScopes`를 추가합니다. 각 항목은 `limitationIndex`와
정확한 `channels` 배열로 구성됩니다. 읽지 못한 코드에서 발견한 이름 목록이 아니라, 해당
공백 전체를 포함하는 상한입니다. 외부 객체·팩토리가 제공한 Swift 핸들러는 영향을 받는 등록
채널을 모두 알 때만 `opaque-handler-bodies` 범위를 좁힙니다. 하나라도 모르면 기존 전체
target 범위를 유지하며, 다른 범위 불명 공백을 덮어쓰지 않습니다.

Swift 브리지 이름은 같은 파일의 불변 `let` 별칭과 괄호를 최대 64단계 따라가고, 양쪽이
풀리는 `+` 연결은 합쳐진 리터럴로(한쪽만 풀리면 풀린 쪽이 접두사로) 풉니다. `self.x = 인자`
처럼 이니셜라이저 인자로만 채워지는 프로퍼티는 `Type(label:)` 호출 지점의 값으로 풀고,
`call`을 그대로 넘기는 한 홉 위임(`Task { await handleAsync(call, …) }`)은 등록 채널을 그대로
계승합니다. 가변 값, 값을 모르는 가림 선언, 다른 연산자·보간, 호출 지점 간 불일치, 다른
파일의 값은 dynamic으로 남깁니다.
[상수·Needle·스토리보드 실측](docs/scans/2026-09-analysis-blindspots.md)에 지원 범위와 입력
공백을 정리했습니다.

동적인 Swift 브리지 이름이 최신 인덱스 소스에서 나오면 `bridges`는 제한된 함수 간 값 흐름
분석도 실행합니다. 모든 분석 문맥이 같은 정확한 문자열에 동의할 때만 이름을 적용하므로,
지원되는 인자·반환·콜백·메모리 경로는 함수 사이에서도 해석됩니다. 문맥 간 불일치, 미상 값,
미지원 구문, 오래된 소스와 예산 초과는 `dynamic`으로 남습니다.
[함수 간 분석 실측](docs/scans/2026-09-interprocedural-flow.md)에 실행 값과 지원 범위를
비교했습니다.

`cartograph bridges --messages --target flutter`는 Flutter `BasicMessageChannel`과 Pigeon
핸들러를 위한 bridge-facts v2 확장입니다. 가상의 method를 만들지 않고 `message-handle`
사실과 closure 범위, 그 위치에서 실제 컴파일러 인덱스가 관찰한 호출·참조 심볼을 냅니다.
기존 감싸는 setup 심볼은 모든 사실에 그대로 남기며, 범위나 인덱스 근거가 불완전하면
소비자가 setup의 넓은 영향과 공백을 유지해야 합니다. dispatch 후보는 인덱스의 실제
`overrides` 관계가 있을 때만 포함합니다. 현재 범위는 공개 `url_launcher_macos@3.2.2` 생성
Swift 소스로 검증했으며, 모든 Pigeon 형태를 지원한다는 발행 호환성 약속은 아닙니다.

ObjC Flutter 스캔은 직접 채널 생성, 인라인 블록, 같은 파일의 registrar 위임과
`handleMethodCall:result:`를 지원합니다. 파일 범위의 불변 `NSString *const` 이름도 한 단계
풉니다. 긍정 `isEqualToString:` 분기는 `sourceLanguage: "objective-c"` 사실이 되며 Swift
심볼을 지어내지 않습니다. Clang 인덱스에 선언이 유일하게 있으면 실제 `c:` USR을 싣고,
없거나 위치가 모호하면 구문의 정규화된 이름(`Plugin.handleMethodCall:result:`)만 이름뿐인
심볼로 싣습니다(Swift 사실과 같은 대칭). 이름은 소스에서 결정적이지만 USR은 추측하지
않습니다. USR이 있어도 현재 Swift 분석 그래프의 정점은 아닙니다. 조건부 컴파일·매크로·
재대입·미지원 위임은 불확실하게 남기고, 리터럴 일부를 읽었어도 일반 `objective-c-sources`
공백은 좁히지 않습니다. [제한된 스캔 실측](docs/scans/2026-09-objc-flutter.md)에 관측 범위를
기록했습니다.

새 생산자보다 이 확장을 지원하는 isthmus를 먼저 배포해야 합니다. 옛 v1 소비자는 기존의 넓은
한계를 유지하지만, 옛 isthmus는 ObjC의 그래프 범위를 구분하지 못해 symbol 누락으로
실패하거나 Swift 그래프에 적용할 수 없는 Clang 보존 근거를 내보낼 수 있습니다. 새 isthmus는
조인 증거를 남기고 Swift 전용 보존 목록에서 제외한 수를 `omittedObjectiveCHandlers`로
알립니다. cartograph도 이 수를 한계에 싣습니다. 표식 없는 Swift 핸들러의 symbol 누락은
여전히 보존 생성 실패입니다.

```console
$ cartograph bridges
{
  "facts" : [
    {
      "channel" : "com.example/camera",
      "dynamic" : false,
      "kind" : "method-handle",
      "location" : { "column" : 18, "line" : 26, "path" : "CameraPlugin.swift" },
      "method" : "takePhoto",
      "symbol" : { "qualifiedName" : "CameraPlugin.handle", "usr" : "s:3App12CameraPlugin…" }
    }
  ],
  "format" : "bridge-facts",
  "generatedAt" : "2026-09-04T00:00:00.000Z",
  "limitations" : [ ],
  "platform" : "swift",
  "project" : "/app/ios",
  "target" : "flutter",
  "tool" : { "name" : "cartograph", "version" : "0.17.0" },
  "version" : 1
}
```

판정이 아니라 사실을 냅니다. 반대쪽에서 실제로 핸들러를 부르는지는 모릅니다. 리터럴이 아닌
이름은 버리지 않고 원문 표현식과 `dynamic: true`로 남겨, 소비자가 조인하지 못한 수를 셀 수
있게 합니다. 상수는 한 단계만 따라갑니다(`static let name = "…"`을
`FlutterMethodChannel(name: Self.name)`에 쓰는 경우). 그보다 깊으면 `dynamic`입니다.
핸들러 클로저 밖의 `case "…"`는 `FlutterMethodCall`을 받는 함수 안에서만 세고, 파일에
채널이 정확히 하나일 때 그 채널에 붙고, 아니면 `null`입니다. 핸들러를 달지 않고 채널을
만들기만 한 것은 사실이 아닙니다. `limitations`에는 동적 이름의 수, 채널을 못 정했거나
추측한 핸들의 수, USR이 없는 Swift 핸들러의 수(빌드 뒤 편집된 Swift — 이름뿐 심볼이 된
ObjC 핸들은 `objective-c-handlers` 쪽에서 셉니다), React Native 모듈로 가정한 `@objc(Name)`
클래스의 수, 이 형식이 다루지 않는 `FlutterEventChannel`과 Pigeon `BasicMessageChannel`의 수,
근거 파일로 살릴 수 없는 Objective-C 핸들러의 수, Flutter와 React Native가 섞인 프로젝트를
셉니다.

사실 위치는 프로젝트 상대 경로이고 `generatedAt`은 UTC 밀리초 형식입니다. 한 프로젝트에
여러 브리지 메커니즘이 있으면 isthmus v0.1에 넘기기 전에 `--target flutter` 또는
`--target react-native`로 문서를 분리합니다. target 문서는 제외한 사실 수를
`target-filter` limitation으로 알립니다.

isthmus는 `external-retentions`를 돌려줍니다 — 호출자를 찾은 Swift 선언마다 USR과 근거입니다.
`--external-retentions <경로>`(또는 설정의 `external_retentions_path`)는 각각을 이유가
`externalBridge`인 보존 루트로 만들고, `--explain`은 파일을 가리키는 대신 근거를 문장으로
인용합니다.

```console
$ cartograph dead --external-retentions .isthmus/retentions.cartograph.json --explain CameraPlugin
App.CameraPlugin is retained because its member App.init(messenger:) is called from another platform across a bridge, per the external retentions file.
  evidence: dart lib/camera.dart:42 invokes 'takePhoto' on channel 'com.example/camera'
```

반대쪽에서 여러 위치로 부르면 근거의 `callers`에 전체 호출 위치를(생산자 상한을 넘은 만큼은
`callersOmitted`으로) 싣고 `--explain`은 이를 나열하되, 문장을 짧게 유지하려고 남은 수를
`+N more`로만 적습니다. 호출이 하나뿐인 문서는 기존과 같은 문장을 냅니다.

지정했는데 없는 파일은 조용히 넘어가지 않고 도구 실패(종료 코드 2)입니다. 파일을 준 사람은
그것이 반영되기를 기대합니다. `query`는 `limitations`에 파일의 출처와, 인덱스의 어느 선언과도
맞지 않는 근거의 수를 싣습니다. 이름을 바꾼 핸들러는 버그가 되기 전에 거기서 먼저 드러납니다.

### `skill` — 코딩 에이전트에게 이 도구 쓰는 법 설치하기

```bash
cartograph skill
```

프로젝트에 `.claude/skills/cartograph/SKILL.md`를 씁니다. 먼저 읽어 보고 싶으면 저장소의
[`Skills/cartograph/SKILL.md`](Skills/cartograph/SKILL.md)에 같은 파일이 있습니다. 둘이
갈라지면 테스트가 실패하므로, 사람이 검토한 것과 에이전트가 실제로 받는 것이 다를 수
없습니다. `--project ~`로 설치하면 한 프로젝트가 아니라 전체에 적용됩니다.

이 문서의 대부분은 어떤 명령을 실행하라는 내용이 아닙니다. 에이전트는 판정을 망설임 없이
편집으로 옮기기 때문에, 답이 *증명하지 않는 것*에 분량을 씁니다 — `unreachable`은 그래프에
대한 사실이지 삭제 허가가 아니라는 것, `limitations`를 같은 호흡에 읽어야 한다는 것,
`suppressedByBaseline`은 팀이 이미 내린 결정이라는 것, 그리고 `graph --format json`을 통째로
컨텍스트에 밀어 넣어도 `query`로 답할 수 없는 질문에는 답하지 못한다는 것.

### `metrics` — 아키텍처 지표

```bash
cartograph metrics --level module
```

Robert C. Martin의 패키지 지표를 이 그래프 위에서 계산합니다. 이 저장소에서 돌린 결과:

```
NODE                   Ca  Ce     I     A     D           ZONE
---------------------  --  --  ----  ----  ----  -------------
CartographCore          8   0  0.00  0.04  0.96   zone-of-pain
CartographAnalysis      2   1  0.33  0.00  0.67   zone-of-pain
CartographConfig        1   1  0.50  0.00  0.50   zone-of-pain
CartographIndexStore    1   1  0.50  0.00  0.50   zone-of-pain
CartographSyntax        1   1  0.50  0.00  0.50   zone-of-pain
CartographExport        1   2  0.67  0.06  0.27  main-sequence
CartographKit           1   5  0.83  0.00  0.17  main-sequence
CartographTestSupport   0   1  1.00  0.00  0.00  main-sequence
cartograph              0   3  1.00  0.00  0.00  main-sequence
```

`CartographCore`가 zone-of-pain 깊숙이 자리한 것은 예상대로입니다 — 모두가 의존하는 구체적인
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

```bash
cartograph rules --strict
```

레이어 판정은 정점 이름·모듈 이름·파일 경로를 모두 대상으로 삼습니다. 팀마다 레이어를
디렉터리로 정의하기도 하고 이름 규칙으로 정의하기도 하기 때문입니다. 어느 레이어에도 속하지
않는 정점은 `info`로 보고합니다 — 규칙이 무엇을 덮지 못하는지 모르면 "통과"라는 결과를
믿을 수 없습니다.

`--explain <노드>`는 그 정점이 어느 레이어에 들어갔는지, 어느 패턴이 그렇게 만들었는지,
그 레이어에서 출발하는 규칙이 무엇인지 보여 줍니다 — 설정을 디버깅할 때 실제로 던지는
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

지금 있는 발견을 기록해 두고 *새로 생긴* 것만 빌드를 실패시킵니다. 지문은 USR 기반이라
코드를 파일 안에서 위아래로 옮겨도 억제한 발견이 되살아나지 않습니다.

파일을 쓰는 자리는 언제나 명시적입니다 — `--write`로 주거나, 설정이 `baseline_path`를 정하지
않았다면 프로젝트 루트의 기본 이름(`.cartograph-baseline.json`)입니다. 설정의
`baseline_path` 키는 억제 발견을 *읽는* 위치를 나타낼 뿐, 베이스라인이 쓰이는 곳을 정하지
못합니다 — 분석 대상 저장소의 설정이 임의의 경로에 쓰기를 지시할 수 있어서는 안 되기
때문입니다. `baseline_path`가 설정된 채 `--write` 없이 `baseline`을 돌리면 64로 끝나고 그
이유를 말합니다.

### `--since` — 이번 PR이 건드린 자리만 보기

```bash
cartograph dead --since origin/main --strict
```

주어진 git 기준점 이후 바뀐 모델링 대상 파일**에 위치한** 발견만 보고합니다 — Swift,
Objective-C, Interface Builder 확장자를 대상으로 커밋된 변경, 추적 파일의 미커밋 변경,
아직 추가하지 않은 새 파일을 모두 포함합니다. 모델링하지 않는 변경은 한계로 알립니다.
그래프는 여전히 프로젝트 전체로 만듭니다 — 좁힌 그래프에서 나온 도달성 판정은 그냥 틀린
값이기 때문입니다. 좁히는 것은 보고뿐입니다.

이것은 "이번 변경이 무엇을 건드렸나"에 답하지, "이번 변경이 무엇을 만들었나"에 답하지
않습니다. 건드리지 않은 파일에 선언된 심볼의 마지막 호출을 이번 커밋이 지웠다면 그 심볼은
죽지만, 발견의 위치는 건드리지 않은 파일이라 보고되지 않습니다. 그 경우는 다음 전체
실행에서 베이스라인이 잡습니다. `--since`는 렌즈이지 증명이 아닙니다. 그래서 `baseline`은
`--since`를 거부합니다 — 일부만 기록해 두면 나중에 범위 밖 부채가 전부 신규로 보이기
때문입니다. `query`도 거부합니다 — 선언 하나는 발견 목록이 아니라 렌즈를 걸 자리가
없습니다. `graph`(보고가 아닌 프로젝트 전체), `bridges`(일부만 내면 하류 조인이 빠진
핸들러로 읽습니다), `--explain` 답변(질의처럼 단일 대상)도 같습니다. `--since`가 듣는 것은
발견 목록을 내는 `dead`·`cycles`·`metrics`·`rules`뿐입니다. `impact --since`는 진단 위치를
거르는 렌즈가 아니라 바뀐 경로를 시드로 삼아 프로젝트 전체 그래프의 소비자를 따라가는 영향
분석입니다 — 삭제와 이름 변경 경로도 포함합니다. `impact`의 `noChanges`는 모델링된 소스
경로가 선택되지 않았다는 뜻이며, 모든 변경 파일이 안전하다는 증거가 아닙니다.

`baseline`과 `--since`는 다른 질문에 답하며 함께 쓸 수 있습니다 — 베이스라인은 오늘의 빚이
늘지 않게 하는 CI 래칫이고, `--since`는 PR을 보는 렌즈입니다. CI에서는 전체 이력을
받아야 합니다(`fetch-depth: 0`). 그러지 않으면 기준점을 찾지 못합니다.

## 설정

프로젝트 루트의 `.cartograph.yml`입니다. `cartograph init`으로 주석 달린 템플릿을 만드세요.
커맨드라인 옵션이 언제나 파일보다 우선합니다. `level` 키를 읽는 것은 해상도로 그리는
명령(`graph`, `cycles`, `metrics`, `rules`)뿐입니다 — 나머지에겐 아무 일도 안
합니다(`dead`·`query`는 항상 심볼 레벨이고 `dataflow`는 자체 값 문맥 그래프를 씁니다).
`--level` 플래그와
같은데, 그쪽은 명령이 앞에서 거부합니다.

```yaml
level: module
include: ["Sources/**"]
exclude: ["**/.build/**", "**/*.generated.swift"]

retention:
  retain_public: false            # 라이브러리라면 켜기
  retain_objc_accessible: true    # 기본값 켜짐. 아래 참조
  retain_interface_builder: true
  retain_tests: true
  retain_previews: true
  retain_codable_properties: true
  retain_raw_representable_enum_cases: true
  retained_names: ["*.shared"]
  retained_files: ["Sources/Generated/**"]

thresholds:
  max_cycles: 0
  max_unused_symbols: 0
  max_rule_violations: 0
  max_instability: 0.9
  max_distance: 0.8

baseline_path: .cartograph-baseline.json    # 억제 발견을 읽어 오는 위치.
                                            # `cartograph baseline`은 --write 또는
                                            # 프로젝트 루트 기본값에만 씁니다
external_retentions_path: .isthmus/retentions.cartograph.json   # isthmus 산출물. `bridges` 참조
derived_data_path: DerivedData    # CI가 -derivedDataPath로 둔 위치
report_format: text               # text json xcode checkstyle github-actions sarif
graph_format: dot                 # dot mermaid json html
strict: false
```

모르는 키는 오류 대신 경고로 알립니다 — 오타 하나 때문에 빌드가 멈추는 대신 무엇이
무시됐는지 알려 줘야 하기 때문입니다.

## 보존 규칙

인덱스 스토어에는 컴파일러가 본 것만 기록됩니다. 런타임 셀렉터, 합성된 `Codable`,
Interface Builder 연결, 원시값 열거형의 동적 생성은 전부 보이지 않습니다. 아래 규칙이 그
공백을 메우며, 각 규칙은 *왜* 살렸는지를 함께 남기므로 `--explain`이 답할 수 있습니다.

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
| 분석 범위 밖 선언을 오버라이드하거나 준수하는 **멤버** | 프레임워크가 호출. 이 규칙만으로 소유 타입까지 살리지는 않음 |
| `subscript(dynamicMember:)`, `@_dynamicReplacement`, `dynamic` | 동적 디스패치 |
| 컴파일러 합성 선언 | 지울 수 없음. 그것을 담은 타입까지 살리지도 않음 |
| `// cartograph:ignore`, `// cartograph:ignore:all` | 사용자가 지정 |
| `retained_names`, `retained_files` 글롭 | 사용자가 지정 |
| 권한·I/O 오류로 소스를 읽지 못한 선언 | 보존 정보가 불완전함(`sourceUnavailable`). 접근을 복구하고 다시 분석 |
| `--external-retentions`가 지목한 선언 | 다른 플랫폼이 브리지를 넘어 호출. `--explain`이 근거를 인용 |

**`retain_objc_accessible`은 기본값으로 켜져 있습니다.** Periphery는 기본값이 꺼져 있었고,
그것이 혼합 언어 UIKit 프로젝트에서 오탐의 가장 큰 원인이었습니다. 아무도 믿지 않는 미사용
코드 탐지기는 없는 것만 못하므로, Cartograph는 살리는 쪽으로 기웁니다.

프로토콜 요구사항은 오버라이드 관계를 역방향으로 따라가며 처리합니다. 요구사항이 호출되면
그 구현이 전부 도달 가능해집니다 — 단, 구현을 소유한 타입 자체가 도달 가능할 때만이어서,
한 번도 만들어지지 않는 타입이 자신이 호출하는 모든 것을 되살리지는 않습니다. 앞쪽 절반이
없으면 프로토콜 뒤의 타입이 전부 죽어 보이고, 뒤쪽 절반이 없으면 죽은 코드가 쓰이지 않는
준수 뒤에 숨습니다. 두 절반 모두 이 도구를 자기 자신에게 돌리는 과정과 외부 리뷰에서
드러났습니다.

구체 구현을 직접 호출했다고 그 프로토콜 요구사항까지 사용한 것은 아닙니다. 실제 요구사항
호출은 해당 구현과 프로토콜 익스텐션의 기본 구현을 활성화하며, 요구사항의 상속과 클래스
오버라이드 관계도 유지합니다. 선택한 그래프 밖의 프레임워크 계약은 보수적으로 다룹니다.

컴파일러의 넓은 `dynamic` 발생 역할은 Swift의 명시적 `dynamic` 제어자와 다릅니다. 유일한
소스 식별자 위치와 해석된 속성이 일치할 때만 인덱스 근거를 정정합니다. 명시적 `dynamic`,
런타임 치환, Objective-C 노출, 알 수 없는 매크로·소스는 계속 보호하며, 실제로 호출되지 않는
일반 익스텐션 도우미는 보고할 수 있습니다.

`--retain-public`에서는 프로토콜 요구사항과 enum case가 바깥 선언의 접근 수준을 상속하며,
접근 수준을 명시한 익스텐션은 멤버의 기본 접근을 정합니다. public class·struct의 일반 멤버는
여전히 기본값이 internal이고, 익스텐션의 개별 멤버는 기본 접근을 명시적으로 바꿀 수
있습니다.

### 알려진 한계

- **지역 함수 구분에는 소스와 인덱스 근거가 필요합니다.** 신선한 소스에서 함수·메서드·
  이니셜라이저·디이니셜라이저의 정확한 인덱스 소유자와, 모호하지 않은 지역 호출 또는 함수
  값 참조 사슬을 확인하면 지역 함수를 복원합니다. `query`·`impact`의 직접 소비자는 지역
  함수가 되고 바깥 함수는 실제 전이 깊이로 표시됩니다. 익명 클로저는 가장 가까운 이름 있는
  소유자에 남습니다. 기존 `usr` 필드의 `cartograph:local-function:`은 컴파일러 USR이 아닌
  Cartograph 합성 키이며 그대로 다시 질의할 수 있습니다. 지역 선언의 줄·열이 바뀌면 이 키도
  바뀝니다. 호출되지 않거나 재귀만 있는 지역 함수, 이름 가림·오버로드, 지원 밖 매크로·조건부
  컴파일, 낡거나 시각을 모르는 파일은 바깥 인덱스 소유자로 남기고 실제 개수를
  `local-function-projection`으로 알립니다 — 이런 경우 정확한 소유자는 소스를 확인해야
  합니다. 프로퍼티·서브스크립트 접근자는 구분하지 않으며, 호출·일반 참조·포함 관계를 제외한
  사용자 간선 필터에서는 구분을 끕니다. 기본 타입·파일·모듈 그래프는 그대로이고, 심볼
  그래프에는 복원된 지역 함수 사이의 실제 재귀 관계가 나타날 수 있습니다.

- **파일별 신선도가 모든 빌드 구성의 완전성을 뜻하지는 않습니다.** 파일의 최신 유닛 시각으로
  다른 타깃의 빌드가 편집을 가리는 것은 막지만, 같은 파일을 포함하는 모든 구성이
  재빌드됐음을 증명하지는 않습니다. 유닛을 찾지 못한 파일은 별도로 알립니다.

- **`#Preview` 매크로 본문.** `#Preview` 안에서만 쓰이는 타입은 매크로 확장 시 컴파일러가
  참조를 남긴 경우에만 보존됩니다. `PreviewProvider` 준수는 직접 인식하지만 `#Preview` 매크로는
  그렇지 않습니다.
- **Interface Builder 연결을 개별로 대조하지 않습니다.** `retain_interface_builder`가 켜져
  있으면 실제 연결 여부와 무관하게 모든 `@IBOutlet`·`@IBAction`을 보존하므로, 연결이 끊긴
  아웃렛은 보고되지 않습니다. 커스텀 클래스는 이름으로 대조합니다.
- **Objective-C 소스는 심볼 그래프로 분석하지 않습니다.** `.m`/`.h`는 그래프에 보이지
  않으며, 그쪽에서 참조되는 Swift 선언은 기본값이 켜진 `retain_objc_accessible`이 덮습니다.
  `bridges`는 별도로 `.m`의 Flutter 채널·핸들러 패턴과 React Native export 매크로를
  스캔하지만, 이 사실 스캔이 Objective-C 선언을 그래프 정점으로 만들지는 않습니다.
- **다른 언어의 호출자는 isthmus를 통해서만 압니다.** `bridges`는 Swift가 선언한 것을
  내보낼 뿐이고, Dart나 JavaScript가 실제로 부르는지는 이 도구가 하지 않는 조인입니다.
- **대입만 되는 프로퍼티는 쓰이는 것으로 셉니다.** 그래프의 참조 간선은 한 종류뿐이라
  인덱스의 읽기/쓰기 구분을 싣지 않습니다. `counter.neverRead = 1`이 읽는 것과 똑같이
  보입니다. `bump()`가 `neverRead`에 대입만 하고 아무도 읽지 않는 네 줄짜리 패키지에서
  `dead`는 아무것도 보고하지 않고 `query`는 `reachable`, 사용처는 `bump()`라고 답합니다.
  그런 프로퍼티는 지워도 안전하지만 이 도구는 알려 주지 않습니다. 가르려면 읽기·쓰기
  간선이 필요하고 아직 없습니다.
- **컴파일되지 않은 `#if` 분기는 존재하지 않습니다.** 인덱스 스토어는 실제로 빌드한 구성만
  압니다.

## CI

종료 코드로 "코드에 문제가 있음"과 "도구가 실패했음"을 구분할 수 있습니다.

| 코드 | 의미 |
|---|---|
| `0` | 정상 |
| `1` | `--strict` 상태에서 문제 발견, 또는 설정한 임계값 초과 |
| `2` | 도구 실패 — 인덱스 스토어 없음, 인덱스가 이 프로젝트를 하나도 모름, 읽기 실패, 설정 오류 |
| `64` | 사용 오류 — 알 수 없는 옵션·하위 명령·값, 명령이 받을 수 없는 플래그 조합 |

### 공식 액션

컴포지트 액션이 릴리스 바이너리를 내려받고, 인덱스를 만들고, 게이트 하나를 돌린 뒤 SARIF
리포트를 code scanning에 올립니다.

```yaml
name: Cartograph
on: [push, pull_request]
permissions:
  contents: read
  security-events: write          # upload-sarif 에 필요
jobs:
  cartograph:
    runs-on: macos-15             # Cartograph 는 Xcode 툴체인의 libIndexStore 를 읽습니다
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0          # --since 에 기준 커밋 이력이 필요
      - uses: ictechgy/cartograph@main
        with:
          command: check
          since: ${{ github.event.pull_request.base.sha || github.event.before }}
```

릴리스 태그가 `action.yml`을 포함하게 되면 그 태그로 고정하세요(`@main`은 개발 브랜치를
따릅니다). 입력:

| 입력 | 기본값 | 의미 |
|---|---|---|
| `command` | `check` | `check`(dead·cycles·rules 한 번에), `dead`, `cycles`, `rules` |
| `args` | — | 추가 인자, 예: `--limit 500` |
| `version` | `latest` | 내려받을 릴리스 태그, `latest`면 최신 릴리스 |
| `binary` | — | 이미 있는 바이너리 경로. 지정하면 내려받지 않음 |
| `project` | `.` | 분석할 프로젝트 루트. 인덱스 스토어는 여기서 자동 탐색 |
| `build` | `swift` | 분석 전 `swift build`, 직접 빌드했다면 `none` |
| `sarif-file` | `cartograph.sarif` | SARIF 2.1.0 리포트 경로 |
| `upload-sarif` | `true` | code scanning 업로드(`security-events: write` 필요) |
| `fail-on-findings` | `true` | `false`면 발견이 있어도 스텝을 실패시키지 않음 |

출력: `exit-code`(`0` 정상, `1` 발견, `2` 도구 실패)와 `sarif-file`. Xcode 툴체인의
`libIndexStore`를 읽으므로 macOS 러너가 아니면 명확한 메시지와 함께 실패합니다.
`xcodebuild`로 빌드한다면 `build: none`으로 두고 만든 바이너리를 `binary`로 넘기거나,
Cartograph를 직접 설치해 아래 수동 명령을 쓰세요.

액션 없이 같은 게이트를 돌리려면 두 줄이면 됩니다.

```yaml
- run: swift build
- run: cartograph check --strict --report-format github-actions
```

GitHub code scanning에는 SARIF를 냅니다.

```yaml
- run: cartograph dead --report-format sarif -o cartograph.sarif
- uses: github/codeql-action/upload-sarif@v4
  with:
    sarif_file: cartograph.sarif
```

stdio와 워크플로 검증 하네스는 원시 증거를 분석 대상 소스 트리 밖에 남깁니다.

```bash
Scripts/verify-mcp.py --cartograph .build/debug/cartograph
Scripts/benchmark-workflows.py --cartograph .build/debug/cartograph --project .
```

시간 초과, 잘못된 프로토콜 출력, 정합성 불일치가 있으면 실패하며, 비교가 유효하지 않은 속도
측정은 통과로 기록하지 않습니다.
검증 워크로드·측정값·적용 범위는 [워크플로 검증 기록](docs/WORKFLOW-VALIDATION.md)에 있습니다.

## 구조

의존은 한 방향으로만 흐릅니다.

```
CartographCore  ←  Config · Syntax · Analysis · Export · IndexStore  ←  Kit  ←  CLI
```

| 모듈 | 책임 |
|---|---|
| `CartographCore` | 그래프 모델, 인덱스 추상화, 설정 타입. 외부 의존성 없음. |
| `CartographConfig` | `.cartograph.yml` 로딩(Yams). |
| `CartographSyntax` | SwiftSyntax로 접근 수준과 속성 읽기. |
| `CartographAnalysis` | 순환, 도달성, 보존, 지표, 레이어 규칙, 베이스라인. |
| `CartographExport` | 그래프 렌더러와 진단 리포터. |
| `CartographIndexStore` | IndexStoreDB를 건드리는 유일한 모듈. |
| `CartographKit` | 파이프라인 조립. 라이브러리로도 배포돼 임베드할 수 있음. |
| `cartograph` | 인자 파싱과 종료 코드. |

도메인과 알고리즘 계층은 IndexStoreDB가 존재한다는 사실조차 모릅니다. 그래서 픽스처 Xcode
프로젝트 하나 없이도 강제된 90% 커버리지 게이트를 지킬 수 있습니다 — 분석은 손으로 만든
스냅샷 위에서 돌아갑니다.
커버리지 게이트는 단위 테스트와 계측된 CLI 통합 하네스를 합산하며 단위 테스트만의 비율도
따로 표시합니다. 의존성 발견 재현율은 정답 코퍼스로 별도 측정하며 라인 커버리지에서
추론하지 않습니다.

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

베이스라인·임계값·출력 형식은 CI 정책이라 별도의 명령 API(`detectCycles()`,
`detectUnusedCode()` 등)에 있습니다. 프로그램에서 호출하는 쪽이 표를 파싱할 일은 없습니다.

## 프로젝트 언어

문서와 사용자에게 보이는 출력은 영어, 소스 주석은 메인테이너의 작업 언어인 한국어,
식별자는 항상 영어입니다. PR은 어느 언어로 써도 됩니다.

## 기여

[CONTRIBUTING.md](CONTRIBUTING.md)를 보세요. 이 저장소에서 작업하는 에이전트는
[AGENTS.md](AGENTS.md)를 먼저 읽어야 합니다.

## 라이선스

MIT. [LICENSE](LICENSE)를 보세요.

Cartograph는 독립 프로젝트이며 Periphery나 Apple과 관련이 없습니다.
