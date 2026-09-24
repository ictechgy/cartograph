# Handoff

> 2026-09-23까지 보존한 과거 기록이다. 현재 재개 정보는 [HANDOFF.md](HANDOFF.md)를 따른다.
> 아래 버전·대기·Next Steps·Resume Prompt는 각 기록 당시의 상태이며 현재 작업 지시가 아니다.

_Last updated: 2026-09-20 (0.20.0 GitHub·Homebrew 발행/설치 검증 완료)_

재개 시 [Current Status](#current-status) → [Next Steps](#next-steps) →
[Resume Prompt](#resume-prompt)를 읽는다. 아래 Goal과 날짜별 완료·검증·배포 기록은 당시의
범위를 설명하며, 현재 발행·개발 상태는 Current Status 첫 항목을 우선한다.

## Goal

경쟁 강화(warm 질의·dead 경고 3종·온보딩 안내), **0.17.0 릴리스와 Homebrew 배포**,
bridge-facts EventChannel·FFI interop 한계·Expo Modules, README 영·한 퇴고까지
**전부 머지·배포 완료**했다. 0.18.0(Expo Modules + impact 인접 목록)도 릴리스됐다.
0.19.0(불필요 ignore·public 경고, fix, affected, GitHub Action, equatable/hashable 보존)도
릴리스됐다 — Homebrew 탭 [PR #48](https://github.com/ictechgy/homebrew-tap/pull/48)도 머지돼
formula가 0.19.0을 가리킨다.
이후 경쟁 갭 분석(`docs/evaluation/2026-09-18-competitive-gaps.md`, PR #107에 포함)을
거쳐 사용자가 "순차적으로" 갭을 닫기를 요청했다. 순서: ①웜 query 지연 →
②불필요 ignore 감지 → ③불필요 public 경고 → ④impact --before 제거 간선 →
⑤기계적 fix → ⑥impact 입도 → ⑦테스트 영향 질의 → ⑧공식 GitHub Action →
⑨equatable/hashable 옵션 → ⑩런타임 텔레메트리(연구 전용 보류).
①은 PR #106, ②는 PR #107, ③은 PR #110, ⑤는 PR #112, ⑦은 PR #114, ⑧은 PR #116,
⑨는 PR #118로 **완료**했다. ④impact --before 제거 간선은 **0.17.0의 `scopeDiff`(PR #93)로
이미 완료**, ⑥impact 입도도 **수신 타입을 호출자로 세던 결함 수정(0.14.0)으로 이미 완료**돼
있었다 — 고정 리비전 Alamofire·Kingfisher에 현재 바이너리를 돌려 gold 소비자만 나옴을
확인했다(2026-09-19). 경쟁 갭 문서의 4·6번이 stale이었다.
순차 갭 목록은 **⑩런타임 텔레메트리(연구 전용 보류)만 남았다** — 이후 작업은 아래
"경쟁 조사 — codegraph 대비 개선점" 섹션의 후보(C1~C5·S1~S6)와 릴리스 후속이다.

컨테이너 확장 인접-목록 개선은
[PR #104](https://github.com/ictechgy/cartograph/pull/104)로 **스쿼시 머지 완료**했다
(`6bbf766`, 리뷰 head `be7af2a`, CI 녹색). 브리지 `sourceCache` 최적화는 미착수 보류다.

## Current Status

### 0.20.0 발행 검증 — 2026-09-20

- [PR #125](https://github.com/ictechgy/cartograph/pull/125)·tag `0.20.0`은 `d7df412`다. 브리지 커밋 `5c43c36`의 포함 관계를 Git으로 확인했다.
  [release run 35459152441](https://github.com/ictechgy/cartograph/actions/runs/35459152441)이 성공했다.
- GitHub universal archive SHA256은 `833eb3c86deffc8e7c845297df57d41e35bb644bd5a943b09843e52075c6f072`.
  독립 다운로드 파일·릴리스 노트를 대조했고 arm64/x86_64·--version 0.20.0·CLI 계약을 확인했다.
- Homebrew 탭 [PR #49](https://github.com/ictechgy/homebrew-tap/pull/49)이 머지됐다(`72144ee`).
  formula URL·SHA를 대조하고 호스트에서 0.18.0→0.20.0 upgrade 및 brew test를 통과했다.
- Clang ObjC 그래프·보존과 Swift RN 이벤트 추출이 이 발행본에 포함된다. isthmus 0.8.0 후보
  아카이브 및 자매 발행본으로 실제 Clang/이벤트/공개 plugin 왕복을 검증했다. 이후 사용자가
  npm 0.8.0을 발행했고, registry 아카이브가 후보와 바이트 단위로 같으며 별도 설치의 CLI 계약·
  cold-cache 검사가 통과했다. 네 저장소 호환 세트의 발행·설치 검증은 완료됐다.
  최종 근거는 [isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md)에 있다.
- 이번 브리지의 이전 미발행 표기는 이 절의 0.20.0 발행으로 해소됐다. 아래 0.19.0의 호스트 설치 대기와
  과거 미검증 표기는 해당 시점의 기록이며 반복할 작업이 아니다. 전체 후속 진행은
  [isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md)를 확인한다.

### 완료 — 자매 브리지 확장 (2026-09-20, PR #123)

- [PR #123](https://github.com/ictechgy/cartograph/pull/123)을 squash merge했다(`5c43c36`).
  로컬 `main`과 원격 `main`이 같고 머지 트리의 내용 해시는 검토·CI를 통과한 PR head의 tree 해시와 일치한다.
  이 HANDOFF는 해당 머지의 인계 기록이다.
- `.m`/`.mm`의 Clang 선언·참조를 일반 그래프에 포함하고 RN 구현 매크로에 실제 USR를
  연결한다. 같은 줄의 보조 class method와 instance method를 구분하며, 다른 파일의 선언이나
  셀렉터 이름으로 ID를 추측하지 않는다. isthmus의 ObjC retention이 실제 정점까지 연결된다.
- `bridges --rn-events`는 직접 Swift RCTEventEmitter 하위 타입의 방출을 v2
  `react-native-event`로 낸다. 조건부 import/본문·extension·파일 단위 가림·읽기 실패로
  관찰하지 못한 범위를 limitations에 남긴다. ObjC/Expo 이벤트·간접 emitter·전체 앱 실행은
  이번 정적 추출 범위에 포함되지 않는다.
- [CI run 35453717002](https://github.com/ictechgy/cartograph/actions/runs/35453717002)의
  coverage와 자기 분석 잡 모두 성공했다. 앞선 로컬 검증은 테스트 1,647개·coverage 92.84%,
  CLI·실제 compiler fixture·strict 자기 분석 4종 통과다. Clang→ObjC retention→explain,
  JS/Swift/Kotlin RN 이벤트 조인, Dart/Swift 왕복·limitation-scopes·고정 공개 battery
  플러그인의 macOS retention도 isthmus 하네스로 검증했다.
- GLM은 packet-ask 패킷 `0d5b0f1cd8cc`와 수정분 `125112deba78`로 검토했다.
  [반영·기각 근거](https://github.com/ictechgy/cartograph/pull/123#issuecomment-5743320171)를
  PR에 남겼다. 이전 임시 로그 경로의 존재를 가정하지 말고 PR/CI를 근거로 사용한다.
- 동반 머지: isthmus [#96](https://github.com/ictechgy/isthmus/pull/96), kartograph
  [#82](https://github.com/ictechgy/kartograph/pull/82), dartograph
  [#127](https://github.com/ictechgy/dartograph/pull/127).
  계약은 [GRAPH-EXCHANGE](https://github.com/ictechgy/isthmus/blob/main/docs/GRAPH-EXCHANGE.md), 전체 실행 기록은
  [isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md)를 참조한다.
- 이번 구현·검증·머지의 남은 작업은 없다. 새 태그/배포는 하지 않았고, 이 변경을 기존
  0.19.0 발행본에 포함된 기능으로 설명하지 않는다. 브리지 `sourceCache` 최적화는 여전히 별도 후보다.

### 완료 — ⑨ Equatable/Hashable 저장 프로퍼티 보존

[PR #118](https://github.com/ictechgy/cartograph/pull/118) 스쿼시 머지(`773ee6d`, 2026-09-19).
CI 녹색(Build/test/coverage + 자기 분석). 아래는 구현 기록이다.

- **구현:** `retain_equatable_properties`·`retain_hashable_properties` 옵션(기본 켬). 구문
  상속 절에서 `.equatable`/`.hashable` 표식을 남기고, 부모가 값 타입이면 저장 프로퍼티를
  `.equatableProperty`/`.hashableProperty` 근거로 보존한다. 익스텐션에 선언한 준수도 타입
  본체에 적용된다(`conformanceDerivedAttributes`).
- **의미:** `Hashable`은 `Equatable`을 상속하므로 Equatable 옵션만으로도 Hashable 타입의
  프로퍼티가 보존된다(Periphery `isEquatable` 목록과 동일). 클래스는 제외 — `==`/`hash(into:)`
  합성이 값 타입에만 적용되고, 클래스의 직접 구현 읽기는 인덱스에 남는다.
- **기본값 선택:** Periphery는 두 옵션 모두 기본 꺼짐이지만 이 저장소는 켬으로 둔다
  (`retain_codable_properties`와 같은 이유 — 인덱스에 읽기 흔적이 없는 합성 판독기).
  README가 그 차이를 설명한다.
- **검증:** 신규 테스트 6개(Equatable/Hashable 근거·옵션 off·Hashable→Equatable 폴백·클래스
  제외·익스텐션 준수·상속 절 표식·옛 설정 기본값). 변이 3종(옵션 게이팅 제거·클래스 제외
  제거·폴백 제거) 각각 해당 테스트 실패. 전체 1,640개 중 실패 56건은 전부 샌드박스 임시
  디렉터리 차단(단언 실패 0). strict 자기 분석 4종·CLI 계약·release 빌드 통과.
  근거 문장 고정 테스트(ModelTests)에 새 문구를 추가.
- **남은 것:** 없음 — 순차 갭 목록은 ⑩(연구 전용)만 남았다.

### 완료 — ⑧ 공식 GitHub Action

[PR #116](https://github.com/ictechgy/cartograph/pull/116) 스쿼시 머지(`195e25b`, 2026-09-19).
CI 녹색(Build/test/coverage + 자기 분석, 자기 분석의 `GitHub Action smoke` 단계 실행 성공).
아래는 구현 기록이다.

- **구현:** 루트 `action.yml` composite action. 흐름은 릴리스 자산 다운로드(또는 `binary`
  입력) → 인덱스 빌드(`build: swift` 기본, `none` 가능) → 게이트 하나
  (`check|dead|cycles|rules`) `--strict` → SARIF 출력 → 기본 업로드
  (`github/codeql-action/upload-sarif@v4`).
- **계약:** `fail-on-findings: false`면 보고 전용이고, 종료 코드로 발견(1)과 툴 실패(2)를
  구분한다. 비-macOS 러너는 `libIndexStore`를 읽을 수 없어 명확한 메시지로 실패한다.
  출력은 `exit-code`·`sarif-file`.
- **검증:** CI 자기 분석 잡이 `uses: ./`로 커밋된 action.yml을 매 PR마다 태운다(이미 빌드한
  바이너리를 `binary`로 전달, 업로드 off). 매니페스트 테스트 4개가 선언/참조 입력 드리프트,
  컴포지트 `run` 단계의 `shell` 누락, 게이트 허용 목록 vs 등록 하위 명령, README 안내를
  고정한다. 셸 로직은 통과 게이트(exit 0)·픽스처 `dead`(exit 1, SARIF results 30)·
  `fail-on-findings` true/false 경로로 로컬 재현했고, Yams로 action.yml 파싱을 확인했다.
- **남은 것:** 다음 릴리스가 action.yml을 포함하면 README 예시를 태그로 고정(현재 `@main`),
  Marketplace 게시와 이동 메이저 태그(`v1`)는 저장소 설정 몫. `upload-sarif` 경로 자체는
  코드 스캐닝 설정에 의존해 이 저장소 CI에서는 실행하지 않았다(스모크는 SARIF 파일 생성까지).

### 완료 — ⑦ 테스트 영향 질의 (`affected`)

[PR #114](https://github.com/ictechgy/cartograph/pull/114) 스쿼시 머지(`49ce665`, 2026-09-19).
CI 녹색(Build/test/coverage + 자기 분석). 아래는 구현 기록이다.

- **구현:** `cartograph affected [--since <rev> | --file <path> | <symbol>] [--depth]
  [--limit] [--format text|json]`. CI의 "이 변경에 어떤 테스트를 돌리나"에 답한다.
  소비자를 따라가 테스트 선언(XCTest·swift-testing)만 depth·경유(`via`)·관계·간선과
  함께 보고하고, 변경이 직접 건드린 테스트는 depth 0 `changed`로 싣는다.
- **배관 공유:** 시드 선택·컨테이너 확장·디스패치 투영·깊이 제한은 `impact`와 같은
  것을 쓴다 — 답이 갈라지면 같은 변경에 두 명령이 다른 테스트를 말하게 된다.
  `--since` 변경 목록 계산은 `ChangedSelectionSupport`로 모아 impact와 공유한다.
- **정직성 계약:** 정적 도달성이다. 빈 목록은 명시적으로 "테스트가 닿지 않는다"고
  말하고, 모든 응답에 "기존 테스트의 커버리지 증거가 아니다" 문장과 분석
  `limitations`를 싣는다. 테스트 타깃이 분석 범위 밖이면 `configured-path-filter`
  한계가 그 사실을 설명한다.
- **문서:** `change-affected` v1(text/json). `--limit` 초과 시 전체 개수와
  `truncated.sections == ["tests"]`.
- **착수 전 확인:** ⑥impact 입도는 stale이었다 — 파일럿의 containing type 2건은
  `self.` 호출의 수신 타입이 소비자로 새던 결함(`receivedBy`)이었고 "Stop treating
  receiver types as callers"(0.14.0)로 이미 수정됐다. 고정 리비전 Alamofire(`bda9ed5`)·
  Kingfisher(`ab1c1de`)를 빌드해 현재 바이너리로 depth 1·3 재현 → gold 소비자만 나오고
  containing type 0건. 경쟁 갭 문서 4·6을 완료로 표시하고 2·3·5·7 표시도 함께 정리했다.
- **검증:** 신규 테스트 13개(Kit 8·CLI 5). 변이 2종(테스트 근거 필터 제거·depth 0
  변경 테스트 포함 제거) 각각 해당 테스트 실패. 전체 1,630개 중 실패 56건은 전부
  샌드박스 임시 디렉터리 차단(단언 실패 0). CLI 계약(affected --help·사용 오류 6종)·
  strict 자기 분석 4종·release 빌드 통과.
- **CI가 잡은 것:** 새 CLI 파일이 `ImpactCommand ↔ ChangedSelectionSupport` 타입
  순환을 만들어 `cycles --level type --strict`가 실패 — `isModeledChange`를 helper로
  옮겨 해소(공유 시드 헬퍼는 명령 타입을 참조하지 않는다).
- **남은 것:** affected 코퍼스 골든(코퍼스 설정이 테스트 타깃을 제외해 불가),
  스킬 문서 안내 추가 후보.

### 완료 — ⑤ 기계적 fix

[PR #112](https://github.com/ictechgy/cartograph/pull/112) 스쿼시 머지(`1bd0cf7`, 2026-09-19).
CI 녹색(Build/test/coverage + 자기 분석). 아래는 구현 기록이다.

- **구현:** `cartograph fix [--apply] [--format text|json] [--since <rev>]`. 기본은
  드라이런이고 `--apply`로만 파일을 쓴다. 고치는 규칙은 두 개로 고정한다 —
  `unused-import`는 import 선언을 줄째로 제거, `unused-parameter`는 인자 레이블을
  남긴 채 내부 이름만 제거(`func f(retry:)` → `func f(retry _:)`, 연산자 함수는
  레이블이 무의미해 이름만 `_`). 나머지 경고는 사람의 판단이 필요해 건드리지 않는다.
- **검증이 곧 구현:** 위치로 밀어 넣지 않는다. 지금 소스를 다시 파싱해 (a) 기록된
  자리에 기대한 선언이 있고, (b) import 줄에 다른 코드·블록 주석이 없고, (c) 편집
  결과가 다시 파싱되는 편집만 계획으로 인정한다. 드라이런에서도 메모리에서
  편집·재파싱을 수행한다. 실패한 편집은 이유(`notFound`·`lineHasOtherCode`·
  `alreadyUnnamed`·`sourceHasErrors`·`resultHasErrors`·`overlapping`·`unreadable`)와
  함께 skip으로 보고한다.
- **쓰기:** `FileSystem.write`의 파일 단위 원자적 쓰기 그대로. 텍스트 재작성 없이
  구문 트리에서 찾은 UTF-8 범위만 바꿔 끼워 주석·공백을 보존한다.
- **선별:** `dead`와 같은 `filterAndApplyBaseline` 경로로 `--since` 렌즈와
  베이스라인을 적용한다 — 이미 받아들인 발견은 건드리지 않는다.
- **종료 코드:** `--apply` 없이 `--strict`면 계획이 남아 있는 동안 1(CI 게이트),
  적용 뒤에는 skip이 있을 때만 1.
- **낡은 인덱스에서 멈춘다:** 편집 뒤 같은 스냅샷으로 다시 돌리면 import 발견은
  사라지고, 자리가 어긋난 파라미터는 `notFound`로 skip된다 — 두 번째 편집을
  추측하지 않는다. README가 새 빌드에서 돌리라고 안내한다.
- **검증:** 신규 테스트 26개(구문 16·Kit 8·CLI 2). 변이 5종(소스 파싱 가드 제거·
  모듈 경로 대조 제거·줄 내용 가드 제거·레이블 보존 제거·드라이런 쓰기 조건 제거)
  각각 해당 테스트 실패. 전체 1,614개 중 실패 56건은 전부 샌드박스 임시 디렉터리
  차단(단언 실패 0). CLI 계약·strict 자기 분석 4종(새 인덱스)·release 빌드 통과.
  자기 분석에서 `fix`는 `no mechanical fixes found`.
- **남은 것:** 코퍼스 fix 골든(검출 방향, 샌드박스에서 픽스처 재빌드 불가),
  스킬 문서에 `cartograph fix` 안내 추가 후보.

### 완료 — ③ 불필요 public 접근 수준

[PR #110](https://github.com/ictechgy/cartograph/pull/110) 스쿼시 머지(`711a2b4`, 2026-09-19).
CI 녹색(Build/test/coverage + 자기 분석). 아래는 구현 기록이다.

- **구현:** `dead`에 `redundant-public` 경고(비-strict, strict 카운트 제외). 같은 모듈
  안에서만 참조되는 public 선언을 "internal로 줄일 수 있다"고 보고한다. 판정은 보수적인
  두 질문이다 — ① 출처 모듈을 증명하지 못하는 참조가 하나라도 있거나 다른 모듈 참조가
  있으면 침묵, ② 다른 공개 선언의 인터페이스(시그니처·상속 절·제네릭 제약·기본값)가
  참조하면 침묵. 본문 자리 참조는 요구가 아니다. 오버라이드(문법 표식 + `overrideOf`
  관계)·프로토콜 요구사항/증인·enum case·`@objc`/IB/dynamic/런타임 관리·테스트 타깃·
  설정 보존·외부 브리지 근거는 제외한다.
- **참조 0건은 보고하지 않는다.** `retain_public`이 살려 둔 API 전체를 "internal로
  줄이라"고 하면 보고가 쏟아지고, 미사용 여부는 `unused-symbol`이 따로 답한다.
- **`retain_public` 상호작용(Periphery와 동일):** 보존 근거가 `.publicAPI`인 정점은
  전부 제외해 규칙이 침묵한다 — 공개 표면이 의도적이라는 선언이고, 라이브러리는 자기
  API를 모듈 안에서 읽는다. 이 저장소 자기 분석 설정이 `retain_public: true`라 자기
  분석에서는 0건이다. 기본 모드(앱·모노레포)에서 쓰는 규칙이다.
- **자리 분류 인프라:** `IndexedReference.position`(signature|body|unknown) 추가.
  `ReferenceBodyScanner`가 CodeBlock/AccessorBlock 구간을 모으고 `SnapshotEnricher`가
  참조 위치로 분류한다. `@inlinable`/`@usableFromInline`/`@_transparent`/
  `@_alwaysEmitIntoClient` 본문은 본문으로 기록하지 않는다 — 그 안의 참조는 공개
  노출을 요구할 수 있다. 판단 못 한 참조는 unknown으로 두고 인터페이스처럼 다룬다
  (본문으로 잘못 낮추면 필요 없는 공개 노출을 요구하지 않아 오탐이 된다). 구문 캐시
  스키마 14, 분석기 개정 21.
- **②와의 일관성:** superfluous-ignore 반사실이 이 규칙의 발견도 세도록 analyzer를
  넘긴다 — 이 경고를 실제로 억제하던 주석을 "아무 일도 하지 않는다"고 오판하지 않는다.
- **CI가 잡은 두 문제:** ① `ReferenceBodyScanner`의 중첩 Collector가 바깥 타입 정적
  API를 불러 타입 레벨 자기 순환이 생겼다(`cycles --level type --strict` 실패) — 방문자와
  공유 속성 집합을 파일 범위로 내렸다(`ef16c07`). ② 코퍼스 기본 모드 0건 가정이 틀렸다 —
  새 인덱스 기준으로 코퍼스에 실제 모듈 내 전용 public 표면(`InheritedAccessHost`)이
  있었다 — 기본 모드 단정을 빼고 결정적인 `retain_public` 침묵만 고정한다(`49d55cf`).
- **검증:** 신규 테스트 27개(분석 17·구문 10), 변이 5종(자리 분류 뒤집기·교차 모듈 검사
  제거·조상 노출 검사 제거·무시 제외 제거·②반사실 훅 제거) 각각 해당 테스트 실패.
  전체 1,588개 중 실패 56건은 전부 샌드박스 임시 디렉터리 차단(단언 실패 0). CLI 계약·
  strict 자기 분석 4종(새 인덱스)·release 빌드 통과. CI 두 잡 통과.
- **남은 것:** 코퍼스 검출 방향 골든(샌드박스에서 픽스처 재빌드 불가로 생성 못 함),
  `retain_public: true`인 라이브러리용 `--no-retain-public` 탈출구 후보.

### 완료 — ② 불필요 `cartograph:ignore` 감지

[PR #107](https://github.com/ictechgy/cartograph/pull/107) 스쿼시 머지(`66037f8`, 2026-09-18).
ultra-review 3라운드 반영까지 전 게이트·CI 통과 후 머지. 아래는 구현 기록이다.

- **구현:** `ReachabilityAnalyzer.superfluousIgnores`가 반사실 판정을 한다.
  자기 주석이 있는 `.ignoreComment` 정점(`.ignoreInherited`가 아닌 것)마다
  단위를 세우고, 단위는 `.member` 간선(같은 파일 한정)으로 덮는 무시 자손을
  함께 묶는다 — 조상 주석이 물려준 무시(`.ignoreInherited`)는 자기 단위를
  만들지 않고 덮는 주석의 판정에 접힌다. 그 단위만 뗀 도달성을 다시 돌려
  새 발견이 없으면 `superfluous-ignore` 경고로 보고한다. 파일 범위 단위는
  `.ignoreAllComment` 표식이 있을 때만 만든다 — `SnapshotEnricher`가
  `ignore:all` 파일의 심볼에 `.ignoreComment`와 함께 출처 표식을 단다.
  겹친 단위는 커버리지 중복도로 처리하고, **확정된 단위의 주석은 뒤 판정에서
  뗀 채로 누적한다** — 서로만 참조하는 무시 덩어리에서 앞 주석 하나만 보고해
  "보고된 주석을 모두 떼어도 새 발견이 없다"는 보장이 성립한다.
  `RetentionPolicy`의 `retainedNodesWithoutIgnoreComments`로 같은 규칙의
  보존을 재계산하고, `findsTestOnlyCode`가 켜져 있으면 반사실 세계의
  test-only 보고 변화도, assign-only·미사용 import 발견 변화도 필요 조건으로
  본다. 진단은 `dead` 전용 경고(strict 미포함), 베이스라인 키는
  `usr|ignore`·`ignore:file:<path>`.
- **성능:** 단위별 반사실은 `traverse`의 `alreadyReached` 시드로 무시 영역만
  걷는다. 시드 정점은 큐에 들어가지 않아 역방향 오버라이드 증인이 누락될 수
  있어, 시드의 incoming `.overrides` 간선만 따로 검사한다(회귀 테스트 고정).
- **그 과정에서 찾아 고친 버그:**
  - `CommentCommand.parse`가 부분 문자열 매칭이라 문서 주석이 명령을 *언급*만
    해도 `.ignoreComment`가 붙던 기존 오탐 — 주석 맨 앞 접두사+경계 매칭으로.
  - 영속 IndexStoreDB 캐시가 지워진 유닛을 잊지 않아 파일 발생을 통째로
    삼키던 결함 — 유닛 집합 지문(FNV-1a)을 DB 경로에 섞고, 지문 실패 시
    `-unverified` 전용 경로(버전 없는 낡은 경로 재사용 금지), 열 때 형제 DB를
    정리한다(`prepareReaderDatabase`/`pruneStaleReaderDatabases`,
    `FileSystem.removeItem` 추가로 모든 래퍼 갱신).
- **ultra-review 1라운드 반영:** claude×2·codex 전부 CHANGES_REQUESTED, agy
  6/16샤드(3 APPROVE·3 CR, 나머지 headless 권한 거부 무출력), grok 무효.
  반영: strict-weak-ordering 비교자(`locationThenID` 통일), 크로스파일 멤버
  흡수 차단, `.ignoreAllComment` 출처, testOnly 반사실, -unverified+형제 정리,
  누적 판정(상호 의존), 시드 오버라이드, `#require` 안전 단언.
- **ultra-review 2라운드 반영:** claude-A 10건·claude-B 8건·codex 6건(전부 CR),
  agy·grok 재시도 무효(타임아웃·무출력). 합의 블로커: `-unverified` 재사용
  (실행 간 유령 재현) → 열기 전 삭제로, `baseName-*` 광범위 정리 → 접미가
  `unverified`|16진인 항목만, 빈 `fileIgnored` 가드. 단독 트랙 실결함: 중첩
  주석 독립 단위화, 위치 없는 정점 nil==nil 그룹화 → 단일 단위,
  `FileSystem.removeItem` 필수 메서드 → 기본 구현으로 소스 호환성 유지,
  assign-only·unused-import 반사실 누락 → `honoringIgnoreComments`·
  `exposesIgnoredImport` 추가. 기각: 조건부 증인(기존 처리)·InMemory 모델 일치·
  문서화 한계·스냅샷 캐치 없음.
- **2라운드 반영이 드러낸 근본 문제:** 중첩 단위화가 전파 무시와 자기 주석을
  구별하지 못해 fixture가 깨졌다 — 선언 주석은 `context.isIgnored`로 멤버에
  `.ignoreComment`를 물려주므로, 자기 주석 없는 멤버가 유령 단위를 만들어
  `ping()` 발견과 `IgnoredAndDead` 필요 주석의 불필요 오판을 냈다. 신규
  `.ignoreInherited` 표식으로 전파 무시를 구별해 자기 주석이 있는 정점만
  단위로 세운다 — 부모 주석은 서브트리 전체를 덮는 것이 실제 의미다.
- **ultra-review 3라운드 반영(수정분 대상):** claude·codex 전부 CHANGES_REQUESTED
  (agy·grok은 지속 무효로 미투입 — 커버리지 갭 기록). 합의: 형제 정리 접미가
  임의 길이 16진을 지움(`db-2024` 등) → 지문을 고정폭 16자로 두고 접미도 정확히
  그 형태만; `-unverified` 삭제 실패 삼킴 → 없음 외 실패 시 일회용
  `-unverified-<uuid>` 경로(낡은 DB 재사용 금지). 단독 실결함: 무시 부모 없는
  `.ignoreInherited` 고아가 어느 단위에도 못 들어가 주석이 영구 미판정 → 고아를
  단위 꼭대기로 승격(이전 동작 복원); `exposesIgnoredImport`가 자기 `ignore`
  있는 import까지 풂 → `IndexedImport.isIgnoredOnlyByFileComment` 출처 추가.
  LOW 반영: prune의 동시 실행 경쟁 → `modificationDate` 유예(300초),
  구문 계층 `.ignoreInherited` 핀 테스트, 죽은 부모+자기 주석 멤버·삼단 중첩
  핀 테스트, README에 멤버→부모 보존 규칙 한 문장. 부수 수정: `.ignoreInherited`
  도입 때 누락된 SourceFactsCache schemaVersion 12→13(낡은 캐시의 상속 표식
  없는 facts가 유령 단위를 되살림).
- **검증:** SuperfluousIgnoreTests 28개 + ReaderDatabasePathTests 11개 +
  구문 핀 테스트. 변이 확인: 고아 승격 제거·`isIgnoredOnlyByFileComment`→`isIgnored`·
  지문 길이 제한 제거·unverified 폴백 `try?`·prune 유예 제거 각각 해당 테스트 실패.
  전 게이트 통과(테스트·커버리지 93.05%·fixture·CLI 계약·strict 자기 분석).
- **남은 것:** 없음 — 2026-09-18 머지 완료.

### 완료 — ① 웜 query 지연

[PR #106](https://github.com/ictechgy/cartograph/pull/106) 스쿼시 머지(`72f3be0`).
웜 `query`/`status` ~9ms → ~0.1ms. ultra-review 6라운드로 수렴, serve에
`--session-freshness-interval`(기본 1초, [0, 86400]) 추가.

<details><summary>① 상세(완료 기록)</summary>

- **병목 규명:** `describeQuery`는 이미 완전히 bounded(explain + `GraphNeighborhood`
  BFS 2개 + containment 2개 + 증거 예산 200)이고, `QuerySession`은 세션당 한 번 만들어
  캐시된다. 웜 호출의 실질 비용은 `ensurePrepared`의 **매 요청 입력 지문 재계산** —
  이 저장소에서 ~9ms(status≈query로 분리 측정), 소스+인덱스 파일 전부 stat.
- **구현:** `AnalysisSession`에 `freshnessCheckInterval`(기본 `.zero` = 기존 동작인
  요청마다 검증)과 주입 가능한 `now` 시각 소스를 추가하고, 창 안의 연속 요청은
  마지막 검증 세대를 그대로 쓴다. `serve`는 `--session-freshness-interval`로
  창을 받는다(기본 1초, `[0, 86400]` 밖은 거부 — inf/nan 포함). 성공한 reload도
  검증 시각으로 간주해 관측 시작 시각을 찍는다. `cartograph_status`의
  `refresh: true`는 `session.refresh()`로 창을 우회한다. `runtimeContext`의
  Core Data 증거 검증은 명시적이므로 창과 무관하게 매번 수행.
- **계측**(release, 이 저장소): 창 안 웜 status/query **~0.0-0.1ms**(이전 ~9ms),
  창 경과 후 첫 호출 ~9-11ms(재검증 정상), 첫 요청 ~0.7-1.9s(세션 준비, 무관).
- **계약 검사:** `verify-mcp.py`는 기본 창 경로를 측정 구간이 창 안인 시도만
  단언하며 최대 세 번 재시도하고, 창 메커니즘은 `--session-freshness-interval 300`
  별도 서버에서 재사용·우회·편집 감지를 스케줄러 지연과 무관하게 단언한다.
- **테스트 8개(주입 시계로 수면 없이 결정적):** 창 안 미재독+이전 세대 사용,
  창 경과 후 재검증, 명시 refresh 우회+창 재시작, `.zero`·음수 기본값, 변경 없는
  재검증의 창 재시작, refresh 실패 폐기, 창 만료 후 지문 실패 폐기·복구.

</details>

### 완료된 개선 — 2026-09-18

- [PR #104](https://github.com/ictechgy/cartograph/pull/104) 스쿼시 머지(`6bbf766`,
  2026-09-18). ultra-review 3라운드 — 라운드 1에서 상대 타이밍 상한·진짜 순환
  픽스처·생성기 확장·계약 고정 테스트를 반영했고, 라운드 2·3은 블로커 0건으로
  수렴했다(사용 가능 트랙: Claude·Codex·Antigravity; Grok은 출력 계약 무효로 제외).
  agy 단독 HIGH("방문 집합 재사용이 비컨테이너 시드 자식을 생략")는 기준 구현과
  동일한 상속 계약이라 기각하고 테스트로 고정했다. CI에서만 드러난 `Expander`
  memberwise init 접근 수준 오류는 명시 init으로 고쳤다(`be7af2a`).
  변경 파일: `Sources/CartographKit/ImpactService.swift`(위임으로 축소), 신규
  `Sources/CartographAnalysis/ImpactSelectionExpansion.swift`·
  `Tests/CartographAnalysisTests/ImpactSelectionExpansionTests.swift`,
  `CHANGELOG.md`(`Unreleased`의 Changed에 impact 확장 개선 항목).
- **초안의 동등성 갭을 찾아 고쳤다.** 초안은 도달한 정점이 컨테이너(타입·익스텐션)일
  때만 이웃을 수집해, 도달된 메서드 아래 지역 선언(인덱스는 parentUSR로 남기고
  `LocalFunctionBinder`도 `?? owner.usr`로 단다)과 그 하위 트리를 빠뜨렸다.
  최종 구현은 도달한 **모든** 정점의 자식 집합을 방문 시점에 인접 목록으로
  계산한다(pull 모델): 어휘 멤버 + `semanticParent`가 그 정점인 멤버 + 그 정점을
  확장하는 익스텐션. 다중 member 부모·다중 extends 같은 비정상 그래프까지
  원 구현의 `children[X]` 집합과 정확히 같다.
- **Codex 독립 리뷰 1건 확정·수정.** 익스텐션 하나가 도달된 타입 여럿을 확장하면
  멤버 목록을 타입마다 다시 훑어 `semanticParent` 조회까지 곱해지는 최악
  (병적 그래프에서 원 구현보다 나쁨). `Expander`가 익스텐션 멤버를 의미 부모별로
  한 번만 그룹핑해 캐시하게 고쳤다. LOW 2건도 반영: 순환 테스트를 진짜 순환
  (익스텐션 둘의 상호 extends)으로 교체, "익스텐션 시드는 확장 대상 타입을
  포함하지 않는다" 계약을 문서·테스트로 고정. 30ms 상한의 한계(간선 방문 횟수가
  아닌 타이밍 단언)는 인정하나 저장소 관례와 CodeGraph API 범위 안에서는 유지.
- **계측**(디버그, 44k 정점/140k 간선): 좁은 선택 58.3ms → 0.15ms(~400×),
  넓은 선택(22k 정점 도달) 78.9ms → 38.1ms(~2×). 두 결과 집합은 동일했다.
- 테스트 9개: 지역 선언 하위 트리, 익스텐션·의미 부모, 익스텐션 시드 계약,
  진짜 순환 종료, 비컨테이너 시드, 기준 구현 대조, **시드 고정 무작위
  프로퍼티**(40 그래프×12 시드 — 초안에서는 114건 불일치로 실패 확인),
  좁은 선택 상한 30ms(기준 구현은 ~58ms라 분리됨; 노이즈 간선은 도달 범위 밖
  정점끼리 둬야 상한이 의미 있다).
- 실 저장소 스모크: `cartograph impact CodeGraph` → changeScope 39 · affected 260
  (신규 파일이 인덱스에 들어와 +2; 리뷰 수정 후 재실행도 동일).
- 브리지 원문 캐시(`CartographService.swift`의 `sourceCache`)는 **변경하지 않았다**.
  재읽기로 메모리를 줄이면 2패스가 서로 다른 소스 상태를 볼 수 있다. 일관성을 유지하는
  작은 개선이 입증되지 않으면 보류하고 메모리 계측 결과부터 확보한다.
- 보안: Codex 읽기 전용 정적 검토에서 MCP·런타임 경계의 확정 취약점 없음.
  전체 저장소/의존성 감사나 동적 보안 검증은 아니며 보안 수정은 없다.
- 리뷰 오탐: `GraphQueryIndex.similarCandidates`가 동명 정점 전부를 추천한다는 제안은 기각.
  실제 70행은 이름별 `.first`를 이미 고른다. 이 제안을 근거로 수정하지 말 것.

### 이미 완료된 릴리스 이력

- [0.19.0 릴리스](https://github.com/ictechgy/cartograph/releases/tag/0.19.0) 공개(2026-09-19).
  버전 범프 [PR #120](https://github.com/ictechgy/cartograph/pull/120)(`9baf1ab`), 태그 `0.19.0`,
  릴리스 워크플로 `35435788783` 성공. asset `cartograph-0.19.0-macos-universal.tar.gz`
  sha256 `4079e4f9…c0424e3`, 압축 해제 바이너리 `--version` 0.19.0·universal(x86_64+arm64)·
  `docs/QUERY-EVIDENCE.md` 포함, 릴리스 바이너리로 CLI 계약 통과까지 직접 확인했다.
  Homebrew는 `HOMEBREW_TAP_TOKEN` 부재로 워크플로가 건너뛰어
  [tap PR #48](https://github.com/ictechgy/homebrew-tap/pull/48)을 수동으로 냈고 **머지됐다**
  (`1a8f707`; formula url·sha256이 0.19.0 asset과 일치함을 확인). `brew upgrade`·`brew test`는
  이 샌드박스에서 `/opt/homebrew` 쓰기가 막혀 호스트 확인이 남았다.
- 0.19.0에 포함된 작업: `superfluous-ignore`·`redundant-public` 경고(PR #107·#110),
  `cartograph fix`(#112), `cartograph affected`(#114), 공식 GitHub Action(#116),
  `retain_equatable/hashable_properties`(#118), warm query 세션 지문 창(#106),
  판독기 DB 유령 유닛 수정(#107).
- 지침 재배치·HANDOFF 압축 [PR #101](https://github.com/ictechgy/cartograph/pull/101) 머지(`b468541`).
  루트 `AGENTS.md`는 색인, 구현 주의점은 `Sources/AGENTS.md`, 인덱스 규칙은
  `Sources/CartographIndexStore/AGENTS.md`(신규, 타깃 exclude 등록)에 있다.
- 워크트리는 `/Users/jinhongan/Desktop/cartograph` 하나(main). `cartograph-p1` 제거,
  로컬·원격 낡은 브랜치 전부 삭제, 바탕화면의 날짜별 산출물 디렉터리(~6.4GB) 정리 완료.
- [0.17.0 릴리스](https://github.com/ictechgy/cartograph/releases/tag/0.17.0) 공개.
  버전 범프 [PR #95](https://github.com/ictechgy/cartograph/pull/95)(`5582341`), 태그 `0.17.0`,
  릴리스 워크플로 `35169960516` 성공. Homebrew는 `HOMEBREW_TAP_TOKEN` 부재로 워크플로가
  건너뛰어 [tap PR #46](https://github.com/ictechgy/homebrew-tap/pull/46)을 수동으로 냈고 머지됐다.
  `brew upgrade` 0.16.0→0.17.0, `brew test` 통과.
- 0.17.0에 포함된 작업: warm 질의 69→12ms, `impact --before`의 `scopeDiff`, 브리지 스캐너
  상수 해석·init 주입·한 홉 위임, 자기 경고 181→0, 세션 캐시 정확성 수정(버려진 링크
  재지정·열거 실패 감지). [PR #93](https://github.com/ictechgy/cartograph/pull/93) 스쿼시 머지.
- Expo Modules 지원 [PR #97](https://github.com/ictechgy/cartograph/pull/97)(`513cbef`),
  README 영·한 퇴고 [PR #98](https://github.com/ictechgy/cartograph/pull/98)(`8a09625`) 머지.

## Completed

- **경쟁 강화 (PR #90)**: warm 질의 단축, 미사용 파라미터/assign-only 프로퍼티/미사용 import
  경고 3종, 프로젝트 형태 맞춤 인덱스 없음 안내. 리뷰 루프(4라운드)에서 확인된 정확성 버그 4건
  수정: 외부 심볼 지연 귀속(`externalOnlyUSRs`), 다중 워크스페이스 선택+셸 인용,
  `AnalysisInputFingerprintCache` NSLock, 순환 재수출 폐포 고정점 반복.
- **0.16.0 배포**: release 워크플로 `35074750840` 성공(18m25s). asset SHA-256 독립 재계산
  일치(`4b423f7b…be57d31`), 압축 해제 바이너리 `--version` 0.16.0, universal 확인.
- **브리지 (PR #92)**: `setStreamHandler` non-nil 등록 → `stream-handle`; `--events` 문서는
  transport `event-channel`·version 2; `messages`/`events` 동시 지정은 CLI·공개 API 모두 거절;
  전송별 문서는 자신의 관측 공백(`unscanned-event/message-channels`)을 싣고 ObjC 소스 수는 공통.
  리뷰 루프(3라운드) 수정: 증명된 비-event 수신자 스킵, `==` 정확 일치만 분기 근거,
  `channel:` 인자보다 수신자 증명 우선, `dlsym` 공백 허용, 죽은 `stream` 한계 항목 제거,
  픽스처 골든에 dependencies·handlerScope 반영.
- **0.17.0 (PR #93~#100)**: Codex 독립 리뷰로 확정된 결함 9건 수정 후 머지 — `constantString`
  `+` 연결 지수 폭발(메모·4096자 상한), 지역 `channel` 파라미터가 `injectedChannel`로 새던
  문제, `Type.init`/무 레이블 생성자 호출 미기록, 비-self 대입 무효화 누락, 위임 인자 위치
  대조, 버려진 심볼릭 링크 스탬프, 실패 열거 미캐시, `inclusions` 상한, scopeDiff 인접 수집.
  CI 전용 `verify-analysis-blindspots.py`의 concat 기대치는 의도된 개선이라 갱신(`556c5b3`).

## Key Files & State

| 경로 | 읽는 이유 |
| --- | --- |
| [AGENTS.md](AGENTS.md), [Sources/AGENTS.md](Sources/AGENTS.md) | 필수 검사, 공통 계약과 모듈 경계; 하위 지침 색인 |
| [Sources/CartographIndexStore/AGENTS.md](Sources/CartographIndexStore/AGENTS.md) | `receivedBy`를 호출자로 읽지 않는 규칙, 제한적 소유자 귀속 |
| [Sources/CartographSyntax/BridgeFactScanner.swift](Sources/CartographSyntax/BridgeFactScanner.swift) | 채널 종류 증명(`provenChannelKind`), 상수 해석·init 주입·한 홉 위임 2패스 |
| [Sources/CartographKit/BridgeFacts.swift](Sources/CartographKit/BridgeFacts.swift) | v2 문서·전송별 limitation 집계 |
| [Sources/CartographKit/CartographService.swift](Sources/CartographKit/CartographService.swift) | `bridgeFacts` 공개 경계 검증, `isScopedDocument`(기본 문서 표식) |
| [Sources/CartographKit/AnalysisSession.swift](Sources/CartographKit/AnalysisSession.swift) | 세션 캐시 — walk 레코드, 링크·디렉터리 스탬프, 입력 지문 재사용 |
| [Sources/CartographAnalysis/RedundantPublicAnalyzer.swift](Sources/CartographAnalysis/RedundantPublicAnalyzer.swift) | redundant-public 판정 — 교차 모듈·인터페이스 참조·보수 제외 조건 |
| [Sources/CartographSyntax/ReferenceBodyScanner.swift](Sources/CartographSyntax/ReferenceBodyScanner.swift) | 본문 구간 수집 — `IndexedReference.position` 분류의 근거 |
| [Sources/CartographSyntax/MechanicalFixer.swift](Sources/CartographSyntax/MechanicalFixer.swift) | 안전한 소스 편집 — 위치 재확인·줄 가드·재파싱 검증 |
| [Sources/CartographKit/MechanicalFixDocument.swift](Sources/CartographKit/MechanicalFixDocument.swift) | fix 계획/적용 — 스코프·베이스라인 선별과 `mechanical-fixes` 문서 |
| [Sources/CartographKit/AffectedDocument.swift](Sources/CartographKit/AffectedDocument.swift) | 테스트 영향 질의 — impact 배관 재사용, `change-affected` 문서 |
| [Sources/cartograph/Affected.swift](Sources/cartograph/Affected.swift) | affected 하위 명령 — 시드 검증과 `ChangedSelectionSupport` 공유 |
| [action.yml](action.yml) | 공식 composite action — 바이너리 해석·인덱스 빌드·게이트·SARIF 업로드 계약 |
| [Sources/CartographCore/Config/RetentionOptions.swift](Sources/CartographCore/Config/RetentionOptions.swift) | 보존 옵션 계약 — 새 옵션은 여기·템플릿·키 목록·README를 함께 고친다 |
| [Fixtures/FalsePositiveCorpus/expected-bridges.json](Fixtures/FalsePositiveCorpus/expected-bridges.json) | 브리지 골든 — 출력 필드 추가 시 갱신 필요 |
| [.github/workflows/release.yml](.github/workflows/release.yml) | 태그 검증, universal archive, 탭 갱신(토큰 없으면 조용히 건너뜀) |
| [docs/evaluation/2026-09-16-harder-comparison.md](docs/evaluation/2026-09-16-harder-comparison.md) | 어려운 작업 재측정 근거 |

## Important Context / Decisions

- **확정:** 미증명 수신자의 `setStreamHandler`는 동적 이름의 사실로 남긴다 — 메시지 경로와 같은
  dynamic 허용이고, 지우면 isthmus가 핸들러 존재를 모른다. **다른 종류로 증명된** 수신자만 거른다.
- **확정:** FFI 표식(`@_cdecl`·`@_silgen_name`·`dlsym`·`Dart_PostCObject`·`dart_native_api.h`)은
  어휘 증거라 사실이 아니라 파일 수준 `unscanned-ffi-interop` 한계다.
- **확정:** `isScopedDocument`는 "전송 문서"가 아니라 `includesFlutter && !messages && !events`인
  기본 문서 표식. 전송 문서의 카운트 조건은 `isScopedDocument || <flag>` 형태다.
- **확정:** 브리지 채널 추론은 보수적이다 — 지역 바인딩이 있으면 init 주입을 보지 않고,
  위임은 인자 위치·레이블이 같은 한 홉만 인정한다. Expo 모듈의 컴포넌트 채널은 뷰 클래스가
  아니라 모듈 이름이다(`requireNativeViewManager` 계약).
- **확정:** `redundant-public`은 `retain_public`이 켜지면 침묵한다 — 공개 표면이 의도적이라는
  선언이라, 모듈이 자기 API를 읽는 것을 보고로 만들 수 없다(Periphery도 같은 모드에서 분석을
  끈다). 라이브러리가 이 질문까지 보려면 `--no-retain-public` 탈출구가 필요할 수 있다.
- **확정:** 참조 자리 분류는 보수 방향이다 — 판단 못 한 참조는 인터페이스로 간주한다. 본문으로
  잘못 낮추면 필요 없는 공개 노출을 요구하지 않아 "internal로 줄여도 된다"는 오탐이 된다.
- **확정:** 참조 0건 public 선언은 redundant-public으로 보고하지 않는다 — 의도된 API 표면일
  수 있고, 미사용 여부는 `unused-symbol`이 답한다.
- **확정:** `fix`가 고치는 규칙은 `unused-import`·`unused-parameter` 둘뿐이고 기본은
  드라이런이다. 편집은 현재 소스에서 다시 찾아 검증한 것만 적용하며, 어긋나면 이유와 함께
  skip한다 — 추측한 텍스트를 쓰지 않는다. `unused-parameter`는 인자 레이블을 절대 떨어뜨리지
  않는다(둘째 이름이 없으면 `x _:`를 넣는다).
- **확정:** `affected`는 `impact`와 같은 시드 선택·컨테이너 확장·디스패치 투영·깊이
  제한을 쓴다. 새 질의를 만들 때도 이 배관을 복제하지 말고 공유한다 — 같은 변경에 두
  명령이 다른 답을 내면 어느 쪽도 믿을 수 없다. 시드 파일 계산은
  `ChangedSelectionSupport`가 유일한 구현이고, 이 헬퍼는 명령 타입을 참조하지 않는다
  (타입 순환이 생긴다).
- **확정:** `affected`의 빈 목록은 "테스트가 닿지 않는다"는 그래프 사실이지 커버리지
  증거가 아니다. 렌더러가 그 문장을 항상 싣는다.
- **확정:** `PrintableText.printable`은 기본으로 개행을 지운다 — 여러 줄 출력은 줄마다
  적용해 join해야 한다(`ImpactComparison.renderText`는 전체를 넘겨 한 줄로 뭉개는 기존
  결함이 있다 — Blockers의 후속 후보).
- **확정:** 공식 액션은 릴리스 자산(universal)을 기본으로 받고 `binary` 입력으로 대체할 수
  있다. macOS 러너 전용이며(`libIndexStore`), 종료 코드 1(발견)과 2(툴 실패)를 사용자
  워크플로에 그대로 전달한다. 액션의 게이트 목록은 `check|dead|cycles|rules`로 고정하고,
  매니페스트 테스트가 실제 하위 명령과의 일치를 지킨다.
- **확정:** 로컬 액션(`uses: ./`)은 체크아웃된 리비전에서 실행된다 — CI 스모크가 커밋된
  action.yml 자체를 매 PR마다 검증할 수 있는 이유다.
- **확정:** `retain_equatable_properties`·`retain_hashable_properties`는 기본 켬이다
  (Periphery와 다른 선택 — 합성 판독기 흔적이 없다는 같은 이유). Hashable은 Equatable
  옵션만으로도 보존되고, 클래스는 두 옵션의 대상이 아니다. 보존 옵션을 새로 만들면
  `RetentionOptions`·설정 템플릿·`knownRetentionKeys`·README 영·한·근거 문장 표를 함께
  고친다.
- **미입증:** 한정 코퍼스·커버리지 수치는 전체 정확도나 에이전트 생산성의 증거가 아니다.
- **가정/후보:** `ImportScanner`의 `importKind`→`importKindSpecifier` 이전은 swift-syntax 하한을
  603+로 올릴 때.

## Verification

아래 표는 **PR #118(⑨)의 근거**다.

| 검사 | 결과 |
| --- | --- |
| 신규·관련 테스트 | 통과 — RetentionPolicy 5종·SwiftSyntaxAnalyzer 1종·ConfigurationLoader 1종 추가 |
| 변이 확인 | 옵션 게이팅 제거·클래스 제외 제거·Hashable→Equatable 폴백 제거 각각 해당 테스트 실패 |
| 전체 `swift test`(클린 빌드) | 1,640개 중 실패 56건은 전부 샌드박스 임시 디렉터리 차단(단언 실패 0) |
| strict 자기 분석·CLI 계약 | 4종·계약 모두 통과 |
| `swift build -c release` | 통과 |
| CI `35427455325` | Build/test/coverage·자기 분석 두 잡 통과 |

아래 표는 **PR #116(⑧)의 근거**다.

| 검사 | 결과 |
| --- | --- |
| 매니페스트 테스트 | ActionManifestTests 4개 통과 — 입력 드리프트·셸 단계·게이트 목록·README |
| 셸 로직 로컬 재현 | 통과 게이트(exit 0, SARIF version 2.1.0), 픽스처 `dead`(exit 1, results 30·rules 4), `fail-on-findings` true=1/false=0 |
| YAML 파싱 | Yams로 action.yml 파싱 — composite, inputs 9, outputs 2, steps 5 |
| 전체 `swift test` | 1,634개 중 실패 56건은 전부 샌드박스 임시 디렉터리 차단(단언 실패 0) |
| strict 자기 분석·CLI 계약 | 4종·계약 모두 통과 |
| CI `35425320710` | 두 잡 통과 — 자기 분석의 `GitHub Action smoke`(step 20) 실행 성공 |

아래 표는 **PR #114(⑦)의 근거**다.

| 검사 | 결과 |
| --- | --- |
| `swift test`(신규·관련 26개) | 통과 — AffectedDocumentTests 8·AffectedCommandTests 5 포함 |
| 변이 확인 | 테스트 근거 필터 제거·depth 0 변경 테스트 포함 제거 각각 해당 테스트 실패 |
| 전체 `swift test` | 1,630개 중 실패 56건은 전부 샌드박스 임시 디렉터리 차단(단언 실패 0) |
| `Scripts/verify-cli-contract.sh` | 통과 — affected --help·사용 오류 6종 추가 |
| strict 자기 분석(새 인덱스) | dead·cycles·cycles type·rules 통과 — 새 CLI 타입 순환을 helper 이동으로 해소 |
| `swift build -c release` | 통과 |
| CI `35418799363` | Build/test/coverage·자기 분석 두 잡 통과 |
| 갭 문서 재현 | 고정 리비전 Alamofire·Kingfisher 빌드 후 `impact` depth 1·3 → containing type 0건(⑥ stale 확인) |

아래 표는 **PR #112(⑤)의 근거**다.

| 검사 | 결과 |
| --- | --- |
| `swift test`(신규·관련 55개) | 통과 — MechanicalFixerTests 16·MechanicalFixTests 8·CLI 3종 |
| 변이 확인 | 소스 파싱 가드·모듈 경로 대조·줄 내용 가드·레이블 보존·드라이런 쓰기 조건 제거 각각 해당 테스트 실패 |
| 전체 `swift test` | 1,614개 중 실패 56건은 전부 샌드박스 임시 디렉터리 차단(단언 실패 0) |
| `Scripts/verify-cli-contract.sh` | 통과 — fix --help·사용 오류 3종 추가 |
| strict 자기 분석(새 인덱스) | dead·cycles·cycles type·rules 모두 findings 없음. `fix`는 `no mechanical fixes found` |
| `swift build -c release` | 통과 |
| CI `35412180773` | Build/test/coverage·자기 분석 두 잡 통과 |

아래 표는 **PR #110(③)의 근거**다. 자리 분류·게이트·가드는 호스트/CI에서 한 번 더 돌렸다.

| 검사 | 결과 |
| --- | --- |
| `swift test`(필터: 신규·관련 106개) | 통과 — RedundantPublicTests 17 + ReferenceBodyScanner/보강 10 포함 |
| 변이 확인 | 자리 분류 뒤집기·교차 모듈 검사 제거·조상 노출 검사 제거·무시 제외 제거·②반사실 훅 제거 각각 해당 테스트 실패 |
| 전체 `swift test` | 1,588개 중 실패 56건은 전부 샌드박스 임시 디렉터리 차단(단언 실패 0) |
| `Scripts/verify-cli-contract.sh` | 통과 |
| strict 자기 분석(새 인덱스) | dead·cycles·cycles type·rules 모두 findings 없음 — CI 실패였던 타입 순환을 `ef16c07`로 수정 |
| `swift build -c release` | 통과 |
| CI `35367382220` | Build/test/coverage·자기 분석 두 잡 통과 |
| `verify-fixtures.sh` | 전체는 SwiftUI 매크로 플러그인 부재로 샌드박스에서 불가. `--retain-public` 침묵 가드는 CI가 수행 |

아래 표는 **PR #107(②)의 근거**다.

| 검사 | 결과 |
| --- | --- |
| `swift test` | 8번들 전부 통과 — SuperfluousIgnore 28·ReaderDatabasePath 11(3라운드 반영 후) |
| `Scripts/coverage.sh` | **93.05%** (기준 90%, 계측 CLI 통합 포함) |
| `Scripts/verify-cli-contract.sh` | 통과 |
| `Scripts/verify-fixtures.sh` | 통과 — 디버그 바이너리 경로 지정, superfluous-ignore 2건 골든 일치(수정 전 유령 발견으로 실패 후 복구) |
| strict 자기 분석 | dead·cycles·type cycles·rules 모두 findings 없음 — 자기 분석이 잔재 `effectiveDatabasePath`를 잡아 삭제 |
| 변이 확인 | 파일단위 휴리스틱·누적 제거·시드 스캔 제거·`honoringIgnoreComments: true`·`exposesIgnoredImport` 제거·고아 승격·import 출처·지문 길이·unverified 폴백·prune 유예 각각 해당 테스트 실패 |

아래 표는 **PR #104의 근거**다.

| 검사 | 결과 |
| --- | --- |
| `swift test`(coverage.sh 내 8번들) | **1,505 tests** 전부 통과, 이슈 0(리뷰 수정 후 재실행도 통과) |
| `Scripts/coverage.sh` | **93.03%** (기준 90%, 리뷰 수정 후 재측정) |
| `Scripts/verify-cli-contract.sh` | 통과 |
| `Scripts/verify-fixtures.sh` | 통과 — 디버그 바이너리 경로 지정 |
| strict 자기 분석 | dead·cycles·type cycles·rules 모두 findings 없음 |
| 동등성 | 무작위 프로퍼티 480 비교·고정 케이스가 기준 구현과 일치; 초안은 114건 불일치로 실패 확인(테스트가 실제로 뭄); Codex 측 독립 모델 25,216 비교도 불일치 없음 |
| 성능 계측 | 좁은 선택 58.3→0.15ms, 넓은 선택 78.9→38.1ms(디버그, 44k/140k) |

아래 표는 **이전 릴리스의 근거**다.

| 검사 | 결과 |
| --- | --- |
| `swift test` (PR #93 헤드) | **1,479 tests** 전부 통과 |
| `Scripts/coverage.sh` | **92.99%** (기준 90%) |
| `Scripts/verify-cli-contract.sh` | 통과 (0/64/2 종료 코드 전 구간) |
| `Scripts/verify-fixtures.sh` | 통과 — 골든 갱신 후 재검증 |
| strict 자기 분석 | dead **0 경고**·cycles·type cycles·rules 모두 findings 없음 |
| CI (PR #93~#101) | Build/test/coverage gate + 자기 분석 전부 SUCCESS |
| Release `35169960516` | 성공; 공개 asset 해시·universal·버전 직접 검증 |
| Homebrew | formula 0.17.0 + 검증된 sha256(`ff1bbbc6…7087cb`); `brew upgrade`·`brew test` 통과 |
| 변이 확인 | 새 테스트 9종이 수정 전 코드에서 실패함을 확인 |

## Blockers & Open Questions

- `HOMEBREW_TAP_TOKEN`이 없어 탭 갱신은 계속 수동 PR. 자동화하려면 저장소 시크릿 추가 필요.
  0.19.0 탭 [PR #48](https://github.com/ictechgy/homebrew-tap/pull/48)은 머지 완료(`1a8f707`).
- 리뷰 인프라: Grok은 quota-exhausted로 두 번 연속 사용 불가. agy는 headless에서 도구 호출이
  자동 거부돼 프롬프트에 "도구 사용 금지" 문구가 필요하고, 가끔 그래도 무출력.
- `run-external`은 세션 디렉터리가 `mktemp -d` 수준(700)의 사설 디렉터리여야 하고, 재시도 전에
  stale `attempts/w001-<출력명>-` 디렉터리를 지워야 한다.
- 실기기·임의 DI/heap/반사의 완전성과 Core Data dynamic-framework-only 정의는 미지원/미검증.
- `$TMPDIR/cartograph-index-db`가 6.9GB까지 누적됐다(2026-09-18 정리). 형제 정리는 같은
  baseName만 보니 서로 다른 스토어의 판독기 DB는 영구히 남는다 — 전역 상한이나 오래된
  항목 GC가 없다. 개선 후보.
- ③ 후속 후보: 코퍼스에 검출 방향 케이스+골든 추가(픽스처 재빌드가 되는 호스트에서),
  `retain_public: true`인 라이브러리용 `--no-retain-public` 탈출구, 두 README의 라이브러리
  안내 보강.
- ⑤ 후속 후보: 코퍼스 fix 골든(호스트에서 `AliasConformance.swift` 파라미터 3건이 실제
  검출됨을 확인), `cartograph fix`를 스킬 문서에 안내.
- ⑦ 후속 후보: affected 코퍼스 골든(코퍼스 `.cartograph.yml`이 `Tests/**`를 제외해
  테스트 타깃이 그래프에 없다 — 테스트 포함 설정이 필요), `cartograph affected`를 스킬
  문서에 안내.
- ⑧ 후속 후보: **0.19.0 태그가 action.yml을 포함하므로 README의 `uses: ictechgy/cartograph@main`을
  `@0.19.0`으로 고정**, Marketplace 게시와 이동 메이저 태그(`v1`), `upload-sarif` 경로를
  코드 스캐닝이 켜진 저장소에서 한 번 실측.
- 별건 후보: `ImpactComparison.renderText`가 `PrintableText.printable`에 전체 문자열을
  넘겨 여러 줄 출력이 한 줄로 뭉개진다 — 줄 단위 적용으로 고칠 것.
- 브리지 스캐너의 남은 공백: 파일 스코프 `let`을 `var` 프로퍼티 외 경로(비-init 대입)로
  채우는 형태와 RN 매크로 외 Objective-C 플러그인 핸들러 추출. PR #123의 Clang 그래프·
  RN 매크로 ID 지원은 일반적인 Objective-C 핸들러 스캔의 완전성을 뜻하지 않는다.

## What Worked / Avoid

- 규칙마다 "그 규칙이 없으면 실패하는" 테스트 + 변이로 실제 무는지 확인.
- 리뷰 발견은 전부 코드·계약 문서와 대조해 검증 — 합의 ≠ 정답(agy의 `isScopedDocument` 오독,
  Claude의 `--retain-public`→`retain_public` 제안도 실제 플래그라 기각), 단독 트랙이라도
  실증된 정확성 버그(순환 폐포)는 고친다.
- `git checkout`으로 변이를 되돌리면 미커밋 수정까지 날아간다 — `git stash`/수동 복원 사용.
- CI `success`만으로 탭 갱신·머지 상태를 주장하지 않는다 — formula 내용과 PR 메타데이터를 본다.
- 커밋 메시지 히어독에 백틱이 있으면 셸이 먹는다 — 메시지를 파일로 쓰거나 이스케이프한다.
- CI에는 로컬 필수 게이트에 없는 검증 스크립트가 있다(`verify-analysis-blindspots.py` 등).
  CI 실패 시 로컬에서 같은 스크립트를 직접 돌려 재현한다.
- 중첩 타입은 타입 레벨 그래프에서 바깥 타입으로 접힌다 — 구문 방문자가 바깥 타입의 정적
  API를 부르면 자기 순환으로 보고된다(③에서 `cycles --level type --strict`가 잡았다).
  방문자는 파일 범위에 두고 공유 상수는 바깥 타입을 참조하지 않게 분리한다.
- 로컬 픽스처 인덱스는 낡을 수 있다(③ 당시 staleness 3/15). CI의 새 인덱스가 코퍼스의 실제
  표면을 드러내 가드 가정을 뒤집었다 — 픽스처 판정을 바꾸면 로컬 통과만 믿지 않는다.
- 착수 전에 갭 문서와 릴리스 이력을 대조한다. ④로 기록된 `impact --before` 제거 간선은
  이미 0.17.0의 `scopeDiff`(PR #93)로 완료돼 있었다 — 경쟁 갭 문서가 stale이었다.
- 갭 문서의 평가 기록은 **현재 바이너리로 재현해 확인한다.** ⑥의 "containing type" 2건은
  평가 시점의 `receivedBy` 결함이었고 이후 버전에서 이미 사라졌는데, 문서만 보고 착수하면
  없던 기능을 다시 만들게 된다. 고정 리비전을 빌드해 결과를 재현하는 비용이 더 싸다.
- 공유 헬퍼는 명령 타입을 참조하지 않는다 — `ImpactCommand ↔ ChangedSelectionSupport`
  자기 순환이 생겨 `cycles --level type --strict`가 잡았다(⑤의 중첩 방문자와 같은 부류).
- GitHub Action은 `uses: ./`로 스모크를 돌린다. 로컬 액션은 체크아웃된 리비전을 실행하므로
  릴리스 자산 없이도 YAML 파싱·단계 배선·출력 계약을 PR CI에서 검증할 수 있다. 처음부터
  `binary` 입력을 둔 것이 이 스모크를 가능하게 했다.
- 증분 빌드 산출물이 손상되면 불가능한 테스트 실패(순수 함수 단언 실패, 엉뚱한 파일 오류)가
  나온다. ⑨에서 전체 실행이 요약 없이 중단되고 `AffectedDocumentTests`가 빌드 전용 설정으로
  실패하는 것처럼 보였다 — 개별 필터에서는 통과했다. `$TMPDIR` 스크래치의
  `arm64-apple-macosx` 디렉터리를 지워 클린 빌드하니 1,640개·환경 실패만 남았다.
  코드를 의심하기 전에 빌드 산출물을 의심한다.
- 여러 줄 사람용 출력을 `PrintableText.printable`에 통째로 넘기지 않는다. 기본값이 개행을
  지워 한 줄로 뭉개진다(⑤에서 발견). 줄마다 적용해 join한다.

## 경쟁 조사 — codegraph 대비 개선점 (2026-09-18)

조사 대상: [colbymchenry/codegraph](https://github.com/colbymchenry/codegraph) v1.6.0 (스타 71,337, tree-sitter+Rust 커널,
SQLite+FTS5, MCP 단일 툴 `codegraph_explore`, 파일 감시 자동 동기화, `codegraph install`로 9개 에이전트
배선, 텔레메트리 기본 on, 호스팅 유료 플랫폼 예고). 판정: **경쟁이 아니라 보완 관계** — codegraph는
"에이전트가 어디를 읽을까"에, cartograph는 "지워도 되나·무엇이 깨지나"에 답한다. 자매 저장소
(kartograph·dartograph·isthmus)에도 같은 날짜의 동일 섹션이 있고, 아래 "공통" 항목은 네 곳에서 겹친다.
Goal 섹션의 갭 순서(③~⑩)는 그대로 두고, 아래는 그 순서에 끼워 넣을 **후보**다.

### 실측 사실
- `gh api repos/ictechgy/cartograph`: 스타 3 · 포크 1 · 열린 이슈 0. PR 105개 머지, 릴리스 18회,
  테스트 1,505건, 커버리지 93.03%. 엔지니어링 품질과 도달 범위의 격차가 모든 기능 갭보다 크다.
- `Sources/` 전체에 `snippet|verbatim|sourceText` 0건 — `query`는 메타데이터만 반환한다.
- `CartographMCPTools.swift`: MCP 툴 5개(status·query·impact·check·runtime_discover).
- `cartograph skill`은 `.claude/skills/cartograph/SKILL.md` 하나만 쓴다(README:924).
- `docs/evaluation/2026-09-16-harder-comparison.md`의 LSP 대조(H1 브리지 42ms 정확 vs LSP 290ms 실패,
  H2 전이 디스패치에서 LSP `UploadRequest` 누락, H5 지역 함수 LSP `references` 0건)가 README에 없다.
- `docs/evaluation/2026-09-18-competitive-gaps.md`의 "Periphery Pro는 setup polish만, 분석 모델 불변"은
  현재 periphery.pro 광고(`agent-prompt` 출력 형식, 스캔 3× 단축, GitHub Actions 재사용 워크플로,
  VS Code 확장, 인디 무료)와 어긋난다.

### 공통 (네 저장소 동일)
| # | 부족한 점 | 근거 | 제안 | 난이도 |
|---|---|---|---|---|
| C1 | 에이전트 배선이 Claude Code 단일 타깃 | `cartograph skill`·`.claude-plugin/` 전용. codegraph `install`은 9개 에이전트 감지 + MCP 설정 + AGENTS.md 마커 블록. 마커 블록 이유: **서브에이전트·non-MCP 하네스는 MCP 초기화 지시를 못 받는다** | `cartograph install`(다중 에이전트 감지 + AGENTS.md 블록) + `curl \| sh` 설치 스크립트 | 중 |
| C2 | MCP 툴 5개 — 에이전트가 고르고 예산을 계산해야 함 | SKILL.md가 툴 선택과 `symbols × limit ≤ 1000` 예산을 문단째 가르치는 것이 증상. codegraph는 8개 중 `explore` 1개만 노출하고 `_meta.anthropic/alwaysLoad: true`로 Claude Code 툴 지연 로딩을 우회 | 디스패처 `cartograph_explore` 신설(판정+근거+경로+영향), 기존 5개는 env opt-in, `alwaysLoad` 부착 | 중 |
| C3 | 근거를 가리키기만 하고 보여주지 않음 | 소스 원문 반환 0건. codegraph의 "파일 읽기 0회" 주장은 원문을 한 페이로드에 담는 데서 나옴 | `--include-source`(기본 off)로 상위 N 심볼 라인 범위 스니펫. codegraph 스스로 이 방식이 세션 잔류 컨텍스트를 80% 늘린다고 공개 → 기본 off가 맞음 | 중 |
| C4 | 검증된 강점이 README 밖에 묻힘 | 위 LSP 대조표 · 동결 오라클 · 컴파일러 변이 · 바이너리 해시 검증 전부 README 부재. codegraph는 불리한 수치(잔류 컨텍스트 +80%, 대조군 오염 통제)까지 상단 공개 | README 상단에 대조표 1개 + 2026-09-15 파일럿이 **이점을 못 찾은** 과제도 같이 게재. 고칠 것은 문장이 아니라 **순서** | 소 |
| C5 | 채택 퍼널 부재 | 스타 3, 이슈 0, GitHub Action 없음(갭 ⑧). 에러가 이탈을 가르침 — codegraph AGENTS.md "Errors teach abandonment" | Action(⑧) 승격 + "오탐 신고" 이슈 템플릿 + `notFound`류를 오류톤 대신 `suggestions` 동봉 중립 응답으로 | 소 |

### cartograph 고유
| # | 부족한 점 | 근거 | 제안 | 난이도 |
|---|---|---|---|---|
| S1 | 경쟁 갭 문서가 stale — Periphery Pro가 에이전트 레인에 진입 | 위 실측. README "Why another tool" 표는 아카이브 OSS Periphery만 상대 | 갭 문서 갱신 + 비교축을 Pro가 못 따라오는 impact·dataflow·cycles·bridges로 이동 | 소 |
| S2 | Swift MCP 서버 카테고리가 경쟁 인식에서 빠짐 | SwiftLens · swiftadopt-mcp · anvyxhq/swift-mcp-server · XcodeBuildMCP · Apple `xcrun mcpbridge` — 전부 sourcekit-lsp 기반. 갭 문서는 Serena·ios-agent-mcp만 다룸 | (추측) Apple 1st-party 심볼 MCP가 정식화되면 심볼 질의는 범용화 → 방어선은 LSP가 못 답하는 그래프 질문(H2·H5가 이미 증명). 포지셔닝 문구를 그 축으로 | 소 |
| S3 | 인덱스 신선도를 "사람이 빌드하라"는 문단으로 넘김 | SKILL.md가 편집 후 빌드를 **부탁**. `limitations`에 `index-staleness: 3 of 214` 집계는 이미 계산 중 | 질의된 심볼의 **자기 파일**이 stale이면 심볼 단위 플래그(프로젝트 전역 한 줄이 아니라). 워처는 선택적 opt-in | 중(플래그)/대(워처) |
| S4 | README 1,281줄·73KB, 한·영 수동 동기화, 문서 사이트 없음 | PR #98이 통째로 퇴고 작업. 평가자가 30초에 "뭐고 되는가"를 못 읽음 | ~200줄(문제·벤치 표·설치·5줄 퀵스타트·정직성 문단)로 축소, 레퍼런스는 GitHub Pages | 중 |
| S5 | 추론 간선 provenance 축이 명령마다 다른 필드로 흩어짐 | proven/dynamic 채널, `automaticRuntime`/`observedRuntime`, `RetentionReason` 각각. codegraph는 `provenance:'heuristic'`+`synthesizedBy` 단일 축(단, 코드상 synthesizer 4종에만 실제 부착) | 모든 간선·사실에 `provenance: compiler\|syntax\|heuristic\|observed` 단일 축. isthmus 조인이 기계 판독 신뢰도를 얻음 | 중 |
| S6 | 테스트 영향 질의(갭 ⑦) | codegraph `affected` + 복붙 CI 스니펫으로 출시. cartograph는 역방향 도달성과 impact `tests` 필드 보유 | `cartograph affected --since` 승격 + 동일 CI 레시피 | 소~중 |

### 지킬 것 (따라가면 안 되는 것)
1. **기본 on 텔레메트리·호스팅 유료 티어.** "100% 로컬·계정 없음·MIT·유료 티어 없음"은 Periphery Pro
   라이선스 게이트에 맞선 가장 날카로운 차별점이다.
2. **추측으로 산 폭.** codegraph는 이름 일치·관행(`View`/`Manager` 접미사, Cocoa 전치사)으로 해소하고
   태깅한다. cartograph는 컴파일러가 기록한 것만 읽고 `deletable: true`를 영원히 내지 않는다(AGENTS.md).
   provenance 태그 아이디어는 빌리되, 증명 못 한 간선을 합성하려는 의지는 빌리지 않는다.

### 권장 착수 순서
C4(소) → S1·S2(소, 문서) → C1(중) → C2(중) → S3 플래그(중) → C3(중). 기존 갭 ⑨~⑩과의 병합은 메인테이너 판단.

## Next Steps

자매 브리지 확장 PR #123과 동반 세 PR은 모두 머지됐고 추가 구현·리뷰 대기는 없다.
해당 기능은 미발행 상태이며 릴리스나 아래 후보 착수는 최신 사용자 요청 범위를 따른다.

1. `git status --short --branch`, `git worktree list`, `git diff`로 미커밋 변경을 확인한다.
2. **0.19.0 릴리스 완료**(태그 `0.19.0`, 릴리스 워크플로 `35435788783`, asset sha256
   `4079e4f9…c0424e3`). Homebrew 탭 [PR #48](https://github.com/ictechgy/homebrew-tap/pull/48)도
   머지 완료(`1a8f707`) — `brew upgrade`·`brew test`만 호스트에서 확인하면 된다.
3. 순차 갭 목록이 끝났다: ②#107·③#110·⑤#112·⑦#114·⑧#116·⑨#118 머지, ④는 `scopeDiff`(PR #93),
   ⑥은 수신 타입 호출자 결함 수정(0.14.0)으로 이미 완료. ⑩런타임 텔레메트리는 연구 전용 보류.
4. 다음 작업은 아래 "경쟁 조사 — codegraph 대비 개선점" 후보(C1~C5·S1~S6, 권장 순서
   C4 → S1·S2 → C1 → C2 → S3 플래그 → C3)와 릴리스 후속(액션 태그 고정 등)이다 —
   메인테이너 판단으로 진행한다.
5. 브리지 `sourceCache` 최적화는 동일 소스 스냅샷 보존 조건에서 검토한다. 근거 없이 제거하지
   않으며, 입증되지 않으면 메모리 계측 결과부터 확보한다.

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph`에서 `HANDOFF.md`와 적용되는 `AGENTS.md`를 읽으세요.
현재 main은 `5c43c36`(PR #123)입니다. Clang ObjC 그래프/보존 연결과 Swift RN 이벤트 추출은
CI·GLM·자매 왕복 검증을 거쳐 머지됐지만 아직 새 릴리스로 발행하지 않았습니다.
Current Status의 첫 절과 실제 Git 상태를 먼저 확인하고, 이 HANDOFF의 로컬 수정도 보존하세요.
0.19.0이 릴리스됐습니다(태그 `0.19.0`, 워크플로 `35435788783`, asset sha256 `4079e4f9…c0424e3`).
Homebrew 탭 [PR #48](https://github.com/ictechgy/homebrew-tap/pull/48)도 머지됐습니다(`1a8f707`).
`brew upgrade`·`brew test`는 호스트에서 확인하세요.
순차 경쟁 갭 목록이 끝났습니다: ②#107·③#110·⑤#112·⑦#114·⑧#116·⑨#118 완료, ④는
`scopeDiff`(PR #93), ⑥은 수신 타입 호출자 결함 수정(0.14.0)으로 **이미** 완료돼 있었고 경쟁
갭 문서 4·6은 stale 정리했습니다. ⑩런타임 텔레메트리는 연구 전용 보류입니다.
다음 작업은 HANDOFF의 "경쟁 조사 — codegraph 대비 개선점" 후보(C1~C5·S1~S6, 권장 순서
C4 → S1·S2 → C1 → C2 → S3 플래그 → C3)와 릴리스 후속(액션 태그를 `@0.19.0`으로 고정,
Marketplace 등)을 메인테이너 판단으로 고르면 됩니다. 각 갭의 남은 후속(코퍼스 골든,
스킬 안내, impact text 렌더러 개행 결함)은 Blockers에 있습니다. 완료된 배포·검증을
반복하지 마세요.


---

## 2026-09-23 발행 완료 인계 스냅샷

중복 기록을 현재 인계에서 줄이기 전 원문이다. 최신 상태는 루트 HANDOFF.md를 따른다.

# Handoff

_Last updated: 2026-09-23_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다. 과거 Next Steps·미발행 표기는 당시 기록이다.

## Current Status

- **CLI 0.21.0 발행·Homebrew 설치 검증 완료:** [릴리스](https://github.com/ictechgy/cartograph/releases/tag/0.21.0)의
  태그는 `ba9af2fa3cc426a42bfbed391cebfc1708b1b2f2`이며 [릴리스 PR #133](https://github.com/ictechgy/cartograph/pull/133)은 병합됐다.
  [PR CI](https://github.com/ictechgy/cartograph/actions/runs/35776430976)는 테스트 1,650개·통합 커버리지
  92.83%(단위 87.50%), CLI 계약·코퍼스·런타임/MCP·strict 자기 분석(모듈·타입 순환 포함)을 통과했다.
  [main CI](https://github.com/ictechgy/cartograph/actions/runs/35777773005)와
  [Release 실행](https://github.com/ictechgy/cartograph/actions/runs/35777799863)도 모두 통과했다.
- 공개 universal archive SHA256은 `4b204d2e343281499163df8def35374956d38b813d589519130f1f53244b623f`.
  독립 다운로드와 GitHub asset digest가 일치하고, arm64/x86_64·버전 0.21.0·CLI 계약을 확인했다.
  압축을 푼 LICENSE·README·QUERY-EVIDENCE 계약 문서도 태그 소스와 일치한다. 공개 latest는 0.21.0이다.
- 자동 tap 갱신은 토큰 미설정으로 건너뛰어 [Homebrew PR #50](https://github.com/ictechgy/homebrew-tap/pull/50)을
  `0ef8908`로 병합했다. 실제 formula URL·SHA를 대조하고 호스트 0.20.0→0.21.0 upgrade와
  `brew test`를 통과했다. 설치된 바이너리는 독립 검증한 공개 바이너리와 바이트까지 일치한다.
  최종 근거는 로컬 `.git/evidence-release-0.21.0-20260923/status.json`, `pr-ci.log`, `release.log`,
  `public-cli-contract.log`, `brew-upgrade.log`, `brew-test.log`다. 발행·설치 대기를 다시 시작하지 않는다.
- GitHub Action `action-v1.0.0`과 GitLab Catalog `1.0.0` 태그는 유지한다. GitLab 컴포넌트의
  CLI 0.20.0·archive 체크섬 고정은 별도 발행 계약으로 그대로다. 영·한 README의 직접 설치와
  GitHub Action 바이너리 예제는 0.21.0을 가리킨다.
- **PR #130 병합 완료:** `90f4d8c`로 병합했고 [main CI](https://github.com/ictechgy/cartograph/actions/runs/35773385182)와
  [SARIF 검증](https://github.com/ictechgy/cartograph/actions/runs/35773385293)도 통과했다.
  최종 PR CI의 테스트 1,650개·통합 커버리지 92.84%(단위 87.51%), CLI 계약·코퍼스·
  strict 자기 분석(모듈·타입 순환 포함)을 확인했다. 문서 4개도 반영됐고 당시 작업 폴더는 깨끗했다.
  `.git/evidence-pr130-final-20260923/`가 최종 근거다. 아래 발행 기록의 0.20.0 latest는 당시 상태다.

- **GitLab Catalog 1.0.0 발행 완료:** [Cartograph CI](https://gitlab.com/explore/catalog/ictechgy/cartograph-ci)
  (프로젝트 ID `86723928`)의 이름·버전·`cartograph@1.0.0` 설치 구문과 비로그인 HTTP 200을 확인했다.
  [태그 파이프라인 2871315648](https://gitlab.com/ictechgy/cartograph-ci/-/pipelines/2871315648)의 Linux 검사,
  실제 Mac 분석, 보고서 검증, `release:` 발행 잡 모두 통과했다. [릴리스 1.0.0](https://gitlab.com/ictechgy/cartograph-ci/-/releases/1.0.0)은
  GitLab `main`의 `9836b1b9`를 가리킨다. [MR !1](https://gitlab.com/ictechgy/cartograph-ci/-/merge_requests/1)은 머지했다.
- **소비자 검증 완료:** `verify/catalog-1.0.0`은 공개된 버전을 명시적으로 include한다.
  [파이프라인 2871345482](https://gitlab.com/ictechgy/cartograph-ci/-/pipelines/2871345482)에서 실제 진단 3개를
  확인했고, [검증 MR !2](https://gitlab.com/ictechgy/cartograph-ci/-/merge_requests/2)에 추가한
  `Probe.catalogConsumerUnused()`가 **새 Code Quality 진단 1건**으로 표시됐다(소스 16행).
  같은 프로젝트의 검증 브랜치에서 실행한 근거이며, MR은 병합하지 않고 닫았다. 1.0.0 태그는 유지한다.
- **GitLab 구현 병합·검증 완료:** [GitHub PR #132](https://github.com/ictechgy/cartograph/pull/132)는
  최종 `d26a94b`의 전체 CI와 Linux·Mac 컴포넌트 검사를 통과한 뒤 `3171998`로 머지했다.
  구현은 `Integrations/GitLab/`, 하네스는 `.github/workflows/gitlab-component.yml`이다.
  행동 검사 15개, 낡은 보고서 변이 실패 단언 6개, 실제 샘플 진단 2개·진입점 보존,
  전체 코퍼스 37개 진단·5개 규칙·전체 미사용 골든을 검증했다. 별도 Orca worktree는
  `feature-gitlab-component/` / `feature/gitlab-component`다. 배포용 브랜치
  `feature/gitlab-catalog-export`는 `35c019c`, GitHub 배포 폴더·GitLab main/태그 tree는
  `840d35cfb99e15922ca9c6b8a0e45c7c2b8597c2`로 일치한다.
- **임시 Mac 러너 정리 완료:** 사용자가 실행안을 승인해 프로젝트 전용 러너 `56611172`로
  지정한 파이프라인·커밋의 Mac 잡을 하나씩 총 5회 실행했다. 모두 성공 후 러너 등록을 삭제했고,
  프로세스 없음·프로젝트 러너 0개·임시 인증파일/바이너리/체크아웃 제거를 확인했다. 상시 서비스는 설치하지 않았다.
  이후 유지관리 CI에는 적격 Mac 러너를 연결해야 하며 `CARTOGRAPH_CI_RUNNER_TAG`로 선택한다.
  소비자도 자신의 macOS 러너가 필요하다. 끝난 계정 인증·임시 러너 승인·발행을 다시 시작하지 않는다.
  최종 근거는 `.git/evidence-gitlab-20260922/status.json`, `pipeline-*.json`, `consumer-mr-report.txt`,
  `runner-cleanup/cleanup.json`이다. Orca의 파일 Replace 업로드는 동작하며, 편집 후 API/Git로 내용을 대조한다.

- **액션 릴리스 공개 완료:** [action-v1.0.0](https://github.com/ictechgy/cartograph/releases/tag/action-v1.0.0)은
  `567d91fb0d4e99866c6f52c8650792baf13b71c7`을 가리킨다. 이름은 `Cartograph Swift Analysis`다.
  액션 전용 릴리스이며 그때 새 CLI 바이너리는 발행하지 않았다. 당시 바이너리 릴리스와 Homebrew는
  **0.20.0**이었다. 기존 태그를 옮기거나 릴리스를 다시 만들지 않는다.
- **공개 태그 실행 검증 완료:** [실행 35547841097](https://github.com/ictechgy/cartograph/actions/runs/35547841097)이
  실제 `uses: ictechgy/cartograph@action-v1.0.0`을 내려받아 실행했다. GitHub가 **37개 결과·5개 규칙**을
  처리 완료했고 처리 오류·경고는 없었다. 12개 진단 파일 경로도 실제 코퍼스 파일과 일치했다.
  서버 분석 ID는 `1808201773`이다. 별도 검증 브랜치 `verify/action-v1.0.0`의 `9de347b`는
  원격 액션 태그를 호출하기 위한 것이며 제품 변경 브랜치가 아니다.
- **Marketplace 등록 완료:** 9월 22일 Chrome에서 사용자 재인증 후 기존 릴리스의 게시가 완료됐다.
  [공개 페이지](https://github.com/marketplace/actions/cartograph-swift-analysis?version=action-v1.0.0)의 이름·
  `Code quality` 카테고리·`uses: ictechgy/cartograph@action-v1.0.0` 설치 안내를 확인했다.
  기본·버전별 URL 모두 비로그인 HTTP 200이다. Orca 로그인이나 이전 인증 대기를 재개하지 않는다.
  기본 브랜치의 이름 충돌·125자 이상 설명을 고친 [PR #131](https://github.com/ictechgy/cartograph/pull/131)은
  `76219c0`으로 머지했다. 이름 `Cartograph Swift Analysis`, 설명 117자이며 기존 매니페스트 테스트의
  이름 기대값만 함께 갱신했다. 실행 설정은 그대로다. [CI](https://github.com/ictechgy/cartograph/actions/runs/35635573987)는
  1,647개 테스트·통합 커버리지 92.84%·자기 분석 모두 통과했다.
  Marketplace 기본 "Use latest version"은 당시 저장소 latest인 `0.20.0`을 따르며 액션 버전에는
  older 표시가 붙는다. 위 버전별 링크로 안내한다. CLI latest와 `action-v1.0.0`의 SHA가
  그대로임을 검증했다. 이 표시를 없애려고 latest를 바꾸거나 태그를 옮기지 않는다.
  최종 근거는 `.git/evidence-marketplace-20260922/status.json`과 인접 공개 HTML·CI 로그다.
- **PR #130 최종 통합:** 작업 브랜치는 `feature/action-corpus-cache`다.
  [PR #130](https://github.com/ictechgy/cartograph/pull/130)이 최종 CI·병합 상태의 정본이다.
  9월 23일 사용자 승인으로 문서 4개를 `6a28298`에 커밋했고, `c7c5c48`에서 최신 main
  (`3171998`, PR #131·#132 포함)을 충돌 없이 통합했다. 기존 사용자 인계 내용은 보존했다.
  캐시 정리·잠금, Action 실패 처리·경로 보정, 코퍼스·스킬 계약의 최종 코드 검토에서
  새 병합 차단 결함은 발견하지 않았다. Action·캐시 하네스, GitLab 행동 검사 15개,
  YAML·Python·셸 구문, 문서 47개 로컬 링크와 버전·러너 예제 검증을 통과했다.
  public/fix/affected 컴파일러 골든·스킬 안내, 캐시 정리 preview/apply·사용 중 잠금·최근 사용 표식,
  Action 실패 처리·SARIF 경로 보정을 구현했다. 통합 전 `567d91f`의
  [전체 CI](https://github.com/ictechgy/cartograph/actions/runs/35521930946)
  통과: 테스트 **1,650개**, 통합 커버리지 **92.83%**(단위 87.50%), CLI 계약·코퍼스·런타임/MCP·
  strict 자기 분석(모듈·타입 순환 포함). 로컬 통합 커버리지는 92.84%였다.
  Swift 6.3의 추가 `@Test` implicit accessor는 원시 영향 목록과 대조한 뒤 골든 집계에서만
  분리한다. 실제 테스트·명시적 소비자는 통째로 비교한다. 기존 `ReactNativeEventScanner.swift`의
  unused-import 경고 1건은 비게이트 경고로 남아 있다.
- **메모리 기준 계측 완료:** `sourceCache`는 변경하지 않았다. 디버그 기준 저장소 원문
  2,083,941바이트/189파일, 프로세스 최대 RSS 164,790,272–209,158,144바이트다.
  RSS를 캐시 자체 할당량이나 개선 효과로 해석하지 않는다. 실제 전역 캐시는 삭제하지 않았다.
  kartograph·dartograph에는 별도 로컬 스킬 공유 인계를 남겼다.
- 구현 설명은 [상세 기록](docs/ACTION-CORPUS-CACHE.md), 측정값은
  [메모리 원시 결과](docs/evidence/bridge-memory-20260921.json)에 있다. 최종 CI·업로드·공개 태그 원시는 로컬
  `.git/evidence-action-corpus-cache-20260921/manifest.json`과 `published-tag/`, `published-tag-run.log`에 있다.

- 자매 후속에서 `generatedAt`을 문서 추출 시각으로 통일하고 optional `sourceModifiedAt`을
  source mtime 관찰값으로 분리했다. cartograph는 기존 추출 시각 의미를 유지하고 mtime은
  측정하지 않아 생략한다. [README](README.md#bridges--export-native-bridge-evidence)에 명시했다.
  이 타임스탬프 문서 갱신 당시에는 새 버전·태그를 발행하지 않았다.
- 자매 확장은 [isthmus PR #104](https://github.com/ictechgy/isthmus/pull/104) (`a356f49`)와
  [kartograph PR #90](https://github.com/ictechgy/kartograph/pull/90) (`5add226`)의 머지·최종 CI·GLM 반영까지 완료됐다.
  공개 RN Gradle witness/retention과 Android API36 실기기 release, iOS27 시뮬레이터 debug,
  RN0.81.4/Hermes legacy bridge 실기기 release를 검증했다. KAPT/KSP 출력은 별도 receipt로 검증한다.
  이 실행 근거는 cartograph 자체의 모든 플랫폼 정확도나 추가 RN 수신 측 추출 지원을 뜻하지 않는다.
  이번 확장은 새 버전으로 발행하지 않았으며 cartograph 소스/발행 버전은 0.20.0을 유지한다.

- cartograph **0.20.0**은 [GitHub](https://github.com/ictechgy/cartograph/releases/tag/0.20.0)와
  Homebrew에 발행됐다. 릴리스 소스는 `d7df412`, 브리지 확장 PR은
  [#123](https://github.com/ictechgy/cartograph/pull/123)이다.
- universal archive SHA256은 `833eb3c86deffc8e7c845297df57d41e35bb644bd5a943b09843e52075c6f072`.
  다운로드·arm64/x86_64·CLI 계약을 확인했고, 탭 [PR #49](https://github.com/ictechgy/homebrew-tap/pull/49)
  머지 뒤 호스트 upgrade·brew test도 통과했다. 이전 인증·설치 대기를 재개하지 않는다.
- Clang ObjC 그래프·실제 USR 보존과 Swift RN 전역 이벤트 추출이 포함된다. 일반 ObjC
  핸들러 스캔 전체나 RN 엔진·앱 런타임을 검증했다는 뜻은 아니다.
- 영·한 README의 Action 설치 예제를 PR #130에서 `ictechgy/cartograph@action-v1.0.0`으로 맞췄고,
  `sarif-id` 출력, Marketplace 버전별 링크와 기본 latest 동작, 상세 기록의 발행 상태도 반영했다.
  바이너리 입력은 릴리스 PR #133에서 `version: 0.21.0`으로 갱신했다.
  로컬 링크와 버전 표기, `git diff --check`를 검증했다.
- 자매 발행본·왕복 검증의 최신 근거는 [isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md),
  사용법은 [README](README.md)를 따른다. 현재 branch·원격 머지 상태는 Git으로 확인한다.

## Next Steps

자매 확장의 남은 선택 범위는 KAPT/KSP receipt의 snapshot/cache 연동, iPhone 실기기·iOS release와
RN 새 아키텍처/lifecycle/미디어 재생 검증, 새 선택적 collector 발행이다. 정본은
[isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md)의 “남은 추가 확장”이다.
완료·보존·정리 원시는 isthmus의 로컬 `.git/evidence-runtime-expansion-20260920/FINAL.json`에 있다.
이번 인계 갱신은 이 후속 작업을 시작한 것이 아니다. 아래 cartograph 고유 후보는 별도로 유지한다.

완료한 브리지 확장·0.20.0 발행·Homebrew 검증은 반복할 작업이 아니다. 이번 문서 정리 이후의
선택 후보는 다음과 같으며, 현재 사용자 요청 범위에서 필요한 항목만 진행한다.

GitHub Marketplace와 GitLab Catalog 게시 작업은 모두 끝났다. PR #131·#132의 구현·병합·
인증·임시 러너 등록·게시를 반복하지 않는다. CLI 0.21.0의 GitHub·Homebrew 발행·설치 검증도 끝났다.

사용자가 승인한 CLI 0.21.0의 GitHub·Homebrew 발행과 설치 검증은 모두 완료됐다.
PR #130·#133과 tap PR #50도 병합됐다. 다음 사용자 요청을 따른다. GitLab의 상시 Mac 러너 연결,
추가 기능·성능 최적화·새 릴리스·실제 캐시 삭제는 별도 선택 범위다.
두 Orca 작업 폴더 `fix-action-marketplace-metadata/`,
`feature-gitlab-component/`는 부모 저장소의 로컬 exclude에 있고 정리 대상으로 승인받지 않았다.

SARIF 실측·공개 태그 실행·코퍼스·스킬·캐시 수명 관리·메모리 기준 계측은 구현과 검증이 완료됐다.
전역 실제 캐시 삭제나 `sourceCache` 최적화는 수행하지 않았다. 완료된 항목을 다시 착수하지 않는다.

- 경쟁 조사 C1~C5·S1~S6의 나머지 후보는 [과거 원장](HANDOFF-HISTORY.md#경쟁-조사--codegraph-대비-개선점-2026-09-18)과
  현재 코드를 대조한 뒤 범위를 선택한다. 런타임 텔레메트리는 연구 전용 보류다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. CLI 0.21.0은 GitHub와 Homebrew에
발행됐고 공개 archive·CLI 계약·호스트 upgrade·brew test까지 검증했어. PR #130·#133과 tap PR #50은
병합됐어. GitHub Marketplace action-v1.0.0과 GitLab Catalog 1.0.0도 발행·소비자 검증이 끝났고
임시 Mac 러너는 정리했어. GitLab 컴포넌트는 검증된 CLI 0.20.0 고정을 유지해.
발행·설치·인증·러너 승인 대기를 다시 시작하지 말고 실제 Git 상태와 다음 사용자 요청을 따라.
사용자 변경을 보존해. 캐시 삭제와 작업 폴더 정리는 별도야.
