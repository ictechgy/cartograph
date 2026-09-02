# CLAUDE.md

Claude Code로 이 저장소에서 작업할 때의 안내입니다.

**작업 규칙의 정본은 [AGENTS.md](AGENTS.md)입니다. 먼저 읽으세요.**
이 파일은 Claude Code에서만 의미가 있는 내용만 담습니다.

디렉터리별 규칙은 각각 [Sources/AGENTS.md](Sources/AGENTS.md),
[Tests/AGENTS.md](Tests/AGENTS.md)에 있습니다.

---

## 세션을 시작할 때

빌드가 처음이면 의존성 해석에 몇 분 걸립니다(`indexstore-db`는 C++를, `swift-syntax`는
큰 Swift 트리를 컴파일합니다). 백그라운드로 돌리고 그동안 코드를 읽으세요.

```bash
swift build --build-tests
```

## 완료를 주장하기 전에

아래 두 가지를 **실제로 실행하고 출력을 확인한 뒤에만** 완료라고 말하세요.

```bash
Scripts/coverage.sh
```

```bash
swift build \
  && swift run cartograph dead   --strict \
  && swift run cartograph cycles --strict \
  && swift run cartograph rules  --strict
```

두 번째가 이 도구로 이 저장소를 분석하는 단계(도그푸딩)입니다. 이 도구가 실제로 발견한 결함은 전부 여기서만
드러났고 단위 테스트는 하나도 잡지 못했습니다. 건너뛰지 마세요.

`-Xswiftc -index-store-path`는 Swift 6.4 기본 빌드 시스템에서 무시됩니다. 요청한 디렉터리가
아예 생기지 않고, 그 상태로 도구를 돌리면 종료 코드 2가 나와 분석 실패로 오해하기 쉽습니다.
`--index-store`를 빼고 자동 탐색에 맡기세요.

인덱스에는 낡은 유닛이 남습니다. 파일을 옮기거나 지운 뒤 유령 정점이 보이면
`swift build --scratch-path .build-fresh`로 새 인덱스를 만들어 확인하세요.

## 출력을 읽을 때 주의할 점

`swift test`는 타깃마다 별도의 테스트 실행 결과를 출력합니다. 마지막 줄만 보면
다른 타깃의 실패를 놓칩니다. 다음과 같이 확인하세요.

```bash
swift test 2>&1 | grep -E "error:|issue at|Test run with"
```

`cartograph dead` 출력은 진단 줄 + 빈 줄 + 요약 줄 구조입니다.
`tail -n`으로 자르면 앞쪽 진단이 잘려 문제가 사라진 것처럼 보입니다.
실제로 이 착각 때문에 한 번 잘못 판단한 적이 있습니다. 요약 줄의 개수를 함께 보세요.

## 병렬로 돌려도 되는 것

빌드·테스트·자기 분석은 서로 독립적이므로 백그라운드로 함께 돌려도 됩니다.
다만 `swift build`와 `swift test`를 동시에 돌리면 `.build` 잠금을 두고 서로 기다립니다.
한 번에 하나만 돌리세요.

## 이 저장소에서 자주 쓰는 확인 명령

```bash
# 특정 심볼이 왜 살아 있는지
swift run cartograph dead --explain <이름 또는 USR>

# 모듈 구조를 한눈에
swift run cartograph graph --level module --format mermaid

# 특정 모듈만 잘라서 보기
swift run cartograph graph --level type --include 'Sources/CartographAnalysis/**'
```
