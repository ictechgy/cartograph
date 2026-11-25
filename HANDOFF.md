# Handoff

_Last updated: 2026-11-25 by Claude (계열 점검 5차: 범위 밖 무시 파일을 세션 지문에 싣기, Linux 스크래치 검증)_

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
- 계열 점검 3차(2026-11-22)는 PR #240으로 `main` `e56eac8`에 스쿼시 머지됐다. 아래 "3차 점검" 절을 본다.
- 계열 점검 4차(2026-11-22)는 PR #241로 `main` `05ae10b`에 스쿼시 머지됐다. 아래 "4차 점검" 절을 본다.
- 계열 점검 5차(2026-11-25)는 브랜치 `ccr-37904670-hxdjsx`(`main` `05ae10b` 기준)에 있다. 아래 "5차 점검" 절을 본다.

### 5차 점검 (2026-11-25, `main` `05ae10b` 기준)

- **세션 지문이 범위 밖 무시 파일을 보게 했다** (`a01c740`, 4차 "물려받은 한계"의 MCP 세션 지문 항목). `ProjectFileInventory`는
  include/exclude와 무관하게 Git이 무시한 후보(소스·헤더·IB·Core Data 리소스)를 `source-discovery-exclusions`로 세고, 그중
  범위 밖 무시 소스는 따로 센다. 세션 지문(`AnalysisInputFingerprinter.addSourceFiles`)은 범위 안 경로와 범위 안 Git 목록만
  실어서, 범위 밖 무시 파일이 생기거나 사라지거나 범위 밖 파일의 추적을 풀고 무시해도 세대가 그대로였고 `serve`는 낡은 개수·경로·
  범위 밖 문장을 계속 냈다.
  - 재현(Linux 스크래치, `main` 바이너리, 실제 `serve`·실제 인덱스): 기본 제외 `**/*.generated.swift`에 걸리는 무시
    `R.generated.swift`를 만들면 새 CLI `query`는 `source-discovery-exclusions: 1 …; paths: ["Sources/Tiny/R.generated.swift"]`를 내는데
    세션은 세대 1 그대로 한계가 없다. `git rm --cached` 뒤 무시한 `Tracked.generated.swift`도 같다(5단계 중 2단계 불일치).
  - 수정: 지문 탐색이 범위 밖 후보를 결과 목록과 따로 모으고(`WalkInclusion.outsideScope`, 탐색 캐시 `WalkRecord.outsideScope`),
    Git 목록에 없는 것만 경로로 싣는다(`git-excluded-outside-scope:`). 내용은 읽지 않는다. 범위 밖이어도 Git 목록에 있는 파일은 싣지
    않아 세션을 다시 준비시키지 않는다. 그런 파일이 없는 프로젝트는 지문이 바이트까지 같다.
  - 처음 안은 범위 밖 후보를 결과 목록에 넣고 나중에 걸렀는데, 탐색은 같은 파일의 두 이름 중 먼저 걸은 것만 남기므로 범위 밖 무시
    링크(`Alias.generated.swift -> Zone.swift`)가 범위 안 원본을 목록에서 밀어내 그 내용 편집이 세대를 바꾸지 못했다. 그래서 범위 밖
    후보는 목록에 넣지 않고 따로 모은다. 이 형태는 새 테스트 두 번째가 고정한다.
  - 테스트(`GitSourceFreshnessTests`): 생성·삭제·추적 파일(세대 그대로)·추적 해제를 한 세션으로 돌리며 세대와 한계가 새 세션과 같은지,
    그리고 위 링크 형태. 첫 테스트는 `main` 소스에서 7건 실패한다. 돌연변이 셋도 모두 잡힌다 — 범위 밖 후보를 목록에 넣는 처음 안
    (링크 테스트 1건), 범위 밖 경로를 싣지 않음(첫 테스트 7건), Git 목록 대조를 빼고 범위 밖 후보를 전부 실음(추적 파일에서 세대가
    바뀌어 4건).
  - 적대 입력(실제 `serve` 한 세션 대 매 단계 새 CLI `query`, 한 패키지·한 인덱스, 21단계): 무시 파일 생성·삭제, 무시되지 않은 비추적
    범위 밖 파일, 같은 파일의 추적, 추적 해제와 무시, `.git/info/exclude`, 기본 제외 `Generated/` 아래 파일, 한글·공백 이름과 새 무시 글롭,
    무시된 헤더·xib(기본 설정에서는 범위 안), 추적 파일을 가리키는 무시 링크, 사용자 `exclude`가 기본값을 대체, 그 패턴 아래 무시 파일,
    좁힌 `include`와 그 밖의 무시 파일·추적 파일·무시 디렉터리 안 파일·디렉터리 삭제, 범위 밖 중첩 저장소와 그 안 파일, 설정 삭제.
    `main`은 11단계에서 세션과 새 실행의 `limitations`가 달랐고 브랜치는 0단계다. 범위 밖 추적·비추적 파일 세 단계에서 세대가 그대로다.
    중첩 저장소 안 파일 추가는 `485e477`에서 세대를 바꿨다(아래 리뷰 반영 S1에서 고쳤다).
  - 성능(Linux 릴리스 빌드 두 벌, 같은 패키지, `--session-freshness-interval 0`, 따뜻한 `cartograph_status` 25회의 중앙값, 공유 머신이라
    잡음이 크다. `Fixtures/**`를 제외한 패키지에 범위 밖 파일 N개): 무시 모드 N=2,000에서 `main` 58.5·55.6 ms 대 브랜치 65.3·64.1 ms,
    N=20,000에서 56.7·56.0 ms 대 112.2·125.5 ms로 파일당 약 3 µs씩 선형으로 는다(경로 해시. 스크래치는 CryptoKit 대신 순수 Swift SHA-256을
    쓴다). 추적 모드는 두 번의 측정에서 앞뒤가 뒤집혀 잡음 안이다(N=20,000: 965 대 871, 829 대 996 ms).
  - 기존 비용(이번에 고치지 않음): 추적 모드의 `main` 자체가 N=20,000에서 따뜻한 호출 하나에 0.8~1초다. `addGitSourceSelection`이 지문마다
    Git 목록 전체를 정렬하고 경로마다 글롭 대조를 하기 때문이다(탐색 쪽은 판정을 메모하지만 이 반복은 하지 않는다). 범위 밖 추적 파일이
    많은 저장소의 `serve` 비용 후보다.
  - 업그레이드 노트(CHANGELOG): 그런 파일이 있는 프로젝트에서는 이전 버전이 기록한 `affected --target-scope` 캡처의 입력 지문이 맞지
    않아 낡은 캡처로 다룬다. 다시 캡처한다.
  - 남은 것: Git 선택 실패 이유는 지문에 없다(두 실패 이유 사이의 전환이 세대를 바꾸지 않음, 결정적으로 재현할 방법이 없어 두었다).
    `empty-index` 한계의 전체 소스 수는 범위 밖 추적 파일까지 세는데 그 파일들은 지문에 없다(탈출구를 켠 빈 인덱스에서만 보이는 수).
    디렉터리 목록을 읽을 때 이미 끊어져 있던 링크는 대상이 생겨도 그 디렉터리가 바뀔 때까지 지문에 없다(탐색 캐시가 목록의 항목 종류를
    다시 쓰고, 끊어진 링크는 탐색 결과에 들지 않는다). 범위 밖 무시 링크와 범위 안 링크 모두 그렇다 — 아래 리뷰 반영의 적대 입력 13·16단계.
- **리뷰 반영** (PR #242 독립 리뷰, 차단 항목 없음, `485e477` 위에 커밋. 바꾼 두 Swift 파일은 스크래치 사본과 바이트까지 같다):
  - S1 중첩 저장소·서브모듈·worktree: Git 목록은 이것들을 디렉터리나 gitlink 하나로만 내므로, `485e477`에서는 그 안의 범위 밖 후보가 전부
    지문에 들어가 `include: ["Sources/**"]`인 이 저장소에서 `.claude/worktrees/<n>`의 파일을 만들거나 지울 때마다 세대가 바뀌었다(답은 같음).
    이제 탐색 때 루트가 아닌 `.git` 항목이 있는 디렉터리 아래의 범위 밖 후보를 뺀다(처음에는 실제 경로 접두사로 했고 2차 리뷰 F1에서
    걸은 길 기준으로 바꿨다, 아래). 경계는 전처럼
    `source-repository-boundary:`가 맡는다. 스크래치 cartograph에 worktree(.swift 683개)를 두고 파일 하나를 만들면 `485e477` 지문은
    바뀌고 새 지문은 그대로다.
  - S2 범위 밖 무시 링크: 링크가 Git이 고른 소스를 가리키면 범위 밖 무시 소스로 세지 않는다(`untrackedSources`). 재지정이나 대상 삭제는
    경로 목록을 바꾸지 않아 `485e477`(과 `main`)에서는 개수가 바뀌어도 세대가 그대로였다. 탐색이 범위 밖 후보마다 링크인지 기록하고
    (새로 걸을 때 방금 읽은 디렉터리 목록에서), 지문은 Git 목록에 없는 링크의 지금 대상(`fingerprintStamp.resolvedPath`, 없으면 `missing`)을
    한 줄 더 싣는다. 대상이 사라진 링크도 캐시된 목록에 남아 있으면 `missing`이 되어 세대가 바뀌고, 대상이 돌아오면 다시 바뀐다.
    남은 틈은 위 "남은 것"의 처음부터 끊어져 있던 링크다.
  - S3 Git 상태만 바뀌는 단계: 첫 테스트에 `R.generated.swift`가 있는 채로 `git add -f`·`git rm --cached`를 넣었다. 작업 트리는 그대로라
    탐색 캐시를 다시 쓰는 단계다. `485e477`에서도 통과한다(대조를 지문마다 하므로). Git 목록 대조를 탐색 출력과 함께 캐시하는 변이에서
    7건 실패한다.
  - N1 문구: README 두 벌·CHANGELOG를 "이 저장소의 Git 목록에 있는 파일"과 중첩 저장소 안 파일로 고치고, 링크 대상과 남은 틈을 적었다.
  - N2 메모리: `WalkRecord.outsideScope`는 추적 여부가 탐색 없이 바뀌므로 Git 목록에 있는 후보도 남긴다(중첩 저장소 안 후보는 뺐다).
    크기는 범위 밖 후보 수에 비례하고 지문마다 후보당 집합 조회 하나다. 문서 주석에 적었다.
  - 새 테스트: 링크 재지정·대상 삭제·복원(`485e477`에서 6건 실패), 중첩 저장소·worktree 편집은 세대 그대로이고 같은 범위 밖 무시 파일은
    새 세대(`485e477`에서 3건 실패). 변이(최종 테스트 기준): 중첩 저장소 필터 제거 → 3건, 링크 대상 제거 → 6건, Git 대조 캐시 → 7건,
    범위 밖을 싣지 않음 → 테스트 셋에서 18건, Git 목록 대조 없음 → 8건.
  - 적대 입력 2(실제 `serve` 대 새 CLI, `include: ["Sources/**"]`, worktree·중첩 저장소, 16단계): `485e477`은 worktree 파일 생성·삭제와
    중첩 저장소 파일 추가에서 세대가 바뀌고(02·03·05) 링크 재지정(08)·대상 삭제(10)에서 답이 달랐다. 새 바이너리는 02~05에서 세대가
    그대로이고 08·10·11이 같다. 두 바이너리 모두 다른 것은 13(처음부터 끊어진 범위 밖 링크의 대상 생성, 남은 틈)과 16(같은 일의 범위 안
    판, 이번 변경 이전부터)뿐이다. 기존 21단계는 0단계 불일치이고 20단계(중첩 저장소 안 파일)에서 이제 세대가 그대로다. 재현 5단계도 모두 같다.
  - 재검증: `swift test` 실패 이름 48개가 이전 브랜치 실행과 같다(Kit 이슈 15, CLI 26, IndexStore 15; `485e477` 사본은 새 테스트 둘을
    더해 50개). 자기 분석 네 가지 exit 0, `dead` 26건이 `485e477` 바이너리와 같고 정점 9853. CLI 계약 276 ok·실패 3건(`xcrun`) 동일,
    `verify-mcp.py`·`verify-ignored-sources.py` 통과. cartograph·Yams·swift-argument-parser 지문·한계가 `485e477` 바이너리와 같다.
    디버그 빌드 따뜻한 호출 비교(`485e477` 대 새, N=2,000/20,000 추적·무시)는 잡음 안이다(무시 N=20,000: 766 대 747 ms).
- **2차 리뷰 반영** (`35f9b55` 재검토, 고칠 것 하나와 잔지적 셋, `35f9b55` 위에 커밋):
  - F1 중첩 저장소 안을 가리키는 루트 안 디렉터리 링크: `35f9b55`는 중첩 여부를 실제 경로 접두사(`Vendor/Lib/` 아래)로 정했다. 소스 발견은
    `Vendor/Lib`로는 내려가지 않지만 `App/Lib -> ../Vendor/Lib/Sources`로는 내려가고(`App/Lib/.git`이 없다) 자식을 실제 경로
    `Vendor/Lib/Sources/X.swift`로 적어 범위 밖 무시 소스로 센다. 그래서 그 디렉터리에 파일을 더하거나 빼면 개수는 바뀌는데 세대는
    그대로였다(`485e477`에서는 바뀌었다). 이제 `recursiveFiles(under:separatesNestedRepositories:isIncluded:…)`(Core)가 걸은 길을 따라
    "루트 아닌 `.git` 항목이 있는 디렉터리 아래로 걸어 들어왔는지"를 파일마다 넘기고(판정은 이미 읽은 목록으로, 끊어진 `.git` 링크는
    경계가 아니다 — 발견의 `fileExists || directoryExists`와 같다), 같은 실제 디렉터리를 경계 안팎 두 길로 걸을 수 있게 방문 기록을 둘로
    나눈다. 끄면(기존 호출자 전부) 예전과 같다. `outsideNestedRepositories`(접두사 대조, 잔지적 N-b의 O(후보×경계))는 없앴다.
    재현: 실제 `serve`에서 `Sources/VLib -> ../Vendor/Lib/Pkg` 단계 셋이 `35f9b55`는 모두 다르고 새 바이너리는 모두 같다.
    새 테스트("중첩 저장소 안을 가리키는 루트 안 디렉터리 링크로 걸은 범위 밖 파일은 소스 발견처럼 지문에 남는다")는 `35f9b55`에서 4건
    실패한다. 변이: 방문 기록을 하나로 합침 → 이 테스트 4건, 중첩 표시를 무시함 → 이 테스트와 worktree 테스트에서 4건.
  - N-a 링크마다 `realpath`: 바꾸지 않았다. 인벤토리는 링크의 정규 경로가 Git이 고른 소스의 정규 경로인지로 센다
    (`untrackedSources`). `readlink` 문자열과 대상 stat(dev·ino·mode)은 링크 경로 중간의 디렉터리 링크가 같은 파일의 다른 이름(하드
    링크)으로 재지정되면 정규 경로가 바뀌어도 그대로라 판정이 같지 않다. 비용은 실측했다 — 디버그 빌드 따뜻한 호출에서 범위 밖 무시
    링크 20,000개가 같은 수의 무시 파일보다 약 1.3초(2,000개: 약 0.15초) 더 든다. 링크마다 (readlink 문자열, 대상 부모 디렉터리 식별)로
    결과를 메모하는 방식이 후보다.
  - N-b: F1 재설계로 해당 함수가 없어졌다. 경계 판정은 디렉터리마다 이미 읽은 목록에서 한 번이다.
  - N-c 문구: README.md·CHANGELOG의 영어 문장에 "outside the scope"를 넣고, 범위 안 파일은 중첩 저장소 안이어도 내용까지 지문에 들어가
    (발견은 건너뛰지만) 필요 없는 새 세대를 만들 수 있다는 이전부터의 과대 근사를 적었다. README.ko.md도 같은 내용으로 맞췄다.
  - 재검증: `swift test` 실패 이름 48개가 이전과 같다(Kit 이슈 15·CLI 26·IndexStore 15, 새 테스트 통과, Core 236 통과). `35f9b55` 사본은
    새 테스트를 더해 Kit 19 이슈다(로그가 섞여 컴파일러 테스트 셋의 결과 줄이 빠졌지만 이슈 수는 같다). 자기 분석 네 가지 exit 0, `dead`
    26건이 `35f9b55` 바이너리와 같고 정점 9854. CLI 계약 276 ok·실패 3건(`xcrun`) 동일, `verify-mcp.py`·`verify-ignored-sources.py` 통과.
    실제 `serve` 21단계 0건 불일치, 재현 5단계 모두 같음, 리뷰 시퀀스(F1 세 단계 포함 19단계)는 13·16단계(처음부터 끊어진 링크, 남은 틈)만
    다르다. cartograph·Yams·swift-argument-parser 지문·한계가 `35f9b55` 바이너리와 같고, cartograph worktree 편집은 두 바이너리 모두 지문을
    바꾸지 않는다. 디버그 빌드 따뜻한 호출(`35f9b55` 대 새)은 잡음 안이다(무시 N=20,000: 849 대 805 ms, 링크 N=20,000: 2,123 대 2,108 ms).
- **검증**(Linux 스크래치, 4차와 같은 방법: `mirror.gcr.io`의 `swift:6.4.3-noble` amd64 툴체인 레이어 `sha256:ec37e35b…`를 매니페스트와
  대조): 이번 사본 shim은 4차보다 많다 — `FoundationXML` import, `posix_spawn*_t` 비옵셔널, `siginfo_t._sifields`, `proc_listpgrppids`(0),
  `CFGetTypeID` 대체, `autoreleasepool`(Linux Foundation에 없음, 별도 파일), 테스트의 `st_atim`·`AnyObject.isEqual`. 바꾼 두 파일은 사본과
  저장소가 바이트까지 같다.
  - `swift test`: Core 236·Config 36·Syntax 631·Analysis 546·Export 73 통과. Kit·CLI·IndexStore 이슈 수는 `main` 소스 사본 14+7·26·15,
    브랜치 14·26·15다(`main`의 7은 새 테스트). 실패 테스트 이름도 새 테스트를 빼고 같다. 예외 하나: CLI의 `macOS collector`
    (`/usr/bin/xcrun` 없음) 실패 줄은 브랜치 로그에만 있는데, 타깃 출력이 섞인 `main` 로그에는 이 테스트의 결과 줄 자체가 없고 CLI 이슈 수는
    두 실행 모두 26이다.
  - 자기 분석 네 가지 exit 0. `dead` 26건(shim 4건 포함)은 같은 인덱스에서 `main` 바이너리와 줄까지 같고 정점 9845. 순환 없음, `rules`는
    shim 모듈 레이어 미지정 정보 3건.
  - `verify-cli-contract.sh`: 276 ok, 실패 3건은 모두 `xcrun`(인덱스를 만드는 2건과 `verify-since-lines.py`)이고 `main` 바이너리와 ok·FAIL 줄이
    같다. `verify-mcp.py` 통과, `verify-ignored-sources.py` 통과(경로 4개·미사용 7건), `verify-prepared-indexstore-sessions.py` 18 OK,
    `unittest discover -s Scripts/benchmark-inputs` 311 OK, `verify-plugin-manifest.py` OK.
  - 지문 동일성: 범위 밖 무시 파일이 없는 cartograph 자기 분석·Yams·swift-argument-parser에서 `cartograph_status`의 지문·한계가
    `main` 바이너리와 같다.
  - 못 돌린 것: `coverage.sh`(`xcrun llvm-cov`), `verify-fixtures.sh` 전체(SwiftUI·Objective-C·macOS 인덱스),
    `followup-verify-mcp-preparation.py`(macOS 전용), macOS 전용 테스트. 근거는 macOS CI다. GLM 리뷰는 이 환경에서 쓸 수 없었다.
- **제외한 것**: D1·D2(사용자 결정), B1·B3·B5·C(사용자 선택), B2(Narrowing 절차), 보조 인덱스 읽기 비용 측정(실제 프로젝트 필요),
  4차의 다른 물려받은 한계 둘(대소문자만 바꾼 이름 변경, 저장소 안 디렉터리 링크 — Linux에서 재현 불가), `assign-only` 문구 고정,
  `accessHidingOwners` 첫 루프 정리, `CartographKit` 임베더 `Thresholds` 검사.

### 4차 점검 (2026-11-22, `main` `e56eac8` 기준)

커밋 해시는 브랜치의 것이다.

- **무시 소스 한계 문장 정정** (`4b7bfde`): `source-discovery-exclusions`는 "Declarations used by ignored sources the
  compiler indexed are retained (ignoredSourceReference)."라고만 말했다. 그런데 `include`/`exclude`가 거른 무시 소스는
  보조 읽기 대상이 아니다(`ProjectFileInventory.ignoredSourceFiles`가 경로 필터를 건다). 기본 제외 `**/*.generated.swift`·
  `**/Generated/**`가 R.swift 기본 출력 `R.generated.swift`와 흔한 Sourcery·SwiftGen 출력 경로에 맞아, 기본 설정에서 그 파일만
  쓰는 선언은 색인돼 있어도 미사용으로 보고됐고 한계는 반대로 읽혔다(재현: 아래 하위 코퍼스의 `usedOnlyByExcludedGenerated()`).
  이제 거른 무시 소스가 있으면 그 개수와 고치는 방법(해당 `exclude` 패턴 빼기)을 덧붙이고, 따라가는 무시 소스가 없으면 보존
  문장을 싣지 않는다(이전 동작 그대로). 판정은 바꾸지 않았다 — 발견 목록은 전후가 같다.
  CHANGELOG `[Unreleased]`의 해당 `Fixed` 항목과 README 두 벌(보존 표, 소스 발견 절)에 경계를 적었다.
- **무시 컴파일 소스 하위 코퍼스와 검증기** (`01eafe9`, 다음 할 일 2): `Fixtures/IgnoredSourceCorpus`와
  `Scripts/verify-ignored-sources.py`. 무시 파일은 커밋할 수 없어 `Templates/*.txt`를 사본에 옮기고 `git init` 뒤 Git이 정확히
  그 경로만 무시하는지 확인한 다음 새 스크래치 경로로 빌드한다. 기대 미사용 목록 7건은 소스에서 정했다. 따라가는 생성 파일,
  기본 제외에 걸린 생성 파일, 컴파일되지 않는 작업 사본, 익스텐션만 하는 사용, 추적된 죽은 코드를 가리키는 무시 링크,
  준수·이름 참조를 한 패키지에 둔다. 무시 파일에서 나온 발견·정점·순환이 없는지, 한계의 경로 4개와 두 문장, `query` 상태·근거,
  `--explain` 문장도 본다. 대조군으로 같은 인덱스에서 생성 파일의 무시를 풀면 타입 순환과 그 파일의 미사용 타입이 나타난다.
  `verify-fixtures.sh` 끝에서 돈다(CI·릴리스 게이트가 이미 이 스크립트를 돌리므로 `ci.yml`과 native 관측 고정값은 그대로다).
- **돌연변이 확인**: 검증기는 Linux 스크래치 빌드의 변이 다섯 개를 모두 잡았다 — `IgnoredSourceReferences.targets`가
  빈 집합(`Helper`·`Screen`·`AdoptedByGenerated`가 새로 보고), `untrackedSources` 미필터(`DeadCallee`가 사라짐), 무시 소스의 경로
  필터 제거(`usedOnlyByExcludedGenerated()`가 사라짐), `extends`를 사용으로 셈(`ExtendedOnly`가 사라짐), 범위 밖 문장 제거(한계
  검사 실패). `main` 소스로 만든 바이너리는 한계 문장 검사에서만 실패하고 나머지 판정은 모두 통과한다 — 보존 동작 자체는 PR #237
  그대로라는 뜻이다. 새 단위 테스트 `GitSourceInventoryTests`의 범위 밖 문장 검사는 문장 가드를 뒤집은 변이에서 실패했다.
- **Linux 스크래치 검증**: 3차와 같은 방법(Docker Hub `swift:6.4.3-noble` 툴체인 레이어, 이번에는 Docker Hub 요청 한도 때문에 같은
  digest를 `mirror.gcr.io`에서 받아 sha256 대조)이다. 사본 shim은 3차와 조금 다르다 — `Darwin` 대신 `LinuxDarwinShim` 모듈 이름을 쓴다
  (`Darwin`이라는 모듈이 있으면 indexstore-db의 `#if canImport(Darwin)`가 켜져 블록 API로 컴파일하다 실패한다).
  - `swift test`: Core 236·Config 36·Syntax 631·Analysis 546·Export 73 통과. Kit·CLI·IndexStore의 실패 테스트 59개는 `main`
    소스로 같은 사본을 돌린 실패 목록과 이름까지 같다(전부 `xcrun`·`/private/tmp`·프로세스 그룹·시뮬레이터 전제). 3차의 48개와
    수가 다른 것은 shim 차이(`proc_listpgrppids`를 0으로 두는 등) 때문이며 이번 변경과 무관하다.
  - 자기 분석 네 가지 모두 exit 0. `dead` 경고 22건은 `main` 기준선과 줄까지 같고 정점만 2개 늘었다(새 프로퍼티·함수). 순환 없음,
    `rules` 발견 없음. 사본 동기화가 같은 내용을 다시 써서 생긴 `index-staleness`는 mtime을 되돌려 없앴다.
  - `verify-cli-contract.sh`: 276 ok, `xcrun swiftc`로 인덱스를 만드는 2건만 FAIL(3차와 같음).
  - `verify-ignored-sources.py`: 통과(경로 4개, 미사용 7건). `python3 -m unittest discover -s Scripts/benchmark-inputs` 311 OK,
    `verify-plugin-manifest.py` OK, `verify-release-workflow.py` 18 OK. `verify-coverage-inputs.py`는 GNU `mktemp -t`가 `X` 없는 템플릿을
    거부해 실패한다(`coverage.sh`의 BSD 전제, 이번 변경과 무관).
  - 실제 프로젝트 전후 비교(`main` 바이너리 대 브랜치 바이너리, 같은 인덱스): Yams 5.4.0(기본 183건, `--retain-public` 9건),
    swift-argument-parser 1.8.2(309건, 81건), cartograph 자기 분석 모두 진단과 limitations가 같다. 세 곳 모두 범위 밖 무시 소스가 없어서다.
  - 적대 입력(한 패키지·한 인덱스에 설정만 바꿔 `main`과 대조): 기본 제외 `R.generated.swift`·`Generated/`·한글과 공백이 든
    `생성 코드.generated.swift`, 대문자 `R.Generated.swift`(글롭이 대소문자를 가려 따라감), 사용자 `exclude`, 좁힌 `include`(무시 소스 8개
    전부 범위 밖, 보존 문장 없이 개수만), `.git/info/exclude`, 강제 추가된 추적 파일(무시 소스로 세지 않음), 추적 파일을 가리키는
    무시 링크(범위 안에서는 세지 않음, 제외돼도 리뷰 반영 뒤에는 세지 않음), 저장소 밖(한계 없음), 손상된 Git index(폴백, 문장 없음). 모든 경우
    발견 목록은 `main`과 같았고, 센 개수와 실제로 보고된 선언이 일치했다.
  - 못 돌린 것: `coverage.sh`(`xcrun llvm-cov`·`.xctest`), `verify-fixtures.sh` 전체(SwiftUI·Objective-C 코퍼스와 macOS 인덱스 전제 —
    새 검증기는 그 스크립트 끝에서 돌고 단독으로는 Linux에서 통과), macOS 전용 테스트. 근거는 macOS CI다. GLM 리뷰도 이 환경에서
    쓸 수 없었다.
- **리뷰 반영** (PR #241 독립 리뷰, 차단 항목 없음, 코드 `55e3abd`, 문서는 그다음 커밋):
  - 검증기 환경 격리: 공유 `run`이 호출자의 `GIT_*`를 그대로 넘겼다. 버린 저장소를 `GIT_DIR`로 지정해 옛 검증기를 돌리니
    `git -C <사본> init`이 그 바깥 저장소의 `.git` 파일 2개를 바꾸고 사본에는 `.git`이 생기지 않았으며, 빌드를 다 한 뒤에야
    엉뚱한 미사용 목록 불일치로 실패했다. 이제 `main()`과 `materialize()` 처음에 `GIT_*`를 지우고(Cartograph의 Git 호출 두 곳은
    이미 스스로 지운다), 사본 지역 설정에 `core.excludesFile=/dev/null`을 두고, 사본이 자기 저장소인지 확인한다. 같은 조건에서 새
    검증기는 통과하고 바깥 저장소는 그대로다. 전역 gitignore에 `Package.swift`를 둔 HOME으로도 옛 검증기는 빌드 뒤 경로 목록
    불일치로 실패하고 새 검증기는 통과한다. 드리프트 검사는 모든 `.swift`와 `Package.swift`로 넓혀, `.gitignore`에
    `/Package.swift`를 더한 변이를 빌드 전에(0초) 잡는다(옛 검사는 빌드 뒤 11초에 다른 이유로 실패).
  - 빌드 디렉터리: `BuildArtifactDirectories.prunedNames`(`.build`·`DerivedData` 등)는 걷지 않는다. Linux에서 SwiftPM 빌드 도구
    플러그인이 `.build/plugins/outputs/.../PluginGenerated.swift`에 `Helper.usedByPlugin()` 호출을 생성하게 하니
    `dead --retain-public`이 `usedByPlugin()`을 미사용으로 보고했고 어느 한계도 그 파일을 말하지 않았다. README 두 벌·CHANGELOG·
    코퍼스 README에 적고, 무시 소스 문장이 실릴 때 "Generated sources inside build directories that discovery does not walk … are not
    examined." 문장을 붙인다. 플러그인 출력을 따라가는 것은 아래 D2다.
  - 패턴 이름: 괄호 안의 기본 패턴 이름을 늘 붙이던 것을, 범위 밖 파일에 실제로 걸린 `exclude` 패턴(JSON, 제어 문자 이스케이프)과
    include 누락으로 바꾸고 고치는 방법도 걸린 쪽만 말한다. 사용자 `exclude`는 기본값을 대체하고 `init` 템플릿에는
    `**/Generated/**`가 없다.
  - 과다 계수: 추적 파일(범위 밖 포함)을 가리키는 무시 링크는 범위 밖 수에서 뺀다(`untrackedSources`, 추적 목록은 `allSourceFiles`).
    무시 소스 분할은 `IgnoredSourceReferences.partition` 한 번으로 한다.
  - 문서: 아래 "다음 할 일" 2의 "마지막 줄"을 고쳤다(ok 줄 뒤에 빈 줄과 "통과"가 온다). D1에 추적 생성 파일 사정을, 아래에 물려받은
    한계를 적었다. 코퍼스 README에 출처(R.swift 빌드 단계의 `R.generated.swift`, Sourcery의 `<Template>.generated.swift`, SwiftGen의
    `Generated/`, 에이전트 작업 사본)를 적었다.
  - 돌연변이(`GitSourceInventoryTests`, Linux 스크래치): 모든 exclude 패턴을 적음(5 issues), 추적 파일 링크를 셈(2), 빌드 디렉터리
    문장을 빼거나 늘 붙임(2·1), include 누락을 무시(2) — 다섯 개 모두 실패한다. 검증기는 리뷰 전 바이너리를 범위 밖 문장 검사에서
    잡는다(이제 걸린 패턴 `["**/*.generated.swift"]`과 빌드 디렉터리 문장까지 문자열로 본다).
  - 재검증: `swift test` 실패 59개가 `main` 기준선과 이름까지 같다(Kit의 issue 하나 차이는 이미 실패하는
    `MechanicalFixVerificationTests` 프로세스 그룹 테스트 안의 타이밍). 자기 분석 네 가지 exit 0, `dead` 경고 22건 동일(정점 9803).
    CLI 계약 276 ok·2 FAIL(`xcrun swiftc`). 검증기 통과. 적대 입력 재실행: 기본 설정 3건(패턴 두 개 이름), 사용자 `exclude` 1건(사용자
    패턴만, 추적 파일 링크 빠짐 — 전에는 2건), 좁힌 `include` 7건(전에는 8건, include 누락 함께 표시). 발견 목록은 리뷰 전 바이너리와
    모두 같다. Yams·swift-argument-parser도 진단·limitations가 같다.
- **물려받은 한계(리뷰가 지적, 이번에 고치지 않음)**:
  - 저장소 안 디렉터리 링크: 링크로 먼저 걷고 Git 목록과 대조한다는 지적이다. Linux에서 `ZMirror -> Sources/Lib/Core`(링크가 먼저 걸리는
    순서)로 재현하지 못했다 — `directoryEntries`가 링크 디렉터리의 자식을 실제 경로로 적어 Git 목록과 맞는다. macOS에서 다시 볼 것.
  - 대소문자만 바꾼 이름 변경: 대소문자를 가리지 않는 파일 시스템에서 `mv Foo.swift foo.swift` 뒤 Git 색인에는 `Foo.swift`가 남고 걷기는
    `foo.swift`를 낸다. `git.paths.contains`는 대소문자를 가리므로 그 파일이 무시 소스로 세지고 분석에서 빠질 수 있다(코드 판독, Linux
    ext4에서는 재현 불가).
  - ~~MCP 세션 지문: 세션 재사용 판단이 범위 안 경로만 보면 범위 밖 무시 파일이 생기거나 사라져도 개수가 낡을 수 있다는 지적이다.~~
    5차 점검에서 재현하고 고쳤다(위 "5차 점검").
- **제외한 것**:
  - 범위 밖 무시 소스를 따라가 보존하는 것(아래 "남은 후보" D1). 보존을 넓히는 쪽이지만 `exclude`의 뜻을 바꾼다. 추적되는 제외 파일은
    지금도 간선을 버리므로, 무시 파일만 따라가면 같은 `R.generated.swift`가 추적 여부에 따라 다른 답을 낸다.
  - 빌드 도구 플러그인 출력을 따라가는 것(아래 D2).
  - B1·B3·B5·C(사용자 선택), B2(Narrowing 절차), 보조 인덱스 읽기 비용 측정(실제 프로젝트 필요), `assign-only` 문구 고정,
    `accessHidingOwners` 첫 루프 정리, `CartographKit` 임베더 `Thresholds` 검사(API 동작 변경).

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
2. ~~무시 컴파일 소스 하위 코퍼스와 검증기~~ — 4차 점검에서 `Fixtures/IgnoredSourceCorpus`와 `verify-ignored-sources.py`로
   했다. macOS CI의 `verify-fixtures.sh` 로그 끝부분, "통과" 바로 앞의 ok 줄 "무시 컴파일 소스 경계 4개 경로·미사용 7건"을 확인한다.
3. 보조 인덱스 읽기 비용을 HealthMap 등 실제 프로젝트에서 잰다.
4. 발행은 지시가 있을 때만 한다. 이때 `[Unreleased]`를 버전 절로 옮기고 플러그인 매니페스트 버전도 함께 올린다.
5. PR #239(B4)의 macOS CI에서 `AgentSkillTemplateTests`·`verify-mcp.py`·`verify-plugin-manifest.py`와 완료 검증
   네 가지를 확인한다. `claude plugin validate .`(v2.1.281 이상이면 MCP 항목도 검사)를 돌릴 수 있는 환경이면 함께
   돌린다. GLM 리뷰를 받을 수 있게 되면 이 변경도 후속 리뷰한다.
6. 5차 점검 PR의 macOS CI에서 `GitSourceFreshnessTests`의 새 테스트 두 개(`/private/var` 임시 경로·APFS)와 `verify-mcp.py`,
   완료 검증 네 가지를 확인한다. Linux 스크래치에서는 통과했다.

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
- **결정 필요(4차 점검에서 발견)**
  - D1 `include`/`exclude`가 거른 Git 무시 소스도 따라갈지. 지금은 따라가지 않고 한계가 개수를 센다(`4b7bfde`). 기본 제외가
    R.swift·Sourcery·SwiftGen 출력과 겹쳐 기본 설정의 생성 파일 대부분이 해당한다. 무시 파일 자신은 어차피 분석 범위 밖이라 제외가
    더할 것이 없다는 점은 따라가는 쪽의 근거다. 추적되는 제외 파일은 간선을 버리는 현재 계약과 어긋난다는 점은 반대 근거다.
    그 계약 쪽도 조용하다: 기본 제외에 걸린 **추적** 생성 파일(`Forced.generated.swift`)은 호출자를 잃는데 아무 한계도 붙지 않는다
    (`configured-path-filter`는 기본값보다 좁힐 때만 실린다, `narrowsPathsBeyondDefaults`). 4차 적대 입력에서 확인했다.
  - D2 빌드 도구 플러그인 출력(`.build/plugins/outputs`, Xcode는 DerivedData)이 쓰는 선언을 보존할지. 탐색이 그 디렉터리를 걷지 않아
    지금은 미사용으로 보고되고 한계도 없다(무시 소스 문장이 실릴 때만 경계를 말한다). R.swift 7·SwiftGen·Sourcery 플러그인
    사용자에게 같은 오탐 계열이다. 스토어에서 플러그인 출력 유닛을 찾아 보조로 읽는 방식이 후보이며, 무시 소스와 같은 보존 근거를
    쓸지·한계로만 둘지를 정해야 한다.
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
이어 가고, 남은 후보(4차 점검의 D1·D2 포함)는 내가 고른 뒤 착수해.
발행·태그는 따로 지시가 있을 때만 해.
