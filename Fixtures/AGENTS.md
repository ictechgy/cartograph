# Fixtures/AGENTS.md

오탐 코퍼스 규칙입니다. 루트 [AGENTS.md](../AGENTS.md)를 먼저 읽으세요.

## 이 디렉터리가 존재하는 이유

단위 테스트는 손으로 만든 스냅샷을 봅니다. **컴파일러가 실제로 무엇을 인덱스에 기록하는지는 검증하지 못합니다.** 이 저장소의 오탐은 전부 그 틈에서 나왔습니다 — SwiftUI 프로퍼티 래퍼의 `$name` 분할, 프로토콜 구현, `@main`. `Fixtures/FalsePositiveCorpus`는 실제로 빌드되는 SwiftPM 패키지이고, `Scripts/verify-fixtures.sh`가 그것을 진짜 인덱스 스토어로 분석해 기대 파일과 **통째로** 비교합니다.

## 규칙

- **양방향으로 실패해야 합니다.** `expected-unused.txt` · `expected-test-only.txt` · `expected-retain-public.txt`는 보고 목록 전체입니다. 새 오탐(있으면 안 되는 줄)과 잃어버린 검출(있어야 하는 줄이 사라짐)이 똑같이 diff로 잡힙니다. "이 줄이 없는지"만 확인하는 단언을 쓰지 마세요.
- **새 오탐 계열은 코퍼스에 먼저 넣고 고칩니다.** 순서를 바꾸면 수정이 실제로 그 계열을 잡는지 알 수 없습니다.
- **수정을 끄고 돌려 실패하는지 확인하세요.** 첫 번째 코퍼스는 프로젝션 수정을 껐는데도 통과했습니다 — 아무것도 증명하지 않는 픽스처였습니다. 손으로 만든 프로퍼티 래퍼는 `$name` 분할을 만들지 않습니다. **SwiftUI의 `@State`만 그렇습니다.** 그래서 코퍼스는 SwiftUI에 의존하고, 빌드가 7초쯤 걸립니다.
- **자기 분석에서 제외되어 있어야 합니다.** `.cartograph.yml`의 `exclude`에 `Fixtures/**`가 있습니다. 픽스처는 일부러 미사용 선언을 담고 있으므로 자기 분석에 들어가면 `dead --strict`가 실패합니다.
- 케이스마다 README에 **어느 실제 프로젝트에서 어떤 형태로 나왔는지**를 적으세요. 코퍼스는 회귀 테스트이자 오탐의 역사입니다.

## 케이스를 추가할 때

1. `Sources/Corpus`(라이브러리) 또는 `Sources/CorpusApp`(엔트리포인트가 필요한 것)에 재현 코드를 넣습니다. 테스트 전용 케이스는 `Tests/CorpusTests`, Objective-C 는 `Sources/CorpusObjC`(인덱스에는 들어오지 않고 `limitations` 와 `bridges` 의 텍스트 스캔만 봅니다).
2. 기대 파일을 갱신합니다. 미사용 목록 셋(`expected-unused.txt` · `expected-test-only.txt` · `expected-retain-public.txt`)은 정렬된 전체 목록, `expected-bridges.json` 은 생성 시각·버전·프로젝트 경로를 자리 표시자로 바꾼 `bridges` 출력 전체, `expected-unused-with-retentions.txt` 는 `external-retentions.json` 을 걸었을 때의 목록입니다.
3. `Scripts/verify-fixtures.sh`를 돌려 통과를 확인한 뒤, **해당 수정을 잠시 되돌리고 실패하는 것까지 확인**합니다.
4. `Fixtures/FalsePositiveCorpus/README.md`에 케이스의 출처를 적습니다.

CI(`ci.yml`)가 이 스크립트를 돌립니다. 로컬에서 통과했어도 CI 로그를 확인하세요 — 툴체인 버전이 다르면 인덱스가 다르게 기록될 수 있고, 그것이 바로 이 코퍼스가 잡아야 하는 종류의 변화입니다.
