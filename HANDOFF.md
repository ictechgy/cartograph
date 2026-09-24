# Handoff

_Last updated: 2026-09-24 by Devin_

작업 규칙은 [AGENTS.md](AGENTS.md), 이전 원문은 [HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 있다.
이력의 오래된 버전·승인 대기·미발행 표기는 현재 지시로 되살리지 않는다.

## Goal

0.21.0 발행·배포는 전부 끝났고(아래 Completed 참고), isthmus의 두 번째 조인 도메인
**persistence**의 Swift 생산자 `cartograph schema`도 [PR #136](https://github.com/ictechgy/cartograph/pull/136)으로
머지 완료했다(`7ed102e`). persistence 생산자는 gartograph(Go)·rustograph(Rust)·
kartograph(Kotlin)·cartograph(Swift)가 호출 측 `relation-use`를 내고, schemagraph가
`relation-decl`을 내는 수신 측이다.

## Current Status

- 저장소: `/Users/jinhongan/Desktop/cartograph`. `main`은 `7ed102e`다.
- `cartograph schema`는 `feature/schema-facts-swift`에서 squash 머지됐다(원격·로컬 브랜치
  정리 완료). isthmus 측 수용 테스트·계약 문서는 isthmus PR #112(`b6a0eec`)로 머지됐다.
- `cartograph schema`는 SwiftSyntax 스캐너(`SchemaFactScanner` + `SqlRelations`)로
  sqlite3 인자·GRDB `sql:`/`Table`/`tableExists`/`databaseTableName`·SQLite.swift·Fluent·
  게이트 없는 대문자 SQL 리터럴을 읽어 `platform: "swift"`, `target: "persistence"`
  문서를 낸다. Core Data·SwiftData·Realm·미지원 DB 프레임워크는 사실이 아니라
  limitation 개수로 센다.
- GLM 리뷰 2라운드를 반영했다. 1라운드: extension 안 static 테이블 선언 귀속,
  `SQLite.Table` 한정 생성자, 바인딩 리터럴 이중 발화 억제, 표현식 빌더 과대계수,
  같은 이름 재바인딩 오귀속 방지, `tableExists`, limitation 파일 수 계수.
  2라운드: 중첩된 다른 테이블 수신자 호출의 컬럼이 바깥 채널로 오귀속하던 문제를
  ColumnCollector 서브트리 건너뛰기로 수정했다.
- 검증 상태: `swift build`·전체 `swift test` 390개(스캐너 31 + 렉서 8 포함)·
  `verify-cli-contract`·`verify-fixtures`·`coverage.sh`(통합 91.87%)·strict
  dead/cycles/cycles-type/rules 모두 통과. 실제 인덱스가 있는 fixture에서 isthmus
  `check` 조인까지 확인했다(matchedRelations·`relation-use-without-decl`·실제 USR 부착).
- `schema`는 아직 발행본에 없다 — 0.21.0 이후 main 기능이다. 다음 릴리스에서 포함된다.

| 발행물 | 현재 버전·상태 |
|---|---|
| CLI / Homebrew | [0.21.0](https://github.com/ictechgy/cartograph/releases/tag/0.21.0), 호스트 설치·검증 완료 |
| GitHub Action | [action-v1.0.0](https://github.com/marketplace/actions/cartograph-swift-analysis?version=action-v1.0.0), Marketplace 등록 완료 |
| GitLab component | [cartograph-ci 1.0.0](https://gitlab.com/explore/catalog/ictechgy/cartograph-ci), 별도 검증된 CLI 0.20.0 고정 유지 |

## Completed & Verification

- PR #130은 `90f4d8c`로 병합됐다. public/fix/affected 컴파일러 골든·스킬 안내,
  캐시 preview/apply·사용 중 잠금·최근 사용 표식, Action 실패 처리·SARIF 경로 보정이 포함된다.
- [릴리스 PR #133](https://github.com/ictechgy/cartograph/pull/133)과 태그 `0.21.0`의 소스는
  `ba9af2fa3cc426a42bfbed391cebfc1708b1b2f2`다. [PR CI](https://github.com/ictechgy/cartograph/actions/runs/35776430976):
  테스트 **1,650개**, 통합 커버리지 **92.83%**(단위 **87.50%**), CLI 계약·실제 코퍼스·런타임/MCP·
  strict dead·모듈/타입 cycles·rules 통과. [Release 실행](https://github.com/ictechgy/cartograph/actions/runs/35777799863)도 성공했다.
- 공개 universal archive SHA256:
  `4b204d2e343281499163df8def35374956d38b813d589519130f1f53244b623f`.
  독립 다운로드와 GitHub digest가 일치했다. arm64/x86_64·버전·CLI 계약과 포함된
  LICENSE·README·QUERY-EVIDENCE 문서를 검증했다.
- [Homebrew PR #50](https://github.com/ictechgy/homebrew-tap/pull/50)은 `0ef8908`로 병합됐다.
  formula URL·SHA, 호스트 0.20.0→0.21.0 upgrade, `brew test` 통과.
  설치 바이너리와 공개 바이너리의 바이트도 일치한다. 인계 시 `cartograph --version`은 0.21.0이다.
- Marketplace 메타데이터 PR #131, GitLab 구현 PR #132, GitLab MR !1은 병합됐다.
  공개 Action 태그의 실제 SARIF 실행에서 **37개 결과·5개 규칙·12개 파일 경로**와 서버 처리 완료를 확인했다.
- GitLab [태그 파이프라인](https://gitlab.com/ictechgy/cartograph-ci/-/pipelines/2871315648)과
  [소비자 파이프라인](https://gitlab.com/ictechgy/cartograph-ci/-/pipelines/2871345482)이 성공했다.
  같은 프로젝트의 검증 브랜치에서 진단 3개와 MR의 새 Code Quality 진단 1건을 확인했다.
  검증 MR !2는 병합 없이 닫았고 브랜치는 근거로 보존했다. 외부 별도 프로젝트 검증으로 확대 해석하지 않는다.
- 임시 GitLab Mac 러너 `56611172`의 등록·프로세스·임시 인증파일·체크아웃을 모두 정리했다.
  상시 서비스는 없다. 다음 유지관리 CI와 소비자는 적격 Mac 러너가 필요하다.

## Key Files & Evidence

- [README](README.md), [한국어 README](README.ko.md): 직접 설치·Action 바이너리 예제는 0.21.0.
  [상세 기록](docs/ACTION-CORPUS-CACHE.md): 코퍼스·캐시·Action·메모리 기준 계측과 발행 근거.
- `Integrations/GitLab/`: Catalog 배포 소스, 테스트. `.github/workflows/gitlab-component.yml`: GitHub 하네스.
- 로컬 `.git/evidence-release-0.21.0-20260923/status.json`: 릴리스·tap·설치 검증 완료와 원시 로그.
- 로컬 `.git/evidence-pr130-final-20260923/review.json`: 최종 검토·병합·CI·SARIF 근거.
- 로컬 `.git/evidence-gitlab-20260922/`: `status.json`, `pipeline-*.json`, `consumer-mr-report.txt`,
  `runner-cleanup/cleanup.json`. Marketplace 근거는 `.git/evidence-marketplace-20260922/`.
  `.git` 근거는 버전 관리되지 않는다. 공개 PR·CI 링크와 상세 기록을 함께 따른다.
- 로컬 `.git/evidence-cleanup-20260923/cleanup.json`: 사용자 요청으로 삭제한 경로·용량·보존 검증.
  GitLab 작업 폴더의 작은 smoke 보고서 3개는 같은 폴더의 `gitlab-smoke-reports/`에 보존했다.

## Important Context / Avoid

- 완료된 발행·계정 재인증·임시 러너 승인·설치를 다시 시작하지 않는다. 기존 태그를 이동하지 않는다.
  Marketplace 기본 최신 선택은 저장소 CLI latest를 따르므로 Action은 버전별 링크로 안내한다.
- Release 잡 성공만으로 tap 갱신을 단정하지 않는다. 이번에도 토큰 미설정으로 자동 갱신을 건너뛰어
  별도 tap PR로 반영했다. 토큰 파일을 읽거나 재설정할 필요는 없다.
- GitLab 유지관리 러너는 `CARTOGRAPH_CI_RUNNER_TAG`로 선택한다. Orca의 파일 Replace 업로드가
  동작했으며, 편집 후 API/Git로 대조했다. 완료한 인증·편집기 실패를 재시도하지 않는다.
- `sourceCache`는 최적화하지 않았고 메모리 기준 계측만 했다. 실제 전역 캐시는 삭제하지 않았다.
  `ReactNativeEventScanner.swift`의 unused `import Foundation`은 schema-facts 작업에서 제거했다
  — `dead --strict`가 경고를 위반으로 세기 때문에 게이트를 막고 있었다.
- schema 스캐너의 채널 이스케이프 규약: 호출 인자 리터럴(`Table("main.users")`)은 `.`가
  한정자라 `escapeQualified`, 선언 이름(`static let databaseTableName`)은 리터럴 식별자라
  `escapeName`. `SchemaDeclCollector`/`SchemaFactCollector`는 단방향 참조여야 한다
  (공유 상수는 Decl 쪽에 둠 — 타입 순환이 `cycles --level type --strict`에 걸린다).
- 2026-09-23 사용자 정리 요청으로 `fix-action-marketplace-metadata/`, `feature-gitlab-component/`와
  연결 로컬 브랜치·셸을 Orca에서 제거했다. 미커밋 변경 없음과 병합 커밋의 파일 일치를 먼저 확인했다.
  원격 브랜치와 태그는 유지했다. 삭제된 폴더의 로컬 exclude 항목도 제거했다.
- 약 1.15 GiB의 불필요한 사본·산출물을 정리했다: 오래된 0.18.0 Release 제품·중간 산출물,
  코퍼스 `.build`, Python 캐시, 0.21.0 다운로드/압축 해제 사본·임시 tap 체크아웃.
  현재 Debug 빌드·인덱스·의존성 캐시와 검증 로그·manifest는 보존했다.
  Release·코퍼스 빌드가 다시 필요하면 재생성한다. 설치본과 `.build/debug/cartograph`는 모두 0.21.0이다.
- 2026-09-24 두 번째 정리: 머지 완료된 로컬 브랜치 13개를 삭제했다(각 PR 병합 확인,
  원격 브랜치는 유지). 원격이 없던 `feature/gitlab-catalog-export`(고아 브랜치)는 트리가
  `main:Integrations/GitLab`과 동일(`840d35c`)함을, `feature/schema-facts`는 #134 병합본과
  같은 커밋임을 확인했다. 산출물은 ValueFlowBenchmark 실행별 `swift-build`·`.swift-build`,
  `Fixtures/FalsePositiveCorpus/.build`, 루트 `default.profraw`, `Scripts/__pycache__`,
  `.DS_Store`를 지워 약 680 MiB를 확보했다. 벤치마크 결과 JSON·로그와 `.build`(Debug·인덱스)는 보존했다.
- 제품 소스는 바뀌지 않았다. 정리 대상 부재·현재 인덱스·CLI 버전·문서 보존을 확인했으며,
  기존 제품 검증 근거를 재사용했다. 산출물을 다시 만드는 전체 테스트는 재실행하지 않았다.

## Next Steps

`cartograph schema`는 머지 완료다. 남은 확장 후보는 dartograph(Dart) 생산자,
도메인 간 상관(공유 심볼 키 — DB 컬럼 변경 → API 핸들러 → 위젯), 세 번째
도메인(네트워크 경계)이다.
자매 확장의 KAPT/KSP receipt snapshot/cache 연동, iPhone·iOS release·RN 새 아키텍처 검증,
collector 발행은 [isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md)가 정본이다.
런타임 텔레메트리는 연구 전용 보류다. 이 후보들을 자동으로 착수하지 않는다.

## Resume Prompt

`/Users/jinhongan/Desktop/cartograph`에서 HANDOFF.md와 적용 AGENTS.md를 읽고 Git 상태를 확인해줘.
`cartograph schema`(Swift persistence 생산자)는 PR #136으로 머지 완료됐어(`7ed102e`) —
로컬 브랜치·재생성 가능한 산출물 정리도 끝났다(로컬에는 `main`만 남음).
남은 후보는 dartograph 생산자·교차 도메인 상관·네트워크 도메인이고 자동 착수하지 말 것.
0.21.0 발행·검증은 전부 끝났으니 반복하지 말 것.
