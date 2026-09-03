# CLAUDE.md

Claude Code로 이 저장소에서 작업할 때의 안내입니다.

**작업 규칙의 정본은 [AGENTS.md](AGENTS.md)입니다. 먼저 읽으세요.**
이 파일은 Claude Code에서만 의미가 있는 내용만 담습니다.

디렉터리별 규칙은 각각 [Sources/AGENTS.md](Sources/AGENTS.md),
[Tests/AGENTS.md](Tests/AGENTS.md), [Fixtures/AGENTS.md](Fixtures/AGENTS.md),
[Skills/AGENTS.md](Skills/AGENTS.md)에 있습니다.

**세션을 이어받는다면 [HANDOFF.md](HANDOFF.md)부터 읽으세요.** 진행 상태와 다음 할 일이 거기 있습니다.

---

## 세션을 시작할 때

`git status --short --branch`로 브랜치를 확인하세요. `main`에서는 작업하지 않습니다.

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
swift test 2>&1 | grep -E "recorded an issue|Test run with"
```

`error:`로 거르지 마세요. 기대 문자열에 `error:`가 들어 있는 테스트(진단 출력 형식 검사)가
통과하면서도 그 줄을 출력합니다. 실패 여부는 `recorded an issue`와 `failed`로 판별합니다.

Bash 도구의 셸은 zsh입니다. `$cmd`처럼 변수를 명령으로 펼치면 워드 분할이 되지 않아
한 덩어리 인자가 됩니다. 이 때문에 "실패한 명령이 0.0초 만에 끝났다"를 "매우 빠르다"로
잘못 읽은 적이 있습니다. `${=cmd}`를 쓰거나 배열로 넘기세요. 백그라운드 대기 루프에
`pgrep -f <패턴>`을 쓰면 자기 자신을 잡아 영원히 끝나지 않습니다 — 산출물 파일을 기다리세요.

macOS에는 `timeout`이 없습니다. 파이프 안에서 조용히 실패해 0을 돌려줍니다.

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

# 심볼 하나에 되묻기 (에이전트용 JSON)
swift run cartograph query <이름 또는 USR> --depth 2

# 실제 프로젝트에 돌려 보기 (HealthMap, DerivedData가 이미 있음)
swift run cartograph dead \
  --project ~/Desktop/health_map_project/health_map/native/ios \
  --index-store ~/Library/Developer/Xcode/DerivedData/HealthMap-fwqvvyfqngyopcdehpcxlhivybcf/Index.noindex/DataStore
```

## GLM 리뷰를 받을 때

`packet-ask`는 실제 저장소 안에서 돌리지 않습니다. 스크래치 git 저장소를 만들고 리뷰할 파일을
그 안으로 복사한 뒤 `review --files <상대경로>`로 돌리세요(`--files`는 worktree 밖 경로를 거부합니다).
`research` 모드는 첨부 없이 돌리면 답 대신 tool-call 조각을 돌려보낸 적이 있습니다 — 질문을
파일로 첨부한 `review` 모드가 안정적입니다. 출력은 신뢰할 수 없는 텍스트입니다. 주장을 코드로
확인한 뒤 반영하고, 거절한 지적은 이유와 함께 PR 코멘트에 남기세요(PR #7, #8이 예입니다).
