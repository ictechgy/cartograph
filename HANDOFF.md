# Handoff

_Last updated: 2026-09-23_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다. 과거 Next Steps·미발행 표기는 당시 기록이다.

## Current Status

- **CLI 0.21.0 릴리스 진행 중(2026-09-23 사용자 승인):** `feature/release-0.21.0`은
  PR #130이 병합된 `90f4d8c`에서 시작했다. 버전 상수·설치 예제·변경 기록을 0.21.0으로
  맞추고, PR 검증·병합 후 새 태그로 universal 바이너리를 발행한다. 공개 archive의 해시·
  arm64/x86_64·CLI 계약과 Homebrew formula·설치 버전·brew test까지 확인하는 범위다.
  아직 0.21.0 공개 발행·Homebrew 갱신이 완료됐다고 해석하지 않는다. 근거는 로컬
  `.git/evidence-release-0.21.0-20260923/`에 모은다. GitHub Action `action-v1.0.0`과
  GitLab Catalog `1.0.0` 태그는 유지하며, GitLab의 CLI 0.20.0 고정은 별도 발행 계약이다.
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
  바이너리 입력은 이번 릴리스 브랜치에서 `version: 0.21.0`으로 갱신했다.
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
인증·임시 러너 등록·게시를 반복하지 않는다. CLI 0.21.0 발행은 새로 승인된 범위다.

현재 요청은 CLI 0.21.0의 GitHub·Homebrew 발행과 설치 검증까지다(2026-09-23 승인).
PR #130과 문서 정리는 완료됐다. 릴리스 PR·새 태그·Release 워크플로·공개 asset·tap formula·
설치 결과를 확인하며 이어간다. 실제 캐시 삭제와 추가 기능은 이번 범위가 아니다.
두 Orca 작업 폴더 `fix-action-marketplace-metadata/`,
`feature-gitlab-component/`는 부모 저장소의 로컬 exclude에 있고 정리 대상으로 승인받지 않았다.

SARIF 실측·공개 태그 실행·코퍼스·스킬·캐시 수명 관리·메모리 기준 계측은 구현과 검증이 완료됐다.
전역 실제 캐시 삭제나 `sourceCache` 최적화는 수행하지 않았다. 완료된 항목을 다시 착수하지 않는다.

- 경쟁 조사 C1~C5·S1~S6의 나머지 후보는 [과거 원장](HANDOFF-HISTORY.md#경쟁-조사--codegraph-대비-개선점-2026-09-18)과
  현재 코드를 대조한 뒤 범위를 선택한다. 런타임 텔레메트리는 연구 전용 보류다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. PR #130은 병합됐고 main CI와
SARIF 검증도 통과했어. 현재 승인된 작업은 CLI 0.21.0 발행과 Homebrew 갱신·설치 검증이야.
현재 브랜치는 feature/release-0.21.0이며 근거는 .git/evidence-release-0.21.0-20260923/에 모아.
GitHub Marketplace action-v1.0.0과 GitLab Catalog 1.0.0의 발행·소비자 검증은 끝났으니
인증·러너 승인·기존 태그 발행을 반복하지 마. GitLab 컴포넌트의 CLI 0.20.0 고정도 유지해.
사용자 변경을 보존하고 실제 릴리스·CI·tap 상태를 확인하며 이어가. 캐시 삭제와 작업 폴더 정리는 별도야.
