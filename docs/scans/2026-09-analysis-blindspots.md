# 상수·Needle·스토리보드 사각지대 점검 — 2026-09-08

Issue #64 후속 요청에 따라 공개 도구의 설계와 실제 Swift 인덱스를 비교했다.
브리지 확장(PR #65) 위에서 재현했으며, 출시된 0.8.2의 지원 범위를 바꾸어 서술하지 않는다.
CodeQL/Semgrep 엔진을 실행한 성능 비교가 아니다.

## 다른 도구에서 가져온 원칙과 실제 변경

| 근거 | Cartograph에 적용한 것 | 적용하지 않은 가정 |
|---|---|---|
| [CodeQL Swift local/global data flow](https://codeql.github.com/docs/codeql-language-guides/analyzing-data-flow-in-swift/) | 지역 분석부터 시작하고 선언 문맥을 보존한다. 상수 별칭은 정의된 스코프에서 해석한다. | 데이터 흐름과 도달성 그래프를 같은 것으로 취급하지 않는다. 전역 추적·taint 분석을 구현했다고 주장하지 않는다. |
| [Semgrep 상수 전파](https://docs.semgrep.dev/writing-rules/data-flow/constant-propagation) | 표면에 리터럴이 없어도 불변 별칭을 따라간다. 반대로 변경 가능한 값과 가림은 미상으로 남긴다. | CE의 단일 파일 분석과 상용 interfile 분석을 구분한다. 함수 호출이 값을 바꾸지 않는다는 가정을 가져오지 않는다. |
| [Needle 생성 코드](https://github.com/uber/needle/blob/c6a3b2c5f4bb60da4ab9ee97fea38cdf45cd4bcc/Sample/MVC/TicTacToe/Sources/NeedleGenerated.swift) | 생성 파일도 실제 프로그램 입력으로 검사한다. 기본·동적 모드와 생성 파일 제외를 각각 재현한다. | `Needle`라는 이름만 보고 모든 컴포넌트·프로퍼티를 보존하지 않는다. |

이번 코드는 불변 Swift `let` 별칭과 괄호를 최대 64단계까지 해석한다. 매개변수·클로저 캡처·
조건 패턴·계산 프로퍼티·타입 이름을 가린 수신자가 바깥 이름을 가리면 그 값을 가져오지 않는다. 가변 문자열은
외부 변경이나 inout 전달을 놓칠 수 있으므로 정적 채널 이름으로 확정하지 않는다.
채널 재대입은 기존 지역·프로퍼티 바인딩에 합치며, `self.channel`과 bare `channel`을
섞거나 클로저가 바깥 채널을 바꾸면 충돌을 놓치지 않는다. 접근자에도 별도 스코프를 적용한다.
컴파일러가 연산자 구현을 확인한 것이 아니므로 `+`, 보간, 함수 반환값, 다른 파일의 상수,
`#if` 활성 분기는 새로 판별하지 않는다. 문자열 결합까지 지원하는 완전한 상수 평가기가 아니다.

수정 전에는 매개변수와 계산 프로퍼티가 전역 `name = "wrong"`을 가려도 채널을 `wrong`으로
확정했고, `mutate(&name)`에 넘긴 가변 문자열도 처음 값으로 확정했다. 세 회귀 검사가 모두
실제 assertion에서 실패하는 것을 확인한 뒤 수정했다. `dynamic`에서 정적으로 바뀐 경우와
잘못된 정적 값에서 `dynamic`으로 바뀐 경우를 구분한다.

## 실제 인덱스 관측

| 입력 | 수정 전 / 조건 | 관측 |
|---|---|---|
| 직접 문자열 `let direct = "direct"` | 일반 빌드 | 정적 이름 `direct` |
| `let alias = direct` | 수정 전 → 후 | `dynamic: alias` → 정적 이름 `direct` |
| `let parens = ("parenthesized")` | 수정 전 → 후 | `dynamic: parens` → 정적 이름 `parenthesized` |
| `let concat = "com.example/" + "camera"` | 수정 후에도 | `dynamic: concat`; 연산자 의미 미확인 |
| 사용한/사용하지 않은 `static let` | 실제 compiler index | 각각 `reachable` / `unreachable` |
| Needle 기본 모드 | 실제 Foundation 런타임 + 수기 생성 코드 형태 | 실행 `needle-ok`; 제공 프로퍼티·provider 도달 가능, 미사용 서비스 미도달 |
| Needle `NEEDLE_DYNAMIC` | 별도 scratch에서 빌드 | 실행 `needle-ok`; 등록 클로저를 통해 제공 프로퍼티 도달 가능, 미사용 서비스 미도달 |
| Needle 생성 파일을 exclude | 실행 바이너리는 그대로 | 실제 사용 중인 제공 프로퍼티가 `unreachable`; `configured-path-filter` 한계 동반 |
| storyboard `customClass="RuntimeScreen"` | 다른 Swift 참조 없음 | `retained`, 이유 `interfaceBuilder`; 대조 타입은 `unreachable` |
| storyboard identifier만 있고 customClass 없음 | 같은 인덱스 | `RuntimeScreen`도 `unreachable`; identifier를 클래스명으로 추측하지 않음 |

Needle 소스는 `uber/needle`의 `c6a3b2c5f4bb60da4ab9ee97fea38cdf45cd4bcc`에 고정했다.
원본 `Sources/NeedleFoundation`(Apache-2.0)을 저장소 밖에 내려받아 그대로 빌드했다.
컴포넌트와 등록 코드는 작은 수기 하네스다. Needle generator 자체를 실행하거나
실제 앱 전체·pluginized 모드를 검증한 것은 아니다. 동적 모드의 실제 동작은
[Component.swift](https://github.com/uber/needle/blob/c6a3b2c5f4bb60da4ab9ee97fea38cdf45cd4bcc/Sources/NeedleFoundation/Component.swift)의
키 경로·등록 테이블을 사용한다.

스토리보드 identifier는 클래스 이름이 아니라 문서 안에서 컨트롤러를 선택하는 키다.
[Apple instantiateViewController 문서](https://developer.apple.com/documentation/uikit/uistoryboard/instantiateviewcontroller(withidentifier:))가
그 의미를 정의한다. 현재 Cartograph는 모든 `customClass`를 보존하므로 런타임 분기로 선택되는
클래스를 분기별로 놓치지는 않는다. 대신 실제로 선택되지 않는 장면도 보존하며, 문자열 호출에서
그 클래스까지의 `usedBy` 경로는 만들지 않는다. 재현은 XML 참조와 인덱스 보강 검사이며 UIKit 앱을
실행한 검사가 아니다. 소스 storyboard가 없거나 필터 밖에 있으면 이 보장은 적용되지 않는다.

## 재현

```bash
swift build
python3 Scripts/verify-analysis-blindspots.py \
  .build/out/Products/Debug/cartograph \
  --needle-source /path/to/needle-at-c6a3b2c5
```

스크립트는 네트워크에 접근하지 않는다. 지정한 체크아웃에서 Foundation 소스만 복사하고,
별도 임시 패키지와 실제 인덱스를 만든다. 결과 JSON과 생성 소스·빌드 로그를 출력한 임시 경로에
남긴다. `--needle-source`를 생략하면 Needle은 실행하지 않았다고 명시한다.
현재 하네스의 바이너리·인덱스 경로는 Xcode 기반 macOS SwiftPM을 대상으로 한다.

## 남은 우선순위

1. 다른 파일의 상수·문자열 연산은 컴파일러가 확인한 심볼/연산자와 결합해야 한다. 이름만 같은
   변수나 사용자 정의 연산자를 표준 문자열로 오인하는 최적화는 넣지 않는다.
2. Needle 생성 파일 제외·미생성·낡은 빌드는 그래프 입력 공백이다. 기존 필터·신선도 한계를
   소비자가 반드시 확인해야 한다. 특정 프레임워크 이름만 보고 무조건 보존하는 방식은 피한다.
3. 스토리보드 장면별 사용 경로가 필요하면 identifier→장면→customClass 관계와 근거를 그래프에
   추가한다. 지금의 포괄 보존을 좁히려면 별도의 반대 방향 코퍼스와 실제 프로젝트 델타가 필요하다.

## 검증 기록

727 tests와 커버리지 93.61%를 통과했다. CLI 계약, 기존 실제 인덱스 코퍼스,
자기 분석 dead/cycles(타입 포함)/rules strict, Dart 보존 왕복 및 고정 battery_plus 검사도 통과했다.
새 재현 스크립트는 이전 배포 바이너리에서 별칭·괄호 기대값에 실패하고 수정 바이너리에서
Needle 두 모드까지 통과했다. 테스트의 초록불만으로 지원 범위를 늘려 쓰지 않는다.
