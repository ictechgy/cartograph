# Handoff

_Last updated: 2026-11-22 by Claude (계열 점검 3차 PR #240: 임계값 범위 검사와 리뷰 반영, PR #237 돌연변이 확인, Linux 스크래치 검증)_

작업 규칙은 [AGENTS.md](AGENTS.md), 이전 원문은 [HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 있다
(2026-09-25 기록은 그 파일 끝 절로 옮겼다). 이력의 오래된 버전·Next Steps는 현재 지시로 되살리지 않는다.

## Current Status

- 최신 발행은 **0.30.0**(2026-11-03, CHANGELOG)이다. 0.23.0~0.30.0의 내용은 CHANGELOG의 해당 절이 정본이다.
- 계열 9개 저장소 점검(2026-11-03)에서 나온 수정은 **PR #237**로 `main`에 스쿼시 머지됐다
  (2026-11-09, `f892ddb`). CHANGELOG `[Unreleased]`에 정리돼 있고 아직 발행하지 않았다.
  아래 절의 커밋 해시는 PR 브랜치의 것이며, `main`에는 `f892ddb` 하나로 합쳐졌다.
- `main` `f892ddb`의 CI 체크 12개(자기 분석, synthesized-property 보존 측정 포함)가 모두 성공했다(2026-11-10 확인).
- 후보 **B4**(플러그인 MCP 선언)는 **PR #239**에서 처리했다(2026-11-15, `main` `5b73a48` 기준).
  아래 "PR #239 — B4 처리" 절을 본다. 이 PR도 CHANGELOG `[Unreleased]`에 들어가며 발행은 따로 지시가 있을 때 한다.
  PR #239는 `main` `8f6a1c3`로 스쿼시 머지됐고 그 커밋의 CI도 성공했다.
- 계열 점검 3차(2026-11-22)는 브랜치 `ccr-37904670-hxdjsx`(`main` `8f6a1c3` 기준, PR #240)에 있다. 아래 "3차 점검" 절을 본다.

### 3차 점검 (2026-11-22, `main` `8f6a1c3` 기준)

커밋 해시는 브랜치의 것이다.

- **임계값 범위 검사** (`0aba669`): `max_efferent_coupling`만 음수를 거부했다. 음수 `max_cycles`·
  `max_unused_symbols`·`max_rule_violations`는 발견 0건인 실행도 실패시켰고("found 0, allowed at most -1", exit 1),
  `max_instability: 90`(백분율)이나 `.nan`은 아무 정점도 걸지 못해 `metrics --strict`가 exit 0으로 통과했다.
  이제 개수는 0 이상, 비율은 0 이상 1 이하만 받고 그 밖은 키·값·원인·고치는 방법을 담은 설정 오류(exit 2)다.
  0과 1(정수 표기 포함)은 그대로 받는다. 문구는 아래 "리뷰 반영"에서 고쳤다.
  CHANGELOG `Fixed`에 업그레이드 노트, README 두 벌의 지표 절에 범위를 적었다. 새 테스트 9건(키·값 조합)은 수정 전
  코드에서 전부 실패했다.
- **계약 스크립트** (`400f026`): 빈 인덱스 픽스처에 `--allow-empty-index`를 주고 두 경우가 exit 2인지 본다. 수정 전
  바이너리로는 1과 0이 나와 두 줄 모두 실패하는 것을 확인했다.
- **README 예시** (`2cdadcc`): `unused-parameter`·`assign-only` 예시가 실제로 나오지 않는 형식(`'Net.Client.fetch(...)'`,
  `of 'Net.Client'`)이었다. 실제 문구는 함수의 모듈 한정 이름과 소유 타입의 짧은 이름이다(코퍼스 기대 파일과 자기 분석
  출력이 근거). 진단 문구 자체는 바꾸지 않았다.
- **PR #237 새 테스트의 돌연변이 확인**(아래 다음 할 일 1, 코드 변경 없음): Linux 스크래치 빌드에서 변이 20개를 하나씩
  넣고 해당 스위트를 돌렸다. 18개는 의도한 테스트가 실패했다 — 프로토콜 폐포 제거, `s:SL`(보존), 프로토콜 요구사항
  가드, `codableEnumCase` 근거, 무시 소스 근거의 순서·제거·impact 검토 근거, assign-only 폐포, 상위 클래스 inheritance
  포함, `#if` 파일 import(분석·스캐너), 레이어 절대 경로 후보, 구문 쪽 `Comparable`·`Swift.` 한정, 무시 소스의 `extends`
  포함·추적 링크 제외·저장소 밖 Git 미실행. 나머지 2개는 동작이 같은 변이다. `codableEnumCase`를
  `retainsContainingType`에서 빼도 이 근거는 `needsReachableOwner`라 조건부로 분류돼 `inheritedRetentions`(무조건
  근거만 받음)에 닿지 않는다. `ReachabilityAnalyzer.synthesizedReaderProtocolUSRs`에서 `s:SL`을 빼도
  `accessHidingOwners`의 둘째 루프(`RetentionPolicy.synthesizedConformances`, 같은 다섯 USR의 직접 준수 포함)가
  같은 정점을 숨긴다. 즉 첫 루프는 지금 둘째 루프에 포함된다(정리 후보, 손대지 않음).
- **무시 컴파일 소스의 실제 인덱스 확인**(다음 할 일 2의 일부, 코드 변경 없음): Git 저장소에 무시된
  `Generated.swift`만 부르는 `Helper.usedByGenerated()`와 아무도 안 부르는 `Helper.neverCalled()`를 두고 Linux에서
  빌드해 `dead`를 돌렸다. `neverCalled`만 보고되고, `--explain usedByGenerated`는 "referenced from a Git-ignored source
  file the compiler indexed"로 답했다. `source-discovery-exclusions` 한계도 그 경로를 싣는다. 동결 코퍼스·검증기는 아직이다.
- **Linux 스크래치 검증 방법**: swift.org 다운로드 호스트가 막혀 Docker Hub 공식 `swift:6.4.3-noble` 이미지의 툴체인
  레이어(digest 대조, 이미지 빌드가 swift.org 서명을 검증한 tarball)를 스크래치에 풀었다. 저장소 사본에서만 `import Darwin`을
  Glibc 기반 shim으로, `CryptoKit`(SHA-256만)·`CoreData`(컴파일 모델 읽기 불가)를 shim 모듈로 바꾸고 macOS 전용 테스트
  파일 두 개(`BoundedInputReadTests`, `CoreDataSessionInvalidationTests`)를 뺐다. C 헤더는 `-Xcc/-Xcxx -I<toolchain>/usr/lib/swift`
  (와 `.../Block`)로 찾는다. `DEVELOPER_DIR`에 `Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib` 링크(→ `.so`)를
  두면 CLI가 Linux 인덱스(`.build/out`)를 읽는다. 이 shim은 커밋하지 않는다.
  - 결과: 테스트 타깃 8개 중 Core·Config·Syntax·Analysis·Export 다섯이 통과하고, Kit·IndexStore·CLI에서 48건이 실패한다.
    전부 `xcrun`·시뮬레이터·`/tmp` 별칭·macOS libIndexStore 경로에 걸리는 macOS 전용이며, 수정 전후 실패 목록이 새 테스트
    두 개를 빼고 같다. 자기 분석은 네 가지 모두 exit 0이다(`dead` 경고 26건 = macOS CI의 22건 + shim 모듈 4건, 순환 없음,
    `rules`는 shim 모듈 세 개의 레이어 미지정 정보 3건). CLI 계약은 리뷰 반영 뒤 276건 통과(기존 271 + 임계값 5줄),
    `xcrun swiftc`로 인덱스를 만드는 2건만 실패. 처음 보고한 "47건 실패·275건 통과"는 셈을 잘못한 것이다(출력이 섞인
    실패 줄 하나를 놓쳤고, 통과 줄은 273이었다).
  - 못 돌린 것: `coverage.sh`(`xcrun llvm-cov`·`.xctest` 번들 전제), `verify-fixtures.sh`(Objective-C 코퍼스와 macOS
    인덱스 전제), 위 macOS 전용 테스트. 근거는 macOS CI다. GLM 리뷰도 이 환경에서 쓸 수 없었다.
- **제외한 것**: B1·B3·B5·C는 아래 "남은 후보"대로 사용자가 고른 뒤 착수한다. B2는 Narrowing 절차가 필요하다.
  Encodable만 준수하는 열거형의 케이스도 `codableEnumCase`로 살지만(디코딩이 없어 케이스를 만들지 않는다) 보존을 좁히는
  변경이라 반대 방향 코퍼스와 실제 프로젝트 근거 없이 하지 않는다. `unused-parameter` 문구에 소유 타입을 넣는 것은 출력 변경이라
  코퍼스 기대 파일 갱신과 함께 따로 다룬다.
- **리뷰 반영** (PR #240 독립 리뷰, 차단 항목 없음):
  - 문구(`3a1138e`): AGENTS.md는 오류에 원인과 해결 방향을 함께 담으라고 한다. 비율 오류는 원인만 말했으므로
    "Write a percentage as a fraction (0.9 for 90%), or remove the key to turn the check off."를, 새로 검사하는 세 개수 키는
    "Set 0 to allow none, or remove the key to turn the check off."를 붙였다. 비율 범위는 "from 0 to 1 inclusive"로 쓴다.
    `max_efferent_coupling` 문구는 발행된 그대로 두고("must be 0 or greater"가 고칠 범위를 말한다) 테스트가 바이트로 고정한다.
  - 테스트(`3a1138e`): 값("(got -3)", "(got 90.0)", "(got nan)", "(got -inf)" 등)과 원인·고치는 방법까지 단언한다.
    `#expect(throws:)`의 반환값을 쓴다(클로저 매처 형태는 Swift Testing이 soft-deprecated로 표시했다). 경계값은 두 비율 키 모두
    0과 1(YAML 정수)로 돈다. 돌연변이 — "(got …)" 삭제(개수·비율), 고치는 방법 삭제(개수·비율), `limit <= 0` — 를 모두 잡는다.
  - 계약(`10c6624`): 종료 코드만 보던 두 줄에 `expect_output` 문구 확인을 더하고, 경계값 설정으로 `metrics --strict`가
    0으로 끝나는 대조군을 넣었다. 문구를 "invalid threshold"로 바꾼 변이는 문구 줄이, 개수 0을 거부하는 변이는 대조군이 잡는다.
  - 문서(`7ac4108`): README 두 벌의 설정 참조 블록, `cartograph init` 템플릿, `Thresholds` 문서 주석에 범위를 적었다.
  - 기록만 하는 것: `CartographKit` 임베더가 코드로 만든 `Thresholds`는 로더를 거치지 않아 범위 검사를 받지 않는다
    (`ArchitectureMetricsTests`가 `maxEfferentCoupling: -1`을 코드로 넣어 쓴다). `assign-only` 진단 문구는 어느 테스트·코퍼스
    기대 파일도 고정하지 않는다 — README 예시를 바꾼 근거는 `AnalysisDiagnostics.assignOnlyDiagnostics` 코드다.

### PR #239 — B4 처리 (2026-11-15)

아래 커밋 해시는 PR 브랜치의 것이다. 스쿼시 머지되면 `main`에는 커밋 하나로 합쳐진다.

- **선언**: `.claude-plugin/plugin.json`에 인라인 `mcpServers.cartograph`를 넣었다(`5492331`).
  명령은 PATH의 `cartograph`, 인자는 `serve --project ${CLAUDE_PROJECT_DIR}`다.
  - 근거 문서: code.claude.com/docs/en/plugins-reference의 `mcpServers` 절(인라인 맵·파일·번들·배열, 루트 `.mcp.json`과
    병합되고 같은 이름은 뒤 선언이 덮음). code.claude.com/docs/en/mcp의 "Plugin-provided MCP servers" 절(`.mcp.json` 또는
    `plugin.json` 인라인, stdio의 `command`·`args`·`env`에서 `${CLAUDE_PROJECT_DIR}` 치환). 플러그인 설정이
    `${CLAUDE_PROJECT_DIR}`를 기본값 없이 바로 치환한다는 문장은 같은 문서 "Option 3: Add a local stdio server" 절에 있다.
  - 두 형식 모두 문서화돼 있다. 루트 `.mcp.json`을 고르지 않은 이유는 플러그인 루트가 저장소 루트라서다.
    이 저장소를 여는 기여자에게 프로젝트 MCP 서버로도 읽힌다.
  - 플러그인 MCP 서버의 작업 디렉터리는 문서에 없다. 그래서 README 예시의 `--project .` 대신
    `${CLAUDE_PROJECT_DIR}`를 쓴다. `--project`는 `.cartograph.yml`의 `project_path`보다 우선한다.
  - `${CLAUDE_PROJECT_DIR}`는 세션이 시작된 프로젝트 루트이고 worktree에 들어가도 그대로다(code.claude.com/docs/en/hooks,
    MCP 문서는 같은 값이라고 함). worktree·다른 디렉터리·`ios/` 하위 프로젝트는 CLI에 `--project`를 주라고 문서에 적었다.
  - 같은 서버가 여러 곳에 있으면 한 번만 연결하고 local·project·user가 플러그인보다 앞선다. 플러그인은 URL·명령으로
    대조하며 인자 비교 여부는 문서에 없다(mcp 문서 "Scope hierarchy and precedence").
  - 매니페스트 `version`은 설치자를 그 버전에 묶는다(plugins-reference `version` 절). 0.30.0을 설치한 사용자는 다음 발행에서
    버전을 올려야 이 선언을 받는다. 버전 대조 검사가 있으므로 발행 절차대로 올리면 된다.
- **검사**: `Scripts/verify-plugin-manifest.py`(CI `comparison-contracts` 잡)가 선언을 고정하고, 추적되는 루트
  `.mcp.json`을 거부하고(작업 트리가 아니면 있는 것만으로 거부), CLI 소스에 `serve`·`--project` 문자열이 남아 있는지
  본다(`8702540`·`31c436c`, 선언 전에는 실패하는 것을 확인함). CLI 검사는 소스 텍스트 경보선이고, 실행 보장은
  `verify-mcp.py`가 첫 서버를 이 선언 그대로 띄워 맡는다. 다른 하네스가 쓰는 `MCPProcess` 기본 인자는 그대로다.
  `coverage.sh --skip-test`의 신선도 입력에 `.claude-plugin`을 넣었다(`78093c0`).
- **문서**: 스킬 템플릿·사본, README 두 벌의 `skill` 절, 플러그인·마켓플레이스 설명에 PATH 전제를 적었다(`20bde1c`).
  리뷰 뒤 분석 루트·중복 서버·셸과 서버의 PATH 차이를 더했다(`b0d7541`).
- **CI 수정**: native 관측의 `ci.yml` 고정값(바이트·sha256·blob)을 갱신했다(`76f08a9`). 전례는 `7dc7f74`와 PR #237의
  `f9bca67`이다. 세 번째라 갱신할 세 곳을 AGENTS.md「분석·검증 시 주의점」에 적었다(`e69b2e3`).
- **리뷰**: GLM 리뷰 대신 독립 Claude 리뷰를 받았다. 지적(S1·S2·N1~N7)과 처리 결과는 PR 본문의 "리뷰 반영" 표에 있다.
- **이 환경에서 못 돌린 것**(Linux, Swift 툴체인 없음): 컴파일·`swift test`(특히 `AgentSkillTemplateTests` 바이트 일치),
  `verify-mcp.py` 실제 실행, coverage·CLI 계약·fixtures, 자기 분석 네 가지. 근거는 PR #239의 macOS CI다.
  `claude plugin validate`도 이 환경에 없어 돌리지 않았다.

### PR #237 — 처리한 것

- **오탐·조용한 누락 수정** (보존을 넓히는 방향이라 결과가 사라질 수는 있어도 새로 생기지 않는다)
  - Git이 무시했지만 컴파일된 소스가 쓰는 선언을 `ignoredSourceReference`로 보존한다(`319d01a`).
    다른 보존 근거가 없을 때만 붙는 마지막 폴백이고, `impact`에서는 런타임 검토 사실로 나온다.
    보조 읽기는 본 분석이 고른 스토어만 쓰고(`--index-store` 준수), 추적 파일로 풀리는 무시 링크는 뺀다(`cbff8a9`).
  - 합성 Codable/Equatable/Hashable 준수를 인덱스와 프로젝트 프로토콜을 거쳐 판정한다(`47c5f9a`).
    `Comparable`(`s:SL`)도 Equatable로 센다. assign-only 판정도 프로토콜을 거친 준수를 따른다(`12f4cb4`).
  - `codableEnumCase`는 열거형이 도달 가능할 때만 케이스를 살리고, 열거형 자체는 살리지 않는다(`4bb5aa5`).
  - `#if`가 있는 파일의 `unused-import`를 보고하지 않는다(`18d6a3d`, README 문구 `9149285`).
  - Git 선택이 폴백하면 `source-discovery-git-unavailable` 한계를 싣는다(`81750c5`).
    선택 결과는 `GitSourceSelection`, 목록은 값 타입 `GitSourceInventory`로 나눴다.
    자기 분석의 타입 순환을 끊으려는 분리다(`51a4765`).
  - target scope 인벤토리가 `.build-*` 스크래치를 건너뛴다(`8dc0060`).
- **동작 변경(업그레이드 노트)**: 레이어 `path` 판정은 프로젝트 안 파일에 상대 경로만 쓴다(`a78831f`).
  의미가 달라진 공개 API `LayerDefinition.matches(candidates:)`는 지우지 않고 deprecated로 표시했다(`a87ceae`).
- **계약·CI·문서**
  - 스킬에 `cartograph_prepare`를 넣었다(`8ac2ce6`).
  - 플러그인 매니페스트 버전을 CI·릴리스에서 대조한다(`a7d1536`, 릴리스 하네스 `352e1df`).
  - iOS preflight를 PR CI에서 돌린다(`e3e6b26`).
  - `query`의 `unknown` 상태를 계약에 적었다(`c1e7ccf`).
  - 단위 테스트만의 커버리지가 기준 아래면 경고한다(`c5ca9df`).
  - isthmus `c76e105` 벡터를 다시 벤더링하고 SQL 관계 벡터를 실행한다(`c7648b4`).
  - AGENTS의 query 스키마 규칙을 실제 계약에 맞췄다(`9d6a1a6`).
- **CI 수정**
  - fix 검증 하네스의 실패 스위치를 `#if` 제외 대상 밖 파일로 옮겼다(`3f9c4a2`).
  - native 관측의 `ci.yml` 고정값(바이트·sha256·blob)을 갱신했다(`f9bca67`). 전례는 `7dc7f74`다.
  - 보존 측정 기준선 어댑터가 `.codableEnumCase`를 남기고 C-P1-3 두 플래그만 되돌린다(`644abc8`).
- **코퍼스**: FalsePositiveCorpus에 다음 오탐 계열을 넣었다(`bc8d1a6`). 새 finding은 없고, 기대 파일 4개의
  `unindexed-sources:` 분모만 소스 파일 2개 추가로 52→54가 됐다(자기 분석 CI가 잡음).
  - 프로토콜 상속·별칭으로 얻은 Codable
  - Codable 열거형 케이스
  - `#if`만 있는 import

### PR #237 — 제외한 것과 이유

- **Git 무시 컴파일 소스의 코퍼스 사례**: 빌드 시점에 무시 파일을 만들어야 한다. 그러면 동결된 JSON 기대 파일
  5개의 `limitations`도 바뀐다. 전용 하위 코퍼스와 자체 검증기로 따로 다룬다.
- **보조 인덱스 읽기 비용 측정**: 무시 소스가 있을 때만 한 번 더 읽는다 — 모든 유닛을 열어 의존 목록을 훑고,
  레코드는 무시 파일의 것만 읽는다(`RawIndexStoreReader.swift`). 수치는 macOS CI나
  실제 프로젝트에서 재야 하고, 이 PR에서는 재지 않았다.
- **B1·B3**: 수정 범위를 넘는 새 기능이다.
- **B2**: 보존을 좁히는 변경이라 CONTRIBUTING "Narrowing one" 절차가 필요하다.
- **Core의 Darwin 파일 I/O를 Kit로 옮기기**: 큰 순수 리팩터링이다. 예외로 문서화만 했다.
- **계열 `query` 스키마 통일**: 공개 JSON 계약을 깨므로 하지 않는다(아래 계열 결정).

### 컴파일 근거와 리뷰 방식

- **이 PR을 작성한 세션에는 Swift 툴체인이 없었다**(Linux 컨테이너, Core의 `import Darwin`). 따라서 다음의
  유일한 근거는 PR #237과 `main` `f892ddb`의 macOS CI다. 로컬에서는 Python 하네스와 정적 대조만 돌렸다.
  - 컴파일과 `swift test`
  - `coverage.sh`·`verify-cli-contract.sh`·`verify-fixtures.sh`
  - 자기 분석(dead·cycles·type cycles·rules)
  - 새 테스트의 돌연변이 확인
- **GLM 리뷰 대체**: AGENTS가 요구하는 `packet-ask` GLM 리뷰는 이 환경에서 쓸 수 없었다. 대신 전체 diff를
  독립 Claude 리뷰로 검토했다. 지적과 처리 결과는 PR 본문에 있다. GLM 리뷰 없이 머지됐으므로, GLM 리뷰를 받을 수
  있는 환경이 되면 이 변경을 후속 리뷰한다.

### 다음 할 일 (PR #237 머지 이후)

1. ~~새 보존 테스트의 돌연변이 확인~~ — 3차 점검에서 Linux 스크래치 빌드로 했다(변이 20개 중 18개 검출, 2개는 동작이
   같은 변이). 이 테스트들은 손으로 만든 스냅샷 위의 순수 분석이라 플랫폼과 무관하다.
2. 무시 컴파일 소스 하위 코퍼스와 검증기를 만든다(위 제외 항목). 실제 인덱스에서 보존이 동작하는 것은 3차 점검에서
   일회성으로 확인했다.
3. 보조 인덱스 읽기 비용을 HealthMap 등 실제 프로젝트에서 잰다.
4. 발행은 지시가 있을 때만 한다. 이때 `[Unreleased]`를 버전 절로 옮기고 플러그인 매니페스트 버전도 함께 올린다.
5. PR #239(B4)의 macOS CI에서 `AgentSkillTemplateTests`·`verify-mcp.py`·`verify-plugin-manifest.py`와 완료 검증
   네 가지를 확인한다. `claude plugin validate .`(v2.1.281 이상이면 MCP 항목도 검사)를 돌릴 수 있는 환경이면 함께
   돌린다. GLM 리뷰를 받을 수 있게 되면 이 변경도 후속 리뷰한다.

| 발행물 | 상태 |
|---|---|
| CLI / GitHub Release | 0.30.0 |
| Homebrew | 릴리스 workflow의 tap 단계는 `HOMEBREW_TAP_TOKEN` 미설정으로 건너뛴다. 발행마다 tap PR과 `brew test`를 따로 확인한다 |
| GitHub Action | `action-v1.0.0` |

## 남은 후보 (사용자가 고른 뒤 착수)

2026-09-25 경쟁 조사의 B·C 후보는 0.23.0~0.30.0 사이에 일부만 다뤄졌다.

- **미구현**
  - B1 매니페스트 수준의 암묵·중복 의존성 검사(Package.swift/xcodeproj 선언과 인덱스 모듈 참조를 대조).
    kartograph의 `dependencies --resolved-dependencies`가 참고 구현이다.
  - B2 연결 안 된 `@IBOutlet`/`@IBAction` 개별 보고. 보존을 좁히는 변경이라 CONTRIBUTING의 "Narrowing one"
    (반대 방향 코퍼스 + 실제 프로젝트 3곳 델타)을 통과해야 한다.
  - B3 redundant protocol conformance.
- **처리함**
  - B4 에이전트 플러그인: PR #239에서 처리. 매니페스트가 스킬과 함께 MCP 서버를 선언한다(위 "PR #239 — B4 처리").
- **부분 구현**
  - B5 삭제 가능 LOC 요약: `--file-summary`가 개수만 센다.
  - C 편집 뒤 인덱스 낡음: `cartograph_prepare`와 `index-staleness` 한계까지만 있다.
- **계열 결정(2026-11-04)**: gartograph·rustograph의 `query` 응답 스키마는 맞추지 않고 각자 고유의 공개 계약으로
  둔다. 공유하는 것은 출력 철학뿐이다. AGENTS.md 규칙을 이 현실에 맞게 고쳤다.

## Important Context / Avoid

- `check`는 dead·모듈/타입 cycles·rules만 묶는다. 지표 임계값은 `metrics --strict`에서만 게이트가 된다.
- AGENTS.md "삭제 판정을 내지 마세요" 때문에 삭제 지침형 기능은 만들지 않는다.
- 레이어 규칙 `rationale`·`hint`는 `text`·`json`과 `--explain`에만 나오고, 베이스라인 지문에는 들어가지 않는다.
- 돌연변이 테스트 뒤에는 `swift build`를 다시 돌린다. `swift test`가 실행 파일도 다시 빌드한다.
- 조사 에이전트의 "기능 없음" 주장은 grep과 코드로 확인한 뒤 반영한다(전례 있음).
- 적합성 벡터를 바꾸면 `conformance/conformance.lock`의 해시와 isthmus 커밋을 함께 갱신한다.
  isthmus `scripts/conformance-drift.mjs cartograph=<checkout>`으로 대조한다.

## Resume Prompt

저장소 루트에서 HANDOFF.md와 적용 AGENTS.md를 읽고 Git 상태를 확인해줘. PR #237은 `main`에 스쿼시
머지됐고(`f892ddb`) 아직 발행하지 않았어. B4는 PR #239에서 처리했어. "다음 할 일 (PR #237 머지 이후)"를
이어 가고,
남은 후보는 내가 고른 뒤 착수해.
발행·태그는 따로 지시가 있을 때만 해.
